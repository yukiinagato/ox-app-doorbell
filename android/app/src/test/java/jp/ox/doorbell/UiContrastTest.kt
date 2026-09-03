package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UiContrastTest {

    @Test
    fun luminanceMatchesTheWcagReferenceValues() {
        assertEquals(0.0, UiContrast.luminance(0x000000), 1e-9)
        assertEquals(1.0, UiContrast.luminance(0xFFFFFF), 1e-9)
        // Pure sRGB primaries carry the documented coefficients on linearised channels.
        assertEquals(0.2126, UiContrast.luminance(0xFF0000), 1e-4)
        assertEquals(0.7152, UiContrast.luminance(0x00FF00), 1e-4)
        assertEquals(0.0722, UiContrast.luminance(0x0000FF), 1e-4)
    }

    @Test
    fun contrastIsSymmetricAndBoundedByBlackOnWhite() {
        assertEquals(21.0, UiContrast.contrast(0x000000, 0xFFFFFF), 1e-6)
        assertEquals(
            UiContrast.contrast(0x1E6FB8, 0xFFFFFF),
            UiContrast.contrast(0xFFFFFF, 0x1E6FB8),
            1e-9,
        )
        assertEquals(1.0, UiContrast.contrast(0x808080, 0x808080), 1e-9)
    }

    @Test
    fun theInkChosenIsWhicheverActuallyReadsBetter() {
        assertEquals(Ink.DARK, UiContrast.inkFor(0xE9EDF0))
        assertEquals(Ink.DARK, UiContrast.inkFor(0xFFFFFF))
        assertEquals(Ink.LIGHT, UiContrast.inkFor(0x111820))
        assertEquals(Ink.LIGHT, UiContrast.inkFor(0x000000))
    }

    @Test
    fun aMidToneBackgroundTakesDarkInkBecauseContrastIsNotLinearInLuminance() {
        // The Moto wallpaper. Y = 0.494 sits just under a naive 0.5 midpoint, but the light ink
        // manages only about 1.8:1 there while the dark ink gives about 9.4:1.
        val wallpaper = 0xBBBBB4
        assertTrue(UiContrast.luminance(wallpaper) < 0.5)
        assertEquals(Ink.DARK, UiContrast.inkFor(wallpaper))
        assertTrue(UiContrast.contrast(Palette.DARK_INK, wallpaper) > 9.0)
        assertTrue(UiContrast.contrast(Palette.LIGHT_INK, wallpaper) < 2.0)
    }

    @Test
    fun aGenuinelyDarkMidToneStillTakesLightInk() {
        val charcoal = 0x404040
        assertEquals(Ink.LIGHT, UiContrast.inkFor(charcoal))
        assertTrue(UiContrast.contrast(Palette.LIGHT_INK, charcoal) > 9.0)
    }

    @Test
    fun theInkCrossoverSitsWellBelowTheLuminanceMidpoint() {
        val crossover = UiContrast.inkCrossoverLuminance(Palette.LIGHT_INK, Palette.DARK_INK)
        assertTrue("crossover was $crossover", crossover in 0.15..0.22)
        // Either side of it the choice flips, and nowhere near 0.5.
        assertEquals(Ink.LIGHT, UiContrast.inkFor(luminanceGrey(crossover - 0.05)))
        assertEquals(Ink.DARK, UiContrast.inkFor(luminanceGrey(crossover + 0.05)))
    }

    /** The neutral grey whose relative luminance is approximately [target]. */
    private fun luminanceGrey(target: Double): Int {
        var best = 0
        var bestError = Double.MAX_VALUE
        for (value in 0..255) {
            val grey = (value shl 16) or (value shl 8) or value
            val error = Math.abs(UiContrast.luminance(grey) - target)
            if (error < bestError) {
                bestError = error
                best = grey
            }
        }
        return best
    }

    @Test
    fun averagingAnImageRegionIgnoresFullyTransparentPixels() {
        val pixels = intArrayOf(
            0xFF000000.toInt(), 0xFFFFFFFF.toInt(), 0x00FF0000,
        )
        // Black and white average to mid grey; the transparent red pixel does not count.
        assertEquals(0x7F7F7F, UiContrast.averageRgb(pixels))
        assertEquals(0, UiContrast.averageRgb(intArrayOf(0x00000000)))
    }

    @Test
    fun oppositeImagesProduceOppositeInks() {
        val lightImage = IntArray(16 * 16) { 0xFFE2E8EE.toInt() }
        val darkImage = IntArray(16 * 16) { 0xFF17202A.toInt() }
        assertEquals(Ink.DARK, UiContrast.inkFor(UiContrast.averageRgb(lightImage)))
        assertEquals(Ink.LIGHT, UiContrast.inkFor(UiContrast.averageRgb(darkImage)))
    }

    @Test
    fun theTextShadowIsAddedOnlyWhenTheChosenInkFallsShort() {
        // Light ink over mid grey is legible enough on its own only above 4.5:1.
        assertTrue(UiContrast.needsTextShadow(Palette.LIGHT_INK, 0x8A8A8A))
        assertTrue(!UiContrast.needsTextShadow(Palette.LIGHT_INK, 0x101418))
        assertTrue(!UiContrast.needsTextShadow(Palette.DARK_INK, 0xFFFFFF))
    }

    @Test
    fun theAutomaticCallButtonSeparatesFromTheBackgroundAndCarriesReadableText() {
        for (background in listOf(0x9BD748, 0xFFFFFF, 0x101418, 0x1E6FB8, 0x808080)) {
            val button = UiContrast.autoAccent(background)
            val ink = UiContrast.callButtonInk(button)
            assertTrue(
                "button separation on ${UiContrast.formatRgb(background)}",
                UiContrast.contrast(button, background) >= UiContrast.UI_AA,
            )
            assertTrue(
                "button text on ${UiContrast.formatRgb(background)}",
                UiContrast.contrast(ink, button) >= UiContrast.TEXT_AA,
            )
        }
    }

    @Test
    fun theAutomaticCallButtonGoesDarkOnALightBackground() {
        val button = UiContrast.autoAccent(0x9BD748)
        assertTrue(UiContrast.luminance(button) < UiContrast.luminance(0x9BD748))
        assertEquals(0xFFFFFF, UiContrast.callButtonInk(button))
    }

    @Test
    fun hueRotatesByHalfTheWheel() {
        val background = 0x9BD748
        val button = UiContrast.autoAccent(background)
        val backgroundHue = UiContrast.rgbToHsl(background)[0]
        val buttonHue = UiContrast.rgbToHsl(button)[0]
        val delta = Math.abs(((buttonHue - backgroundHue) % 360.0 + 360.0) % 360.0 - 180.0)
        assertTrue("hue delta was $delta", delta < 8.0)
    }

    @Test
    fun colourParsingAcceptsOnlySixDigitHex() {
        assertEquals(0x1E6FB8, UiContrast.parseRgb("#1E6FB8"))
        assertEquals(0x1E6FB8, UiContrast.parseRgb(" #1e6fb8 "))
        assertNull(UiContrast.parseRgb("#1E6FB"))
        assertNull(UiContrast.parseRgb("1E6FB8"))
        assertNull(UiContrast.parseRgb(null))
        assertEquals("#1E6FB8", UiContrast.formatRgb(0x1E6FB8))
    }

    @Test
    fun theAdvisoryRatioIsRenderedWithOneDecimal() {
        assertEquals("21.0", UiContrast.ratioText(UiContrast.contrast(0x000000, 0xFFFFFF)))
        assertEquals("3.1", UiContrast.ratioText(3.14))
    }
}
