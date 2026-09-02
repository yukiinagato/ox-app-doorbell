// The SOS slide-to-trigger state machine (spec §0.10, §4.4).
//
// Sliding the thumb past 90 % and releasing starts a cancellable countdown of
// emergency.trigger.countdown_s seconds; only when the countdown reaches zero does the shell call
// db_core_emergency_v2(c, 1). Tapping during the countdown cancels it and nothing is reported.
// A configured countdown of zero fires immediately on release. This type holds no Android
// dependency so every transition is host-tested.
package jp.ox.doorbell

internal enum class SosPhase { IDLE, SLIDING, COUNTDOWN, FIRED }

internal data class SosSnapshot(
    val phase: SosPhase,
    val progress: Float,
    val secondsLeft: Int,
    /** True on the transition that must call core; observed once by the owner. */
    val fireNow: Boolean = false,
)

internal class SosSlideState(countdownSeconds: Int) {

    var countdownSeconds: Int = clampCountdown(countdownSeconds)
        private set

    private var phase = SosPhase.IDLE
    private var progress = 0f
    private var secondsLeft = 0

    fun configure(seconds: Int) {
        countdownSeconds = clampCountdown(seconds)
        if (phase == SosPhase.IDLE) secondsLeft = 0
    }

    fun snapshot(): SosSnapshot = SosSnapshot(phase, progress, secondsLeft)

    val armed: Boolean get() = phase == SosPhase.COUNTDOWN

    /** Finger down or D-pad centre pressed. Does nothing while a countdown is running. */
    fun begin(): SosSnapshot {
        if (phase == SosPhase.COUNTDOWN || phase == SosPhase.FIRED) return snapshot()
        phase = SosPhase.SLIDING
        progress = 0f
        return snapshot()
    }

    /** Track the thumb. [value] is 0..1 along the track. */
    fun drag(value: Float): SosSnapshot {
        if (phase != SosPhase.SLIDING) return snapshot()
        progress = value.coerceIn(0f, 1f)
        return snapshot()
    }

    /**
     * Finger up. Past the threshold this arms the countdown (or fires immediately when the
     * configured countdown is zero); short of it the thumb springs back and nothing happens.
     */
    fun release(): SosSnapshot {
        if (phase != SosPhase.SLIDING) return snapshot()
        if (progress < TRIGGER_THRESHOLD) {
            phase = SosPhase.IDLE
            progress = 0f
            return snapshot()
        }
        progress = 1f
        if (countdownSeconds == 0) {
            phase = SosPhase.FIRED
            secondsLeft = 0
            return SosSnapshot(phase, progress, secondsLeft, fireNow = true)
        }
        phase = SosPhase.COUNTDOWN
        secondsLeft = countdownSeconds
        return snapshot()
    }

    /** One second of the countdown elapsed; fires when it reaches zero. */
    fun tick(): SosSnapshot {
        if (phase != SosPhase.COUNTDOWN) return snapshot()
        secondsLeft -= 1
        if (secondsLeft > 0) return snapshot()
        secondsLeft = 0
        phase = SosPhase.FIRED
        return SosSnapshot(phase, progress, secondsLeft, fireNow = true)
    }

    /** 取り消す during the countdown, or an interrupted slide. Never cancels a fired alarm. */
    fun cancel(): SosSnapshot {
        if (phase == SosPhase.FIRED) return snapshot()
        phase = SosPhase.IDLE
        progress = 0f
        secondsLeft = 0
        return snapshot()
    }

    /** Return to idle after the owner handled the alarm, so the control can be used again. */
    fun reset(): SosSnapshot {
        phase = SosPhase.IDLE
        progress = 0f
        secondsLeft = 0
        return snapshot()
    }

    companion object {
        const val TRIGGER_THRESHOLD = 0.9f
        const val DEFAULT_COUNTDOWN_S = 3
        const val MAX_COUNTDOWN_S = 10

        /** Core's documented default for emergency.button_on_roles: the indoor panel alone. */
        const val DEFAULT_BUTTON_ROLE = "indoor_panel"

        /**
         * Whether this device offers the slide bar at all.
         *
         * emergency.button_on_roles is a cluster setting, and its absence does not mean
         * "everywhere": core documents the default as ["indoor_panel"], so a door station shows
         * no bar unless the cluster names door_station. This shell used to read an absent key --
         * and an empty list -- as "show it", which put an SOS bar on the door station's visitor
         * screen, where any passer-by could raise the household alarm. An empty list is a
         * deliberate "nowhere", and a value that is not a list is treated as unset, which is what
         * every other shell does.
         */
        fun visibleForRole(config: org.json.JSONObject?, role: String): Boolean {
            val roles = config?.optJSONObject("emergency")?.optJSONArray("button_on_roles")
                ?: return role == DEFAULT_BUTTON_ROLE
            for (index in 0 until roles.length())
                if (roles.optString(index) == role) return true
            return false
        }

        fun clampCountdown(seconds: Int): Int = seconds.coerceIn(0, MAX_COUNTDOWN_S)

        /** Read emergency.trigger.countdown_s, defaulting to the documented three seconds. */
        fun countdownFromConfig(config: org.json.JSONObject?): Int {
            val trigger = config?.optJSONObject("emergency")?.optJSONObject("trigger")
                ?: return DEFAULT_COUNTDOWN_S
            if (!trigger.has("countdown_s")) return DEFAULT_COUNTDOWN_S
            return clampCountdown(trigger.optInt("countdown_s", DEFAULT_COUNTDOWN_S))
        }

        /** emergency.trigger.mode; "hold" stays accepted for old configurations but slides. */
        fun slideMode(config: org.json.JSONObject?): Boolean {
            val mode = config?.optJSONObject("emergency")?.optJSONObject("trigger")
                ?.optString("mode").orEmpty()
            return mode.isEmpty() || mode == "slide" || mode == "hold"
        }
    }
}
