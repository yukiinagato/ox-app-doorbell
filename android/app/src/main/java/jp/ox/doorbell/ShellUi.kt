// Shared building blocks for the code-built screens (docs/en/ui-guidelines.md).
//
// Controls come from the flavor's PlatformUi (Material Components on modern, framework widgets
// on legacy19) with their stock appearance; this file only composes them into the recurring
// arrangements: section headings, list rows, status chips. Two-part labels are rendered by
// [twoPartText] so the deliberate break and the smaller second line are identical everywhere.
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

    /** The door tile's corner radius; a scrim behind a list matches it. */
    const val CARD_RADIUS_DP = 12
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

    /** 70 % of the card colour, as an alpha byte. */
    const val SCRIM_ALPHA = 179

    /**
     * A translucent card: the shape and tone [card] uses, letting a little of what is behind it
     * through. It is what goes under a list that sits on the theme picture -- the rows then have
     * a known surface and keep their own palette colours, instead of every row having to be
     * measured against whatever part of the wallpaper it happens to land on.
     */
    fun scrim(context: Context, fillRgb: Int, radiusDp: Int = CARD_RADIUS_DP,
              alpha: Int = SCRIM_ALPHA): GradientDrawable = GradientDrawable().apply {
        setColor((alpha.coerceIn(0, 255) shl 24) or (fillRgb and 0xffffff))
        cornerRadius = dp(context, radiusDp).toFloat()
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

    /** Text in one step of the platform type ramp, in the theme's own ink. */
    fun label(context: Context, value: CharSequence, role: TextRole, colorRgb: Int? = null): TextView =
        TextView(context).apply {
            text = value
            @Suppress("DEPRECATION")
            setTextAppearance(context, when (role) {
                TextRole.DISPLAY -> R.style.TextAppearance_Doorbell_Display
                TextRole.HEADLINE -> R.style.TextAppearance_Doorbell_Headline
                TextRole.TITLE -> R.style.TextAppearance_Doorbell_Title
                TextRole.SUBTITLE -> R.style.TextAppearance_Doorbell_Subtitle
                TextRole.BODY -> R.style.TextAppearance_Doorbell_Body
                TextRole.SUPPORTING -> R.style.TextAppearance_Doorbell_Supporting
                TextRole.LABEL -> R.style.TextAppearance_Doorbell_Label
            })
            val tokens = PlatformUi.tokens(context)
            setTextColor(opaque(colorRgb ?: when (role) {
                TextRole.SUPPORTING, TextRole.LABEL -> tokens.muted
                else -> tokens.ink
            }))
        }

    /** A section heading above a group of rows: the label style in the accent. */
    fun sectionHeading(context: Context, palette: Palette, value: String): TextView =
        label(context, value, TextRole.LABEL, accentInk(palette)).apply {
            setTypeface(typeface, Typeface.BOLD)
            setPadding(dp(context, 16), dp(context, 20), dp(context, 16), dp(context, 8))
        }

    /** The accent as text on the ground, or the plain ink when the accent would not read there. */
    fun accentInk(palette: Palette): Int =
        if (UiStylePolicy.contrast(palette.accent, palette.ground) >= 4.5) palette.accent
        else palette.ink

    /** A status chip in semantic colours. */
    fun pill(
        context: Context,
        value: CharSequence,
        backgroundRgb: Int,
        inkRgb: Int,
        @Suppress("UNUSED_PARAMETER") sizeSp: Float = 12.5f,
        @Suppress("UNUSED_PARAMETER") borderRgb: Int? = null,
    ): TextView = PlatformUi.chip(context, value, ChipKind.STATUS, fillRgb = backgroundRgb,
                                  inkRgb = inkRgb)

    /**
     * A focusable action: filled when [primary] or given a role colour, tonal otherwise. Its
     * label may carry a deliberate second line.
     */
    fun button(
        context: Context,
        label: TwoPartLabel,
        palette: Palette,
        primary: Boolean = false,
        backgroundRgb: Int? = null,
        inkRgb: Int? = null,
        onClick: () -> Unit,
    ): Button {
        val filled = primary || backgroundRgb != null
        val kind = if (filled) ButtonKind.FILLED else ButtonKind.TONAL
        return PlatformUi.button(context, kind).apply {
            if (backgroundRgb != null) PlatformUi.styleButton(this, kind, backgroundRgb, inkRgb)
            text = twoPartText(label, currentTextColor and 0xffffff, palette.dark)
            isFocusable = true
            minHeight = dp(context, TOUCH_FLOOR_DP)
            minimumHeight = dp(context, TOUCH_FLOOR_DP)
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

    /** A group of rows: the platform's card, its content edge to edge so rows ripple fully. */
    fun card(context: Context, @Suppress("UNUSED_PARAMETER") palette: Palette): CardHandle =
        PlatformUi.card(context)

    /**
     * One list row: title, the current value under it, an optional explanation, and an optional
     * trailing control. The whole row is the touch target when [onClick] is given.
     */
    fun row(
        context: Context,
        palette: Palette,
        title: String,
        value: String = "",
        note: String = "",
        enabled: Boolean = true,
        trailing: View? = null,
        icon: Int = 0,
        onClick: (() -> Unit)? = null,
    ): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        isBaselineAligned = false
        minimumHeight = dp(context, if (value.isEmpty() && note.isEmpty()) ROW_MIN_DP else ROW_TALL_DP)
        setPadding(dp(context, 16), dp(context, 8), dp(context, 16), dp(context, 8))
        if (icon != 0) addView(android.widget.ImageView(context).apply {
            setImageResource(icon)
            setColorFilter(opaque(palette.muted))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(dp(context, 24), dp(context, 24)).apply {
            rightMargin = dp(context, 16)
        })
        val texts = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        texts.addView(label(context, title, TextRole.BODY, if (enabled) palette.ink else palette.muted))
        if (value.isNotEmpty()) texts.addView(label(context, value, TextRole.SUPPORTING))
        if (note.isNotEmpty()) texts.addView(label(context, note, TextRole.LABEL).apply {
            setPadding(0, dp(context, 2), 0, 0)
        })
        addView(texts, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        if (trailing != null) addView(trailing, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { leftMargin = dp(context, 16) })
        if (onClick != null && enabled) {
            isFocusable = true
            isClickable = true
            val ripple = android.util.TypedValue()
            context.theme.resolveAttribute(android.R.attr.selectableItemBackground, ripple, true)
            setBackgroundResource(ripple.resourceId)
            setOnClickListener { onClick() }
        }
    }

    private const val ROW_MIN_DP = 56
    private const val ROW_TALL_DP = 72

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
