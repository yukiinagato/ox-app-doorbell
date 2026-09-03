package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Preparing the theme picture for the dashboard: how it is placed, how far it is darkened, and
 * what identifies one prepared copy.
 *
 * The bitmap work needs a device; these are the decisions around it, which are what a wrong
 * backdrop actually comes from -- a stretched picture, a cache that never hits, or an overlay too
 * light to keep the captions readable.
 */
class ThemeBackdropTest {

    // ---------- the cache key ----------

    @Test
    fun onePreparedCopyPerPictureAndSize() {
        assertEquals("abc@800x600/0@65", ThemeBackdrop.cacheKey("abc", 800, 600))
        // A different picture, or either dimension, is a different copy.
        assertNotEquals(
            ThemeBackdrop.cacheKey("abc", 800, 600),
            ThemeBackdrop.cacheKey("def", 800, 600),
        )
        assertNotEquals(
            ThemeBackdrop.cacheKey("abc", 800, 600),
            ThemeBackdrop.cacheKey("abc", 600, 800),
        )
    }

    /**
     * The overlay is composited into the prepared bitmap, so moving it has to prepare the picture
     * again rather than leave the old darkening on screen.
     */
    @Test
    fun aMovedOverlayIsADifferentPreparedCopy() {
        val configured = BackdropOverlay(enabled = true, rgb = 0x000000, opacity = 62)
        val lighter = configured.copy(opacity = 30)
        val tinted = configured.copy(rgb = 0x102030)
        val off = configured.copy(enabled = false)
        val keys = listOf(configured, lighter, tinted, off, BackdropOverlay.LEGACY)
            .map { ThemeBackdrop.cacheKey("abc", 800, 600, it) }
        assertEquals(keys.size, keys.toSet().size)
        // The same overlay is the same copy: an unchanged status document must hit the cache.
        assertEquals(
            ThemeBackdrop.cacheKey("abc", 800, 600, configured),
            ThemeBackdrop.cacheKey("abc", 800, 600, configured.copy()),
        )
    }

    /** The two orientations of one panel, plus a theme change, must all fit. */
    @Test
    fun theCacheHoldsAPanelsRealWorkingSet() {
        assertTrue(ThemeBackdrop.CACHE_LIMIT >= 4)
    }

    // ---------- placement ----------

    @Test
    fun aPictureOfTheSameShapeFillsTheViewExactly() {
        val rect = ThemeBackdrop.fillRect(1600, 1200, 800, 600)
        assertEquals(0, rect.left)
        assertEquals(0, rect.top)
        assertEquals(800, rect.width)
        assertEquals(600, rect.height)
    }

    /**
     * Aspect fill, never letterbox: the picture covers the whole view and the overflow is
     * centred. A landscape photograph on a portrait phone overflows left and right.
     */
    @Test
    fun aWidePictureOnATallViewOverflowsSidewaysAndStaysCentred() {
        val rect = ThemeBackdrop.fillRect(1600, 900, 400, 800)
        assertTrue("must cover the width", rect.width >= 400)
        assertEquals("must cover the height exactly", 800, rect.height)
        // Centred: the two overhangs match.
        assertEquals(rect.left, 400 - rect.right)
        assertTrue("overflows to the left", rect.left < 0)
    }

    @Test
    fun aTallPictureOnAWideViewOverflowsVerticallyAndStaysCentred() {
        val rect = ThemeBackdrop.fillRect(900, 1600, 800, 400)
        assertEquals("must cover the width exactly", 800, rect.width)
        assertTrue("must cover the height", rect.height >= 400)
        assertEquals(rect.top, 400 - rect.bottom)
        assertTrue("overflows above", rect.top < 0)
    }

    @Test
    fun theAspectRatioIsNeverDistorted() {
        val rect = ThemeBackdrop.fillRect(1600, 900, 400, 800)
        val source = 1600.0 / 900.0
        val drawn = rect.width.toDouble() / rect.height.toDouble()
        assertEquals(source, drawn, 0.01)
    }

    @Test
    fun aDegenerateSizeIsNotACrash() {
        val rect = ThemeBackdrop.fillRect(0, 0, 800, 600)
        assertEquals(800, rect.width)
        assertEquals(600, rect.height)
        assertEquals(0, ThemeBackdrop.fillRect(100, 100, 0, 0).width)
        assertEquals(0, ThemeBackdrop.fillRect(100, 100, -5, -5).width)
    }

    // ---------- the darkening ----------

    /** Spec §5.1 asks for 55-65 %, so cards and captions keep their contrast over any picture. */
    @Test
    fun theOverlayIsWithinTheSpecifiedRange() {
        assertTrue(ThemeBackdrop.DARKEN_ALPHA >= 0.55f)
        assertTrue(ThemeBackdrop.DARKEN_ALPHA <= 0.65f)
    }

    @Test
    fun theOverlayIsAnOpaqueBlackAlphaByte() {
        assertEquals(153, ThemeBackdrop.overlayAlpha(0.60f))
        assertEquals(0, ThemeBackdrop.overlayAlpha(0f))
        assertEquals(255, ThemeBackdrop.overlayAlpha(1f))
        // Out of range values are clamped rather than producing a broken paint.
        assertEquals(255, ThemeBackdrop.overlayAlpha(4f))
        assertEquals(0, ThemeBackdrop.overlayAlpha(-1f))
    }

    @Test
    fun darkeningScalesEachChannelTowardsBlack() {
        // White under a 60 % black overlay keeps 40 % of each channel.
        assertEquals(0x666666, ThemeBackdrop.darken(0xFFFFFF, 0.60f))
        // ...and under the 65 % the dashboard uses, 35 %.
        assertEquals(0x5A5A5A, ThemeBackdrop.darken(0xFFFFFF, 0.65f))
        assertEquals(0x000000, ThemeBackdrop.darken(0x000000, 0.60f))
        assertEquals(0xFFFFFF, ThemeBackdrop.darken(0xFFFFFF, 0f))
        assertEquals(0x000000, ThemeBackdrop.darken(0xFFFFFF, 1f))
    }

    /**
     * The point of the overlay: a white wallpaper has to end up dark enough for the light ink the
     * dark palette uses to clear 4.5:1, which is what made a flat ground necessary before.
     */
    @Test
    fun aWhitePictureBecomesDarkEnoughForLightInk() {
        val darkened = ThemeBackdrop.darken(0xFFFFFF)
        assertTrue(
            "light ink must clear 4.5:1 over the darkened picture",
            UiContrast.contrast(0xFFFFFF, darkened) >= 4.5,
        )
    }

    @Test
    fun aBrightPhotographIsDarkenedTowardsTheSameFloor() {
        for (bright in listOf(0xFFFFFF, 0xF0E8D8, 0xE0F0FF, 0xFFF4C0)) {
            val darkened = ThemeBackdrop.darken(bright)
            assertTrue(
                "still too light: ${Integer.toHexString(darkened)}",
                UiContrast.luminance(darkened) < UiContrast.luminance(bright),
            )
            assertTrue(UiContrast.contrast(0xFFFFFF, darkened) >= 4.5)
        }
    }
}
