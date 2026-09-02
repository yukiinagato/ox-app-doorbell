package jp.keihan.doorbell

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import java.util.ArrayDeque

/** Camera1 NV21 to Baseline AVC with API 16-20 and API 21+ buffer adapters. */
internal class VideoEncoder(
    private val core: DoorbellCore,
    private val listener: (Snapshot) -> Unit = {},
    private val commissioningGate: EncoderCommissioningGate = AlwaysCommissionedEncoder,
) {
    data class Snapshot(
        val state: String,
        val codec: String = "",
        val colorFormat: Int = 0,
        val width: Int = 0,
        val height: Int = 0,
        val fps: Int = 0,
        val certified: Boolean = false,
        val error: String = "",
    )

    private data class Candidate(
        val codecName: String,
        val colorFormat: Int,
        val profileKeys: Boolean,
    ) {
        val id = "$codecName:$colorFormat:$profileKeys"
    }

    private data class QueuedTime(val ptsUs: Long, val captureMs: Long)

    @Volatile private var codec: MediaCodec? = null
    @Volatile private var drainRunning = false
    @Volatile private var started = false
    @Volatile private var terminalFailure = false
    @Volatile var snapshot = Snapshot("idle")
        private set

    private var width = 0
    private var height = 0
    private var fps = 15
    private var bitrateKbps = 600
    private var certified = false
    private var forceCommissioned = false
    private var allowSoftware = false
    private var lastFeedElapsedMs = 0L
    private var sessionStartNs = 0L
    private var lastPtsUs = -1L
    private var configData: ByteArray? = null
    private var profileIdc: Int? = null
    private var sawKeyframe = false
    private var sawSps = false
    private var sawPps = false
    private var forwardingStarted = false
    private var probeStartedMs = 0L
    private var bufferAccess: CodecBufferAccess? = null
    private var currentCandidate: Candidate? = null
    private var drainThread: Thread? = null
    private val rejectedCandidates = LinkedHashSet<String>()
    private val queuedTimes = ArrayDeque<QueuedTime>()

    val isRunning: Boolean get() = started
    val hasTerminalFailure: Boolean get() = terminalFailure

    @Synchronized
    fun start(
        fps: Int,
        bitrateKbps: Int,
        certified: Boolean = false,
        allowSoftware: Boolean = false,
    ) {
        this.fps = fps.coerceIn(5, 30)
        this.bitrateKbps = bitrateKbps.coerceIn(128, 4_000)
        this.forceCommissioned = certified
        this.certified = certified
        this.allowSoftware = allowSoftware
        releaseCodecLocked()
        rejectedCandidates.clear()
        terminalFailure = false
        width = 0
        height = 0
        lastFeedElapsedMs = 0L
        started = true
        publish(Snapshot(if (certified) "waiting" else "waiting_uncommissioned",
                         fps = this.fps, certified = certified))
    }

    @Synchronized
    fun stop() {
        started = false
        terminalFailure = false
        releaseCodecLocked()
        publish(Snapshot("idle", certified = certified))
    }

    /** Ask a running encoder for an IDR when a new live subscriber attaches. */
    @Synchronized
    fun requestKeyFrame(): Boolean {
        val active = codec ?: return false
        if (Build.VERSION.SDK_INT < 19) return false
        return try {
            active.setParameters(Bundle().apply { putInt("request-sync", 0) })
            Log.i(TAG, "requested sync frame for new fMP4 subscriber")
            true
        } catch (e: Exception) {
            Log.w(TAG, "sync-frame request failed: ${e.javaClass.simpleName}")
            false
        }
    }

    /** Non-blocking live input: a busy codec drops the newest camera frame. */
    @Synchronized
    fun feed(data: ByteArray, w: Int, h: Int, captureMs: Long) {
        if (!started || terminalFailure || w <= 0 || h <= 0) return
        val elapsed = SystemClock.elapsedRealtime()
        if (lastFeedElapsedMs != 0L && elapsed - lastFeedElapsedMs < 1000L / fps) return
        lastFeedElapsedMs = elapsed

        var active = codec
        if (active == null || w != width || h != height) {
            releaseCodecLocked()
            active = createNextCodec(w, h)
            if (active == null) return
            codec = active
            width = w
            height = h
            startOutputDrain(active)
        }

        try {
            val index = active.dequeueInputBuffer(0)
            if (index < 0) return
            val input = bufferAccess?.input(active, index)
            if (input == null) {
                active.queueInputBuffer(index, 0, 0, nextPtsUs(), 0)
                failCurrent(active, "input buffer unavailable")
                return
            }
            input.clear()
            val ptsUs = nextPtsUs()
            val color = currentCandidate?.colorFormat ?: 0
            if (!AvcByteStream.copyNv21(data, w, h, color, input)) {
                active.queueInputBuffer(index, 0, 0, ptsUs, 0)
                failCurrent(active, "unsupported input layout or capacity")
                return
            }
            rememberCaptureTime(ptsUs, captureMs)
            active.queueInputBuffer(index, 0, w * h * 3 / 2, ptsUs, 0)
        } catch (e: Exception) {
            failCurrent(active, "input failed: ${e.javaClass.simpleName}")
        }
    }

    @Synchronized
    private fun createNextCodec(w: Int, h: Int): MediaCodec? {
        val candidates = codecCandidates()
        for (candidate in candidates) {
            if (candidate.id in rejectedCandidates) continue
            var local: MediaCodec? = null
            try {
                val format = MediaFormat.createVideoFormat(AVC_MIME, w, h)
                format.setInteger(MediaFormat.KEY_COLOR_FORMAT, candidate.colorFormat)
                format.setInteger(MediaFormat.KEY_BIT_RATE, bitrateKbps * 1000)
                format.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, GOP_SECONDS)
                if (candidate.profileKeys) {
                    format.setInteger("profile", MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
                    format.setInteger(
                        "level",
                        if (w * h > 640 * 480) MediaCodecInfo.CodecProfileLevel.AVCLevel31
                        else MediaCodecInfo.CodecProfileLevel.AVCLevel3,
                    )
                }
                local = MediaCodec.createByCodecName(candidate.codecName)
                if (Build.VERSION.SDK_INT >= 21) CodecApi21.requestCbr(local, format)
                if (Build.VERSION.SDK_INT >= 26) format.setInteger("latency", 0)
                local.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                local.start()
                val access = CodecBufferAccessFactory.create()
                access.afterStart(local)
                bufferAccess = access
                currentCandidate = candidate
                configData = null
                profileIdc = null
                sawKeyframe = false
                sawSps = false
                sawPps = false
                forwardingStarted = false
                certified = forceCommissioned || commissioningGate.isCommissioned(candidate.id)
                probeStartedMs = SystemClock.elapsedRealtime()
                sessionStartNs = System.nanoTime()
                lastPtsUs = -1L
                queuedTimes.clear()
                publish(Snapshot(
                    if (certified) "probing" else "probing_uncommissioned",
                    candidate.codecName, candidate.colorFormat, w, h, fps, certified,
                ))
                Log.i(TAG, "probing ${candidate.codecName} color=${candidate.colorFormat} " +
                    "${w}x$h @${fps}fps")
                return local
            } catch (e: Exception) {
                rejectedCandidates.add(candidate.id)
                try { local?.stop() } catch (_: Exception) { }
                try { local?.release() } catch (_: Exception) { }
                Log.w(TAG, "reject ${candidate.id}: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
        terminalFailure = true
        publish(Snapshot("degraded", width = w, height = h, fps = fps,
                         certified = certified, error = "no verified Baseline AVC encoder"))
        return null
    }

    @Suppress("DEPRECATION")
    private fun codecCandidates(): List<Candidate> {
        val result = ArrayList<Candidate>()
        val preferredColors = listOf(
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420PackedSemiPlanar,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420PackedPlanar,
        )
        for (i in 0 until MediaCodecList.getCodecCount()) {
            val info = try { MediaCodecList.getCodecInfoAt(i) } catch (_: Exception) { continue }
            if (!info.isEncoder || info.supportedTypes.none {
                    it.equals(AVC_MIME, ignoreCase = true) }) continue
            val lower = info.name.lowercase()
            val software = lower.startsWith("omx.google.") || lower.contains("software") ||
                lower.contains("ffmpeg") || lower.startsWith("c2.android.")
            if (software && !allowSoftware) continue
            val formats = try {
                info.getCapabilitiesForType(AVC_MIME).colorFormats.toSet()
            } catch (_: Exception) { emptySet() }
            for (color in preferredColors) {
                if (color !in formats || color !in AvcByteStream.safeByteColorFormats) continue
                result.add(Candidate(info.name, color, true))
                // Some KitKat codecs reject profile keys but still emit Baseline.  The relaxed
                // attempt is accepted only after its SPS proves profile_idc=66.
                result.add(Candidate(info.name, color, false))
            }
        }
        return result
    }

    private fun startOutputDrain(active: MediaCodec) {
        drainRunning = true
        drainThread = Thread({
            val info = MediaCodec.BufferInfo()
            while (drainRunning && codec === active) {
                var failure: String? = null
                try {
                    val index = active.dequeueOutputBuffer(info, 5_000)
                    when {
                        index >= 0 -> failure = handleOutput(active, index, info)
                        index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                            failure = readCodecConfig(active.outputFormat)
                        index == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED ->
                            bufferAccess?.onOutputBuffersChanged(active)
                    }
                    if (failure == null) failure = maybeCompleteCommissioning()
                    if ((!sawKeyframe || !sawSps || !sawPps) &&
                        SystemClock.elapsedRealtime() - probeStartedMs > PROBE_MS)
                        failure = "no Baseline SPS/PPS/IDR within ${PROBE_MS}ms"
                } catch (e: Exception) {
                    if (drainRunning && codec === active)
                        failure = "output failed: ${e.javaClass.simpleName}"
                }
                if (failure != null) {
                    failCurrent(active, failure)
                    break
                }
            }
        }, "doorbell-h264-output").also {
            it.priority = Thread.MAX_PRIORITY
            it.start()
        }
    }

    /** Returns a validation failure after the output buffer has been released. */
    private fun handleOutput(
        active: MediaCodec,
        index: Int,
        info: MediaCodec.BufferInfo,
    ): String? {
        var failure: String? = null
        try {
            val source = bufferAccess?.output(active, index)
            if (source != null && info.size in 1..AvcByteStream.MAX_ACCESS_UNIT) {
                val copy = source.duplicate()
                if (info.offset < 0 || info.offset + info.size > copy.capacity())
                    return "invalid output buffer bounds"
                copy.position(info.offset)
                copy.limit(info.offset + info.size)
                val raw = ByteArray(info.size)
                copy.get(raw)
                val annexB = AvcByteStream.toAnnexB(raw) ?: return "invalid AVC framing"
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    acceptCodecConfig(annexB)?.let { failure = it }
                } else {
                    observeParameterSets(annexB)
                    val inlineProfile = AvcByteStream.profileIdc(annexB)
                    if (inlineProfile != null) acceptProfile(inlineProfile)?.let { failure = it }
                    val key = info.flags and MediaCodec.BUFFER_FLAG_SYNC_FRAME != 0 ||
                        AvcByteStream.containsNalType(annexB, 5)
                    if (failure == null && key && profileIdc == 66 && sawSps && sawPps) {
                        sawKeyframe = true
                        if (certified) {
                            val config = configData
                            val output = if (AvcByteStream.containsNalType(annexB, 7) &&
                                AvcByteStream.containsNalType(annexB, 8)) annexB
                            else AvcByteStream.prepend(config, annexB)
                            core.onEncodedFrame(
                                output,
                                true,
                                captureTimeFor(info.presentationTimeUs),
                            )
                            forwardingStarted = true
                            publish(Snapshot(
                                "active",
                                currentCandidate?.codecName.orEmpty(),
                                currentCandidate?.colorFormat ?: 0,
                                width, height, fps, certified = true,
                            ))
                        }
                    } else if (failure == null && certified && forwardingStarted) {
                        core.onEncodedFrame(annexB, false, captureTimeFor(info.presentationTimeUs))
                    }
                }
            }
        } finally {
            try { active.releaseOutputBuffer(index, false) } catch (_: Exception) { }
        }
        return failure
    }

    private fun readCodecConfig(format: MediaFormat): String? {
        val units = ArrayList<ByteArray>(2)
        for (key in arrayOf("csd-0", "csd-1")) {
            val buffer = try { format.getByteBuffer(key) } catch (_: Exception) { null } ?: continue
            val copy = buffer.duplicate()
            if (copy.remaining() <= 0 || copy.remaining() > AvcByteStream.MAX_ACCESS_UNIT) continue
            val bytes = ByteArray(copy.remaining())
            copy.get(bytes)
            AvcByteStream.toAnnexB(bytes)?.let(units::add)
        }
        if (units.isNotEmpty()) {
            var combined: ByteArray? = null
            for (unit in units) combined = AvcByteStream.prepend(combined, unit)
            return combined?.let { acceptCodecConfig(it) }
        }
        return null
    }

    private fun acceptCodecConfig(config: ByteArray): String? {
        observeParameterSets(config)
        val idc = AvcByteStream.profileIdc(config)
        if (idc != null) {
            val error = acceptProfile(idc)
            if (error != null) return error
        }
        val previous = configData
        configData = if (previous == null) config else {
            val addsSps = !AvcByteStream.containsNalType(previous, 7) &&
                AvcByteStream.containsNalType(config, 7)
            val addsPps = !AvcByteStream.containsNalType(previous, 8) &&
                AvcByteStream.containsNalType(config, 8)
            if (addsSps || addsPps) AvcByteStream.prepend(previous, config) else previous
        }
        return null
    }

    private fun observeParameterSets(data: ByteArray) {
        if (AvcByteStream.containsNalType(data, 7)) sawSps = true
        if (AvcByteStream.containsNalType(data, 8)) sawPps = true
    }

    private fun maybeCompleteCommissioning(): String? {
        if (certified || !sawSps || !sawPps || !sawKeyframe || profileIdc != 66) return null
        val duration = SystemClock.elapsedRealtime() - probeStartedMs
        if (duration < CodecSelfTestEvidence.MIN_DURATION_MS) return null
        if (duration > CodecSelfTestEvidence.MAX_DURATION_MS)
            return "AVC commissioning exceeded ${CodecSelfTestEvidence.MAX_DURATION_MS}ms"
        val candidate = currentCandidate ?: return "AVC commissioning lost codec identity"
        val evidence = CodecSelfTestEvidence(
            width = width,
            height = height,
            fps = fps,
            bitrateKbps = bitrateKbps,
            profileIdc = profileIdc ?: 0,
            sawSps = sawSps,
            sawPps = sawPps,
            sawIdr = sawKeyframe,
            durationMs = duration,
        )
        if (!commissioningGate.recordMeasured(candidate.id, evidence))
            return "AVC commissioning evidence was not persisted"
        certified = true
        publish(Snapshot(
            "commissioned_waiting_idr",
            candidate.codecName,
            candidate.colorFormat,
            width,
            height,
            fps,
            certified = true,
        ))
        return null
    }

    private fun acceptProfile(idc: Int): String? {
        profileIdc = idc
        return if (idc == 66) null else "encoder ignored Baseline profile (profile_idc=$idc)"
    }

    @Synchronized
    private fun failCurrent(active: MediaCodec, reason: String) {
        if (codec !== active) return
        currentCandidate?.let { rejectedCandidates.add(it.id) }
        Log.w(TAG, "AVC candidate failed: $reason")
        publish(Snapshot("retrying", currentCandidate?.codecName.orEmpty(),
                         currentCandidate?.colorFormat ?: 0, width, height, fps,
                         certified, reason))
        releaseCodecLocked()
    }

    @Synchronized
    private fun rememberCaptureTime(ptsUs: Long, captureMs: Long) {
        queuedTimes.addLast(QueuedTime(ptsUs, captureMs))
        while (queuedTimes.size > MAX_TIME_MAP) queuedTimes.removeFirst()
    }

    @Synchronized
    private fun captureTimeFor(ptsUs: Long): Long {
        while (queuedTimes.size > 1) {
            val second = queuedTimes.elementAt(1)
            if (second.ptsUs > ptsUs) break
            queuedTimes.removeFirst()
        }
        val match = queuedTimes.peekFirst()
        return if (match != null && kotlin.math.abs(match.ptsUs - ptsUs) <= 1_000_000L)
            match.captureMs else System.currentTimeMillis()
    }

    private fun nextPtsUs(): Long {
        val candidate = ((System.nanoTime() - sessionStartNs) / 1_000L).coerceAtLeast(0L)
        lastPtsUs = candidate.coerceAtLeast(lastPtsUs + 1)
        return lastPtsUs
    }

    @Synchronized
    private fun releaseCodecLocked() {
        val active = codec
        codec = null
        drainRunning = false
        try { active?.stop() } catch (_: Exception) { }
        val thread = drainThread
        if (thread != null && thread !== Thread.currentThread()) {
            try { thread.join(250) } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        drainThread = null
        try { active?.release() } catch (_: Exception) { }
        bufferAccess = null
        currentCandidate = null
        configData = null
        profileIdc = null
        sawKeyframe = false
        sawSps = false
        sawPps = false
        forwardingStarted = false
        queuedTimes.clear()
    }

    private fun publish(value: Snapshot) {
        snapshot = value
        listener(value)
    }

    companion object {
        private const val TAG = "doorbell-encoder"
        private const val AVC_MIME = "video/avc"
        private const val GOP_SECONDS = 1
        private const val PROBE_MS = 2_000L
        private const val MAX_TIME_MAP = 90
    }
}
