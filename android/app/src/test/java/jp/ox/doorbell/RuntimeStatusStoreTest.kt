package jp.ox.doorbell

import java.io.File
import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class RuntimeStatusStoreTest {
    @Test
    fun rootHealthFieldsPersistAndNullRemovesStaleMeasurements() {
        val root = Files.createTempDirectory("doorbell-runtime-status-").toFile()
        try {
            val file = File(root, "runtime.json")
            val store = RuntimeStatusStore(file)
            store.updateFields(JSONObject()
                .put("generation", 7L)
                .put("heartbeat_ms", 1_700_000_000_123L)
                .put("last_exit_reason", "unexpected_process_exit")
                .put("helper_mode", "auto"))
            store.updateFields(JSONObject().put("helper_mode", JSONObject.NULL))

            val restored = RuntimeStatusStore(file).snapshot()
            assertEquals(7L, restored.getLong("generation"))
            assertEquals(1_700_000_000_123L, restored.getLong("heartbeat_ms"))
            assertEquals("unexpected_process_exit", restored.getString("last_exit_reason"))
            assertFalse(restored.has("helper_mode"))
        } finally {
            root.deleteRecursively()
        }
    }
}
