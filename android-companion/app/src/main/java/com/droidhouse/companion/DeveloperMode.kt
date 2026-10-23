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
 * permission that adb grants with [GRANT_COMMAND] (the Mac does this on its
 * own when the phone is on adb). The grant survives reboots and turning
 * developer mode off, so after it the phone can be switched back on from the
 * app, the Quick Settings tile, or the Mac over Wi-Fi with no adb at all.
 */
object DeveloperMode {
    private const val TAG = "DeveloperMode"

    /** Settings.Global.ADB_WIFI_ENABLED is hidden API; the key is stable since Android 11. */
    private const val ADB_WIFI_ENABLED = "adb_wifi_enabled"

    const val GRANT_COMMAND =
        "adb shell pm grant com.droidhouse.companion android.permission.WRITE_SECURE_SETTINGS"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    val wirelessSupported: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R

    fun canToggle(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_SECURE_SETTINGS) ==
            PackageManager.PERMISSION_GRANTED

    fun isEnabled(context: Context): Boolean =
        global(context, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED) == 1

    fun snapshot(context: Context): DeveloperModePayload {
        val usb = global(context, Settings.Global.ADB_ENABLED) == 1
        val tcpPort = if (wirelessSupported) 0 else adbTcpPort()
        return DeveloperModePayload(
            developerOptions = isEnabled(context),
            usbDebugging = usb,
            wirelessDebugging = if (wirelessSupported) global(context, ADB_WIFI_ENABLED) == 1 else usb && tcpPort > 0,
            wirelessPort = if (usb) tcpPort else 0,
            wirelessSupported = wirelessSupported,
            canToggle = canToggle(context),
            grantCommand = GRANT_COMMAND
        )
    }

    /**
     * Writes all three switches. Off goes in reverse order so adb, the thing
     * most likely carrying this very request, is the last to go.
     */
    fun setEnabled(context: Context, enabled: Boolean): Result<Unit> = runCatching {
        check(canToggle(context)) { "Grant the permission first: $GRANT_COMMAND" }
        val resolver = context.contentResolver
        val value = if (enabled) 1 else 0
        if (enabled) {
            Settings.Global.putInt(resolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 1)
            Settings.Global.putInt(resolver, Settings.Global.ADB_ENABLED, 1)
            // Android refuses Wireless debugging off Wi-Fi and resets it; that's
            // fine, USB debugging is still on.
            if (wirelessSupported) Settings.Global.putInt(resolver, ADB_WIFI_ENABLED, 1)
        } else {
