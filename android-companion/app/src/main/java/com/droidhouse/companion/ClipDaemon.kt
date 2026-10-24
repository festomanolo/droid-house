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
