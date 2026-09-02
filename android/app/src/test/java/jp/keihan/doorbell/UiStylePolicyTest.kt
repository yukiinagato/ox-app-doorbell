package jp.keihan.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UiStylePolicyTest {
    private val baseline = UiStyleBaseline(
        foregroundArgb = 0xfff2f5f8.toInt(),
        backgroundRgb = 0x10151b,
        accentRgb = 0x4da3ff,
        borderRgb = 0x4da3ff,
        radiusDp = 12f,
    )

    @Test
    fun strictColorsAndEffectiveSingleFieldContrastAreEnforced() {
        assertTrue(UiStylePolicy.validate(
            JSONObject().put("foreground", "#FFFFFF"),
            baseline,
            false,
        ).valid)
        assertFalse(UiStylePolicy.validate(
            JSONObject().put("foreground", "#777777"),
            UiStyleBaseline(0xff000000.toInt(), 0xffffff),
            false,
        ).valid)
        assertFalse(UiStylePolicy.validate(
            JSONObject().put("background", "#FFFFFF"),
            UiStyleBaseline(0x80ffffff.toInt(), 0x000000),
            false,
        ).valid)
        for (invalid in listOf("#FFF", "#FFFFFFFF", "ffffff", "#GGGGGG")) {
            assertFalse(UiStylePolicy.validate(
                JSONObject().put("foreground", invalid),
                baseline,
                false,
            ).valid)
        }
    }

    @Test
    fun safetyControlsCannotShrinkAndUnsupportedPropertiesFailClosed() {
        assertFalse(UiStylePolicy.validate(
            JSONObject().put("scale", 0.99), baseline, true,
        ).valid)
        assertFalse(UiStylePolicy.validate(
            JSONObject().put("font_scale", 0.99), baseline, true,
        ).valid)
        assertTrue(UiStylePolicy.validate(
            JSONObject().put("scale", 0.75), baseline, false,
        ).valid)
        assertTrue(UiStylePolicy.validate(
            JSONObject().put("accent", "#FFFFFF"), baseline, false,
        ).valid)
        assertFalse(UiStylePolicy.validate(
            JSONObject().put("shadow", "#FFFFFF"), baseline, false,
        ).valid)
    }

    @Test
    fun accentBorderAndRadiusAreValidatedAndRetainedForRendering() {
        val accepted = UiStylePolicy.validate(
            JSONObject()
                .put("accent", "#FFFFFF")
                .put("border", "#4DA3FF")
                .put("radius", 24.5),
            baseline,
            false,
        )
        assertTrue(accepted.valid)
        assertEquals(0xffffff, accepted.style?.accentRgb)
        assertEquals(0x4da3ff, accepted.style?.borderRgb)
        assertEquals(24.5f, accepted.style?.radiusDp)
        assertFalse(UiStylePolicy.validate(
            JSONObject().put("accent", "#222222"), baseline, false,
        ).valid)
        assertFalse(UiStylePolicy.validate(
            JSONObject().put("border", "#222222"), baseline, false,
        ).valid)
        assertFalse(UiStylePolicy.validate(
            JSONObject().put("radius", 64.01), baseline, false,
        ).valid)
        assertFalse(UiStylePolicy.validate(
            JSONObject().put("radius", "12"), baseline, false,
        ).valid)
    }

    @Test
    fun invalidProposalUsesOnlyARevalidatedLastKnownGoodStyle() {
        val invalid = JSONObject()
            .put("foreground", "#222222")
            .put("background", "#222222")
        val saved = JSONObject()
            .put("foreground", "#F2F5F8")
            .put("background", "#243040")
        val resolution = UiStylePolicy.resolve(invalid, saved, baseline, false)
        assertEquals("last_known_good", resolution.source)
        assertTrue(resolution.rejectionReason.isNotEmpty())

        val noSafeFallback = UiStylePolicy.resolve(invalid, invalid, baseline, false)
        assertEquals("platform_default", noSafeFallback.source)
        assertTrue(noSafeFallback.style == null)
    }

    @Test
    fun applicationReportSeparatesValidationAndPersistenceFailures() {
        val invalidProposal = UiStyleApplyReport(
            "node-a",
            "call.primary",
            "last_known_good",
            validationError = "foreground_background_contrast_below_4_5",
        )
        assertFalse(invalidProposal.validationValid)
        assertTrue(invalidProposal.lastKnownGoodPersisted)

        val persistenceFailure = UiStyleApplyReport(
            "node-a",
            "call.primary",
            "applied_not_persisted",
            persistenceError = "last_known_good_persist_failed",
        )
        assertTrue(persistenceFailure.validationValid)
        assertFalse(persistenceFailure.lastKnownGoodPersisted)
    }
}
