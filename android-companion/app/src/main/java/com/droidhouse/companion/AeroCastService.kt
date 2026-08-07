package com.droidhouse.companion

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.Surface
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.serialization.json.Json
import java.io.BufferedOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

/**
 * AeroCast: streams the device's screen (H.264 over MediaCodec) and its audio
 * (PCM via AudioPlaybackCapture) to the Mac over a plain TCP socket on 8081,
 * tunnelled by `adb forward`.
 *
 * Ordering here is dictated by the platform, not by taste:
 *   1. `startForeground` with the `mediaProjection` type — Android 14+ rejects
 *      `getMediaProjection` if the service isn't already foreground.
 *   2. register a `MediaProjection.Callback` — also mandatory since 14.
 *   3. only then create the VirtualDisplay and start capturing.
 */
class AeroCastService : Service() {

    companion object {
        private const val TAG = "AeroCastService"

        const val CHANNEL_ID = "droidhouse_aerocast_channel"
        const val NOTIFICATION_ID = 2002
        const val PORT = 8081

        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        const val EXTRA_AUDIO = "audio"
        const val EXTRA_BIT_RATE = "bitRate"
        const val EXTRA_MAX_WIDTH = "maxWidth"

        const val ACTION_START = "com.droidhouse.companion.AEROCAST_START"
        const val ACTION_STOP = "com.droidhouse.companion.AEROCAST_STOP"

        private const val VIDEO_MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val DEFAULT_BIT_RATE = 8_000_000
        private const val DEFAULT_MAX_WIDTH = 1080
        private const val FRAME_RATE = 60
        private const val SAMPLE_RATE = 44_100
        private const val CHANNEL_COUNT = 2

        @Volatile
        var isStreaming: Boolean = false
            private set

        @Volatile
        private var awaitingConsent: Boolean = false

        @Volatile
        private var statusMessage: String = "Idle"

        @Volatile
        private var streamWidth: Int = 0

        @Volatile
        private var streamHeight: Int = 0

        @Volatile
        private var audioEnabled: Boolean = true

        /** Pending options captured between the bridge request and consent. */
        @Volatile
        private var pendingAudio: Boolean = true

        @Volatile
        private var pendingBitRate: Int = DEFAULT_BIT_RATE

        @Volatile
        private var pendingMaxWidth: Int = DEFAULT_MAX_WIDTH

        fun stateSnapshot(): AeroCastStatePayload = AeroCastStatePayload(
            streaming = isStreaming,
            awaitingConsent = awaitingConsent,
            port = PORT,
            width = streamWidth,
            height = streamHeight,
            audioEnabled = audioEnabled,
            message = statusMessage
        )

        /**
         * Asks the user to approve screen capture and, once approved, starts
         * the stream.
         *
         * Android forbids an app in the background from launching an activity,
         * and the bridge request arrives on a socket thread with the app very
         * possibly not visible. So we do both: attempt the direct launch, and
         * post a tappable notification that works regardless. Returning `true`
         * means the request was *accepted*, not that pixels are flowing yet —
         * the Mac polls `/api/aerocast/status` (and simply waits on the socket)
         * to find out.
         */
        fun requestStart(
            context: Context,
            audio: Boolean,
            bitRate: Int?,
            maxWidth: Int?
        ): Boolean {
            if (isStreaming) {
                statusMessage = "Already streaming"
                return true
            }

            pendingAudio = audio
            pendingBitRate = bitRate?.takeIf { it in 500_000..40_000_000 } ?: DEFAULT_BIT_RATE
            pendingMaxWidth = maxWidth?.takeIf { it in 240..2160 } ?: DEFAULT_MAX_WIDTH

            awaitingConsent = true
            statusMessage = "Waiting for screen-capture approval on the device"

            val consentIntent = Intent(context, AeroCastConsentActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                putExtra(EXTRA_AUDIO, pendingAudio)
                putExtra(EXTRA_BIT_RATE, pendingBitRate)
                putExtra(EXTRA_MAX_WIDTH, pendingMaxWidth)
            }

            postConsentNotification(context, consentIntent)

            return runCatching {
                context.startActivity(consentIntent)
                true
            }.getOrElse { error ->
                // Background-launch blocked — the notification is the path now.
                Log.i(TAG, "Direct consent launch unavailable; notification posted instead", error)
                statusMessage =
                    "Tap the DroidHouse notification on your phone to approve screen capture"
                true
            }
        }

        fun requestStop(context: Context) {
            awaitingConsent = false
            val intent = Intent(context, AeroCastService::class.java).apply {
                action = ACTION_STOP
            }
            runCatching { context.startService(intent) }
            cancelConsentNotification(context)
        }

        /** Called by the consent activity once the user has decided. */
        fun onConsentResult(context: Context, resultCode: Int, data: Intent?) {
            cancelConsentNotification(context)

            if (data == null) {
                awaitingConsent = false
                statusMessage = "Screen capture was declined"
                return
            }

            val intent = Intent(context, AeroCastService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_RESULT_DATA, data)
                putExtra(EXTRA_AUDIO, pendingAudio)
                putExtra(EXTRA_BIT_RATE, pendingBitRate)
                putExtra(EXTRA_MAX_WIDTH, pendingMaxWidth)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        private const val CONSENT_NOTIFICATION_ID = 2003

        private fun postConsentNotification(context: Context, consentIntent: Intent) {
            ensureChannel(context)

            val pending = PendingIntent.getActivity(
                context,
                0,
                consentIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setContentTitle("AeroCast is waiting")
                .setContentText("Tap to let your Mac mirror this screen")
                .setSmallIcon(R.drawable.droid)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build()

            runCatching {
                context.getSystemService(NotificationManager::class.java)
                    ?.notify(CONSENT_NOTIFICATION_ID, notification)
            }
        }

        private fun cancelConsentNotification(context: Context) {
            runCatching {
                context.getSystemService(NotificationManager::class.java)
                    ?.cancel(CONSENT_NOTIFICATION_ID)
            }
        }

        fun ensureChannel(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "AeroCast Streaming",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Screen and audio mirroring to a paired Mac"
                    setShowBadge(false)
                }
            )
        }
    }

    // ---------------------------------------------------------------- state

    private val json = Json { encodeDefaults = true }
    private val running = AtomicBoolean(false)

    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var audioRecord: AudioRecord? = null

    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private var writer: AeroCastWriter? = null

    private var acceptThread: Thread? = null
    private var videoThread: Thread? = null
    private var audioThread: Thread? = null
    private var heartbeatThread: Thread? = null

    private var captureWidth = 0
    private var captureHeight = 0
    private var captureDensity = 0
    private var bitRate = DEFAULT_BIT_RATE
    private var wantsAudio = true

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            Log.i(TAG, "MediaProjection stopped by the system or the user")
            statusMessage = "Screen capture ended on the device"
            teardown()
            stopSelf()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                teardown()
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_START -> {
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
                @Suppress("DEPRECATION")
                val resultData: Intent? = intent.getParcelableExtra(EXTRA_RESULT_DATA)

                wantsAudio = intent.getBooleanExtra(EXTRA_AUDIO, true)
                bitRate = intent.getIntExtra(EXTRA_BIT_RATE, DEFAULT_BIT_RATE)
                val maxWidth = intent.getIntExtra(EXTRA_MAX_WIDTH, DEFAULT_MAX_WIDTH)

                if (resultData == null) {
                    statusMessage = "No projection token supplied"
                    stopSelf()
                    return START_NOT_STICKY
                }

                startStreaming(resultCode, resultData, maxWidth)
            }

            else -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    // ------------------------------------------------------------- start-up

    private fun startStreaming(resultCode: Int, resultData: Intent, maxWidth: Int) {
        if (running.getAndSet(true)) return

        awaitingConsent = false
        audioEnabled = wantsAudio

        // (1) Foreground first — Android 14+ refuses the projection otherwise.
        goForeground()

        // (2) Acquire the projection and register the mandatory callback.
        val manager = getSystemService(MediaProjectionManager::class.java)
        val acquired = runCatching { manager?.getMediaProjection(resultCode, resultData) }
            .getOrElse { error ->
                Log.e(TAG, "getMediaProjection failed", error)
                null
            }

        if (acquired == null) {
            statusMessage = "The system refused the screen-capture token"
            running.set(false)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        projection = acquired
        acquired.registerCallback(projectionCallback, Handler(Looper.getMainLooper()))

        computeCaptureGeometry(maxWidth)

        // (3) Wait for the Mac, then wire up the pipelines.
        acceptThread = Thread({ acceptLoop() }, "AeroCast-Accept").apply {
            isDaemon = true
            start()
        }

        statusMessage = "Waiting for the Mac to connect on port $PORT"
    }

    private fun goForeground() {
        ensureChannel(this)

        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, AeroCastService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("AeroCast is live")
            .setContentText("Mirroring this screen to your Mac")
            .setSmallIcon(R.drawable.droid)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopIntent)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /**
     * Picks an encode resolution: the real display size, scaled down so the
     * long edge fits `maxWidth`, with both dimensions forced even because
     * H.264 macroblocks demand it.
     */
    private fun computeCaptureGeometry(maxWidth: Int) {
        val metrics = DisplayMetrics()
        val displayManager = getSystemService(DisplayManager::class.java)
        val display = displayManager?.getDisplay(Display.DEFAULT_DISPLAY)

        @Suppress("DEPRECATION")
        display?.getRealMetrics(metrics)

        var width = metrics.widthPixels.takeIf { it > 0 } ?: resources.displayMetrics.widthPixels
        var height = metrics.heightPixels.takeIf { it > 0 } ?: resources.displayMetrics.heightPixels
        captureDensity = metrics.densityDpi.takeIf { it > 0 } ?: resources.displayMetrics.densityDpi

        val longEdge = maxOf(width, height)
        val limit = maxOf(maxWidth, 240)
        if (longEdge > limit) {
            val scale = limit.toDouble() / longEdge
            width = (width * scale).toInt()
            height = (height * scale).toInt()
        }

        captureWidth = width - (width % 2)
        captureHeight = height - (height % 2)
        streamWidth = captureWidth
        streamHeight = captureHeight

        Log.i(TAG, "AeroCast geometry ${captureWidth}x${captureHeight} @ ${captureDensity}dpi")
    }

    // ---------------------------------------------------------- socket setup

    private fun acceptLoop() {
        try {
            // Loopback only: this socket is meant to be reached through the adb
            // tunnel, never from the local network.
            val server = ServerSocket(PORT, 1, InetAddress.getByName("127.0.0.1"))
            server.reuseAddress = true
            serverSocket = server

            val socket = server.accept()
            socket.tcpNoDelay = true
            clientSocket = socket

            val out = AeroCastWriter(BufferedOutputStream(socket.getOutputStream(), 64 * 1024))
            writer = out
            out.writeHandshake()

            out.writeJson(
                AeroCastWriter.TYPE_STREAM_INFO,
                json.encodeToString(
                    StreamInfoPayload.serializer(),
                    StreamInfoPayload(
                        width = captureWidth,
                        height = captureHeight,
                        sampleRate = if (wantsAudio) SAMPLE_RATE else 0,
                        channels = if (wantsAudio) CHANNEL_COUNT else 0,
                        videoBitRate = bitRate,
                        frameRate = FRAME_RATE,
                        deviceName = "${Build.MANUFACTURER} ${Build.MODEL}"
                    )
                )
            )

            isStreaming = true
            statusMessage = "Streaming to the Mac"

            startVideoPipeline()
            if (wantsAudio) startAudioPipeline()
            startHeartbeat()

        } catch (error: Exception) {
            if (running.get()) {
                Log.e(TAG, "AeroCast accept loop failed", error)
                statusMessage = "Could not open port $PORT: ${error.message}"
            }
            teardown()
            stopSelf()
        }
    }

    // ---------------------------------------------------------------- video

    private fun startVideoPipeline() {
        val format = MediaFormat.createVideoFormat(VIDEO_MIME, captureWidth, captureHeight).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
            // A keyframe every second keeps the Mac's decoder able to recover
            // quickly if it ever has to flush mid-stream.
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            // Without this, a completely static screen produces no output at
            // all and the Mac's socket looks dead.
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 200_000L)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        }

        val codec = MediaCodec.createEncoderByType(VIDEO_MIME)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = codec.createInputSurface()
        codec.start()

        encoder = codec
        inputSurface = surface

        virtualDisplay = projection?.createVirtualDisplay(
            "AeroCast",
            captureWidth,
            captureHeight,
            captureDensity,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            surface,
            null,
            null
        )

        videoThread = Thread({ drainEncoder(codec) }, "AeroCast-Video").apply {
            isDaemon = true
            start()
        }
    }

    private fun drainEncoder(codec: MediaCodec) {
        val bufferInfo = MediaCodec.BufferInfo()

        try {
            while (running.get()) {
                val index = codec.dequeueOutputBuffer(bufferInfo, 25_000)

                when {
                    index >= 0 -> {
                        val buffer = codec.getOutputBuffer(index)
                        if (buffer != null && bufferInfo.size > 0) {
                            buffer.position(bufferInfo.offset)
                            buffer.limit(bufferInfo.offset + bufferInfo.size)

                            val payload = ByteArray(bufferInfo.size)
                            buffer.get(payload)

                            val isConfig =
                                bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                            val isKeyFrame =
                                bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0

                            writer?.writePacket(
                                type = if (isConfig) AeroCastWriter.TYPE_VIDEO_CONFIG
                                       else AeroCastWriter.TYPE_VIDEO_FRAME,
                                flags = if (isKeyFrame) AeroCastWriter.FLAG_KEYFRAME else 0,
                                presentationTimeUs = bufferInfo.presentationTimeUs,
                                payload = payload
                            )
                        }
                        codec.releaseOutputBuffer(index, false)

                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                    }

                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        // SPS/PPS arrive here on some devices instead of as a
                        // CODEC_CONFIG buffer, so forward them either way.
                        val outputFormat = codec.outputFormat
                        val csd0 = outputFormat.getByteBuffer("csd-0")
                        val csd1 = outputFormat.getByteBuffer("csd-1")
                        if (csd0 != null) {
                            val combined = java.io.ByteArrayOutputStream()
                            val sps = ByteArray(csd0.remaining())
                            csd0.get(sps)
                            combined.write(sps)
                            if (csd1 != null) {
                                val pps = ByteArray(csd1.remaining())
                                csd1.get(pps)
                                combined.write(pps)
                            }
                            writer?.writePacket(
                                AeroCastWriter.TYPE_VIDEO_CONFIG, 0, 0L, combined.toByteArray()
                            )
                        }
                    }

                    index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        // Nothing ready; loop again.
                    }
                }
            }
        } catch (error: Exception) {
            if (running.get()) {
                Log.e(TAG, "Video pipeline stopped", error)
                statusMessage = "Video pipeline error: ${error.message}"
                teardown()
                stopSelf()
            }
        }
    }

    // ---------------------------------------------------------------- audio

    private fun startAudioPipeline() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "RECORD_AUDIO not granted — casting video only")
            audioEnabled = false
            return
        }

        val currentProjection = projection ?: return

        val captureConfig = AudioPlaybackCaptureConfiguration.Builder(currentProjection)
            // Apps that mark their audio as non-capturable are excluded by the
            // platform regardless of what we ask for here.
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()

        val audioFormat = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()

        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        ).coerceAtLeast(4096)

        val record = runCatching {
            AudioRecord.Builder()
                .setAudioFormat(audioFormat)
                .setBufferSizeInBytes(minBuffer * 2)
                .setAudioPlaybackCaptureConfig(captureConfig)
                .build()
        }.getOrElse { error ->
            Log.e(TAG, "Could not build the playback-capture AudioRecord", error)
            audioEnabled = false
            null
        } ?: return

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord failed to initialise")
            record.release()
            audioEnabled = false
            return
        }

        audioRecord = record
        record.startRecording()

        writer?.writeJson(
            AeroCastWriter.TYPE_AUDIO_CONFIG,
            json.encodeToString(
                StreamInfoPayload.serializer(),
                StreamInfoPayload(
                    width = captureWidth,
                    height = captureHeight,
                    sampleRate = SAMPLE_RATE,
                    channels = CHANNEL_COUNT,
                    videoBitRate = bitRate,
                    frameRate = FRAME_RATE,
                    deviceName = "${Build.MANUFACTURER} ${Build.MODEL}"
                )
            )
        )

        audioThread = Thread({ pumpAudio(record, minBuffer) }, "AeroCast-Audio").apply {
            isDaemon = true
            start()
        }
    }

    private fun pumpAudio(record: AudioRecord, bufferSize: Int) {
        // ~20 ms of stereo 16-bit audio per packet: small enough to keep lip
        // sync tight, large enough that we aren't writing a header per sample.
        val chunk = ByteArray(minOf(bufferSize, SAMPLE_RATE * CHANNEL_COUNT * 2 / 50))

        try {
            while (running.get()) {
                val read = record.read(chunk, 0, chunk.size)
                if (read <= 0) {
                    if (read == AudioRecord.ERROR_INVALID_OPERATION ||
                        read == AudioRecord.ERROR_BAD_VALUE
                    ) break
                    continue
                }
                writer?.writePacket(
                    type = AeroCastWriter.TYPE_AUDIO_FRAME,
                    flags = 0,
                    presentationTimeUs = System.nanoTime() / 1000,
                    payload = chunk,
                    offset = 0,
                    length = read
                )
            }
        } catch (error: Exception) {
            if (running.get()) {
                Log.w(TAG, "Audio pipeline stopped", error)
            }
        }
    }

    // ------------------------------------------------------------ heartbeat

    private fun startHeartbeat() {
        heartbeatThread = Thread({
            try {
                while (running.get()) {
                    Thread.sleep(2000)
                    writer?.writeHeartbeat()
                }
            } catch (_: InterruptedException) {
                // Normal shutdown.
            } catch (error: Exception) {
                if (running.get()) Log.w(TAG, "Heartbeat stopped", error)
            }
        }, "AeroCast-Heartbeat").apply {
            isDaemon = true
            start()
        }
    }

    // ------------------------------------------------------------- teardown

    private fun teardown() {
        if (!running.getAndSet(false)) {
            isStreaming = false
            return
        }

        isStreaming = false
        awaitingConsent = false

        runCatching { writer?.writePacket(AeroCastWriter.TYPE_HEARTBEAT, AeroCastWriter.FLAG_END_OF_STREAM, 0, ByteArray(0)) }

        runCatching { audioRecord?.stop() }
        runCatching { audioRecord?.release() }
        audioRecord = null

        runCatching { virtualDisplay?.release() }
        virtualDisplay = null

        runCatching { encoder?.stop() }
        runCatching { encoder?.release() }
        encoder = null

        runCatching { inputSurface?.release() }
        inputSurface = null

        runCatching { projection?.unregisterCallback(projectionCallback) }
        runCatching { projection?.stop() }
        projection = null

        runCatching { clientSocket?.close() }
        clientSocket = null

        runCatching { serverSocket?.close() }
        serverSocket = null

        writer = null

        heartbeatThread?.interrupt()
        heartbeatThread = null
        videoThread = null
        audioThread = null
        acceptThread = null

        streamWidth = 0
        streamHeight = 0
        statusMessage = "Idle"

        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
    }
}
