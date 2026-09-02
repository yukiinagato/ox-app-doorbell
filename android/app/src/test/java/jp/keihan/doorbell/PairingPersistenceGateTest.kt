package jp.keihan.doorbell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingPersistenceGateTest {
    @Test
    fun successRequiresTheCanonicalReferenceAndAtomicBootCommit() {
        val gate = PairingPersistenceGate()
        gate.initialize(false)

        assertFalse(gate.recordPaired("", true))
        assertFalse(gate.recordPaired("secret:other", true))
        assertFalse(gate.recordPaired(PairingPersistenceGate.MESH_PSK_REFERENCE, false))
        assertTrue(gate.recordPaired(PairingPersistenceGate.MESH_PSK_REFERENCE, true))
        assertTrue(gate.canMarkReady(true, true, true))
    }

    @Test
    fun pollingStaysBlockedAfterBootPersistenceFailure() {
        val gate = PairingPersistenceGate()
        gate.initialize(true)

        gate.recordPaired(PairingPersistenceGate.MESH_PSK_REFERENCE, false)

        assertFalse(gate.canMarkReady(true, true, true))
    }

    @Test
    fun corePersistenceErrorRevokesAPreviouslyReadyShell() {
        val gate = PairingPersistenceGate()
        gate.initialize(true)
        gate.recordFailure()

        assertFalse(gate.canMarkReady(true, true, true))
    }
}
