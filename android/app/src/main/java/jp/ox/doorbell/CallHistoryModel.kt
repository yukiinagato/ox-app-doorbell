// Call history projection for the dashboard list and the full-screen paged history (spec §5.1).
//
// Core returns rows newest first from db_core_call_log_json(since_ms, limit). The full-screen page
// loads fifty rows at a time and continues from the oldest row it already has, so paging is
// expressed here as a "before" watermark over the returned rows rather than in the caller.
// Everything is pure and host-tested.
package jp.ox.doorbell

import org.json.JSONObject

internal data class CallRow(
    val id: String,
    val callId: String,
    val tsMs: Long,
    val door: String,
    val purpose: String,
    val visitorLang: String,
    val outcome: String,
    val answeredBy: String,
    val durationMs: Long,
    val hlc: String,
    val seen: Boolean,
) {
    val missed: Boolean get() = outcome == "missed"
}

internal enum class HistoryFilter { ALL, MISSED, DOOR }

/** One rendered day group: a heading plus the rows that belong to it. */
internal data class DayGroup(val dayKey: String, val rows: List<CallRow>)

internal object CallHistoryModel {

    const val PAGE_SIZE = 50
    const val DASHBOARD_ROWS = 20

    fun parse(document: JSONObject?): List<CallRow> {
        val rows = document?.optJSONArray("rows") ?: return emptyList()
        val out = ArrayList<CallRow>(rows.length())
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            val id = row.optString("id")
            if (id.isEmpty()) continue
            out.add(
                CallRow(
                    id = id,
                    callId = row.optString("call_id"),
                    tsMs = row.optLong("ts", 0L),
                    door = row.optString("door"),
                    purpose = row.optString("purpose"),
                    visitorLang = row.optString("visitor_lang"),
                    outcome = row.optString("outcome"),
                    answeredBy = row.optString("answered_by"),
                    durationMs = row.optLong("duration_ms", 0L),
                    hlc = row.optString("hlc"),
                    seen = row.optBoolean("seen", true),
                ),
            )
        }
        return out
    }

    fun unreadMissed(document: JSONObject?): Int = document?.optInt("unread_missed", 0) ?: 0

    /** Newest row's hlc, which is the watermark passed to db_core_call_log_mark_seen. */
    fun newestHlc(rows: List<CallRow>): String = rows.firstOrNull()?.hlc.orEmpty()

    fun filter(rows: List<CallRow>, filter: HistoryFilter, door: String): List<CallRow> =
        when (filter) {
            HistoryFilter.ALL -> rows
            HistoryFilter.MISSED -> rows.filter { it.missed }
            HistoryFilter.DOOR -> if (door.isEmpty()) rows else rows.filter { it.door == door }
        }

    /**
     * The rows for a page. Core's limit is a whole-history cap, so a page is taken by asking for
     * (pages * PAGE_SIZE) rows and returning the newest slice; [hasMore] says whether asking for
     * one more page can still produce rows.
     */
    fun page(rows: List<CallRow>, pages: Int): List<CallRow> =
        rows.take((pages.coerceAtLeast(1)) * PAGE_SIZE)

    /** The limit to request from core for a given page count, leaving room to detect more rows. */
    fun requestLimit(pages: Int): Int =
        ((pages.coerceAtLeast(1)) * PAGE_SIZE + 1).coerceAtMost(500)

    /** True when core returned more rows than the page shows, so "load more" stays enabled. */
    fun hasMore(returned: Int, pages: Int): Boolean =
        returned > (pages.coerceAtLeast(1)) * PAGE_SIZE

    /**
     * Oldest timestamp already shown, so a caller that gains a real before_ms paging ABI can
     * continue from here without changing the screen.
     */
    fun beforeMs(rows: List<CallRow>): Long = rows.lastOrNull()?.tsMs ?: 0L

    /** Group rows into day sections, preserving the newest-first order within and between days. */
    fun group(rows: List<CallRow>, dayKeyOf: (Long) -> String): List<DayGroup> {
        val out = ArrayList<DayGroup>()
        var currentKey: String? = null
        var current = ArrayList<CallRow>()
        for (row in rows) {
            val key = dayKeyOf(row.tsMs)
            if (key != currentKey) {
                if (currentKey != null) out.add(DayGroup(currentKey, current))
                currentKey = key
                current = ArrayList()
            }
            current.add(row)
        }
        if (currentKey != null) out.add(DayGroup(currentKey, current))
        return out
    }

    fun durationText(durationMs: Long): String {
        if (durationMs <= 0L) return ""
        val totalSeconds = durationMs / 1000L
        return String.format(
            java.util.Locale.US, "%d:%02d", totalSeconds / 60L, totalSeconds % 60L,
        )
    }
}
