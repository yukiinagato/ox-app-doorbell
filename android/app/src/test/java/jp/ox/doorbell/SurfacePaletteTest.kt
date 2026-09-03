package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Where a surface takes its colour from.
 *
 * Cards, scrim plates, chips and buttons follow status.display.appearance.effective and nothing
 * else. The wallpaper's average colour is allowed to drive exactly two things: the computed
 * call-button accent, and the per-region ink of text drawn straight onto the picture. A pale
 * wallpaper behind a dark cluster must not turn the call list's plate light, because the text on
 * that plate is chosen from the palette and would then be light-on-light.
 */
class SurfacePaletteTest {

    private fun display(effective: String, wallpaperRgb: String): JSONObject = JSONObject(
        """{"appearance":{"configured":"$effective","effective":"$effective"},
            "theme":{"bg_image":"h1","bg_color":"$wallpaperRgb",
                     "auto_background":{"color":"$wallpaperRgb","source":"image"}}}""",
    )

    private fun paletteFor(effective: String, wallpaperRgb: String): Palette {
        val parsed = CoreDisplays.parse(display(effective, wallpaperRgb))
        return Appearance.palette(CoreDisplays.isDark(parsed.appearance!!, null))
    }

    private val lightWallpaper = "#F2EFE8"
    private val darkWallpaper = "#12161A"

    @Test
    fun aDarkClusterKeepsDarkSurfacesOverEitherWallpaper() {
        val overLight = paletteFor("dark", lightWallpaper)
        val overDark = paletteFor("dark", darkWallpaper)
        assertSame(Palette.DARK, overLight)
        assertSame(Palette.DARK, overDark)
        assertEquals(Palette.DARK.surface, overLight.surface)
        assertEquals(Palette.DARK.surfaceAlt, overLight.surfaceAlt)
        assertEquals(Palette.DARK.ink, overLight.ink)
        assertTrue(overLight.dark)
    }

    @Test
    fun aLightClusterKeepsLightSurfacesOverEitherWallpaper() {
        val overLight = paletteFor("light", lightWallpaper)
        val overDark = paletteFor("light", darkWallpaper)
        assertSame(Palette.LIGHT, overLight)
        assertSame(Palette.LIGHT, overDark)
        assertEquals(Palette.LIGHT.surface, overDark.surface)
        assertEquals(Palette.LIGHT.surfaceAlt, overDark.surfaceAlt)
        assertEquals(Palette.LIGHT.ink, overDark.ink)
        assertTrue(!overDark.dark)
    }

    /** The wallpaper cannot move a surface; only the appearance can. */
    @Test
    fun theWallpaperNeverMovesASurface() {
        for (wallpaper in listOf(lightWallpaper, darkWallpaper, "#808080", "#FFFFFF")) {
            assertEquals(Palette.DARK.surface, paletteFor("dark", wallpaper).surface)
            assertEquals(Palette.LIGHT.surface, paletteFor("light", wallpaper).surface)
        }
        assertNotEquals(
            paletteFor("dark", lightWallpaper).surface,
            paletteFor("light", lightWallpaper).surface,
        )
    }

    /**
     * Text on a surface the shell painted takes its ink from that surface, not from the picture:
     * the plate is opaque, so core's average of the wallpaper says nothing about what is behind
     * the words.
     */
    @Test
    fun inkOnAPaintedSurfaceIgnoresTheWallpaper() {
        val theme = CoreDisplays.parse(display("dark", lightWallpaper)).theme
        val onPlate = CoreDisplays.inkFor(
            theme = theme,
            region = "status_line",
            fallbackBackgroundRgb = Palette.DARK.surface,
            sampledBackgroundRgb = null,
            imageDrawnLocally = false,
            knownSurface = true,
        )
        // A dark plate takes light ink however pale the wallpaper behind the window is.
        assertEquals(Palette.LIGHT_INK, onPlate.inkRgb)

        val onLightPlate = CoreDisplays.inkFor(
            theme = CoreDisplays.parse(display("light", darkWallpaper)).theme,
            region = "status_line",
            fallbackBackgroundRgb = Palette.LIGHT.surface,
            sampledBackgroundRgb = null,
            imageDrawnLocally = false,
            knownSurface = true,
        )
        assertEquals(Palette.DARK_INK, onLightPlate.inkRgb)
    }

    /**
     * Text with no plate under it is the one case the wallpaper decides, and it decides from the
     * region's own measured pixels rather than from the appearance. The dashboard's counters are
     * this case: they sit straight on the picture.
     */
    @Test
    fun inkOnTheBarePictureFollowsTheMeasuredRegion() {
        val theme = CoreDisplays.parse(display("dark", lightWallpaper)).theme
        val overBrightPatch = CoreDisplays.inkFor(
            theme = theme,
            region = "status_line",
            fallbackBackgroundRgb = Palette.DARK.ground,
            sampledBackgroundRgb = 0xF6F4F0,
            imageDrawnLocally = true,
        )
        assertEquals(Palette.DARK_INK, overBrightPatch.inkRgb)

        val overDarkPatch = CoreDisplays.inkFor(
            theme = theme,
            region = "status_line",
            fallbackBackgroundRgb = Palette.DARK.ground,
            sampledBackgroundRgb = 0x141A20,
            imageDrawnLocally = true,
        )
        assertEquals(Palette.LIGHT_INK, overDarkPatch.inkRgb)
    }
}
