package com.droidhouse.companion

import android.content.ContentValues
import android.content.Context
import android.provider.Telephony
import android.util.Log
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.abs

/**
 * Remembers messages this app has sent.
 *
 * The problem it solves: `SmsManager.sendTextMessage` puts a message on the
 * radio but does **not** write it to the SMS provider. Only the device's
 * default SMS app is allowed to do that. So a message DroidHouse sends is
 * genuinely delivered, yet completely absent from `content://sms` — meaning the
 * Mac's next thread fetch returns a conversation with no trace of it.
 *
 * Two mitigations, in order:
 *   1. try a real provider insert — succeeds when the companion happens to be
 *      the default SMS app, in which case the message becomes permanent and
 *      visible to every app on the phone;
 *   2. otherwise keep it here, and merge it into thread reads so the Mac (and
 *      the companion UI) show an accurate conversation for the session.
 */
object SentOutbox {

    private const val TAG = "SentOutbox"
    private const val MAX_RETAINED = 400

    /** Milliseconds within which an outbox entry and a provider row are "the same". */
    private const val DEDUPE_WINDOW_MS = 90_000L

    data class SentMessage(
        val id: String,
        val threadId: String,
        val address: String,
        val body: String,
        val timestamp: Long,
        val persistedToProvider: Boolean
    )

    private val sent = CopyOnWriteArrayList<SentMessage>()

    /**
     * Records a successful send, attempting a provider insert first.
     * Returns the thread id the message was filed under.
     */
    fun record(context: Context, address: String, body: String): String {
        val timestamp = System.currentTimeMillis()

        // Resolving (or creating) the canonical thread id means the Mac can ask
        // for this conversation by the same id the provider uses.
        val threadId = runCatching {
            Telephony.Threads.getOrCreateThreadId(context, address).toString()
        }.getOrElse {
            Log.w(TAG, "Could not resolve a thread id for $address", it)
            address
        }

        val persisted = insertIntoProvider(context, address, body, timestamp, threadId)

        sent.add(
            0,
            SentMessage(
                id = "dh-sent-$timestamp-${body.hashCode()}",
                threadId = threadId,
                address = address,
                body = body,
                timestamp = timestamp,
                persistedToProvider = persisted
            )
        )

        while (sent.size > MAX_RETAINED) {
            sent.removeAt(sent.size - 1)
        }

        return threadId
    }

    /**
     * Merges outbox entries for a thread into rows read from the provider,
     * skipping any the provider already reports.
     */
    fun merge(threadId: String, providerMessages: List<MessagePayload>): List<MessagePayload> {
        val mine = sent.filter { it.threadId == threadId }
        if (mine.isEmpty()) return providerMessages

        val extras = mine.filterNot { candidate ->
            providerMessages.any { existing ->
                existing.isOutgoing &&
                    existing.body == candidate.body &&
                    abs(parseTimestamp(existing.timestamp) - candidate.timestamp) < DEDUPE_WINDOW_MS
            }
        }

        if (extras.isEmpty()) return providerMessages

        val converted = extras.map { message ->
            MessagePayload(
                id = message.id,
                conversationId = threadId,
                sender = "Me",
                body = message.body,
                timestamp = SmsRepository.formatTimestamp(message.timestamp),
                isOutgoing = true
            )
        }

        return (providerMessages + converted).sortedBy { parseTimestamp(it.timestamp) }
    }

    /** Most recent outbox entry for a thread, for conversation snippets. */
    fun latestFor(threadId: String): SentMessage? =
        sent.filter { it.threadId == threadId }.maxByOrNull { it.timestamp }

    fun all(): List<SentMessage> = sent.toList()

    fun count(): Int = sent.size

    // ------------------------------------------------------------- internals

    private fun insertIntoProvider(
        context: Context,
        address: String,
        body: String,
        timestamp: Long,
        threadId: String
    ): Boolean {
        // Cheap pre-check: skip the attempt entirely unless we're the default
        // SMS app, so we don't log a SecurityException on every single send.
        val defaultPackage = runCatching {
            Telephony.Sms.getDefaultSmsPackage(context)
        }.getOrNull()

        if (defaultPackage != context.packageName) return false

        val values = ContentValues().apply {
            put(Telephony.Sms.ADDRESS, address)
            put(Telephony.Sms.BODY, body)
            put(Telephony.Sms.DATE, timestamp)
            put(Telephony.Sms.READ, 1)
            put(Telephony.Sms.SEEN, 1)
            put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_SENT)
            threadId.toLongOrNull()?.let { put(Telephony.Sms.THREAD_ID, it) }
        }

        return runCatching {
            context.contentResolver.insert(Telephony.Sms.Sent.CONTENT_URI, values) != null
        }.getOrElse {
            Log.i(TAG, "Provider insert refused; keeping the message in the outbox", it)
            false
        }
    }

    private fun parseTimestamp(iso: String): Long =
        runCatching { SmsRepository.parseTimestamp(iso) }.getOrDefault(0L)
}
