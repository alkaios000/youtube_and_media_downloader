package com.linkdrop.linkdrop_downloader

import android.Manifest
import android.app.Activity
import android.app.WallpaperManager
import android.content.ClipData
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.yausername.aria2c.Aria2c
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.zip.ZipInputStream
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

class MediaEngineBridge(private val context: Context) {
    companion object {
        private const val TAG = "AllDownloadEngine"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val uncaughtHandler = CoroutineExceptionHandler { _, throwable ->
        Log.e(TAG, "Unhandled engine coroutine error", throwable)
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO + uncaughtHandler)

    @Volatile
    private var isInitialized = false

    @Volatile
    private var ffmpegReady = false

    @Volatile
    private var aria2cReady = false

    @Volatile
    private var progressEmitter: ((Map<String, Any?>) -> Unit)? = null

    private val pausedTasks = java.util.Collections.synchronizedSet(HashSet<String>())

    fun setProgressEmitter(emitter: ((Map<String, Any?>) -> Unit)?) {
        progressEmitter = emitter
    }

    private fun postToMain(block: () -> Unit) {
        mainHandler.post(block)
    }

    fun initEngine(onSuccess: (Map<String, Any?>) -> Unit, onError: (String, String) -> Unit) {
        scope.launch {
            try {
                ensureInitialized()
                // Skip spawning Python `yt-dlp --version` subprocess during launch init
                // so app startup stays instant; exact version is fetched lazily in Settings.
                val info = mapOf(
                    "initialized" to isInitialized,
                    "version" to "bundled",
                    "ffmpegReady" to ffmpegReady,
                    "aria2cReady" to aria2cReady,
                    "downloadFolder" to getPublicFolderLabel(),
                )
                postToMain { onSuccess(info) }
            } catch (t: Throwable) {
                Log.e(TAG, "initEngine failed", t)
                postToMain { onError("INIT_ERROR", t.message ?: "Gagal inisialisasi engine yt-dlp") }
            }
        }
    }

    @Synchronized
    private fun ensureInitialized() {
        if (isInitialized) return
        YoutubeDL.getInstance().init(context)
        ffmpegReady = try {
            FFmpeg.getInstance().init(context)
            ensureCppSharedLibCopied()
            true
        } catch (t: Throwable) {
            Log.w(TAG, "FFmpeg init warning", t)
            false
        }
        aria2cReady = try {
            Aria2c.getInstance().init(context)
            ensureCppSharedLibCopied()
            true
        } catch (t: Throwable) {
            Log.w(TAG, "Aria2c init warning", t)
            false
        }
        isInitialized = true
    }

    private fun ensureCppSharedLibCopied() {
        runCatching {
            val nativeLibDir = File(context.applicationInfo.nativeLibraryDir)
            val source = File(nativeLibDir, "libc++_shared.so")
            if (!source.exists()) return

            val baseDir = File(context.noBackupFilesDir, "youtubedl-android/packages")
            val targetLibDirs = listOf(
                File(baseDir, "ffmpeg/usr/lib"),
                File(baseDir, "aria2c/usr/lib"),
                File(baseDir, "python/usr/lib"),
            )
            for (libDir in targetLibDirs) {
                if (libDir.exists() && libDir.isDirectory) {
                    val dest = File(libDir, "libc++_shared.so")
                    if (!dest.exists() || dest.length() != source.length()) {
                        source.copyTo(dest, overwrite = true)
                    }
                }
            }
        }.onFailure { Log.w(TAG, "ensureCppSharedLibCopied warning", it) }
    }

    private fun resolveEffectiveCookiesPath(cookiesPath: String?): String? {
        if (!cookiesPath.isNullOrBlank() && File(cookiesPath).exists()) {
            return cookiesPath
        }
        val webViewCookies = File(context.filesDir, "webview_cookies.txt")
        if (webViewCookies.exists() && webViewCookies.length() > 30) {
            return webViewCookies.absolutePath
        }
        return null
    }

    fun updateEngine(
        channelName: String,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (String, String) -> Unit,
    ) {
        scope.launch {
            try {
                ensureInitialized()
                val channel = when (channelName.lowercase(Locale.US)) {
                    "nightly" -> YoutubeDL.UpdateChannel._NIGHTLY
                    "master" -> YoutubeDL.UpdateChannel._MASTER
                    else -> YoutubeDL.UpdateChannel._STABLE
                }
                val status = YoutubeDL.getInstance().updateYoutubeDL(context, channel)
                val version = runCatching { YoutubeDL.getInstance().version(context) }.getOrNull() ?: "unknown"
                val statusText = status?.name ?: "DONE"
                postToMain {
                    onSuccess(
                        mapOf(
                            "status" to statusText,
                            "updated" to (status == YoutubeDL.UpdateStatus.DONE),
                            "version" to version,
                        ),
                    )
                }
            } catch (t: Throwable) {
                Log.e(TAG, "updateEngine failed", t)
                postToMain { onError("UPDATE_ERROR", t.message ?: "Gagal memperbarui engine yt-dlp") }
            }
        }
    }

    fun extractInfo(
        url: String,
        cookiesPath: String?,
        onSuccess: (String) -> Unit,
        onError: (String, String) -> Unit,
    ) {
        scope.launch {
            try {
                ensureInitialized()
                val effectiveCookies = resolveEffectiveCookiesPath(cookiesPath)
                val request = YoutubeDLRequest(url)
                request.addOption("--dump-single-json")
                request.addOption("--no-playlist")
                request.addOption("--no-warnings")
                request.addOption("--skip-download")
                request.addOption("--socket-timeout", "25")
                if (effectiveCookies != null) {
                    request.addOption("--cookies", effectiveCookies)
                }

                val response = YoutubeDL.getInstance().execute(request)
                val rawOut = response.out?.trim().orEmpty()
                if (rawOut.isEmpty()) {
                    val errText = response.err?.trim().orEmpty()
                    throw IllegalStateException(
                        if (errText.isNotEmpty()) errText else "Tidak ada metadata yang diterima dari link ini.",
                    )
                }
                postToMain { onSuccess(rawOut) }
            } catch (t: Throwable) {
                Log.e(TAG, "extractInfo failed", t)
                postToMain { onError("EXTRACT_ERROR", sanitizeError(t.message)) }
            }
        }
    }

    fun extractProfileItems(
        url: String,
        cookiesPath: String?,
        onSuccess: (String) -> Unit,
        onError: (String, String) -> Unit,
    ) {
        scope.launch {
            try {
                ensureInitialized()
                val effectiveCookies = resolveEffectiveCookiesPath(cookiesPath)
                val request = YoutubeDLRequest(url)
                request.addOption("--flat-playlist")
                request.addOption("--dump-single-json")
                request.addOption("--no-warnings")
                request.addOption("--skip-download")
                request.addOption("--socket-timeout", "45")
                if (effectiveCookies != null) {
                    request.addOption("--cookies", effectiveCookies)
                }

                val response = YoutubeDL.getInstance().execute(request)
                val rawOut = response.out?.trim().orEmpty()
                if (rawOut.isEmpty()) {
                    val errText = response.err?.trim().orEmpty()
                    throw IllegalStateException(
                        if (errText.isNotEmpty()) errText else "Tidak menemukan daftar media pada profil ini.",
                    )
                }
                postToMain { onSuccess(rawOut) }
            } catch (t: Throwable) {
                Log.e(TAG, "extractProfileItems failed", t)
                postToMain { onError("PROFILE_ERROR", sanitizeError(t.message)) }
            }
        }
    }

    fun downloadWithYtDlp(
        taskId: String,
        url: String,
        formatSelector: String?,
        audioOnly: Boolean,
        audioFormat: String,
        cookiesPath: String?,
        useAria2c: Boolean,
        platformFolder: String,
        creatorFolder: String,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (String, String) -> Unit,
    ) {
        scope.launch {
            val workDir = File(context.cacheDir, "ytdl_task_$taskId")
            try {
                ensureInitialized()
                ensureCppSharedLibCopied()
                val effectiveCookies = resolveEffectiveCookiesPath(cookiesPath)
                val isYouTube = url.lowercase(Locale.US).let {
                    it.contains("youtube.com") || it.contains("youtu.be")
                }

                val attempts = mutableListOf<DownloadAttempt>()
                val primarySelector = formatSelector?.takeIf { it.isNotBlank() }
                    ?: "bestvideo[vcodec^=avc1][ext=mp4]+bestaudio[ext=m4a]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best[ext=mp4]/best"
                attempts.add(
                    DownloadAttempt(
                        label = null,
                        formatSelector = primarySelector,
                        extraExtractorArgs = null,
                        forceMerge = ffmpegReady && !audioOnly,
                    ),
                )
                if (isYouTube) {
                    attempts.add(
                        DownloadAttempt(
                            label = "Mencoba klien alternatif YouTube...",
                            formatSelector = primarySelector,
                            extraExtractorArgs = "youtube:player_client=android,web_safari",
                            forceMerge = ffmpegReady && !audioOnly,
                        ),
                    )
                    if (!audioOnly) {
                        attempts.add(
                            DownloadAttempt(
                                label = "Mencoba mode kompatibel (MP4 langsung)...",
                                formatSelector = "best[vcodec^=avc1][ext=mp4]/best[ext=mp4]/18/best",
                                extraExtractorArgs = "youtube:player_client=android,tv_embedded,web",
                                forceMerge = false,
                            ),
                        )
                    }
                }

                var lastError: Throwable? = null
                var producedPrimary: File? = null
                pausedTasks.remove(taskId)

                for ((attemptIdx, attempt) in attempts.withIndex()) {
                    if (attemptIdx > 0 && workDir.exists()) {
                        workDir.deleteRecursively()
                    }
                    workDir.mkdirs()

                    if (attempt.label != null) {
                        emitProgress(taskId, -1.0, -1, attempt.label)
                    }

                    val request = YoutubeDLRequest(url)
                    request.addOption("-o", "${workDir.absolutePath}/%(title).80s [%(id)s].%(ext)s")
                    request.addOption("--no-playlist")
                    request.addOption("--no-mtime")
                    request.addOption("--continue")
                    request.addOption("--windows-filenames")
                    request.addOption("--socket-timeout", "30")
                    request.addOption("--retries", "3")
                    request.addOption("--fragment-retries", "3")

                    if (effectiveCookies != null) {
                        request.addOption("--cookies", effectiveCookies)
                    }

                    if (attempt.extraExtractorArgs != null) {
                        request.addOption("--extractor-args", attempt.extraExtractorArgs)
                    }

                    if (audioOnly) {
                        val targetAudio = audioFormat.lowercase(Locale.US).ifBlank { "mp3" }
                        request.addOption("-x")
                        request.addOption("--audio-format", targetAudio)
                        request.addOption("--audio-quality", "0")
                        request.addOption("--add-metadata")
                    } else {
                        request.addOption("-f", attempt.formatSelector)
                        if (attempt.forceMerge) {
                            request.addOption("--merge-output-format", "mp4")
                        }
                    }

                    if (useAria2c && aria2cReady && !audioOnly && attempt.extraExtractorArgs == null) {
                        request.addOption("--downloader", "libaria2c.so")
                        request.addOption("--external-downloader-args", "aria2c:\"--summary-interval=1 -x 4 -s 4 -k 1M\"")
                    }

                    try {
                        var lastEmitTime = 0L
                        YoutubeDL.getInstance().execute(request, taskId) { progress, etaInSeconds, line ->
                            val now = System.currentTimeMillis()
                            if (now - lastEmitTime >= 180L || progress >= 99.5f || progress < 0f) {
                                lastEmitTime = now
                                emitProgress(taskId, progress.toDouble(), etaInSeconds, line ?: "")
                            }
                        }

                        val producedFiles = workDir.listFiles()
                            ?.filter { file ->
                                file.isFile &&
                                    file.length() > 0 &&
                                    !file.name.endsWith(".part", ignoreCase = true) &&
                                    !file.name.endsWith(".ytdl", ignoreCase = true) &&
                                    !file.name.endsWith(".temp", ignoreCase = true)
                            }
                            ?.sortedByDescending { it.length() }
                            .orEmpty()

                        if (producedFiles.isNotEmpty()) {
                            producedPrimary = producedFiles.first()
                            break
                        } else {
                            lastError = IllegalStateException("File hasil unduhan tidak ditemukan.")
                        }
                    } catch (t: Throwable) {
                        val msg = t.message.orEmpty()
                        if (msg.contains("destroyed", ignoreCase = true) || msg.contains("interrupt", ignoreCase = true)) {
                            throw t
                        }
                        Log.w(TAG, "Download attempt failed (${attempt.extraExtractorArgs ?: "default"}): $msg")
                        lastError = t
                    }
                }

                val primaryFile = producedPrimary
                    ?: throw (lastError ?: IllegalStateException("File hasil unduhan tidak ditemukan."))

                val initialMime = detectMimeType(primaryFile.name)
                val preparedFile = if (initialMime.startsWith("video/", ignoreCase = true)) {
                    emitProgress(taskId, 99.0, 0, "Memperbarui waktu media agar tampil paling atas...")
                    stampFreshVideoMetadata(primaryFile, workDir)
                } else {
                    primaryFile
                }
                val finalName = if (preparedFile.name.endsWith(".mp4", ignoreCase = true) &&
                    !primaryFile.name.endsWith(".mp4", ignoreCase = true)
                ) {
                    primaryFile.name.substringBeforeLast('.') + ".mp4"
                } else {
                    primaryFile.name
                }
                val mimeType = detectMimeType(finalName)
                val exported = exportFileToPublicStorage(
                    sourceFile = preparedFile,
                    requestedName = finalName,
                    mimeType = mimeType,
                    platformFolder = platformFolder,
                    creatorFolder = creatorFolder,
                )

                postToMain { onSuccess(exported) }
            } catch (t: Throwable) {
                val wasPaused = pausedTasks.remove(taskId)
                val msg = t.message.orEmpty()
                if (wasPaused) {
                    postToMain { onError("PAUSED", "Unduhan dijeda.") }
                } else if (msg.contains("destroyed", ignoreCase = true) || msg.contains("interrupt", ignoreCase = true)) {
                    postToMain { onError("CANCELLED", "Unduhan dibatalkan.") }
                } else {
                    Log.e(TAG, "downloadWithYtDlp failed", t)
                    postToMain { onError("DOWNLOAD_ERROR", sanitizeError(msg)) }
                }
            } finally {
                // Keep partial .part files on disk when paused so yt-dlp --continue resumes cleanly!
                if (!pausedTasks.contains(taskId)) {
                    val hasPartial = workDir.listFiles()?.any { it.name.endsWith(".part", ignoreCase = true) } == true
                    if (!hasPartial) {
                        runCatching { workDir.deleteRecursively() }
                    }
                }
            }
        }
    }

    private fun emitProgress(taskId: String, progress: Double, etaSeconds: Long, line: String) {
        val payload = mapOf(
            "taskId" to taskId,
            "progress" to progress,
            "etaSeconds" to etaSeconds,
            "line" to line,
        )
        postToMain { progressEmitter?.invoke(payload) }
    }

    private data class DownloadAttempt(
        val label: String?,
        val formatSelector: String,
        val extraExtractorArgs: String?,
        val forceMerge: Boolean,
    )

    fun pauseDownload(taskId: String): Boolean {
        pausedTasks.add(taskId)
        return try {
            YoutubeDL.getInstance().destroyProcessById(taskId)
        } catch (_: Throwable) {
            false
        }
    }

    fun cancelDownload(taskId: String): Boolean {
        pausedTasks.remove(taskId)
        val ok = try {
            YoutubeDL.getInstance().destroyProcessById(taskId)
        } catch (_: Throwable) {
            false
        }
        scope.launch {
            runCatching { File(context.cacheDir, "ytdl_task_$taskId").deleteRecursively() }
        }
        return ok
    }

    /**
     * Builds the complete `LD_LIBRARY_PATH` required by bundled `libffmpeg.so`.
     * Crucially includes `python/usr/lib` (which provides `libexpat.so.1` needed
     * by `libfontconfig.so`), `ffmpeg/usr/lib`, `aria2c/usr/lib`, and `nativeLibDir`.
     */
    private fun buildFfmpegLdLibraryPath(nativeLibDir: File, existingLd: String = ""): String {
        val pkgsBase = File(context.noBackupFilesDir, "youtubedl-android/packages")
        val candidates = listOf(
            File(pkgsBase, "ffmpeg/usr/lib"),
            File(pkgsBase, "python/usr/lib"),
            File(pkgsBase, "aria2c/usr/lib"),
            nativeLibDir,
        )
        val parts = ArrayList<String>(5)
        for (dir in candidates) {
            if (dir.exists()) parts.add(dir.absolutePath)
        }
        if (existingLd.isNotBlank()) parts.add(existingLd)
        return parts.joinToString(":")
    }

    /**
     * Converts a downloaded Pixiv Ugoira `.zip` archive + frame delay metadata into a smooth
     * playable H.264 `.mp4` video (or animated `.gif`) using the bundled native `libffmpeg.so`,
     * then exports directly to Private Vault (default for Pixiv) or Public Gallery.
     */
    fun convertUgoiraZip(
        zipPath: String,
        frames: List<Map<String, Any?>>,
        outputFormat: String,
        fileName: String,
        platformFolder: String,
        creatorFolder: String,
        albumFolder: String? = null,
        isPrivate: Boolean = true,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (String, String) -> Unit,
    ) {
        scope.launch {
            val zipFile = File(zipPath)
            val workDir = File(context.cacheDir, "ugoira_${System.currentTimeMillis()}_${zipFile.name.hashCode()}")
            val framesDir = File(workDir, "frames")
            try {
                if (!zipFile.exists() || zipFile.length() == 0L) {
                    throw IllegalArgumentException("File ZIP Ugoira tidak ditemukan atau kosong.")
                }
                ensureInitialized()
                ensureCppSharedLibCopied()

                val nativeLibDir = File(context.applicationInfo.nativeLibraryDir)
                val ffmpegBin = File(nativeLibDir, "libffmpeg.so")
                if (!ffmpegBin.exists()) {
                    throw IllegalStateException("Engine FFmpeg tidak ditemukan untuk mengonversi Ugoira.")
                }

                framesDir.mkdirs()
                val canonicalFramesRoot = framesDir.canonicalPath
                val extractedFiles = mutableListOf<String>()

                ZipInputStream(FileInputStream(zipFile).buffered()).use { zis ->
                    val buffer = ByteArray(32 * 1024)
                    var entry = zis.nextEntry
                    while (entry != null) {
                        if (!entry.isDirectory) {
                            val entryName = File(entry.name).name
                            if (entryName.isNotBlank() && !entryName.startsWith(".")) {
                                val outTarget = File(framesDir, entryName)
                                if (outTarget.canonicalPath.startsWith(canonicalFramesRoot)) {
                                    FileOutputStream(outTarget).use { fos ->
                                        var read = zis.read(buffer)
                                        while (read > 0) {
                                            fos.write(buffer, 0, read)
                                            read = zis.read(buffer)
                                        }
                                    }
                                    extractedFiles.add(entryName)
                                }
                            }
                        }
                        zis.closeEntry()
                        entry = zis.nextEntry
                    }
                }

                if (extractedFiles.isEmpty()) {
                    throw IllegalStateException("Arsip ZIP Ugoira tidak berisi frame gambar.")
                }

                val orderedFrames = mutableListOf<Pair<String, Int>>()
                for (f in frames) {
                    val fName = File(f["file"]?.toString().orEmpty()).name
                    val delayMs = ((f["delay"] as? Number)?.toInt() ?: 50).coerceIn(10, 10000)
                    if (fName.isNotEmpty() && File(framesDir, fName).exists()) {
                        orderedFrames.add(fName to delayMs)
                    }
                }
                if (orderedFrames.isEmpty()) {
                    extractedFiles.sorted().forEach { name ->
                        orderedFrames.add(name to 50)
                    }
                }

                // Write FFmpeg concat demuxer script with exact Pixiv per-frame durations
                val concatFile = File(framesDir, "concat.txt")
                val sb = StringBuilder("ffconcat version 1.0\n")
                for ((fName, delayMs) in orderedFrames) {
                    val escaped = fName.replace("'", "'\\''")
                    val sec = String.format(Locale.US, "%.4f", delayMs / 1000.0)
                    sb.append("file '").append(escaped).append("'\n")
                    sb.append("duration ").append(sec).append('\n')
                }
                // FFmpeg concat demuxer requires repeating the final frame once to keep its duration
                val lastEscaped = orderedFrames.last().first.replace("'", "'\\''")
                sb.append("file '").append(lastEscaped).append("'\n")
                concatFile.writeText(sb.toString())

                val isGif = outputFormat.equals("gif", ignoreCase = true)
                val outExt = if (isGif) "gif" else "mp4"
                val outFile = File(workDir, "ugoira_out.$outExt")

                fun runFfmpeg(args: List<String>): Pair<Int, String> {
                    if (outFile.exists()) runCatching { outFile.delete() }
                    val cmd = mutableListOf(ffmpegBin.absolutePath)
                    cmd.addAll(args)
                    val pb = ProcessBuilder(cmd)
                    pb.directory(framesDir)
                    pb.redirectErrorStream(true)
                    val existingLd = pb.environment()["LD_LIBRARY_PATH"].orEmpty()
                    pb.environment()["LD_LIBRARY_PATH"] =
                        buildFfmpegLdLibraryPath(nativeLibDir, existingLd)

                    val proc = pb.start()
                    val logBuf = StringBuilder()
                    val drain = Thread {
                        runCatching {
                            proc.inputStream.bufferedReader().use { r ->
                                logBuf.append(r.readText().takeLast(600))
                            }
                        }
                    }
                    drain.start()
                    val finished = proc.waitFor(180, TimeUnit.SECONDS)
                    if (!finished) {
                        proc.destroyForcibly()
                        return -1 to "FFmpeg timeout"
                    }
                    drain.join(1500)
                    return proc.exitValue() to logBuf.toString()
                }

                var ok = false
                var lastLog = ""
                if (isGif) {
                    val (code1, log1) = runFfmpeg(
                        listOf(
                            "-y", "-f", "concat", "-safe", "0", "-i", "concat.txt",
                            "-vf", "scale='min(720,iw)':-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3",
                            "-loop", "0",
                            outFile.absolutePath,
                        ),
                    )
                    if (code1 == 0 && outFile.exists() && outFile.length() > 512L) {
                        ok = true
                    } else {
                        lastLog = log1
                        val (code2, log2) = runFfmpeg(
                            listOf(
                                "-y", "-f", "concat", "-safe", "0", "-i", "concat.txt",
                                "-loop", "0",
                                outFile.absolutePath,
                            ),
                        )
                        if (code2 == 0 && outFile.exists() && outFile.length() > 512L) {
                            ok = true
                        } else {
                            lastLog = log2
                        }
                    }
                } else {
                    val vfFilter = "pad=ceil(iw/2)*2:ceil(ih/2)*2:color=black,format=yuv420p"
                    // Attempt 1: Variable-frame-rate H.264 High@4.1 (exact Pixiv frame delays)
                    val (code1, log1) = runFfmpeg(
                        listOf(
                            "-y", "-f", "concat", "-safe", "0", "-i", "concat.txt",
                            "-vf", vfFilter,
                            "-c:v", "libx264", "-profile:v", "high", "-level", "4.1",
                            "-pix_fmt", "yuv420p",
                            "-fps_mode", "vfr", "-crf", "18", "-preset", "veryfast",
                            "-movflags", "+faststart",
                            outFile.absolutePath,
                        ),
                    )
                    if (code1 == 0 && outFile.exists() && outFile.length() > 512L) {
                        ok = true
                    } else {
                        lastLog = log1
                        // Attempt 2: Constant-frame-rate H.264 fallback (handles quirky frame timestamps)
                        val (code2, log2) = runFfmpeg(
                            listOf(
                                "-y", "-f", "concat", "-safe", "0", "-i", "concat.txt",
                                "-vf", vfFilter,
                                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                                "-fps_mode", "cfr", "-r", "24", "-crf", "19", "-preset", "veryfast",
                                "-movflags", "+faststart",
                                outFile.absolutePath,
                            ),
                        )
                        if (code2 == 0 && outFile.exists() && outFile.length() > 512L) {
                            ok = true
                        } else {
                            lastLog = log2
                            // Attempt 3: Universal mpeg4 fallback
                            val (code3, log3) = runFfmpeg(
                                listOf(
                                    "-y", "-f", "concat", "-safe", "0", "-i", "concat.txt",
                                    "-vf", vfFilter,
                                    "-c:v", "mpeg4", "-q:v", "3", "-pix_fmt", "yuv420p",
                                    "-fps_mode", "cfr", "-r", "24", "-movflags", "+faststart",
                                    outFile.absolutePath,
                                ),
                            )
                            if (code3 == 0 && outFile.exists() && outFile.length() > 512L) {
                                ok = true
                            } else {
                                lastLog = log3
                            }
                        }
                    }
                    if (ok) {
                        Mp4TimestampPatcher.patchToNow(outFile)
                    }
                }

                if (!ok) {
                    Log.e(TAG, "convertUgoiraZip FFmpeg failed: $lastLog")
                    val detail = lastLog.lines().lastOrNull { it.isNotBlank() }?.take(140).orEmpty()
                    throw IllegalStateException(
                        if (detail.isNotEmpty()) "Gagal konversi Ugoira (FFmpeg): $detail" else "Gagal mengonversi Ugoira dengan FFmpeg.",
                    )
                }

                val safeName = sanitizeFileName(fileName)
                val mimeType = if (isGif) "image/gif" else "video/mp4"
                val exported = if (isPrivate) {
                    exportFileToPrivateVault(
                        sourceFile = outFile,
                        requestedName = safeName,
                        mimeType = mimeType,
                        platformFolder = platformFolder,
                        creatorFolder = creatorFolder,
                        albumFolder = albumFolder,
                    )
                } else {
                    exportFileToPublicStorage(
                        sourceFile = outFile,
                        requestedName = safeName,
                        mimeType = mimeType,
                        platformFolder = platformFolder,
                        creatorFolder = creatorFolder,
                        albumFolder = albumFolder,
                    )
                }

                postToMain { onSuccess(exported) }
            } catch (t: Throwable) {
                Log.e(TAG, "convertUgoiraZip failed", t)
                postToMain { onError("UGOIRA_ERROR", t.message ?: "Gagal mengonversi Ugoira") }
            } finally {
                runCatching { zipFile.delete() }
                runCatching { workDir.deleteRecursively() }
            }
        }
    }

    fun saveFileToDownloads(
        sourcePath: String,
        fileName: String,
        mimeType: String?,
        platformFolder: String,
        creatorFolder: String,
        albumFolder: String? = null,
        isPrivate: Boolean = false,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (String, String) -> Unit,
    ) {
        scope.launch {
            val sourceFile = File(sourcePath)
            var stampedTemp: File? = null
            try {
                if (!sourceFile.exists() || sourceFile.length() == 0L) {
                    throw IllegalArgumentException("File sementara tidak ditemukan atau kosong.")
                }
                val safeName = sanitizeFileName(fileName)
                val resolvedMime = mimeType?.takeIf { it.isNotBlank() } ?: detectMimeType(safeName)
                val fileToExport = if (!isPrivate && resolvedMime.startsWith("video/", ignoreCase = true)) {
                    runCatching { ensureInitialized() }
                    val stamped = stampFreshVideoMetadata(sourceFile, sourceFile.parentFile ?: context.cacheDir)
                    if (stamped.absolutePath != sourceFile.absolutePath) {
                        stampedTemp = stamped
                    }
                    stamped
                } else {
                    sourceFile
                }
                val exported = if (isPrivate) {
                    exportFileToPrivateVault(
                        sourceFile = fileToExport,
                        requestedName = safeName,
                        mimeType = resolvedMime,
                        platformFolder = platformFolder,
                        creatorFolder = creatorFolder,
                        albumFolder = albumFolder,
                    )
                } else {
                    exportFileToPublicStorage(
                        sourceFile = fileToExport,
                        requestedName = safeName,
                        mimeType = resolvedMime,
                        platformFolder = platformFolder,
                        creatorFolder = creatorFolder,
                        albumFolder = albumFolder,
                    )
                }
                runCatching { sourceFile.delete() }
                runCatching { stampedTemp?.delete() }
                postToMain { onSuccess(exported) }
            } catch (t: Throwable) {
                runCatching { stampedTemp?.delete() }
                Log.e(TAG, "saveFileToDownloads failed", t)
                postToMain { onError("SAVE_ERROR", t.message ?: "Gagal menyimpan file") }
            }
        }
    }

    fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    /**
     * Shared external hidden vault (`Documents/.all_download_vault/`) that survives
     * app uninstall, clear-data, reinstall, and `flutter run` while remaining 100%
     * hidden from Android Gallery & WhatsApp via `.nomedia`.
     */
    private fun persistentVaultBaseDir(): File? {
        if (!hasAllFilesAccess()) return null
        return runCatching {
            @Suppress("DEPRECATION")
            val docs = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
            val base = File(docs, ".all_download_vault")
            if (!base.exists()) base.mkdirs()
            if (!base.exists() || !base.canWrite()) return@runCatching null
            val nomedia = File(base, ".nomedia")
            if (!nomedia.exists()) runCatching { nomedia.createNewFile() }
            base
        }.getOrNull()
    }

    fun getPersistentStateDirPath(): String? {
        val base = persistentVaultBaseDir() ?: return null
        val stateDir = File(base, "state")
        if (!stateDir.exists()) stateDir.mkdirs()
        val nomedia = File(stateDir, ".nomedia")
        if (!nomedia.exists()) runCatching { nomedia.createNewFile() }
        return if (stateDir.exists() && stateDir.canWrite()) stateDir.absolutePath else null
    }

    private fun persistentPrivateVaultRoot(): File? {
        val base = persistentVaultBaseDir() ?: return null
        val mediaDir = File(base, "media")
        if (!mediaDir.exists()) mediaDir.mkdirs()
        val nomedia = File(mediaDir, ".nomedia")
        if (!nomedia.exists()) runCatching { nomedia.createNewFile() }
        return if (mediaDir.exists() && mediaDir.canWrite()) mediaDir else null
    }

    private fun legacyPrivateVaultRoot(): File {
        val base = context.getExternalFilesDir(null) ?: context.filesDir
        val root = File(base, "private_vault")
        if (!root.exists()) root.mkdirs()
        val nomedia = File(root, ".nomedia")
        if (!nomedia.exists()) runCatching { nomedia.createNewFile() }
        return root
    }

    private fun privateVaultRoot(): File {
        return persistentPrivateVaultRoot() ?: legacyPrivateVaultRoot()
    }

    private fun allPrivateVaultRoots(): List<File> {
        val roots = mutableListOf<File>()
        persistentPrivateVaultRoot()?.let { roots.add(it) }
        val legacy = legacyPrivateVaultRoot()
        if (roots.none { it.absolutePath == legacy.absolutePath }) {
            roots.add(legacy)
        }
        return roots
    }

    /**
     * Migrates any files still sitting in the old app-private directory
     * (`Android/data/.../files/private_vault`) into the uninstall-proof
     * `Documents/.all_download_vault/media/` directory.
     */
    fun migrateLegacyPrivateVault(onDone: (Int) -> Unit) {
        scope.launch {
            val persistent = persistentPrivateVaultRoot()
            if (persistent == null) {
                postToMain { onDone(0) }
                return@launch
            }
            val legacy = legacyPrivateVaultRoot()
            if (!legacy.exists() || legacy.canonicalPath == persistent.canonicalPath) {
                postToMain { onDone(0) }
                return@launch
            }

            var movedCount = 0
            runCatching {
                legacy.walkTopDown()
                    .filter { it.isFile && !it.name.startsWith(".") && it.length() > 0L }
                    .forEach { src ->
                        runCatching {
                            val relPath = src.relativeTo(legacy).path
                            val dst = File(persistent, relPath)
                            dst.parentFile?.mkdirs()
                            val alreadyPresent = dst.exists() && dst.isFile && dst.length() == src.length()
                            if (!alreadyPresent) {
                                FileInputStream(src).use { input ->
                                    FileOutputStream(dst).use { output ->
                                        input.copyTo(output, bufferSize = 64 * 1024)
                                    }
                                }
                                runCatching { dst.setLastModified(src.lastModified()) }
                            }
                            if (dst.exists() && dst.length() > 0L) {
                                if (src.delete()) {
                                    cleanupEmptyPrivateDirs(src)
                                    movedCount++
                                }
                            }
                        }
                    }
            }
            postToMain { onDone(movedCount) }
        }
    }

    private fun cleanupEmptyPrivateDirs(deletedFile: File) {
        runCatching {
            val roots = allPrivateVaultRoots().mapNotNull { runCatching { it.canonicalFile }.getOrNull() }
            var current = deletedFile.parentFile?.canonicalFile
            while (current != null) {
                val matchedRoot = roots.firstOrNull { root ->
                    current != root && current.path.startsWith(root.path)
                } ?: break
                val children = current.listFiles()?.filter { it.name != ".nomedia" }
                if (children.isNullOrEmpty()) {
                    current.deleteRecursively()
                    current = current.parentFile?.canonicalFile
                    if (current == matchedRoot) break
                } else {
                    break
                }
            }
        }
    }

    private fun exportFileToPrivateVault(
        sourceFile: File,
        requestedName: String,
        mimeType: String,
        platformFolder: String,
        creatorFolder: String,
        albumFolder: String?,
    ): Map<String, Any?> {
        val cleanName = sanitizeFileName(requestedName)
        val safePlatform = sanitizeFolderSegment(platformFolder, "Pixiv")
        val safeCreator = sanitizeFolderSegment(creatorFolder, "Umum")
        val safeAlbum = albumFolder?.takeIf { it.isNotBlank() }?.let {
            sanitizeFolderSegment(it, "")
        }.orEmpty()

        val vault = privateVaultRoot()
        val targetDir = if (safeAlbum.isNotEmpty()) {
            File(File(File(vault, safePlatform), safeCreator), safeAlbum)
        } else {
            File(File(vault, safePlatform), safeCreator)
        }
        targetDir.mkdirs()

        val destFile = File(targetDir, cleanName)
        val folderLabel = if (safeAlbum.isNotEmpty()) {
            "Privat/$safePlatform/$safeCreator/$safeAlbum"
        } else {
            "Privat/$safePlatform/$safeCreator"
        }

        // Skip if identical file already exists — never create "file (1)" duplicates!
        if (destFile.exists() && destFile.isFile && destFile.length() > 0L) {
            return mapOf(
                "savedPath" to destFile.absolutePath,
                "contentUri" to "",
                "fileName" to destFile.name,
                "fileSize" to destFile.length(),
                "mimeType" to mimeType,
                "folderLabel" to folderLabel,
                "platformFolder" to safePlatform,
                "creatorFolder" to safeCreator,
                "albumFolder" to safeAlbum,
                "isPrivate" to true,
                "skipped" to true,
            )
        }

        FileInputStream(sourceFile).use { input ->
            FileOutputStream(destFile).use { output ->
                input.copyTo(output, bufferSize = 64 * 1024)
            }
        }
        val nowMs = System.currentTimeMillis()
        runCatching { destFile.setLastModified(nowMs) }

        return mapOf(
            "savedPath" to destFile.absolutePath,
            "contentUri" to "",
            "fileName" to destFile.name,
            "fileSize" to destFile.length(),
            "mimeType" to mimeType,
            "folderLabel" to folderLabel,
            "platformFolder" to safePlatform,
            "creatorFolder" to safeCreator,
            "albumFolder" to safeAlbum,
            "isPrivate" to true,
            "skipped" to false,
        )
    }

    /**
     * Checks asynchronously whether the target file already exists in Private Vault
     * or Public MediaStore so downloads can be skipped cleanly before fetching bytes
     * (never overwriting or producing `(1)` duplicate files).
     */
    fun findExistingFile(
        fileName: String,
        mimeType: String?,
        platformFolder: String,
        creatorFolder: String,
        albumFolder: String? = null,
        checkPrivateVault: Boolean = true,
        onResult: (Map<String, Any?>?) -> Unit,
    ) {
        scope.launch {
            val found = runCatching {
                findExistingFileSync(
                    requestedName = fileName,
                    mimeType = mimeType,
                    platformFolder = platformFolder,
                    creatorFolder = creatorFolder,
                    albumFolder = albumFolder,
                    checkPrivateVault = checkPrivateVault,
                )
            }.getOrNull()
            postToMain { onResult(found) }
        }
    }

    private fun findExistingFileSync(
        requestedName: String,
        mimeType: String?,
        platformFolder: String,
        creatorFolder: String,
        albumFolder: String?,
        checkPrivateVault: Boolean,
    ): Map<String, Any?>? {
        val cleanName = sanitizeFileName(requestedName)
        val resolvedMime = mimeType?.takeIf { it.isNotBlank() } ?: detectMimeType(cleanName)
        val safePlatform = sanitizeFolderSegment(platformFolder, "Lainnya")
        val safeCreator = sanitizeFolderSegment(creatorFolder, "Umum")
        val safeAlbum = albumFolder?.takeIf { it.isNotBlank() }?.let {
            sanitizeFolderSegment(it, "")
        }.orEmpty()

        // 1. Check ALL Private Vault roots (uninstall-proof Documents/.all_download_vault/media + legacy app-private)
        if (checkPrivateVault) {
            for (vault in allPrivateVaultRoots()) {
                val candidateDirs = buildList {
                    if (safeAlbum.isNotEmpty()) {
                        add(File(File(File(vault, safePlatform), safeCreator), safeAlbum) to "Privat/$safePlatform/$safeCreator/$safeAlbum")
                    }
                    add(File(File(vault, safePlatform), safeCreator) to "Privat/$safePlatform/$safeCreator")
                }
                for ((dir, label) in candidateDirs) {
                    val f = File(dir, cleanName)
                    if (f.exists() && f.isFile && f.length() > 0L) {
                        return mapOf(
                            "savedPath" to f.absolutePath,
                            "contentUri" to "",
                            "fileName" to f.name,
                            "fileSize" to f.length(),
                            "mimeType" to resolvedMime,
                            "folderLabel" to label,
                            "platformFolder" to safePlatform,
                            "creatorFolder" to safeCreator,
                            "albumFolder" to safeAlbum,
                            "isPrivate" to true,
                            "skipped" to true,
                        )
                    }
                }
            }
        }

        // 2. Check Public Storage (both with album subfolder and legacy flat creator folder)
        val existingPublic = findExistingPublicFile(
            cleanName = cleanName,
            mimeType = resolvedMime,
            safePlatform = safePlatform,
            safeCreator = safeCreator,
            safeAlbum = safeAlbum,
        )
        if (existingPublic != null) return existingPublic

        if (safeAlbum.isNotEmpty()) {
            val existingFlatPublic = findExistingPublicFile(
                cleanName = cleanName,
                mimeType = resolvedMime,
                safePlatform = safePlatform,
                safeCreator = safeCreator,
                safeAlbum = "",
            )
            if (existingFlatPublic != null) return existingFlatPublic
        }

        return null
    }

    private fun findExistingPublicFile(
        cleanName: String,
        mimeType: String,
        safePlatform: String,
        safeCreator: String,
        safeAlbum: String,
    ): Map<String, Any?>? {
        val subFolder = if (safeAlbum.isNotEmpty()) {
            "all_download/$safePlatform/$safeCreator/$safeAlbum"
        } else {
            "all_download/$safePlatform/$safeCreator"
        }
        val isVideo = mimeType.startsWith("video/", ignoreCase = true)
        val isImage = mimeType.startsWith("image/", ignoreCase = true)
        val isAudio = mimeType.startsWith("audio/", ignoreCase = true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val targets = when {
                isVideo -> listOf(
                    Triple(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "${Environment.DIRECTORY_PICTURES}/$subFolder/", "Pictures/$subFolder"),
                    Triple(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "${Environment.DIRECTORY_MOVIES}/$subFolder/", "Movies/$subFolder"),
                    Triple(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "${Environment.DIRECTORY_DCIM}/$subFolder/", "DCIM/$subFolder"),
                )
                isImage -> listOf(
                    Triple(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "${Environment.DIRECTORY_PICTURES}/$subFolder/", "Pictures/$subFolder"),
                    Triple(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "${Environment.DIRECTORY_DCIM}/$subFolder/", "DCIM/$subFolder"),
                )
                isAudio -> listOf(
                    Triple(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, "${Environment.DIRECTORY_MUSIC}/$subFolder/", "Music/$subFolder"),
                )
                else -> listOf(
                    Triple(MediaStore.Downloads.EXTERNAL_CONTENT_URI, "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/", "Download/$subFolder"),
                )
            }

            @Suppress("DEPRECATION")
            val projection = arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.DATA,
            )

            for ((collectionUri, relWithSlash, folderLabel) in targets) {
                val relNoSlash = relWithSlash.trimEnd('/')
                val selection = "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND (${MediaStore.MediaColumns.RELATIVE_PATH} = ? OR ${MediaStore.MediaColumns.RELATIVE_PATH} = ?)"
                val args = arrayOf(cleanName, relWithSlash, relNoSlash)

                val found = runCatching {
                    resolver.query(collectionUri, projection, selection, args, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID))
                            val name = cursor.getString(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)) ?: cleanName
                            val size = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE))
                            @Suppress("DEPRECATION")
                            val dataIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                            val dataPath = if (dataIdx >= 0) cursor.getString(dataIdx) else null
                            val uri = ContentUris.withAppendedId(collectionUri, id)

                            val reallyExists = (size > 0L) && (
                                (!dataPath.isNullOrBlank() && File(dataPath).exists()) ||
                                    runCatching {
                                        resolver.openAssetFileDescriptor(uri, "r")?.use { true } ?: false
                                    }.getOrDefault(false)
                                )
                            if (reallyExists) {
                                mapOf(
                                    "savedPath" to (dataPath ?: "/storage/emulated/0/$folderLabel/$name"),
                                    "contentUri" to uri.toString(),
                                    "fileName" to name,
                                    "fileSize" to size,
                                    "mimeType" to mimeType,
                                    "folderLabel" to folderLabel,
                                    "platformFolder" to safePlatform,
                                    "creatorFolder" to safeCreator,
                                    "albumFolder" to safeAlbum,
                                    "isPrivate" to false,
                                    "skipped" to true,
                                )
                            } else {
                                null
                            }
                        } else {
                            null
                        }
                    }
                }.getOrNull()
                if (found != null) return found
            }
            return null
        } else {
            @Suppress("DEPRECATION")
            val rootType = when {
                isVideo || isImage -> Environment.DIRECTORY_PICTURES
                isAudio -> Environment.DIRECTORY_MUSIC
                else -> Environment.DIRECTORY_DOWNLOADS
            }
            val folderLabel = when {
                isVideo || isImage -> "Pictures/$subFolder"
                isAudio -> "Music/$subFolder"
                else -> "Download/$subFolder"
            }
            @Suppress("DEPRECATION")
            val dirs = listOf(
                File(Environment.getExternalStoragePublicDirectory(rootType), subFolder),
                File(context.getExternalFilesDir(rootType), subFolder),
            )
            for (dir in dirs) {
                val f = File(dir, cleanName)
                if (f.exists() && f.isFile && f.length() > 0L) {
                    return mapOf(
                        "savedPath" to f.absolutePath,
                        "contentUri" to "",
                        "fileName" to f.name,
                        "fileSize" to f.length(),
                        "mimeType" to mimeType,
                        "folderLabel" to folderLabel,
                        "platformFolder" to safePlatform,
                        "creatorFolder" to safeCreator,
                        "albumFolder" to safeAlbum,
                        "isPrivate" to false,
                        "skipped" to true,
                    )
                }
            }
            return null
        }
    }

    /**
     * Double-locked fresh MP4 timestamp writer:
     * 1) Runs FFmpeg stream-copy (`-map 0:v? -map 0:a? -map_metadata -1 -map_chapters -1
     *    -metadata creation_time=<NOW_UTC> -metadata:s:v creation_time=<NOW_UTC>
     *    -metadata:s:a creation_time=<NOW_UTC> -c copy -movflags +faststart`) to wipe ALL
     *    embedded YouTube/upload dates & optimize for WhatsApp.
     * 2) Runs pure-Kotlin [Mp4TimestampPatcher.patchToNow] directly on the output MP4 binary
     *    to guarantee every `mvhd`, `tkhd`, and `mdhd` box holds RIGHT NOW even if FFmpeg skipped!
     */
    private fun stampFreshVideoMetadata(inputFile: File, workDir: File): File {
        val ext = inputFile.extension.lowercase(Locale.US)
        var resultFile = inputFile

        if (ffmpegReady && (ext == "mp4" || ext == "m4v" || ext == "mov" || ext == "mkv" || ext == "webm")) {
            val remuxed = tryFfmpegFreshRemux(inputFile, workDir)
            if (remuxed != null) {
                resultFile = remuxed
            }
        }

        // Always enforce MP4 binary box timestamps directly in pure Kotlin as lock #2!
        Mp4TimestampPatcher.patchToNow(resultFile)
        return resultFile
    }

    private fun tryFfmpegFreshRemux(inputFile: File, workDir: File): File? {
        return try {
            ensureCppSharedLibCopied()
            val nativeLibDir = File(context.applicationInfo.nativeLibraryDir)
            val ffmpegBin = File(nativeLibDir, "libffmpeg.so")
            if (!ffmpegBin.exists()) return null

            val isAlreadyMp4Like = inputFile.extension.lowercase(Locale.US) in setOf("mp4", "m4v", "mov")
            val outExt = if (isAlreadyMp4Like) "mp4" else inputFile.extension.lowercase(Locale.US)
            val outFile = File(workDir, "fresh_${System.currentTimeMillis()}.$outExt")

            val isoFmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
            val nowIso = isoFmt.format(Date())

            val cmd = mutableListOf(
                ffmpegBin.absolutePath,
                "-y",
                "-i",
                inputFile.absolutePath,
                "-map",
                "0:v?",
                "-map",
                "0:a?",
                "-map_metadata",
                "-1",
                "-map_chapters",
                "-1",
                "-metadata",
                "creation_time=$nowIso",
                "-metadata:s:v",
                "creation_time=$nowIso",
                "-metadata:s:a",
                "creation_time=$nowIso",
                "-c",
                "copy",
            )
            if (outExt == "mp4") {
                cmd.add("-movflags")
                cmd.add("+faststart")
            }
            cmd.add(outFile.absolutePath)

            val pb = ProcessBuilder(cmd)
            pb.redirectErrorStream(true)
            val existingLd = pb.environment()["LD_LIBRARY_PATH"].orEmpty()
            pb.environment()["LD_LIBRARY_PATH"] =
                buildFfmpegLdLibraryPath(nativeLibDir, existingLd)

            val proc = pb.start()
            val logBuf = StringBuilder()
            val drainThread = Thread {
                runCatching {
                    proc.inputStream.bufferedReader().use { r ->
                        logBuf.append(r.readText().takeLast(500))
                    }
                }
            }
            drainThread.start()
            val finished = proc.waitFor(25, TimeUnit.SECONDS)
            if (!finished) {
                proc.destroyForcibly()
                runCatching { outFile.delete() }
                return null
            }
            drainThread.join(1500)

            if (proc.exitValue() == 0 && outFile.exists() && outFile.length() > 1024L) {
                outFile
            } else {
                Log.w(TAG, "FFmpeg fresh remux exit=${proc.exitValue()}: $logBuf")
                runCatching { outFile.delete() }
                null
            }
        } catch (t: Throwable) {
            Log.w(TAG, "tryFfmpegFreshRemux failed", t)
            null
        }
    }

    private fun exportFileToPublicStorage(
        sourceFile: File,
        requestedName: String,
        mimeType: String,
        platformFolder: String,
        creatorFolder: String,
        albumFolder: String? = null,
    ): Map<String, Any?> {
        val cleanName = sanitizeFileName(requestedName)
        val safePlatform = sanitizeFolderSegment(platformFolder, "Lainnya")
        val safeCreator = sanitizeFolderSegment(creatorFolder, "Umum")
        val safeAlbum = albumFolder?.takeIf { it.isNotBlank() }?.let {
            sanitizeFolderSegment(it, "")
        }.orEmpty()
        val subFolder = if (safeAlbum.isNotEmpty()) {
            "all_download/$safePlatform/$safeCreator/$safeAlbum"
        } else {
            "all_download/$safePlatform/$safeCreator"
        }

        val fileSize = sourceFile.length()
        val nowMs = System.currentTimeMillis()
        val nowSec = nowMs / 1000L
        runCatching { sourceFile.setLastModified(nowMs) }

        val isVideo = mimeType.startsWith("video/", ignoreCase = true)
        val isImage = mimeType.startsWith("image/", ignoreCase = true)
        val isAudio = mimeType.startsWith("audio/", ignoreCase = true)

        // Never overwrite or create "(1)" duplicate copies when the exact file already exists!
        val existingPublic = findExistingPublicFile(
            cleanName = cleanName,
            mimeType = mimeType,
            safePlatform = safePlatform,
            safeCreator = safeCreator,
            safeAlbum = safeAlbum,
        )
        if (existingPublic != null) {
            return existingPublic
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver

            val targets = when {
                isVideo -> listOf(
                    Triple(
                        MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                        "${Environment.DIRECTORY_PICTURES}/$subFolder/",
                        "Pictures/$subFolder",
                    ),
                    Triple(
                        MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                        "${Environment.DIRECTORY_MOVIES}/$subFolder/",
                        "Movies/$subFolder",
                    ),
                    Triple(
                        MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                        "${Environment.DIRECTORY_DCIM}/$subFolder/",
                        "DCIM/$subFolder",
                    ),
                )
                isImage -> listOf(
                    Triple(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                        "${Environment.DIRECTORY_PICTURES}/$subFolder/",
                        "Pictures/$subFolder",
                    ),
                    Triple(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                        "${Environment.DIRECTORY_DCIM}/$subFolder/",
                        "DCIM/$subFolder",
                    ),
                )
                isAudio -> listOf(
                    Triple(
                        MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                        "${Environment.DIRECTORY_MUSIC}/$subFolder/",
                        "Music/$subFolder",
                    ),
                )
                else -> listOf(
                    Triple(
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                        "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/",
                        "Download/$subFolder",
                    ),
                )
            }

            var insertedUri: Uri? = null
            var chosenFolderLabel = "Pictures/$subFolder"
            var lastInsertError: Throwable? = null

            for ((collectionUri, relativePath, folderLabel) in targets) {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, cleanName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                    put(MediaStore.MediaColumns.DATE_ADDED, nowSec)
                    put(MediaStore.MediaColumns.DATE_MODIFIED, nowSec)
                    if (isVideo || isImage) {
                        put(MediaStore.MediaColumns.DATE_TAKEN, nowMs)
                    }
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                try {
                    val uri = resolver.insert(collectionUri, values)
                    if (uri != null) {
                        insertedUri = uri
                        chosenFolderLabel = folderLabel
                        break
                    }
                } catch (t: Throwable) {
                    lastInsertError = t
                    Log.w(TAG, "MediaStore insert failed for $relativePath, trying fallback", t)
                }
            }

            val uri = insertedUri
                ?: throw (lastInsertError ?: IllegalStateException("Gagal membuat entri MediaStore di Galeri."))

            try {
                resolver.openOutputStream(uri)?.use { out ->
                    FileInputStream(sourceFile).use { input ->
                        input.copyTo(out, bufferSize = 64 * 1024)
                    }
                } ?: throw IllegalStateException("Gagal membuka stream output MediaStore.")

                val finishMs = System.currentTimeMillis()
                val finishSec = finishMs / 1000L

                val doneValues = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                    put(MediaStore.MediaColumns.DATE_ADDED, finishSec)
                    put(MediaStore.MediaColumns.DATE_MODIFIED, finishSec)
                    if (isVideo || isImage) {
                        put(MediaStore.MediaColumns.DATE_TAKEN, finishMs)
                    }
                }
                resolver.update(uri, doneValues, null, null)

                var finalDisplayName = cleanName
                var realFilePath: String? = null
                @Suppress("DEPRECATION")
                val projection = arrayOf(
                    MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaStore.MediaColumns.DATA,
                )
                runCatching {
                    resolver.query(uri, projection, null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val nameIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                            if (nameIdx >= 0) {
                                finalDisplayName = cursor.getString(nameIdx) ?: cleanName
                            }
                            @Suppress("DEPRECATION")
                            val dataIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                            if (dataIdx >= 0) {
                                realFilePath = cursor.getString(dataIdx)
                            }
                        }
                    }
                }

                runCatching {
                    if (!realFilePath.isNullOrBlank()) {
                        val f = File(realFilePath!!)
                        if (f.exists()) f.setLastModified(finishMs)
                    }
                }

                runCatching {
                    val refreshNowMs = System.currentTimeMillis()
                    val refreshNowSec = refreshNowMs / 1000L
                    val refreshValues = ContentValues().apply {
                        put(MediaStore.MediaColumns.DATE_MODIFIED, refreshNowSec)
                        if (isVideo || isImage) {
                            put(MediaStore.MediaColumns.DATE_TAKEN, refreshNowMs)
                        }
                    }
                    resolver.update(uri, refreshValues, null, null)
                }

                // On Android 10+, MediaStore IS_PENDING=0 already indexes images instantaneously.
                // Run explicit MediaScanner only for video/audio (to broadcast fresh MP4 mvhd timestamps)
                // so bulk 100-photo downloads (e.g. Pixiv) stay super fast & never flood Binder IPC.
                if (!isImage && !realFilePath.isNullOrBlank()) {
                    runCatching {
                        MediaScannerConnection.scanFile(
                            context,
                            arrayOf(realFilePath!!),
                            arrayOf(mimeType),
                            null,
                        )
                    }
                }

                return mapOf(
                    "savedPath" to (realFilePath ?: "/storage/emulated/0/$chosenFolderLabel/$finalDisplayName"),
                    "contentUri" to uri.toString(),
                    "fileName" to finalDisplayName,
                    "fileSize" to fileSize,
                    "mimeType" to mimeType,
                    "folderLabel" to chosenFolderLabel,
                    "platformFolder" to safePlatform,
                    "creatorFolder" to safeCreator,
                    "albumFolder" to safeAlbum,
                    "isPrivate" to false,
                    "skipped" to false,
                )
            } catch (t: Throwable) {
                runCatching { resolver.delete(uri, null, null) }
                throw t
            }
        } else {
            @Suppress("DEPRECATION")
            val rootType = when {
                isVideo || isImage -> Environment.DIRECTORY_PICTURES
                isAudio -> Environment.DIRECTORY_MUSIC
                else -> Environment.DIRECTORY_DOWNLOADS
            }
            val folderLabel = when {
                isVideo || isImage -> "Pictures/$subFolder"
                isAudio -> "Music/$subFolder"
                else -> "Download/$subFolder"
            }
            @Suppress("DEPRECATION")
            val publicBase = Environment.getExternalStoragePublicDirectory(rootType)
            val targetDir = File(publicBase, subFolder)
            val dirReady = (targetDir.exists() || targetDir.mkdirs()) && targetDir.canWrite()
            val finalDir = if (dirReady) {
                targetDir
            } else {
                File(context.getExternalFilesDir(rootType), subFolder).apply { mkdirs() }
            }

            val destFile = File(finalDir, cleanName)
            if (destFile.exists() && destFile.isFile && destFile.length() > 0L) {
                return mapOf(
                    "savedPath" to destFile.absolutePath,
                    "contentUri" to "",
                    "fileName" to destFile.name,
                    "fileSize" to destFile.length(),
                    "mimeType" to mimeType,
                    "folderLabel" to folderLabel,
                    "platformFolder" to safePlatform,
                    "creatorFolder" to safeCreator,
                    "albumFolder" to safeAlbum,
                    "isPrivate" to false,
                    "skipped" to true,
                )
            }
            FileInputStream(sourceFile).use { input ->
                FileOutputStream(destFile).use { output ->
                    input.copyTo(output, bufferSize = 64 * 1024)
                }
            }
            val finishMs = System.currentTimeMillis()
            val finishSec = finishMs / 1000L
            runCatching { destFile.setLastModified(finishMs) }

            MediaScannerConnection.scanFile(
                context,
                arrayOf(destFile.absolutePath),
                arrayOf(mimeType),
            ) { _, scannedUri ->
                if (scannedUri != null) {
                    runCatching {
                        val refreshValues = ContentValues().apply {
                            put(MediaStore.MediaColumns.DATE_MODIFIED, finishSec)
                            if (isVideo || isImage) {
                                put(MediaStore.MediaColumns.DATE_TAKEN, finishMs)
                            }
                        }
                        context.contentResolver.update(scannedUri, refreshValues, null, null)
                    }
                }
            }

            return mapOf(
                "savedPath" to destFile.absolutePath,
                "contentUri" to "",
                "fileName" to destFile.name,
                "fileSize" to destFile.length(),
                "mimeType" to mimeType,
                "folderLabel" to folderLabel,
                "platformFolder" to safePlatform,
                "creatorFolder" to safeCreator,
                "albumFolder" to safeAlbum,
                "isPrivate" to false,
            )
        }
    }

    /**
     * Scans Android MediaStore for all files saved inside `all_download/<Platform>/<Username>/`
     * so the in-app File Explorer tab always reflects the real device storage structure.
     */
    fun listManagedFiles(
        onSuccess: (List<Map<String, Any?>>) -> Unit,
        onError: (String, String) -> Unit,
    ) {
        scope.launch {
            try {
                val results = mutableListOf<Map<String, Any?>>()
                val seenPaths = HashSet<String>()

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val resolver = context.contentResolver
                    val collections = listOf(
                        MediaStore.Video.Media.EXTERNAL_CONTENT_URI to "video",
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI to "image",
                        MediaStore.Audio.Media.EXTERNAL_CONTENT_URI to "audio",
                    )

                    @Suppress("DEPRECATION")
                    val projection = arrayOf(
                        MediaStore.MediaColumns._ID,
                        MediaStore.MediaColumns.DISPLAY_NAME,
                        MediaStore.MediaColumns.MIME_TYPE,
                        MediaStore.MediaColumns.SIZE,
                        MediaStore.MediaColumns.DATE_MODIFIED,
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        MediaStore.MediaColumns.DATA,
                    )

                    val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
                    val selectionArgs = arrayOf("%all_download%")
                    val sortOrder = "${MediaStore.MediaColumns.DATE_MODIFIED} DESC"

                    for ((collectionUri, mediaKind) in collections) {
                        runCatching {
                            resolver.query(collectionUri, projection, selection, selectionArgs, sortOrder)?.use { cursor ->
                                val idIdx = cursor.getColumnIndex(MediaStore.MediaColumns._ID)
                                val nameIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                                val mimeIdx = cursor.getColumnIndex(MediaStore.MediaColumns.MIME_TYPE)
                                val sizeIdx = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
                                val modIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_MODIFIED)
                                val relIdx = cursor.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
                                @Suppress("DEPRECATION")
                                val dataIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)

                                while (cursor.moveToNext()) {
                                    val id = if (idIdx >= 0) cursor.getLong(idIdx) else continue
                                    val name = if (nameIdx >= 0) cursor.getString(nameIdx) ?: continue else continue
                                    val mime = if (mimeIdx >= 0) cursor.getString(mimeIdx) ?: detectMimeType(name) else detectMimeType(name)
                                    val size = if (sizeIdx >= 0) cursor.getLong(sizeIdx) else 0L
                                    val modSec = if (modIdx >= 0) cursor.getLong(modIdx) else 0L
                                    val relPath = if (relIdx >= 0) cursor.getString(relIdx) ?: "" else ""
                                    val dataPath = if (dataIdx >= 0) cursor.getString(dataIdx) ?: "" else ""
                                    if (relPath.contains(".all_download_vault", ignoreCase = true) ||
                                        dataPath.contains(".all_download_vault", ignoreCase = true)
                                    ) {
                                        continue
                                    }

                                    val contentUri = ContentUris.withAppendedId(collectionUri, id).toString()
                                    val dedupKey = dataPath.ifBlank { contentUri }
                                    if (!seenPaths.add(dedupKey)) continue

                                    val (platformName, creatorName, albumName) = parseFolderHierarchy(relPath)
                                    results.add(
                                        mapOf(
                                            "fileName" to name,
                                            "mimeType" to mime,
                                            "mediaKind" to mediaKind,
                                            "fileSize" to size,
                                            "modifiedMs" to (modSec * 1000L),
                                            "relativePath" to relPath.trimEnd('/'),
                                            "savedPath" to dataPath,
                                            "contentUri" to contentUri,
                                            "platformFolder" to platformName,
                                            "creatorFolder" to creatorName,
                                            "albumFolder" to albumName,
                                            "isPrivate" to false,
                                        ),
                                    )
                                }
                            }
                        }
                    }
                } else {
                    @Suppress("DEPRECATION")
                    val roots = listOf(
                        File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "all_download"),
                        File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), "all_download"),
                        File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM), "all_download"),
                        File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC), "all_download"),
                        File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "all_download"),
                    )
                    for (root in roots) {
                        if (!root.exists()) continue
                        root.walkTopDown().filter { it.isFile && it.length() > 0 }.forEach { f ->
                            if (!seenPaths.add(f.absolutePath)) return@forEach
                            val mime = detectMimeType(f.name)
                            val kind = when {
                                mime.startsWith("video/") -> "video"
                                mime.startsWith("audio/") -> "audio"
                                mime.startsWith("image/") -> "image"
                                else -> "video"
                            }
                            val rel = f.parentFile?.absolutePath.orEmpty()
                            val (platformName, creatorName, albumName) = parseFolderHierarchy(rel)
                            results.add(
                                mapOf(
                                    "fileName" to f.name,
                                    "mimeType" to mime,
                                    "mediaKind" to kind,
                                    "fileSize" to f.length(),
                                    "modifiedMs" to f.lastModified(),
                                    "relativePath" to rel,
                                    "savedPath" to f.absolutePath,
                                    "contentUri" to "",
                                    "platformFolder" to platformName,
                                    "creatorFolder" to creatorName,
                                    "albumFolder" to albumName,
                                    "isPrivate" to false,
                                ),
                            )
                        }
                    }
                }

                // Also scan Private Vault roots (uninstall-proof Documents/.all_download_vault/media + legacy fallback)
                val seenPrivateLogical = HashSet<String>()
                for (vault in allPrivateVaultRoots()) {
                    runCatching {
                        if (vault.exists()) {
                            vault.walkTopDown()
                                .onEnter { it == vault || !it.name.startsWith(".") }
                                .filter { it.isFile && !it.name.startsWith(".") && it.length() > 0 }
                                .forEach { f ->
                                    if (!seenPaths.add(f.absolutePath)) return@forEach
                                    val mime = detectMimeType(f.name)
                                    val kind = when {
                                        mime.startsWith("video/") -> "video"
                                        mime.startsWith("audio/") -> "audio"
                                        mime.startsWith("image/") -> "image"
                                        else -> "image"
                                    }
                                    val relDir = f.parentFile?.relativeTo(vault)?.path?.replace('\\', '/').orEmpty()
                                    val parts = relDir.split('/').filter { it.isNotBlank() }
                                    val platformName = parts.getOrNull(0) ?: "Pixiv"
                                    val creatorName = parts.getOrNull(1) ?: "Umum"
                                    val albumName = parts.getOrNull(2) ?: ""
                                    val logicalKey = "$platformName/$creatorName/$albumName/${f.name}".lowercase(Locale.US)
                                    if (!seenPrivateLogical.add(logicalKey)) return@forEach
                                    results.add(
                                        mapOf(
                                            "fileName" to f.name,
                                            "mimeType" to mime,
                                            "mediaKind" to kind,
                                            "fileSize" to f.length(),
                                            "modifiedMs" to f.lastModified(),
                                            "relativePath" to "Privat/$relDir",
                                            "savedPath" to f.absolutePath,
                                            "contentUri" to "",
                                            "platformFolder" to platformName,
                                            "creatorFolder" to creatorName,
                                            "albumFolder" to albumName,
                                            "isPrivate" to true,
                                        ),
                                    )
                                }
                        }
                    }
                }

                results.sortByDescending { (it["modifiedMs"] as? Long) ?: 0L }
                postToMain { onSuccess(results) }
            } catch (t: Throwable) {
                Log.e(TAG, "listManagedFiles failed", t)
                postToMain { onError("LIST_ERROR", t.message ?: "Gagal membaca folder file") }
            }
        }
    }

    private fun parseFolderHierarchy(path: String): Triple<String, String, String> {
        val normalized = path.replace('\\', '/').trim('/')
        val parts = normalized.split('/').filter { it.isNotBlank() }
        val idx = parts.indexOfFirst { it.equals("all_download", ignoreCase = true) }
        if (idx == -1) return Triple("Lainnya", "Umum", "")
        val platform = parts.getOrNull(idx + 1)?.takeIf { it.isNotBlank() } ?: "Lainnya"
        val creator = parts.getOrNull(idx + 2)?.takeIf { it.isNotBlank() } ?: "Umum"
        val album = parts.getOrNull(idx + 3)?.takeIf { it.isNotBlank() } ?: ""
        return Triple(platform, creator, album)
    }

    fun setWallpaper(
        activity: Activity,
        filePath: String?,
        contentUri: String?,
        target: String,
        cropLeft: Float? = null,
        cropTop: Float? = null,
        cropWidth: Float? = null,
        cropHeight: Float? = null,
        onSuccess: (Boolean) -> Unit,
        onError: (String, String) -> Unit,
    ) {
        scope.launch {
            try {
                val normalizedPath = filePath
                    ?.trim()
                    ?.removePrefix("file://")
                    ?.takeIf { it.isNotEmpty() }
                val normalizedUri = contentUri
                    ?.trim()
                    ?.takeIf { it.startsWith("content://") }

                fun findLocalFile(): File? {
                    if (normalizedPath != null) {
                        val f = File(normalizedPath)
                        if (f.exists() && f.isFile && f.length() > 0L && f.canRead()) {
                            return f
                        }
                    }
                    return null
                }

                fun openImageStream(): java.io.InputStream? {
                    // Try readable local file first (Private Vault / app storage / accessible external)
                    findLocalFile()?.let { f ->
                        val s = runCatching { FileInputStream(f) }.getOrNull()
                        if (s != null) return s
                    }
                    // Then try Scoped Storage contentUri (Android 10+ MediaStore)
                    if (normalizedUri != null) {
                        val s = runCatching {
                            context.contentResolver.openInputStream(Uri.parse(normalizedUri))
                        }.getOrNull()
                        if (s != null) return s
                    }
                    // Final fallback: locate by display name in MediaStore if path went stale
                    if (normalizedPath != null) {
                        val baseName = File(normalizedPath).name
                        if (baseName.isNotBlank() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val lookedUpUri = runCatching {
                                context.contentResolver.query(
                                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                                    arrayOf(MediaStore.MediaColumns._ID),
                                    "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
                                    arrayOf(baseName, "%all_download%"),
                                    "${MediaStore.MediaColumns.DATE_MODIFIED} DESC",
                                )?.use { c ->
                                    if (c.moveToFirst()) {
                                        ContentUris.withAppendedId(
                                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                                            c.getLong(0),
                                        )
                                    } else {
                                        null
                                    }
                                }
                            }.getOrNull()
                            if (lookedUpUri != null) {
                                val s = runCatching {
                                    context.contentResolver.openInputStream(lookedUpUri)
                                }.getOrNull()
                                if (s != null) return s
                            }
                        }
                    }
                    return null
                }

                fun decodeSafeBitmap(maxDimension: Int = 2560): Bitmap {
                    var decoded: Bitmap? = null

                    // 1) Try modern ImageDecoder on Android 9+ (handles JPEG, PNG, WebP, HEIF + EXIF rotation!)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        val source = runCatching {
                            val localFile = findLocalFile()
                            when {
                                localFile != null -> ImageDecoder.createSource(localFile)
                                normalizedUri != null -> ImageDecoder.createSource(
                                    context.contentResolver,
                                    Uri.parse(normalizedUri),
                                )
                                else -> null
                            }
                        }.getOrNull()
                        if (source != null) {
                            decoded = runCatching {
                                ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                                    decoder.isMutableRequired = false
                                    val w = info.size.width
                                    val h = info.size.height
                                    val longest = maxOf(w, h)
                                    if (longest > maxDimension && longest > 0) {
                                        val scale = maxDimension.toFloat() / longest.toFloat()
                                        decoder.setTargetSize(
                                            maxOf(1, (w * scale).toInt()),
                                            maxOf(1, (h * scale).toInt()),
                                        )
                                    }
                                }
                            }.getOrNull()
                        }
                    }

                    // 2) Fallback: classic BitmapFactory stream decode with safe downsampling
                    if (decoded == null) {
                        val boundsOpts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                        val boundsStream = openImageStream()
                            ?: throw IllegalArgumentException(
                                "File gambar tidak ditemukan atau tidak dapat dibaca. Coba segarkan folder lalu ulangi.",
                            )
                        boundsStream.use { BitmapFactory.decodeStream(it, null, boundsOpts) }

                        var inSample = 1
                        val w = boundsOpts.outWidth
                        val h = boundsOpts.outHeight
                        if (w > 0 && h > 0) {
                            val longest = maxOf(w, h)
                            while (longest / inSample > maxDimension) {
                                inSample *= 2
                            }
                        }

                        val decodeOpts = BitmapFactory.Options().apply {
                            inSampleSize = inSample
                            inPreferredConfig = Bitmap.Config.ARGB_8888
                        }
                        decoded = openImageStream()?.use {
                            BitmapFactory.decodeStream(it, null, decodeOpts)
                        } ?: throw IllegalStateException("Gagal mendekode gambar untuk wallpaper.")
                    }

                    var working = decoded

                    // Apply user-framed normalized crop rectangle (from in-app WallpaperCropPreviewScreen)
                    if (cropLeft != null && cropTop != null && cropWidth != null && cropHeight != null &&
                        cropWidth > 0.01f && cropHeight > 0.01f
                    ) {
                        val cl = cropLeft.coerceIn(0f, 0.99f)
                        val ct = cropTop.coerceIn(0f, 0.99f)
                        val cw = cropWidth.coerceIn(0.01f, 1f - cl)
                        val ch = cropHeight.coerceIn(0.01f, 1f - ct)

                        val x = (cl * working.width).toInt().coerceIn(0, maxOf(0, working.width - 1))
                        val y = (ct * working.height).toInt().coerceIn(0, maxOf(0, working.height - 1))
                        val w = (cw * working.width).toInt().coerceIn(1, working.width - x)
                        val h = (ch * working.height).toInt().coerceIn(1, working.height - y)

                        if (w < working.width || h < working.height || x > 0 || y > 0) {
                            val cropped = Bitmap.createBitmap(working, x, y, w, h)
                            if (cropped != working) {
                                working.recycle()
                                working = cropped
                            }
                        }
                    }

                    if (!working.hasAlpha()) return working

                    // Flatten transparent PNGs onto opaque black so system wallpaper never renders artifacts
                    val opaque = Bitmap.createBitmap(working.width, working.height, Bitmap.Config.ARGB_8888)
                    val canvas = Canvas(opaque)
                    canvas.drawColor(Color.BLACK)
                    canvas.drawBitmap(working, 0f, 0f, null)
                    working.recycle()
                    return opaque
                }

                val wm = WallpaperManager.getInstance(context)

                // Direct native WallpaperManager apply (Home / Lock / Both)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && !wm.isSetWallpaperAllowed) {
                    throw IllegalStateException("Perangkat tidak mengizinkan penggantian wallpaper saat ini.")
                }

                val bitmap = decodeSafeBitmap(maxDimension = 2560)
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        val flags = when (target.lowercase(Locale.US)) {
                            "lock" -> WallpaperManager.FLAG_LOCK
                            "both" -> WallpaperManager.FLAG_SYSTEM or WallpaperManager.FLAG_LOCK
                            else -> WallpaperManager.FLAG_SYSTEM
                        }
                        val applied = runCatching {
                            wm.setBitmap(bitmap, null, true, flags) > 0
                        }.getOrDefault(false)
                        if (!applied) {
                            // Some OEM ROMs (e.g. certain MIUI/HyperOS builds) restrict FLAG_LOCK; fallback safely
                            wm.setBitmap(bitmap)
                        }
                    } else {
                        wm.setBitmap(bitmap)
                    }
                } finally {
                    bitmap.recycle()
                }

                postToMain { onSuccess(true) }
            } catch (t: Throwable) {
                Log.e(TAG, "setWallpaper failed", t)
                postToMain { onError("WALLPAPER_ERROR", t.message ?: "Gagal memasang wallpaper") }
            }
        }
    }

    fun openFile(filePath: String?, contentUri: String?, mimeType: String?): Boolean {
        val resolvedUri = resolveReadableUri(filePath, contentUri) ?: return false
        val resolvedMime = mimeType?.takeIf { it.isNotBlank() }
            ?: detectMimeType(filePath ?: contentUri ?: "")

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(resolvedUri, resolvedMime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return runCatching {
            context.startActivity(intent)
            true
        }.getOrDefault(false)
    }

    fun shareFile(filePath: String?, contentUri: String?, mimeType: String?, title: String?): Boolean {
        val resolvedUri = resolveReadableUri(filePath, contentUri) ?: return false
        val resolvedMime = mimeType?.takeIf { it.isNotBlank() }
            ?: detectMimeType(filePath ?: contentUri ?: "")

        val sendIntent = Intent(Intent.ACTION_SEND).apply {
            type = resolvedMime
            putExtra(Intent.EXTRA_STREAM, resolvedUri)
            if (!title.isNullOrBlank()) {
                putExtra(Intent.EXTRA_SUBJECT, title)
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(sendIntent, "Bagikan Media").apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return runCatching {
            context.startActivity(chooser)
            true
        }.getOrDefault(false)
    }

    fun shareMultipleFiles(items: List<Map<String, Any?>>): Boolean {
        if (items.isEmpty()) return false
        if (items.size == 1) {
            val single = items.first()
            return shareFile(
                filePath = single["filePath"]?.toString(),
                contentUri = single["contentUri"]?.toString(),
                mimeType = single["mimeType"]?.toString(),
                title = single["title"]?.toString(),
            )
        }

        val uris = ArrayList<Uri>(items.size)
        val mimeFamilies = HashSet<String>()
        var clipData: ClipData? = null

        for (item in items) {
            val filePath = item["filePath"]?.toString()
            val contentUri = item["contentUri"]?.toString()
            val resolved = resolveReadableUri(filePath, contentUri) ?: continue
            uris.add(resolved)

            val mime = item["mimeType"]?.toString()?.takeIf { it.isNotBlank() }
                ?: detectMimeType(filePath ?: contentUri ?: "")
            val family = mime.substringBefore('/').lowercase(Locale.US)
            if (family.isNotBlank()) mimeFamilies.add(family)

            if (clipData == null) {
                clipData = ClipData.newRawUri("all_download_media", resolved)
            } else {
                clipData.addItem(ClipData.Item(resolved))
            }
        }

        if (uris.isEmpty()) return false

        val combinedMime = when {
            mimeFamilies.size == 1 -> "${mimeFamilies.first()}/*"
            else -> "*/*"
        }

        val sendIntent = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            type = combinedMime
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            if (clipData != null) {
                this.clipData = clipData
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        val chooser = Intent.createChooser(sendIntent, "Bagikan ${uris.size} Media").apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return runCatching {
            context.startActivity(chooser)
            true
        }.getOrDefault(false)
    }

    fun deleteMultipleFiles(
        items: List<Map<String, Any?>>,
        onDone: (Int) -> Unit,
    ) {
        scope.launch {
            var deletedCount = 0
            for (item in items) {
                val ok = deleteFile(
                    filePath = item["filePath"]?.toString(),
                    contentUri = item["contentUri"]?.toString(),
                )
                if (ok) deletedCount++
            }
            postToMain { onDone(deletedCount) }
        }
    }

    fun deleteFileAsync(
        filePath: String?,
        contentUri: String?,
        onDone: (Boolean) -> Unit,
    ) {
        scope.launch {
            val ok = deleteFile(filePath = filePath, contentUri = contentUri)
            postToMain { onDone(ok) }
        }
    }

    fun deleteFile(filePath: String?, contentUri: String?): Boolean {
        var deleted = false
        if (!contentUri.isNullOrBlank() && contentUri.startsWith("content://")) {
            deleted = runCatching {
                context.contentResolver.delete(Uri.parse(contentUri), null, null) > 0
            }.getOrDefault(false)
        }
        if (!deleted && !filePath.isNullOrBlank()) {
            val file = File(filePath)
            if (file.exists()) {
                deleted = runCatching { file.delete() }.getOrDefault(false)
                if (deleted) {
                    cleanupEmptyPrivateDirs(file)
                }
            }
        }
        return deleted
    }

    // =========================================================================
    // RECYCLE BIN / TRASH ENGINE (.all_download_vault/.trash + fallback)
    // =========================================================================

    private val trashLock = Any()

    private fun ensureNoMediaMarker(dir: File) {
        runCatching {
            val nomedia = File(dir, ".nomedia")
            if (!nomedia.exists()) nomedia.createNewFile()
        }
    }

    private fun resolveTrashDir(): File {
        val base = persistentVaultBaseDir() ?: legacyPrivateVaultRoot()
        val dir = File(base, ".trash")
        if (!dir.exists()) dir.mkdirs()
        ensureNoMediaMarker(dir)
        return dir
    }

    private fun allTrashDirs(): List<File> {
        val out = ArrayList<File>(2)
        persistentVaultBaseDir()?.let { base ->
            val d = File(base, ".trash")
            if (d.exists()) out.add(d)
        }
        val legacy = File(legacyPrivateVaultRoot(), ".trash")
        if (legacy.exists() && out.none { it.absolutePath == legacy.absolutePath }) {
            out.add(legacy)
        }
        return out
    }

    private fun readTrashEntriesLocked(trashDir: File): MutableList<JSONObject> {
        val indexFile = File(trashDir, "trash_index_v1.json")
        if (!indexFile.exists()) return mutableListOf()
        return runCatching {
            val arr = JSONArray(indexFile.readText(Charsets.UTF_8))
            val out = ArrayList<JSONObject>(arr.length())
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                val tp = obj.optString("trashPath")
                if (tp.isNotBlank() && File(tp).exists()) {
                    out.add(obj)
                }
            }
            out
        }.getOrDefault(mutableListOf())
    }

    private fun writeTrashEntriesLocked(trashDir: File, entries: List<JSONObject>) {
        if (!trashDir.exists()) trashDir.mkdirs()
        ensureNoMediaMarker(trashDir)
        val arr = JSONArray()
        for (e in entries) arr.put(e)
        val target = File(trashDir, "trash_index_v1.json")
        val tmp = File(trashDir, "trash_index_v1.json.tmp")
        runCatching {
            tmp.writeText(arr.toString(), Charsets.UTF_8)
            if (target.exists()) target.delete()
            if (!tmp.renameTo(target)) {
                target.writeText(arr.toString(), Charsets.UTF_8)
                tmp.delete()
            }
        }
    }

    private fun jsonObjectToTrashMap(obj: JSONObject): Map<String, Any?> {
        return mapOf(
            "id" to obj.optString("id"),
            "trashPath" to obj.optString("trashPath"),
            "originalPath" to obj.optString("originalPath"),
            "fileName" to obj.optString("fileName"),
            "mimeType" to obj.optString("mimeType"),
            "mediaKind" to obj.optString("mediaKind", "image"),
            "fileSize" to obj.optLong("fileSize", 0L),
            "isPrivate" to obj.optBoolean("isPrivate", true),
            "platformFolder" to obj.optString("platformFolder", "Pixiv"),
            "creatorFolder" to obj.optString("creatorFolder", "Umum"),
            "albumFolder" to obj.optString("albumFolder", ""),
            "deletedAtMs" to obj.optLong("deletedAtMs", System.currentTimeMillis()),
        )
    }

    fun moveFilesToTrash(
        items: List<Map<String, Any?>>,
        onDone: (List<Map<String, Any?>>) -> Unit,
    ) {
        scope.launch {
            val trashedResults = ArrayList<Map<String, Any?>>(items.size)
            val trashDir = resolveTrashDir()
            val nowMs = System.currentTimeMillis()
            val newEntries = ArrayList<JSONObject>(items.size)

            for (item in items) {
                val filePath = item["filePath"]?.toString().orEmpty()
                val contentUri = item["contentUri"]?.toString().orEmpty()
                val fileName = item["fileName"]?.toString()?.takeIf { it.isNotBlank() }
                    ?: File(filePath).name.ifBlank { "media_$nowMs.jpg" }
                val mimeType = item["mimeType"]?.toString()?.takeIf { it.isNotBlank() }
                    ?: detectMimeType(fileName)
                val mediaKind = item["mediaKind"]?.toString()?.takeIf { it.isNotBlank() }
                    ?: when {
                        mimeType.startsWith("video/") -> "video"
                        mimeType.startsWith("audio/") -> "audio"
                        else -> "image"
                    }
                val isPrivate = item["isPrivate"] as? Boolean ?: true
                val platformFolder = item["platformFolder"]?.toString()?.takeIf { it.isNotBlank() } ?: "Pixiv"
                val creatorFolder = item["creatorFolder"]?.toString()?.takeIf { it.isNotBlank() } ?: "Umum"
                val albumFolder = item["albumFolder"]?.toString().orEmpty()

                val trashId = UUID.randomUUID().toString()
                val safeExt = fileName.substringAfterLast('.', "").take(8)
                val storedName = if (safeExt.isNotBlank()) "${trashId}.$safeExt" else trashId
                val destFile = File(trashDir, storedName)

                val moved = runCatching {
                    var placed = false
                    val srcFile = if (filePath.isNotBlank()) File(filePath) else null
                    // Fast path: O(1) atomic rename when file is directly accessible on same volume!
                    if (srcFile != null && srcFile.exists() && srcFile.isFile) {
                        if (srcFile.renameTo(destFile) && destFile.exists()) {
                            placed = true
                            cleanupEmptyPrivateDirs(srcFile)
                            if (contentUri.startsWith("content://")) {
                                runCatching {
                                    context.contentResolver.delete(Uri.parse(contentUri), null, null)
                                }
                            }
                        } else {
                            srcFile.copyTo(destFile, overwrite = true)
                            if (destFile.exists() && destFile.length() > 0L) {
                                placed = true
                                deleteFile(filePath, contentUri)
                            }
                        }
                    }
                    if (!placed && contentUri.startsWith("content://")) {
                        context.contentResolver.openInputStream(Uri.parse(contentUri))?.use { input ->
                            FileOutputStream(destFile).use { out ->
                                input.copyTo(out, bufferSize = 64 * 1024)
                            }
                        }
                        if (destFile.exists() && destFile.length() > 0L) {
                            placed = true
                            deleteFile(filePath, contentUri)
                        }
                    }
                    placed
                }.getOrDefault(false)

                if (moved && destFile.exists()) {
                    val obj = JSONObject().apply {
                        put("id", trashId)
                        put("trashPath", destFile.absolutePath)
                        put("originalPath", filePath)
                        put("fileName", fileName)
                        put("mimeType", mimeType)
                        put("mediaKind", mediaKind)
                        put("fileSize", destFile.length())
                        put("isPrivate", isPrivate)
                        put("platformFolder", platformFolder)
                        put("creatorFolder", creatorFolder)
                        put("albumFolder", albumFolder)
                        put("deletedAtMs", nowMs)
                    }
                    newEntries.add(obj)
                    trashedResults.add(jsonObjectToTrashMap(obj))
                } else {
                    runCatching { if (destFile.exists()) destFile.delete() }
                }
            }

            if (newEntries.isNotEmpty()) {
                synchronized(trashLock) {
                    val existing = readTrashEntriesLocked(trashDir)
                    existing.addAll(0, newEntries)
                    writeTrashEntriesLocked(trashDir, existing)
                }
            }
            postToMain { onDone(trashedResults) }
        }
    }

    fun listTrashItems(onDone: (List<Map<String, Any?>>) -> Unit) {
        scope.launch {
            val all = ArrayList<Map<String, Any?>>()
            synchronized(trashLock) {
                for (dir in allTrashDirs()) {
                    val entries = readTrashEntriesLocked(dir)
                    writeTrashEntriesLocked(dir, entries)
                    for (e in entries) {
                        all.add(jsonObjectToTrashMap(e))
                    }
                }
            }
            all.sortByDescending { (it["deletedAtMs"] as? Long) ?: 0L }
            postToMain { onDone(all) }
        }
    }

    fun restoreTrashItems(ids: List<String>, onDone: (Int) -> Unit) {
        scope.launch {
            val idSet = ids.toHashSet()
            if (idSet.isEmpty()) {
                postToMain { onDone(0) }
                return@launch
            }
            var restored = 0
            synchronized(trashLock) {
                for (dir in allTrashDirs()) {
                    val entries = readTrashEntriesLocked(dir)
                    val remaining = ArrayList<JSONObject>(entries.size)
                    var changed = false
                    for (obj in entries) {
                        val id = obj.optString("id")
                        if (!idSet.contains(id)) {
                            remaining.add(obj)
                            continue
                        }
                        val trashFile = File(obj.optString("trashPath"))
                        if (!trashFile.exists()) {
                            changed = true
                            continue
                        }
                        val fileName = obj.optString("fileName").ifBlank { trashFile.name }
                        val mimeType = obj.optString("mimeType").ifBlank { detectMimeType(fileName) }
                        val isPrivate = obj.optBoolean("isPrivate", true)
                        val platformFolder = obj.optString("platformFolder", "Pixiv")
                        val creatorFolder = obj.optString("creatorFolder", "Umum")
                        val albumFolder = obj.optString("albumFolder").takeIf { it.isNotBlank() }

                        val ok = runCatching {
                            if (isPrivate) {
                                exportFileToPrivateVault(
                                    sourceFile = trashFile,
                                    requestedName = fileName,
                                    mimeType = mimeType,
                                    platformFolder = platformFolder,
                                    creatorFolder = creatorFolder,
                                    albumFolder = albumFolder,
                                )
                            } else {
                                exportFileToPublicStorage(
                                    sourceFile = trashFile,
                                    requestedName = fileName,
                                    mimeType = mimeType,
                                    platformFolder = platformFolder,
                                    creatorFolder = creatorFolder,
                                    albumFolder = albumFolder,
                                )
                            }
                            runCatching { trashFile.delete() }
                            true
                        }.getOrDefault(false)

                        if (ok) {
                            restored++
                            changed = true
                        } else {
                            remaining.add(obj)
                        }
                    }
                    if (changed) {
                        writeTrashEntriesLocked(dir, remaining)
                    }
                }
            }
            postToMain { onDone(restored) }
        }
    }

    fun deleteTrashItemsPermanently(ids: List<String>, onDone: (Int) -> Unit) {
        scope.launch {
            val idSet = ids.toHashSet()
            var deleted = 0
            synchronized(trashLock) {
                for (dir in allTrashDirs()) {
                    val entries = readTrashEntriesLocked(dir)
                    val remaining = ArrayList<JSONObject>(entries.size)
                    var changed = false
                    for (obj in entries) {
                        val id = obj.optString("id")
                        if (idSet.contains(id)) {
                            runCatching { File(obj.optString("trashPath")).delete() }
                            deleted++
                            changed = true
                        } else {
                            remaining.add(obj)
                        }
                    }
                    if (changed) {
                        writeTrashEntriesLocked(dir, remaining)
                    }
                }
            }
            postToMain { onDone(deleted) }
        }
    }

    fun emptyTrash(onDone: (Int) -> Unit) {
        scope.launch {
            var deleted = 0
            synchronized(trashLock) {
                for (dir in allTrashDirs()) {
                    val entries = readTrashEntriesLocked(dir)
                    for (obj in entries) {
                        runCatching { File(obj.optString("trashPath")).delete() }
                        deleted++
                    }
                    // Also delete any orphaned trash blobs
                    dir.listFiles()?.forEach { child ->
                        if (child.isFile && child.name != ".nomedia" && child.name != "trash_index_v1.json") {
                            runCatching { child.delete() }
                        }
                    }
                    writeTrashEntriesLocked(dir, emptyList())
                }
            }
            postToMain { onDone(deleted) }
        }
    }

    fun purgeExpiredTrash(maxAgeDays: Int, onDone: (Int) -> Unit) {
        scope.launch {
            if (maxAgeDays <= 0) {
                postToMain { onDone(0) }
                return@launch
            }
            val cutoffMs = System.currentTimeMillis() - (maxAgeDays.toLong() * 24L * 60L * 60L * 1000L)
            var purged = 0
            synchronized(trashLock) {
                for (dir in allTrashDirs()) {
                    val entries = readTrashEntriesLocked(dir)
                    val remaining = ArrayList<JSONObject>(entries.size)
                    var changed = false
                    for (obj in entries) {
                        val deletedAt = obj.optLong("deletedAtMs", System.currentTimeMillis())
                        if (deletedAt < cutoffMs) {
                            runCatching { File(obj.optString("trashPath")).delete() }
                            purged++
                            changed = true
                        } else {
                            remaining.add(obj)
                        }
                    }
                    if (changed) {
                        writeTrashEntriesLocked(dir, remaining)
                    }
                }
            }
            postToMain { onDone(purged) }
        }
    }

    /**
     * Unlocks private vault files into public MediaStore (`Pictures/all_download/<Platform>/<Creator>/<Album>/`)
     * with fresh timestamps so they immediately appear in Android Gallery and WhatsApp.
     */
    fun unlockFiles(
        items: List<Map<String, Any?>>,
        onDone: (Int) -> Unit,
    ) {
        scope.launch {
            var count = 0
            for (item in items) {
                val isPrivate = item["isPrivate"] as? Boolean ?: true
                if (!isPrivate) continue
                val filePath = item["filePath"]?.toString().orEmpty()
                if (filePath.isBlank()) continue
                val src = File(filePath)
                if (!src.exists() || !src.isFile || src.length() == 0L) continue

                val fileName = item["fileName"]?.toString()?.takeIf { it.isNotBlank() } ?: src.name
                val mimeType = item["mimeType"]?.toString()?.takeIf { it.isNotBlank() }
                    ?: detectMimeType(fileName)
                val platformFolder = item["platformFolder"]?.toString()?.takeIf { it.isNotBlank() } ?: "Pixiv"
                val creatorFolder = item["creatorFolder"]?.toString()?.takeIf { it.isNotBlank() } ?: "Umum"
                val albumFolder = item["albumFolder"]?.toString()?.takeIf { it.isNotBlank() }

                val ok = runCatching {
                    exportFileToPublicStorage(
                        sourceFile = src,
                        requestedName = fileName,
                        mimeType = mimeType,
                        platformFolder = platformFolder,
                        creatorFolder = creatorFolder,
                        albumFolder = albumFolder,
                    )
                    src.delete()
                    cleanupEmptyPrivateDirs(src)
                    true
                }.getOrDefault(false)
                if (ok) count++
            }
            postToMain { onDone(count) }
        }
    }

    /**
     * Locks public Gallery files back into the app-private vault and removes them from
     * public MediaStore so they are hidden from Gallery & WhatsApp again.
     */
    fun lockFiles(
        items: List<Map<String, Any?>>,
        onDone: (Int) -> Unit,
    ) {
        scope.launch {
            var count = 0
            for (item in items) {
                val isPrivate = item["isPrivate"] as? Boolean ?: false
                if (isPrivate) continue

                val filePath = item["filePath"]?.toString().orEmpty()
                val contentUri = item["contentUri"]?.toString().orEmpty()
                val fileName = item["fileName"]?.toString()?.takeIf { it.isNotBlank() }
                    ?: File(filePath).name.ifBlank { "media_${System.currentTimeMillis()}.jpg" }
                val mimeType = item["mimeType"]?.toString()?.takeIf { it.isNotBlank() }
                    ?: detectMimeType(fileName)
                val platformFolder = item["platformFolder"]?.toString()?.takeIf { it.isNotBlank() } ?: "Pixiv"
                val creatorFolder = item["creatorFolder"]?.toString()?.takeIf { it.isNotBlank() } ?: "Umum"
                val albumFolder = item["albumFolder"]?.toString()?.takeIf { it.isNotBlank() }

                val ok = runCatching {
                    val tempCopy = File(context.cacheDir, "lock_tmp_${System.nanoTime()}_${sanitizeFileName(fileName)}")
                    try {
                        var copied = false
                        if (contentUri.startsWith("content://")) {
                            context.contentResolver.openInputStream(Uri.parse(contentUri))?.use { input ->
                                FileOutputStream(tempCopy).use { out ->
                                    input.copyTo(out, bufferSize = 64 * 1024)
                                }
                                copied = tempCopy.exists() && tempCopy.length() > 0L
                            }
                        }
                        if (!copied && filePath.isNotBlank()) {
                            val srcFile = File(filePath)
                            if (srcFile.exists() && srcFile.length() > 0L) {
                                srcFile.copyTo(tempCopy, overwrite = true)
                                copied = tempCopy.exists() && tempCopy.length() > 0L
                            }
                        }
                        if (!copied) return@runCatching false

                        exportFileToPrivateVault(
                            sourceFile = tempCopy,
                            requestedName = fileName,
                            mimeType = mimeType,
                            platformFolder = platformFolder,
                            creatorFolder = creatorFolder,
                            albumFolder = albumFolder,
                        )
                        deleteFile(filePath, contentUri)
                        true
                    } finally {
                        runCatching { tempCopy.delete() }
                    }
                }.getOrDefault(false)
                if (ok) count++
            }
            postToMain { onDone(count) }
        }
    }

    fun fileExists(filePath: String?, contentUri: String?): Boolean {
        if (!contentUri.isNullOrBlank() && contentUri.startsWith("content://")) {
            val existsInMediaStore = runCatching {
                context.contentResolver.openAssetFileDescriptor(Uri.parse(contentUri), "r")?.use { true } ?: false
            }.getOrDefault(false)
            if (existsInMediaStore) return true
        }
        if (!filePath.isNullOrBlank()) {
            return File(filePath).exists()
        }
        return false
    }

    fun getStorageInfoAsync(onDone: (Map<String, Any?>) -> Unit) {
        scope.launch {
            val cacheBytes = runCatching { calculateDirSize(context.cacheDir) }.getOrDefault(0L)
            val version = try {
                if (isInitialized) YoutubeDL.getInstance().version(context) ?: "bundled" else "memuat..."
            } catch (_: Throwable) {
                "bundled"
            }
            val info = mapOf(
                "downloadFolder" to getPublicFolderLabel(),
                "cacheBytes" to cacheBytes,
                "version" to version,
                "ffmpegReady" to ffmpegReady,
                "aria2cReady" to aria2cReady,
            )
            postToMain { onDone(info) }
        }
    }

    fun clearCacheAsync(onDone: (Long) -> Unit) {
        scope.launch {
            var freed = 0L
            runCatching {
                context.cacheDir.listFiles()?.forEach { child ->
                    if (child.name.startsWith("ytdl_") || child.name.startsWith("direct_")) {
                        freed += calculateDirSize(child)
                        runCatching { child.deleteRecursively() }
                    }
                }
            }
            postToMain { onDone(freed) }
        }
    }

    private fun resolveReadableUri(filePath: String?, contentUri: String?): Uri? {
        if (!contentUri.isNullOrBlank() && contentUri.startsWith("content://")) {
            return Uri.parse(contentUri)
        }
        if (!filePath.isNullOrBlank()) {
            val file = File(filePath)
            if (file.exists()) {
                return FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileprovider",
                    file,
                )
            }
        }
        return null
    }

    private fun getPublicFolderLabel(): String = "Pictures/all_download/<Aplikasi>/<Username>"

    private fun resolveUniqueFile(dir: File, name: String): File {
        var candidate = File(dir, name)
        if (!candidate.exists()) return candidate
        val dotIndex = name.lastIndexOf('.')
        val base = if (dotIndex > 0) name.substring(0, dotIndex) else name
        val ext = if (dotIndex > 0) name.substring(dotIndex) else ""
        var count = 1
        while (candidate.exists()) {
            candidate = File(dir, "$base ($count)$ext")
            count++
        }
        return candidate
    }

    private fun sanitizeFolderSegment(raw: String?, fallback: String): String {
        val cleaned = (raw ?: "")
            .removePrefix("@")
            .replace(Regex("[\\\\/:*?\"<>|\\r\\n\\t]+"), "_")
            .replace(Regex("\\s+"), " ")
            .trim()
            .trim('.')
        return if (cleaned.isEmpty()) fallback else cleaned.take(48).trim()
    }

    private fun sanitizeFileName(raw: String): String {
        val cleaned = raw
            .replace(Regex("[\\\\/:*?\"<>|\\r\\n\\t]+"), "_")
            .trim()
            .trim('.')
        return if (cleaned.isEmpty()) "all_download_media.mp4" else cleaned.take(120)
    }

    private fun detectMimeType(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase(Locale.US)
        if (ext.isEmpty()) return "video/mp4"
        return when (ext) {
            "mp4", "m4v" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "mp3" -> "audio/mpeg"
            "m4a" -> "audio/mp4"
            "ogg", "opus" -> "audio/ogg"
            "wav" -> "audio/wav"
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "webp" -> "image/webp"
            "gif" -> "image/gif"
            else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        }
    }

    private fun calculateDirSize(file: File): Long {
        if (!file.exists()) return 0L
        if (file.isFile) return file.length()
        return file.listFiles()?.sumOf { calculateDirSize(it) } ?: 0L
    }

    private fun sanitizeError(raw: String?): String {
        val text = raw?.trim().orEmpty()
        if (text.isEmpty()) return "Terjadi kesalahan saat memproses link."
        val lines = text.lines().map { it.trim() }.filter { it.isNotEmpty() }
        val errorLine = lines.lastOrNull { it.startsWith("ERROR:", ignoreCase = true) }
        return errorLine?.removePrefix("ERROR:")?.trim() ?: lines.last().take(280)
    }
}
