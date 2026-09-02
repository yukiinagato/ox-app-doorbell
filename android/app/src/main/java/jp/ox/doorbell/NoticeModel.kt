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
     * The announcement core already resolved for one door.
     *
     * status.doors.<id>.notice carries the value that door actually shows plus a "scope" of
     * "door" or "global", so the shell renders it rather than merging the two sources itself.
     * Returns null when core published nothing, and the caller then falls back to [effective].
     */
    fun fromStatus(status: JSONObject?, door: String, nowMs: Long): Notice? {
        if (door.isEmpty()) return null
        val entry = status?.optJSONObject("doors")?.optJSONObject(door) ?: return null
        if (!entry.has("notice") || entry.isNull("notice")) return null
        val notice = parse(
            entry.optJSONObject("notice"),
            doorSpecific = entry.optJSONObject("notice")?.optString("scope") != "global",
        ) ?: return null
        return notice.takeIf { it.activeAt(nowMs) }
    }

    /**
     * The announcement a given door should render right now, derived from configuration: its own
     * value when one is active, otherwise the cluster-wide value. This is the fallback for a core
     * that does not publish the resolved value; prefer [fromStatus]. Expired values are treated as
     * absent on every shell so a pruning tick that has not run yet never leaves stale text on a
     * door station.
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

    /**
     * The value a screen paints: core's resolved answer when it has one, otherwise the local
     * derivation. Every screen goes through this so the two paths never diverge.
     */
    fun resolve(status: JSONObject?, config: JSONObject?, door: String, nowMs: Long): Notice? =
        fromStatus(status, door, nowMs) ?: effective(config, door, nowMs)

    /** Doors that currently show an announcement, used for the dashboard tile chips. */
    fun activeDoors(
        status: JSONObject?,
        config: JSONObject?,
        doors: List<String>,
        nowMs: Long,
    ): Set<String> = doors.filter { resolve(status, config, it, nowMs) != null }.toSet()

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
     * Which door identifiers one publish action addresses.
     *
     * 「全体」 is a single write to the cluster-wide announcement, which core stores at
     * notice.global; a door-specific announcement always overrides it, so the two never have to be
     * merged by hand. [allDoors] is unused by the global path and kept only so a caller can pass
     * the door list it already has.
     */
    fun writeTargets(
        target: NoticeTarget,
        door: String,
        @Suppress("UNUSED_PARAMETER") allDoors: List<String> = emptyList(),
    ): List<String> =
        if (target == NoticeTarget.GLOBAL) listOf(DoorbellCore.GLOBAL_DOOR)
        else listOf(door).filter { it.isNotEmpty() && it != DoorbellCore.GLOBAL_DOOR }
}

internal enum class ExpiryChoice { ONE_HOUR, TODAY, UNTIL_CLEARED, CUSTOM }
