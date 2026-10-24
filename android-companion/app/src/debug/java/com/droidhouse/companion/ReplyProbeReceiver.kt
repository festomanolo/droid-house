package com.droidhouse.companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Debug builds only. Posts a notification with an inline reply action, then
 * logs whatever reply arrives, so the Mac → phone reply path can be tested end
 * to end without sending anything to a real contact.
 */
class ReplyProbeReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "ReplyProbe"
        private const val ACTION_POST = "com.droidhouse.companion.debug.POST_PROBE"
        private const val ACTION_REPLY = "com.droidhouse.companion.debug.REPLY_PROBE"
        private const val CHANNEL = "debug_reply_probe"
        private const val RESULT_KEY = "probe_reply"
        private const val NOTIFICATION_ID = 4242
    }

    override fun onReceive(context: Context, intent: Intent) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Reply probe (debug)", NotificationManager.IMPORTANCE_DEFAULT)
        )

        when (intent.action) {
            ACTION_POST -> post(context, manager, intent.getStringExtra("text") ?: "Reply to me from the Mac")
            ACTION_REPLY -> {
                val reply = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(RESULT_KEY)
                Log.i(TAG, "got reply: $reply")
                manager.cancel(NOTIFICATION_ID)
            }
        }
    }

    private fun post(context: Context, manager: NotificationManager, text: String) {
        val replyIntent = PendingIntent.getBroadcast(
            context, 0,
            Intent(context, ReplyProbeReceiver::class.java).setAction(ACTION_REPLY),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )
        val action = Notification.Action.Builder(null, "Reply", replyIntent)
            .addRemoteInput(RemoteInput.Builder(RESULT_KEY).setLabel("Reply").build())
            .build()

        manager.notify(
            NOTIFICATION_ID,
            Notification.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.sym_action_chat)
                .setContentTitle("Reply probe")
                .setContentText(text)
                .addAction(action)
                .build()
        )
        Log.i(TAG, "posted")
    }
}
