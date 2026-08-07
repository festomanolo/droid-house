package com.droidhouse.companion

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire types shared with the macOS app.
 *
 * Field names here are the contract — the Swift side decodes them by name, so
 * renaming a property is a breaking protocol change, not a refactor.
 */

@Serializable
data class StatusPayload(
    val status: String,
    val app: String,
    val version: String,
    val protocolVersion: Int,
    val notificationAccess: Boolean,
    val smsAccess: Boolean,
    val aeroCastAvailable: Boolean,
    val aeroCastStreaming: Boolean,
    val deviceModel: String,
    val androidRelease: String,
    val sdkInt: Int
)

@Serializable
data class ClipboardPayload(
    val text: String,
    val timestamp: Long,
    /** Which route captured this text: listener, share, tile, capture-activity, mac. */
    val source: String = "Android",
    /**
     * False on Android 10+, where only the foreground app or active IME may
     * read the clipboard. The Mac uses this to explain why a background copy
     * on the phone doesn't appear on its own.
     */
    val backgroundReadable: Boolean = false
)

/**
 * A conversation summary. `id` is the SMS thread id as a string so the Mac can
 * ask for the thread back verbatim.
 */
@Serializable
data class ConversationPayload(
    val id: String,
    val name: String,
    val phoneNumber: String,
    val avatarUrl: String? = null,
    val lastMessageSnippet: String,
    /** ISO-8601 UTC, which is what the Swift decoder is configured for. */
    val lastMessageTimestamp: String,
    val unreadCount: Int
)

@Serializable
data class MessagePayload(
    val id: String,
    val conversationId: String,
    val sender: String,
    val body: String,
    val timestamp: String,
    val isOutgoing: Boolean
)

@Serializable
data class SendMessageRequest(
    val recipient: String,
    val body: String
)

@Serializable
data class SetClipboardRequest(
    val text: String
)

@Serializable
data class ScreenshotPayload(
    val path: String,
    val filename: String,
    val timestamp: Long,
    val sizeBytes: Long
)

@Serializable
data class NotificationPayload(
    val id: String,
    val packageName: String,
    val appLabel: String,
    val title: String,
    val text: String,
    val timestamp: Long,
    val isMessaging: Boolean
)

@Serializable
data class AeroCastRequest(
    val audio: Boolean = true,
    val video: Boolean = true,
    @SerialName("bitRate") val bitRate: Int? = null,
    @SerialName("maxWidth") val maxWidth: Int? = null
)

@Serializable
data class AeroCastStatePayload(
    val streaming: Boolean,
    val awaitingConsent: Boolean,
    val port: Int,
    val width: Int,
    val height: Int,
    val audioEnabled: Boolean,
    val message: String
)

/**
 * Sent as the first AeroCast packet so the Mac can size its window and
 * configure its audio graph before a single frame arrives.
 */
@Serializable
data class StreamInfoPayload(
    val width: Int,
    val height: Int,
    val sampleRate: Int,
    val channels: Int,
    val videoBitRate: Int? = null,
    val frameRate: Int? = null,
    val deviceName: String? = null
)

@Serializable
data class SimpleResult(
    val success: Boolean,
    val message: String = ""
)

/**
 * A raw provider dump. Columns and rows are positional and un-normalised — one
 * row in, one row out — because the macOS Roster viewer's entire contract is
 * that related entries stay separate.
 */
@Serializable
data class RosterPayload(
    val name: String,
    val columns: List<String>,
    val rows: List<List<String>>,
    val truncated: Boolean = false
)
