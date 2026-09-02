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

    /** Identifies one prepared backdrop. The picture is identified by its asset hash. */
    fun cacheKey(hash: String, width: Int, height: Int): String = "$hash@${width}x$height"

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

    /** The overlay as an opaque-black alpha byte, which is what Canvas wants. */
    fun overlayAlpha(alpha: Float = DARKEN_ALPHA): Int =
        (alpha.coerceIn(0f, 1f) * 255f).toInt().coerceIn(0, 255)

    // ---------- the prepared bitmap ----------

    private val cache = LinkedHashMap<String, Bitmap>()

    /** The prepared picture when this exact picture and size were already built. */
    fun cached(hash: String, width: Int, height: Int): Bitmap? = synchronized(cache) {
        cache[cacheKey(hash, width, height)]
    }

    /**
     * Decode, scale, darken. Call this off the main thread: it decodes a photograph.
     *
     * Returns null when the bytes are not an image or the size is not real yet, and the caller
     * then leaves the flat ground colour up rather than showing half a backdrop.
     */
    fun build(bytes: ByteArray?, hash: String, width: Int, height: Int): Bitmap? {
        if (bytes == null || bytes.isEmpty() || width <= 0 || height <= 0) return null
        cached(hash, width, height)?.let { return it }
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
            canvas.drawARGB(overlayAlpha(), 0, 0, 0)
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
            cache[cacheKey(hash, width, height)] = prepared
        }
        return prepared
    }

    /** Drop everything, for a theme that has gone away or a shell entering safe mode. */
    fun clear() = synchronized(cache) {
        for (bitmap in cache.values) bitmap.recycle()
        cache.clear()
    }
}
