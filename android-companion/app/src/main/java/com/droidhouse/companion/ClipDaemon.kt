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

        registerListener()
        startHeartbeat()
        log("listening")

        Looper.loop()
        lock.close()
    }

    /**
     * IOnPrimaryClipChangedListener has one oneway method, so any transaction
     * on a plain Binder is the change notification. Wrapping the Binder with
     * the hidden Stub's asInterface gives a proxy of the right type to pass in.
     */
    private fun registerListener() {
        val callback = object : Binder() {
            override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                if (code == FIRST_CALL_TRANSACTION) {
                    onClipChanged()
                    return true
                }
                return super.onTransact(code, data, reply, flags)
            }
        }

        val listener = Class.forName("android.content.IOnPrimaryClipChangedListener\$Stub")
            .getMethod("asInterface", IBinder::class.java)
            .invoke(null, callback)

        val add = clipboard.javaClass.methods.first { it.name == "addPrimaryClipChangedListener" }
        add.invoke(clipboard, *fillArgs(add, listener))
    }

    private fun onClipChanged() {
        val text = readClip() ?: return
        if (text.isEmpty() || text == lastText) return
        lastText = text
        post("/api/clipboard/phone", JSONObject().put("text", text).toString())
    }

    private fun readClip(): String? = runCatching {
        val clip = getPrimaryClip.invoke(clipboard, *fillArgs(getPrimaryClip, null)) as ClipData?
        if (clip == null || clip.itemCount == 0) return null
        val item = clip.getItemAt(0)
        (item.text ?: item.htmlText)?.toString()
    }.getOrElse {
        log("read failed: ${it.cause ?: it}")
        null
    }

    /**
     * Tells the bridge the daemon is alive, and exits once the APK it was
     * started from has been replaced, so a reinstall never leaves old code
     * running.
     */
    private fun startHeartbeat() {
        val apk = System.getProperty("java.class.path").orEmpty().split(':').firstOrNull().orEmpty()
        Thread {
            while (true) {
                if (apk.isNotEmpty() && !File(apk).exists()) {
                    log("companion was reinstalled; exiting")
                    System.exit(0)
                }
                post("/api/clipboard/daemon", "{}")
                Thread.sleep(HEARTBEAT_MS)
            }
        }.apply { isDaemon = true }.start()
    }

    /** The first String is the calling package; any later one is an attribution tag. */
    private fun fillArgs(method: Method, listener: Any?): Array<Any?> {
        val packageIndex = method.parameterTypes.indexOfFirst { it == String::class.java }
        return method.parameterTypes.mapIndexed { index, type ->
            when {
                type == String::class.java -> if (index == packageIndex) SHELL_PACKAGE else null
                type == Int::class.javaPrimitiveType -> 0
                type == Boolean::class.javaPrimitiveType -> false
                listener != null && type.isInstance(listener) -> listener
                else -> null
            }
        }.toTypedArray()
    }

    private fun post(path: String, body: String) {
        runCatching {
            val connection = URL(BRIDGE + path).openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.connectTimeout = 2_000
            connection.readTimeout = 2_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.outputStream.use { it.write(body.toByteArray()) }
            connection.responseCode
            connection.disconnect()
        }
    }

    private fun log(message: String) = println("droidhouse-clipd: $message")
}
