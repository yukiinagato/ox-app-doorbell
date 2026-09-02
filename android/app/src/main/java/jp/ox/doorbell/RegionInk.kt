// Per-region automatic ink for text drawn straight onto the theme background (spec §5).
//
// Core publishes display.theme.auto_ink, but it has no layout geometry: over a background image it
// can only average the whole picture, so one answer is applied to every region. On a photograph
// with a light sky and a dark foreground that single answer is wrong for at least one of them --
// the observed failure was a white footer over the light part of the image.
//
// So the shell refines it where core cannot: it samples the background actually covered by each
// text region, downscales that area to at most 16x16, averages WCAG relative luminance, and picks
// the dark ink at Y >= 0.5 and the light ink below it. The 1 px opposite-ink shadow at 40 % is
// added only when the chosen ink still falls short of 4.5:1.
//
// Precedence: an administrator's ink_override always wins; then, whenever a background image is
// on screen, the local sample; then core's per-region value, which is authoritative only for a
// flat colour.
//
// The signal for "there is a picture" is display.theme.bg_image, never auto_background.source. A
// core that declines to average a large photograph reported source "color" for it, and a shell
// that believed that painted light text onto a light picture -- the observed failure on a 5.7 MP
// JPEG. Core now reports "image_unsampled" with a reason instead, and both spellings are handled
// by simply not consulting source for this decision at all.
package jp.ox.doorbell

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.view.View

/** What to paint one text region with. */
internal data class RegionInkResult(
    val inkRgb: Int,
    /** True when the ink alone misses 4.5:1 and needs the opposite-ink shadow behind it. */
    val needsShadow: Boolean,
) {
    val shadowRgb: Int
        get() = if (inkRgb == Palette.LIGHT_INK) Palette.DARK_INK else Palette.LIGHT_INK
}

/** What is actually behind the text, which decides whose answer is used. */
internal enum class BackgroundKind {
    /** No picture: core's per-region ink has no geometry to be wrong about. */
    FLAT_COLOUR,

    /** A picture is on screen: the local per-region sample decides. */
    IMAGE_DRAWN,

    /** A picture is configured but not yet painted, so the flat colour is what shows. */
    IMAGE_NOT_DRAWN,

    /**
     * The shell painted this region's background itself, so it knows the exact colour and it is
     * not the theme background core measured. The dashboard's cards and ground are this case.
     */
    KNOWN_SURFACE,
}

internal object RegionInkPolicy {

    /** The shadow is drawn at 40 % of the opposite ink, per §5. */
    const val SHADOW_ALPHA = 102

    /**
     * Resolve one region's ink.
     *
     * [override] is the administrator's explicit colour, [coreInkLight] is core's published
     * decision, [background] says which rule applies, and [sampledBackgroundRgb] is what the shell
     * measured under this region, or null when it could not measure.
     */
    fun resolve(
        override: Int?,
        coreInkLight: Boolean?,
        background: BackgroundKind,
        sampledBackgroundRgb: Int?,
        fallbackBackgroundRgb: Int,
    ): RegionInkResult {
        val measured = sampledBackgroundRgb ?: fallbackBackgroundRgb
        if (override != null) return RegionInkResult(
            override, UiContrast.needsTextShadow(override, measured),
        )
        val light = when (background) {
            // Nothing local to add: core measured the one colour there is.
            BackgroundKind.FLAT_COLOUR ->
                coreInkLight ?: (UiContrast.inkFor(measured) == Ink.LIGHT)
            // The picture is on screen, so this region's own pixels decide. Core's whole-image
            // answer is only the fallback for a region the shell could not measure.
            BackgroundKind.IMAGE_DRAWN -> if (sampledBackgroundRgb != null)
                UiContrast.inkFor(sampledBackgroundRgb) == Ink.LIGHT
            else coreInkLight ?: (UiContrast.inkFor(measured) == Ink.LIGHT)
            // The picture is not painted yet; core's ink describes it and not what is on screen.
            BackgroundKind.IMAGE_NOT_DRAWN ->
                UiContrast.inkFor(fallbackBackgroundRgb) == Ink.LIGHT
            // A surface the shell painted: its colour is known exactly, and core measured a
            // different background entirely.
            BackgroundKind.KNOWN_SURFACE -> UiContrast.inkFor(measured) == Ink.LIGHT
        }
        val ink = if (light) Palette.LIGHT_INK else Palette.DARK_INK
        val against = if (background == BackgroundKind.IMAGE_NOT_DRAWN) fallbackBackgroundRgb
            else measured
        return RegionInkResult(ink, UiContrast.needsTextShadow(ink, against))
    }
}

internal object RegionInk {

    /** The sampled area is reduced to this square before averaging, as §5 specifies. */
    const val SAMPLE = 16

    /**
     * Average the background actually behind [region], by drawing [background] into a small bitmap
     * through the same transform the region occupies. Returns null when there is nothing to
     * sample, and the caller then falls back to the flat background colour.
     */
    fun sample(background: View?, region: View, groundRgb: Int): Int? {
        if (background == null || background.visibility != View.VISIBLE) return null
        if (background.width <= 0 || background.height <= 0) return null
        if (region.width <= 0 || region.height <= 0) return null

        // The region's bounds in the background view's own coordinates.
        val regionXy = IntArray(2)
        val backgroundXy = IntArray(2)
        region.getLocationInWindow(regionXy)
        background.getLocationInWindow(backgroundXy)
        val left = (regionXy[0] - backgroundXy[0]).toFloat()
        val top = (regionXy[1] - backgroundXy[1]).toFloat()
        val width = region.width.toFloat()
        val height = region.height.toFloat()
        // A region scrolled or laid out entirely off the background tells us nothing.
        if (left + width <= 0f || top + height <= 0f) return null
        if (left >= background.width || top >= background.height) return null

        var bitmap: Bitmap? = null
        return try {
            bitmap = Bitmap.createBitmap(SAMPLE, SAMPLE, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            // The ground shows through wherever the image does not cover the region.
            canvas.drawColor(Color.rgb(groundRgb ushr 16 and 0xff, groundRgb ushr 8 and 0xff,
                                       groundRgb and 0xff))
            canvas.scale(SAMPLE / width, SAMPLE / height)
            canvas.translate(-left, -top)
            background.draw(canvas)
            val pixels = IntArray(SAMPLE * SAMPLE)
            bitmap.getPixels(pixels, 0, SAMPLE, 0, 0, SAMPLE, SAMPLE)
            UiContrast.averageRgb(pixels)
        } catch (_: Exception) {
            null
        } catch (_: OutOfMemoryError) {
            null
        } finally {
            bitmap?.recycle()
        }
    }
}
