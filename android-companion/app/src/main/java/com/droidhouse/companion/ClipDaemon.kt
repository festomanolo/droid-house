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
