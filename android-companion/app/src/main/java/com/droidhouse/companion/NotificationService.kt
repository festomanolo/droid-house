package com.droidhouse.companion

import android.content.Context
import android.content.pm.PackageManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.util.concurrent.CopyOnWriteArrayList

data class NotificationMessage(
    val id: String,
    val packageName: String,
    val title: String,
    val text: String,
    val timestamp: Long
)

/**
 * Mirrors the device's notification shade to the Mac.
 *
 * The list is capped and de-duplicated by notification key: apps re-post the
 * same key on every update (progress bars, ongoing calls), and without that
 * guard a single download would flood the buffer.
 */
class NotificationService : NotificationListenerService() {

    companion object {
        private const val TAG = "DHNotificationService"
        private const val MAX_RETAINED = 150

        val capturedNotifications = CopyOnWriteArrayList<NotificationMessage>()

        /** Packages whose notifications are conversations rather than chrome. */
        private val MESSAGING_PACKAGES = setOf(
            "com.google.android.apps.messaging",
            "com.samsung.android.messaging",
            "com.android.mms",
            "com.whatsapp",
            "org.telegram.messenger",
            "com.facebook.orca",
            "com.google.android.gm",
            "com.microsoft.teams",
            "com.discord",
            "com.Slack",
            "org.thoughtcrime.securesms"
        )

        /** Snapshot for the bridge, newest first, with app labels resolved. */
        fun snapshot(context: Context): List<NotificationPayload> {
            val packageManager = context.packageManager
            val labelCache = HashMap<String, String>()

            return capturedNotifications.map { notification ->
                val label = labelCache.getOrPut(notification.packageName) {
                    resolveAppLabel(packageManager, notification.packageName)
                }
                NotificationPayload(
                    id = notification.id,
                    packageName = notification.packageName,
                    appLabel = label,
                    title = notification.title,
                    text = notification.text,
                    timestamp = notification.timestamp,
                    isMessaging = MESSAGING_PACKAGES.contains(notification.packageName)
                )
            }
        }

        private fun resolveAppLabel(packageManager: PackageManager, packageName: String): String =
            runCatching {
                packageManager.getApplicationLabel(
                    packageManager.getApplicationInfo(packageName, 0)
                ).toString()
            }.getOrDefault(packageName)
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(TAG, "Notification listener connected")
        // Seed from whatever is already in the shade, so a Mac that connects
        // mid-session isn't staring at an empty list.
        runCatching { activeNotifications }
            .getOrNull()
            ?.forEach { record(it) }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn?.let { record(it) }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        val key = sbn?.key ?: return
        capturedNotifications.removeAll { it.id == key }
    }

    private fun record(sbn: StatusBarNotification) {
        // Our own foreground-service notification is noise on the Mac.
        if (sbn.packageName == packageName) return

        val extras = sbn.notification.extras
        val title = extras.getCharSequence("android.title")?.toString().orEmpty()
        val text = extras.getCharSequence("android.text")?.toString()
            ?: extras.getCharSequence("android.bigText")?.toString()
            ?: ""

        if (title.isEmpty() && text.isEmpty()) return

        val message = NotificationMessage(
            id = sbn.key,
            packageName = sbn.packageName,
            title = title,
            text = text,
            timestamp = sbn.postTime
        )

        // Replace-in-place on re-post so updates don't accumulate duplicates.
        capturedNotifications.removeAll { it.id == message.id }
        capturedNotifications.add(0, message)

        while (capturedNotifications.size > MAX_RETAINED) {
            capturedNotifications.removeAt(capturedNotifications.size - 1)
        }
    }
}
