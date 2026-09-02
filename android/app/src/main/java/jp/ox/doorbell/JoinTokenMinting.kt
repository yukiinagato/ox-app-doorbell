// Minting the Pairing PIN is separate from opening the bulk-add window (spec §5.4).
//
// The founder's PIN card and the Add-device panel mint or refresh a code and nothing else;
// 「まとめて追加」 is the only control that opens the pairing-mode window, because while that window
// is open core automatically invites every device it discovers. Showing a PIN must never do that.
//
// db_core_mint_join_token_json is compiled into the same shared object as the shell, so there is
// no path here that opens the window as a fallback: a failure is reported to the operator instead.
package jp.ox.doorbell

import org.json.JSONObject

internal object JoinTokenMinting {

    /** Core clamps the requested PIN lifetime to this range; zero keeps core's own default. */
    const val MIN_SECONDS = 30
    const val MAX_SECONDS = 600

    /** True when a request would be accepted as-is rather than clamped by core. */
    fun withinCoreRange(seconds: Int): Boolean =
        seconds == 0 || seconds in MIN_SECONDS..MAX_SECONDS

    /**
     * Mint a PIN for the card. Never opens the bulk-add window, whatever the outcome; a null or
     * unsuccessful result is surfaced by the caller as an error on the card.
     */
    fun mint(core: DoorbellCore, seconds: Int): JSONObject? = core.mintJoinToken(seconds)

    /** Whether a mint result is a success core actually minted a PIN for. */
    fun succeeded(result: JSONObject?): Boolean =
        result != null && result.optBoolean("ok", false) &&
            result.optString("pin").isNotEmpty()

    /** The documented error key, or an empty string when the result was a success. */
    fun errorOf(result: JSONObject?): String =
        if (succeeded(result)) "" else result?.optString("err").orEmpty()
}
