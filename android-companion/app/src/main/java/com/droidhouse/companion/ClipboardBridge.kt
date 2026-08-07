package com.droidhouse.companion

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import android.widget.Toast

/**
 * Ways to get text from the phone onto the Mac's clipboard.
 *
 * ## Why this file exists
 *
 * Since Android 10, `ClipboardManager.getPrimaryClip()` returns null unless the
 * caller is the foreground app or the active IME. A background service — which
 * is exactly what the DroidHouse bridge is — can never read the clipboard. That
 * is a deliberate privacy control, not a bug to work around, and it's why the
 * Mac → phone direction has always worked while phone → Mac did not.
 *
 * We also can't reach it from the host: `cmd clipboard` is unimplemented and
 * `dumpsys clipboard` prints nothing on this OEM's build.
 *
 * So instead of pretending, the companion offers three routes that are fully
 * supported and need no special privileges:
 *
 *  1. **[ClipboardShareActivity]** — registered for `ACTION_PROCESS_TEXT`, so
 *     "DroidHouse" appears in the text-selection toolbar right next to Copy.
 *     Also handles `ACTION_SEND`, putting it in the system share sheet.
 *  2. **[ClipboardTileService]** — a Quick Settings tile. One pull-down and one
 *     tap pushes the current clip, from anywhere.
 *  3. **Foreground capture** — opening the companion reads and pushes whatever
 *     is on the clipboard, since the app then legitimately has focus.
 */
object ClipboardBridge {

    private const val TAG = "ClipboardBridge"

    /**
     * Last value captured through any of the supported routes. This is what
     * `GET /api/clipboard` serves.
     */
    @Volatile
    var capturedText: String = ""
        private set

    @Volatile
    var capturedAt: Long = 0L
        private set

    @Volatile
    var captureSource: String = "none"
        private set

    fun publish(text: String, source: String) {
        if (text.isEmpty()) return
        capturedText = text
        capturedAt = System.currentTimeMillis()
        captureSource = source
        Log.i(TAG, "Captured ${text.length} chars via $source")
    }

    /**
     * Reads the system clipboard, which only succeeds while the app has focus.
     * Returns true when something new was captured.
     */
    fun captureFromSystem(context: Context, source: String): Boolean {
        val manager = context.getSystemService(android.content.ClipboardManager::class.java)
            ?: return false

        val clip = runCatching { manager.primaryClip }
            .getOrElse {
                Log.d(TAG, "Clipboard unreadable from $source: ${it.message}")
                null
            } ?: return false

        if (clip.itemCount <= 0) return false

        val text = clip.getItemAt(0).coerceToText(context)?.toString().orEmpty()
        if (text.isEmpty() || text == capturedText) return false

        publish(text, source)
        return true
    }
}

/**
 * Appears in the text-selection toolbar (`ACTION_PROCESS_TEXT`) and in the
 * share sheet (`ACTION_SEND`). Selecting text anywhere on the phone and tapping
 * DroidHouse lands it on the Mac's clipboard immediately.
 *
 * The activity is invisible and finishes at once — it's an action, not a screen.
 */
class ClipboardShareActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)

        val text = extractText(intent)

        if (text.isNullOrBlank()) {
            toast("Nothing to send")
        } else {
            ClipboardBridge.publish(text, "share")
            // Mirror it into the system clipboard too, so the usual paste
            // behaviour on the phone is unchanged by using this action.
            runCatching {
                val manager = getSystemService(android.content.ClipboardManager::class.java)
                manager?.setPrimaryClip(
                    android.content.ClipData.newPlainText("DroidHouse", text)
                )
            }
            toast("Sent to Mac clipboard")
        }

        setResult(RESULT_OK)
        finish()
        overridePendingTransition(0, 0)
    }

    private fun extractText(intent: Intent?): String? {
        if (intent == null) return null

        return when (intent.action) {
            Intent.ACTION_PROCESS_TEXT ->
                intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
                    ?: intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT_READONLY)?.toString()

            Intent.ACTION_SEND ->
                intent.getStringExtra(Intent.EXTRA_TEXT)

            else -> intent.getStringExtra(Intent.EXTRA_TEXT)
        }
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }
}

/**
 * Quick Settings tile that pushes the current clipboard to the Mac.
 *
 * A tile's own process doesn't hold focus, so the read is performed after
 * collapsing the shade via [TileService.startActivityAndCollapse] into the
 * share activity — which briefly *does* have focus and can read the clip.
 */
class ClipboardTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        qsTile?.apply {
            state = if (DroidHouseCompanion.isBridgeRunning) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            label = "Clip → Mac"
            subtitle = if (DroidHouseCompanion.isBridgeRunning) "Bridge live" else "Bridge offline"
            updateTile()
        }
    }

    override fun onClick() {
        super.onClick()

        // Try the direct read first — on some builds a tile click grants a
        // brief window in which the clipboard is readable.
        if (ClipboardBridge.captureFromSystem(applicationContext, "tile")) {
            showToast("Clipboard sent to Mac")
            return
        }

        // Otherwise bounce through the transparent capture activity, which has
        // real focus and can therefore read it.
        val intent = Intent(this, ClipboardCaptureActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pending = android.app.PendingIntent.getActivity(
                this, 0, intent,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                    android.app.PendingIntent.FLAG_IMMUTABLE
            )
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun showToast(message: String) {
        Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT).show()
    }
}

/**
 * A transparent activity whose only purpose is to hold focus for the instant it
 * takes to read the clipboard, then vanish.
 */
class ClipboardCaptureActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)
    }

    override fun onResume() {
        super.onResume()

        val captured = ClipboardBridge.captureFromSystem(applicationContext, "capture-activity")
        Toast.makeText(
            this,
            if (captured) "Clipboard sent to Mac" else "Clipboard is empty or unchanged",
            Toast.LENGTH_SHORT
        ).show()

        finish()
        overridePendingTransition(0, 0)
    }
}
