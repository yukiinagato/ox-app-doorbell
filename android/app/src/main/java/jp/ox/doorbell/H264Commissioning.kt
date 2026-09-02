package jp.ox.doorbell

import android.content.Context
import android.os.Build
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject

internal data class CodecSelfTestEvidence(
    val width: Int,
    val height: Int,
    val fps: Int,
    val bitrateKbps: Int,
    val profileIdc: Int,
    val sawSps: Boolean,
    val sawPps: Boolean,
    val sawIdr: Boolean,
    val durationMs: Long,
) {
    fun validApi19Baseline(): Boolean =
        width == 480 && height == 360 && fps == 15 && bitrateKbps == 600 &&
            profileIdc == 66 && sawSps && sawPps && sawIdr &&
            durationMs in MIN_DURATION_MS..MAX_DURATION_MS

    companion object {
        const val MIN_DURATION_MS = 1_500L
        const val MAX_DURATION_MS = 2_000L
    }
}

internal interface EncoderCommissioningGate {
    fun isCommissioned(codecName: String): Boolean
    fun recordMeasured(codecName: String, evidence: CodecSelfTestEvidence): Boolean
}

internal object AlwaysCommissionedEncoder : EncoderCommissioningGate {
    override fun isCommissioned(codecName: String): Boolean = true
    override fun recordMeasured(codecName: String, evidence: CodecSelfTestEvidence): Boolean = true
}

/** Private measurement ledger. No boot/config value can create a commissioned record. */
internal class H264CommissioningStore(
    private val file: File,
    private val artifactBuild: String,
    private val firmwareFingerprint: String,
) : EncoderCommissioningGate {
    private var records = load()

    @Synchronized
    override fun isCommissioned(codecName: String): Boolean = records.any {
        it.artifactBuild == artifactBuild && it.firmwareFingerprint == firmwareFingerprint &&
            it.codecName == codecName && it.evidence.validApi19Baseline()
    }

    @Synchronized
    fun hasCurrentMeasurement(): Boolean = records.any {
        it.artifactBuild == artifactBuild && it.firmwareFingerprint == firmwareFingerprint &&
            it.evidence.validApi19Baseline()
    }

    @Synchronized
    fun currentCodecIdentities(): Set<String> = records.filter {
        it.artifactBuild == artifactBuild && it.firmwareFingerprint == firmwareFingerprint &&
            it.evidence.validApi19Baseline()
    }.mapTo(LinkedHashSet()) { it.codecName }

    @Synchronized
    override fun recordMeasured(codecName: String, evidence: CodecSelfTestEvidence): Boolean {
        if (codecName.isBlank() || codecName.length > 256 || artifactBuild.isBlank() ||
            firmwareFingerprint.isBlank() || !evidence.validApi19Baseline()) return false
        val previous = ArrayList(records)
        records.removeAll {
            it.artifactBuild == artifactBuild && it.firmwareFingerprint == firmwareFingerprint &&
                it.codecName == codecName
        }
        val record = Record(
            artifactBuild,
            firmwareFingerprint,
            codecName,
            System.currentTimeMillis(),
            evidence,
        )
        records.add(record)
        while (records.size > MAX_RECORDS) records.removeAt(0)
        if (persist()) return true
        records = previous
        return false
    }

    private fun persist(): Boolean {
        val parent = file.parentFile ?: return false
        if (!parent.exists() && !parent.mkdirs()) return false
        val root = JSONObject().put("schema_version", 1).put("records", JSONArray())
        val array = root.getJSONArray("records")
        for (record in records) array.put(record.toJson())
        val tmp = File(parent, file.name + ".tmp")
        return try {
            FileOutputStream(tmp).use { out ->
                out.write(root.toString().toByteArray(Charsets.UTF_8))
                out.flush()
                out.fd.sync()
            }
            if (!tmp.renameTo(file)) throw java.io.IOException("rename failed")
            true
        } catch (_: Exception) {
            tmp.delete()
            false
        }
    }

    private fun load(): MutableList<Record> {
        if (!file.isFile || file.length() !in 1..MAX_BYTES) return ArrayList()
        return try {
            val root = JSONObject(file.readText(Charsets.UTF_8))
            if (root.optInt("schema_version") != 1) return ArrayList()
            val result = ArrayList<Record>()
            val array = root.optJSONArray("records") ?: return result
            for (index in 0 until array.length()) {
                Record.fromJson(array.optJSONObject(index))?.takeIf {
                    it.evidence.validApi19Baseline()
                }?.let(result::add)
            }
            result
        } catch (_: Exception) {
            ArrayList()
        }
    }

    private data class Record(
        val artifactBuild: String,
        val firmwareFingerprint: String,
        val codecName: String,
        val measuredAtMs: Long,
        val evidence: CodecSelfTestEvidence,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("artifact_build", artifactBuild)
            .put("firmware_fingerprint", firmwareFingerprint)
            .put("codec", codecName)
            .put("measured_at_ms", measuredAtMs)
            .put("evidence_source", EVIDENCE_SOURCE)
            .put("width", evidence.width)
            .put("height", evidence.height)
            .put("fps", evidence.fps)
            .put("bitrate_kbps", evidence.bitrateKbps)
            .put("profile_idc", evidence.profileIdc)
            .put("sps", evidence.sawSps)
            .put("pps", evidence.sawPps)
            .put("idr", evidence.sawIdr)
            .put("duration_ms", evidence.durationMs)

        companion object {
            fun fromJson(value: JSONObject?): Record? {
                if (value == null || value.optString("evidence_source") != EVIDENCE_SOURCE)
                    return null
                val build = value.optString("artifact_build")
                val fingerprint = value.optString("firmware_fingerprint")
                val codec = value.optString("codec")
                if (build.isBlank() || fingerprint.isBlank() || codec.isBlank()) return null
                return Record(
                    build,
                    fingerprint,
                    codec,
                    value.optLong("measured_at_ms", 0L),
                    CodecSelfTestEvidence(
                        value.optInt("width"),
                        value.optInt("height"),
                        value.optInt("fps"),
                        value.optInt("bitrate_kbps"),
                        value.optInt("profile_idc"),
                        value.optBoolean("sps"),
                        value.optBoolean("pps"),
                        value.optBoolean("idr"),
                        value.optLong("duration_ms"),
                    ),
                )
            }
        }
    }

    companion object {
        private const val EVIDENCE_SOURCE = "media_codec_output_v1"
        private const val MAX_RECORDS = 32
        private const val MAX_BYTES = 128 * 1024L

        fun artifactBuild(context: Context, coreVersion: String): String {
            @Suppress("DEPRECATION")
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            return "${info.versionName.orEmpty()}:${info.versionCode}:$coreVersion:" +
                "${BuildConfig.DOORBELL_SOURCE_ID}:${installedApkSha256(context)}"
        }

        private fun installedApkSha256(context: Context): String = try {
            val digest = MessageDigest.getInstance("SHA-256")
            File(context.applicationInfo.sourceDir).inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val size = input.read(buffer)
                    if (size < 0) break
                    digest.update(buffer, 0, size)
                }
            }
            digest.digest().joinToString("") { "%02x".format(it) }
        } catch (_: Exception) {
            "apk-unavailable"
        }

        fun forDevice(context: Context, coreVersion: String): H264CommissioningStore =
            H264CommissioningStore(
                File(context.filesDir, "h264-commissioning-v1.json"),
                artifactBuild(context, coreVersion),
                Build.FINGERPRINT,
            )
    }
}

internal data class AvcOperatingPoint(
    val width: Int,
    val height: Int,
    val fps: Int,
    val bitrateKbps: Int,
)

internal object AndroidCodecPolicy {
    val api19 = AvcOperatingPoint(480, 360, 15, 600)

    fun operatingPoint(
        sdk: Int,
        configuredResolution: Pair<Int, Int>?,
        configuredFps: Int?,
        configuredBitrateKbps: Int?,
    ): AvcOperatingPoint {
        if (sdk <= 19) return api19
        val resolution = configuredResolution ?: (640 to 360)
        return AvcOperatingPoint(
            resolution.first.coerceIn(160, 1_920),
            resolution.second.coerceIn(120, 1_080),
            (configuredFps ?: 30).coerceIn(5, 30),
            (configuredBitrateKbps ?: 700).coerceIn(128, 4_000),
        )
    }
}
