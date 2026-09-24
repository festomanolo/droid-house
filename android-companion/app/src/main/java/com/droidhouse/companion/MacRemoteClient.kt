package com.droidhouse.companion

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.nio.ByteBuffer
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

// MARK: - Mac Remote Client (Android)
//
// Manages the WebSocket connection from Android to the macOS Remote Host (port 8089)
// over WAN (Tailscale/Internet/DDNS) or local LAN. Handles handshake authentication,
// coalesces trackpad events, decodes live JPEG desktop frames, and monitors RTT latency.

class MacRemoteClient private constructor() {

    enum class ConnectionState {
        DISCONNECTED,
        CONNECTING,
        AUTHENTICATING,
        CONNECTED,
        FAILED
    }

    companion object {
        private const val TAG = "MacRemoteClient"
        private const val PREFS_NAME = "droidhouse_mac_remote_prefs"
        private const val KEY_HOST = "saved_host"
        private const val KEY_PORT = "saved_port"
        private const val KEY_PIN = "saved_pin"

        val shared = MacRemoteClient()
    }

    private val scope = CoroutineScope(Dispatchers.IO + Job())
    private var pingJob: Job? = null

    private val okHttpClient = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS) // Keep-alive WebSocket
        .writeTimeout(5, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    private var webSocket: WebSocket? = null
    private val isConnecting = AtomicBoolean(false)

    @Volatile
    var state: ConnectionState = ConnectionState.DISCONNECTED
        private set

    @Volatile
    var statusMessage: String = "Disconnected"
        private set

    @Volatile
    var connectedMacName: String? = null
        private set

    @Volatile
    var screenWidth: Double = 1920.0
        private set

    @Volatile
    var screenHeight: Double = 1080.0
        private set

    @Volatile
    var rttLatencyMs: Long = 0
        private set

    @Volatile
    var latestScreenFrame: Bitmap? = null
        private set

    @Volatile
    var isScreenStreaming: Boolean = false
        private set

    // Trackpad sensitivity factor (0.5 to 2.5)
    var trackpadSensitivity: Float = 1.25f

    // Live Real-Time Cursor Tracking
    @Volatile
    var cursorXRatio: Float = 0.5f
        private set

    @Volatile
    var cursorYRatio: Float = 0.5f
        private set

    @Volatile
    var isCursorDown: Boolean = false
        private set

    // Listeners
    var onStateChanged: ((ConnectionState, String) -> Unit)? = null
    var onFrameReceived: ((Bitmap) -> Unit)? = null
    var onCursorMoved: ((Float, Float, Boolean) -> Unit)? = null

    // Preferences
    fun getSavedHost(context: Context): String {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_HOST, "") ?: ""
    }

    fun getSavedPort(context: Context): Int {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getInt(KEY_PORT, MacRemoteProtocol.DEFAULT_PORT)
    }

    fun getSavedPin(context: Context): String {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_PIN, "") ?: ""
    }

    fun saveConnectionDetails(context: Context, host: String, port: Int, pin: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_HOST, host.trim())
            .putInt(KEY_PORT, port)
            .putString(KEY_PIN, pin.trim())
            .apply()
    }

    // MARK: - Connection Management

    fun connect(host: String, port: Int, pin: String) {
        if (state == ConnectionState.CONNECTED || state == ConnectionState.CONNECTING) {
            disconnect()
        }

        val cleanHost = host.trim()
        val targetPort = if (port in 1..65535) port else MacRemoteProtocol.DEFAULT_PORT
        val url = "ws://$cleanHost:$targetPort"

        updateState(ConnectionState.CONNECTING, "Connecting to $cleanHost:$targetPort…")

        val request = Request.Builder()
            .url(url)
            .build()

        webSocket = okHttpClient.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(ws: WebSocket, response: Response) {
                updateState(ConnectionState.AUTHENTICATING, "Authenticating with PIN…")
                val deviceName = "${Build.MANUFACTURER} ${Build.MODEL} (DroidHouse)"
                val authMsg = MacRemoteProtocol.auth(pin = pin.trim(), deviceName = deviceName)
                ws.send(authMsg)
            }

            override fun onMessage(ws: WebSocket, text: String) {
                handleTextMessage(ws, text)
            }

            override fun onMessage(ws: WebSocket, bytes: ByteString) {
                handleBinaryMessage(bytes)
            }

            override fun onClosing(ws: WebSocket, code: Int, reason: String) {
                ws.close(1000, null)
                updateState(ConnectionState.DISCONNECTED, "Connection closed: $reason")
            }

            override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
                Log.e(TAG, "WebSocket failure: ${t.localizedMessage}", t)
                updateState(ConnectionState.FAILED, "Connection failed: ${t.localizedMessage ?: "Network error"}")
                cleanup()
            }
        })
    }

    fun disconnect() {
        try {
            if (isScreenStreaming) {
                setScreenStreaming(false)
            }
            webSocket?.close(1000, "User disconnected")
        } catch (e: Exception) {
            Log.w(TAG, "Error during close: ${e.localizedMessage}")
        } finally {
            cleanup()
            updateState(ConnectionState.DISCONNECTED, "Disconnected")
        }
    }

    private fun cleanup() {
        pingJob?.cancel()
        pingJob = null
        webSocket = null
        connectedMacName = null
        latestScreenFrame = null
        isScreenStreaming = false
    }

    private fun updateState(newState: ConnectionState, message: String) {
        state = newState
        statusMessage = message
        onStateChanged?.invoke(newState, message)
    }

    // MARK: - Message Handling

    private fun handleTextMessage(ws: WebSocket, text: String) {
        try {
            val env = MacRemoteProtocol.json.decodeFromString<MacRemoteProtocol.OutboundEnvelope>(text)
            when (env.type) {
                "auth_ok" -> {
                    connectedMacName = env.macName ?: "Mac"
                    screenWidth = env.screenWidth ?: 1920.0
                    screenHeight = env.screenHeight ?: 1080.0
                    updateState(ConnectionState.CONNECTED, "Connected to $connectedMacName")
                    startPingLoop()
                }

                "auth_fail" -> {
                    updateState(ConnectionState.FAILED, env.message ?: "Authentication failed (Invalid PIN)")
                    disconnect()
                }

                "pong" -> {
                    if (env.pingId != null) {
                        val now = System.currentTimeMillis().toDouble() / 1000.0
                        val rtt = ((now - env.pingId) * 1000.0).toLong()
                        rttLatencyMs = rtt.coerceAtLeast(1L)
                        // Send back to Mac for its monitor
                        ws.send(MacRemoteProtocol.pongRtt(env.pingId))
                    }
                }

                "cursor_pos" -> {
                    val cx = env.cursorX?.toFloat()
                    val cy = env.cursorY?.toFloat()
                    if (cx != null && cy != null) {
                        cursorXRatio = cx.coerceIn(0f, 1f)
                        cursorYRatio = cy.coerceIn(0f, 1f)
                        isCursorDown = env.cursorDown == true
                        onCursorMoved?.invoke(cursorXRatio, cursorYRatio, isCursorDown)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse inbound text envelope: ${e.localizedMessage}")
        }
    }

    private fun handleBinaryMessage(bytes: ByteString) {
        val byteBuffer = ByteBuffer.wrap(bytes.toByteArray())
        if (byteBuffer.remaining() < 12) return

        val magic = byteBuffer.int
        if (magic != MacRemoteProtocol.SCREEN_HEADER_MAGIC) return

        val width = byteBuffer.short.toInt() and 0xFFFF
        val height = byteBuffer.short.toInt() and 0xFFFF
        val timestamp = byteBuffer.int

        var payloadOffset = 12
        if (byteBuffer.remaining() >= 4) {
            val rawCurX = byteBuffer.short.toInt() and 0xFFFF
            val rawCurY = byteBuffer.short.toInt() and 0xFFFF
            cursorXRatio = (rawCurX.toFloat() / 65535f).coerceIn(0f, 1f)
            cursorYRatio = (rawCurY.toFloat() / 65535f).coerceIn(0f, 1f)
            payloadOffset = 16
            onCursorMoved?.invoke(cursorXRatio, cursorYRatio, isCursorDown)
        }
        val payloadLength = bytes.size - payloadOffset

        val byteArray = bytes.toByteArray()
        val bitmap = BitmapFactory.decodeByteArray(byteArray, payloadOffset, payloadLength)
        if (bitmap != null) {
            latestScreenFrame = bitmap
            onFrameReceived?.invoke(bitmap)
        }
    }

    private fun startPingLoop() {
        pingJob?.cancel()
        pingJob = scope.launch {
            while (isActive && state == ConnectionState.CONNECTED) {
                delay(3000)
                val now = System.currentTimeMillis().toDouble() / 1000.0
                sendRaw(MacRemoteProtocol.ping(now))
            }
        }
    }

    // Dynamic Mac Trackpad Acceleration Engine
    private var lastDx: Float = 0f
    private var lastDy: Float = 0f

    fun sendMouseMove(deltaX: Float, deltaY: Float) {
        if (state != ConnectionState.CONNECTED) return

        val distance = Math.hypot(deltaX.toDouble(), deltaY.toDouble()).toFloat()
        if (distance <= 0.001f) return

        // Authentic macOS Trackpad Velocity Response Curve:
        // - Precision Zone (< 3.0 px): 0.85x linear damping for pixel-perfect targeting
        // - Linear Zone (3.0 - 10.0 px): 1.0x to 1.35x progressive tracking
        // - Dynamic Acceleration Zone (10.0 - 24.0 px): power-law exponent (~1.4x - 2.2x)
        // - High-Velocity Flicks (> 24.0 px): logarithmic boost up to 3.85x to span wide Mac displays
        val accelFactor: Float = when {
            distance < 3.0f -> 0.85f
            distance < 10.0f -> 1.0f + (distance - 3.0f) * 0.05f
            distance < 24.0f -> 1.35f + (distance - 10.0f) * 0.09f
            else -> (2.61f + (distance - 24.0f) * 0.12f).coerceAtMost(3.85f)
        }

        // Exponential Moving Average (EMA) smoothing to eliminate digitizer step-ladder jitter
        val smoothDx = (deltaX * 0.78f + lastDx * 0.22f)
        val smoothDy = (deltaY * 0.78f + lastDy * 0.22f)
        lastDx = deltaX
        lastDy = deltaY

        val finalDx = (smoothDx * accelFactor * trackpadSensitivity).toDouble()
        val finalDy = (smoothDy * accelFactor * trackpadSensitivity).toDouble()

        sendRaw(MacRemoteProtocol.mouseMove(finalDx, finalDy))
    }

    fun sendMouseMoveAbs(xRatio: Float, yRatio: Float) {
        if (state != ConnectionState.CONNECTED) return
        cursorXRatio = xRatio.coerceIn(0f, 1f)
        cursorYRatio = yRatio.coerceIn(0f, 1f)
        onCursorMoved?.invoke(cursorXRatio, cursorYRatio, isCursorDown)
        sendRaw(MacRemoteProtocol.mouseMoveAbs(xRatio.toDouble(), yRatio.toDouble()))
    }

    fun sendMouseClick(button: String = "left") {
        if (state != ConnectionState.CONNECTED) return
        sendRaw(MacRemoteProtocol.mouseClick(button))
    }

    fun sendMouseDoubleClick() {
        if (state != ConnectionState.CONNECTED) return
        sendRaw(MacRemoteProtocol.mouseDoubleClick())
    }

    fun sendMouseDown(button: String = "left") {
        if (state != ConnectionState.CONNECTED) return
        sendRaw(MacRemoteProtocol.mouseDown(button))
    }

    fun sendMouseUp(button: String = "left") {
        if (state != ConnectionState.CONNECTED) return
        sendRaw(MacRemoteProtocol.mouseUp(button))
    }

    fun sendMouseScroll(deltaX: Float, deltaY: Float) {
        if (state != ConnectionState.CONNECTED) return
        // Multiply for natural trackpad scrolling feel
        sendRaw(MacRemoteProtocol.mouseScroll((deltaX * 1.5).toDouble(), (deltaY * 1.5).toDouble()))
    }

    fun sendKeyText(text: String) {
        if (state != ConnectionState.CONNECTED || text.isEmpty()) return
        sendRaw(MacRemoteProtocol.keyText(text))
    }

    fun sendKeyCombo(combo: String) {
        if (state != ConnectionState.CONNECTED) return
        sendRaw(MacRemoteProtocol.keyCombo(combo))
    }

    fun sendSystemAction(action: String) {
        if (state != ConnectionState.CONNECTED) return
        sendRaw(MacRemoteProtocol.systemAction(action))
    }

    fun setScreenStreaming(enabled: Boolean, fps: Int = 20, quality: Double = 0.55, scale: Double = 0.70) {
        if (state != ConnectionState.CONNECTED) return
        isScreenStreaming = enabled
        sendRaw(MacRemoteProtocol.screenStream(enabled, fps, quality, scale))
    }

    fun requestSingleFrame() {
        if (state != ConnectionState.CONNECTED) return
        sendRaw(MacRemoteProtocol.requestFrame())
    }

    private fun sendRaw(jsonString: String) {
        try {
            webSocket?.send(jsonString)
        } catch (e: Exception) {
            Log.w(TAG, "Send error: ${e.localizedMessage}")
        }
    }
}
