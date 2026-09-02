// Backoff for the door-audio monitor leg.
//
// From device testing (2026-09-03): while two indoor panels were paired to an iPad 1 acting as a
// door station, the iPad logged "[sip-uas] dialog ended mode=monitor RTP tx=0 rx=0" about 1.5
// times a second for 39 seconds. A panel kept opening monitor dialogs against a door with no
// audio, each ending immediately, with no backoff. That storm saturated the iPad and took its
// HTTP down with it.
//
// A monitor leg is a convenience, never something worth retrying hard. So: a dialog that carried
// no media is treated as a failure and the next attempt waits twice as long, capped; a door that
// reports no audio is never retried at all; and nothing is retried while the operator has the
// monitor toggle off.
package jp.ox.doorbell

internal enum class MonitorStop {
    /** Retrying is allowed, subject to the current delay. */
    NONE,

    /** The operator turned the monitor off. Resuming is their decision. */
    TOGGLE_OFF,

    /** The door has no audio to listen to. Nothing will change that during this visit. */
    NO_AUDIO,
}

internal class MonitorBackoff(
    private val baseMs: Long = BASE_MS,
    private val capMs: Long = CAP_MS,
) {

    private var failures = 0
    private var stop = MonitorStop.NONE

    /** Wall-clock time the next attempt becomes allowed; zero means "now". */
    private var readyAtMs = 0L

    val stopReason: MonitorStop get() = stop

    val failureCount: Int get() = failures

    /** The wait after the failures seen so far: 1 s, 2, 4, 8, 16, then capped. */
    fun currentDelayMs(): Long {
        if (failures <= 0) return 0L
        var delay = baseMs
        repeat(failures - 1) {
            if (delay >= capMs) return capMs
            delay *= 2
        }
        return delay.coerceAtMost(capMs)
    }

    /** Whether a monitor leg may be opened at [nowMs]. */
    fun mayStart(nowMs: Long): Boolean =
        stop == MonitorStop.NONE && nowMs >= readyAtMs

    /** How long to wait before the next attempt, or -1 when there will not be one. */
    fun retryDelayMs(nowMs: Long): Long {
        if (stop != MonitorStop.NONE) return -1L
        return (readyAtMs - nowMs).coerceAtLeast(0L)
    }

    /**
     * A monitor dialog ended having carried no media in either direction -- the door answered and
     * hung up with nothing on the wire. Returns the wait before the next attempt.
     */
    fun onDeadDialog(nowMs: Long): Long {
        failures += 1
        val delay = currentDelayMs()
        readyAtMs = nowMs + delay
        return delay
    }

    /** The door refused the dialog. Same treatment: something is wrong, so stop hammering it. */
    fun onRefused(nowMs: Long): Long = onDeadDialog(nowMs)

    /** Media actually flowed, so whatever was wrong is over. */
    fun onMediaFlowed() {
        failures = 0
        readyAtMs = 0L
    }

    /** The door has no audio capability: never retry. */
    fun onNoAudioCapability() {
        stop = MonitorStop.NO_AUDIO
    }

    /** The operator turned the monitor off. */
    fun onToggledOff() {
        if (stop == MonitorStop.NO_AUDIO) return
        stop = MonitorStop.TOGGLE_OFF
    }

    /**
     * The operator turned it back on. The accumulated delay is deliberately kept: a door that was
     * failing a moment ago is still probably failing, and a toggle is not evidence otherwise.
     */
    fun onToggledOn() {
        if (stop == MonitorStop.TOGGLE_OFF) stop = MonitorStop.NONE
    }

    companion object {
        const val BASE_MS = 1_000L
        const val CAP_MS = 30_000L

        /**
         * Whether a finished dialog carried media. Counters are cumulative, so this is only asked
         * about the leg that just ended.
         */
        fun carriedMedia(rtpTx: Long, rtpRx: Long): Boolean = rtpTx > 0L || rtpRx > 0L
    }
}
