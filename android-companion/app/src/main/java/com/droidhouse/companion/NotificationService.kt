package com.droidhouse.companion

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import androidx.core.app.NotificationCompat
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

data class NotificationMessage(
    val id: String,
    val packageName: String,
    val title: String,
    val text: String,
    val timestamp: Long,
    val canReply: Boolean = false,
    val lastFromSelf: Boolean = false
)

sealed class NotificationReplyResult {
    object Sent : NotificationReplyResult()
    /** The notification, or its reply action, is no longer live. */
    object Gone : NotificationReplyResult()
    data class Failed(val reason: String) : NotificationReplyResult()
}

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

        /**
         * The inline-reply action of every live notification that has one,
         * keyed by notification key. Holding the action is what lets the Mac
         * answer a WhatsApp/Instagram/SMS notification as if the user had typed
         * into the shade: the PendingIntent belongs to the posting app, so the
         * reply goes out through that app's own account.
         */
        private val replyActions = ConcurrentHashMap<String, Notification.Action>()

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
            "org.thoughtcrime.securesms",
            "com.whatsapp.w4b",
            "com.instagram.android",
            "com.instagram.barcelona",
            "com.snapchat.android",
            "com.google.android.apps.dynamite",
            "com.viber.voip",
            "jp.naver.line.android",
            "com.skype.raider",
            "com.twitter.android",
            "com.linkedin.android"
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
                    isMessaging = MESSAGING_PACKAGES.contains(notification.packageName),
                    canReply = notification.canReply,
                    lastFromSelf = notification.lastFromSelf
                )
            }
        }

        /**
         * Fires the notification's own reply action with [text] filled into
         * every free-form input — exactly what SystemUI does when the user
         * types into the shade.
         */
        fun reply(context: Context, key: String, text: String): NotificationReplyResult {
            val action = replyActions[key] ?: return NotificationReplyResult.Gone
            val inputs = action.remoteInputs?.filter { it.allowFreeFormInput }.orEmpty()
            if (inputs.isEmpty()) return NotificationReplyResult.Gone

            val results = Bundle().apply {
                inputs.forEach { putCharSequence(it.resultKey, text) }
            }
            val fillIn = Intent().addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
            RemoteInput.addResultsToIntent(inputs.toTypedArray(), fillIn, results)
            RemoteInput.setResultsSource(fillIn, RemoteInput.SOURCE_FREE_FORM_INPUT)

            return try {
                action.actionIntent.send(context, 0, fillIn)
                NotificationReplyResult.Sent
            } catch (canceled: PendingIntent.CanceledException) {
                // The app withdrew the notification (read on the phone, thread
                // deleted) between the Mac's poll and the reply.
                replyActions.remove(key)
                NotificationReplyResult.Gone
            } catch (error: Exception) {
                Log.e(TAG, "Inline reply to $key failed", error)
                NotificationReplyResult.Failed(error.message ?: error.javaClass.simpleName)
            }
        }

        private fun findReplyAction(notification: Notification): Notification.Action? =
            notification.actions?.firstOrNull { action ->
                action.actionIntent != null &&
                    action.remoteInputs?.any { it.allowFreeFormInput } == true
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
        replyActions.remove(key)
    }

    private fun record(sbn: StatusBarNotification) {
        // Our own foreground-service notification is noise on the Mac.
        if (sbn.packageName == packageName) return

        // Group summaries ("5 messages from 2 chats") only restate their
        // children, and their reply action — if any — has no single thread.
        if (sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return

        val extras = sbn.notification.extras
        val title = extras.getCharSequence("android.title")?.toString().orEmpty()
        var text = extras.getCharSequence("android.text")?.toString()
            ?: extras.getCharSequence("android.bigText")?.toString()
            ?: ""

        // Messaging apps describe the thread with MessagingStyle; its newest
        // entry is the real latest message, and its sender says whether that
        // message is the user's own (an app re-posts after we reply).
        var lastFromSelf = false
        runCatching { NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(sbn.notification) }
            .getOrNull()
            ?.let { style ->
                val latest = style.messages.lastOrNull() ?: return@let
                latest.text?.toString()?.takeIf { it.isNotEmpty() }?.let { text = it }
                val sender = latest.person
                lastFromSelf = sender == null ||
                    (sender.key != null && sender.key == style.user.key) ||
                    (sender.key == null && sender.name == style.user.name)
            }

        if (title.isEmpty() && text.isEmpty()) return

        val replyAction = findReplyAction(sbn.notification)
        if (replyAction != null) replyActions[sbn.key] = replyAction else replyActions.remove(sbn.key)

        val message = NotificationMessage(
            id = sbn.key,
            packageName = sbn.packageName,
            title = title,
            text = text,
            timestamp = sbn.postTime,
            canReply = replyAction != null,
            lastFromSelf = lastFromSelf
        )

        // Replace-in-place on re-post so updates don't accumulate duplicates.
        capturedNotifications.removeAll { it.id == message.id }
        capturedNotifications.add(0, message)

        while (capturedNotifications.size > MAX_RETAINED) {
            val evicted = capturedNotifications.removeAt(capturedNotifications.size - 1)
            replyActions.remove(evicted.id)
        }
    }
}
