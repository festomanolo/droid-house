package com.droidhouse.companion

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

// MARK: - Mac Remote Protocol (Android)
//
// Client-side schemas and serialization helpers for controlling macOS
// from the DroidHouse Android companion app over WAN (Tailscale/Internet)
// or local LAN.

object MacRemoteProtocol {
    const val DEFAULT_PORT = 8089
    const val SCREEN_HEADER_MAGIC = 0x44485343 // 'DHSC'

    val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
    }

    @Serializable
    data class InboundEnvelope(
        val type: String,
        val pin: String? = null,
        val deviceName: String? = null,
        val dx: Double? = null,
        val dy: Double? = null,
        val xRatio: Double? = null,
        val yRatio: Double? = null,
        val button: String? = null,
        val text: String? = null,
        val keyCode: Int? = null,
        val keyDown: Boolean? = null,
        val combo: String? = null,
        val action: String? = null,
        val fps: Int? = null,
        val quality: Double? = null,
        val scale: Double? = null,
        val enabled: Boolean? = null,
        val timestamp: Double? = null
    )

    @Serializable
    data class OutboundEnvelope(
        val type: String,
        val success: Boolean? = null,
        val message: String? = null,
        val macName: String? = null,
        val screenWidth: Double? = null,
        val screenHeight: Double? = null,
        val version: Int? = null,
        val timestamp: Double? = null,
        val accessibilityGranted: Boolean? = null,
        val screenCaptureGranted: Boolean? = null,
        val pingId: Double? = null
    )

    enum class SystemAction(val rawValue: String) {
        VOLUME_UP("volume_up"),
        VOLUME_DOWN("volume_down"),
        VOLUME_MUTE("volume_mute"),
        PLAY_PAUSE("play_pause"),
        NEXT_TRACK("next_track"),
        PREV_TRACK("prev_track"),
        BRIGHTNESS_UP("brightness_up"),
        BRIGHTNESS_DOWN("brightness_down"),
        LOCK_SCREEN("lock_screen"),
        SLEEP_DISPLAY("sleep_display"),
        SLEEP_MAC("sleep_mac"),
        MISSION_CONTROL("mission_control"),
        SHOW_DESKTOP("show_desktop")
    }

    enum class KeyCombo(val rawValue: String) {
        SPOTLIGHT("spotlight"),
        APP_SWITCHER("app_switcher"),
        COPY("copy"),
        PASTE("paste"),
        UNDO("undo"),
        SELECT_ALL("select_all"),
        SAVE("save"),
        ENTER("enter"),
        BACKSPACE("backspace"),
        ESCAPE("escape"),
        TAB("tab"),
        SPACE("space"),
        ARROW_UP("arrow_up"),
        ARROW_DOWN("arrow_down"),
        ARROW_LEFT("arrow_left"),
        ARROW_RIGHT("arrow_right")
    }

    // Message Constructors
    fun auth(pin: String, deviceName: String): String =
        json.encodeToString(InboundEnvelope(type = "auth", pin = pin, deviceName = deviceName))

    fun ping(timestamp: Double): String =
        json.encodeToString(InboundEnvelope(type = "ping", timestamp = timestamp))

    fun pongRtt(timestamp: Double): String =
        json.encodeToString(InboundEnvelope(type = "pong_rtt", timestamp = timestamp))

    fun mouseMove(dx: Double, dy: Double): String =
        json.encodeToString(InboundEnvelope(type = "mouse_move", dx = dx, dy = dy))

    fun mouseMoveAbs(xRatio: Double, yRatio: Double): String =
        json.encodeToString(InboundEnvelope(type = "mouse_move_abs", xRatio = xRatio, yRatio = yRatio))

    fun mouseClick(button: String = "left"): String =
        json.encodeToString(InboundEnvelope(type = "mouse_click", button = button))

    fun mouseDoubleClick(): String =
        json.encodeToString(InboundEnvelope(type = "mouse_double_click"))

    fun mouseDown(button: String = "left"): String =
        json.encodeToString(InboundEnvelope(type = "mouse_down", button = button))

    fun mouseUp(button: String = "left"): String =
        json.encodeToString(InboundEnvelope(type = "mouse_up", button = button))

    fun mouseScroll(dx: Double, dy: Double): String =
        json.encodeToString(InboundEnvelope(type = "mouse_scroll", dx = dx, dy = dy))

    fun keyText(text: String): String =
        json.encodeToString(InboundEnvelope(type = "key_text", text = text))

    fun keyPress(keyCode: Int, keyDown: Boolean): String =
        json.encodeToString(InboundEnvelope(type = "key_press", keyCode = keyCode, keyDown = keyDown))

    fun keyCombo(combo: String): String =
        json.encodeToString(InboundEnvelope(type = "key_combo", combo = combo))

    fun systemAction(action: String): String =
        json.encodeToString(InboundEnvelope(type = "system_action", action = action))

    fun screenStream(enabled: Boolean, fps: Int = 20, quality: Double = 0.55, scale: Double = 0.70): String =
        json.encodeToString(
            InboundEnvelope(
                type = "screen_stream",
                enabled = enabled,
                fps = fps,
                quality = quality,
                scale = scale
            )
        )

    fun requestFrame(): String =
        json.encodeToString(InboundEnvelope(type = "request_frame"))
}
