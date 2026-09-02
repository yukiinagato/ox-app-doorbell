// Door announcements: targeting, expiry, and the admin-editable preset list (spec §4.3, §5.2).
//
// Core stores a per-door value at doors.<id>.notice and a cluster-wide value at notice.global.
// A door-specific announcement always wins over the global one. Everything here is pure so the
// precedence, the expiry pruning, and the preset parsing are covered by host unit tests.
package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject

internal enum class NoticeTarget { GLOBAL, DOOR }

internal data class Notice(
    val text: String,
    val fromDevice: String,
    val createdMs: Long,
    val expiresMs: Long,
    /** True when this value came from doors.<id>.notice rather than notice.global. */
    val doorSpecific: Boolean,
) {
    fun activeAt(nowMs: Long): Boolean =
        text.isNotEmpty() && (expiresMs <= 0L || expiresMs > nowMs)
}

internal data class NoticePreset(val id: String, val text: String)

internal object NoticeModel {

    const val MAX_TEXT = 200
    const val MAX_PRESETS = 8

    /** Parse one stored announcement object. Returns null for absent or malformed values. */
    fun parse(value: JSONObject?, doorSpecific: Boolean): Notice? {
        val text = value?.optString("text").orEmpty()
        if (text.isEmpty()) return null
        return Notice(
            text = text,
            fromDevice = value?.optString("from_device").orEmpty(),
            createdMs = value?.optLong("created_ms", 0L) ?: 0L,
            expiresMs = value?.optLong("expires_ms", 0L) ?: 0L,
            doorSpecific = doorSpecific,
        )
    }

    /**
     * The announcement a given door should render right now: its own value when one is active,
     * otherwise the cluster-wide value. Expired values are treated as absent on every shell so a
     * pruning tick that has not run yet never leaves stale text on a door station.
     */
    fun effective(config: JSONObject?, door: String, nowMs: Long): Notice? {
        val doorValue = if (door.isEmpty()) null else parse(
            config?.optJSONObject("doors")?.optJSONObject(door)?.optJSONObject("notice"),
            doorSpecific = true,
        )
        if (doorValue != null && doorValue.activeAt(nowMs)) return doorValue
        val global = parse(config?.optJSONObject("notice")?.optJSONObject("global"), false)
        return global?.takeIf { it.activeAt(nowMs) }
    }

    /** Doors that currently show an announcement, used for the dashboard tile chips. */
    fun activeDoors(config: JSONObject?, doors: List<String>, nowMs: Long): Set<String> =
        doors.filter { effective(config, it, nowMs) != null }.toSet()

    /**
     * The presets rendered by the dialog. Defaults are seeded by core; an empty or malformed list
     * falls back to the three catalog defaults the caller supplies so the dialog is never bare.
     */
    fun presets(config: JSONObject?, fallback: List<String>): List<NoticePreset> {
        val stored = config?.optJSONObject("notice")?.optJSONArray("presets")
            ?: config?.opt("notice.presets") as? JSONArray
        val out = ArrayList<NoticePreset>(MAX_PRESETS)
        if (stored != null) {
            for (index in 0 until stored.length()) {
                if (out.size >= MAX_PRESETS) break
                val entry = stored.optJSONObject(index)
                val text = (entry?.optString("text") ?: stored.optString(index)).orEmpty().trim()
                if (text.isEmpty() || text.length > MAX_TEXT) continue
                val id = entry?.optString("id")?.takeIf { it.isNotEmpty() } ?: "p$index"
                out.add(NoticePreset(id, text))
            }
        }
        if (out.isNotEmpty()) return out
        return fallback.filter { it.isNotEmpty() }.take(MAX_PRESETS)
            .mapIndexed { index, text -> NoticePreset("default$index", text) }
    }

    /** Validation shared by the dialog and the settings screen. */
    fun validate(text: String): String? = when {
        text.trim().isEmpty() -> "empty"
        text.length > MAX_TEXT -> "too_long"
        else -> null
    }

    /** Absolute deadline for an expiry choice; zero means "until cleared". */
    fun expiryFor(choice: ExpiryChoice, nowMs: Long, endOfDayMs: Long, hours: Int): Long =
        when (choice) {
            ExpiryChoice.ONE_HOUR -> nowMs + 3_600_000L
            ExpiryChoice.TODAY -> endOfDayMs
            ExpiryChoice.UNTIL_CLEARED -> 0L
            ExpiryChoice.CUSTOM -> nowMs + hours.coerceIn(1, 24 * 30) * 3_600_000L
        }

    /**
     * Which doors one publish action writes.
     *
     * Core exposes db_core_set_door_notice per door but no global entry point, so "全体" is
     * carried out as a write to every configured door, which is exactly the replicated result
     * §5.1 describes (doors.*.notice for every door). Reading still prefers a door-specific value
     * over notice.global when a newer core publishes one.
     */
    fun writeTargets(target: NoticeTarget, door: String, allDoors: List<String>): List<String> =
        if (target == NoticeTarget.GLOBAL) allDoors.filter { it.isNotEmpty() }
        else listOf(door).filter { it.isNotEmpty() }
}

internal enum class ExpiryChoice { ONE_HOUR, TODAY, UNTIL_CLEARED, CUSTOM }
