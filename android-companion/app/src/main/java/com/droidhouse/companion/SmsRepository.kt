package com.droidhouse.companion

import android.Manifest
import android.content.ContentResolver
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.provider.ContactsContract
import android.provider.Telephony
import android.util.Log
import androidx.core.content.ContextCompat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Reads SMS threads and messages straight out of Telephony's content provider.
 *
 * Everything here is best-effort: if READ_SMS has not been granted the queries
 * return empty lists rather than throwing, so the bridge stays up and the Mac
 * can show an honest "no access" state instead of a dead endpoint.
 */
class SmsRepository(private val context: Context) {

    private val resolver: ContentResolver get() = context.contentResolver

    /** Cache of address -> display name, so we don't re-query per message. */
    private val contactNameCache = HashMap<String, String>()

    companion object {
        private const val TAG = "SmsRepository"
        private const val MAX_THREADS = 200
        private const val MAX_MESSAGES = 500

        private val iso8601: ThreadLocal<SimpleDateFormat> = object : ThreadLocal<SimpleDateFormat>() {
            override fun initialValue(): SimpleDateFormat =
                SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
                    timeZone = TimeZone.getTimeZone("UTC")
                }
        }

        fun formatTimestamp(millis: Long): String =
            iso8601.get()!!.format(Date(millis))

        /** Inverse of [formatTimestamp], used when reconciling the outbox. */
        fun parseTimestamp(iso: String): Long =
            iso8601.get()!!.parse(iso)?.time ?: 0L
    }

    fun hasSmsAccess(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_SMS) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasContactsAccess(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED

    // ---------------------------------------------------------------- threads

    /**
     * One entry per SMS thread, newest first.
     *
     * Android exposes a conversations view, but it omits the address, so we
     * walk it and then resolve each thread's most recent message for the
     * number and snippet.
     */
    fun conversations(): List<ConversationPayload> {
        if (!hasSmsAccess()) return emptyList()

        val results = ArrayList<ConversationPayload>()

        val projection = arrayOf(
            Telephony.Sms.Conversations.THREAD_ID,
            Telephony.Sms.Conversations.SNIPPET,
            Telephony.Sms.Conversations.MESSAGE_COUNT
        )

        runCatching {
            resolver.query(
                Telephony.Sms.Conversations.CONTENT_URI,
                projection,
                null,
                null,
                "${Telephony.Sms.Conversations.DEFAULT_SORT_ORDER} LIMIT $MAX_THREADS"
            )
        }.getOrNull()?.use { cursor ->
            val threadIdIndex = cursor.getColumnIndex(Telephony.Sms.Conversations.THREAD_ID)
            val snippetIndex = cursor.getColumnIndex(Telephony.Sms.Conversations.SNIPPET)

            while (cursor.moveToNext()) {
                val threadId = if (threadIdIndex >= 0) cursor.getLong(threadIdIndex) else continue
                val snippet = if (snippetIndex >= 0) cursor.getString(snippetIndex).orEmpty() else ""

                val latest = latestMessageInThread(threadId) ?: continue
                val address = latest.address
                val displayName = resolveContactName(address) ?: address

                // A message we sent but couldn't persist is still the newest
                // thing in the thread, so it must own the snippet.
                val outboxLatest = SentOutbox.latestFor(threadId.toString())
                val useOutbox = outboxLatest != null && outboxLatest.timestamp > latest.date

                results.add(
                    ConversationPayload(
                        id = threadId.toString(),
                        name = displayName,
                        phoneNumber = address,
                        lastMessageSnippet = when {
                            useOutbox -> outboxLatest!!.body
                            snippet.isNotEmpty() -> snippet
                            else -> latest.body
                        },
                        lastMessageTimestamp = formatTimestamp(
                            if (useOutbox) outboxLatest!!.timestamp else latest.date
                        ),
                        unreadCount = unreadCount(threadId)
                    )
                )
            }
        }

        return results.sortedByDescending { it.lastMessageTimestamp }
    }

    private data class LatestMessage(val address: String, val body: String, val date: Long)

    private fun latestMessageInThread(threadId: Long): LatestMessage? {
        val projection = arrayOf(
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE
        )
        return runCatching {
            resolver.query(
                Telephony.Sms.CONTENT_URI,
                projection,
                "${Telephony.Sms.THREAD_ID} = ?",
                arrayOf(threadId.toString()),
                "${Telephony.Sms.DATE} DESC LIMIT 1"
            )
        }.getOrNull()?.use { cursor ->
            if (!cursor.moveToFirst()) return@use null
            LatestMessage(
                address = cursor.stringOr(Telephony.Sms.ADDRESS, ""),
                body = cursor.stringOr(Telephony.Sms.BODY, ""),
                date = cursor.longOr(Telephony.Sms.DATE, System.currentTimeMillis())
            )
        }
    }

    private fun unreadCount(threadId: Long): Int = runCatching {
        resolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms._ID),
            "${Telephony.Sms.THREAD_ID} = ? AND ${Telephony.Sms.READ} = 0",
            arrayOf(threadId.toString()),
            null
        )
    }.getOrNull()?.use { it.count } ?: 0

    // --------------------------------------------------------------- messages

    /**
     * Full thread, oldest first, which is the order the chat pane renders.
     *
     * Provider rows are merged with anything this app has sent but couldn't
     * write to the provider — see [SentOutbox] for why that gap exists.
     */
    fun messages(threadId: String): List<MessagePayload> {
        if (!hasSmsAccess()) return SentOutbox.merge(threadId, emptyList())

        val projection = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.TYPE
        )

        val out = ArrayList<MessagePayload>()

        runCatching {
            resolver.query(
                Telephony.Sms.CONTENT_URI,
                projection,
                "${Telephony.Sms.THREAD_ID} = ?",
                arrayOf(threadId),
                "${Telephony.Sms.DATE} DESC LIMIT $MAX_MESSAGES"
            )
        }.getOrNull()?.use { cursor ->
            while (cursor.moveToNext()) {
                val type = cursor.intOr(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_INBOX)
                // SENT / OUTBOX / QUEUED all originate from this device.
                val isOutgoing = type == Telephony.Sms.MESSAGE_TYPE_SENT ||
                    type == Telephony.Sms.MESSAGE_TYPE_OUTBOX ||
                    type == Telephony.Sms.MESSAGE_TYPE_QUEUED

                val address = cursor.stringOr(Telephony.Sms.ADDRESS, "")

                out.add(
                    MessagePayload(
                        id = cursor.stringOr(Telephony.Sms._ID, System.nanoTime().toString()),
                        conversationId = threadId,
                        sender = if (isOutgoing) "Me" else (resolveContactName(address) ?: address),
                        body = cursor.stringOr(Telephony.Sms.BODY, ""),
                        timestamp = formatTimestamp(
                            cursor.longOr(Telephony.Sms.DATE, System.currentTimeMillis())
                        ),
                        isOutgoing = isOutgoing
                    )
                )
            }
        }

        return SentOutbox.merge(threadId, out.reversed())
    }

    /** Address of a thread, so a reply can be routed without the Mac guessing. */
    fun addressForThread(threadId: String): String? {
        val id = threadId.toLongOrNull() ?: return null
        return latestMessageInThread(id)?.address
    }

    // --------------------------------------------------------------- contacts

    private fun resolveContactName(address: String): String? {
        if (address.isBlank()) return null
        contactNameCache[address]?.let { return it }
        if (!hasContactsAccess()) return null

        val uri = Uri.withAppendedPath(
            ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
            Uri.encode(address)
        )

        val name = runCatching {
            resolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null, null, null
            )
        }.getOrNull()?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }

        if (name != null) contactNameCache[address] = name
        return name
    }

    // ----------------------------------------------------------------- roster

    /**
     * Dumps a provider table verbatim: every column the cursor exposes, every
     * row it returns, in cursor order.
     *
     * Nothing is joined, grouped or de-duplicated. A contact with four numbers
     * yields four rows here, which is exactly what the Mac's Roster viewer is
     * built to display.
     */
    fun rawTable(uri: Uri, name: String, limit: Int = 5000): RosterPayload {
        val columns = ArrayList<String>()
        val rows = ArrayList<List<String>>()
        var truncated = false

        runCatching { resolver.query(uri, null, null, null, null) }
            .getOrElse { error ->
                Log.w(TAG, "rawTable($uri) failed", error)
                null
            }
            ?.use { cursor ->
                columns.addAll(cursor.columnNames)
                while (cursor.moveToNext()) {
                    if (rows.size >= limit) {
                        truncated = true
                        break
                    }
                    val row = ArrayList<String>(columns.size)
                    for (index in columns.indices) {
                        row.add(cursor.safeString(index))
                    }
                    rows.add(row)
                }
            }

        return RosterPayload(name = name, columns = columns, rows = rows, truncated = truncated)
    }

    // ---------------------------------------------------------------- helpers

    private fun Cursor.stringOr(column: String, fallback: String): String {
        val index = getColumnIndex(column)
        if (index < 0 || isNull(index)) return fallback
        return getString(index) ?: fallback
    }

    private fun Cursor.longOr(column: String, fallback: Long): Long {
        val index = getColumnIndex(column)
        if (index < 0 || isNull(index)) return fallback
        return getLong(index)
    }

    private fun Cursor.intOr(column: String, fallback: Int): Int {
        val index = getColumnIndex(column)
        if (index < 0 || isNull(index)) return fallback
        return getInt(index)
    }

    /** Reads any column type as text; BLOBs become a size marker, not garbage. */
    private fun Cursor.safeString(index: Int): String = when (getType(index)) {
        Cursor.FIELD_TYPE_NULL -> ""
        Cursor.FIELD_TYPE_INTEGER -> getLong(index).toString()
        Cursor.FIELD_TYPE_FLOAT -> getDouble(index).toString()
        Cursor.FIELD_TYPE_STRING -> getString(index).orEmpty()
        Cursor.FIELD_TYPE_BLOB -> "<blob ${getBlob(index)?.size ?: 0}B>"
        else -> ""
    }
}
