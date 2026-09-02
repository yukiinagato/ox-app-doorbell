package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The cross-platform visit_purposes.<id>.enabled flag: a disabled purpose is never offered to a
 * visitor, but its label still resolves for a call in flight and for the call history.
 */
class VisitPurposesTest {

    private val config = JSONObject(
        """
        {"visit_purposes":{
          "p_delivery":{"order":1,"icon":"📦","enabled":true,
                        "label":{"ja":"配達","en":"Delivery","zh":"送货"}},
          "p_post":{"order":2,"enabled":false,"label":{"ja":"郵便","en":"Post"}},
          "p_visit":{"order":3,"label":{"ja":"訪問","en":"Visit"}},
          "p_repair":{"order":4,"enabled":false,"label":{"ja":"工事"}}}}
        """.trimIndent(),
    )

    @Test
    fun anAbsentFlagMeansEnabledSoAnOlderInstallationKeepsEveryPurpose() {
        // p_visit has no "enabled" key at all.
        assertTrue(VisitPurposes.isEnabled(config, "p_visit"))
        assertTrue(VisitPurposes.isEnabled(null, "anything"))
        assertTrue(VisitPurposes.isEnabled(JSONObject(), "p_visit"))
    }

    @Test
    fun theFlagIsReadWhenItIsPresent() {
        assertTrue(VisitPurposes.isEnabled(config, "p_delivery"))
        assertFalse(VisitPurposes.isEnabled(config, "p_post"))
        assertFalse(VisitPurposes.isEnabled(config, "p_repair"))
    }

    @Test
    fun theVisitorChooserOffersOnlyEnabledPurposes() {
        assertEquals(listOf("p_delivery", "p_visit"), VisitPurposes.enabled(config))
    }

    @Test
    fun theSettingsListKeepsDisabledPurposesSoTheyCanBeTurnedBackOn() {
        assertEquals(
            listOf("p_delivery", "p_post", "p_visit", "p_repair"),
            VisitPurposes.all(config),
        )
    }

    @Test
    fun bothListsAreOrderedByConfiguredOrderThenIdentifier() {
        val unordered = JSONObject(
            """
            {"visit_purposes":{
              "b":{"order":1,"label":{"ja":"B"}},
              "a":{"order":1,"label":{"ja":"A"}},
              "c":{"label":{"ja":"C"}}}}
            """.trimIndent(),
        )
        // Equal orders fall back to the identifier; an absent order sorts last.
        assertEquals(listOf("a", "b", "c"), VisitPurposes.all(unordered))
        assertEquals(listOf("a", "b", "c"), VisitPurposes.enabled(unordered))
    }

    @Test
    fun disablingEveryPurposeLeavesTheChooserEmptyRatherThanShowingDisabledOnes() {
        val allOff = JSONObject(
            """
            {"visit_purposes":{"p_a":{"enabled":false,"label":{"ja":"A"}},
                               "p_b":{"enabled":false,"label":{"ja":"B"}}}}
            """.trimIndent(),
        )
        assertTrue(VisitPurposes.enabled(allOff).isEmpty())
        // The settings list still has both, so the operator can restore them.
        assertEquals(listOf("p_a", "p_b"), VisitPurposes.all(allOff))
    }

    @Test
    fun anAbsentOrEmptyConfigurationYieldsNoPurposes() {
        assertTrue(VisitPurposes.all(null).isEmpty())
        assertTrue(VisitPurposes.enabled(null).isEmpty())
        assertTrue(VisitPurposes.all(JSONObject()).isEmpty())
        assertTrue(VisitPurposes.enabled(JSONObject("""{"visit_purposes":{}}""")).isEmpty())
    }

    @Test
    fun aDisabledPurposeStillResolvesItsLabelForACallInFlightAndForTheHistory() {
        // The visitor chose it before it was turned off; the incoming screen and the call log
        // must keep showing their own words rather than a raw identifier.
        assertEquals("郵便", VisitPurposes.label(config, "p_post", "ja"))
        assertEquals("Post", VisitPurposes.label(config, "p_post", "en"))
    }

    @Test
    fun labelsFallBackToJapaneseThenToTheIdentifier() {
        assertEquals("配達", VisitPurposes.label(config, "p_delivery", "ja"))
        assertEquals("Delivery", VisitPurposes.label(config, "p_delivery", "en"))
        // p_repair has only Japanese.
        assertEquals("工事", VisitPurposes.label(config, "p_repair", "en"))
        // An unknown purpose, and an unknown language on a known purpose.
        assertEquals("p_unknown", VisitPurposes.label(config, "p_unknown", "ja"))
        assertEquals("訪問", VisitPurposes.label(config, "p_visit", "ko"))
        assertEquals("", VisitPurposes.label(config, "", "ja"))
    }

    @Test
    fun theIconPrefixesTheLabelOnlyWhenOneIsConfigured() {
        assertEquals("📦  配達", VisitPurposes.decoratedLabel(config, "p_delivery", "ja"))
        assertEquals("訪問", VisitPurposes.decoratedLabel(config, "p_visit", "ja"))
        assertEquals("📦", VisitPurposes.icon(config, "p_delivery"))
        assertEquals("", VisitPurposes.icon(config, "p_visit"))
    }

    @Test
    fun theSettingsToggleWritesTheCrossPlatformKey() {
        assertEquals("visit_purposes.p_post.enabled", VisitPurposes.enabledKey("p_post"))
    }

    @Test
    fun theToggleWriteIsAPlainBooleanTheConfigWriterCanSend() {
        // The settings screen writes this through the same batch document the web admin uses.
        val ops = JSONObject(
            ConfigOps.build(listOf(VisitPurposes.enabledKey("p_post") to "false")),
        ).getJSONArray("ops")
        assertEquals(1, ops.length())
        assertEquals("set", ops.getJSONObject(0).getString("op"))
        assertEquals("visit_purposes.p_post.enabled", ops.getJSONObject(0).getString("key"))
        assertFalse(ops.getJSONObject(0).getBoolean("value"))
    }
}
