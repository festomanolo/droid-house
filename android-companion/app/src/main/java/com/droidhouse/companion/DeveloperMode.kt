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
    /** Fixed port adbd listens on over Wi-Fi after `adb tcpip`, else 0. */
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
        // `adb tcpip` works on every release, alongside Wireless debugging.
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
            if (wirelessSupported) Settings.Global.putInt(resolver, ADB_WIFI_ENABLED, value)
            Settings.Global.putInt(resolver, Settings.Global.ADB_ENABLED, value)
            Settings.Global.putInt(resolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, value)
        }
        Log.i(TAG, "Developer mode ${if (enabled) "on" else "off"}")
        Unit
    }.onFailure { Log.w(TAG, "Couldn't switch developer mode", it) }

    fun openSettings(context: Context) {
        val intent = Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }
            .onFailure {
                context.startActivity(Intent(Settings.ACTION_DEVICE_INFO_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
    }

    fun copyGrantCommand(context: Context) {
        context.getSystemService(ClipboardManager::class.java)
            ?.setPrimaryClip(ClipData.newPlainText("adb grant", GRANT_COMMAND))
    }

    fun install(route: Route, context: Context) = with(route) {
        get("/api/device/developer") {
            call.respond(snapshot(context))
        }

        post("/api/device/developer") {
            val request = runCatching { call.receive<DeveloperModeRequest>() }.getOrNull()
            if (request == null) {
                call.respond(HttpStatusCode.BadRequest, SimpleResult(false, "Body must be {\"enabled\": true|false}"))
                return@post
            }
            if (!canToggle(context)) {
                call.respond(
                    HttpStatusCode.Conflict,
                    SimpleResult(false, "Connect the phone over adb once so the Mac can grant DroidHouse permission to change developer settings.")
                )
                return@post
            }

            if (request.enabled) {
                setEnabled(context, true).fold(
                    onSuccess = { call.respond(snapshot(context)) },
                    onFailure = { call.respond(HttpStatusCode.InternalServerError, SimpleResult(false, it.message ?: "Failed")) }
                )
            } else {
                // Over the adb tunnel, turning USB debugging off kills the
                // connection this reply travels on, so answer first.
                call.respond(snapshot(context).copy(developerOptions = false, usbDebugging = false, wirelessDebugging = false, wirelessPort = 0))
                scope.launch {
                    delay(600)
                    setEnabled(context, false)
                }
            }
        }
    }

    private fun global(context: Context, key: String): Int =
        Settings.Global.getInt(context.contentResolver, key, 0)

    /** `adb tcpip` sets this property; it lasts until reboot. */
    private fun adbTcpPort(): Int = runCatching {
        val process = ProcessBuilder("getprop", "service.adb.tcp.port").redirectErrorStream(true).start()
        process.inputStream.bufferedReader().use { it.readText() }.trim().toIntOrNull() ?: 0
    }.getOrDefault(0)
}

/** Quick Settings tile: one tap to drop developer mode before opening a banking app. */
class DeveloperModeTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        refresh()
    }

    override fun onClick() {
        super.onClick()
        if (!DeveloperMode.canToggle(this)) {
            Toast.makeText(this, "Open DroidHouse to set up the developer mode switch", Toast.LENGTH_LONG).show()
            return
        }
        val enabled = !DeveloperMode.isEnabled(this)
        DeveloperMode.setEnabled(this, enabled).fold(
            onSuccess = {
                Toast.makeText(this, if (enabled) "Developer mode on" else "Developer mode off", Toast.LENGTH_SHORT).show()
            },
            onFailure = { Toast.makeText(this, it.message ?: "Couldn't switch developer mode", Toast.LENGTH_LONG).show() }
        )
        refresh()
    }

    private fun refresh() {
        val tile = qsTile ?: return
        val enabled = DeveloperMode.isEnabled(this)
        tile.state = when {
            !DeveloperMode.canToggle(this) -> Tile.STATE_UNAVAILABLE
            enabled -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        tile.label = "Dev Mode"
        tile.icon = Icon.createWithResource(this, R.drawable.droid)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (enabled) "On · debugging" else "Off"
        }
        tile.updateTile()
    }
}
