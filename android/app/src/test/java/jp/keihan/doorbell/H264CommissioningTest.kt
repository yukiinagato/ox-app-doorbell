package jp.keihan.doorbell

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class H264CommissioningTest {
    private val evidence = CodecSelfTestEvidence(
        width = 480,
        height = 360,
        fps = 15,
        bitrateKbps = 600,
        profileIdc = 66,
        sawSps = true,
        sawPps = true,
        sawIdr = true,
        durationMs = 1_750L,
    )

    @Test
    fun artifactSourceIdentityIsAFullSha256() {
        assertTrue(BuildConfig.DOORBELL_SOURCE_ID.matches(Regex("^[0-9a-f]{64}$")))
    }

    @Test
    fun api19OperatingPointIgnoresUnsafeConfiguration() {
        val value = AndroidCodecPolicy.operatingPoint(
            19,
            1_920 to 1_080,
            30,
            4_000,
        )
        assertEquals(AvcOperatingPoint(480, 360, 15, 600), value)
    }

    @Test
    fun measurementIsBoundToExactArtifactFingerprintAndCodec() {
        val root = Files.createTempDirectory("doorbell-avc-").toFile()
        try {
            val file = File(root, "commissioning.json")
            val measured = H264CommissioningStore(file, "app:1:core-a", "exact/fw:1")
            assertFalse(measured.isCommissioned("OMX.vendor.avc.encoder"))
            assertTrue(measured.recordMeasured("OMX.vendor.avc.encoder", evidence))
            assertTrue(measured.isCommissioned("OMX.vendor.avc.encoder"))
            assertFalse(measured.isCommissioned("OMX.other.avc.encoder"))

            assertFalse(H264CommissioningStore(
                file,
                "app:2:core-a",
                "exact/fw:1",
            ).isCommissioned("OMX.vendor.avc.encoder"))
            assertFalse(H264CommissioningStore(
                file,
                "app:1:core-a",
                "exact/fw:2",
            ).isCommissioned("OMX.vendor.avc.encoder"))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun incompleteOrOutOfWindowEvidenceCannotCommission() {
        val root = Files.createTempDirectory("doorbell-avc-invalid-").toFile()
        try {
            val store = H264CommissioningStore(File(root, "commissioning.json"), "build", "fw")
            assertFalse(store.recordMeasured("codec", evidence.copy(sawPps = false)))
            assertFalse(store.recordMeasured("codec", evidence.copy(durationMs = 1_499L)))
            assertFalse(store.recordMeasured("codec", evidence.copy(durationMs = 2_001L)))
            assertFalse(store.hasCurrentMeasurement())
        } finally {
            root.deleteRecursively()
        }
    }

}
