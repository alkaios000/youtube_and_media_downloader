package com.linkdrop.linkdrop_downloader

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import com.yausername.aria2c.Aria2c
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class MediaEngineBridge(private val context: Context) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    private var isInitialized = false

    @Volatile
    private var ffmpegReady = false

    @Volatile
    private var aria2cReady = false

    @Volatile
    private var progressEmitter: ((Map<String, Any?>) -> Unit)? = null

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
                val version = runCatching { YoutubeDL.getInstance().version(context) }.getOrNull() ?: "bundled"
                val info = mapOf(
                    "initialized" to isInitialized,
                    "version" to version,
                    "ffmpegReady" to ffmpegReady,
                    "aria2cReady" to aria2cReady,
                    "downloadFolder" to getPublicFolderLabel(),
                )
                postToMain { onSuccess(info) }
            } catch (e: Exception) {
                postToMain { onError("INIT_ERROR", e.message ?: "Gagal inisialisasi engine yt-dlp") }
            }
        }
    }

    @Synchronized
    private fun ensureInitialized() {
        if (isInitialized) return
        YoutubeDL.getInstance().init(context)
        ffmpegReady = runCatching {
            FFmpeg.getInstance().init(context)
            true
        }.getOrDefault(false)
        aria2cReady = runCatching {
            Aria2c.getInstance().init(context)
            true
        }.getOrDefault(false)
        isInitialized = true
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
            } catch (e: Exception) {
                postToMain { onError("UPDATE_ERROR", e.message ?: "Gagal memperbarui engine yt-dlp") }
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
                val request = YoutubeDLRequest(url)
                request.addOption("--dump-single-json")
                request.addOption("--no-playlist")
                request.addOption("--no-warnings")
                request.addOption("--skip-download")
                request.addOption("--socket-timeout", "25")
                if (!cookiesPath.isNullOrBlank() && File(cookiesPath).exists()) {
                    request.addOption("--cookies", cookiesPath)
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
            } catch (e: Exception) {
                postToMain { onError("EXTRACT_ERROR", sanitizeError(e.message)) }
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
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (String, String) -> Unit,
    ) {
        scope.launch {
            val workDir = File(context.cacheDir, "ytdl_task_$taskId")
            try {
                ensureInitialized()
                if (workDir.exists()) workDir.deleteRecursively()
                workDir.mkdirs()

                val request = YoutubeDLRequest(url)
                request.addOption("-o", "${workDir.absolutePath}/%(title).80s [%(id)s].%(ext)s")
                request.addOption("--no-playlist")
                request.addOption("--no-mtime")
                request.addOption("--windows-filenames")
                request.addOption("--socket-timeout", "30")
                request.addOption("--retries", "3")
                request.addOption("--fragment-retries", "3")

                if (!cookiesPath.isNullOrBlank() && File(cookiesPath).exists()) {
                    request.addOption("--cookies", cookiesPath)
                }

                if (audioOnly) {
                    val targetAudio = audioFormat.lowercase(Locale.US).ifBlank { "mp3" }
                    request.addOption("-x")
                    request.addOption("--audio-format", targetAudio)
                    request.addOption("--audio-quality", "0")
                    request.addOption("--add-metadata")
                } else {
                    val selector = formatSelector?.takeIf { it.isNotBlank() }
                        ?: "bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best"
                    request.addOption("-f", selector)
                    if (ffmpegReady) {
                        request.addOption("--merge-output-format", "mp4")
                    }
                }

                if (useAria2c && aria2cReady && !audioOnly) {
                    request.addOption("--downloader", "libaria2c.so")
                    request.addOption("--external-downloader-args", "aria2c:\"--summary-interval=1 -x 4 -s 4 -k 1M\"")
                }

                var lastEmitTime = 0L
                YoutubeDL.getInstance().execute(request, taskId) { progress, etaInSeconds, line ->
                    val now = System.currentTimeMillis()
                    if (now - lastEmitTime >= 180L || progress >= 99.5f || progress < 0f) {
                        lastEmitTime = now
                        val payload = mapOf(
                            "taskId" to taskId,
                            "progress" to progress.toDouble(),
                            "etaSeconds" to etaInSeconds,
                            "line" to (line ?: ""),
                        )
                        postToMain { progressEmitter?.invoke(payload) }
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

                if (producedFiles.isEmpty()) {
                    throw IllegalStateException("File hasil unduhan tidak ditemukan.")
                }

                val primaryFile = producedFiles.first()
                val mimeType = detectMimeType(primaryFile.name)
                val exported = exportFileToPublicDownloads(primaryFile, primaryFile.name, mimeType)

                postToMain { onSuccess(exported) }
            } catch (e: Exception) {
                val msg = e.message.orEmpty()
                if (msg.contains("destroyed", ignoreCase = true) || msg.contains("interrupt", ignoreCase = true)) {
                    postToMain { onError("CANCELLED", "Unduhan dibatalkan.") }
                } else {
                    postToMain { onError("DOWNLOAD_ERROR", sanitizeError(msg)) }
                }
            } finally {
                runCatching { workDir.deleteRecursively() }
            }
        }
    }

    fun cancelDownload(taskId: String): Boolean {
        return runCatching {
            YoutubeDL.getInstance().destroyProcessById(taskId)
        }.getOrDefault(false)
    }

    fun saveFileToDownloads(
        sourcePath: String,
        fileName: String,
        mimeType: String?,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (String, String) -> Unit,
    ) {
        scope.launch {
            val sourceFile = File(sourcePath)
            try {
                if (!sourceFile.exists() || sourceFile.length() == 0L) {
                    throw IllegalArgumentException("File sementara tidak ditemukan atau kosong.")
                }
                val safeName = sanitizeFileName(fileName)
                val resolvedMime = mimeType?.takeIf { it.isNotBlank() } ?: detectMimeType(safeName)
                val exported = exportFileToPublicDownloads(sourceFile, safeName, resolvedMime)
                runCatching { sourceFile.delete() }
                postToMain { onSuccess(exported) }
            } catch (e: Exception) {
                postToMain { onError("SAVE_ERROR", e.message ?: "Gagal menyimpan file ke folder Download") }
            }
        }
    }

    private fun exportFileToPublicDownloads(
        sourceFile: File,
        requestedName: String,
        mimeType: String,
    ): Map<String, Any?> {
        val cleanName = sanitizeFileName(requestedName)
        val fileSize = sourceFile.length()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, cleanName)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/LinkDrop")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }

            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Gagal membuat entri MediaStore di folder Downloads.")

            try {
                resolver.openOutputStream(uri)?.use { out ->
                    FileInputStream(sourceFile).use { input ->
                        input.copyTo(out, bufferSize = 64 * 1024)
                    }
                } ?: throw IllegalStateException("Gagal membuka stream output MediaStore.")

                val doneValues = ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                }
                resolver.update(uri, doneValues, null, null)

                var finalDisplayName = cleanName
                resolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(MediaStore.Downloads.DISPLAY_NAME)
                        if (idx >= 0) {
                            finalDisplayName = cursor.getString(idx) ?: cleanName
                        }
                    }
                }

                return mapOf(
                    "savedPath" to "/storage/emulated/0/Download/LinkDrop/$finalDisplayName",
                    "contentUri" to uri.toString(),
                    "fileName" to finalDisplayName,
                    "fileSize" to fileSize,
                    "mimeType" to mimeType,
                )
            } catch (e: Exception) {
                runCatching { resolver.delete(uri, null, null) }
                throw e
            }
        } else {
            @Suppress("DEPRECATION")
            val publicDownloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val targetDir = File(publicDownloads, "LinkDrop")
            val dirReady = (targetDir.exists() || targetDir.mkdirs()) && targetDir.canWrite()
            val finalDir = if (dirReady) {
                targetDir
            } else {
                File(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "LinkDrop").apply { mkdirs() }
            }

            val destFile = resolveUniqueFile(finalDir, cleanName)
            FileInputStream(sourceFile).use { input ->
                FileOutputStream(destFile).use { output ->
                    input.copyTo(output, bufferSize = 64 * 1024)
                }
            }

            MediaScannerConnection.scanFile(
                context,
                arrayOf(destFile.absolutePath),
                arrayOf(mimeType),
                null,
            )

            return mapOf(
                "savedPath" to destFile.absolutePath,
                "contentUri" to "",
                "fileName" to destFile.name,
                "fileSize" to destFile.length(),
                "mimeType" to mimeType,
            )
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
            }
        }
        return deleted
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

    fun getStorageInfo(): Map<String, Any?> {
        val cacheBytes = calculateDirSize(context.cacheDir)
        return mapOf(
            "downloadFolder" to getPublicFolderLabel(),
            "cacheBytes" to cacheBytes,
            "version" to (runCatching { YoutubeDL.getInstance().version(context) }.getOrNull() ?: "bundled"),
            "ffmpegReady" to ffmpegReady,
            "aria2cReady" to aria2cReady,
        )
    }

    fun clearCache(): Long {
        var freed = 0L
        context.cacheDir.listFiles()?.forEach { child ->
            if (child.name.startsWith("ytdl_") || child.name.startsWith("direct_")) {
                freed += calculateDirSize(child)
                runCatching { child.deleteRecursively() }
            }
        }
        return freed
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

    private fun getPublicFolderLabel(): String = "Download/LinkDrop"

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

    private fun sanitizeFileName(raw: String): String {
        val cleaned = raw
            .replace(Regex("[\\\\/:*?\"<>|\\r\\n\\t]+"), "_")
            .trim()
            .trim('.')
        return if (cleaned.isEmpty()) "linkdrop_media.mp4" else cleaned.take(120)
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
