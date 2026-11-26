package com.linkdrop.linkdrop_downloader

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val ENGINE_CHANNEL = "com.linkdrop.downloader/engine"
        private const val PROGRESS_CHANNEL = "com.linkdrop.downloader/progress"
        private const val SHARE_CHANNEL = "com.linkdrop.downloader/share"
        private const val PERMISSION_REQUEST_CODE = 4201
    }

    private lateinit var bridge: MediaEngineBridge
    private lateinit var sniffer: WebViewMediaSniffer
    private var initialSharedText: String? = null
    private var shareEventSink: EventChannel.EventSink? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var hasRequestedPermissionsBefore = false

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
        if (Intent.ACTION_SEND == intent.action && intent.type?.startsWith("text/") == true) {
            val shared = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
            if (!shared.isNullOrEmpty()) {
                if (!isLaunch && shareEventSink != null) {
                    shareEventSink?.success(shared)
                } else {
                    initialSharedText = shared
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = MediaEngineBridge(applicationContext)
        sniffer = WebViewMediaSniffer(applicationContext)

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
                        shareEventSink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        shareEventSink = null
                    }
                },
            )

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

                    "openBrowserLogin" -> {
                        val platform = call.argument<String>("platform") ?: "instagram"
                        sniffer.openLoginDialog(
                            activity = this,
                            platform = platform,
                            onDone = { info -> result.success(info) },
                        )
                    }

                    "getBrowserSessionStatus" -> {
                        result.success(
                            mapOf(
                                "instagram" to sniffer.hasPlatformCookies("instagram"),
                                "douyin" to sniffer.hasPlatformCookies("douyin"),
                                "facebook" to sniffer.hasPlatformCookies("facebook"),
                                "pixiv" to sniffer.hasPlatformCookies("pixiv"),
                            ),
                        )
                    }

                    "getCookieHeader" -> {
                        val url = call.argument<String>("url") ?: ""
                        result.success(sniffer.getCookieHeaderForUrl(url))
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
                        val limit = call.argument<Int>("limit") ?: 30
                        if (url.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "URL profil kosong", null)
                            return@setMethodCallHandler
                        }
                        bridge.extractProfileItems(
                            url = url,
                            cookiesPath = cookiesPath,
                            limit = limit,
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

                    "cancelDownload" -> {
                        val taskId = call.argument<String>("taskId") ?: ""
                        result.success(bridge.cancelDownload(taskId))
                    }

                    "saveFileToDownloads" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName") ?: "media.mp4"
                        val mimeType = call.argument<String>("mimeType")
                        val platformFolder = call.argument<String>("platformFolder") ?: "Lainnya"
                        val creatorFolder = call.argument<String>("creatorFolder") ?: "Umum"
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

                    "deleteFile" -> {
                        val ok = bridge.deleteFile(
                            filePath = call.argument<String>("filePath"),
                            contentUri = call.argument<String>("contentUri"),
                        )
                        result.success(ok)
                    }

                    "fileExists" -> {
                        val exists = bridge.fileExists(
                            filePath = call.argument<String>("filePath"),
                            contentUri = call.argument<String>("contentUri"),
                        )
                        result.success(exists)
                    }

                    "getInitialSharedText" -> {
                        val pending = initialSharedText
                        initialSharedText = null
                        result.success(pending)
                    }

                    "getStorageInfo" -> {
                        result.success(bridge.getStorageInfo())
                    }

                    "clearCache" -> {
                        result.success(bridge.clearCache())
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
