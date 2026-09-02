package jp.ox.doorbell

import org.json.JSONObject

internal data class UiStyleBaseline(
    val foregroundArgb: Int?,
    val backgroundRgb: Int?,
    val accentRgb: Int? = null,
    val borderRgb: Int? = null,
    val radiusDp: Float = 0f,
)

internal data class ValidatedUiStyle(
    val scale: Float = 1f,
    val fontScale: Float = 1f,
    val foregroundRgb: Int? = null,
    val backgroundRgb: Int? = null,
    val accentRgb: Int? = null,
    val borderRgb: Int? = null,
    val radiusDp: Float? = null,
)

internal data class UiStyleValidation(
    val style: ValidatedUiStyle? = null,
    val reason: String = "",
) {
    val valid: Boolean get() = style != null
}

internal data class UiStyleResolution(
    val style: ValidatedUiStyle? = null,
    val source: String,
    val rejectionReason: String = "",
)

internal data class UiStyleApplyReport(
    val nodeId: String,
    val semanticId: String,
    val result: String,
    val validationError: String = "",
    val persistenceError: String = "",
) {
    val validationValid: Boolean get() = validationError.isEmpty()
    val lastKnownGoodPersisted: Boolean get() = persistenceError.isEmpty()
}

/** Pure validation for the exact subset advertised by the Android UI manifest. */
internal object UiStylePolicy {
    val allProperties = setOf(
        "scale", "font_scale", "foreground", "background", "accent", "border", "radius",
    )
    private val colorPattern = Regex("^#[0-9A-Fa-f]{6}$")

    fun resolve(
        proposed: JSONObject?,
        lastKnownGood: JSONObject?,
        baseline: UiStyleBaseline,
        safetyCritical: Boolean,
        allowedProperties: Set<String> = allProperties,
    ): UiStyleResolution {
        if (proposed == null) return UiStyleResolution(source = "platform_default")
        val proposedResult = validate(proposed, baseline, safetyCritical, allowedProperties)
        if (proposedResult.valid) return UiStyleResolution(
            proposedResult.style,
            source = "proposed",
        )
        val savedResult = lastKnownGood?.let {
            validate(it, baseline, safetyCritical, allowedProperties)
        }
        if (savedResult?.valid == true) return UiStyleResolution(
            savedResult.style,
            source = "last_known_good",
            rejectionReason = proposedResult.reason,
        )
        val reason = if (savedResult != null)
            "${proposedResult.reason}; last_known_good:${savedResult.reason}"
        else proposedResult.reason
        return UiStyleResolution(source = "platform_default", rejectionReason = reason)
    }

    fun validate(
        value: JSONObject,
        baseline: UiStyleBaseline,
        safetyCritical: Boolean,
        allowedProperties: Set<String> = allProperties,
    ): UiStyleValidation {
        if (value.toString().toByteArray(Charsets.UTF_8).size > MAX_STYLE_BYTES)
            return invalid("style_too_large")
        val keys = value.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            if (key !in allowedProperties || key !in allProperties)
                return invalid("unsupported_property:$key")
        }
        val scale = number(value, "scale") ?: if (value.has("scale"))
            return invalid("scale_must_be_number") else 1.0
        val fontScale = number(value, "font_scale") ?: if (value.has("font_scale"))
            return invalid("font_scale_must_be_number") else 1.0
        if (scale !in 0.75..2.0) return invalid("scale_out_of_range")
        if (fontScale !in 0.75..2.0) return invalid("font_scale_out_of_range")
        if (safetyCritical && scale < 1.0) return invalid("safety_scale_below_one")
        if (safetyCritical && fontScale < 1.0)
            return invalid("safety_font_scale_below_one")

        val foreground = color(value, "foreground")
        if (value.has("foreground") && foreground == null)
            return invalid("foreground_must_be_rrggbb")
        val background = color(value, "background")
        if (value.has("background") && background == null)
            return invalid("background_must_be_rrggbb")
        val accent = color(value, "accent")
        if (value.has("accent") && accent == null)
            return invalid("accent_must_be_rrggbb")
        val border = color(value, "border")
        if (value.has("border") && border == null)
            return invalid("border_must_be_rrggbb")
        val radius = number(value, "radius")
        if (value.has("radius") && radius == null)
            return invalid("radius_must_be_number")
        if (radius != null && radius !in 0.0..64.0) return invalid("radius_out_of_range")

        val colorsChanged = value.has("foreground") || value.has("background") ||
            value.has("accent") || value.has("border")
        val effectiveBackground = if (colorsChanged) background ?: baseline.backgroundRgb else null
        if (value.has("foreground") || value.has("background")) {
            effectiveBackground ?: return invalid("effective_background_unavailable")
            val effectiveForeground = foreground ?: baseline.foregroundArgb?.let {
                compositeOverRgb(it, effectiveBackground)
            } ?: return invalid("effective_foreground_unavailable")
            if (contrast(effectiveForeground, effectiveBackground) < MIN_TEXT_CONTRAST)
                return invalid("foreground_background_contrast_below_4_5")
        }
        if (value.has("accent") || value.has("background")) {
            effectiveBackground ?: return invalid("effective_background_unavailable")
            val effectiveAccent = accent ?: baseline.accentRgb
                ?: return invalid("effective_accent_unavailable")
            if (contrast(effectiveAccent, effectiveBackground) < MIN_CONTROL_CONTRAST)
                return invalid("accent_background_contrast_below_3")
        }
        if (value.has("border") || value.has("background")) {
            effectiveBackground ?: return invalid("effective_background_unavailable")
            val effectiveBorder = border ?: baseline.borderRgb
                ?: return invalid("effective_border_unavailable")
            if (contrast(effectiveBorder, effectiveBackground) < MIN_CONTROL_CONTRAST)
                return invalid("border_background_contrast_below_3")
        }
        return UiStyleValidation(ValidatedUiStyle(
            scale.toFloat(),
            fontScale.toFloat(),
            foreground,
            background,
            accent,
            border,
            radius?.toFloat(),
        ))
    }

    internal fun parseRgb(value: String): Int? =
        if (colorPattern.matches(value)) value.substring(1).toIntOrNull(16) else null

    internal fun contrast(firstRgb: Int, secondRgb: Int): Double {
        val first = luminance(firstRgb)
        val second = luminance(secondRgb)
        return (maxOf(first, second) + 0.05) / (minOf(first, second) + 0.05)
    }

    private fun color(value: JSONObject, key: String): Int? {
        if (!value.has(key) || value.opt(key) !is String) return null
        return parseRgb(value.optString(key))
    }

    private fun number(value: JSONObject, key: String): Double? {
        val raw = value.opt(key) as? Number ?: return null
        return raw.toDouble().takeIf { it.isFinite() }
    }

    private fun compositeOverRgb(foregroundArgb: Int, backgroundRgb: Int): Int {
        val alpha = foregroundArgb ushr 24 and 0xff
        if (alpha == 255) return foregroundArgb and RGB_MASK
        if (alpha == 0) return backgroundRgb
        fun channel(shift: Int): Int {
            val foreground = foregroundArgb ushr shift and 0xff
            val background = backgroundRgb ushr shift and 0xff
            return (foreground * alpha + background * (255 - alpha) + 127) / 255
        }
        return channel(16) shl 16 or channel(8) shl 8 or channel(0)
    }

    private fun luminance(rgb: Int): Double {
        fun channel(shift: Int): Double {
            val encoded = (rgb ushr shift and 0xff) / 255.0
            return if (encoded <= 0.04045) encoded / 12.92
            else Math.pow((encoded + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private fun invalid(reason: String) = UiStyleValidation(reason = reason)

    private const val MAX_STYLE_BYTES = 4 * 1024
    private const val MIN_TEXT_CONTRAST = 4.5
    private const val MIN_CONTROL_CONTRAST = 3.0
    private const val RGB_MASK = 0x00ffffff
}
