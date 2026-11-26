package com.linkdrop.linkdrop_downloader

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CACHED_ENGINE_ID = "all_download_main_engine"
        private const val ENGINE_CHANNEL = "com.linkdrop.downloader/engine"
        private const val PROGRESS_CHANNEL = "com.linkdrop.downloader/progress"
        private const val SHARE_CHANNEL = "com.linkdrop.downloader/share"
        private const val PERMISSION_REQUEST_CODE = 4201
        private const val EXPORT_BACKUP_REQUEST_CODE = 4202
        private const val IMPORT_BACKUP_REQUEST_CODE = 4203

        // Process-wide singletons so active downloads, FFmpeg/yt-dlp coroutines,
        // and wallpaper jobs survive Android 12/13+ Monet Activity relaunches!
        @Volatile
        private var sharedBridge: MediaEngineBridge? = null

        @Volatile
        private var sharedSniffer: WebViewMediaSniffer? = null

        @Volatile
        private var pluginsRegisteredOnEngine: FlutterEngine? = null

        @Volatile
        private var pendingInitialSharedText: String? = null

        @Volatile
        private var activeShareEventSink: EventChannel.EventSink? = null

        private fun getBridge(appContext: Context): MediaEngineBridge {
            return sharedBridge ?: synchronized(this) {
                sharedBridge ?: MediaEngineBridge(appContext.applicationContext).also {
                    sharedBridge = it
                }
            }
        }

        private fun getSniffer(appContext: Context): WebViewMediaSniffer {
            return sharedSniffer ?: synchronized(this) {
                sharedSniffer ?: WebViewMediaSniffer(appContext.applicationContext).also {
                    sharedSniffer = it
                }
            }
        }
    }

    private lateinit var bridge: MediaEngineBridge
    private lateinit var sniffer: WebViewMediaSniffer
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingExportResult: MethodChannel.Result? = null
    private var pendingExportJson: String? = null
    private var pendingImportResult: MethodChannel.Result? = null
    private var hasRequestedPermissionsBefore = false

    /**
     * Reuses the already-running [FlutterEngine] across Android 12/13+ Material You
     * (Monet) wallpaper relaunches & warm restarts. On first launch returns `null` so
     * Flutter creates the engine with full debug/release shell args, then caches it in
     * [configureFlutterEngine]. Eliminates the 5+ second ANR freeze after setting wallpaper.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return FlutterEngineCache.getInstance().get(CACHED_ENGINE_ID)
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        runCatching { handleIncomingIntent(intent, isLaunch = true) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        runCatching { handleIncomingIntent(intent, isLaunch = false) }
    }

    private fun handleIncomingIntent(intent: Intent?, isLaunch: Boolean) {
        if (intent == null) return
        if (Intent.ACTION_SEND == intent.action) {
            val extraText = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim().orEmpty()
            val extraSubject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.trim().orEmpty()
            val shared = when {
                extraText.contains("http", ignoreCase = true) -> extraText
                extraSubject.contains("http", ignoreCase = true) -> extraSubject
                extraText.isNotEmpty() -> extraText
                else -> extraSubject
            }
            if (shared.isNotEmpty()) {
                val sink = activeShareEventSink
                if (sink != null) {
                    runOnUiThread { sink.success(shared) }
                } else {
                    pendingInitialSharedText = shared
                }
            }
        }
    }

    private fun requiredStoragePermissions(): Array<String> {
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> arrayOf(
                Manifest.permission.READ_MEDIA_VIDEO,
                Manifest.permission.READ_MEDIA_AUDIO,
                Manifest.permission.READ_MEDIA_IMAGES,
            )
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> arrayOf(
                Manifest.permission.READ_EXTERNAL_STORAGE,
            )
            else -> arrayOf(
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
                Manifest.permission.READ_EXTERNAL_STORAGE,
            )
        }
    }

    private fun buildPermissionStatus(): Map<String, Any?> {
        val perms = requiredStoragePermissions()
        val missing = perms.filter { perm ->
            ContextCompat.checkSelfPermission(this, perm) != PackageManager.PERMISSION_GRANTED
        }
        val granted = missing.isEmpty()
        val permanentlyDenied = !granted && hasRequestedPermissionsBefore && missing.all { perm ->
            !ActivityCompat.shouldShowRequestPermissionRationale(this, perm)
        }
        return mapOf(
            "granted" to granted,
            "permanentlyDenied" to permanentlyDenied,
            "sdkInt" to Build.VERSION.SDK_INT,
            "missing" to missing,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            hasRequestedPermissionsBefore = true
            val result = pendingPermissionResult
            pendingPermissionResult = null
            result?.success(buildPermissionStatus())
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == EXPORT_BACKUP_REQUEST_CODE) {
            val res = pendingExportResult
            val json = pendingExportJson
            pendingExportResult = null
            pendingExportJson = null
            if (resultCode != RESULT_OK || data?.data == null || json == null) {
                res?.success(false)
                return
            }
            val uri = data.data!!
            Thread {
                val ok = runCatching {
                    contentResolver.openOutputStream(uri)?.use { out ->
                        out.write(json.toByteArray(Charsets.UTF_8))
                        out.flush()
                    } ?: return@runCatching false
                    true
                }.getOrDefault(false)
                runOnUiThread { res?.success(ok) }
            }.start()
        } else if (requestCode == IMPORT_BACKUP_REQUEST_CODE) {
            val res = pendingImportResult
            pendingImportResult = null
            if (resultCode != RESULT_OK || data?.data == null) {
                res?.success(null)
                return
            }
            val uri = data.data!!
            Thread {
                val text = runCatching {
                    contentResolver.openInputStream(uri)?.bufferedReader(Charsets.UTF_8)?.use {
                        it.readText()
                    }
                }.getOrNull()
                runOnUiThread { res?.success(text) }
            }.start()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        FlutterEngineCache.getInstance().put(CACHED_ENGINE_ID, flutterEngine)
        bridge = getBridge(applicationContext)
        sniffer = getSniffer(applicationContext)

        if (pluginsRegisteredOnEngine !== flutterEngine) {
            super.configureFlutterEngine(flutterEngine)
            pluginsRegisteredOnEngine = flutterEngine

            // Bind EventChannels once per cached FlutterEngine so active streams
            // survive Android 12/13+ Monet wallpaper Activity relaunches uninterrupted.
            val mainLooperHandler = Handler(Looper.getMainLooper())
            EventChannel(flutterEngine.dartExecutor.binaryMessenger, PROGRESS_CHANNEL)
                .setStreamHandler(
                    object : EventChannel.StreamHandler {
                        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                            bridge.setProgressEmitter { payload ->
                                events?.success(payload)
                            }
                        }

                        override fun onCancel(arguments: Any?) {
                            bridge.setProgressEmitter(null)
                        }
                    },
                )

            EventChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
                .setStreamHandler(
                    object : EventChannel.StreamHandler {
                        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                            activeShareEventSink = events
                            val pending = pendingInitialSharedText
                            if (!pending.isNullOrEmpty() && events != null) {
                                pendingInitialSharedText = null
                                mainLooperHandler.post { events.success(pending) }
                            }
                        }

                        override fun onCancel(arguments: Any?) {
                            activeShareEventSink = null
                        }
                    },
                )
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ENGINE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkPermissions" -> {
                        result.success(buildPermissionStatus())
                    }

                    "requestPermissions" -> {
                        val perms = requiredStoragePermissions()
                        val missing = perms.filter { perm ->
                            ContextCompat.checkSelfPermission(this, perm) != PackageManager.PERMISSION_GRANTED
                        }
                        if (missing.isEmpty()) {
                            result.success(buildPermissionStatus())
                        } else {
                            pendingPermissionResult?.success(buildPermissionStatus())
                            pendingPermissionResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                missing.toTypedArray(),
                                PERMISSION_REQUEST_CODE,
                            )
                        }
                    }

                    "openAppSettings" -> {
                        val opened = runCatching {
                            val intent = Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.fromParts("package", packageName, null),
                            ).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            true
                        }.getOrDefault(false)
                        result.success(opened)
                    }

                    "sniffMedia" -> {
                        val url = call.argument<String>("url")
                        val platform = call.argument<String>("platform") ?: "other"
                        val timeoutMs = (call.argument<Int>("timeoutMs") ?: 16000).toLong()
                        if (url.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "URL kosong", null)
                            return@setMethodCallHandler
                        }
                        sniffer.sniffMedia(
                            activity = this,
                            url = url,
                            platform = platform,
                            timeoutMs = timeoutMs,
                            onResult = { payload -> result.success(payload) },
                            onError = { code, message -> result.error(code, message, null) },
                        )
                    }

                    "sniffProfileItems" -> {
                        val url = call.argument<String>("url")
                        val platform = call.argument<String>("platform") ?: "tiktok"
                        val timeoutMs = (call.argument<Int>("timeoutMs") ?: 28000).toLong()
                        if (url.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "URL profil kosong", null)
                            return@setMethodCallHandler
                        }
                        sniffer.sniffProfileItems(
                            activity = this,
                            url = url,
                            platform = platform,
                            timeoutMs = timeoutMs,
                            onResult = { payload -> result.success(payload) },
                            onError = { code, message -> result.error(code, message, null) },
                        )
                    }

                    "openBrowserLogin" -> {
                        val platform = call.argument<String>("platform") ?: "instagram"
                        sniffer.openLoginDialog(
                            activity = this,
                            platform = platform,
                            onDone = { info -> result.success(info) },
                        )
                    }

                    "getBrowserSessionStatus" -> {
                        Thread {
                            val status = mapOf(
                                "instagram" to sniffer.hasPlatformCookies("instagram"),
                                "douyin" to sniffer.hasPlatformCookies("douyin"),
                                "facebook" to sniffer.hasPlatformCookies("facebook"),
                                "pixiv" to sniffer.hasPlatformCookies("pixiv"),
                                "tiktok" to sniffer.hasPlatformCookies("tiktok"),
                            )
                            runOnUiThread { result.success(status) }
                        }.start()
                    }

                    "getCookieHeader" -> {
                        val url = call.argument<String>("url") ?: ""
                        Thread {
                            val header = sniffer.getCookieHeaderForUrl(url)
                            runOnUiThread { result.success(header) }
                        }.start()
                    }

                    "clearBrowserSessions" -> {
                        sniffer.clearWebViewCookies {
                            result.success(true)
                        }
                    }

                    "initEngine" -> {
                        bridge.initEngine(
                            onSuccess = { info -> result.success(info) },
                            onError = { code, message -> result.error(code, message, null) },
                        )
                    }

                    "updateEngine" -> {
                        val channel = call.argument<String>("channel") ?: "stable"
                        bridge.updateEngine(
                            channelName = channel,
                            onSuccess = { info -> result.success(info) },
                            onError = { code, message -> result.error(code, message, null) },
                        )
                    }

                    "extractInfo" -> {
                        val url = call.argument<String>("url")
                        val cookiesPath = call.argument<String>("cookiesPath")
                        if (url.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "URL tidak boleh kosong", null)
                            return@setMethodCallHandler
                        }
                        bridge.extractInfo(
                            url = url,
                            cookiesPath = cookiesPath,
                            onSuccess = { json -> result.success(json) },
                            onError = { code, message -> result.error(code, message, null) },
                        )
                    }

                    "extractProfileItems" -> {
                        val url = call.argument<String>("url")
                        val cookiesPath = call.argument<String>("cookiesPath")
                        if (url.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "URL profil kosong", null)
                            return@setMethodCallHandler
                        }
                        bridge.extractProfileItems(
                            url = url,
                            cookiesPath = cookiesPath,
                            onSuccess = { json -> result.success(json) },
                            onError = { code, message -> result.error(code, message, null) },
                        )
                    }

                    "downloadWithYtDlp" -> {
                        val taskId = call.argument<String>("taskId")
                        val url = call.argument<String>("url")
                        if (taskId.isNullOrBlank() || url.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "taskId dan url wajib diisi", null)
                            return@setMethodCallHandler
                        }
                        val formatSelector = call.argument<String>("formatSelector")
                        val audioOnly = call.argument<Boolean>("audioOnly") ?: false
                        val audioFormat = call.argument<String>("audioFormat") ?: "mp3"
                        val cookiesPath = call.argument<String>("cookiesPath")
                        val useAria2c = call.argument<Boolean>("useAria2c") ?: false
                        val platformFolder = call.argument<String>("platformFolder") ?: "Lainnya"
                        val creatorFolder = call.argument<String>("creatorFolder") ?: "Umum"

                        bridge.downloadWithYtDlp(
                            taskId = taskId,
                            url = url,
                            formatSelector = formatSelector,
                            audioOnly = audioOnly,
                            audioFormat = audioFormat,
                            cookiesPath = cookiesPath,
                            useAria2c = useAria2c,
                            platformFolder = platformFolder,
                            creatorFolder = creatorFolder,
                            onSuccess = { saved -> result.success(saved) },
                            onError = { code, message -> result.error(code, message, null) },
                        )
                    }

                    "pauseDownload" -> {
                        val taskId = call.argument<String>("taskId") ?: ""
                        result.success(bridge.pauseDownload(taskId))
                    }

                    "cancelDownload" -> {
                        val taskId = call.argument<String>("taskId") ?: ""
                        result.success(bridge.cancelDownload(taskId))
                    }

                    "convertUgoiraZip" -> {
                        val zipPath = call.argument<String>("zipPath")
                        val rawFrames = call.argument<List<Map<String, Any?>>>("frames").orEmpty()
                        val outputFormat = call.argument<String>("outputFormat") ?: "mp4"
                        val fileName = call.argument<String>("fileName") ?: "ugoira.mp4"
                        val platformFolder = call.argument<String>("platformFolder") ?: "Pixiv"
                        val creatorFolder = call.argument<String>("creatorFolder") ?: "Umum"
                        val albumFolder = call.argument<String>("albumFolder")
                        val isPrivate = call.argument<Boolean>("isPrivate") ?: true
                        if (zipPath.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "zipPath kosong", null)
                            return@setMethodCallHandler
                        }
                        bridge.convertUgoiraZip(
                            zipPath = zipPath,
                            frames = rawFrames,
                            outputFormat = outputFormat,
                            fileName = fileName,
                            platformFolder = platformFolder,
                            creatorFolder = creatorFolder,
                            albumFolder = albumFolder,
                            isPrivate = isPrivate,
                            onSuccess = { saved -> result.success(saved) },
                            onError = { code, message -> result.error(code, message, null) },
                        )
                    }

                    "saveFileToDownloads" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName") ?: "media.mp4"
                        val mimeType = call.argument<String>("mimeType")
                        val platformFolder = call.argument<String>("platformFolder") ?: "Lainnya"
                        val creatorFolder = call.argument<String>("creatorFolder") ?: "Umum"
                        val albumFolder = call.argument<String>("albumFolder")
                        val isPrivate = call.argument<Boolean>("isPrivate") ?: false
                        if (sourcePath.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "sourcePath kosong", null)
                            return@setMethodCallHandler
                        }
                        bridge.saveFileToDownloads(
                            sourcePath = sourcePath,
                            fileName = fileName,
                            mimeType = mimeType,
                            platformFolder = platformFolder,
                            creatorFolder = creatorFolder,
                            albumFolder = albumFolder,
                            isPrivate = isPrivate,
                            onSuccess = { saved -> result.success(saved) },
                            onError = { code, message -> result.error(code, message, null) },
                        )
                    }

                    "listManagedFiles" -> {
                        bridge.listManagedFiles(
                            onSuccess = { files -> result.success(files) },
                            onError = { code, message -> result.error(code, message, null) },
                        )
                    }

                    "setWallpaper" -> {
                        val filePath = call.argument<String>("filePath")
                        val contentUri = call.argument<String>("contentUri")
                        val target = call.argument<String>("target") ?: "home"
                        val cropLeft = (call.argument<Number>("cropLeft"))?.toFloat()
                        val cropTop = (call.argument<Number>("cropTop"))?.toFloat()
                        val cropWidth = (call.argument<Number>("cropWidth"))?.toFloat()
                        val cropHeight = (call.argument<Number>("cropHeight"))?.toFloat()
                        bridge.setWallpaper(
                            activity = this,
                            filePath = filePath,
                            contentUri = contentUri,
                            target = target,
                            cropLeft = cropLeft,
                            cropTop = cropTop,
                            cropWidth = cropWidth,
                            cropHeight = cropHeight,
                            onSuccess = { ok -> result.success(ok) },
                            onError = { code, message -> result.error(code, message, null) },
                        )
                    }

                    "openFile" -> {
                        val ok = bridge.openFile(
                            filePath = call.argument<String>("filePath"),
                            contentUri = call.argument<String>("contentUri"),
                            mimeType = call.argument<String>("mimeType"),
                        )
                        result.success(ok)
                    }

                    "shareFile" -> {
                        val ok = bridge.shareFile(
                            filePath = call.argument<String>("filePath"),
                            contentUri = call.argument<String>("contentUri"),
                            mimeType = call.argument<String>("mimeType"),
                            title = call.argument<String>("title"),
                        )
                        result.success(ok)
                    }

                    "shareMultipleFiles" -> {
                        val rawItems = call.argument<List<Map<String, Any?>>>("items").orEmpty()
                        val ok = bridge.shareMultipleFiles(rawItems)
                        result.success(ok)
                    }

                    "deleteFile" -> {
                        val ok = bridge.deleteFile(
                            filePath = call.argument<String>("filePath"),
                            contentUri = call.argument<String>("contentUri"),
                        )
                        result.success(ok)
                    }

                    "deleteMultipleFiles" -> {
                        val rawItems = call.argument<List<Map<String, Any?>>>("items").orEmpty()
                        bridge.deleteMultipleFiles(rawItems) { count ->
                            result.success(count)
                        }
                    }

                    "unlockFiles" -> {
                        val rawItems = call.argument<List<Map<String, Any?>>>("items").orEmpty()
                        bridge.unlockFiles(rawItems) { count ->
                            result.success(count)
                        }
                    }

                    "lockFiles" -> {
                        val rawItems = call.argument<List<Map<String, Any?>>>("items").orEmpty()
                        bridge.lockFiles(rawItems) { count ->
                            result.success(count)
                        }
                    }

                    "fileExists" -> {
                        val exists = bridge.fileExists(
                            filePath = call.argument<String>("filePath"),
                            contentUri = call.argument<String>("contentUri"),
                        )
                        result.success(exists)
                    }

                    "findExistingFile" -> {
                        val fileName = call.argument<String>("fileName") ?: ""
                        val mimeType = call.argument<String>("mimeType")
                        val platformFolder = call.argument<String>("platformFolder") ?: "Lainnya"
                        val creatorFolder = call.argument<String>("creatorFolder") ?: "Umum"
                        val albumFolder = call.argument<String>("albumFolder")
                        val checkPrivateVault = call.argument<Boolean>("checkPrivateVault") ?: true
                        if (fileName.isBlank()) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        bridge.findExistingFile(
                            fileName = fileName,
                            mimeType = mimeType,
                            platformFolder = platformFolder,
                            creatorFolder = creatorFolder,
                            albumFolder = albumFolder,
                            checkPrivateVault = checkPrivateVault,
                            onResult = { existing -> result.success(existing) },
                        )
                    }

                    "getInitialSharedText" -> {
                        val pending = pendingInitialSharedText
                        pendingInitialSharedText = null
                        result.success(pending)
                    }

                    "getStorageInfo" -> {
                        bridge.getStorageInfoAsync { info -> result.success(info) }
                    }

                    "clearCache" -> {
                        bridge.clearCacheAsync { freed -> result.success(freed) }
                    }

                    "exportBackupFile" -> {
                        val jsonContent = call.argument<String>("jsonContent") ?: ""
                        val fileName = call.argument<String>("fileName") ?: "all_download_backup.json"
                        if (jsonContent.isBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        pendingExportResult?.success(false)
                        pendingExportResult = result
                        pendingExportJson = jsonContent
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/json"
                            putExtra(Intent.EXTRA_TITLE, fileName)
                        }
                        runCatching {
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, EXPORT_BACKUP_REQUEST_CODE)
                        }.onFailure {
                            pendingExportResult = null
                            pendingExportJson = null
                            result.success(false)
                        }
                    }

                    "importBackupFile" -> {
                        pendingImportResult?.success(null)
                        pendingImportResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/plain", "*/*"))
                        }
                        runCatching {
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, IMPORT_BACKUP_REQUEST_CODE)
                        }.onFailure {
                            pendingImportResult = null
                            result.success(null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
