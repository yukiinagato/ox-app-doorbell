package jp.keihan.doorbell

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BootConfigPairingTest {
    @Test
    fun firstRunRequiresSetupAndSuppliesUsableRandomDoorSuggestion() {
        withTemporaryDirectory { directory ->
            val config = BootConfig.load(File(directory, "boot.json"))
            assertTrue(config.setupRequired)
            assertTrue(BootConfig.validDoor(config.suggestedDoor))
            assertTrue(config.suggestedDoor.startsWith("door-"))
        }
    }

    @Test
    fun validIndoorSetupDoesNotRequireDoorAndInvalidDoorStationDoes() {
        withTemporaryDirectory { directory ->
            val file = File(directory, "boot.json")
            assertNotNull(BootConfig.persistSetup(file, "hall", "indoor_panel", ""))
            val indoor = BootConfig.load(file)
            assertFalse(indoor.setupRequired)
            assertEquals("indoor_panel", indoor.role)

            file.writeText("""{"name":"front","role":"door_station","door":"","setup_complete":true}""")
            assertTrue(BootConfig.load(file).setupRequired)
            assertNull(BootConfig.persistSetup(file, "front", "door_station", "invalid space"))
        }
    }

    @Test
    fun legacyProfileWithoutExplicitConfirmationRequiresSetupOnce() {
        withTemporaryDirectory { directory ->
            val file = File(directory, "boot.json")
            file.writeText("""{"name":"hall","role":"indoor_panel","door":""}""")

            assertTrue(BootConfig.load(file).setupRequired)
            assertNotNull(BootConfig.persistSetup(file, "hall", "indoor_panel", ""))
            assertFalse(BootConfig.load(file).setupRequired)
        }
    }

    @Test
    fun persistsOnlyTheSecretReferenceAndMergedSeedsInBothGenerations() {
        withTemporaryDirectory { directory ->
            val file = File(directory, "boot.json")
            file.writeText(
                """{"name":"test","psk_hex":"${"ab".repeat(32)}","seed_peers":["old:47172"]}""",
                Charsets.UTF_8,
            )

            val persisted = BootConfig.persistPskReference(
                file,
                listOf("new:47172", "old:47172", ""),
            )

            assertNotNull(persisted)
            for (generation in listOf(file, File(directory, "boot.json.bak"))) {
                val json = JSONObject(generation.readText(Charsets.UTF_8))
                assertEquals(
                    PairingPersistenceGate.MESH_PSK_REFERENCE,
                    json.getString("psk_ref"),
                )
                assertFalse(json.has("psk_hex"))
                val seeds = json.getJSONArray("seed_peers")
                assertEquals(2, seeds.length())
                assertEquals("old:47172", seeds.getString(0))
                assertEquals("new:47172", seeds.getString(1))
            }
            assertFalse(File(directory, "boot.json.tmp").exists())
            assertFalse(File(directory, "boot.json.bak.tmp").exists())
        }
    }

    @Test
    fun reportsFailureWithoutReplacingThePrimaryGeneration() {
        withTemporaryDirectory { directory ->
            val file = File(directory, "boot.json")
            val original = """{"name":"test","seed_peers":["old:47172"]}"""
            file.writeText(original, Charsets.UTF_8)
            assertTrue(File(directory, "boot.json.tmp").mkdir())

            val persisted = BootConfig.persistPskReference(file, listOf("new:47172"))

            assertNull(persisted)
            assertEquals(original, file.readText(Charsets.UTF_8))
        }
    }

    @Test
    fun leavingTheClusterRemovesEverySecretReferenceFromBothGenerations() {
        withTemporaryDirectory { directory ->
            val file = File(directory, "boot.json")
            file.writeText(
                """{"name":"test","psk_ref":"secret:mesh.psk","seed_peers":["old:47172"]}""",
                Charsets.UTF_8,
            )

            val cleared = BootConfig.clearPskReference(file)

            assertNotNull(cleared)
            for (generation in listOf(file, File(directory, "boot.json.bak"))) {
                val json = JSONObject(generation.readText(Charsets.UTF_8))
                assertFalse(json.has("psk_ref"))
                assertFalse(json.has("psk_hex"))
                assertFalse(json.has("seed_peers"))
                assertEquals("test", json.getString("name"))
            }
            assertFalse(BootConfig.hasSecureMeshReference(BootConfig.load(file).rawJson))
        }
    }

    @Test
    fun leavingTheClusterIsANoOpWhenNoSecretWasStored() {
        withTemporaryDirectory { directory ->
            val file = File(directory, "boot.json")
            file.writeText("""{"name":"test"}""", Charsets.UTF_8)

            assertNull(BootConfig.clearPskReference(file))
        }
    }

    private fun withTemporaryDirectory(block: (File) -> Unit) {
        val marker = File.createTempFile("doorbell-pairing-", ".tmp")
        assertTrue(marker.delete())
        assertTrue(marker.mkdir())
        try {
            block(marker)
        } finally {
            marker.deleteRecursively()
        }
    }
}
