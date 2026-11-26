package com.linkdrop.linkdrop_downloader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Android Foreground Service (`dataSync`) that keeps active downloads alive when
 * the screen turns off or the app is backgrounded on aggressive OEMs (Xiaomi MIUI /
 * HyperOS, Oppo, Vivo), holds a scoped partial CPU WakeLock strictly while downloads
 * are running, and displays a clean silent progress notification + completion alert.
 */
class DownloadForegroundService : Service() {
    companion object {
        private const val TAG = "DownloadFgService"
        const val CHANNEL_PROGRESS = "all_download_progress"
        const val CHANNEL_COMPLETE = "all_download_complete"
        const val NOTIFICATION_ID_PROGRESS = 7101
        const val NOTIFICATION_ID_COMPLETE = 7102

        const val ACTION_UPDATE = "com.linkdrop.downloader.action.UPDATE"
        const val ACTION_STOP = "com.linkdrop.downloader.action.STOP"
        const val ACTION_PAUSE_ALL = "com.linkdrop.downloader.action.PAUSE_ALL"

        const val EXTRA_TITLE = "title"
        const val EXTRA_SUBTITLE = "subtitle"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_INDETERMINATE = "indeterminate"
        const val EXTRA_ACTIVE_COUNT = "activeCount"

        @Volatile
        var onPauseAllRequested: (() -> Unit)? = null

        @Volatile
        private var isServiceRunning = false

        fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
            val progressChannel = NotificationChannel(
                CHANNEL_PROGRESS,
                "Progres Unduhan",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Menampilkan progres unduhan aktif dan menjaga unduhan tetap berjalan di latar belakang."
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            val completeChannel = NotificationChannel(
                CHANNEL_COMPLETE,
                "Unduhan Selesai",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Memberitahu saat unduhan selesai atau gagal."
            }
            nm.createNotificationChannel(progressChannel)
            nm.createNotificationChannel(completeChannel)
        }

        fun startOrUpdate(
            context: Context,
            title: String,
            subtitle: String,
            progress: Int,
            indeterminate: Boolean,
            activeCount: Int,
        ) {
            ensureChannels(context)
            val intent = Intent(context, DownloadForegroundService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_SUBTITLE, subtitle)
                putExtra(EXTRA_PROGRESS, progress.coerceIn(0, 100))
                putExtra(EXTRA_INDETERMINATE, indeterminate)
                putExtra(EXTRA_ACTIVE_COUNT, activeCount)
            }
            runCatching {
                if (isServiceRunning) {
                    context.startService(intent)
                } else {
                    ContextCompat.startForegroundService(context, intent)
                }
            }.onFailure { err ->
                Log.w(TAG, "Unable to start foreground service: ${err.message}")
            }
        }

        fun stop(context: Context) {
            if (!isServiceRunning) return
            runCatching {
                context.startService(
                    Intent(context, DownloadForegroundService::class.java).apply {
                        action = ACTION_STOP
                    },
                )
            }.onFailure {
                runCatching {
                    context.stopService(Intent(context, DownloadForegroundService::class.java))
                }
            }
        }

        fun showCompletionNotification(
            context: Context,
            title: String,
            body: String,
            hasErrors: Boolean = false,
        ) {
            ensureChannels(context)
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val contentPi = if (launchIntent != null) {
                PendingIntent.getActivity(
                    context,
                    7109,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            } else {
                null
            }
            val notif = NotificationCompat.Builder(context, CHANNEL_COMPLETE)
                .setSmallIcon(
                    if (hasErrors) android.R.drawable.stat_notify_error
                    else android.R.drawable.stat_sys_download_done,
                )
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .apply { if (contentPi != null) setContentIntent(contentPi) }
                .build()
            runCatching {
                nm.notify(NOTIFICATION_ID_COMPLETE, notif)
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE_ALL -> {
                runCatching { onPauseAllRequested?.invoke() }
                stopSelfClean()
                return START_NOT_STICKY
            }
            ACTION_STOP -> {
                stopSelfClean()
                return START_NOT_STICKY
            }
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }
                    ?: "all_download — Mengunduh..."
                val subtitle = intent?.getStringExtra(EXTRA_SUBTITLE).orEmpty()
                val progress = intent?.getIntExtra(EXTRA_PROGRESS, 0) ?: 0
                val indeterminate = intent?.getBooleanExtra(EXTRA_INDETERMINATE, true) ?: true

                acquireWakeLockIfNeeded()
                val notification = buildProgressNotification(
                    title = title,
                    subtitle = subtitle,
                    progress = progress,
                    indeterminate = indeterminate,
                )

                val started = runCatching {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        startForeground(
                            NOTIFICATION_ID_PROGRESS,
                            notification,
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                        )
                    } else {
                        startForeground(NOTIFICATION_ID_PROGRESS, notification)
                    }
                    true
                }.getOrElse { err ->
                    Log.w(TAG, "startForeground failed: ${err.message}")
                    false
                }

                if (started) {
                    isServiceRunning = true
                } else {
                    stopSelfClean()
                }
                return START_NOT_STICKY
            }
        }
    }

    private fun buildProgressNotification(
        title: String,
        subtitle: String,
        progress: Int,
        indeterminate: Boolean,
    ): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPi = if (launchIntent != null) {
            PendingIntent.getActivity(
                this,
                7103,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        } else {
            null
        }

        val pauseIntent = Intent(this, DownloadForegroundService::class.java).apply {
            action = ACTION_PAUSE_ALL
        }
        val pausePi = PendingIntent.getService(
            this,
            7104,
            pauseIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_PROGRESS)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(subtitle.ifBlank { "Menjaga unduhan tetap berjalan..." })
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setProgress(100, progress.coerceIn(0, 100), indeterminate)
            .addAction(
                android.R.drawable.ic_media_pause,
                "Jeda Semua",
                pausePi,
            )
            .apply { if (contentPi != null) setContentIntent(contentPi) }
            .build()
    }

    private fun acquireWakeLockIfNeeded() {
        runCatching {
            val existing = wakeLock
            if (existing != null && existing.isHeld) return
            val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
            val wl = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "all_download:DownloadQueueWakeLock",
            ).apply {
                setReferenceCounted(false)
                // Safety ceiling of 4 hours so wake lock can never leak indefinitely
                acquire(4L * 60L * 60L * 1000L)
            }
            wakeLock = wl
        }
    }

    private fun releaseWakeLock() {
        runCatching {
            wakeLock?.let { wl ->
                if (wl.isHeld) wl.release()
            }
            wakeLock = null
        }
    }

    private fun stopSelfClean() {
        isServiceRunning = false
        releaseWakeLock()
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        }
        stopSelf()
    }

    override fun onDestroy() {
        isServiceRunning = false
        releaseWakeLock()
        super.onDestroy()
    }
}
