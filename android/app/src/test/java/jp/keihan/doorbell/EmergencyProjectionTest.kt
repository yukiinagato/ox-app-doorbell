package jp.keihan.doorbell

import java.io.File
import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EmergencyProjectionTest {
    @Test
    fun channelsAreProjectedWithoutImplicitSystemPresentation() {
        val inApp = EmergencyProjection.fromEvent(JSONObject()
            .put("t", "emergency")
            .put("active", true)
            .put("event_hlc", "10:0:a")
            .put("channels", org.json.JSONArray().put("in_app"))
            .put("ttl_s", 30), 1_000L)!!

        assertTrue(inApp.uses("in_app"))
        assertFalse(inApp.uses("system_notification"))
        assertEquals(31_000L, inApp.presentationUntilWallMs)

        val notification = EmergencyProjection.fromEvent(JSONObject()
            .put("t", "emergency")
            .put("active", true)
            .put("channels", org.json.JSONArray().put("system_notification")), 2_000L)!!
        assertFalse(notification.uses("in_app"))
        assertTrue(notification.uses("system_notification"))
    }

    @Test
    fun explicitEmptyChannelsRemainSilentAndClearRemainsDurable() {
        val active = EmergencyProjection.fromEvent(JSONObject()
            .put("t", "emergency")
            .put("active", true)
            .put("channels", org.json.JSONArray()), 3_000L)!!
        assertTrue(active.channels.isEmpty())
        assertTrue(active.active)

        val missingV2Channels = EmergencyProjection.fromEvent(JSONObject()
            .put("schema_version", 2)
            .put("t", "emergency")
            .put("active", true), 3_500L)!!
        assertTrue(missingV2Channels.channels.isEmpty())
        val legacy = EmergencyProjection.fromEvent(JSONObject()
            .put("schema_version", 1)
            .put("t", "emergency")
            .put("active", true), 3_500L)!!
        assertEquals(setOf("in_app"), legacy.channels)

        val clear = EmergencyProjection.silentState(false, "20:0:a", 4_000L)
        assertFalse(clear.active)
        assertTrue(clear.channels.isEmpty())
    }

    @Test
    fun stateStoreRestoresOnlyKnownPresentationFields() {
        val root = Files.createTempDirectory("doorbell-emergency-").toFile()
        try {
            val file = File(root, "state.json")
            val store = EmergencyStateStore(file)
            assertTrue(store.update(EmergencyPresentation(
                active = true,
                eventHlc = "30:1:a",
                source = "front",
                channels = setOf("in_app"),
                receivedWallMs = 5_000L,
            )))
            val restored = EmergencyStateStore(file).snapshot()!!
            assertTrue(restored.active)
            assertEquals("30:1:a", restored.eventHlc)
            assertEquals(setOf("in_app"), restored.channels)
            assertTrue(store.update(restored.copy(active = false, eventHlc = "31:0:a")))
            val cleared = EmergencyStateStore(file).snapshot()!!
            assertFalse(cleared.active)
            assertEquals("31:0:a", cleared.eventHlc)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun persistenceFailureDoesNotSuppressTheInMemorySafetyState() {
        val store = EmergencyStateStore(File("emergency-state-without-parent"))
        val active = EmergencyPresentation(active = true, eventHlc = "40:0:a")
        assertFalse(store.update(active))
        assertTrue(store.snapshot()?.active == true)
        assertEquals("40:0:a", store.snapshot()?.eventHlc)
    }
}
