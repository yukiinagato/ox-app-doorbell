package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Per-region automatic ink (spec §5) and the layout rules that stop the footer colliding with the
 * SOS slider. Both come from a real-device finding on the Moto: a white version line over the
 * light part of a background image, clipped by the slider next to it.
 */
class RegionInkTest {

    private val lightPatch = 0xE9EDF0
    private val darkPatch = 0x17202A

    // ---------- the decision table ----------
    //
    // Rows: administrator override / a picture on screen (local sample) / a picture core averaged
    // / a flat colour / a picture core declined to average. The last row is the observed failure:
    // core reported source "color" for a 5.7 MP JPEG it would not decode, and a shell that
    // believed it painted light text onto a light picture.

    private fun ink(
        override: Int? = null,
        coreInkLight: Boolean? = null,
        background: BackgroundKind,
        sample: Int? = null,
        fallback: Int = 0x808080,
    ) = RegionInkPolicy.resolve(override, coreInkLight, background, sample, fallback)

    @Test
    fun overrideWinsOverEveryOtherRow() {
        for (kind in BackgroundKind.values()) {
            assertEquals(
                "override lost to $kind",
                0xFF0000,
                ink(override = 0xFF0000, coreInkLight = true, background = kind,
                    sample = darkPatch).inkRgb,
            )
        }
    }

    @Test
    fun aPictureOnScreenIsDecidedByTheLocalSample() {
        // Core said light for the whole picture; this region sits on its light part.
        assertEquals(
            Palette.DARK_INK,
            ink(coreInkLight = true, background = BackgroundKind.IMAGE_DRAWN,
                sample = lightPatch).inkRgb,
        )
        assertEquals(
            Palette.LIGHT_INK,
            ink(coreInkLight = false, background = BackgroundKind.IMAGE_DRAWN,
                sample = darkPatch).inkRgb,
        )
    }

    @Test
    fun aPictureCoreAveragedIsStillDecidedLocallyWhereTheShellCanMeasure() {
        // Core sampling the image does not make its one answer right for every region.
        assertEquals(
            Palette.DARK_INK,
            ink(coreInkLight = true, background = BackgroundKind.IMAGE_DRAWN,
                sample = lightPatch).inkRgb,
        )
        // Only a region the shell could not measure falls back to core's average.
        assertEquals(
            Palette.LIGHT_INK,
            ink(coreInkLight = true, background = BackgroundKind.IMAGE_DRAWN,
                sample = null).inkRgb,
        )
    }

    @Test
    fun aFlatColourLeavesCoresAnswerStanding() {
        assertEquals(
            Palette.LIGHT_INK,
            ink(coreInkLight = true, background = BackgroundKind.FLAT_COLOUR,
                fallback = lightPatch).inkRgb,
        )
        // With nothing from core the same rule is applied locally.
        assertEquals(
            Palette.DARK_INK,
            ink(background = BackgroundKind.FLAT_COLOUR, fallback = lightPatch).inkRgb,
        )
    }

    @Test
    fun aPictureCoreDeclinedToSampleIsNeverTrusted() {
        // The Moto failure: core answered "light" for a picture it never decoded. The shell
        // measures the region itself and gets the opposite, correct, answer.
        val result = ink(
            coreInkLight = true, background = BackgroundKind.IMAGE_DRAWN, sample = lightPatch,
        )
        assertEquals(Palette.DARK_INK, result.inkRgb)
    }

    @Test
    fun aPictureConfiguredButNotYetPaintedUsesWhatIsActuallyOnScreen() {
        // Core's ink describes the picture; until it is drawn the flat colour is what shows.
        assertEquals(
            Palette.DARK_INK,
            ink(coreInkLight = true, background = BackgroundKind.IMAGE_NOT_DRAWN,
                fallback = lightPatch).inkRgb,
        )
    }

    @Test
    fun aSurfaceTheShellPaintedIgnoresCoresThemeMeasurement() {
        // The dashboard's cards are not the theme background core measured at all.
        assertEquals(
            Palette.DARK_INK,
            ink(coreInkLight = true, background = BackgroundKind.KNOWN_SURFACE,
                sample = lightPatch).inkRgb,
        )
        assertEquals(
            Palette.LIGHT_INK,
            ink(coreInkLight = false, background = BackgroundKind.KNOWN_SURFACE,
                sample = darkPatch).inkRgb,
        )
    }

    @Test
    fun twoRegionsOnOneImageCanDisagree() {
        fun at(patch: Int) =
            ink(coreInkLight = true, background = BackgroundKind.IMAGE_DRAWN, sample = patch).inkRgb
        assertTrue(at(lightPatch) != at(darkPatch))
    }

    @Test
    fun aPictureArrivingAfterTheFirstLayoutFlipsTheInk() {
        // The exact sequence on the device: the screen binds before the asset is fetched, so the
        // first decision is made against the flat #101418 ground and picks light ink. When the
        // bitmap lands the region is measured for real -- a light wallpaper -- and the ink must
        // flip. A decision taken once at bind time is how light text ended up on a light picture.
        val theme = CoreDisplays.parse(
            org.json.JSONObject(
                """{"theme":{"bg_color":"#101418","bg_image":"asset",
                             "auto_background":{"color":"#101418","source":"color"},
                             "auto_ink":{"footer":"light"}}}""",
            ),
        ).theme!!

        // 1. First layout: configured but not painted yet.
        assertEquals(
            BackgroundKind.IMAGE_NOT_DRAWN,
            CoreDisplays.backgroundKind(theme, imageDrawnLocally = false),
        )
        val beforeImage = CoreDisplays.inkFor(theme, "footer", 0x101418, null, false)
        assertEquals(Palette.LIGHT_INK, beforeImage.inkRgb)

        // 2. The bitmap is painted and the region is sampled: the Moto wallpaper average.
        assertEquals(
            BackgroundKind.IMAGE_DRAWN,
            CoreDisplays.backgroundKind(theme, imageDrawnLocally = true),
        )
        val afterImage = CoreDisplays.inkFor(theme, "footer", 0x101418, 0xBBBBB4, true)
        assertEquals(Palette.DARK_INK, afterImage.inkRgb)
        assertTrue(beforeImage.inkRgb != afterImage.inkRgb)
    }

    @Test
    fun everyVisitorRegionFlipsTogetherWhenThePictureLands() {
        // All four regions the visitor screen draws straight onto the background.
        for (region in listOf("clock", "date", "hint", "footer")) {
            val before = CoreDisplays.inkFor(null, region, 0x101418, null, false)
            val after = CoreDisplays.inkFor(null, region, 0x101418, 0xBBBBB4, true)
            assertEquals("$region before", Palette.LIGHT_INK, before.inkRgb)
            assertEquals("$region after", Palette.DARK_INK, after.inkRgb)
        }
    }

    // ---------- the shadow ----------

    @Test
    fun theShadowIsAddedOnlyWhenEvenTheBetterInkMissesTheTextRatio() {
        // Only a narrow band around the crossover defeats both tokens; #787878 is its worst
        // point, where the best either can manage is about 4.1:1.
        val crossoverGrey = ink(background = BackgroundKind.FLAT_COLOUR, fallback = 0x787878)
        assertTrue(crossoverGrey.needsShadow)
        // A properly dark background does not.
        val dark = ink(background = BackgroundKind.FLAT_COLOUR, fallback = 0x101418)
        assertFalse(dark.needsShadow)
        assertEquals(Palette.LIGHT_INK, dark.inkRgb)
        // Nor does a mid grey that the better ink clears comfortably: under the old midpoint rule
        // this one was given light ink at 3.2:1, and now takes dark ink at 5.3:1 with no shadow.
        val midGrey = ink(background = BackgroundKind.FLAT_COLOUR, fallback = 0x8A8A8A)
        assertEquals(Palette.DARK_INK, midGrey.inkRgb)
        assertFalse(midGrey.needsShadow)
    }

    @Test
    fun theShadowIsTheOppositeInkAtFortyPercent() {
        val overLight = ink(background = BackgroundKind.FLAT_COLOUR, fallback = 0xFFFFFF)
        assertEquals(Palette.DARK_INK, overLight.inkRgb)
        assertEquals(Palette.LIGHT_INK, overLight.shadowRgb)

        val overDark = ink(background = BackgroundKind.FLAT_COLOUR, fallback = 0x000000)
        assertEquals(Palette.LIGHT_INK, overDark.inkRgb)
        assertEquals(Palette.DARK_INK, overDark.shadowRgb)

        // 40 % of full opacity, as §5 specifies.
        assertEquals(102, RegionInkPolicy.SHADOW_ALPHA)
        assertEquals(0.4, RegionInkPolicy.SHADOW_ALPHA / 255.0, 0.005)
    }

    @Test
    fun anOverrideThatIsHardToReadStillGetsTheShadowRatherThanBeingReplaced() {
        // A custom colour is never rejected; it is helped.
        val result = ink(
            override = 0x9A9A9A, background = BackgroundKind.IMAGE_DRAWN,
            sample = 0x8A8A8A, fallback = 0x8A8A8A,
        )
        assertEquals(0x9A9A9A, result.inkRgb)
        assertTrue(result.needsShadow)
    }

    @Test
    fun aRegionCrossingLightAndDarkGetsTheShadowEvenThoughItsAverageIsFine() {
        // The visitor hint crosses a pale wall and a dark jacket. The average clears 4.5:1 with
        // dark ink, but over the jacket that same ink is unreadable, so the shadow is required.
        val busy = RegionSample(averageRgb = 0xC8CCD0, minLuminance = 0.01, maxLuminance = 0.85)
        val result = RegionInkPolicy.resolve(
            override = null, coreInkLight = null, background = BackgroundKind.IMAGE_DRAWN,
            sampledBackgroundRgb = busy.averageRgb, fallbackBackgroundRgb = 0x101418,
            sample = busy,
        )
        assertEquals(Palette.DARK_INK, result.inkRgb)
        assertTrue(UiContrast.contrast(result.inkRgb, busy.averageRgb) > 4.5)
        assertTrue("a busy region needs the shadow", result.needsShadow)
    }

    @Test
    fun anEvenRegionKeepsNoShadow() {
        val flat = RegionSample(averageRgb = 0xE9EDF0, minLuminance = 0.80, maxLuminance = 0.86)
        val result = RegionInkPolicy.resolve(
            null, null, BackgroundKind.IMAGE_DRAWN, flat.averageRgb, 0x101418, flat,
        )
        assertEquals(Palette.DARK_INK, result.inkRgb)
        assertFalse(result.needsShadow)
    }

    @Test
    fun theWorstPatchIsMeasuredAgainstWhicheverSideTheInkSitsOn() {
        val spread = RegionSample(0x808080, minLuminance = 0.0, maxLuminance = 1.0)
        // Light ink is defeated by the light end, dark ink by the dark end; both are below AA.
        assertTrue(spread.worstContrast(Palette.LIGHT_INK) < UiContrast.TEXT_AA)
        assertTrue(spread.worstContrast(Palette.DARK_INK) < UiContrast.TEXT_AA)
        // A region that is uniformly dark gives light ink its full ratio.
        val dark = RegionSample(0x101418, minLuminance = 0.01, maxLuminance = 0.02)
        assertTrue(dark.worstContrast(Palette.LIGHT_INK) > 10.0)
    }

    @Test
    fun summarisingKeepsBothTheAverageAndTheExtremes() {
        val pixels = IntArray(RegionInk.SAMPLE * RegionInk.SAMPLE) { index ->
            if (index % 2 == 0) 0xFFFFFFFF.toInt() else 0xFF000000.toInt()
        }
        val sample = RegionInk.summarise(pixels)
        assertEquals(0x7F7F7F, sample.averageRgb)
        assertEquals(0.0, sample.minLuminance, 1e-9)
        assertEquals(1.0, sample.maxLuminance, 1e-9)
        // Whichever ink is chosen for the average, half the region defeats it.
        assertTrue(sample.worstContrast(Palette.DARK_INK) < UiContrast.TEXT_AA)
    }

    // ---------- sampling maths ----------

    @Test
    fun theSampledAreaIsAveragedAtSixteenBySixteen() {
        assertEquals(16, RegionInk.SAMPLE)
        // Half light, half dark averages to something the rule can decide on.
        val pixels = IntArray(RegionInk.SAMPLE * RegionInk.SAMPLE) { index ->
            if (index % 2 == 0) 0xFFFFFFFF.toInt() else 0xFF000000.toInt()
        }
        val average = UiContrast.averageRgb(pixels)
        assertEquals(0x7F7F7F, average)
    }

    @Test
    fun aMostlyLightRegionResolvesToDarkInkAndTheReverse() {
        fun patch(light: Int): Int {
            val total = RegionInk.SAMPLE * RegionInk.SAMPLE
            return UiContrast.averageRgb(
                IntArray(total) { if (it < light) 0xFFF0F2F4.toInt() else 0xFF141A20.toInt() },
            )
        }
        val mostlyLight = patch(230)
        val mostlyDark = patch(20)
        assertEquals(
            Palette.DARK_INK,
            ink(background = BackgroundKind.IMAGE_DRAWN, sample = mostlyLight).inkRgb,
        )
        assertEquals(
            Palette.LIGHT_INK,
            ink(background = BackgroundKind.IMAGE_DRAWN, sample = mostlyDark).inkRgb,
        )
    }

    // ---------- the footer must not collide with the slider ----------

    @Test
    fun aPortraitPhoneStacksTheVersionLineAboveTheSlider() {
        // The Moto in portrait, which is where the clipping was seen.
        assertTrue(VisitorLayout.footerStacked(360, 780))
        assertTrue(VisitorLayout.footerStacked(411, 869))
        // A portrait tablet stacks too: taller than wide is always stacked.
        assertTrue(VisitorLayout.footerStacked(768, 1024))
    }

    @Test
    fun onlyAWideLandscapeWindowPutsTheSliderBesideTheVersionLine() {
        assertFalse(VisitorLayout.footerStacked(1024, 768))
        assertFalse(VisitorLayout.footerStacked(800, 600))
        // A short but narrow landscape window still stacks rather than clipping.
        assertTrue(VisitorLayout.footerStacked(568, 320))
    }

    @Test
    fun breathingRoomIsAddedOnlyOutOfRealSlack() {
        // A tall screen with compact content gets a generous gap...
        assertEquals(32, VisitorLayout.groupGapDp(800, 400, 4))
        // ...a snug one gets a small one...
        assertEquals(8, VisitorLayout.groupGapDp(640, 600, 4))
        // ...and a short screen keeps the tight layout rather than pushing the call button off.
        assertEquals(0, VisitorLayout.groupGapDp(600, 600, 4))
        assertEquals(0, VisitorLayout.groupGapDp(500, 600, 4))
    }

    @Test
    fun theGapAlwaysComesFromTheDocumentedScale() {
        for (available in 300..1200 step 7) {
            val gap = VisitorLayout.groupGapDp(available, 400, 4)
            assertTrue("gap $gap is off the scale",
                       gap == 0 || VisitorLayout.SPACING_SCALE.contains(gap))
        }
    }

    @Test
    fun oneGroupNeedsNoGapAndSlackIsNeverFullySpent() {
        assertEquals(0, VisitorLayout.groupGapDp(800, 100, 1))
        // At most two thirds of the slack is spent, so the layout never sits flush to the edges.
        val gap = VisitorLayout.groupGapDp(800, 400, 4)
        assertTrue(gap * 3 <= (800 - 400))
    }

    @Test
    fun theDashboardActionsFollowTheSameWidthRule() {
        assertTrue(VisitorLayout.actionsStacked(360))
        assertTrue(VisitorLayout.actionsStacked(599))
        assertFalse(VisitorLayout.actionsStacked(600))
        assertFalse(VisitorLayout.actionsStacked(1024))
    }
}
