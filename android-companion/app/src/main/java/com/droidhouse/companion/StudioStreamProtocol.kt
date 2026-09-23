package com.droidhouse.companion

import java.io.OutputStream
import java.nio.ByteBuffer

/**
 * StudioStreamWriter:
 *
 * Wire format for Studio Camera & Studio Microphone:
 *   HEADER: "STUD" (4B) + version (1B = 1)
 *   PACKET: type (1B) + flags (1B) + ptsUs (8B) + length (4B) + payload (length bytes)
 *
 * Transmits 60 FPS hardware H.264 video (30-60 Mbps) and bit-perfect uncompressed
 * 48 kHz 16-bit stereo PCM audio to macOS over ADB tunnel (port 8082).
 */
class StudioStreamWriter(private val output: OutputStream) {

    companion object {
        val MAGIC = byteArrayOf(0x53, 0x54, 0x55, 0x44) // "STUD"
        const val VERSION: Byte = 1

        const val TYPE_STREAM_INFO: Byte = 1
        const val TYPE_VIDEO_CONFIG: Byte = 2
        const val TYPE_VIDEO_FRAME: Byte = 3
        const val TYPE_AUDIO_CONFIG: Byte = 4
        const val TYPE_AUDIO_FRAME: Byte = 5
        const val TYPE_HEARTBEAT: Byte = 6

        const val FLAG_KEYFRAME: Byte = 1
        const val FLAG_END_OF_STREAM: Byte = 2
        const val FLAG_UNPROCESSED: Byte = 4

        private const val HEADER_SIZE = 14
    }

    private val lock = Any()
    private val header = ByteArray(HEADER_SIZE)

    @Volatile
    var bytesWritten: Long = 0L
        private set

    fun writeHandshake() = synchronized(lock) {
        output.write(MAGIC)
        output.write(byteArrayOf(VERSION))
        output.flush()
        bytesWritten += MAGIC.size + 1
    }

    fun writePacket(type: Byte, flags: Byte, presentationTimeUs: Long, payload: ByteArray) =
        writePacket(type, flags, presentationTimeUs, payload, 0, payload.size)

    fun writePacket(
        type: Byte,
        flags: Byte,
        presentationTimeUs: Long,
        payload: ByteArray,
        offset: Int,
        length: Int
    ) = synchronized(lock) {
        header[0] = type
        header[1] = flags
        for (i in 0 until 8) {
            header[2 + i] = ((presentationTimeUs ushr ((7 - i) * 8)) and 0xFF).toByte()
        }
        header[10] = ((length ushr 24) and 0xFF).toByte()
        header[11] = ((length ushr 16) and 0xFF).toByte()
        header[12] = ((length ushr 8) and 0xFF).toByte()
        header[13] = (length and 0xFF).toByte()

        output.write(header)
        if (length > 0) {
            output.write(payload, offset, length)
        }
        output.flush()
        bytesWritten += HEADER_SIZE + length
    }

    fun writePacket(type: Byte, flags: Byte, presentationTimeUs: Long, buffer: ByteBuffer, length: Int) {
        val bytes = ByteArray(length)
        buffer.get(bytes)
        writePacket(type, flags, presentationTimeUs, bytes, 0, length)
    }

    fun writeJson(type: Byte, json: String) {
        writePacket(type, 0, 0L, json.toByteArray(Charsets.UTF_8))
    }

    fun writeHeartbeat() {
        writePacket(TYPE_HEARTBEAT, 0, System.nanoTime() / 1000, ByteArray(0))
    }
}
