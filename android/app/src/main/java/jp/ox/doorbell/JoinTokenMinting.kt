// Minting the Pairing PIN is separate from opening the bulk-add window (spec §5.4).
//
// The PIN card mints or refreshes a code and nothing else; 「まとめて追加」 is the only control that
// opens the pairing-mode window, and it carries its own warning. A core built before
// db_core_mint_join_token_json existed has no PIN-only entry point, so the shell falls back to the
// combined call and closes the window again immediately. The decision is pure and host-tested.
package jp.ox.doorbell

import org.json.JSONObject

internal enum class MintPath {
    /** Core exports the PIN-only entry point; the window is never opened. */
    JOIN_TOKEN,

    /** Older core: mint through the combined call, then close the window again. */
    START_PAIRING_THEN_CLOSE,
}

internal object JoinTokenMinting {

    /**
     * Which path to take for the PIN card. [bulkAddOwnedByUser] is true when the operator has
     * deliberately opened 「まとめて追加」, in which case the fallback must not close the window
     * out from under them.
     */
    fun pathFor(supported: Boolean): MintPath =
        if (supported) MintPath.JOIN_TOKEN else MintPath.START_PAIRING_THEN_CLOSE

    /** True when the fallback path must close the pairing-mode window it just opened. */
    fun closesWindow(path: MintPath, bulkAddOwnedByUser: Boolean): Boolean =
        path == MintPath.START_PAIRING_THEN_CLOSE && !bulkAddOwnedByUser

    /**
     * Mint a PIN for the card. Never opens the bulk-add window on its own: on the fallback path
     * the window is closed again unless the operator already owns it.
     */
    fun mint(core: DoorbellCore, seconds: Int, bulkAddOwnedByUser: Boolean): JSONObject? {
        val path = pathFor(core.mintJoinTokenSupported())
        if (path == MintPath.JOIN_TOKEN) return core.mintJoinToken(seconds)
        val result = core.startPairing(seconds)
        if (closesWindow(path, bulkAddOwnedByUser)) core.setPairingMode(0)
        return result
    }
}
