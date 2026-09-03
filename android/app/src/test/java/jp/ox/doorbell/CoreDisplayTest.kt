package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The appearance and automatic-theme decisions core publishes, and the shell's fallback for a core
 * that publishes none of them.
 */
class CoreDisplayTest {

    private val published = JSONObject(
        """
        {"brightness":80,"night":false,"red_tint":false,
         "appearance":{"configured":"auto_schedule","effective":"dark","follow_system":false,
                       "schedule":{"dark_from":"19:00","light_from":"06:30"}},
         "theme":{"bg_color":"#9BD748","bg_image":null,"bg_image_path":null,
                  "auto_background":{"color":"#9BD748","source":"color"},
                  "auto_ink":{"clock":"dark","date":"dark","status_line":"dark","hint":"dark",
                              "tile_label":"dark","footer":"dark","notice":"dark"},
                  "auto_accent":{"call_button":"#391142","call_button_ink":"light"},
                  "ink_override":{"footer":"#123456"},
                  "call_button_bg":"#391142","call_button_ink":"light"}}
        """.trimIndent(),
    )

    @Test
    fun theAppearanceCoreResolvedIsUsedDirectly() {
        val appearance = CoreDisplays.parse(published).appearance!!
        assertEquals("auto_schedule", appearance.configured)
        assertEquals("dark", appearance.effective)
        assertFalse(appearance.followSystem)
        assertEquals("19:00", appearance.darkFrom)
        assertEquals("06:30", appearance.lightFrom)
        // The schedule is core's to resolve, so the platform setting is ignored here.
        assertTrue(CoreDisplays.isDark(appearance, systemDark = false))
        assertTrue(CoreDisplays.isDark(appearance, systemDark = null))
    }

    @Test
    fun autoSystemConsultsThePlatformAndFallsBackToCoresAnswer() {
        val appearance = CoreAppearance("auto_system", "dark", true, "19:00", "06:30")
        assertFalse(CoreDisplays.isDark(appearance, systemDark = false))
        assertTrue(CoreDisplays.isDark(appearance, systemDark = true))
        // Android before 10 has no system setting; core's resolved answer stands in.
        assertTrue(CoreDisplays.isDark(appearance, systemDark = null))
    }

    @Test
    fun theAutomaticInkIsTakenPerRegionAndAnOverrideWins() {
        val theme = CoreDisplays.parse(published).theme!!
        assertEquals(0x9BD748, theme.backgroundRgb)
        assertEquals("color", theme.backgroundSource)
        assertEquals(Palette.DARK_INK, CoreDisplays.inkFor(theme, "clock", 0x000000).inkRgb)
        // ink_override is an explicit colour and beats the automatic decision.
        assertEquals(0x123456, CoreDisplays.inkFor(theme, "footer", 0x000000).inkRgb)
    }

    @Test
    fun everyPublishedRegionIsRead() {
        val theme = CoreDisplays.parse(published).theme!!
        for (region in CoreDisplays.INK_REGIONS)
            assertTrue("missing region $region", theme.ink.containsKey(region))
    }

    @Test
    fun theCallButtonAndItsTextComeFromCoreRatherThanBeingRederived() {
        val theme = CoreDisplays.parse(published).theme!!
        val (background, ink) = CoreDisplays.callButton(theme, 0x000000)
        assertEquals(0x391142, background)
        assertEquals(0xFFFFFF, ink)
    }

    @Test
    fun aDarkButtonInkTokenIsHonouredEvenWhereWhiteWouldScoreHigher() {
        val theme = CoreTheme(
            backgroundRgb = 0x808080, backgroundSource = "color",
            backgroundUnsampledReason = "", backgroundImage = "", backdrop = null,
            ink = emptyMap(),
            inkOverride = emptyMap(), callButtonBg = 0xE8E8E8, callButtonInkLight = false,
        )
        // Core returns the best compromise on a mid-luminance background; never second-guess it.
        assertEquals(0xE8E8E8 to 0x111111, CoreDisplays.callButton(theme, 0x000000))
    }

    @Test
    fun anOlderCorePublishesNothingAndTheShellComputesTheSameRuleLocally() {
        val empty = CoreDisplays.parse(null)
        assertNull(empty.appearance)
        assertNull(empty.theme)
        assertNull(CoreDisplays.parse(JSONObject("""{"brightness":80}""")).appearance)
        assertNull(CoreDisplays.parse(JSONObject("""{"brightness":80}""")).theme)
        // Local fallback: a light ground takes dark ink and the button is the computed accent.
        assertEquals(Palette.DARK_INK, CoreDisplays.inkFor(null, "clock", 0xEEF1F4).inkRgb)
        assertEquals(Palette.LIGHT_INK, CoreDisplays.inkFor(null, "clock", 0x0F1418).inkRgb)
        val (background, ink) = CoreDisplays.callButton(null, 0x9BD748)
        assertEquals(UiContrast.autoAccent(0x9BD748), background)
        assertEquals(UiContrast.callButtonInk(background), ink)
    }

    @Test
    fun aThemeWithoutTheAutomaticBlockStillYieldsItsBackgroundColour() {
        val display = JSONObject(
            """{"theme":{"bg_color":"#101418","auto_ink":{"clock":"light"}}}""",
        )
        val theme = CoreDisplays.parse(display).theme!!
        assertEquals(0x101418, theme.backgroundRgb)
        assertEquals(Palette.LIGHT_INK, CoreDisplays.inkFor(theme, "clock", 0xFFFFFF).inkRgb)
        // A region core said nothing about is decided locally against the same background.
        assertEquals(Palette.LIGHT_INK, CoreDisplays.inkFor(theme, "hint", 0xFFFFFF).inkRgb)
    }

    @Test
    fun anImageBackedThemeLetsTheShellRefineCoresWholeImageAverage() {
        val display = JSONObject(
            """
            {"theme":{"bg_color":"#101418","bg_image":"abc",
                      "auto_background":{"color":"#7A7A7A","source":"image"},
                      "auto_ink":{"clock":"light","footer":"light"}}}
            """.trimIndent(),
        )
        val theme = CoreDisplays.parse(display).theme!!
        assertTrue(theme.hasBackgroundImage)
        assertTrue(theme.imageSampledByCore)
        // A region the shell measured wins: this footer sits on the light part of the picture.
        assertEquals(
            Palette.DARK_INK,
            CoreDisplays.inkFor(theme, "footer", 0x101418, 0xE9EDF0, imageDrawnLocally = true)
                .inkRgb,
        )
        // Core's average is the fallback only for a region that could not be measured.
        assertEquals(
            Palette.LIGHT_INK,
            CoreDisplays.inkFor(theme, "footer", 0x101418, null, imageDrawnLocally = true).inkRgb,
        )
    }

    @Test
    fun aPictureCoreDeclinedToSampleIsNotMistakenForAFlatColour() {
        // The observed failure: core capped decoding at 4 MP and reported source "color" for a
        // 5.7 MP JPEG. bg_image is the signal, so the shell samples anyway and gets it right.
        val old = CoreDisplays.parse(
            JSONObject(
                """{"theme":{"bg_color":"#101418","bg_image":"big",
                             "auto_background":{"color":"#101418","source":"color"},
                             "auto_ink":{"footer":"light"}}}""",
            ),
        ).theme!!
        assertTrue(old.hasBackgroundImage)
        assertFalse(old.imageSampledByCore)
        assertEquals(
            BackgroundKind.IMAGE_DRAWN,
            CoreDisplays.backgroundKind(old, imageDrawnLocally = true),
        )
        assertEquals(
            Palette.DARK_INK,
            CoreDisplays.inkFor(old, "footer", 0x101418, 0xE9EDF0, imageDrawnLocally = true).inkRgb,
        )

        // The newer core says so explicitly, with a reason; the decision is the same.
        val fresh = CoreDisplays.parse(
            JSONObject(
                """{"theme":{"bg_color":"#101418","bg_image":"big",
                             "auto_background":{"color":"#101418","source":"image_unsampled",
                                                "reason":"too_many_pixels"},
                             "auto_ink":{"footer":"light"}}}""",
            ),
        ).theme!!
        assertEquals("image_unsampled", fresh.backgroundSource)
        assertEquals("too_many_pixels", fresh.backgroundUnsampledReason)
        assertFalse(fresh.imageSampledByCore)
        assertEquals(
            Palette.DARK_INK,
            CoreDisplays.inkFor(fresh, "footer", 0x101418, 0xE9EDF0, imageDrawnLocally = true)
                .inkRgb,
        )
    }

    @Test
    fun aThemeWithNoPictureIsAFlatColourWhateverSourceSays() {
        val theme = CoreDisplays.parse(
            JSONObject(
                """{"theme":{"bg_color":"#EEF1F4","bg_image":null,
                             "auto_background":{"color":"#EEF1F4","source":"color"},
                             "auto_ink":{"clock":"dark"}}}""",
            ),
        ).theme!!
        assertFalse(theme.hasBackgroundImage)
        assertEquals(
            BackgroundKind.FLAT_COLOUR,
            CoreDisplays.backgroundKind(theme, imageDrawnLocally = false),
        )
        assertEquals(Palette.DARK_INK, CoreDisplays.inkFor(theme, "clock", 0xEEF1F4).inkRgb)
    }

    @Test
    fun aPictureConfiguredButNotDrawnYetIsItsOwnCase() {
        val theme = CoreDisplays.parse(
            JSONObject(
                """{"theme":{"bg_color":"#EEF1F4","bg_image":"pending",
                             "auto_background":{"color":"#101418","source":"image"},
                             "auto_ink":{"clock":"light"}}}""",
            ),
        ).theme!!
        assertEquals(
            BackgroundKind.IMAGE_NOT_DRAWN,
            CoreDisplays.backgroundKind(theme, imageDrawnLocally = false),
        )
        // The light ground is what a visitor sees until the picture loads, so dark ink.
        assertEquals(Palette.DARK_INK, CoreDisplays.inkFor(theme, "clock", 0xEEF1F4).inkRgb)
    }

    @Test
    fun aColourBackedThemeIsNotSecondGuessedByASample() {
        val theme = CoreDisplays.parse(published).theme!!
        assertEquals("color", theme.backgroundSource)
        assertFalse(theme.hasBackgroundImage)
        // No picture, so core's per-region answer stands even though a sample was offered.
        assertEquals(
            Palette.DARK_INK,
            CoreDisplays.inkFor(theme, "clock", 0, sampledBackgroundRgb = 0x000000).inkRgb,
        )
    }

    @Test
    fun anAppearanceWithoutAnEffectiveValueIsIgnored() {
        val display = JSONObject("""{"appearance":{"configured":"dark"}}""")
        assertNull(CoreDisplays.parse(display).appearance)
    }
}
