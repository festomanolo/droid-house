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
import io.ktor.server.application.ApplicationCallPipeline
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.call
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.ApplicationEngine
import io.ktor.server.engine.embeddedServer
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.plugins.cors.routing.CORS
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.request.path
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.response.respondFile
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.serialization.json.Json
import java.io.File

/**
 * The bridge. Ktor's CIO engine on port 8080, reached from the Mac either
 * through `adb forward tcp:8080 tcp:8080` or directly over Wi-Fi.
 *
 * With Wi-Fi mode off it binds loopback only, so nothing but the adb tunnel
 * can reach it. With it on it binds every interface, and any caller that isn't
 * loopback must present a token from pairing (see [LanAccess]) — only
 * `/api/hello` and `/api/pair` answer without one.
 */
class BridgeServer(
    private val appContext: Context,
    private val clipboardWatcher: ClipboardWatcher,
    private val screenshotWatcher: ScreenshotWatcher,
    private val port: Int = 8080
) {

    companion object {
        private const val TAG = "BridgeServer"
        /** 2 adds Wi-Fi pairing, the file API and remote input. */
        const val PROTOCOL_VERSION = 2
        const val VERSION = "2.2"
    }

    private val smsRepository = SmsRepository(appContext)
    private var engine: ApplicationEngine? = null

    @Volatile
    var isRunning: Boolean = false
        private set

    fun start() {
        if (isRunning) return

        val host = LanAccess.bindHost()
        val server = embeddedServer(CIO, port = port, host = host) {
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

            // Loopback is the adb tunnel, which adb already authenticated.
            // Everything else needs a paired token.
            intercept(ApplicationCallPipeline.Plugins) {
                val path = call.request.path()
                if (path == "/api/hello" || path == "/api/pair") return@intercept
                if (LanAccess.isLoopback(call.request.local.remoteAddress)) return@intercept

                val token = LanAccess.bearerToken(call.request.headers["Authorization"])
                if (!LanAccess.isAuthorized(token)) {
                    call.respond(
                        HttpStatusCode.Unauthorized,
                        SimpleResult(false, "This Mac isn't paired. Pair it with the code shown in the DroidHouse app.")
                    )
                    finish()
                }
            }

            routing {

                // ------------------------------------------------------ pairing

                get("/api/hello") {
                    call.respond(
                        HelloPayload(
                            app = "DroidHouse Companion",
                            version = VERSION,
                            protocolVersion = PROTOCOL_VERSION,
                            deviceId = LanAccess.deviceId,
                            deviceModel = "${Build.MANUFACTURER} ${Build.MODEL}",
                            androidRelease = Build.VERSION.RELEASE ?: "",
                            pairingRequired = !LanAccess.isLoopback(call.request.local.remoteAddress)
                        )
                    )
                }

                post("/api/pair") {
                    val request = runCatching { call.receive<PairRequest>() }.getOrNull()
                    val token = request?.let { LanAccess.pair(it.code, it.clientName) }
                    if (token == null) {
                        call.respond(
                            HttpStatusCode.Forbidden,
                            SimpleResult(false, "That code doesn't match the one on the phone.")
                        )
                        return@post
                    }
                    call.respond(PairResponse(token, LanAccess.deviceId, "${Build.MANUFACTURER} ${Build.MODEL}"))
                }

                // ------------------------------------------- files & remote input

                FileBridge.install(this, appContext)
                RemoteInputService.install(this, appContext)

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

                post("/api/notifications/reply") {
                    val request = call.receive<NotificationReplyRequest>()
                    if (request.id.isBlank() || request.text.isBlank()) {
                        call.respond(
                            HttpStatusCode.BadRequest,
                            SimpleResult(false, "id and text are both required")
                        )
                        return@post
                    }

                    when (val result = NotificationService.reply(appContext, request.id, request.text)) {
                        NotificationReplyResult.Sent ->
                            call.respond(SimpleResult(true, "Reply sent"))
                        NotificationReplyResult.Gone ->
                            call.respond(
                                HttpStatusCode.Gone,
                                SimpleResult(false, "That notification is no longer on the phone")
                            )
                        is NotificationReplyResult.Failed ->
                            call.respond(
                                HttpStatusCode.InternalServerError,
                                SimpleResult(false, result.reason)
                            )
                    }
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

                // ------------------------------------------------------ studio
                get("/api/studio/status") {
                    call.respond(StudioStreamService.stateSnapshot())
                }

                get("/api/studio/cameras") {
                    call.respond(StudioStreamService.enumerateCameras(appContext))
                }

                post("/api/studio/start") {
                    val request = runCatching { call.receive<StudioStartRequest>() }
                        .getOrDefault(StudioStartRequest())

                    val started = StudioStreamService.requestStart(
                        context = appContext,
                        camera = request.camera,
                        lensId = request.lensId,
                        resolution = request.resolution,
                        fps = request.fps,
                        bitRate = request.bitRate,
                        mic = request.mic,
                        micUnprocessed = request.micUnprocessed
                    )

                    if (started) {
                        call.respond(StudioStreamService.stateSnapshot())
                    } else {
                        call.respond(
                            HttpStatusCode.ServiceUnavailable,
                            SimpleResult(false, "Could not start Studio Broadcast")
                        )
                    }
                }

                post("/api/studio/stop") {
                    StudioStreamService.requestStop(appContext)
                    call.respond(SimpleResult(true, "Studio Broadcast stopped"))
                }

                post("/api/studio/lens") {
                    val request = runCatching { call.receive<StudioLensRequest>() }.getOrNull()
                    if (request != null) {
                        val success = StudioStreamService.switchLens(request.lensId)
                        call.respond(SimpleResult(success, if (success) "Switched lens to ${request.lensId}" else "Failed to switch lens"))
                    } else {
                        call.respond(HttpStatusCode.BadRequest, SimpleResult(false, "Invalid lens request body"))
                    }
                }

                post("/api/studio/zoom") {
                    val request = runCatching { call.receive<StudioZoomRequest>() }.getOrNull()
                    if (request != null) {
                        val success = StudioStreamService.setZoom(request.zoomRatio)
                        call.respond(SimpleResult(success, if (success) "Zoom set to ${request.zoomRatio}x" else "Failed to set zoom"))
                    } else {
                        call.respond(HttpStatusCode.BadRequest, SimpleResult(false, "Invalid zoom request body"))
                    }
                }

                post("/api/studio/torch") {
                    val request = runCatching { call.receive<StudioTorchRequest>() }.getOrNull()
                    if (request != null) {
                        val success = StudioStreamService.setTorch(request.enabled)
                        call.respond(SimpleResult(success, if (success) "Torch set to ${request.enabled}" else "Failed to set torch"))
                    } else {
                        call.respond(HttpStatusCode.BadRequest, SimpleResult(false, "Invalid torch request body"))
                    }
                }
            }
        }

        server.start(wait = false)
        engine = server
        isRunning = true
        Log.i(TAG, "Bridge listening on $host:$port")
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
        version = VERSION,
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
