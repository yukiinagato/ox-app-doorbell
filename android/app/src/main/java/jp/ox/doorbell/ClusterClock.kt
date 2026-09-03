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

/**
 * The last answer core gave, with the monotonic reading it was taken at.
 *
 * The wall clock is re-derived from the monotonic clock rather than read again, so the displayed
 * second advances at a steady 1 Hz even while core's run loop is busy, and re-anchors to core's
 * corrected time on the next refresh.
 */
internal data class TimeAnchor(
    val wallMs: Long,
    val elapsedMs: Long,
    val offsetMin: Int,
    val zone: String,
    val known: Boolean,
)

/** The anchor arithmetic, with no Android or core dependency, so every case is host-tested. */
internal object ClusterClockMath {

    /** How long an anchor is trusted before core is asked again. */
    const val MAX_AGE_MS = 30_000L

    /** Where the cluster wall clock has got to, from the anchor and the monotonic clock. */
    fun projectedWallMs(anchor: TimeAnchor, elapsedNowMs: Long): Long =
        anchor.wallMs + (elapsedNowMs - anchor.elapsedMs)

    /**
     * Whether core should be asked again. A missing anchor is stale, and so is one from the
     * future: the monotonic clock cannot go backwards, so that means the reading is not usable.
     */
    fun stale(anchor: TimeAnchor?, elapsedNowMs: Long, maxAgeMs: Long = MAX_AGE_MS): Boolean {
        if (anchor == null) return true
        val age = elapsedNowMs - anchor.elapsedMs
        return age < 0L || age >= maxAgeMs
    }
}

internal class ClusterClock(
    private val core: DoorbellCore,
    private val elapsedRealtimeMs: () -> Long = { android.os.SystemClock.elapsedRealtime() },
    private val platformWallMs: () -> Long = { System.currentTimeMillis() },
) {

    @Volatile
    private var offsetMin: Int = 0

    @Volatile
    private var offsetKnown = false

    @Volatile
    private var anchor: TimeAnchor? = null

    /** One worker at a time; a burst of ticks must not start a thread each. */
    private val refreshing = java.util.concurrent.atomic.AtomicBoolean(false)

    /**
     * Read the current cluster time. **Blocks**: db_core_local_time_json is a synchronous round
     * trip onto core's run loop, so this waits behind whatever the loop is doing.
     *
     * Use it from a worker thread, or from a one-off path where a stall is invisible. Anything
     * that repeats -- a 1 Hz clock above all -- must use [cached] instead: called once a second
     * from the main thread this made the dashboard clock advance in three-second jumps, because
     * each tick sat waiting on the loop while NTP and status work went through it.
     */
    fun now(): ClusterTime {
        val document = try { core.localTime(0L) } catch (_: Exception) { null }
        if (document == null) return fallback(platformWallMs())
        offsetMin = document.optInt("offset_min", offsetMin)
        offsetKnown = true
        val wallMs = document.optLong("wall_ms", platformWallMs())
        val zone = document.optString("tz")
        val known = document.optBoolean("known", true)
        anchor = TimeAnchor(wallMs, elapsedRealtimeMs(), offsetMin, zone, known)
        return ClusterTime(
            wallMs = wallMs,
            offsetMin = offsetMin,
            hour = document.optInt("hh", 0),
            minute = document.optInt("mm", 0),
            second = document.optInt("ss", 0),
            date = document.optString("date"),
            weekdayNum = document.optInt("weekday_num", 0),
            zone = zone,
            known = known,
        )
    }

    /**
     * The current cluster time without touching core: projected from the last anchor and the
     * monotonic clock. Cheap enough for the main thread at 1 Hz, which is the point.
     *
     * Before the first anchor arrives this is the device clock, which is what the shell showed
     * anyway whenever core could not answer.
     */
    fun cached(): ClusterTime {
        val held = anchor ?: return fallback(platformWallMs())
        val wallMs = ClusterClockMath.projectedWallMs(held, elapsedRealtimeMs())
        return shift(wallMs, held.offsetMin).copy(zone = held.zone, known = held.known)
    }

    /**
     * Re-anchor on a worker thread when the anchor has aged out, so the displayed time keeps
     * following core's NTP correction and the configured zone without any tick ever blocking.
     * Returns at once; [onRefreshed] runs on the worker.
     */
    fun refreshIfStale(maxAgeMs: Long = ClusterClockMath.MAX_AGE_MS,
                       onRefreshed: (() -> Unit)? = null) {
        if (!ClusterClockMath.stale(anchor, elapsedRealtimeMs(), maxAgeMs)) return
        if (!refreshing.compareAndSet(false, true)) return
        Thread({
            try { now() } catch (_: Exception) { } finally { refreshing.set(false) }
            onRefreshed?.invoke()
        }, "doorbell-clock").apply { isDaemon = true }.start()
    }

    /** Core says the time moved: drop the anchor so the next tick re-reads it. */
    fun invalidate() {
        anchor = null
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

    /** Whether core has ever answered, so a caller can say the zone is not confirmed. */
    val anchored: Boolean get() = anchor != null

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
