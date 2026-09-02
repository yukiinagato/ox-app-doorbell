// Shared colour mathematics for the automatic-ink and automatic-accent rules (spec §5, §5.2).
//
// Core publishes display.theme.auto_ink and display.theme.auto_accent so every shell agrees on
// the same answer. These functions are the local fallback used when an older core omits those
// fields, and they also produce the advisory WCAG warning shown next to every colour field.
// Everything here is pure so it is covered by host unit tests.
package jp.ox.doorbell

/** Either the light ink token or the dark ink token for one screen region. */
internal enum class Ink { LIGHT, DARK }

internal object UiContrast {

    /** Relative luminance per WCAG 2.x on linearised sRGB. rgb is 0xRRGGBB. */
    fun luminance(rgb: Int): Double {
        fun channel(shift: Int): Double {
            val encoded = (rgb ushr shift and 0xff) / 255.0
            return if (encoded <= 0.04045) encoded / 12.92
            else Math.pow((encoded + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /** WCAG contrast ratio between two opaque colours; always >= 1.0. */
    fun contrast(firstRgb: Int, secondRgb: Int): Double {
        val first = luminance(firstRgb)
        val second = luminance(secondRgb)
        return (maxOf(first, second) + 0.05) / (minOf(first, second) + 0.05)
    }

    /** "3.1" style ratio text for the advisory warning; one decimal, no rounding surprises. */
    fun ratioText(ratio: Double): String = String.format(java.util.Locale.US, "%.1f", ratio)

    /**
     * The ink that actually reads best: whichever token has the higher WCAG contrast ratio
     * against this background.
     *
     * A midpoint on luminance is the wrong test, because contrast is not linear in luminance --
     * the crossover between the two ink tokens sits near Y = 0.179, not 0.5. The observed failure
     * was a wallpaper averaging #BBBBB4 (Y = 0.494), which a "Y >= 0.5 selects dark" rule called
     * light-on-light at 1.9:1 when the dark ink would have given 9.6:1.
     */
    fun inkFor(backgroundRgb: Int): Ink =
        inkFor(backgroundRgb, Palette.LIGHT_INK, Palette.DARK_INK)

    /** The same choice against an explicit pair of ink tokens. */
    fun inkFor(backgroundRgb: Int, lightInkRgb: Int, darkInkRgb: Int): Ink =
        if (contrast(darkInkRgb, backgroundRgb) >= contrast(lightInkRgb, backgroundRgb)) Ink.DARK
        else Ink.LIGHT

    /**
     * The luminance at which the two ink tokens read equally well. Below it the light ink wins,
     * above it the dark one. Roughly 0.179 for near-black and near-white tokens.
     */
    fun inkCrossoverLuminance(lightInkRgb: Int, darkInkRgb: Int): Double {
        // contrast(light, Y) == contrast(dark, Y) solves to Y = sqrt((Ld+0.05)(Ll+0.05)) - 0.05.
        val light = luminance(lightInkRgb)
        val dark = luminance(darkInkRgb)
        return Math.sqrt((dark + 0.05) * (light + 0.05)) - 0.05
    }

    /**
     * Average an already-downscaled region as ARGB pixels. Fully transparent pixels are ignored
     * so a sparse overlay does not drag the average toward black.
     */
    fun averageRgb(pixels: IntArray): Int {
        var red = 0L
        var green = 0L
        var blue = 0L
        var counted = 0L
        for (pixel in pixels) {
            if ((pixel ushr 24 and 0xff) == 0) continue
            red += (pixel ushr 16 and 0xff).toLong()
            green += (pixel ushr 8 and 0xff).toLong()
            blue += (pixel and 0xff).toLong()
            counted++
        }
        if (counted == 0L) return 0
        return (((red / counted).toInt() and 0xff) shl 16) or
            (((green / counted).toInt() and 0xff) shl 8) or
            ((blue / counted).toInt() and 0xff)
    }

    /**
     * True when the chosen ink needs the 1 px opposite-ink shadow because it still falls short of
     * the 4.5:1 text ratio over this background.
     */
    fun needsTextShadow(inkRgb: Int, backgroundRgb: Int): Boolean =
        contrast(inkRgb, backgroundRgb) < TEXT_AA

    /**
     * Compute the door station's call-button background from its effective background (§5.2):
     * rotate the hue by 180°, then move lightness until the button separates from the background
     * by at least 3:1 and its text keeps 4.5:1, preferring the dark direction on light grounds.
     * Returns the button background; [callButtonInk] picks the matching text colour.
     */
    fun autoAccent(backgroundRgb: Int): Int {
        val hsl = rgbToHsl(backgroundRgb)
        val hue = (hsl[0] + 180.0) % 360.0
        val saturation = hsl[1].coerceAtLeast(0.35)
        val preferDark = luminance(backgroundRgb) >= 0.5
        val order = if (preferDark) DARK_FIRST else LIGHT_FIRST
        var best = hslToRgb(hue, saturation, if (preferDark) 0.2 else 0.8)
        var bestScore = -1.0
        for (lightness in order) {
            val candidate = hslToRgb(hue, saturation, lightness)
            val separation = contrast(candidate, backgroundRgb)
            val ink = callButtonInk(candidate)
            val readable = contrast(ink, candidate)
            if (separation >= UI_AA && readable >= TEXT_AA) return candidate
            // Keep the closest candidate so a background that cannot be separated still yields
            // the most legible button rather than an arbitrary one.
            val score = minOf(separation / UI_AA, readable / TEXT_AA)
            if (score > bestScore) {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    /** White or near-black text on a computed call button, whichever reads better. */
    fun callButtonInk(buttonRgb: Int): Int =
        if (contrast(0xFFFFFF, buttonRgb) >= contrast(0x111111, buttonRgb)) 0xFFFFFF else 0x111111

    /** Parse "#rrggbb"; null for anything else so callers can fall back rather than crash. */
    fun parseRgb(value: String?): Int? {
        val text = value?.trim().orEmpty()
        if (text.length != 7 || text[0] != '#') return null
        return text.substring(1).toIntOrNull(16)
    }

    fun formatRgb(rgb: Int): String = String.format(java.util.Locale.US, "#%06X", rgb and 0xffffff)

    internal fun rgbToHsl(rgb: Int): DoubleArray {
        val red = (rgb ushr 16 and 0xff) / 255.0
        val green = (rgb ushr 8 and 0xff) / 255.0
        val blue = (rgb and 0xff) / 255.0
        val max = maxOf(red, green, blue)
        val min = minOf(red, green, blue)
        val lightness = (max + min) / 2.0
        if (max == min) return doubleArrayOf(0.0, 0.0, lightness)
        val delta = max - min
        val saturation = if (lightness > 0.5) delta / (2.0 - max - min) else delta / (max + min)
        val hue = when (max) {
            red -> ((green - blue) / delta + if (green < blue) 6.0 else 0.0)
            green -> (blue - red) / delta + 2.0
            else -> (red - green) / delta + 4.0
        } * 60.0
        return doubleArrayOf(hue, saturation, lightness)
    }

    internal fun hslToRgb(hue: Double, saturation: Double, lightness: Double): Int {
        val s = saturation.coerceIn(0.0, 1.0)
        val l = lightness.coerceIn(0.0, 1.0)
        if (s == 0.0) {
            val grey = (l * 255.0 + 0.5).toInt().coerceIn(0, 255)
            return (grey shl 16) or (grey shl 8) or grey
        }
        val q = if (l < 0.5) l * (1 + s) else l + s - l * s
        val p = 2 * l - q
        val h = ((hue % 360.0) + 360.0) % 360.0 / 360.0
        fun component(offset: Double): Int {
            var t = h + offset
            if (t < 0) t += 1.0
            if (t > 1) t -= 1.0
            val value = when {
                t < 1.0 / 6.0 -> p + (q - p) * 6.0 * t
                t < 1.0 / 2.0 -> q
                t < 2.0 / 3.0 -> p + (q - p) * (2.0 / 3.0 - t) * 6.0
                else -> p
            }
            return (value * 255.0 + 0.5).toInt().coerceIn(0, 255)
        }
        return (component(1.0 / 3.0) shl 16) or (component(0.0) shl 8) or component(-1.0 / 3.0)
    }

    const val TEXT_AA = 4.5
    const val UI_AA = 3.0

    // Lightness ladders searched in the preferred direction first.
    private val DARK_FIRST = doubleArrayOf(0.20, 0.15, 0.25, 0.30, 0.10, 0.35, 0.85, 0.90, 0.95)
    private val LIGHT_FIRST = doubleArrayOf(0.85, 0.90, 0.80, 0.95, 0.75, 0.20, 0.15, 0.25, 0.10)
}
