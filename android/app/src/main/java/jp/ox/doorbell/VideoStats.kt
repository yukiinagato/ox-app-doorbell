// Live-view counters behind the incoming screen's debug line (spec §5.2):
// `codec/strategy · latency ms · jitter ms · fps · dropped`.
//
// The line is diagnostic, so the numbers are measured rather than estimated: latency is the age of
// the newest displayed frame, jitter is the mean absolute deviation of the inter-frame intervals,
// and fps counts the frames actually put on screen in the sampling window. Pure and host-tested.
package jp.ox.doorbell

internal data class VideoStats(
    val codec: String,
    val latencyMs: Int,
    val jitterMs: Int,
    val fps: Int,
    val dropped: Int,
) {
    val hasFrames: Boolean get() = fps > 0 || latencyMs > 0
}

internal class VideoStatsCounter {

    private val intervals = ArrayDeque<Long>()
    private var lastFrameMs = 0L
    private var dropped = 0
    private var codec = ""

    fun setCodec(value: String) {
        codec = value
    }

    fun onDropped(count: Int = 1) {
        dropped += count.coerceAtLeast(0)
    }

    fun reset() {
        intervals.clear()
        lastFrameMs = 0L
        dropped = 0
    }

    /** Record one frame reaching the screen at [nowMs]. */
    fun onFrame(nowMs: Long) {
        if (lastFrameMs > 0L) {
            val interval = nowMs - lastFrameMs
            if (interval in 1..MAX_INTERVAL_MS) {
                intervals.addLast(interval)
                while (intervals.size > WINDOW) intervals.removeFirst()
            }
        }
        lastFrameMs = nowMs
    }

    fun snapshot(nowMs: Long): VideoStats = VideoStats(
        codec = codec,
        latencyMs = if (lastFrameMs <= 0L) 0 else (nowMs - lastFrameMs).coerceIn(0, 99_999).toInt(),
        jitterMs = jitter(),
        fps = fps(),
        dropped = dropped,
    )

    /**
     * Frames per second derived from the mean interval over the sampling window, so the number is
     * available as soon as a couple of frames have arrived rather than only on a window boundary.
     */
    internal fun fps(): Int {
        if (intervals.isEmpty()) return 0
        val mean = intervals.sum().toDouble() / intervals.size
        if (mean <= 0.0) return 0
        return Math.round(1000.0 / mean).toInt()
    }

    /** Mean absolute deviation of the inter-frame intervals, in whole milliseconds. */
    internal fun jitter(): Int {
        if (intervals.size < 2) return 0
        val mean = intervals.sum().toDouble() / intervals.size
        val deviation = intervals.sumOf { Math.abs(it - mean) } / intervals.size
        return deviation.toInt()
    }

    private companion object {
        const val WINDOW = 30
        const val MAX_INTERVAL_MS = 5_000L
    }
}
