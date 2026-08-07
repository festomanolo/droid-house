package com.droidhouse.companion

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.ContextCompat
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.call
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.ApplicationEngine
import io.ktor.server.engine.embeddedServer
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.plugins.cors.routing.CORS
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.response.respondFile
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.serialization.json.Json
import java.io.File

/**
 * The local bridge. Binds Ktor's CIO engine to 127.0.0.1:8080 and is reached
 * from the Mac through `adb forward tcp:8080 tcp:8080`.
 *
 * Binding to loopback only is deliberate: the socket is meant to be reachable
 * through the adb tunnel and by nothing else on the Wi-Fi network.
 */
class BridgeServer(
    private val appContext: Context,
    private val clipboardWatcher: ClipboardWatcher,
    private val screenshotWatcher: ScreenshotWatcher,
    private val port: Int = 8080
) {

    companion object {
        private const val TAG = "BridgeServer"
        const val PROTOCOL_VERSION = 1
    }

    private val smsRepository = SmsRepository(appContext)
    private var engine: ApplicationEngine? = null

    @Volatile
    var isRunning: Boolean = false
        private set

    fun start() {
        if (isRunning) return

        val server = embeddedServer(CIO, port = port, host = "127.0.0.1") {
            install(ContentNegotiation) {
                json(
                    Json {
                        prettyPrint = false
                        ignoreUnknownKeys = true
                        encodeDefaults = true
                    }
                )
            }

            install(CORS) {
                anyHost()
                allowHeader("Content-Type")
            }

            install(StatusPages) {
                exception<Throwable> { call, cause ->
                    Log.e(TAG, "Unhandled bridge error on ${call.request.local.uri}", cause)
                    call.respond(
                        HttpStatusCode.InternalServerError,
                        SimpleResult(false, cause.message ?: cause.javaClass.simpleName)
                    )
                }
            }

            routing {

                // ------------------------------------------------------ status

                get("/api/status") {
                    call.respond(buildStatus())
                }

                get("/api/health") {
                    call.respond(SimpleResult(true, "ok"))
                }

                // --------------------------------------------------- clipboard

                get("/api/clipboard") {
                    val (text, timestamp) = clipboardWatcher.effectiveText()
                    call.respond(
                        ClipboardPayload(
                            text = text,
                            timestamp = timestamp,
                            source = ClipboardBridge.captureSource,
                            // Tells the Mac whether a background read is even
                            // possible, so its UI can explain the situation
                            // instead of looking broken.
                            backgroundReadable = false
                        )
                    )
                }

                post("/api/clipboard") {
                    val request = call.receive<SetClipboardRequest>()
                    clipboardWatcher.setClipboard(request.text)
                    call.respond(SimpleResult(true, "Clipboard updated"))
                }

                // ---------------------------------------------------- messages

                get("/api/messages") {
                    if (!smsRepository.hasSmsAccess()) {
                        call.respond(HttpStatusCode.Forbidden, emptyList<ConversationPayload>())
                        return@get
                    }
                    call.respond(smsRepository.conversations())
                }

                get("/api/messages/{threadId}") {
                    val threadId = call.parameters["threadId"]
                    if (threadId.isNullOrBlank()) {
                        call.respond(HttpStatusCode.BadRequest, emptyList<MessagePayload>())
                        return@get
                    }
                    call.respond(smsRepository.messages(threadId))
                }

                post("/api/messages/send") {
                    val request = call.receive<SendMessageRequest>()

                    if (request.recipient.isBlank() || request.body.isBlank()) {
                        call.respond(
                            HttpStatusCode.BadRequest,
                            SimpleResult(false, "recipient and body are both required")
                        )
                        return@post
                    }

                    if (!hasPermission(Manifest.permission.SEND_SMS)) {
                        call.respond(
                            HttpStatusCode.Forbidden,
                            SimpleResult(false, "SEND_SMS has not been granted to the companion app")
                        )
                        return@post
                    }

                    // A thread id resolves to its address; a bare number is used
                    // as-is. This lets the Mac send using whichever it has.
                    val destination = smsRepository.addressForThread(request.recipient)
                        ?: request.recipient

                    val result = runCatching {
                        val manager = appContext.getSystemService(SmsManager::class.java)
                            ?: throw IllegalStateException("SmsManager unavailable on this device")

                        // Long messages must be split or the platform silently
                        // truncates them at 160 characters.
                        val parts = manager.divideMessage(request.body)
                        if (parts.size > 1) {
                            manager.sendMultipartTextMessage(destination, null, parts, null, null)
                        } else {
                            manager.sendTextMessage(destination, null, request.body, null, null)
                        }
                    }

                    result.fold(
                        onSuccess = {
                            // Record it so the thread reflects the send even
                            // though the platform won't let us write to the
                            // SMS provider unless we're the default SMS app.
                            val threadId = SentOutbox.record(appContext, destination, request.body)
                            call.respond(SimpleResult(true, "Sent to $destination (thread $threadId)"))
                        },
                        onFailure = { error ->
                            Log.e(TAG, "SMS send failed", error)
                            call.respond(
                                HttpStatusCode.InternalServerError,
                                SimpleResult(false, error.message ?: "SMS send failed")
                            )
                        }
                    )
                }

                // ----------------------------------------------- notifications

                get("/api/notifications") {
                    call.respond(NotificationService.snapshot(appContext))
                }

                // ------------------------------------------------- screenshots

                get("/api/screenshots") {
                    call.respond(
                        screenshotWatcher.screenshotList.map { shot ->
                            ScreenshotPayload(
                                path = shot.path,
                                filename = shot.filename,
                                timestamp = shot.timestamp,
                                sizeBytes = runCatching { File(shot.path).length() }.getOrDefault(0L)
                            )
                        }
                    )
                }

                /**
                 * Serves a screenshot's bytes so the Mac gallery can render a
                 * real thumbnail. Only files inside the directories the watcher
                 * actually indexed are servable — the path comes off the
                 * network, so it must never be trusted as a free-form file read.
                 */
                get("/api/screenshots/file") {
                    val requested = call.request.queryParameters["path"].orEmpty()

                    val known = screenshotWatcher.screenshotList.any { it.path == requested }
                    if (requested.isEmpty() || !known) {
                        call.respond(
                            HttpStatusCode.Forbidden,
                            SimpleResult(false, "Not an indexed screenshot")
                        )
                        return@get
                    }

                    val file = File(requested)
                    if (!file.isFile || !file.canRead()) {
                        call.respond(HttpStatusCode.NotFound, SimpleResult(false, "File is gone"))
                        return@get
                    }

                    // Ktor infers the content type from the extension.
                    call.respondFile(file)
                }

                // ------------------------------------------------------ roster

                get("/api/roster/{table}") {
                    val table = call.parameters["table"].orEmpty()
                    val uri = rosterUri(table)
                    if (uri == null) {
                        call.respond(
                            HttpStatusCode.NotFound,
                            SimpleResult(false, "Unknown roster table '$table'")
                        )
                        return@get
                    }
                    call.respond(smsRepository.rawTable(uri, table))
                }

                // ---------------------------------------------------- aerocast

                get("/api/aerocast/status") {
                    call.respond(AeroCastService.stateSnapshot())
                }

                post("/api/aerocast/start") {
                    val request = runCatching { call.receive<AeroCastRequest>() }
                        .getOrDefault(AeroCastRequest())

                    val started = AeroCastService.requestStart(
                        context = appContext,
                        audio = request.audio,
                        bitRate = request.bitRate,
                        maxWidth = request.maxWidth
                    )

                    if (started) {
                        call.respond(AeroCastService.stateSnapshot())
                    } else {
                        call.respond(
                            HttpStatusCode.ServiceUnavailable,
                            SimpleResult(false, "Could not start AeroCast — open the companion app and approve screen capture.")
                        )
                    }
                }

                post("/api/aerocast/stop") {
                    AeroCastService.requestStop(appContext)
                    call.respond(SimpleResult(true, "AeroCast stopped"))
                }
            }
        }

        server.start(wait = false)
        engine = server
        isRunning = true
        Log.i(TAG, "Bridge listening on 127.0.0.1:$port")
    }

    fun stop() {
        if (!isRunning) return
        runCatching { engine?.stop(500, 1500) }
            .onFailure { Log.w(TAG, "Bridge shutdown was not clean", it) }
        engine = null
        isRunning = false
    }

    // ------------------------------------------------------------- internals

    private fun buildStatus() = StatusPayload(
        status = "online",
        app = "DroidHouse Companion",
        version = "2.0",
        protocolVersion = PROTOCOL_VERSION,
        notificationAccess = hasNotificationAccess(),
        smsAccess = smsRepository.hasSmsAccess(),
        aeroCastAvailable = true,
        aeroCastStreaming = AeroCastService.isStreaming,
        deviceModel = "${Build.MANUFACTURER} ${Build.MODEL}",
        androidRelease = Build.VERSION.RELEASE ?: "",
        sdkInt = Build.VERSION.SDK_INT
    )

    private fun rosterUri(table: String): Uri? = when (table.lowercase()) {
        "contacts" -> ContactsUri.DATA
        "calllog", "call_log" -> ContactsUri.CALL_LOG
        "sms" -> ContactsUri.SMS
        else -> null
    }

    private fun hasPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(appContext, permission) == PackageManager.PERMISSION_GRANTED

    private fun hasNotificationAccess(): Boolean {
        val enabled = Settings.Secure.getString(
            appContext.contentResolver,
            "enabled_notification_listeners"
        ).orEmpty()
        return enabled.contains(appContext.packageName)
    }

    private object ContactsUri {
        val DATA: Uri = Uri.parse("content://com.android.contacts/data")
        val CALL_LOG: Uri = Uri.parse("content://call_log/calls")
        val SMS: Uri = Uri.parse("content://sms")
    }
}
