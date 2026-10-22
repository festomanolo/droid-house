package com.droidhouse.companion

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.hardware.display.DisplayManager
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.call
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import kotlinx.serialization.Serializable

@Serializable
data class InputRequest(
    /** tap | longpress | swipe | key | text | backspace */
    val type: String,
    val x: Float = 0f,
    val y: Float = 0f,
    val x2: Float = 0f,
    val y2: Float = 0f,
    val durationMs: Long = 0,
    val key: String = "",
    val text: String = ""
)

@Serializable
data class DisplayPayload(val width: Int, val height: Int, val inputReady: Boolean)

/**
 * Drives the phone from the Mac's AeroCast window when there's no adb `input`
 * command to lean on.
 *
 * Gestures go through `dispatchGesture`, navigation through global actions,
 * and typing edits the focused field directly. That's everything an app can
 * do without root or the shell user; the user turns it on once in
 * Settings → Accessibility.
 */
class RemoteInputService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: RemoteInputService? = null
            private set

        val isReady: Boolean get() = instance != null

        fun openSettings(context: Context) {
            context.startActivity(
                Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }

        fun displaySize(context: Context): Pair<Int, Int> {
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            context.getSystemService(DisplayManager::class.java)
                ?.getDisplay(Display.DEFAULT_DISPLAY)
                ?.getRealMetrics(metrics)
            return metrics.widthPixels to metrics.heightPixels
        }

        fun install(route: Route, context: Context) = with(route) {
            get("/api/device/display") {
                val (width, height) = displaySize(context)
                call.respond(DisplayPayload(width, height, isReady))
            }

            post("/api/input") {
                val request = call.receive<InputRequest>()

                // Volume needs no accessibility grant, so it works regardless.
                if (request.type == "key" && request.key.startsWith("VOLUME_")) {
                    val audio = context.getSystemService(AudioManager::class.java)
                    val direction = if (request.key == "VOLUME_UP") AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER
                    audio?.adjustStreamVolume(AudioManager.STREAM_MUSIC, direction, AudioManager.FLAG_SHOW_UI)
                    call.respond(SimpleResult(true, "ok"))
                    return@post
                }

                val service = instance
                if (service == null) {
                    call.respond(
                        HttpStatusCode.Conflict,
                        SimpleResult(false, "Turn on “DroidHouse Remote Input” in the phone's Accessibility settings to control it without adb.")
                    )
                    return@post
                }

                val handled = service.perform(request)
                call.respond(SimpleResult(handled, if (handled) "ok" else "Not supported: ${request.type} ${request.key}"))
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    // ------------------------------------------------------------- actions

    fun perform(request: InputRequest): Boolean = when (request.type) {
        "tap" -> stroke(request.x, request.y, request.x, request.y, 40)
        "longpress" -> stroke(request.x, request.y, request.x, request.y, request.durationMs.coerceIn(400, 3000))
        "swipe" -> stroke(request.x, request.y, request.x2, request.y2, request.durationMs.coerceIn(30, 3000))
        "key" -> key(request.key)
        "text" -> editFocused { text, start, end -> Edit(text.replaceRange(start, end, request.text), start + request.text.length) }
        "backspace" -> editFocused { text, start, end ->
            when {
                start != end -> Edit(text.removeRange(start, end), start)
                start > 0 -> Edit(text.removeRange(start - 1, start), start - 1)
                else -> null
            }
        }
        else -> false
    }

    private fun stroke(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long): Boolean {
        val path = Path().apply {
            moveTo(x1.coerceAtLeast(0f), y1.coerceAtLeast(0f))
            lineTo(x2.coerceAtLeast(0f), y2.coerceAtLeast(0f))
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    private fun key(name: String): Boolean = when (name) {
        "BACK", "ESCAPE" -> performGlobalAction(GLOBAL_ACTION_BACK)
        "HOME" -> performGlobalAction(GLOBAL_ACTION_HOME)
        "APP_SWITCH" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
        "NOTIFICATION" -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
        "POWER" -> performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN)
        "ENTER" -> enter()
        "DEL" -> perform(InputRequest(type = "backspace"))
        else -> false
    }

    private fun enter(): Boolean {
        val node = focusedInput() ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
        }
        // Before Android 11 there is no "press enter" action; a newline is the
        // closest thing, and only meaningful in a multi-line field.
        if (!node.isMultiLine) return false
        return perform(InputRequest(type = "text", text = "\n"))
    }

    private data class Edit(val text: String, val cursor: Int)

    /** Rewrites the focused field's text around its current selection. */
    private fun editFocused(change: (String, Int, Int) -> Edit?): Boolean {
        val node = focusedInput() ?: return false

        // A hint ("Search…") is reported as the text of an empty field.
        val current = if (node.isShowingHintText) "" else node.text?.toString().orEmpty()
        val start = node.textSelectionStart.takeIf { it in 0..current.length } ?: current.length
        val end = node.textSelectionEnd.takeIf { it in start..current.length } ?: start

        val edit = change(current, start, end) ?: return true
        val setText = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, edit.text)
        }
        if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, setText)) return false

        val cursor = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, edit.cursor)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, edit.cursor)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, cursor)
        return true
    }

    private fun focusedInput(): AccessibilityNodeInfo? =
        rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.takeIf { it.isEditable }
}
