// The dashboard's live-still refresh rate: a per-device preference (parity with iOS), not
// replicated configuration, because it trades this panel's CPU and network for smoothness.
package jp.ox.doorbell

import android.content.Context

internal object PreviewRate {
    /** Frames per second offered to the resident; the same set iOS offers. */
    val RATES = listOf(0.5, 1.0, 2.0, 4.0)
    const val DEFAULT = 2.0
    private const val PREFS = "doorbell-dashboard"
    private const val KEY = "preview_fps"

    fun saved(context: Context): Double {
        val stored = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getFloat(KEY, DEFAULT.toFloat()).toDouble()
        return RATES.firstOrNull { it == stored } ?: DEFAULT
    }

    fun save(context: Context, rate: Double) {
        if (rate !in RATES) return
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putFloat(KEY, rate.toFloat()).apply()
    }

    fun intervalMs(rate: Double): Long = (1000.0 / rate).toLong().coerceAtLeast(250L)

    /** "0.5", "1", "2", "4" -- the value shown in the {rate} fps label. */
    fun valueText(rate: Double): String =
        if (rate == Math.floor(rate)) rate.toLong().toString() else rate.toString()
}
