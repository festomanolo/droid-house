package com.droidhouse.companion

import android.content.Context
import android.content.SharedPreferences
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.SystemClock
import android.util.Log
import java.io.InputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID

/**
 * Lets a Mac reach the companion over Wi-Fi with no adb in the picture.
 *
 * Over adb the bridge only ever sees loopback connections, and adb itself has
 * already vouched for the Mac (the USB-debugging prompt). Off loopback nothing
 * vouches for the caller, so every LAN request must carry a token the Mac
 * earned by typing the pairing code shown on this phone.
 */
object LanAccess {

    private const val TAG = "LanAccess"
    private const val PREFS = "droidhouse_lan"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_DEVICE_ID = "device_id"
    private const val KEY_TOKENS = "paired_tokens"

    /** Bonjour/NSD type the Mac browses for. */
    const val SERVICE_TYPE = "_droidhouse._tcp."

    /** First line a LAN client writes on a raw stream socket (AeroCast, Studio). */
    private const val STREAM_AUTH_PREFIX = "DHAUTH "

    /** Wrong codes allowed before the code is rotated and pairing pauses. */
    private const val MAX_FAILED_ATTEMPTS = 5
    private const val LOCKOUT_MILLIS = 30_000L

    @Volatile
    private var prefs: SharedPreferences? = null
    private val random = SecureRandom()

    fun init(context: Context) {
        if (prefs == null) {
            prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        }
    }

    /** On by default: "no adb required" is the point of the feature. */
    var isEnabled: Boolean
        get() = prefs?.getBoolean(KEY_ENABLED, true) ?: true
        set(value) {
            prefs?.edit()?.putBoolean(KEY_ENABLED, value)?.apply()
        }

    /**
     * Stable identity for this install, so the Mac can tell "the same phone on
     * a new IP" from "a different phone".
     */
    val deviceId: String
        get() {
            val store = prefs ?: return "unknown"
            store.getString(KEY_DEVICE_ID, null)?.let { return it }
            val fresh = UUID.randomUUID().toString()
            store.edit().putString(KEY_DEVICE_ID, fresh).apply()
            return fresh
        }

    /** Address the bridge and stream sockets bind to. */
    fun bindHost(): String = if (isEnabled) "0.0.0.0" else "127.0.0.1"

    fun bindAddress(): InetAddress = InetAddress.getByName(bindHost())

    // ------------------------------------------------------------- pairing

    @Volatile
    var pairingCode: String = newCode()
        private set

    private var failedAttempts = 0
    private var lockedUntil = 0L

    fun rotateCode() {
        pairingCode = newCode()
    }

    /**
     * Swaps the on-screen code for a long-lived token, or returns null.
     *
     * Each code works once, and a burst of wrong guesses rotates it and pauses
     * pairing, so a 6-digit code can't be brute-forced from the network.
     */
    @Synchronized
    fun pair(code: String, clientName: String): String? {
        val now = SystemClock.elapsedRealtime()
        if (now < lockedUntil) return null

        val matches = MessageDigest.isEqual(
            code.trim().toByteArray(),
            pairingCode.toByteArray()
        )
        if (!matches) {
            failedAttempts += 1
            if (failedAttempts >= MAX_FAILED_ATTEMPTS) {
                failedAttempts = 0
                lockedUntil = now + LOCKOUT_MILLIS
                rotateCode()
            }
            return null
        }

        failedAttempts = 0
        rotateCode()

        val bytes = ByteArray(32).also(random::nextBytes)
        val token = bytes.joinToString("") { "%02x".format(it) }
        val name = clientName.replace('|', ' ').take(60).ifBlank { "Mac" }
        val entries = storedEntries() + "${sha256(token)}|$name|${System.currentTimeMillis()}"
        prefs?.edit()?.putStringSet(KEY_TOKENS, entries)?.apply()
        return token
    }

    fun isAuthorized(token: String?): Boolean {
        if (token.isNullOrBlank()) return false
        val hash = sha256(token)
        return storedEntries().any { it.substringBefore('|') == hash }
    }

    /** Names of every Mac that holds a token, newest first. */
    fun pairedMacs(): List<String> = storedEntries()
        .map { it.split('|') }
        .sortedByDescending { it.getOrNull(2)?.toLongOrNull() ?: 0L }
        .map { it.getOrNull(1) ?: "Mac" }

    fun forgetAll() {
        prefs?.edit()?.remove(KEY_TOKENS)?.apply()
        rotateCode()
    }

    private fun storedEntries(): Set<String> =
        prefs?.getStringSet(KEY_TOKENS, emptySet())?.toSet() ?: emptySet()

    private fun newCode(): String = "%06d".format(random.nextInt(1_000_000))

    private fun sha256(text: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(text.toByteArray())
            .joinToString("") { "%02x".format(it) }

    // ------------------------------------------------------------ requests

    /**
     * True for connections that came in through `adb forward` (adbd connects
     * from the phone itself), which adb has already authenticated.
     */
    fun isLoopback(address: String?): Boolean {
        if (address.isNullOrBlank()) return false
        val literal = address.removePrefix("/").substringBefore('%')
        if (literal == "localhost") return true
        return runCatching {
            // Only IP literals reach here, so this never does a DNS lookup.
            val parsed = InetAddress.getByName(literal)
            parsed.isLoopbackAddress ||
                literal.startsWith("::ffff:127.") ||
                literal.startsWith("0:0:0:0:0:ffff:7f")
        }.getOrDefault(false)
    }

    fun bearerToken(header: String?): String? =
        header?.takeIf { it.startsWith("Bearer ", ignoreCase = true) }
            ?.substring(7)
            ?.trim()

    /** The phone's Wi-Fi (or Ethernet/hotspot) address, for display. */
    fun localAddress(): String? = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .sortedBy { if (it.name.startsWith("wlan")) 0 else 1 }
            .flatMap { it.inetAddresses.toList() }
            .firstOrNull { it is Inet4Address && it.isSiteLocalAddress }
            ?.hostAddress
    }.getOrNull()

    // -------------------------------------------------------- raw streams

    /**
     * Accepts on a stream socket until a client that may watch the stream
     * connects.
     *
     * Loopback (adb) clients are taken as-is. A LAN client must first send
     * `DHAUTH <token>\n` within a few seconds; anything else is dropped and
     * the socket keeps listening, so a stray connection can't squat the
     * single-client stream.
     */
    fun acceptAuthorized(server: ServerSocket, isRunning: () -> Boolean): Socket {
        while (true) {
            val socket = server.accept()
            if (isLoopback(socket.inetAddress?.hostAddress)) return socket

            val accepted = runCatching {
                socket.soTimeout = 5_000
                val line = readLine(socket.getInputStream(), 200)
                socket.soTimeout = 0
                line != null &&
                    line.startsWith(STREAM_AUTH_PREFIX) &&
                    isAuthorized(line.removePrefix(STREAM_AUTH_PREFIX))
            }.getOrDefault(false)

            if (accepted) return socket

            Log.w(TAG, "Rejected unauthenticated stream client ${socket.inetAddress?.hostAddress}")
            runCatching { socket.close() }
            if (!isRunning()) throw java.io.IOException("Stream stopped")
        }
    }

    private fun readLine(input: InputStream, limit: Int): String? {
        val buffer = StringBuilder()
        while (buffer.length < limit) {
            val next = input.read()
            if (next < 0) return null
            if (next == '\n'.code) return buffer.toString().trimEnd('\r')
            buffer.append(next.toChar())
        }
        return null
    }

    // ----------------------------------------------------------- discovery

    private var registration: NsdManager.RegistrationListener? = null

    /** Advertises the bridge so the Mac finds the phone without typing an IP. */
    fun advertise(context: Context, port: Int) {
        if (!isEnabled || registration != null) return
        val manager = context.getSystemService(NsdManager::class.java) ?: return

        val info = NsdServiceInfo().apply {
            serviceName = "DroidHouse ${Build.MODEL}"
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("id", deviceId)
            setAttribute("model", "${Build.MANUFACTURER} ${Build.MODEL}")
            localAddress()?.let { setAttribute("ip", it) }
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "Advertising ${info.serviceName}")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD registration failed: $errorCode")
                registration = null
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
        }

        registration = listener
        runCatching { manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure {
                Log.w(TAG, "NSD unavailable", it)
                registration = null
            }
    }

    fun stopAdvertising(context: Context) {
        val listener = registration ?: return
        registration = null
        runCatching {
            context.getSystemService(NsdManager::class.java)?.unregisterService(listener)
        }
    }
}
