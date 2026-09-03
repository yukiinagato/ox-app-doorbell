// The doorbell:// pairing link.
//
//   doorbell://pair?host=<ip:port>&pin=<6 digits>&exp=<unix seconds>&cluster=<url-encoded name>
//
// One link carries everything a new device needs, so a QR can be scanned by any camera app and the
// device opens straight into a pre-filled join with a single confirm button.
//
// Core is adding db_core_parse_pair_uri_json; this is the same parse, kept here because the shell
// needs it before core ships it, because the decision table has to be host-tested on both tiers,
// and because a malformed link must fail the same way whichever side parsed it. When core exports
// its parser the shell prefers it and this stays as the fallback.
package jp.ox.doorbell

import org.json.JSONObject

internal data class PairInvite(
    val host: String,
    val pin: String,
    /** Unix seconds; zero when the link carries no expiry. */
    val expiresAtS: Long,
    val cluster: String,
) {
    fun expiredAt(nowMs: Long): Boolean =
        expiresAtS > 0L && nowMs / 1000L >= expiresAtS

    fun secondsLeft(nowMs: Long): Long =
        if (expiresAtS <= 0L) Long.MAX_VALUE else expiresAtS - nowMs / 1000L
}

/** Why a link cannot be used. The keys match the catalogue entries the screen renders. */
internal enum class PairUriError { NOT_A_PAIR_LINK, BAD_HOST, BAD_PIN, EXPIRED }

internal sealed class PairUriResult {
    data class Ok(val invite: PairInvite) : PairUriResult()
    data class Invalid(val error: PairUriError) : PairUriResult()
}

internal object PairUri {

    const val SCHEME = "doorbell"
    const val HOST = "pair"
    private val PIN_PATTERN = Regex("^[0-9]{6}$")

    /** Build the link a PIN card's QR encodes. */
    fun build(host: String, pin: String, expiresAtS: Long, cluster: String): String {
        val builder = StringBuilder("$SCHEME://$HOST?host=").append(encode(host))
        builder.append("&pin=").append(encode(pin))
        if (expiresAtS > 0L) builder.append("&exp=").append(expiresAtS)
        if (cluster.isNotEmpty()) builder.append("&cluster=").append(encode(cluster))
        return builder.toString()
    }

    /** True for anything that claims to be a pairing link, so the caller can route it here. */
    fun looksLikePairLink(value: String): Boolean =
        value.trim().startsWith("$SCHEME://", ignoreCase = true)

    /**
     * Parse and validate. [nowMs] decides expiry, which is checked here so a stale QR left on a
     * screen cannot silently start a join that will be refused.
     */
    fun parse(value: String?, nowMs: Long): PairUriResult {
        val text = value?.trim().orEmpty()
        if (!looksLikePairLink(text)) return PairUriResult.Invalid(PairUriError.NOT_A_PAIR_LINK)
        val afterScheme = text.substring(SCHEME.length + 3)
        val host = afterScheme.substringBefore('?').trim('/')
        if (!host.equals(HOST, ignoreCase = true))
            return PairUriResult.Invalid(PairUriError.NOT_A_PAIR_LINK)
        val query = afterScheme.substringAfter('?', "")
        if (query.isEmpty()) return PairUriResult.Invalid(PairUriError.NOT_A_PAIR_LINK)
        val fields = HashMap<String, String>(4)
        for (pair in query.split('&')) {
            if (pair.isEmpty()) continue
            val key = pair.substringBefore('=')
            if (key.isEmpty() || fields.containsKey(key)) continue
            fields[key] = decode(pair.substringAfter('=', ""))
        }
        val seed = fields["host"].orEmpty()
        if (!validHost(seed)) return PairUriResult.Invalid(PairUriError.BAD_HOST)
        val pin = fields["pin"].orEmpty()
        if (!PIN_PATTERN.matches(pin)) return PairUriResult.Invalid(PairUriError.BAD_PIN)
        val invite = PairInvite(
            host = seed,
            pin = pin,
            expiresAtS = fields["exp"]?.toLongOrNull()?.takeIf { it > 0L } ?: 0L,
            cluster = fields["cluster"].orEmpty(),
        )
        if (invite.expiredAt(nowMs)) return PairUriResult.Invalid(PairUriError.EXPIRED)
        return PairUriResult.Ok(invite)
    }

    /** Adopt core's parser result when it has one; the shapes are deliberately identical. */
    fun fromCore(document: JSONObject?, nowMs: Long): PairUriResult? {
        if (document == null) return null
        if (!document.optBoolean("ok", false)) {
            return when (document.optString("err")) {
                "expired" -> PairUriResult.Invalid(PairUriError.EXPIRED)
                "bad_pin" -> PairUriResult.Invalid(PairUriError.BAD_PIN)
                "bad_host" -> PairUriResult.Invalid(PairUriError.BAD_HOST)
                "" -> null
                else -> PairUriResult.Invalid(PairUriError.NOT_A_PAIR_LINK)
            }
        }
        val invite = PairInvite(
            host = document.optString("host"),
            pin = document.optString("pin"),
            expiresAtS = document.optLong("exp", 0L),
            cluster = document.optString("cluster"),
        )
        if (!validHost(invite.host) || !PIN_PATTERN.matches(invite.pin)) return null
        if (invite.expiredAt(nowMs)) return PairUriResult.Invalid(PairUriError.EXPIRED)
        return PairUriResult.Ok(invite)
    }

    /**
     * The QR payload for the PIN card: core's doorbell:// link when it publishes one, otherwise
     * the existing pair_qr content so an older core keeps working.
     *
     * db_core_pairing_json carries the link on its *token* object, and only while a PIN is
     * active; db_core_mint_join_token_json and db_core_start_pairing_json carry it at the top
     * level of their own result. Both shapes are accepted so either document can be handed here.
     * Reading only the top level -- which is what this did -- meant the pairing screen never
     * showed core's link at all and always fell back to the legacy payload.
     */
    fun qrPayload(pairing: JSONObject?): String {
        if (pairing == null) return ""
        val token = uriOf(pairing.optJSONObject("token"))
        if (token.isNotEmpty()) return token
        val own = uriOf(pairing)
        if (own.isNotEmpty()) return own
        return pairing.optString("pair_qr").orEmpty()
    }

    /** A "uri" field that is really there: org.json renders an absent or null value as text. */
    private fun uriOf(document: JSONObject?): String {
        if (document == null || document.isNull("uri")) return ""
        val uri = document.optString("uri").orEmpty()
        return if (uri == "null") "" else uri
    }

    /** host:port, with a non-empty host and a port in range when one is given. */
    internal fun validHost(value: String): Boolean {
        if (value.isEmpty() || value.length > 255) return false
        if (value.any { it.isWhitespace() }) return false
        val separator = value.lastIndexOf(':')
        if (separator < 0) return true
        val host = value.substring(0, separator)
        val port = value.substring(separator + 1).toIntOrNull() ?: return false
        return host.isNotEmpty() && port in 1..65535
    }

    private fun encode(value: String): String = try {
        java.net.URLEncoder.encode(value, "UTF-8")
    } catch (_: Exception) {
        value
    }

    private fun decode(value: String): String = try {
        java.net.URLDecoder.decode(value, "UTF-8")
    } catch (_: Exception) {
        value
    }
}

/** What the pairing screen should do with a link that arrived from a scan or a deep link. */
internal enum class PairLinkAction {
    /** Pre-fill and wait for the single confirm button. */
    CONFIRM,

    /** Already in a cluster: ask before leaving it, because joining is a full reset. */
    CONFIRM_LEAVE_CURRENT,

    /** Show the inline error and do nothing else. */
    REJECT,
}

internal object PairLinkPolicy {

    fun actionFor(result: PairUriResult, alreadyPaired: Boolean): PairLinkAction = when {
        result is PairUriResult.Invalid -> PairLinkAction.REJECT
        alreadyPaired -> PairLinkAction.CONFIRM_LEAVE_CURRENT
        else -> PairLinkAction.CONFIRM
    }

    /** The catalogue key for an inline error message. */
    fun messageKey(error: PairUriError): String = when (error) {
        PairUriError.EXPIRED -> "pair.err.expired"
        PairUriError.BAD_PIN -> "pair.err.bad_pin"
        PairUriError.BAD_HOST -> "pair.err.connect_failed"
        PairUriError.NOT_A_PAIR_LINK -> "pair.err.bad_qr"
    }
}
