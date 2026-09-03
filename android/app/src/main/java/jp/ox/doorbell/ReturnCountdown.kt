// The indoor incoming page returns to the home page on its own (batch 3).
//
// The title carries a "(60)" suffix ticking down from status.call.return_s. Rules from device
// testing:
//   - a visitor cancelling the call does NOT close the page; the live view stays up until the
//     countdown ends or the resident leaves, so they can still see who was there;
//   - tapping the number cancels the countdown, and the page then stays until the resident leaves;
//   - answering pauses it and hides the suffix; ending the call restarts it from the full value.
// Pure, so every transition is host-tested.
package jp.ox.doorbell

import org.json.JSONObject

internal enum class ReturnPhase {
    /** Ticking down; the suffix is visible. */
    RUNNING,

    /** A call is in progress; no suffix and no ticking. */
    PAUSED,

    /** The resident tapped the number; no suffix, and the page stays put. */
    CANCELLED,

    /** Reached zero; the caller returns to the home page. */
    ELAPSED,
}

internal data class ReturnSnapshot(
    val phase: ReturnPhase,
    val secondsLeft: Int,
) {
    /** The title suffix, or an empty string when nothing should be appended. */
    val suffix: String get() =
        if (phase == ReturnPhase.RUNNING) "($secondsLeft)" else ""

    val shouldReturnHome: Boolean get() = phase == ReturnPhase.ELAPSED

    /** Whether a one-second tick should still be scheduled. */
    val ticking: Boolean get() = phase == ReturnPhase.RUNNING
}

internal class ReturnCountdown(totalSeconds: Int = DEFAULT_SECONDS) {

    var totalSeconds: Int = clamp(totalSeconds)
        private set

    private var phase = ReturnPhase.RUNNING
    private var secondsLeft = this.totalSeconds

    fun snapshot(): ReturnSnapshot = ReturnSnapshot(phase, secondsLeft)

    /** Apply a configured length. Only a countdown that has not started yet adopts it. */
    fun configure(seconds: Int) {
        totalSeconds = clamp(seconds)
        if (phase == ReturnPhase.RUNNING && secondsLeft > totalSeconds) secondsLeft = totalSeconds
    }

    fun tick(): ReturnSnapshot {
        if (phase != ReturnPhase.RUNNING) return snapshot()
        secondsLeft -= 1
        if (secondsLeft <= 0) {
            secondsLeft = 0
            phase = ReturnPhase.ELAPSED
        }
        return snapshot()
    }

    /**
     * The call was answered. The resident is talking, so nothing should pull the page away and no
     * number should be counting at them.
     */
    fun pauseForCall(): ReturnSnapshot {
        if (phase == ReturnPhase.CANCELLED || phase == ReturnPhase.ELAPSED) return snapshot()
        phase = ReturnPhase.PAUSED
        return snapshot()
    }

    /** The call ended. The countdown starts again from the full value, never from the remainder. */
    fun resumeAfterCall(): ReturnSnapshot {
        if (phase != ReturnPhase.PAUSED) return snapshot()
        phase = ReturnPhase.RUNNING
        secondsLeft = totalSeconds
        return snapshot()
    }

    /** The resident tapped the number: stop counting and keep the page up. */
    fun cancelByUser(): ReturnSnapshot {
        if (phase == ReturnPhase.ELAPSED) return snapshot()
        phase = ReturnPhase.CANCELLED
        return snapshot()
    }

    /**
     * The visitor cancelled the call. Deliberately not a state change: the page stays, showing the
     * live view, and the countdown that was already running is what eventually closes it.
     */
    fun onVisitorCancelled(): ReturnSnapshot = snapshot()

    companion object {
        const val DEFAULT_SECONDS = 60
        const val MAX_SECONDS = 3600

        private fun clamp(seconds: Int): Int =
            if (seconds <= 0) DEFAULT_SECONDS else seconds.coerceAtMost(MAX_SECONDS)

        /**
         * status.call.return_s when core publishes it, else call.indoor.return_s from
         * configuration, else the documented sixty seconds.
         */
        fun secondsFrom(status: JSONObject?, config: JSONObject?): Int {
            val published = status?.optJSONObject("call")?.optInt("return_s", 0) ?: 0
            if (published > 0) return clamp(published)
            val configured = config?.optJSONObject("call")?.optJSONObject("indoor")
                ?.optInt("return_s", 0) ?: 0
            if (configured > 0) return clamp(configured)
            return DEFAULT_SECONDS
        }
    }
}
