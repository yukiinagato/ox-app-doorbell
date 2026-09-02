package jp.ox.doorbell

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Revocation is a factory reset of this device's cluster identity *and* of its setup (spec §5.4),
 * so the shell can only come back through first-run setup.
 */
class BootConfigFactoryResetTest {

    @get:Rule
    val folder = TemporaryFolder()

    private fun write(json: String): File {
        val file = File(folder.newFolder(), "boot.json")
        file.parentFile?.mkdirs()
        file.writeText(json)
        return file
    }

    private val paired = """
        {"name":"moto-door","role":"door_station","door":"d_front","ui_lang":"ja",
         "listen_port":47172,"http_port":47180,"setup_complete":true,
         "psk_ref":"secret:mesh.psk","seed_peers":["10.0.0.5:47172"]}
    """.trimIndent()

    @Test
    fun aFactoryResetClearsThePairingMaterialAndTheLocalIdentity() {
        val file = write(paired)
        val rewritten = BootConfig.factoryReset(file)
        assertNotNull(rewritten)
        val document = JSONObject(rewritten!!)
        assertFalse(document.has("psk_ref"))
        assertFalse(document.has("psk_hex"))
        assertFalse(document.has("seed_peers"))
        assertFalse(document.optBoolean("setup_complete", false))
        assertEquals("", document.optString("door").takeIf { it.startsWith("d_front") } ?: "")
        assertEquals("doorbell-android", document.optString("name"))
        assertTrue(BootConfig.isFactoryReset(rewritten))
        assertFalse(BootConfig.hasSecureMeshReference(rewritten))
    }

    @Test
    fun theResetProfileRequiresFirstRunSetupAgain() {
        val file = write(paired)
        BootConfig.factoryReset(file)
        val reloaded = BootConfig.load(file)
        assertTrue(reloaded.setupRequired)
        // The suggested door is a fresh identifier, never the revoked one.
        assertFalse(reloaded.door == "d_front")
        assertEquals("doorbell-android", reloaded.name)
    }

    @Test
    fun theProvisionedPortsSurviveSoARepairReachesTheSameEndpoints() {
        val file = write(paired)
        val document = JSONObject(BootConfig.factoryReset(file)!!)
        assertEquals(47172, document.optInt("listen_port"))
        assertEquals(47180, document.optInt("http_port"))
        assertEquals(47180, BootConfig.load(file).httpPort)
    }

    @Test
    fun aResetIsWrittenThroughTheBackupGenerationAndIsIdempotent() {
        val file = write(paired)
        BootConfig.factoryReset(file)
        val backup = File(file.parentFile, file.name + ".bak")
        assertTrue(backup.isFile)
        assertTrue(BootConfig.isFactoryReset(backup.readText()))
        // Running it twice must not resurrect anything or fail.
        val second = BootConfig.factoryReset(file)
        assertNotNull(second)
        assertTrue(BootConfig.isFactoryReset(second!!))
    }

    @Test
    fun clearingOnlyThePairingReferenceIsStillDistinctFromAFactoryReset() {
        val file = write(paired)
        val cleared = BootConfig.clearPskReference(file)
        assertNotNull(cleared)
        // The identity survives a plain unpair, so this must not read as a factory reset.
        assertEquals("moto-door", JSONObject(cleared!!).optString("name"))
        assertTrue(JSONObject(cleared).optBoolean("setup_complete"))
        assertFalse(BootConfig.isFactoryReset(cleared))
    }
}
