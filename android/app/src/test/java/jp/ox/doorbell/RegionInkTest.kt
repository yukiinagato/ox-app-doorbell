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

    // ---------- the shadow ----------

    @Test
    fun theShadowIsAddedOnlyWhenTheChosenInkMissesTheTextRatio() {
        // Mid grey defeats both ink tokens, so whichever is chosen needs the shadow.
        val midGrey = ink(background = BackgroundKind.FLAT_COLOUR, fallback = 0x8A8A8A)
        assertTrue(midGrey.needsShadow)
        // A properly dark background does not.
        val dark = ink(background = BackgroundKind.FLAT_COLOUR, fallback = 0x101418)
        assertFalse(dark.needsShadow)
        assertEquals(Palette.LIGHT_INK, dark.inkRgb)
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
    fun theDashboardActionsFollowTheSameWidthRule() {
        assertTrue(VisitorLayout.actionsStacked(360))
        assertTrue(VisitorLayout.actionsStacked(599))
        assertFalse(VisitorLayout.actionsStacked(600))
        assertFalse(VisitorLayout.actionsStacked(1024))
    }
}
