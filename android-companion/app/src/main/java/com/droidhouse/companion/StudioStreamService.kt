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
import android.hardware.camera2.*
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Log
import android.util.Range
import android.util.Size
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
 * StudioStreamService:
 *
 * Streams hardware camera video (1080p/4K @ 60 FPS via Camera2 + MediaCodec)
 * and uncompressed studio microphone audio (48 kHz stereo 16-bit Linear PCM)
 * to macOS over ADB tunnel (port 8082).
 */
class StudioStreamService : Service() {

    companion object {
        private const val TAG = "StudioStreamService"
        const val CHANNEL_ID = "droidhouse_studio_channel"
        const val NOTIFICATION_ID = 2004
        const val PORT = 8082

        const val EXTRA_CAMERA = "camera"
        const val EXTRA_LENS_ID = "lensId"
        const val EXTRA_RESOLUTION = "resolution"
        const val EXTRA_FPS = "fps"
        const val EXTRA_BIT_RATE = "bitRate"
        const val EXTRA_MIC = "mic"
        const val EXTRA_MIC_UNPROCESSED = "micUnprocessed"

        const val ACTION_START = "com.droidhouse.companion.STUDIO_START"
        const val ACTION_STOP = "com.droidhouse.companion.STUDIO_STOP"

        private const val VIDEO_MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val DEFAULT_BIT_RATE = 35_000_000 // 35 Mbps = visually lossless
        private const val DEFAULT_FPS = 60
        private const val SAMPLE_RATE = 48_000
        private const val CHANNELS = 2

        @Volatile
        var isStreaming: Boolean = false
            private set

        @Volatile
        private var currentLens: String = "back_wide"

        @Volatile
        private var currentResolution: String = "1080p"

        @Volatile
        private var currentFPS: Int = DEFAULT_FPS

        @Volatile
        private var currentBitRate: Int = DEFAULT_BIT_RATE

        @Volatile
        private var currentMicSource: String = "unprocessed"

        @Volatile
        private var statusMessage: String = "Idle"

        fun stateSnapshot(): StudioStatusPayload = StudioStatusPayload(
            streaming = isStreaming,
            port = PORT,
            width = if (currentResolution == "4K") 3840 else 1920,
            height = if (currentResolution == "4K") 2160 else 1080,
            fps = currentFPS,
            bitRate = currentBitRate,
            sampleRate = SAMPLE_RATE,
            channels = CHANNELS,
            lensId = currentLens,
            micSource = currentMicSource,
            message = statusMessage
        )

        fun enumerateCameras(context: Context): List<StudioCameraInfo> {
            val manager = context.getSystemService(CameraManager::class.java) ?: return emptyList()
            val list = mutableListOf<StudioCameraInfo>()

            runCatching {
                for (id in manager.cameraIdList) {
                    val chars = manager.getCameraCharacteristics(id)
                    val facing = chars.get(CameraCharacteristics.LENS_FACING)
                    val facingStr = when (facing) {
                        CameraCharacteristics.LENS_FACING_FRONT -> "front"
                        CameraCharacteristics.LENS_FACING_BACK -> "back"
                        else -> "external"
                    }
                    val focalLengths = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                    val focal = focalLengths?.firstOrNull() ?: 24f

                    val title = when {
                        facingStr == "front" -> "Front Portrait Camera"
                        focal < 20f -> "Ultra-Wide Angle Lens"
                        focal > 50f -> "Telephoto Zoom Lens"
                        else -> "Main Camera"
                    }

                    list.add(StudioCameraInfo(id = id, facing = facingStr, focalLength = focal, title = title))
                }
            }

            return list
        }

        fun requestStart(
            context: Context,
            camera: Boolean,
            lensId: String,
            resolution: String,
            fps: Int,
            bitRate: Int,
            mic: Boolean,
            micUnprocessed: Boolean
        ): Boolean {
            currentLens = lensId
            currentResolution = resolution
            currentFPS = fps
            currentBitRate = bitRate
            currentMicSource = if (micUnprocessed) "unprocessed" else "standard"

            val intent = Intent(context, StudioStreamService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_CAMERA, camera)
                putExtra(EXTRA_LENS_ID, lensId)
                putExtra(EXTRA_RESOLUTION, resolution)
                putExtra(EXTRA_FPS, fps)
                putExtra(EXTRA_BIT_RATE, bitRate)
                putExtra(EXTRA_MIC, mic)
                putExtra(EXTRA_MIC_UNPROCESSED, micUnprocessed)
            }

            // Ensure companion activity is active so camera/audio access is fully allowed
            runCatching {
                val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                }
                if (launchIntent != null) {
                    context.startActivity(launchIntent)
                }
            }

            return runCatching {
                ContextCompat.startForegroundService(context, intent)
                true
            }.getOrElse {
                Log.e(TAG, "Failed to start Studio service", it)
                false
            }
        }

        fun requestStop(context: Context) {
            val intent = Intent(context, StudioStreamService::class.java).apply {
                action = ACTION_STOP
            }
            runCatching { context.startService(intent) }
        }

        fun ensureChannel(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Studio Camera & Microphone",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Live streaming 60FPS video and 48kHz audio to Mac"
                    setShowBadge(false)
                }
            )
        }

        @Volatile
        private var activeInstance: StudioStreamService? = null

        fun switchLens(lensId: String): Boolean {
            currentLens = lensId
            val instance = activeInstance ?: return true
            return instance.applyLens(lensId)
        }

        fun setZoom(zoomRatio: Float): Boolean {
            val instance = activeInstance ?: return false
            return instance.applyZoom(zoomRatio)
        }

        fun setTorch(enabled: Boolean): Boolean {
            val instance = activeInstance ?: return false
            return instance.applyTorch(enabled)
        }
    }

    private val json = Json { encodeDefaults = true }
    private val running = AtomicBoolean(false)

    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private var writer: StudioStreamWriter? = null

    // Video
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var captureRequestBuilder: CaptureRequest.Builder? = null
    private var cameraFacing = "back"
    private var currentZoom = 1.0f
    private var isTorchOn = false
    private var videoEncoder: MediaCodec? = null
    private var encoderInputSurface: Surface? = null
    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null

    // Audio
    private var audioRecord: AudioRecord? = null

    // Threads
    private var acceptThread: Thread? = null
    private var videoThread: Thread? = null
    private var audioThread: Thread? = null
    private var heartbeatThread: Thread? = null

    private var targetWidth = 1920
    private var targetHeight = 1080
    private var targetFps = 60
    private var targetBitRate = DEFAULT_BIT_RATE
    private var enableCamera = true
    private var enableMic = true
    private var unprocessedMic = true
    private var lensSelection = "back_wide"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                teardown()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                enableCamera = intent.getBooleanExtra(EXTRA_CAMERA, true)
                lensSelection = intent.getStringExtra(EXTRA_LENS_ID) ?: "back_wide"
                val res = intent.getStringExtra(EXTRA_RESOLUTION) ?: "1080p"
                targetWidth = if (res == "4K") 3840 else 1920
                targetHeight = if (res == "4K") 2160 else 1080
                targetFps = intent.getIntExtra(EXTRA_FPS, 60)
                targetBitRate = intent.getIntExtra(EXTRA_BIT_RATE, DEFAULT_BIT_RATE)
                enableMic = intent.getBooleanExtra(EXTRA_MIC, true)
                unprocessedMic = intent.getBooleanExtra(EXTRA_MIC_UNPROCESSED, true)

                startStudioPipeline()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    private fun onConnectionClosed(reason: String) {
        if (!running.get()) return
        Log.i(TAG, "Studio stream connection ended: $reason")
        statusMessage = "Idle"
        teardown()
        stopSelf()
    }

    private fun startStudioPipeline() {
        if (running.get()) {
            teardown()
        }
        running.set(true)
        activeInstance = this

        goForeground()

        cameraThread = HandlerThread("StudioCameraThread").apply {
            start()
            cameraHandler = Handler(looper)
        }

        acceptThread = Thread({ acceptLoop() }, "Studio-Accept").apply {
            isDaemon = true
            start()
        }

        statusMessage = "Waiting for Mac to connect on port $PORT"
    }

    private fun goForeground() {
        ensureChannel(this)

        val stopIntent = PendingIntent.getService(
            this,
            2,
            Intent(this, StudioStreamService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Studio Broadcast is live")
            .setContentText("Transmitting studio camera & microphone to Mac")
            .setSmallIcon(R.drawable.droid)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopIntent)
            .build()

        var fgsType = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            fgsType = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && fgsType != 0) {
                startForeground(NOTIFICATION_ID, notification, fgsType)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed startForeground with type, trying default", e)
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun acceptLoop() {
        try {
            val server = ServerSocket(PORT, 1, InetAddress.getByName("127.0.0.1"))
            server.reuseAddress = true
            serverSocket = server

            val socket = server.accept()
            socket.tcpNoDelay = true
            clientSocket = socket

            val out = StudioStreamWriter(BufferedOutputStream(socket.getOutputStream(), 128 * 1024))
            writer = out
            out.writeHandshake()

            val infoJson = json.encodeToString(
                StudioStreamInfoPayload.serializer(),
                StudioStreamInfoPayload(
                    width = targetWidth,
                    height = targetHeight,
                    frameRate = targetFps,
                    videoBitRate = targetBitRate,
                    sampleRate = SAMPLE_RATE,
                    channels = CHANNELS,
                    lensFacing = if (lensSelection.contains("front")) "front" else "back",
                    lensName = lensSelection,
                    deviceModel = "${Build.MANUFACTURER} ${Build.MODEL}",
                    micSource = if (unprocessedMic) "unprocessed" else "standard"
                )
            )
            out.writeJson(StudioStreamWriter.TYPE_STREAM_INFO, infoJson)

            isStreaming = true
            statusMessage = "Broadcasting to Mac"

            if (enableCamera) startCameraPipeline()
            if (enableMic) startAudioPipeline()
            startHeartbeat()

        } catch (err: Exception) {
            if (running.get()) {
                Log.e(TAG, "Accept error", err)
                statusMessage = "Studio port error: ${err.message}"
            }
            onConnectionClosed("Accept socket error: ${err.message}")
        }
    }

    // ------------------------------------------------------------- Camera
    private fun startCameraPipeline() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "CAMERA permission not granted")
            return
        }

        val manager = getSystemService(CameraManager::class.java) ?: return
        val targetCameraId = resolveCameraId(manager, lensSelection)

        // Setup MediaCodec encoder
        val format = MediaFormat.createVideoFormat(VIDEO_MIME, targetWidth, targetHeight).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, targetBitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, targetFps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_LATENCY, 0)
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000L)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
        }

        val codec = MediaCodec.createEncoderByType(VIDEO_MIME)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = codec.createInputSurface()
        codec.start()

        videoEncoder = codec
        encoderInputSurface = surface

        cameraFacing = if (lensSelection.contains("front")) "front" else "back"

        manager.openCamera(targetCameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                cameraDevice = camera
                createCameraSession(camera, surface)
            }

            override fun onDisconnected(camera: CameraDevice) {
                camera.close()
                cameraDevice = null
            }

            override fun onError(camera: CameraDevice, error: Int) {
                camera.close()
                cameraDevice = null
            }
        }, cameraHandler)

        videoThread = Thread({ drainVideoEncoder(codec) }, "Studio-Video").apply {
            isDaemon = true
            start()
        }
    }

    private fun resolveCameraId(manager: CameraManager, selection: String): String {
        val targetFacing = if (selection.contains("front")) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        val candidateIds = mutableListOf<Triple<String, Float, Int>>()

        for (id in manager.cameraIdList) {
            val chars = runCatching { manager.getCameraCharacteristics(id) }.getOrNull() ?: continue
            val facing = chars.get(CameraCharacteristics.LENS_FACING) ?: continue
            if (facing != targetFacing) continue
            val focalLengths = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            val focal = focalLengths?.firstOrNull() ?: 24f
            candidateIds.add(Triple(id, focal, facing))
        }

        if (candidateIds.isEmpty()) return manager.cameraIdList.firstOrNull() ?: "0"

        candidateIds.sortBy { it.second }

        return when (selection) {
            "back_ultra" -> candidateIds.first().first
            "back_tele" -> candidateIds.last().first
            "back_wide" -> {
                if (candidateIds.size > 2) candidateIds[1].first else candidateIds.first().first
            }
            else -> candidateIds.first().first
        }
    }

    private fun createCameraSession(camera: CameraDevice, surface: Surface) {
        val requestBuilder = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
            addTarget(surface)
            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
            set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(targetFps, targetFps))
            set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON)
            if (isTorchOn) {
                set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH)
            }
        }
        applyLensZoomToBuilder(requestBuilder, lensSelection)
        captureRequestBuilder = requestBuilder

        camera.createCaptureSession(listOf(surface), object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(session: CameraCaptureSession) {
                captureSession = session
                runCatching {
                    session.setRepeatingRequest(requestBuilder.build(), null, cameraHandler)
                }
            }

            override fun onConfigureFailed(session: CameraCaptureSession) {
                Log.e(TAG, "Camera session configuration failed")
            }
        }, cameraHandler)
    }

    fun applyLens(lensId: String): Boolean {
        lensSelection = lensId
        currentLens = lensId
        val targetFacing = if (lensId.contains("front")) "front" else "back"
        val facingChanged = (targetFacing != cameraFacing)

        if (!facingChanged && captureSession != null && captureRequestBuilder != null) {
            applyLensZoomToBuilder(captureRequestBuilder!!, lensId)
            val session = captureSession ?: return false
            val builder = captureRequestBuilder ?: return false
            return runCatching {
                session.setRepeatingRequest(builder.build(), null, cameraHandler)
                true
            }.getOrDefault(false)
        }

        cameraHandler?.post {
            reopenCamera(lensId)
        }
        return true
    }

    private fun applyLensZoomToBuilder(builder: CaptureRequest.Builder, lens: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val manager = getSystemService(CameraManager::class.java) ?: return
            val id = cameraDevice?.id ?: return
            val chars = runCatching { manager.getCameraCharacteristics(id) }.getOrNull() ?: return
            val zoomRange = chars.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE) ?: Range(1.0f, 10.0f)

            val targetRatio = when (lens) {
                "back_ultra" -> maxOf(zoomRange.lower, 0.5f)
                "back_tele" -> minOf(zoomRange.upper, maxOf(3.0f, zoomRange.lower))
                "back_wide" -> 1.0f
                else -> 1.0f
            }
            currentZoom = targetRatio
            builder.set(CaptureRequest.CONTROL_ZOOM_RATIO, targetRatio)
        }
    }

    fun applyZoom(zoomRatio: Float): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val builder = captureRequestBuilder ?: return false
            val session = captureSession ?: return false
            val manager = getSystemService(CameraManager::class.java) ?: return false
            val id = cameraDevice?.id ?: return false
            val chars = runCatching { manager.getCameraCharacteristics(id) }.getOrNull() ?: return false
            val zoomRange = chars.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE) ?: Range(1.0f, 10.0f)
            val clamped = zoomRatio.coerceIn(zoomRange.lower, zoomRange.upper)
            currentZoom = clamped
            builder.set(CaptureRequest.CONTROL_ZOOM_RATIO, clamped)
            return runCatching {
                session.setRepeatingRequest(builder.build(), null, cameraHandler)
                true
            }.getOrDefault(false)
        }
        return false
    }

    fun applyTorch(enabled: Boolean): Boolean {
        val builder = captureRequestBuilder ?: return false
        val session = captureSession ?: return false
        isTorchOn = enabled
        builder.set(CaptureRequest.FLASH_MODE, if (enabled) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF)
        return runCatching {
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
            true
        }.getOrDefault(false)
    }

    private fun reopenCamera(selection: String) {
        val manager = getSystemService(CameraManager::class.java) ?: return
        val surface = encoderInputSurface ?: return

        runCatching { captureSession?.close() }
        captureSession = null
        captureRequestBuilder = null

        runCatching { cameraDevice?.close() }
        cameraDevice = null

        val targetCameraId = resolveCameraId(manager, selection)
        cameraFacing = if (selection.contains("front")) "front" else "back"

        manager.openCamera(targetCameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                cameraDevice = camera
                createCameraSession(camera, surface)
            }

            override fun onDisconnected(camera: CameraDevice) {
                camera.close()
                cameraDevice = null
            }

            override fun onError(camera: CameraDevice, error: Int) {
                camera.close()
                cameraDevice = null
            }
        }, cameraHandler)
    }

    private fun drainVideoEncoder(codec: MediaCodec) {
        val bufferInfo = MediaCodec.BufferInfo()
        try {
            while (running.get()) {
                val index = codec.dequeueOutputBuffer(bufferInfo, 25_000)
                if (index >= 0) {
                    val buffer = codec.getOutputBuffer(index)
                    if (buffer != null && bufferInfo.size > 0) {
                        buffer.position(bufferInfo.offset)
                        buffer.limit(bufferInfo.offset + bufferInfo.size)

                        val payload = ByteArray(bufferInfo.size)
                        buffer.get(payload)

                        val isConfig = bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        val isKey = bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0

                        writer?.writePacket(
                            type = if (isConfig) StudioStreamWriter.TYPE_VIDEO_CONFIG else StudioStreamWriter.TYPE_VIDEO_FRAME,
                            flags = if (isKey) StudioStreamWriter.FLAG_KEYFRAME else 0,
                            presentationTimeUs = bufferInfo.presentationTimeUs,
                            payload = payload
                        )
                    }
                    codec.releaseOutputBuffer(index, false)
                }
            }
        } catch (err: Exception) {
            if (running.get()) {
                Log.w(TAG, "Video drain stopped", err)
                onConnectionClosed("Video stream closed: ${err.message}")
            }
        }
    }

    // ------------------------------------------------------------- Audio
    private fun startAudioPipeline() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "RECORD_AUDIO not granted")
            return
        }

        val audioSource = if (unprocessedMic && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            MediaRecorder.AudioSource.UNPROCESSED
        } else {
            MediaRecorder.AudioSource.MIC
        }

        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()

        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        ).coerceAtLeast(4096)

        val record = runCatching {
            AudioRecord.Builder()
                .setAudioSource(audioSource)
                .setAudioFormat(format)
                .setBufferSizeInBytes(minBuf * 2)
                .build()
        }.getOrNull() ?: return

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return
        }

        audioRecord = record
        record.startRecording()

        audioThread = Thread({ pumpAudio(record, minBuf) }, "Studio-Audio").apply {
            isDaemon = true
            start()
        }
    }

    private fun pumpAudio(record: AudioRecord, bufferSize: Int) {
        val chunk = ByteArray(minOf(bufferSize, SAMPLE_RATE * CHANNELS * 2 / 50)) // ~20ms
        try {
            while (running.get()) {
                val read = record.read(chunk, 0, chunk.size)
                if (read > 0) {
                    writer?.writePacket(
                        type = StudioStreamWriter.TYPE_AUDIO_FRAME,
                        flags = if (unprocessedMic) StudioStreamWriter.FLAG_UNPROCESSED else 0,
                        presentationTimeUs = System.nanoTime() / 1000,
                        payload = chunk,
                        offset = 0,
                        length = read
                    )
                }
            }
        } catch (err: Exception) {
            if (running.get()) {
                Log.w(TAG, "Audio pump stopped", err)
                onConnectionClosed("Audio stream closed: ${err.message}")
            }
        }
    }

    private fun startHeartbeat() {
        heartbeatThread = Thread({
            try {
                while (running.get()) {
                    Thread.sleep(2000)
                    writer?.writeHeartbeat()
                }
            } catch (_: InterruptedException) {
            }
        }, "Studio-Heartbeat").apply {
            isDaemon = true
            start()
        }
    }

    private fun teardown() {
        if (!running.getAndSet(false)) return

        if (activeInstance === this) {
            activeInstance = null
        }
        isStreaming = false

        runCatching { captureSession?.close() }
        captureSession = null
        captureRequestBuilder = null

        runCatching { cameraDevice?.close() }
        cameraDevice = null

        runCatching { videoEncoder?.stop(); videoEncoder?.release() }
        videoEncoder = null

        runCatching { encoderInputSurface?.release() }
        encoderInputSurface = null

        runCatching { audioRecord?.stop(); audioRecord?.release() }
        audioRecord = null

        runCatching { clientSocket?.close() }
        clientSocket = null

        runCatching { serverSocket?.close() }
        serverSocket = null

        writer = null

        cameraThread?.quitSafely()
        cameraThread = null

        statusMessage = "Idle"
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
    }
}
