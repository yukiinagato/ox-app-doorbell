package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The administrator-configurable darkening over the dashboard's theme picture, as core publishes
 * it at status.display.theme.backdrop.
 *
 * Three cases decide what gets composited: an administrator who configured the overlay, one who
 * turned it off, and a core too old to have the field at all.
 */
class BackdropOverlayTest {

    private fun theme(backdrop: String?): CoreTheme? = CoreDisplays.parseTheme(
        JSONObject(
            """{"theme":{"bg_image":"h1"${if (backdrop == null) "" else ",\"backdrop\":$backdrop"}}}""",
        ),
    )

    // ---------- configured ----------

    @Test
    fun aConfiguredOverlayIsCompositedAsPublished() {
        val overlay = BackdropOverlay.parse(
            JSONObject("""{"enabled":true,"color":"#102030","opacity":40,"source":"cluster"}"""),
        )!!
        assertTrue(overlay.enabled)
        assertEquals(0x102030, overlay.rgb)
        assertEquals(40, overlay.opacity)
        assertFalse(overlay.transparent)
        assertEquals(102, overlay.alphaByte)
    }

    @Test
    fun aConfiguredOverlayReachesTheThemeThroughTheStatusDocument() {
        val backdrop = theme("""{"enabled":true,"color":"#204060","opacity":80}""")?.backdrop
        assertEquals(BackdropOverlay(enabled = true, rgb = 0x204060, opacity = 80), backdrop)
    }

    /** A published document that leaves keys out takes core's documented defaults. */
    @Test
    fun aPartialDocumentTakesTheDocumentedDefaults() {
        val overlay = BackdropOverlay.parse(JSONObject("""{"opacity":25}"""))!!
        assertTrue(overlay.enabled)
        assertEquals(BackdropOverlay.DEFAULT_RGB, overlay.rgb)
        assertEquals(25, overlay.opacity)

        val bare = BackdropOverlay.parse(JSONObject("{}"))!!
        assertEquals(
            BackdropOverlay(
                enabled = true,
                rgb = BackdropOverlay.DEFAULT_RGB,
                opacity = BackdropOverlay.DEFAULT_OPACITY,
            ),
            bare,
        )
    }

    /** An opacity outside 0..100 is not a percentage; clamp rather than refuse to draw. */
    @Test
    fun anOutOfRangeOpacityIsClamped() {
        assertEquals(100, BackdropOverlay.parse(JSONObject("""{"opacity":320}"""))!!.opacity)
        assertEquals(0, BackdropOverlay.parse(JSONObject("""{"opacity":-8}"""))!!.opacity)
    }

    /** A colour the shell cannot read must not black out the wallpaper on a typo. */
    @Test
    fun anUnreadableColourFallsBackToTheDefault() {
        val overlay = BackdropOverlay.parse(JSONObject("""{"color":"not a colour"}"""))!!
        assertEquals(BackdropOverlay.DEFAULT_RGB, overlay.rgb)
    }

    // ---------- disabled ----------

    @Test
    fun aDisabledOverlayCompositesNothing() {
        val overlay = BackdropOverlay.parse(
            JSONObject("""{"enabled":false,"color":"#000000","opacity":62}"""),
        )!!
        assertFalse(overlay.enabled)
        assertTrue(overlay.transparent)
        assertEquals("off", overlay.cacheTag)
    }

    /** Fully transparent is the same picture as disabled, and must not be composited either. */
    @Test
    fun aZeroOpacityOverlayCompositesNothing() {
        val overlay = BackdropOverlay.parse(JSONObject("""{"enabled":true,"opacity":0}"""))!!
        assertEquals(0, overlay.alphaByte)
        assertTrue(overlay.transparent)
    }

    // ---------- absent: an older core ----------

    @Test
    fun anOlderCorePublishesNoOverlayAtAll() {
        assertNull(BackdropOverlay.parse(null))
        assertNull(theme(null)?.backdrop)
    }

    /**
     * The fallback is the overlay this dashboard has always drawn, not core's default for the new
     * keys: a cluster upgrading to a shell that understands the field must not have its wallpaper
     * visibly re-darkened before an administrator has chosen anything.
     */
    @Test
    fun theFallbackKeepsTodaysDarkening() {
        val legacy = BackdropOverlay.LEGACY
        assertTrue(legacy.enabled)
        assertEquals(0x000000, legacy.rgb)
        assertEquals(65, legacy.opacity)
        assertEquals(ThemeBackdrop.overlayAlpha(ThemeBackdrop.DARKEN_ALPHA), legacy.alphaByte)
        assertFalse(legacy.transparent)
    }

    // ---------- the ink chosen over the overlay ----------

    /**
     * A bright wallpaper under a heavy overlay takes light ink, because the overlay is what a
     * resident is looking at. Core averages the picture as uploaded (Y ~ 0.7 here, which asks for
     * dark ink); under 62 % black the visible ground is far darker and light ink is the right
     * answer. The shell samples the composited bitmap, and the fallback for a region it could not
     * sample has to composite the same overlay rather than trust core's bare average.
     */
    @Test
    fun aLightRegionUnderTheOverlayTakesLightInk() {
        val bright = 0xD8D4CC
        val overlay = BackdropOverlay(enabled = true, rgb = 0x000000, opacity = 62)
        // The bare picture asks for dark ink; that is the reading that must not be used.
        assertEquals(Ink.DARK, UiContrast.inkFor(bright))
        val visible = ThemeBackdrop.under(bright, overlay)
        assertEquals(Ink.LIGHT, UiContrast.inkFor(visible))

        val theme = CoreDisplays.parseTheme(
            JSONObject(
                """{"theme":{"bg_image":"h1","bg_color":"#D8D4CC",
                    "backdrop":{"enabled":true,"color":"#000000","opacity":62}}}""",
            ),
        )
        val result = CoreDisplays.inkFor(
            theme = theme,
            region = "footer",
            fallbackBackgroundRgb = 0x000000,
            sampledBackgroundRgb = null,
            imageDrawnLocally = true,
        )
        assertEquals(Palette.LIGHT_INK, result.inkRgb)
    }

    /** With the overlay turned off the same wallpaper is bright, and dark ink is right again. */
    @Test
    fun theSameRegionWithNoOverlayTakesDarkInk() {
        val theme = CoreDisplays.parseTheme(
            JSONObject(
                """{"theme":{"bg_image":"h1","bg_color":"#D8D4CC",
                    "backdrop":{"enabled":false}}}""",
            ),
        )
        val result = CoreDisplays.inkFor(
            theme = theme,
            region = "footer",
            fallbackBackgroundRgb = 0x000000,
            sampledBackgroundRgb = null,
            imageDrawnLocally = true,
        )
        assertEquals(Palette.DARK_INK, result.inkRgb)
    }

    /** Compositing matches the bitmap: black at full opacity is black, at zero it is the picture. */
    @Test
    fun compositingAColourUnderTheOverlay() {
        val opaque = BackdropOverlay(enabled = true, rgb = 0x000000, opacity = 100)
        assertEquals(0x000000, ThemeBackdrop.under(0xFFFFFF, opaque))
        val none = BackdropOverlay(enabled = true, rgb = 0x000000, opacity = 0)
        assertEquals(0xFFFFFF, ThemeBackdrop.under(0xFFFFFF, none))
        // A coloured overlay tints rather than only darkens.
        val tint = BackdropOverlay(enabled = true, rgb = 0x0000FF, opacity = 100)
        assertEquals(0x0000FF, ThemeBackdrop.under(0xFFFFFF, tint))
        // The legacy overlay composites exactly what it always did.
        assertEquals(
            ThemeBackdrop.darken(0xFFFFFF),
            ThemeBackdrop.under(0xFFFFFF, BackdropOverlay.LEGACY),
        )
    }

    /** A theme document carrying only a backdrop is still a theme the dashboard has to read. */
    @Test
    fun aBackdropOnlyThemeIsNotDiscarded() {
        val parsed = CoreDisplays.parseTheme(
            JSONObject("""{"theme":{"backdrop":{"enabled":false}}}"""),
        )
        assertEquals(false, parsed?.backdrop?.enabled)
    }
}
