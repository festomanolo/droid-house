package com.droidhouse.companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * The always-on half of the companion: keeps the Ktor bridge, the clipboard
 * monitor and the screenshot watcher alive as a foreground service so Android
 * doesn't reclaim them the moment the UI is dismissed.
 */
class DroidHouseCompanion : Service() {

    private var server: BridgeServer? = null
    private var clipboardWatcher: ClipboardWatcher? = null
    private var screenshotWatcher: ScreenshotWatcher? = null

    companion object {
        private const val TAG = "DroidHouseCompanion"
        const val CHANNEL_ID = "droidhouse_companion_channel"
        const val NOTIFICATION_ID = 1001
        const val BRIDGE_PORT = 8080

        /** Mirrors the bridge's liveness for the Compose UI to observe. */
        @Volatile
        var isBridgeRunning: Boolean = false
            private set

        @Volatile
        var lastError: String? = null
            private set
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("Starting the bridge…"))

        clipboardWatcher = ClipboardWatcher(applicationContext).apply { start() }
        screenshotWatcher = ScreenshotWatcher().apply { start() }

        val bridge = BridgeServer(
            appContext = applicationContext,
            clipboardWatcher = clipboardWatcher!!,
            screenshotWatcher = screenshotWatcher!!,
            port = BRIDGE_PORT
        )

        try {
            bridge.start()
            server = bridge
            isBridgeRunning = true
            lastError = null
            updateNotification("Bridge live on 127.0.0.1:$BRIDGE_PORT")
        } catch (error: Exception) {
            Log.e(TAG, "Bridge failed to start", error)
            isBridgeRunning = false
            lastError = error.message ?: error.javaClass.simpleName
            updateNotification("Bridge failed: ${lastError}")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Restart if the process is killed — the Mac expects the bridge to
        // simply be there whenever the phone is.
        return START_STICKY
    }

    override fun onDestroy() {
        server?.stop()
        server = null
        isBridgeRunning = false
        clipboardWatcher?.stop()
        screenshotWatcher?.stop()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ------------------------------------------------------------ notification

    private fun buildNotification(text: String): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("DroidHouse Companion")
            .setContentText(text)
            .setSmallIcon(R.drawable.droid)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(openApp)
            .build()
    }

    private fun updateNotification(text: String) {
        runCatching {
            getSystemService(NotificationManager::class.java)
                ?.notify(NOTIFICATION_ID, buildNotification(text))
        }
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "DroidHouse Companion Service",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Keeps the local bridge to your Mac alive"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
    }
}
