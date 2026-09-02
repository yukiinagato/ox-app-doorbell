package jp.ox.doorbell

import java.io.EOFException
import java.io.InputStream

/** Bounded parser for doorbell-core's endless fMP4 stream. */
internal class Fmp4StreamReader(
    private val input: InputStream,
    private val listener: Listener,
) {
    data class Config(
        val sps: ByteArray,
        val pps: ByteArray,
        val width: Int,
        val height: Int,
    )

    data class Sample(
        val annexB: ByteArray,
        val keyframe: Boolean,
        val presentationTimeUs: Long,
        val durationUs: Long,
        val captureMs: Long,
    )

    interface Listener {
        fun onConfig(config: Config)
        fun onSample(sample: Sample)
    }

    private data class TrunSample(val durationMs: Int, val size: Int, val flags: Int)

    private var configured = false
    private var pendingSamples = emptyList<TrunSample>()
    private var captureTimes = LongArray(0)
    private var presentationMs = 0L
    private var lastDurationMs = 40

    fun pump(keepRunning: () -> Boolean) {
        while (keepRunning()) {
            val header = readHeaderOrEof() ?: return
            val max = when (header.type) {
                TYPE_MOOV -> MAX_INIT_BOX
                TYPE_MOOF -> MAX_FRAGMENT_BOX
                TYPE_MDAT -> MAX_MDAT_BOX
                TYPE_DBTS -> MAX_DBTS_BOX
                else -> MAX_OTHER_BOX
            }
            if (header.bodySize < 0 || header.bodySize > max)
                throw ParseException("${fourcc(header.type)} box too large: ${header.bodySize}")
            val body = ByteArray(header.bodySize)
            readFully(body)
            when (header.type) {
                TYPE_MOOV -> {
                    val config = parseInit(body)
                        ?: throw ParseException("moov has no valid avcC")
                    configured = true
                    listener.onConfig(config)
                }
                TYPE_DBTS -> captureTimes = parseCaptureTimes(body)
                TYPE_MOOF -> {
                    if (!configured) throw ParseException("moof before AVC configuration")
                    pendingSamples = parseMoof(body)
                    if (pendingSamples.isEmpty()) throw ParseException("moof has no samples")
                }
                TYPE_MDAT -> emitMdat(body)
            }
        }
    }

    private fun emitMdat(body: ByteArray) {
        if (pendingSamples.isEmpty()) return
        var offset = 0
        for ((index, sample) in pendingSamples.withIndex()) {
            if (sample.size <= 0 || sample.size > AvcByteStream.MAX_ACCESS_UNIT ||
                offset + sample.size > body.size) throw ParseException("invalid trun sample size")
            val avcc = body.copyOfRange(offset, offset + sample.size)
            val annexB = AvcByteStream.toAnnexB(avcc)
                ?: throw ParseException("invalid AVCC access unit")
            val key = ((sample.flags ushr 24) and 0x3) == 2
            val duration = if (sample.durationMs > 0) sample.durationMs else lastDurationMs
            if (duration > 0) lastDurationMs = duration
            listener.onSample(Sample(
                annexB,
                key,
                presentationMs * 1_000L,
                duration * 1_000L,
                captureTimes.getOrElse(index) { 0L },
            ))
            presentationMs += duration
            offset += sample.size
        }
        pendingSamples = emptyList()
        captureTimes = LongArray(0)
    }

    private data class Header(val type: Int, val bodySize: Int)

    private fun readHeaderOrEof(): Header? {
        val first = input.read()
        if (first < 0) return null
        val raw = ByteArray(8)
        raw[0] = first.toByte()
        readFully(raw, 1, 7)
        var size = u32(raw, 0)
        val type = i32(raw, 4)
        var headerSize = 8L
        if (size == 1L) {
            val extended = ByteArray(8)
            readFully(extended)
            size = u64(extended, 0)
            headerSize = 16L
        }
        if (size == 0L || size < headerSize || size - headerSize > Int.MAX_VALUE)
            throw ParseException("invalid ${fourcc(type)} box size")
        return Header(type, (size - headerSize).toInt())
    }

    private fun readFully(target: ByteArray, offset: Int = 0, count: Int = target.size) {
        var at = offset
        val end = offset + count
        while (at < end) {
            val n = input.read(target, at, end - at)
            if (n < 0) throw EOFException("truncated fMP4 stream")
            if (n == 0) continue
            at += n
        }
    }

    class ParseException(message: String) : Exception(message)

    companion object {
        private const val MAX_INIT_BOX = 2 * 1024 * 1024
        private const val MAX_FRAGMENT_BOX = 512 * 1024
        private const val MAX_MDAT_BOX = AvcByteStream.MAX_ACCESS_UNIT
        private const val MAX_DBTS_BOX = 4 + 64 * 8
        private const val MAX_OTHER_BOX = 2 * 1024 * 1024
        private const val MAX_SAMPLES = 64

        private val TYPE_MOOV = type("moov")
        private val TYPE_MOOF = type("moof")
        private val TYPE_MDAT = type("mdat")
        private val TYPE_DBTS = type("dbts")

        internal fun parseInit(body: ByteArray): Config? {
            val result = InitCollector()
            if (!scanInit(body, 0, body.size, result, 0)) return null
            val sps = result.sps ?: return null
            val pps = result.pps ?: return null
            if (result.width !in 1..4096 || result.height !in 1..4096) return null
            return Config(sps, pps, result.width, result.height)
        }

        private class InitCollector {
            var sps: ByteArray? = null
            var pps: ByteArray? = null
            var width = 0
            var height = 0
        }

        private fun scanInit(
            data: ByteArray,
            start: Int,
            end: Int,
            result: InitCollector,
            depth: Int,
        ): Boolean {
            if (depth > 10 || start < 0 || end > data.size || start > end) return false
            var at = start
            while (at + 8 <= end) {
                val size = u32(data, at)
                if (size < 8 || size > Int.MAX_VALUE || at + size > end) return false
                val boxEnd = at + size.toInt()
                val boxType = i32(data, at + 4)
                val bodyAt = at + 8
                when (fourcc(boxType)) {
                    "avcC" -> if (extractAvcC(data, bodyAt, boxEnd, result)) return true
                    "stsd" -> if (bodyAt + 8 <= boxEnd &&
                        scanInit(data, bodyAt + 8, boxEnd, result, depth + 1)) return true
                    "avc1", "avc2", "encv" -> {
                        if (bodyAt + 78 > boxEnd) return false
                        result.width = u16(data, bodyAt + 24)
                        result.height = u16(data, bodyAt + 26)
                        if (scanInit(data, bodyAt + 78, boxEnd, result, depth + 1)) return true
                    }
                    "moov", "trak", "mdia", "minf", "stbl", "mvex", "edts" ->
                        if (scanInit(data, bodyAt, boxEnd, result, depth + 1)) return true
                }
                at = boxEnd
            }
            return result.sps != null && result.pps != null
        }

        private fun extractAvcC(
            data: ByteArray,
            start: Int,
            end: Int,
            result: InitCollector,
        ): Boolean {
            if (end - start < 11 || data[start].toInt() != 1) return false
            val spsCount = data[start + 5].toInt() and 0x1f
            if (spsCount < 1) return false
            var at = start + 6
            val spsLength = u16(data, at)
            at += 2
            if (spsLength !in 4..4096 || at + spsLength > end) return false
            result.sps = data.copyOfRange(at, at + spsLength)
            at += spsLength
            // Skip additional SPS entries while keeping the first supported stream config.
            repeat(spsCount - 1) {
                if (at + 2 > end) return false
                val n = u16(data, at); at += 2
                if (n <= 0 || at + n > end) return false
                at += n
            }
            if (at >= end) return false
            val ppsCount = data[at].toInt() and 0xff
            at++
            if (ppsCount < 1 || at + 2 > end) return false
            val ppsLength = u16(data, at)
            at += 2
            if (ppsLength !in 2..4096 || at + ppsLength > end) return false
            result.pps = data.copyOfRange(at, at + ppsLength)
            return true
        }

        private fun parseMoof(body: ByteArray): List<TrunSample> {
            var at = 0
            while (at + 8 <= body.size) {
                val size = u32(body, at)
                if (size < 8 || size > Int.MAX_VALUE || at + size > body.size) return emptyList()
                val end = at + size.toInt()
                if (fourcc(i32(body, at + 4)) == "traf") {
                    var child = at + 8
                    while (child + 8 <= end) {
                        val childSize = u32(body, child)
                        if (childSize < 8 || childSize > Int.MAX_VALUE || child + childSize > end)
                            return emptyList()
                        val childEnd = child + childSize.toInt()
                        if (fourcc(i32(body, child + 4)) == "trun")
                            return parseTrun(body, child + 8, childEnd)
                        child = childEnd
                    }
                }
                at = end
            }
            return emptyList()
        }

        private fun parseTrun(data: ByteArray, start: Int, end: Int): List<TrunSample> {
            if (end - start < 8) return emptyList()
            val version = data[start].toInt() and 0xff
            val flags = ((data[start + 1].toInt() and 0xff) shl 16) or
                ((data[start + 2].toInt() and 0xff) shl 8) or
                (data[start + 3].toInt() and 0xff)
            val countLong = u32(data, start + 4)
            if (countLong > MAX_SAMPLES) return emptyList()
            val count = countLong.toInt()
            var at = start + 8
            if (flags and 0x000001 != 0) at += 4
            var firstFlags: Int? = null
            if (flags and 0x000004 != 0) {
                if (at + 4 > end) return emptyList()
                firstFlags = i32(data, at); at += 4
            }
            val hasDuration = flags and 0x000100 != 0
            val hasSize = flags and 0x000200 != 0
            val hasFlags = flags and 0x000400 != 0
            val hasComposition = flags and 0x000800 != 0
            if (!hasSize) return emptyList()
            val result = ArrayList<TrunSample>(count)
            repeat(count) { index ->
                val needed = (if (hasDuration) 4 else 0) + 4 +
                    (if (hasFlags) 4 else 0) + (if (hasComposition) 4 else 0)
                if (at + needed > end) return emptyList()
                val duration = if (hasDuration) i32(data, at).also { at += 4 } else 0
                val size = i32(data, at).also { at += 4 }
                val sampleFlags = when {
                    hasFlags -> i32(data, at).also { at += 4 }
                    index == 0 && firstFlags != null -> firstFlags
                    else -> 0
                } ?: 0
                if (hasComposition) {
                    val composition = i32(data, at); at += 4
                    if (composition != 0 || version != 0) return emptyList()
                }
                if (duration < 0 || size <= 0 || size > AvcByteStream.MAX_ACCESS_UNIT)
                    return emptyList()
                result.add(TrunSample(duration, size, sampleFlags))
            }
            return result
        }

        private fun parseCaptureTimes(body: ByteArray): LongArray {
            if (body.size < 4) throw ParseException("truncated dbts")
            val countLong = u32(body, 0)
            if (countLong > MAX_SAMPLES || 4L + countLong * 8L > body.size)
                throw ParseException("invalid dbts count")
            return LongArray(countLong.toInt()) { index -> u64(body, 4 + index * 8) }
        }

        private fun type(value: String): Int =
            (value[0].code shl 24) or (value[1].code shl 16) or
                (value[2].code shl 8) or value[3].code

        private fun fourcc(value: Int): String = String(charArrayOf(
            ((value ushr 24) and 0xff).toChar(),
            ((value ushr 16) and 0xff).toChar(),
            ((value ushr 8) and 0xff).toChar(),
            (value and 0xff).toChar(),
        ))

        private fun u16(data: ByteArray, at: Int): Int =
            ((data[at].toInt() and 0xff) shl 8) or (data[at + 1].toInt() and 0xff)

        private fun i32(data: ByteArray, at: Int): Int =
            ((data[at].toInt() and 0xff) shl 24) or
                ((data[at + 1].toInt() and 0xff) shl 16) or
                ((data[at + 2].toInt() and 0xff) shl 8) or
                (data[at + 3].toInt() and 0xff)

        private fun u32(data: ByteArray, at: Int): Long = i32(data, at).toLong() and 0xffffffffL

        private fun u64(data: ByteArray, at: Int): Long =
            (u32(data, at) shl 32) or u32(data, at + 4)
    }
}
