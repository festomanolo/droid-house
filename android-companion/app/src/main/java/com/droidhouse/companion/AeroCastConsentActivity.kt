package com.droidhouse.companion

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts

/**
 * A transparent, no-chrome activity whose only job is to raise the system's
 * screen-capture consent dialog and hand the resulting token to
 * [AeroCastService].
 *
 * It exists because `MediaProjectionManager.createScreenCaptureIntent()` can
 * only be launched for a result from an Activity — a Service cannot ask.
 */
class AeroCastConsentActivity : ComponentActivity() {

    companion object {
        private const val TAG = "AeroCastConsent"
    }

    private val projectionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            AeroCastService.onConsentResult(applicationContext, result.resultCode, result.data)
        } else {
            Log.i(TAG, "Screen capture was declined (resultCode=${result.resultCode})")
            AeroCastService.onConsentResult(applicationContext, result.resultCode, null)
        }
        finish()
        // No slide-out: the dialog should feel like it belongs to the system,
        // not like a window this app opened.
        overridePendingTransition(0, 0)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)

        val manager = getSystemService(MediaProjectionManager::class.java)
        if (manager == null) {
            Log.e(TAG, "MediaProjectionManager unavailable on this device")
            finish()
            return
        }

        runCatching {
            projectionLauncher.launch(manager.createScreenCaptureIntent())
        }.onFailure { error ->
            Log.e(TAG, "Could not raise the screen-capture prompt", error)
            AeroCastService.onConsentResult(applicationContext, Activity.RESULT_CANCELED, null)
            finish()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }
}
