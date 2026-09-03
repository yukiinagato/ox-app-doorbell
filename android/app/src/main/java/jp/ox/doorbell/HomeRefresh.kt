// How often the home screen may rebuild itself from core state.
//
// Core emits peers_changed on every fresh peer heartbeat, which on a settled cluster is several
// events a second and on a large one many more. Rebuilding the home screen once per event costs a
// full set of core reads each time, and the reads that marshal into core's run loop hold the loop
// away from its own mesh timers. The shell therefore refreshes on a timer: the first event runs
// immediately, and everything that arrives inside the window is folded into one later refresh.
package jp.ox.doorbell

internal object HomeRefreshPolicy {

    /** No more than one home-screen refresh per second, however many events arrive. */
    const val MIN_INTERVAL_MS = 1_000L

    /**
     * How long to wait before the refresh requested at [nowMs] may run, given that the previous
     * one ran at [lastRunMs]. Zero means run now.
     *
     * [lastRunMs] and [nowMs] are monotonic milliseconds. A zero [lastRunMs] means nothing has run
     * yet, and a reading that appears to go backwards is treated as due rather than as a wait of
     * unknown length, so a clock anomaly cannot strand the screen on stale counters.
     */
    fun delayMs(lastRunMs: Long, nowMs: Long, minIntervalMs: Long = MIN_INTERVAL_MS): Long {
        if (lastRunMs <= 0L) return 0L
        val since = nowMs - lastRunMs
        if (since < 0L || since >= minIntervalMs) return 0L
        return minIntervalMs - since
    }
}
