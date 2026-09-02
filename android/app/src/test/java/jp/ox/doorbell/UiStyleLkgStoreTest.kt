package jp.ox.doorbell

import java.io.File
import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UiStyleLkgStoreTest {
    @Test
    fun validatedStylePersistsAndCorruptPrimaryFallsBackToBackup() {
        val root = Files.createTempDirectory("doorbell-ui-lkg-").toFile()
        try {
            val file = File(root, "styles.json")
            val first = JSONObject()
                .put("foreground", "#F2F5F8")
                .put("background", "#243040")
            val second = JSONObject()
                .put("foreground", "#FFFFFF")
                .put("background", "#B00020")
            val store = UiStyleLkgStore(file)
            assertTrue(store.save("node-a", "sos.trigger", first))
            assertTrue(store.save("node-a", "sos.trigger", second))
            assertEquals("#FFFFFF", UiStyleLkgStore(file)
                .get("node-a", "sos.trigger")?.optString("foreground"))

            file.writeText("corrupt", Charsets.UTF_8)
            val recovered = UiStyleLkgStore(file).get("node-a", "sos.trigger")
            assertNotNull(recovered)
            assertEquals("#F2F5F8", recovered?.optString("foreground"))
        } finally {
            root.deleteRecursively()
        }
    }
}
