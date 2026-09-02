// Shared framework-view building blocks for the batch-2 screens (spec §5, §5.1).
//
// Every coloured-background text goes through [pill] or [button], which enforce the 6 dp vertical
// and 12 dp horizontal padding plus the 8 dp radius the audit requires. Two-part labels are
// rendered by [twoPartText] so the deliberate break and the smaller second line are identical
// everywhere. Framework widgets only: no androidx, no material.
package jp.ox.doorbell

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

internal object ShellUi {

    const val PILL_PADDING_V_DP = 6
    const val PILL_PADDING_H_DP = 12
    const val PILL_RADIUS_DP = 8
    const val TOUCH_FLOOR_DP = 48

    fun dp(context: Context, value: Int): Int =
        (value * context.resources.displayMetrics.density + 0.5f).toInt()

    fun opaque(rgb: Int): Int =
        Color.rgb(rgb ushr 16 and 0xff, rgb ushr 8 and 0xff, rgb and 0xff)

    fun matchWrap(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
    )

    fun rounded(context: Context, fillRgb: Int, radiusDp: Int = PILL_RADIUS_DP,
                borderRgb: Int? = null): GradientDrawable = GradientDrawable().apply {
        setColor(opaque(fillRgb))
        cornerRadius = dp(context, radiusDp).toFloat()
        borderRgb?.let { setStroke(dp(context, 1), opaque(it)) }
    }

    fun spacer(context: Context, heightDp: Int): View = View(context).apply {
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dp(context, heightDp),
        )
    }

    fun text(
        context: Context,
        value: CharSequence,
        sizeSp: Float,
        colorRgb: Int,
        bold: Boolean = false,
    ): TextView = TextView(context).apply {
        text = value
        textSize = sizeSp
        setTextColor(opaque(colorRgb))
        if (bold) setTypeface(typeface, Typeface.BOLD)
        includeFontPadding = false
    }

    /** A section heading for the settings list and the dashboard cards. */
    fun sectionHeading(context: Context, palette: Palette, value: String): TextView =
        text(context, value, 13f, palette.muted, bold = true).apply {
            setPadding(dp(context, 4), dp(context, 14), dp(context, 4), dp(context, 6))
        }

    /**
     * A padded coloured label. Never construct a coloured background for text by hand; this is
     * the one place the padding and radius floor is enforced.
     */
    fun pill(
        context: Context,
        value: CharSequence,
        backgroundRgb: Int,
        inkRgb: Int,
        sizeSp: Float = 12.5f,
        borderRgb: Int? = null,
    ): TextView = text(context, value, sizeSp, inkRgb).apply {
        background = rounded(context, backgroundRgb, 999, borderRgb)
        setPadding(
            dp(context, PILL_PADDING_H_DP), dp(context, PILL_PADDING_V_DP),
            dp(context, PILL_PADDING_H_DP), dp(context, PILL_PADDING_V_DP),
        )
        gravity = Gravity.CENTER
    }

    /** A focusable action. Its label may carry a deliberate second line. */
    fun button(
        context: Context,
        label: TwoPartLabel,
        palette: Palette,
        primary: Boolean = false,
        backgroundRgb: Int? = null,
        inkRgb: Int? = null,
        onClick: () -> Unit,
    ): Button {
        val fill = backgroundRgb ?: if (primary) palette.accent else palette.surfaceAlt
        val ink = inkRgb ?: if (primary) palette.accentInk else palette.ink
        return Button(context).apply {
            text = twoPartText(label, ink, palette.dark)
            isAllCaps = false
            textSize = 15f
            setTextColor(opaque(ink))
            background = rounded(context, fill, 10)
            isFocusable = true
            minHeight = dp(context, TOUCH_FLOOR_DP)
            minimumHeight = dp(context, TOUCH_FLOOR_DP)
            setPadding(
                dp(context, PILL_PADDING_H_DP), dp(context, PILL_PADDING_V_DP),
                dp(context, PILL_PADDING_H_DP), dp(context, PILL_PADDING_V_DP),
            )
            contentDescription = TwoPartLabels.flatten(label)
            setOnClickListener { onClick() }
        }
    }

    fun button(
        context: Context,
        value: String,
        palette: Palette,
        primary: Boolean = false,
        onClick: () -> Unit,
    ): Button = button(context, TwoPartLabel(value, ""), palette, primary, onClick = onClick)

    /**
     * Render a two-part label: primary at full size, secondary on its own line at 0.8x and muted.
     * The break is the authored one; nothing is wrapped mid-phrase.
     */
    fun twoPartText(label: TwoPartLabel, inkRgb: Int, dark: Boolean): CharSequence {
        if (!label.hasSecondary) return label.primary
        val builder = SpannableStringBuilder(label.primary).append('\n').append(label.secondary)
        val start = label.primary.length + 1
        builder.setSpan(
            RelativeSizeSpan(TwoPartLabels.SECONDARY_SCALE), start, builder.length,
            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
        )
        val muted = mute(inkRgb, dark)
        builder.setSpan(
            ForegroundColorSpan(opaque(muted)), start, builder.length,
            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
        )
        return builder
    }

    /**
     * A dimmer variant of an ink colour for the secondary line. Blending toward mid grey keeps the
     * hue and works in both appearances without needing the region's background here; the amount
     * is small enough that the secondary line stays above the 3:1 large-text ratio.
     */
    fun mute(inkRgb: Int, @Suppress("UNUSED_PARAMETER") dark: Boolean): Int {
        fun channel(shift: Int): Int {
            val value = inkRgb ushr shift and 0xff
            return (value * (1.0 - MUTE_BLEND) + 0x80 * MUTE_BLEND).toInt().coerceIn(0, 255)
        }
        return (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
    }

    private const val MUTE_BLEND = 0.3

    /** A grouped card used by the dashboard and the settings list. */
    fun card(context: Context, palette: Palette): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = rounded(context, palette.surface, 12, palette.line)
        val pad = dp(context, 12)
        setPadding(pad, pad, pad, pad)
    }

    /** One tappable settings row: title, optional value, optional secondary explanation. */
    fun row(
        context: Context,
        palette: Palette,
        title: String,
        value: String = "",
        note: String = "",
        enabled: Boolean = true,
        onClick: (() -> Unit)? = null,
    ): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        minimumHeight = dp(context, TOUCH_FLOOR_DP)
        val padH = dp(context, PILL_PADDING_H_DP)
        val padV = dp(context, 10)
        setPadding(padH, padV, padH, padV)
        background = rounded(context, palette.surface, PILL_RADIUS_DP, palette.line)
        addView(text(context, title, 15f, if (enabled) palette.ink else palette.muted))
        if (value.isNotEmpty())
            addView(text(context, value, 13.5f, palette.muted).apply {
                setPadding(0, dp(context, 2), 0, 0)
            })
        if (note.isNotEmpty())
            addView(text(context, note, 12.5f, palette.muted).apply {
                setPadding(0, dp(context, 4), 0, 0)
            })
        if (onClick != null && enabled) {
            isFocusable = true
            isClickable = true
            setOnClickListener { onClick() }
        }
    }

    /**
     * The `name · core vX · app vY · battery` line shown on every screen (§5.1). The battery part
     * disappears on a device that reports none, and charging is marked with a small glyph.
     */
    fun versionLine(
        name: String,
        coreVersion: String,
        appVersion: String,
        batteryPercent: Int,
        charging: Boolean,
        batteryText: (Int) -> String,
    ): String {
        val parts = ArrayList<String>(4)
        if (name.isNotEmpty()) parts.add(name)
        parts.add("core $coreVersion")
        parts.add("app $appVersion")
        if (batteryPercent in 0..100)
            parts.add(if (charging) "⚡ " + batteryText(batteryPercent)
                      else batteryText(batteryPercent))
        return parts.joinToString(" · ")
    }
}
