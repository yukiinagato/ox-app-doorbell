// Light and dark appearance for every Android screen (spec §5.1).
//
// display.appearance is a cluster value with a per-device override; auto_schedule is evaluated in
// the cluster time zone, which is why the caller passes the local hour and minute rendered by
// db_core_local_time_json rather than the OS clock. Android below API 29 has no system dark mode,
// so auto_system is read as auto_schedule there, exactly as the iPad 1 kiosk does.
package jp.ox.doorbell

import org.json.JSONObject

internal enum class AppearanceMode { AUTO_SYSTEM, AUTO_SCHEDULE, LIGHT, DARK }

/** The resolved token set for one appearance. All values are opaque 0xRRGGBB. */
internal data class Palette(
    val dark: Boolean,
    val ground: Int,
    val surface: Int,
    val surfaceAlt: Int,
    val ink: Int,
    val muted: Int,
    val line: Int,
    val accent: Int,
    val accentInk: Int,
    val noticeBg: Int,
    val noticeInk: Int,
    val noticeLine: Int,
    val danger: Int,
    val dangerSoft: Int,
    val dangerInk: Int,
    val okSoft: Int,
    val okInk: Int,
) {
    /** The ink token for a region whose own background is [backgroundRgb]. */
    fun inkOver(backgroundRgb: Int): Int =
        if (UiContrast.inkFor(backgroundRgb) == Ink.DARK) DARK_INK else LIGHT_INK

    companion object {
        const val LIGHT_INK = 0xF3F6F9
        const val DARK_INK = 0x11161B

        val LIGHT = Palette(
            dark = false,
            ground = 0xEEF1F4, surface = 0xFFFFFF, surfaceAlt = 0xF6F8FA,
            ink = 0x171B21, muted = 0x5F6B78, line = 0xD6DCE3,
            accent = 0x1E6FB8, accentInk = 0xFFFFFF,
            noticeBg = 0xFBF0D5, noticeInk = 0x6A4706, noticeLine = 0xE4C36A,
            danger = 0xB02A25, dangerSoft = 0xFBE3E1, dangerInk = 0x7C1A16,
            okSoft = 0xDFF1E3, okInk = 0x1F6B36,
        )

        val DARK = Palette(
            dark = true,
            ground = 0x0F1418, surface = 0x171E25, surfaceAlt = 0x1E2731,
            ink = 0xE8ECF0, muted = 0x9AA6B2, line = 0x2A3440,
            accent = 0x5FA3E6, accentInk = 0x0B1420,
            noticeBg = 0x3A2E10, noticeInk = 0xF1D28A, noticeLine = 0x6B5620,
            danger = 0xE06A63, dangerSoft = 0x3E1D1B, dangerInk = 0xF3B5B1,
            okSoft = 0x1B3524, okInk = 0x9BD9AB,
        )
    }
}

internal object Appearance {

    fun parseMode(value: String?): AppearanceMode = when (value) {
        "auto_schedule" -> AppearanceMode.AUTO_SCHEDULE
        "light" -> AppearanceMode.LIGHT
        "dark" -> AppearanceMode.DARK
        else -> AppearanceMode.AUTO_SYSTEM
    }

    fun modeKey(mode: AppearanceMode): String = when (mode) {
        AppearanceMode.AUTO_SYSTEM -> "auto_system"
        AppearanceMode.AUTO_SCHEDULE -> "auto_schedule"
        AppearanceMode.LIGHT -> "light"
        AppearanceMode.DARK -> "dark"
    }

    /**
     * Decide whether the dark palette applies.
     *
     * [systemDark] is null on a platform with no system dark mode, and auto_system then falls back
     * to the schedule. [minuteOfDay] is the cluster-local time; the window wraps midnight.
     */
    fun isDark(
        mode: AppearanceMode,
        systemDark: Boolean?,
        minuteOfDay: Int,
        darkFrom: Int,
        lightFrom: Int,
    ): Boolean = when (mode) {
        AppearanceMode.LIGHT -> false
        AppearanceMode.DARK -> true
        AppearanceMode.AUTO_SYSTEM -> systemDark
            ?: inDarkWindow(minuteOfDay, darkFrom, lightFrom)
        AppearanceMode.AUTO_SCHEDULE -> inDarkWindow(minuteOfDay, darkFrom, lightFrom)
    }

    /** True inside the [darkFrom, lightFrom) window, which normally wraps past midnight. */
    fun inDarkWindow(minuteOfDay: Int, darkFrom: Int, lightFrom: Int): Boolean {
        if (darkFrom == lightFrom) return false
        return if (darkFrom < lightFrom) minuteOfDay in darkFrom until lightFrom
        else minuteOfDay >= darkFrom || minuteOfDay < lightFrom
    }

    /** Parse "19:00" into minutes since midnight; null when the text is not a clock time. */
    fun parseClock(value: String?): Int? {
        val parts = value?.trim()?.split(":") ?: return null
        if (parts.size != 2) return null
        val hour = parts[0].toIntOrNull() ?: return null
        val minute = parts[1].toIntOrNull() ?: return null
        if (hour !in 0..23 || minute !in 0..59) return null
        return hour * 60 + minute
    }

    fun palette(dark: Boolean): Palette = if (dark) Palette.DARK else Palette.LIGHT

    /**
     * Read the effective appearance from configuration: the device override wins over the cluster
     * default, and the schedule falls back to the documented 19:00/06:30 window.
     */
    fun resolve(
        config: JSONObject?,
        nodeId: String,
        systemDark: Boolean?,
        minuteOfDay: Int,
    ): Palette {
        val deviceValue = config?.optJSONObject("devices")?.optJSONObject(nodeId)
            ?.optJSONObject("local")?.optJSONObject("display")?.optString("appearance")
            ?.takeIf { it.isNotEmpty() }
        val clusterValue = config?.optJSONObject("display")?.optString("appearance")
            ?.takeIf { it.isNotEmpty() }
        val mode = parseMode(deviceValue ?: clusterValue)
        val schedule = config?.optJSONObject("display")?.optJSONObject("appearance_schedule")
        val darkFrom = parseClock(schedule?.optString("dark_from")) ?: DEFAULT_DARK_FROM
        val lightFrom = parseClock(schedule?.optString("light_from")) ?: DEFAULT_LIGHT_FROM
        return palette(isDark(mode, systemDark, minuteOfDay, darkFrom, lightFrom))
    }

    const val DEFAULT_DARK_FROM = 19 * 60
    const val DEFAULT_LIGHT_FROM = 6 * 60 + 30
}
