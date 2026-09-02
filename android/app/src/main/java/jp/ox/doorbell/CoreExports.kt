// Which optional core entry points this build links against (spec §5.5).
//
// The native settings, the administration password, backwards call-log paging and SIP microphone
// muting each have a core export and a documented fallback. The shell resolves the exports once at
// startup and then picks a path per feature, so a core that predates any of them keeps working:
// configuration writes go back to the loopback administration API, call history to the v1 entry
// point without an upper bound, and the microphone to platform muting.
package jp.ox.doorbell

import org.json.JSONObject

internal data class CoreExports(
    val configWrite: Boolean,
    val adminPassword: Boolean,
    val callLogV2: Boolean,
    val micMute: Boolean,
) {
    /** True once core owns every path, which is when the local PIN file may be retired. */
    val complete: Boolean
        get() = configWrite && adminPassword && callLogV2 && micMute

    companion object {
        val NONE = CoreExports(
            configWrite = false, adminPassword = false, callLogV2 = false, micMute = false,
        )

        fun parse(document: JSONObject?): CoreExports {
            if (document == null) return NONE
            return CoreExports(
                configWrite = document.optBoolean("config_write", false),
                adminPassword = document.optBoolean("admin_password", false),
                callLogV2 = document.optBoolean("call_log_v2", false),
                micMute = document.optBoolean("mic_mute", false),
            )
        }
    }
}

/** The outcome of verifying the cluster-wide administrator password. */
internal enum class AdminPasswordState {
    /** Accepted. */
    OK,

    /** Wrong password. */
    WRONG,

    /** Too many attempts; entry is locked out for now. */
    LOCKED,

    /** No cluster password exists yet, so the gate offers to set one. */
    UNSET,

    /** This core cannot answer; the caller falls back to the loopback administration API. */
    UNSUPPORTED,
}

internal object AdminPassword {

    /** Map core's db_core_admin_password_verify result. Null means the export is absent. */
    fun stateOf(result: Int?): AdminPasswordState = when {
        result == null -> AdminPasswordState.UNSUPPORTED
        result > 0 -> AdminPasswordState.OK
        result == 0 -> AdminPasswordState.WRONG
        result == -1 -> AdminPasswordState.LOCKED
        result == -2 -> AdminPasswordState.UNSET
        else -> AdminPasswordState.UNSUPPORTED
    }

    /**
     * Whether clearing a running SOS alarm has to ask for the password.
     *
     * emergency.cancel_requires_pin only applies once a cluster password exists: an alarm must
     * never be impossible to clear because nobody has set one yet (§5.5, "Unset password rule").
     */
    fun alarmClearNeedsPassword(cancelRequiresPin: Boolean, state: AdminPasswordState): Boolean {
        if (!cancelRequiresPin) return false
        return state != AdminPasswordState.UNSET
    }

    /** A new password is refused only for being empty; core owns any stronger rule. */
    fun newPasswordValid(value: String): Boolean = value.isNotEmpty()
}
