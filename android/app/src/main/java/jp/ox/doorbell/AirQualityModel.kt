// The home-screen PM2.5 reading: db_core_air_quality_json parsed into what the indicator draws.
package jp.ox.doorbell

import org.json.JSONObject

internal enum class AirState { HIDDEN, UNCONFIGURED, WAITING, STALE, OK }

/** Core's level names, with the US EPA AQI category colour used for the level dot. */
internal enum class AirLevel(val wire: String, val dotRgb: Int) {
    GOOD("good", 0x00C853),
    MODERATE("moderate", 0xFFD600),
    SENSITIVE("sensitive", 0xFF7E00),
    UNHEALTHY("unhealthy", 0xE53935),
    VERY_UNHEALTHY("very_unhealthy", 0x8F3F97),
    HAZARDOUS("hazardous", 0x7E0023);

    companion object {
        fun parse(value: String): AirLevel? = values().firstOrNull { it.wire == value }
    }
}

internal data class AirQualityReading(
    val state: AirState,
    val pm25: Int = -1,
    val level: AirLevel? = null,
    val ageSeconds: Long = -1L,
) {
    val visible: Boolean get() = state != AirState.HIDDEN

    /** A value is drawn for ok and, dimmed, for stale; everything else is a placeholder. */
    val hasValue: Boolean get() = (state == AirState.OK || state == AirState.STALE) && pm25 >= 0

    val dimmed: Boolean get() = state == AirState.STALE

    /** The dot carries the level only while the reading is current. */
    val dotRgb: Int? get() = if (state == AirState.OK && hasValue) level?.dotRgb else null

    companion object {
        val HIDDEN = AirQualityReading(AirState.HIDDEN)
    }
}

internal object AirQualityModel {

    fun parse(document: JSONObject?): AirQualityReading {
        if (document == null || !document.optBoolean("show", false)) return AirQualityReading.HIDDEN
        val state = when (document.optString("state")) {
            "unconfigured" -> AirState.UNCONFIGURED
            "waiting" -> AirState.WAITING
            "stale" -> AirState.STALE
            "ok" -> AirState.OK
            else -> return AirQualityReading.HIDDEN
        }
        val pm25 = if (document.has("pm25")) document.optInt("pm25", -1) else -1
        if ((state == AirState.OK || state == AirState.STALE) && pm25 < 0)
            return AirQualityReading(AirState.WAITING)
        return AirQualityReading(
            state = state,
            pm25 = pm25,
            level = AirLevel.parse(document.optString("level")),
            ageSeconds = document.optLong("age_s", -1L),
        )
    }

    /** Configured air_sensors as (id, name) for the per-device picker, ordered by name. */
    fun sensorOptions(config: JSONObject?): List<Pair<String, String>> {
        val sensors = config?.optJSONObject("air_sensors") ?: return emptyList()
        val out = ArrayList<Pair<String, String>>()
        val keys = sensors.keys()
        while (keys.hasNext()) {
            val id = keys.next()
            val def = sensors.optJSONObject(id) ?: continue
            out.add(id to def.optString("name").ifEmpty { id })
        }
        return out.sortedWith(compareBy({ it.second.lowercase() }, { it.first }))
    }

    /** The generated string key for a level, or for the placeholder that replaces it. */
    fun statusKey(reading: AirQualityReading): String? = when (reading.state) {
        AirState.HIDDEN -> null
        AirState.UNCONFIGURED -> "air.unconfigured"
        AirState.WAITING -> "air.waiting"
        AirState.STALE -> "air.stale"
        AirState.OK -> reading.level?.let { "air.level_${it.wire}" }
    }

    /**
     * The one-line label: the name, the value and unit when there is one, then the status.
     * [status] is the localized text for [statusKey], or null when there is none to show.
     */
    fun line(reading: AirQualityReading, label: String, unit: String, status: String?): String {
        val parts = StringBuilder(label)
        if (reading.hasValue) parts.append("  ").append(reading.pm25).append(' ').append(unit)
        if (!status.isNullOrEmpty()) parts.append(" · ").append(status)
        return parts.toString()
    }
}
