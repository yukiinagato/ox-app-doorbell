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

    /** Core accepts a new password of this length; checked locally for a useful message. */
    const val MIN_LENGTH = 4
    const val MAX_LENGTH = 128

    /**
     * Map core's db_core_admin_password_verify result: positive accepted, 0 wrong, -1 locked out,
     * -2 no cluster password yet, -3 invalid arguments. Null means the export is absent.
     */
    fun stateOf(result: Int?): AdminPasswordState = when {
        result == null -> AdminPasswordState.UNSUPPORTED
        result > 0 -> AdminPasswordState.OK
        result == 0 -> AdminPasswordState.WRONG
        result == -1 -> AdminPasswordState.LOCKED
        result == -2 -> AdminPasswordState.UNSET
        // -3 is a malformed call, which proves nothing about the cluster password.
        else -> AdminPasswordState.UNSUPPORTED
    }

    /**
     * Whether clearing a running SOS alarm has to ask for the password.
     *
     * Core already computes emergency.cancel_requires_pin AND a password actually being set, and
     * publishes the answer as status.emergency.cancel_requires_password. Reading that is the whole
     * rule: an unset password must never stand between a household and a running alarm.
     */
    fun alarmClearNeedsPassword(status: org.json.JSONObject?): Boolean {
        val emergency = status?.optJSONObject("emergency") ?: return false
        if (emergency.has("cancel_requires_password"))
            return emergency.optBoolean("cancel_requires_password", false)
        // Older core: apply the same conjunction locally rather than gating on the flag alone.
        val requiresPin = emergency.optBoolean("cancel_requires_pin", false)
        val passwordSet = emergency.optBoolean("admin_password_set", true)
        return requiresPin && passwordSet
    }

    /** Whether the cluster has a password at all, as core reports it. */
    fun passwordSet(status: org.json.JSONObject?): Boolean =
        status?.optJSONObject("emergency")?.optBoolean("admin_password_set", false) ?: false

    /** Core requires 4..128 characters; rejecting early gives a better message than -1 does. */
    fun newPasswordValid(value: String): Boolean = value.length in MIN_LENGTH..MAX_LENGTH

    /**
     * Whether the legacy per-device digest may be deleted. Core's migration note: the local digest
     * stays authoritative only until core answers authoritatively about the cluster password, so
     * one password change cannot leave a device with a stale second way in. An accepted password
     * and a lockout both prove core owns it; an argument error proves nothing.
     */
    fun retiresLocalDigest(state: AdminPasswordState): Boolean =
        state == AdminPasswordState.OK || state == AdminPasswordState.LOCKED
}
