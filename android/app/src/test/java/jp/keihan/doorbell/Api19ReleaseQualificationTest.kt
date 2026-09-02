package jp.keihan.doorbell

import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class Api19ReleaseQualificationTest {
    private val sku = Api19ReleaseQualification.sku(
        "vendor", "kitkat-panel", "panel", "panel_product", "board_a",
    )
    private val fingerprint = "vendor/product/device:4.4.2/exact"
    private val codec = "OMX.vendor.avc:21:true"
    private val reportPath = "api19-qualification/kitkat-panel.json"

    @Test
    fun qualificationRequiresExactFingerprintCodecAndEvidenceReport() {
        val bytes = validEvidence().toString().toByteArray(Charsets.UTF_8)
        val gate = gate(bytes)

        assertTrue(gate.matches(
            sku,
            fingerprint,
            setOf(codec),
        ))
        assertFalse(gate.matches(
            sku,
            "$fingerprint/other",
            setOf(codec),
        ))
        assertFalse(gate.matches(
            sku,
            fingerprint,
            setOf("OMX.vendor.avc:19:true"),
        ))
        assertFalse(gate.matches(
            Api19ReleaseQualification.sku(
                "vendor", "kitkat-panel-b", "panel", "panel_product", "board_a",
            ),
            fingerprint,
            setOf(codec),
        ))
    }

    @Test
    fun hashMismatchMissingArtifactAndArbitraryHashCannotQualify() {
        val bytes = validEvidence().toString().toByteArray(Charsets.UTF_8)
        val entry = entry(sha256(bytes))
        val root = JSONObject()
            .put("schema_version", 1)
            .put("entries", JSONArray().put(entry))
        assertFalse(Api19ReleaseQualification.parse(root)
            .matches(sku, fingerprint, setOf(codec)))
        assertFalse(Api19ReleaseQualification.parse(root) { "tampered".toByteArray() }
            .matches(sku, fingerprint, setOf(codec)))

        entry.put("evidence_report_sha256", "a".repeat(64))
        assertFalse(Api19ReleaseQualification.parse(root) { bytes }
            .matches(sku, fingerprint, setOf(codec)))
    }

    @Test
    fun reportMustBindExactIdentityAndEveryHardwareGate() {
        val wrongIdentity = validEvidence().put("firmware_fingerprint", "$fingerprint/other")
            .toString().toByteArray(Charsets.UTF_8)
        assertFalse(gate(wrongIdentity).matches(sku, fingerprint, setOf(codec)))
        val wrongCodec = validEvidence().put("codec_identity", "$codec/other")
            .toString().toByteArray(Charsets.UTF_8)
        assertFalse(gate(wrongCodec).matches(sku, fingerprint, setOf(codec)))

        val shortSoak = validEvidence()
        shortSoak.getJSONObject("tests").getJSONObject("soak")
            .put("duration_ms", 28_799_999L)
        val shortBytes = shortSoak.toString().toByteArray(Charsets.UTF_8)
        assertFalse(gate(shortBytes).matches(sku, fingerprint, setOf(codec)))

        val sequentialSoak = validEvidence()
        sequentialSoak.getJSONObject("tests").getJSONObject("soak")
            .put("simultaneous", false)
        val sequentialBytes = sequentialSoak.toString().toByteArray(Charsets.UTF_8)
        assertFalse(gate(sequentialBytes).matches(sku, fingerprint, setOf(codec)))

        for (test in listOf("camera1", "h264_encode", "h264_decode", "sip")) {
            val failed = validEvidence()
            failed.getJSONObject("tests").getJSONObject(test).put("passed", false)
            val failedBytes = failed.toString().toByteArray(Charsets.UTF_8)
            assertFalse("$test must remain a release gate",
                gate(failedBytes).matches(sku, fingerprint, setOf(codec)))
        }
    }

    private fun gate(bytes: ByteArray): Api19ReleaseQualification {
        val root = JSONObject()
            .put("schema_version", 1)
            .put("entries", JSONArray().put(entry(sha256(bytes))))
        return Api19ReleaseQualification.parse(root) { path ->
            if (path == reportPath) bytes else null
        }
    }

    private fun entry(hash: String): JSONObject = JSONObject()
        .put("sku", sku)
        .put("firmware_fingerprint", fingerprint)
        .put("codec_identity", codec)
        .put("evidence_report", reportPath)
        .put("evidence_report_sha256", hash)

    private fun validEvidence(): JSONObject = JSONObject()
        .put("schema_version", 1)
        .put("sku", sku)
        .put("firmware_fingerprint", fingerprint)
        .put("codec_identity", codec)
        .put("tests", JSONObject()
            .put("camera1", JSONObject()
                .put("passed", true)
                .put("api", "Camera1")
                .put("width", 480)
                .put("height", 360)
                .put("fps", 15)
                .put("captured_frames", 100))
            .put("h264_encode", JSONObject()
                .put("passed", true)
                .put("codec_identity", codec)
                .put("width", 480)
                .put("height", 360)
                .put("fps", 15)
                .put("bitrate_kbps", 600)
                .put("profile_idc", 66)
                .put("gop_ms", 1_000)
                .put("sps", true)
                .put("pps", true)
                .put("idr", true)
                .put("b_frames", false))
            .put("h264_decode", JSONObject()
                .put("passed", true)
                .put("codec_identity", "OMX.vendor.avc.decoder")
                .put("bounded_fmp4", true)
                .put("first_frame", true)
                .put("idr_resync", true))
            .put("sip", JSONObject()
                .put("passed", true)
                .put("backend", "pjsip")
                .put("uac", true)
                .put("uas", true)
                .put("rtp", true))
            .put("soak", JSONObject()
                .put("passed", true)
                .put("duration_ms", 28_800_000L)
                .put("simultaneous", true)
                .put("camera1", true)
                .put("h264_encode", true)
                .put("h264_decode", true)
                .put("sip", true)))

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
}
