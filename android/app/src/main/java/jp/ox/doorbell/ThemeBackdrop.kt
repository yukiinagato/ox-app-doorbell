// The theme picture as it is actually drawn behind a screen (spec §5.1).
//
// A wallpaper behind text is unreadable however the ink is chosen, and decoding a full-size
// photograph on every layout is not affordable on the devices this ships to. So the backdrop is
// prepared once per (picture, view size): decoded off the main thread, scaled to the view with
// aspect fill, darkened by a fixed black overlay, and kept. The darkened copy is what goes on
// screen *and* what RegionInk samples, so the contrast decision is measured against the pixels a
// resident is actually looking at rather than against the original picture.
//
// The kiosk shell does the same thing for the same reasons; only the overlay differs, because a
// dashboard carries cards and small captions where a door screen carries one large call button.
package jp.ox.doorbell

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import org.json.JSONObject

/**
 * The overlay composited over the theme picture, as an administrator configured it
 * (status.display.theme.backdrop, from the cluster keys display.theme.backdrop.* or this device's
 * devices.<id>.local.theme.backdrop.*; core resolves which layer wins and publishes the answer).
 *
 * The overlay is what makes the clock, the call list and the footer read over a bright wallpaper,
 * so an administrator who turns it off or lightens it is taking that legibility on deliberately.
 * The shell renders what it is told and does not second-guess the value.
 */
internal data class BackdropOverlay(
    val enabled: Boolean,
    /** The overlay colour as 0xRRGGBB. */
    val rgb: Int,
    /** How much of that colour is composited over the picture, as a percentage. */
    val opacity: Int,
) {

    /**
     * What Canvas composites with. This goes through the same float path the fixed overlay always
     * used, so a cluster that never configures a backdrop keeps exactly the pixels it had.
     */
    val alphaByte: Int get() = ThemeBackdrop.overlayAlpha(opacity / 100f)

    /** True when there is nothing to composite and the picture is drawn as it arrived. */
    val transparent: Boolean get() = !enabled || alphaByte == 0

    /**
     * Identifies this overlay in a prepared backdrop's cache key. The overlay is baked into the
     * bitmap, so a changed colour or opacity has to miss the cache and prepare the picture again.
     */
    val cacheTag: String get() =
        if (!enabled) "off" else Integer.toHexString(rgb and 0xFFFFFF) + "@" + opacity

    companion object {

        /** Core's defaults, applied to whatever a published backdrop document leaves out. */
        const val DEFAULT_RGB = 0x000000
        const val DEFAULT_OPACITY = 62

        /**
         * What a core that does not publish the field gets: the fixed overlay this dashboard has
         * always drawn. It is deliberately not core's default -- an existing cluster upgrading to
         * a shell that understands the field must not have its wallpaper visibly re-darkened
         * before an administrator has chosen anything.
         */
        val LEGACY = BackdropOverlay(
            enabled = true,
            rgb = DEFAULT_RGB,
            opacity = Math.round(ThemeBackdrop.DARKEN_ALPHA * 100f),
        )

        /** Parse status.display.theme.backdrop. Null means an older core published none. */
        fun parse(backdrop: JSONObject?): BackdropOverlay? {
            if (backdrop == null) return null
            return BackdropOverlay(
                enabled = backdrop.optBoolean("enabled", true),
                rgb = UiContrast.parseRgb(backdrop.optString("color")) ?: DEFAULT_RGB,
                // Anything outside 0..100 is not a percentage; clamp rather than refuse to draw.
                opacity = backdrop.optInt("opacity", DEFAULT_OPACITY).coerceIn(0, 100),
            )
        }
    }
}

/** Where the source picture lands inside the view, in view pixels. */
internal data class BackdropRect(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width: Int get() = right - left
    val height: Int get() = bottom - top
}

internal object ThemeBackdrop {

    /**
     * How far the picture is darkened, at the top of the 55-65 % §5.1 allows.
     *
     * The dashboard is the text-heaviest screen in the product -- a clock, a call list, a footer
     * and two headings all sit straight on the backdrop rather than on a card -- so it takes the
     * strongest overlay in the range. Measured on the Moto against the cluster's own wallpaper,
     * 60 % still left the brightest patches at 4.0:1 against white ink, under the 4.5 floor.
     */
    const val DARKEN_ALPHA = 0.65f

    /** A panel has one picture and at most two orientations; more than this is a leak. */
    const val CACHE_LIMIT = 4

    /**
     * Identifies one prepared backdrop. The picture is identified by its asset hash, and the
     * overlay is part of the identity because it is composited into the bitmap that gets cached.
     */
    fun cacheKey(
        hash: String,
        width: Int,
        height: Int,
        overlay: BackdropOverlay = BackdropOverlay.LEGACY,
    ): String = "$hash@${width}x$height/${overlay.cacheTag}"

    /**
     * Aspect fill: cover the view entirely and centre the overflow, so a picture is never
     * letterboxed onto the ground colour and never stretched out of proportion.
     */
    fun fillRect(sourceWidth: Int, sourceHeight: Int, width: Int, height: Int): BackdropRect {
        if (sourceWidth <= 0 || sourceHeight <= 0 || width <= 0 || height <= 0)
            return BackdropRect(0, 0, width.coerceAtLeast(0), height.coerceAtLeast(0))
        // Scale by whichever axis needs the most magnification; the other one overflows.
        val scale = maxOf(
            width.toDouble() / sourceWidth.toDouble(),
            height.toDouble() / sourceHeight.toDouble(),
        )
        val drawnWidth = Math.round(sourceWidth * scale).toInt().coerceAtLeast(1)
        val drawnHeight = Math.round(sourceHeight * scale).toInt().coerceAtLeast(1)
        val left = (width - drawnWidth) / 2
        val top = (height - drawnHeight) / 2
        return BackdropRect(left, top, left + drawnWidth, top + drawnHeight)
    }

    /**
     * One colour under the same overlay the backdrop gets, for describing it without a bitmap.
     *
     * Computed from the integer alpha the canvas actually composites with, and rounded the same
     * way, so this answer matches the pixels rather than approximating them.
     */
    fun darken(rgb: Int, alpha: Float = DARKEN_ALPHA): Int {
        val keep = (255 - overlayAlpha(alpha)) / 255.0
        val r = Math.round((rgb ushr 16 and 0xff) * keep).toInt().coerceIn(0, 255)
        val g = Math.round((rgb ushr 8 and 0xff) * keep).toInt().coerceIn(0, 255)
        val b = Math.round((rgb and 0xff) * keep).toInt().coerceIn(0, 255)
        return (r shl 16) or (g shl 8) or b
    }

    /**
     * One colour as it appears under [overlay], composited the same way the bitmap is.
     *
     * This is what a region's background actually looks like when the shell could not sample it:
     * core averages the picture as uploaded, and the overlay is applied afterwards, so choosing
     * ink against core's average alone reads a bright wallpaper that is not what is on screen.
     */
    fun under(rgb: Int, overlay: BackdropOverlay): Int {
        if (overlay.transparent) return rgb and 0xFFFFFF
        val over = overlay.alphaByte / 255.0
        val keep = 1.0 - over
        fun mix(shift: Int): Int {
            val base = (rgb ushr shift) and 0xff
            val paint = (overlay.rgb ushr shift) and 0xff
            return Math.round(base * keep + paint * over).toInt().coerceIn(0, 255)
        }
        return (mix(16) shl 16) or (mix(8) shl 8) or mix(0)
    }

    /** The overlay as an opaque-black alpha byte, which is what Canvas wants. */
    fun overlayAlpha(alpha: Float = DARKEN_ALPHA): Int =
        (alpha.coerceIn(0f, 1f) * 255f).toInt().coerceIn(0, 255)

    // ---------- the prepared bitmap ----------

    private val cache = LinkedHashMap<String, Bitmap>()

    /** The prepared picture when this exact picture, size and overlay were already built. */
    fun cached(
        hash: String,
        width: Int,
        height: Int,
        overlay: BackdropOverlay = BackdropOverlay.LEGACY,
    ): Bitmap? = synchronized(cache) {
        cache[cacheKey(hash, width, height, overlay)]
    }

    /**
     * Decode, scale, darken. Call this off the main thread: it decodes a photograph.
     *
     * Returns null when the bytes are not an image or the size is not real yet, and the caller
     * then leaves the flat ground colour up rather than showing half a backdrop.
     */
    fun build(
        bytes: ByteArray?,
        hash: String,
        width: Int,
        height: Int,
        overlay: BackdropOverlay = BackdropOverlay.LEGACY,
    ): Bitmap? {
        if (bytes == null || bytes.isEmpty() || width <= 0 || height <= 0) return null
        cached(hash, width, height, overlay)?.let { return it }
        // Decode no larger than the view: a 12 MP upload would otherwise be held at full size
        // just to be drawn into a few hundred thousand pixels.
        val source = BoundedBitmapDecoder.decode(bytes, width, height) ?: return null
        val prepared = try {
            // RGB_565 halves the texture and the backdrop has no transparency to preserve.
            val out = Bitmap.createBitmap(width, height, Bitmap.Config.RGB_565)
            val canvas = Canvas(out)
            canvas.drawColor(Color.BLACK)
            val fill = fillRect(source.width, source.height, width, height)
            canvas.drawBitmap(
                source,
                Rect(0, 0, source.width, source.height),
                Rect(fill.left, fill.top, fill.right, fill.bottom),
                null,
            )
            // A disabled or fully transparent overlay leaves the picture exactly as it arrived.
            if (!overlay.transparent) canvas.drawARGB(
                overlay.alphaByte,
                overlay.rgb ushr 16 and 0xff,
                overlay.rgb ushr 8 and 0xff,
                overlay.rgb and 0xff,
            )
            out
        } catch (_: Exception) {
            null
        } catch (_: OutOfMemoryError) {
            null
        } finally {
            source.recycle()
        }
        if (prepared == null) return null
        synchronized(cache) {
            if (cache.size >= CACHE_LIMIT) {
                // Oldest first; a rotation pair plus one theme change is the realistic working set.
                val oldest = cache.keys.firstOrNull()
                if (oldest != null) cache.remove(oldest)?.recycle()
            }
            cache[cacheKey(hash, width, height, overlay)] = prepared
        }
        return prepared
    }

    /** Drop everything, for a theme that has gone away or a shell entering safe mode. */
    fun clear() = synchronized(cache) {
        for (bitmap in cache.values) bitmap.recycle()
        cache.clear()
    }
}
