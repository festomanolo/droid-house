package com.droidhouse.companion

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Watches the system clipboard and exposes its current contents to the bridge.
 *
 * Note the platform constraint: since Android 10, reading the clipboard is only
 * permitted for the app that currently holds focus (or the default IME). The
 * listener therefore fires reliably while this app is foregrounded, and the
 * write direction — Mac → phone — always works.
 */
class ClipboardWatcher(private val context: Context) {

    companion object {
        private const val TAG = "ClipboardWatcher"

        /** Snapshot for the Compose UI, which has no handle on the instance. */
        @Volatile
        var lastKnownText: String = ""
            private set
    }

    private val clipboardManager =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    @Volatile
    var currentClipText: String = ""
        private set

    @Volatile
    var lastUpdatedTimestamp: Long = System.currentTimeMillis()
        private set

    private val listener = ClipboardManager.OnPrimaryClipChangedListener {
        updateClipTextFromAndroid()
    }

    fun start() {
        clipboardManager.addPrimaryClipChangedListener(listener)
        updateClipTextFromAndroid()
    }

    fun stop() {
        runCatching { clipboardManager.removePrimaryClipChangedListener(listener) }
    }

    private fun updateClipTextFromAndroid() {
        // Throws SecurityException when we're backgrounded on Android 10+;
        // that's expected, not exceptional.
        val clipData = runCatching { clipboardManager.primaryClip }
            .getOrElse { error ->
                Log.d(TAG, "Clipboard unreadable while backgrounded: ${error.message}")
                null
            } ?: return

        if (clipData.itemCount <= 0) return

        val text = clipData.getItemAt(0).coerceToText(context)?.toString().orEmpty()
        if (text != currentClipText) {
            currentClipText = text
            lastKnownText = text
            lastUpdatedTimestamp = System.currentTimeMillis()
            // Anything we manage to read here is a legitimate phone-side
            // capture, so make it available to the Mac.
            ClipboardBridge.publish(text, "listener")
        }
    }

    /**
     * The value the bridge should serve: whichever of the listener or the
     * explicit capture routes saw text most recently.
     *
     * They can disagree because the listener only fires while the app has
     * focus, whereas the share action and QS tile work from anywhere.
     */
    fun effectiveText(): Pair<String, Long> =
        if (ClipboardBridge.capturedAt >= lastUpdatedTimestamp && ClipboardBridge.capturedText.isNotEmpty()) {
            ClipboardBridge.capturedText to ClipboardBridge.capturedAt
        } else {
            currentClipText to lastUpdatedTimestamp
        }

    fun setClipboard(text: String) {
        if (text == currentClipText) return
        currentClipText = text
        lastKnownText = text
        lastUpdatedTimestamp = System.currentTimeMillis()
        // Record the Mac's value as the current one so the next phone→Mac read
        // doesn't immediately echo it straight back.
        ClipboardBridge.publish(text, "mac")

        // setPrimaryClip must run on a looper thread; the bridge calls this
        // from a Ktor worker.
        Handler(Looper.getMainLooper()).post {
            runCatching {
                clipboardManager.setPrimaryClip(ClipData.newPlainText("DroidHouse macOS", text))
            }.onFailure { Log.w(TAG, "Could not set the clipboard", it) }
        }
    }
}
