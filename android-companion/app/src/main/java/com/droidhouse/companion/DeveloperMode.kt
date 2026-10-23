package com.droidhouse.companion

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Build
import android.provider.Settings
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import android.widget.Toast
import androidx.core.content.ContextCompat
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.call
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

@Serializable
data class DeveloperModePayload(
    val developerOptions: Boolean,
    val usbDebugging: Boolean,
    val wirelessDebugging: Boolean,
    /** Port adbd listens on over Wi-Fi when known (`adb tcpip` before Android 11), else 0. */
    val wirelessPort: Int,
    /** Android 11+ has a real Wireless debugging switch; older releases only have `adb tcpip`. */
    val wirelessSupported: Boolean,
    /** False until WRITE_SECURE_SETTINGS has been granted over adb. */
    val canToggle: Boolean,
    val grantCommand: String
)

@Serializable
data class DeveloperModeRequest(val enabled: Boolean)

/**
 * Turns Developer options, USB debugging and Wireless debugging on or off as
 * one switch, so the same phone can be a test device and still pass the
 * "developer mode is on" checks banking and payment apps make.
 *
 * Those are Settings.Global values only the shell or system can write. The
 * companion can too once it holds WRITE_SECURE_SETTINGS, a development
