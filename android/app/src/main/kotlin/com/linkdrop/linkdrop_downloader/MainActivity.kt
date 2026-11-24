package com.linkdrop.linkdrop_downloader

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val ENGINE_CHANNEL = "com.linkdrop.downloader/engine"
        private const val PROGRESS_CHANNEL = "com.linkdrop.downloader/progress"
        private const val SHARE_CHANNEL = "com.linkdrop.downloader/share"
    }

    private lateinit var bridge: MediaEngineBridge
    private var initialSharedText: String? = null
    private var shareEventSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingIntent(intent, isLaunch = true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent, isLaunch = false)
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = MediaEngineBridge(applicationContext)

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

                        bridge.downloadWithYtDlp(
                            taskId = taskId,
                            url = url,
                            formatSelector = formatSelector,
                            audioOnly = audioOnly,
                            audioFormat = audioFormat,
                            cookiesPath = cookiesPath,
                            useAria2c = useAria2c,
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
                        if (sourcePath.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "sourcePath kosong", null)
                            return@setMethodCallHandler
                        }
                        bridge.saveFileToDownloads(
                            sourcePath = sourcePath,
                            fileName = fileName,
                            mimeType = mimeType,
                            onSuccess = { saved -> result.success(saved) },
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
