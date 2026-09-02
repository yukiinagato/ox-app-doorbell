package jp.keihan.doorbell

import android.media.MediaCodecInfo
import java.nio.ByteBuffer

/** Bounded AVC byte-stream conversion shared by the encoder and live decoder. */
internal object AvcByteStream {
    const val MAX_ACCESS_UNIT = 2 * 1024 * 1024
    private val START_CODE = byteArrayOf(0, 0, 0, 1)

    val safeByteColorFormats = setOf(
        MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar,
        MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420PackedPlanar,
        MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar,
        MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420PackedSemiPlanar,
    )

    fun isPlanar(color: Int): Boolean =
        color == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar ||
            color == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420PackedPlanar

    fun copyNv21(src: ByteArray, width: Int, height: Int, color: Int, dst: ByteBuffer): Boolean {
        val ySize = width * height
        val size = ySize * 3 / 2
        if (src.size < size || dst.remaining() < size || color !in safeByteColorFormats) return false
        dst.put(src, 0, ySize)
        if (isPlanar(color)) {
            var i = ySize + 1
            while (i < size) { dst.put(src[i]); i += 2 } // U
            i = ySize
            while (i < size) { dst.put(src[i]); i += 2 } // V
        } else {
            var i = ySize
            while (i + 1 < size) {
                dst.put(src[i + 1]) // U
                dst.put(src[i])     // V
                i += 2
            }
        }
        return true
    }

    /** Accept Annex-B or four-byte AVCC length prefixes and return canonical Annex-B. */
    fun toAnnexB(input: ByteArray): ByteArray? {
        if (input.isEmpty() || input.size > MAX_ACCESS_UNIT) return null
        if (startCodeLength(input, 0) != 0) return input
        var at = 0
        var outSize = 0
        while (at + 4 <= input.size) {
            val n = readU32(input, at)
            if (n <= 0 || n > MAX_ACCESS_UNIT || at + 4L + n > input.size) return null
            outSize += 4 + n
            if (outSize > MAX_ACCESS_UNIT) return null
            at += 4 + n
        }
        if (at != input.size) return null
        val out = ByteArray(outSize)
        at = 0
        var write = 0
        while (at < input.size) {
            val n = readU32(input, at)
            System.arraycopy(START_CODE, 0, out, write, 4)
            System.arraycopy(input, at + 4, out, write + 4, n)
            at += 4 + n
            write += 4 + n
        }
        return out
    }

    fun prepend(first: ByteArray?, second: ByteArray): ByteArray {
        if (first == null || first.isEmpty()) return second
        if (first.size + second.size > MAX_ACCESS_UNIT) return second
        return ByteArray(first.size + second.size).also {
            System.arraycopy(first, 0, it, 0, first.size)
            System.arraycopy(second, 0, it, first.size, second.size)
        }
    }

    fun containsNalType(annexB: ByteArray, type: Int): Boolean =
        findNalPayload(annexB, type) != null

    /** profile_idc from SPS, or null until codec configuration is available. */
    fun profileIdc(annexB: ByteArray): Int? {
        val payload = findNalPayload(annexB, 7) ?: return null
        return if (payload + 1 < annexB.size) annexB[payload + 1].toInt() and 0xff else null
    }

    fun withStartCode(nal: ByteArray): ByteBuffer = ByteBuffer.wrap(prepend(START_CODE, nal))

    private fun findNalPayload(data: ByteArray, wanted: Int): Int? {
        var i = 0
        while (i + 3 < data.size) {
            val sc = startCodeLength(data, i)
            if (sc == 0) { i++; continue }
            val payload = i + sc
            if (payload < data.size && (data[payload].toInt() and 0x1f) == wanted) return payload
            i = payload + 1
        }
        return null
    }

    private fun startCodeLength(data: ByteArray, at: Int): Int {
        if (at + 3 <= data.size && data[at] == 0.toByte() && data[at + 1] == 0.toByte()) {
            if (data[at + 2] == 1.toByte()) return 3
            if (at + 4 <= data.size && data[at + 2] == 0.toByte() && data[at + 3] == 1.toByte())
                return 4
        }
        return 0
    }

    private fun readU32(data: ByteArray, at: Int): Int =
        ((data[at].toInt() and 0xff) shl 24) or
            ((data[at + 1].toInt() and 0xff) shl 16) or
            ((data[at + 2].toInt() and 0xff) shl 8) or
            (data[at + 3].toInt() and 0xff)
}
