package jp.keihan.doorbell

import android.content.Context
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.security.MessageDigest
import org.json.JSONObject

/** Source-controlled hardware gate; runtime configuration cannot add qualified SKUs. */
internal class Api19ReleaseQualification private constructor(
    private val entries: List<Entry>,
) {
    internal data class Entry(
        val sku: String,
        val firmwareFingerprint: String,
        val codecIdentity: String,
        val evidenceReport: String,
        val evidenceReportSha256: String,
    )

    fun matches(
        sku: String,
        firmwareFingerprint: String,
        commissionedCodecs: Set<String>,
    ): Boolean =
        entries.any {
            it.sku == sku && it.firmwareFingerprint == firmwareFingerprint &&
                it.codecIdentity in commissionedCodecs
        }

    fun matchesCurrentDevice(commissionedCodecs: Set<String>): Boolean =
        matches(currentSku(), Build.FINGERPRINT, commissionedCodecs)

    companion object {
        private const val ASSET = "api19-h264-qualified.json"
        private val sha256 = Regex("^[0-9a-f]{64}$")

        fun load(context: Context): Api19ReleaseQualification = try {
            val bytes = context.assets.open(ASSET).use { input ->
                readLimited(input)
            }
            parse(JSONObject(String(bytes, Charsets.UTF_8))) { path ->
                context.assets.open(path).use { input -> readLimited(input) }
            }
        } catch (_: Exception) {
            Api19ReleaseQualification(emptyList())
        }

        internal fun parse(
            root: JSONObject,
            evidenceLoader: (String) -> ByteArray? = { null },
        ): Api19ReleaseQualification {
            if (!exactKeys(root, setOf("schema_version", "entries")) ||
                strictInt(root, "schema_version") != 1)
                return Api19ReleaseQualification(emptyList())
            val result = ArrayList<Entry>()
            val array = root.optJSONArray("entries") ?: return Api19ReleaseQualification(result)
            for (index in 0 until array.length()) {
                val value = array.optJSONObject(index) ?: continue
                if (!exactKeys(value, setOf(
                        "sku", "firmware_fingerprint", "codec_identity", "evidence_report",
                        "evidence_report_sha256",
                    ))) continue
                val sku = strictString(value, "sku", 256) ?: continue
                val fingerprint = strictString(value, "firmware_fingerprint", 512) ?: continue
                val codec = strictString(value, "codec_identity", 256) ?: continue
                val reportPath = strictString(value, "evidence_report", 160) ?: continue
                val reportHash = strictString(value, "evidence_report_sha256", 64) ?: continue
                if (!evidencePath.matches(reportPath) || !sha256.matches(reportHash)) continue
                val reportBytes = try {
                    evidenceLoader(reportPath)
                } catch (_: Exception) {
                    null
                } ?: continue
                if (reportBytes.isEmpty() || reportBytes.size > MAX_BYTES ||
                    digest(reportBytes) != reportHash) continue
                val report = try {
                    JSONObject(String(reportBytes, Charsets.UTF_8))
                } catch (_: Exception) {
                    continue
                }
                if (!validEvidenceReport(report, sku, fingerprint, codec)) continue
                result.add(Entry(sku, fingerprint, codec, reportPath, reportHash))
            }
            return Api19ReleaseQualification(result)
        }

        private fun validEvidenceReport(
            report: JSONObject,
            sku: String,
            fingerprint: String,
            codec: String,
        ): Boolean {
            if (!exactKeys(report, setOf(
                    "schema_version", "sku", "firmware_fingerprint", "codec_identity", "tests",
                )) || strictInt(report, "schema_version") != 1 ||
                strictString(report, "sku", 256) != sku ||
                strictString(report, "firmware_fingerprint", 512) != fingerprint ||
                strictString(report, "codec_identity", 256) != codec) return false
            val tests = report.optJSONObject("tests") ?: return false
            if (!exactKeys(tests, setOf(
                    "camera1", "h264_encode", "h264_decode", "sip", "soak",
                ))) return false
            return validCamera1(tests.optJSONObject("camera1")) &&
                validEncode(tests.optJSONObject("h264_encode"), codec) &&
                validDecode(tests.optJSONObject("h264_decode")) &&
                validSip(tests.optJSONObject("sip")) &&
                validSoak(tests.optJSONObject("soak"))
        }

        private fun validCamera1(value: JSONObject?): Boolean = value != null &&
            exactKeys(value, setOf(
                "passed", "api", "width", "height", "fps", "captured_frames",
            )) &&
            strictTrue(value, "passed") && strictString(value, "api", 32) == "Camera1" &&
            strictInt(value, "width") == 480 && strictInt(value, "height") == 360 &&
            strictInt(value, "fps") == 15 &&
            (strictLong(value, "captured_frames") ?: 0L) > 0L

        private fun validEncode(value: JSONObject?, codec: String): Boolean = value != null &&
            exactKeys(value, setOf(
                "passed", "codec_identity", "width", "height", "fps", "bitrate_kbps",
                "profile_idc", "gop_ms", "sps", "pps", "idr", "b_frames",
            )) && strictTrue(value, "passed") &&
            strictString(value, "codec_identity", 256) == codec &&
            strictInt(value, "width") == 480 && strictInt(value, "height") == 360 &&
            strictInt(value, "fps") == 15 && strictInt(value, "bitrate_kbps") == 600 &&
            strictInt(value, "profile_idc") == 66 && strictInt(value, "gop_ms") == 1_000 &&
            strictTrue(value, "sps") &&
            strictTrue(value, "pps") && strictTrue(value, "idr") &&
            value.opt("b_frames") == false

        private fun validDecode(value: JSONObject?): Boolean = value != null &&
            exactKeys(value, setOf(
                "passed", "codec_identity", "bounded_fmp4", "first_frame", "idr_resync",
            )) && strictTrue(value, "passed") &&
            strictString(value, "codec_identity", 256) != null &&
            strictTrue(value, "bounded_fmp4") && strictTrue(value, "first_frame") &&
            strictTrue(value, "idr_resync")

        private fun validSip(value: JSONObject?): Boolean = value != null &&
            exactKeys(value, setOf("passed", "backend", "uac", "uas", "rtp")) &&
            strictTrue(value, "passed") && strictString(value, "backend", 32) == "pjsip" &&
            strictTrue(value, "uac") && strictTrue(value, "uas") && strictTrue(value, "rtp")

        private fun validSoak(value: JSONObject?): Boolean = value != null &&
            exactKeys(value, setOf(
                "passed", "duration_ms", "simultaneous", "camera1", "h264_encode",
                "h264_decode", "sip",
            )) && strictTrue(value, "passed") &&
            (strictLong(value, "duration_ms") ?: 0L) >= EIGHT_HOURS_MS &&
            strictTrue(value, "simultaneous") &&
            strictTrue(value, "camera1") && strictTrue(value, "h264_encode") &&
            strictTrue(value, "h264_decode") && strictTrue(value, "sip")

        private fun exactKeys(value: JSONObject, expected: Set<String>): Boolean {
            val actual = LinkedHashSet<String>()
            val keys = value.keys()
            while (keys.hasNext()) actual.add(keys.next())
            return actual == expected
        }

        private fun strictTrue(value: JSONObject, key: String): Boolean = value.opt(key) == true

        private fun strictString(value: JSONObject, key: String, maximum: Int): String? =
            (value.opt(key) as? String)?.takeIf { it.isNotBlank() && it.length <= maximum }

        private fun strictInt(value: JSONObject, key: String): Int? {
            val number = strictLong(value, key) ?: return null
            return number.takeIf { it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong() }?.toInt()
        }

        private fun strictLong(value: JSONObject, key: String): Long? {
            val number = value.opt(key) as? Number ?: return null
            val double = number.toDouble()
            if (!double.isFinite() || double < Long.MIN_VALUE.toDouble() ||
                double > Long.MAX_VALUE.toDouble() || double % 1.0 != 0.0) return null
            return number.toLong()
        }

        private fun digest(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }

        internal fun sku(
            manufacturer: String,
            model: String,
            device: String,
            product: String,
            board: String,
        ): String = listOf(manufacturer, model, device, product, board)
            .joinToString("|") { it.trim().ifEmpty { "unknown" } }

        internal fun currentSku(): String = sku(
            Build.MANUFACTURER,
            Build.MODEL,
            Build.DEVICE,
            Build.PRODUCT,
            Build.BOARD,
        )

        private fun readLimited(input: InputStream): ByteArray {
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(4 * 1024)
            var total = 0
            while (true) {
                val size = input.read(buffer)
                if (size < 0) break
                total += size
                if (total > MAX_BYTES)
                    throw java.io.IOException("qualification file too large")
                output.write(buffer, 0, size)
            }
            return output.toByteArray()
        }

        private const val MAX_BYTES = 64 * 1024
        private const val EIGHT_HOURS_MS = 8L * 60L * 60L * 1_000L
        private val evidencePath =
            Regex("^api19-qualification/[A-Za-z0-9][A-Za-z0-9._-]{0,127}\\.json$")
    }
}
