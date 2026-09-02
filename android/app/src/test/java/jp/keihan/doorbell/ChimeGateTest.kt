package jp.keihan.doorbell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChimeGateTest {
    @Test
    fun rejectsLegacyMissingExpiredAndDuplicateChimes() {
        val gate = ChimeGate()
        assertFalse(gate.accept(1, "call", 0, 20_000, 10_000))
        assertFalse(gate.accept(2, "", 0, 20_000, 10_000))
        assertFalse(gate.accept(2, "expired", 0, 10_000, 10_000))
        assertTrue(gate.accept(2, "call", 0, 20_000, 10_000))
        assertFalse(gate.accept(2, "call", 0, 20_000, 10_001))
        assertTrue(gate.accept(2, "call", 1, 20_000, 10_001))
        assertTrue(gate.accept(2, "other", 0, 20_000, 10_002))
        assertFalse(gate.accept(2, "call", 0, 20_000, 10_003))
    }
}
