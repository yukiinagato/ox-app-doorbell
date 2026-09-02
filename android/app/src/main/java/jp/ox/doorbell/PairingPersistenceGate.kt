package jp.ox.doorbell

/** Fail-closed shell acknowledgement layered on top of Core's secure-store status. */
internal class PairingPersistenceGate {
    @Volatile
    private var bootPersistenceSucceeded = false

    fun initialize(hasSecureBootReference: Boolean) {
        bootPersistenceSucceeded = hasSecureBootReference
    }

    fun recordPaired(secretRef: String, bootCommitted: Boolean): Boolean {
        val accepted = secretRef == MESH_PSK_REFERENCE && bootCommitted
        bootPersistenceSucceeded = accepted
        return accepted
    }

    fun recordFailure() {
        bootPersistenceSucceeded = false
    }

    fun canMarkReady(
        corePaired: Boolean,
        corePersistenceReady: Boolean,
        bootHasSecureReference: Boolean,
    ): Boolean = corePaired && corePersistenceReady && bootHasSecureReference &&
        bootPersistenceSucceeded

    companion object {
        const val MESH_PSK_REFERENCE = "secret:mesh.psk"
    }
}
