// Core-authoritative pairing snapshot decoded for the Android shell. The shell renders
// pairing.state and never infers it; every helper here is framework-free so it stays unit tested.
package jp.ox.doorbell

import org.json.JSONObject

internal object PairingModel {

    const val UNPAIRED = "unpaired"
    const val JOINING = "joining"
    const val PERSIST_ERROR = "persist_error"
    const val READY = "ready"
    const val REVOKED = "revoked"

    /** Bulk-add and Pairing-PIN windows both run for ten minutes. */
    const val PAIRING_WINDOW_S = 600

    /**
     * Authoritative state. A snapshot that predates the pairing contract carries no "state", so
     * the legacy booleans provide the same answer instead of a blank screen.
     */
    fun state(pairing: JSONObject?): String {
        if (pairing == null) return UNPAIRED
        val declared = pairing.optString("state")
        if (declared.isNotEmpty()) return declared
        val paired = pairing.optBoolean("paired")
        val persisted = pairing.optBoolean("persistence_ready")
        return when {
            paired && persisted -> READY
            paired -> PERSIST_ERROR
            else -> UNPAIRED
        }
    }

    /** States that replace the main UI with the onboarding screen. */
    fun isOnboarding(state: String): Boolean =
        state == UNPAIRED || state == JOINING || state == PERSIST_ERROR || state == REVOKED

    data class PendingDevice(
        val id: String,
        val addr: String,
        val name: String,
        val role: String,
        val model: String,
        val platform: String,
        val sw: String,
        val ageSeconds: Int,
        val inviteState: String,
        val attempts: Int,
        val lastError: String,
        /** Core saw a second, different identity key for this node id; inviting it is unsafe. */
        val pkConflict: Boolean = false,
    ) {
        /** Human name, then model, then a short identifier — never a blank row. */
        fun displayName(): String {
            if (name.isNotEmpty()) return name
            val short = if (id.length > 6) id.substring(0, 6) else id
            return if (model.isNotEmpty()) "$model ($short)" else short
        }

        /** Secondary line: role, model, and platform, with empty parts dropped. */
        fun detail(): String =
            listOf(role, model, platform, sw).filter { it.isNotEmpty() }.joinToString(" · ")
    }

    fun pending(pairing: JSONObject?): List<PendingDevice> {
        val devices = pairing?.optJSONObject("pending")?.optJSONArray("devices") ?: return emptyList()
        val out = ArrayList<PendingDevice>(devices.length())
        for (i in 0 until devices.length()) {
            val d = devices.optJSONObject(i) ?: continue
            val id = d.optString("id")
            if (id.isEmpty()) continue
            out.add(
                PendingDevice(
                    id = id,
                    addr = d.optString("addr"),
                    name = d.optString("name"),
                    role = d.optString("role"),
                    model = d.optString("model"),
                    platform = d.optString("platform"),
                    sw = d.optString("sw"),
                    ageSeconds = d.optInt("age_s", 0),
                    inviteState = d.optString("invite_state", "none"),
                    attempts = d.optInt("attempts", 0),
                    lastError = d.optString("last_error"),
                    pkConflict = d.optBoolean("pk_conflict", false),
                ),
            )
        }
        return out
    }

    data class Token(
        val active: Boolean,
        val expiresSeconds: Int,
        val attemptsLeft: Int,
        val host: String,
        val pin: String,
    )

    /** The PIN is present only while the token is live, so a reopened card re-renders from it. */
    fun token(pairing: JSONObject?): Token {
        val t = pairing?.optJSONObject("token")
            ?: return Token(false, 0, 0, "", "")
        val active = t.optBoolean("active") && t.optInt("expires_s", 0) > 0
        return Token(
            active = active,
            expiresSeconds = maxOf(0, t.optInt("expires_s", 0)),
            attemptsLeft = maxOf(0, t.optInt("attempts_left", 0)),
            host = t.optString("host"),
            pin = if (active) t.optString("pin") else "",
        )
    }

    data class BulkAdd(val active: Boolean, val leftSeconds: Int, val addedCount: Int)

    fun bulkAdd(pairing: JSONObject?): BulkAdd {
        val p = pairing?.optJSONObject("pending") ?: return BulkAdd(false, 0, 0)
        return BulkAdd(
            active = p.optBoolean("pairing_mode"),
            leftSeconds = maxOf(0, p.optInt("pairing_mode_left_s", 0)),
            addedCount = maxOf(0, p.optInt("auto_added_count", 0)),
        )
    }

    fun memberCount(pairing: JSONObject?): Int =
        maxOf(0, pairing?.optJSONObject("home")?.optInt("member_count", 0) ?: 0)

    fun connectedCount(pairing: JSONObject?): Int =
        maxOf(0, pairing?.optJSONObject("home")?.optInt("connected_count", 0) ?: 0)

    fun isFounder(pairing: JSONObject?): Boolean = pairing?.optBoolean("is_founder") == true

    /** Zero-padded minutes and seconds for pair.code_expires_in / pair.add_all_on. */
    fun minutes(seconds: Int): String = "%d".format(maxOf(0, seconds) / 60)

    fun seconds(seconds: Int): String = "%02d".format(maxOf(0, seconds) % 60)

    /**
     * Human message for a pairing error code. Raw codes never become the primary message; the
     * caller may append pair.err_detail with the code itself.
     */
    fun errorResource(code: String): Int = when (code) {
        "bad_pin" -> R.string.pair_err_bad_pin
        "expired" -> R.string.pair_err_expired
        "no_token" -> R.string.pair_err_no_token
        "host_unpaired" -> R.string.pair_err_host_unpaired
        "connect_failed" -> R.string.pair_err_connect_failed
        "timeout" -> R.string.pair_err_timeout
        "closed" -> R.string.pair_err_closed
        "join_in_progress" -> R.string.pair_err_join_in_progress
        "already_paired" -> R.string.pair_err_already_paired
        "decrypt_failed" -> R.string.pair_err_decrypt_failed
        "bad_payload" -> R.string.pair_err_bad_payload
        "bad_challenge" -> R.string.pair_err_bad_challenge
        "local_persist_failed" -> R.string.pair_err_local_persist_failed
        "persist_failed" -> R.string.pair_err_persist_failed
        "host_zero_psk" -> R.string.pair_err_host_zero_psk
        "no_ack" -> R.string.pair_err_no_ack
        "confirm_code_required" -> R.string.pair_err_confirm_code_required
        "confirm_code_mismatch" -> R.string.pair_err_confirm_code_mismatch
        "pk_conflict" -> R.string.pair_err_pk_conflict
        "protocol_upgrade_required" -> R.string.pair_err_protocol_upgrade_required
        else -> R.string.pair_err_unknown
    }

    /** The i18n key matching [errorResource], used for configuration overrides through Texts. */
    fun errorKey(code: String): String = when (code) {
        "bad_pin", "expired", "no_token", "host_unpaired", "connect_failed", "timeout", "closed",
        "join_in_progress", "already_paired", "decrypt_failed", "bad_payload", "bad_challenge",
        "local_persist_failed", "persist_failed", "host_zero_psk", "no_ack",
        "confirm_code_required", "confirm_code_mismatch", "pk_conflict",
        "protocol_upgrade_required" -> "pair.err.$code"
        else -> "pair.err.unknown"
    }

    // ---------- security v3 (pairing JSON additions) ----------

    /** This device's 8-digit invitation confirm code, shown on its own pairing screen. */
    fun selfConfirmCode(pairing: JSONObject?): String {
        val code = pairing?.optJSONObject("self")?.optString("confirm_code").orEmpty()
        return if (validConfirmCode(code)) code else ""
    }

    /** Exactly eight ASCII digits, as the inviting device must type them. */
    fun validConfirmCode(code: String): Boolean =
        code.length == CONFIRM_CODE_LENGTH && code.all { it in '0'..'9' }

    /** "1234 5678": grouped for reading aloud and copying by eye. */
    fun groupedConfirmCode(code: String): String =
        if (code.length == CONFIRM_CODE_LENGTH) code.substring(0, 4) + " " + code.substring(4)
        else code

    data class Security(
        val legacyPeers: Int,
        val rekeyRequired: Boolean,
        val pskId: String,
        val prevPskId: String,
        val prevPskUntilMs: Long,
        val identityPk: String,
    )

    fun security(pairing: JSONObject?): Security? {
        val s = pairing?.optJSONObject("security") ?: return null
        val legacy = s.opt("legacy_peers")
        return Security(
            legacyPeers = when (legacy) {
                is org.json.JSONArray -> legacy.length()
                is Number -> legacy.toInt()
                else -> 0
            },
            rekeyRequired = s.optBoolean("rekey_required", false),
            pskId = s.optString("psk_id"),
            prevPskId = if (s.isNull("prev_psk_id")) "" else s.optString("prev_psk_id"),
            prevPskUntilMs = s.optLong("prev_psk_until_ms", 0L),
            identityPk = s.optString("identity_pk"),
        )
    }

    /**
     * Why this device must be paired again after the v3 upgrade, or null when it need not.
     * Core reports `upgrade_rejoin_required` as true plus `upgrade_rejoin_reason`, or as an
     * object carrying `reason`; both forms are accepted.
     */
    fun upgradeRejoinReason(pairing: JSONObject?): String? {
        if (pairing == null) return null
        val value = pairing.opt("upgrade_rejoin_required")
        return when (value) {
            is JSONObject -> if (value.optBoolean("required", true))
                value.optString("reason").ifEmpty { "upgrade_rejoin_required" } else null
            true -> pairing.optString("upgrade_rejoin_reason").ifEmpty { "upgrade_rejoin_required" }
            is String -> value.takeIf { it.isNotEmpty() && it != "false" }
            else -> null
        }
    }

    const val CONFIRM_CODE_LENGTH = 8

    /** True when the QR payload is one this cluster can act on. */
    fun isPairQr(text: String): Boolean {
        if (!text.startsWith(QR_PREFIX)) return false
        val body = text.substring(QR_PREFIX.length)
        val first = body.indexOf('|')
        val last = body.lastIndexOf('|')
        return first > 0 && last > first && last < body.length - 1
    }

    const val QR_PREFIX = "doorbell-pair:"
}
