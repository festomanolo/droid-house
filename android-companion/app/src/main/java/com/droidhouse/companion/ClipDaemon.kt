package com.droidhouse.companion

import android.content.ClipData
import android.net.LocalServerSocket
import android.os.Binder
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import org.json.JSONObject
import java.io.File
import java.lang.reflect.Method
import java.net.HttpURLConnection
import java.net.URL

/**
 * Automatic phone → Mac clipboard, on Android 10 and later.
 *
 * ## Why a daemon
 *
 * A normal app can't read the clipboard from the background (see
 * [ClipboardBridge]). The shell user can: it holds
 * `READ_CLIPBOARD_IN_BACKGROUND`, which is how scrcpy syncs the clipboard. So
 * the Mac starts this class over adb, as shell, with `app_process`:
 *
 * ```
 * CLASSPATH=<base.apk> nohup app_process /system/bin com.droidhouse.companion.ClipDaemon
 * ```
 *
 * It registers a clip-changed listener with the clipboard service and posts
 * each new clip to the bridge on loopback (`POST /api/clipboard/phone`), which
 * the Mac already polls. It outlives the adb session and runs until reboot or
 * until the companion is reinstalled; the Mac restarts it whenever it sees the
 * phone over adb.
 *
 * Everything here goes through hidden framework APIs by reflection. Their
 * signatures change between releases, so arguments are filled by type rather
 * than by position: strings get the shell's package name and ints get 0 (user
 * 0, default device).
 */
object ClipDaemon {

    /** Abstract socket used purely as a single-instance lock. */
    private const val LOCK_NAME = "droidhouse_clipd"
    private const val SHELL_PACKAGE = "com.android.shell"
    private const val BRIDGE = "http://127.0.0.1:8080"
    private const val HEARTBEAT_MS = 15_000L

    private lateinit var clipboard: Any
    private lateinit var getPrimaryClip: Method

    @Volatile
    private var lastText: String = ""

    @JvmStatic
    fun main(args: Array<String>) {
        val lock = runCatching { LocalServerSocket(LOCK_NAME) }.getOrElse {
            log("already running")
            return
        }

        runCatching {
            Class.forName("android.os.Process")
                .getMethod("setArgV0", String::class.java)
                .invoke(null, "droidhouse-clipd")
        }

        Looper.prepareMainLooper()

        val binder = Class.forName("android.os.ServiceManager")
            .getMethod("getService", String::class.java)
            .invoke(null, "clipboard") as IBinder
        clipboard = Class.forName("android.content.IClipboard\$Stub")
            .getMethod("asInterface", IBinder::class.java)
            .invoke(null, binder)!!
        getPrimaryClip = clipboard.javaClass.methods.first { it.name == "getPrimaryClip" }

        // Seed with the current clip so starting the daemon doesn't overwrite
        // whatever is on the Mac.
        lastText = readClip().orEmpty()
