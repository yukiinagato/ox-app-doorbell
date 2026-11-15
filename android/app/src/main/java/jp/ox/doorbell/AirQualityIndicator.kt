// The compact PM2.5 line on both home screens: a level dot and one line of text that takes the
// same per-region ink as the clock and date it sits under.
package jp.ox.doorbell

import android.content.Context
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView

internal class AirQualityIndicator(private val context: Context, val label: TextView) {

    val root: LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        visibility = View.GONE
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        isFocusable = false
    }

    private val dot = View(context).apply {
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private val dotShape = GradientDrawable().apply { shape = GradientDrawable.OVAL }

    var reading: AirQualityReading = AirQualityReading.HIDDEN
        private set
    private var renderKey = ""

    init {
        val size = ShellUi.dp(context, 10)
        root.addView(dot, LinearLayout.LayoutParams(size, size).apply {
            rightMargin = ShellUi.dp(context, UiTokens.SPACE_S)
        })
        dot.background = dotShape
        label.maxLines = 1
        label.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        root.addView(label, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
        ))
    }

    /** Returns true when what is drawn changed, so the caller can repaint the region's ink. */
    fun render(value: AirQualityReading, texts: Texts, outlineRgb: Int): Boolean {
        val status = statusText(value, texts)
        val line = AirQualityModel.line(
            value,
            texts.t("air.pm25_label", R.string.air_pm25_label),
            texts.t("air.unit", R.string.air_unit),
            status,
        )
        val key = "${value.state}:${value.pm25}:${value.level}:$line:$outlineRgb"
        if (key == renderKey) return false
        renderKey = key
        reading = value
        if (!value.visible) {
            root.visibility = View.GONE
            return true
        }
        label.text = line
        val dotRgb = value.dotRgb
        if (dotRgb != null) {
            dotShape.setColor(ShellUi.opaque(dotRgb))
            // The outline keeps a light dot (moderate) visible on a light ground.
            dotShape.setStroke(ShellUi.dp(context, 1), ShellUi.opaque(outlineRgb))
            dot.visibility = View.VISIBLE
        } else {
            dot.visibility = View.GONE
        }
        root.contentDescription = if (value.hasValue)
            texts.t("air.a11y", R.string.air_a11y, value.pm25.toString(), status.orEmpty())
        else texts.t("air.a11y_no_value", R.string.air_a11y_no_value, status.orEmpty())
        root.visibility = View.VISIBLE
        return true
    }

    private fun statusText(value: AirQualityReading, texts: Texts): String? =
        when (AirQualityModel.statusKey(value)) {
            "air.unconfigured" -> texts.t("air.unconfigured", R.string.air_unconfigured)
            "air.waiting" -> texts.t("air.waiting", R.string.air_waiting)
            "air.stale" -> texts.t("air.stale", R.string.air_stale)
            "air.level_good" -> texts.t("air.level_good", R.string.air_level_good)
            "air.level_moderate" -> texts.t("air.level_moderate", R.string.air_level_moderate)
            "air.level_sensitive" -> texts.t("air.level_sensitive", R.string.air_level_sensitive)
            "air.level_unhealthy" -> texts.t("air.level_unhealthy", R.string.air_level_unhealthy)
            "air.level_very_unhealthy" ->
                texts.t("air.level_very_unhealthy", R.string.air_level_very_unhealthy)
            "air.level_hazardous" -> texts.t("air.level_hazardous", R.string.air_level_hazardous)
            else -> null
        }
}
