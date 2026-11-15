package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsRefreshTest {

    @Test
    fun burstOfRequestsRunsOneLoadAndOneFollowUp() {
        val gate = ReloadGate()
        assertTrue(gate.request())
        assertFalse(gate.request())
        assertFalse(gate.request())
        assertTrue(gate.complete())
        assertFalse(gate.complete())
        assertTrue(gate.request())
    }

    @Test
    fun ownWritesSuppressEventRefreshUntilTheyFinish() {
        val writes = PendingWrites()
        assertTrue(writes.idle)
        writes.begin()
        writes.begin()
        assertFalse(writes.idle)
        writes.end()
        assertFalse(writes.idle)
        writes.end()
        writes.end()
        assertTrue(writes.idle)
    }

    @Test
    fun unchangedSnapshotDoesNotRebuildThePage() {
        val gate = RenderGate()
        val first = SettingsFingerprint.of(JSONObject("{\"a\":1}"), null, null)
        assertTrue(gate.needed(first))
        gate.rendered(first)
        assertFalse(gate.needed(SettingsFingerprint.of(JSONObject("{\"a\":1}"), null, null)))
        assertTrue(gate.needed(SettingsFingerprint.of(JSONObject("{\"a\":2}"), null, null)))
    }

    @Test
    fun secretNamesAreCollectedFromNestedReferences() {
        val config = JSONObject(
            "{\"mqtt\":{\"pass_ref\":\"secret:mqtt\"},\"x\":[{\"r\":\"secret:sip.n1\"},\"plain\"]}",
        )
        assertEquals(setOf("mqtt", "sip.n1"), SettingsFingerprint.secretNames(config))
    }
}
