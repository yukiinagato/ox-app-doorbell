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

    // ---------- precedence ----------

    @Test
    fun anAdministratorOverrideWinsOverEverything() {
        val result = RegionInkPolicy.resolve(
            override = 0xFF0000,
            coreInkLight = true,
            coreAuthoritative = true,
            sampledBackgroundRgb = darkPatch,
            fallbackBackgroundRgb = lightPatch,
        )
        assertEquals(0xFF0000, result.inkRgb)
    }

    @Test
    fun coresValueStandsOverAFlatBackgroundColour() {
        // A flat colour has no geometry for core to be wrong about, so its answer is authoritative
        // even though the shell also measured the region.
        val result = RegionInkPolicy.resolve(
            override = null,
            coreInkLight = true,
            coreAuthoritative = true,
            sampledBackgroundRgb = lightPatch,
            fallbackBackgroundRgb = lightPatch,
        )
        assertEquals(Palette.LIGHT_INK, result.inkRgb)
    }

    @Test
    fun theLocalSampleRefinesCoresWholeImageAverage() {
        // The reported failure: core averaged the whole picture to "light ink", but this region
        // sits on the light part of it, so the shell must choose dark ink instead.
        val footer = RegionInkPolicy.resolve(
            override = null,
            coreInkLight = true,
            coreAuthoritative = false,
            sampledBackgroundRgb = lightPatch,
            fallbackBackgroundRgb = 0x808080,
        )
        assertEquals(Palette.DARK_INK, footer.inkRgb)

        // A region on the dark part of the same image keeps light ink.
        val clock = RegionInkPolicy.resolve(
            override = null,
            coreInkLight = true,
            coreAuthoritative = false,
            sampledBackgroundRgb = darkPatch,
            fallbackBackgroundRgb = 0x808080,
        )
        assertEquals(Palette.LIGHT_INK, clock.inkRgb)
    }

    @Test
    fun twoRegionsOnOneImageCanDisagree() {
        fun ink(patch: Int) = RegionInkPolicy.resolve(
            null, coreInkLight = true, coreAuthoritative = false,
            sampledBackgroundRgb = patch, fallbackBackgroundRgb = 0x808080,
        ).inkRgb
        assertTrue(ink(lightPatch) != ink(darkPatch))
    }

    @Test
    fun coresValueIsUsedWhenTheShellCouldNotMeasureTheRegion() {
        val result = RegionInkPolicy.resolve(
            override = null,
            coreInkLight = false,
            coreAuthoritative = false,
            sampledBackgroundRgb = null,
            fallbackBackgroundRgb = lightPatch,
        )
        assertEquals(Palette.DARK_INK, result.inkRgb)
    }

    @Test
    fun withNothingFromCoreTheRuleIsAppliedLocally() {
        assertEquals(
            Palette.DARK_INK,
            RegionInkPolicy.resolve(null, null, false, null, 0xFFFFFF).inkRgb,
        )
        assertEquals(
            Palette.LIGHT_INK,
            RegionInkPolicy.resolve(null, null, false, null, 0x000000).inkRgb,
        )
    }

    // ---------- the shadow ----------

    @Test
    fun theShadowIsAddedOnlyWhenTheChosenInkMissesTheTextRatio() {
        // Mid grey defeats both ink tokens, so whichever is chosen needs the shadow.
        val midGrey = RegionInkPolicy.resolve(null, null, false, 0x8A8A8A, 0x8A8A8A)
        assertTrue(midGrey.needsShadow)
        // A properly dark background does not.
        val dark = RegionInkPolicy.resolve(null, null, false, 0x101418, 0x101418)
        assertFalse(dark.needsShadow)
        assertEquals(Palette.LIGHT_INK, dark.inkRgb)
    }

    @Test
    fun theShadowIsTheOppositeInkAtFortyPercent() {
        val overLight = RegionInkPolicy.resolve(null, null, false, 0xFFFFFF, 0xFFFFFF)
        assertEquals(Palette.DARK_INK, overLight.inkRgb)
        assertEquals(Palette.LIGHT_INK, overLight.shadowRgb)

        val overDark = RegionInkPolicy.resolve(null, null, false, 0x000000, 0x000000)
        assertEquals(Palette.LIGHT_INK, overDark.inkRgb)
        assertEquals(Palette.DARK_INK, overDark.shadowRgb)

        // 40 % of full opacity, as §5 specifies.
        assertEquals(102, RegionInkPolicy.SHADOW_ALPHA)
        assertEquals(0.4, RegionInkPolicy.SHADOW_ALPHA / 255.0, 0.005)
    }

    @Test
    fun anOverrideThatIsHardToReadStillGetsTheShadowRatherThanBeingReplaced() {
        // A custom colour is never rejected; it is helped.
        val result = RegionInkPolicy.resolve(
            override = 0x9A9A9A, coreInkLight = null, coreAuthoritative = false,
            sampledBackgroundRgb = 0x8A8A8A, fallbackBackgroundRgb = 0x8A8A8A,
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
            RegionInkPolicy.resolve(null, null, false, mostlyLight, 0).inkRgb,
        )
        assertEquals(
            Palette.LIGHT_INK,
            RegionInkPolicy.resolve(null, null, false, mostlyDark, 0).inkRgb,
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
