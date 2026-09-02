// Every clock the shell renders comes from core's cluster time (spec §1.2, §5.1).
//
// db_core_local_time_json applies the cluster time zone and core's own NTP correction, so it is
// the source for the dashboard clock, the door-station clock, and every history timestamp. It
// takes the core run loop, so a screen reads it once per tick and formats the rest of its rows
// from the returned wall_ms and offset_min rather than calling back per row.
package jp.ox.doorbell

import java.util.Locale
import org.json.JSONObject

internal data class ClusterTime(
    val wallMs: Long,
    val offsetMin: Int,
    val hour: Int,
    val minute: Int,
    val second: Int,
    val date: String,
    val weekdayNum: Int,
    val zone: String,
    /** False when the configured zone was unknown and tz_offset_min was used instead. */
    val known: Boolean,
) {
    fun clockText(): String =
        String.format(Locale.US, "%02d:%02d:%02d", hour, minute, second)

    fun minuteOfDay(): Int = hour * 60 + minute
}

internal class ClusterClock(private val core: DoorbellCore) {

    @Volatile
    private var offsetMin: Int = 0

    @Volatile
    private var offsetKnown = false

    /** Read the current cluster time, falling back to the device clock on an older core. */
    fun now(): ClusterTime {
        val document = try { core.localTime(0L) } catch (_: Exception) { null }
        if (document == null) return fallback(System.currentTimeMillis())
        offsetMin = document.optInt("offset_min", offsetMin)
        offsetKnown = true
        val wallMs = document.optLong("wall_ms", System.currentTimeMillis())
        return ClusterTime(
            wallMs = wallMs,
            offsetMin = offsetMin,
            hour = document.optInt("hh", 0),
            minute = document.optInt("mm", 0),
            second = document.optInt("ss", 0),
            date = document.optString("date"),
            weekdayNum = document.optInt("weekday_num", 0),
            zone = document.optString("tz"),
            known = document.optBoolean("known", true),
        )
    }

    /** Format a recorded timestamp in the cluster zone without another run-loop round trip. */
    fun format(wallMs: Long): ClusterTime = shift(wallMs, offsetMin)

    /** yyyy-mm-dd for a recorded timestamp, used to group the history by day. */
    fun dayKey(wallMs: Long): String = format(wallMs).date

    private fun fallback(wallMs: Long): ClusterTime {
        val offset = java.util.TimeZone.getDefault().getOffset(wallMs) / 60000
        offsetMin = offset
        return shift(wallMs, offset).copy(known = false)
    }

    private fun shift(wallMs: Long, offset: Int): ClusterTime {
        val local = wallMs + offset * 60_000L
        // Math.floorDiv and Math.floorMod are API 24; this shell still supports API 19.
        val days = CivilDate.floorDiv(local, 86_400_000L)
        val inDay = local - days * 86_400_000L
        val second = (inDay / 1000L).toInt()
        val civil = CivilDate.fromDays(days)
        return ClusterTime(
            wallMs = wallMs,
            offsetMin = offset,
            hour = second / 3600,
            minute = second % 3600 / 60,
            second = second % 60,
            date = String.format(Locale.US, "%04d-%02d-%02d", civil[0], civil[1], civil[2]),
            // 1970-01-01 was a Thursday; weekday_num follows core's Sunday-zero convention.
            weekdayNum = CivilDate.weekday(days),
            zone = "",
            known = offsetKnown,
        )
    }

}

/**
 * Calendar arithmetic without java.time, which is API 26 and above, and without Math.floorDiv,
 * which is API 24. Pure, so the conversions are host-tested.
 */
internal object CivilDate {

    /** Floor division that rounds toward negative infinity, for instants before the epoch. */
    fun floorDiv(value: Long, divisor: Long): Long {
        var quotient = value / divisor
        if (value % divisor != 0L && ((value xor divisor) < 0L)) quotient -= 1L
        return quotient
    }

    /** Sunday is zero, matching core's weekday_num; 1970-01-01 was a Thursday. */
    fun weekday(daysSinceEpoch: Long): Int {
        val shifted = daysSinceEpoch + 4L
        return (shifted - floorDiv(shifted, 7L) * 7L).toInt()
    }

    /** Howard Hinnant's days-to-civil conversion; returns [year, month, day]. */
    fun fromDays(daysSinceEpoch: Long): IntArray {
        val z = daysSinceEpoch + 719468L
        val era = floorDiv(z, 146097L)
        val dayOfEra = z - era * 146097L
        val yearOfEra = (dayOfEra - dayOfEra / 1460L + dayOfEra / 36524L - dayOfEra / 146096L) /
            365L
        var year = yearOfEra + era * 400L
        val dayOfYear = dayOfEra - (365L * yearOfEra + yearOfEra / 4L - yearOfEra / 100L)
        val monthPrime = (5L * dayOfYear + 2L) / 153L
        val day = dayOfYear - (153L * monthPrime + 2L) / 5L + 1L
        val month = if (monthPrime < 10L) monthPrime + 3L else monthPrime - 9L
        if (month <= 2L) year += 1L
        return intArrayOf(year.toInt(), month.toInt(), day.toInt())
    }
}
