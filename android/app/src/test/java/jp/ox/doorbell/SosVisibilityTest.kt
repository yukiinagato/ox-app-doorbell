package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which devices offer the SOS slide bar.
 *
 * The rule is emergency.button_on_roles, defaulting to core's ["indoor_panel"] when the cluster
 * has never set it. The bug this pins down: an absent key used to mean "show it everywhere", so a
 * door station's visitor screen carried an SOS bar that any passer-by could slide.
 */
class SosVisibilityTest {

    private val indoor = "indoor_panel"
    private val door = "door_station"

    private fun config(roles: String): JSONObject =
        JSONObject("""{"emergency":{"button_on_roles":$roles}}""")

    // ---------- the key is absent ----------

    @Test
    fun anAbsentKeyShowsTheBarOnTheIndoorPanelOnly() {
        assertTrue(SosSlideState.visibleForRole(null, indoor))
        assertFalse(SosSlideState.visibleForRole(null, door))
        assertTrue(SosSlideState.visibleForRole(JSONObject(), indoor))
        assertFalse(SosSlideState.visibleForRole(JSONObject(), door))
    }

    @Test
    fun anEmergencyBlockWithoutTheKeyStillDefaultsToTheIndoorPanel() {
        val cfg = JSONObject("""{"emergency":{"trigger":{"countdown_s":5}}}""")
        assertTrue(SosSlideState.visibleForRole(cfg, indoor))
        assertFalse(SosSlideState.visibleForRole(cfg, door))
    }

    // ---------- the key is set ----------

    @Test
    fun aListNamingARoleShowsTheBarOnThatRoleOnly() {
        val onlyIndoor = config("""["indoor_panel"]""")
        assertTrue(SosSlideState.visibleForRole(onlyIndoor, indoor))
        assertFalse(SosSlideState.visibleForRole(onlyIndoor, door))

        val onlyDoor = config("""["door_station"]""")
        assertFalse(SosSlideState.visibleForRole(onlyDoor, indoor))
        assertTrue(SosSlideState.visibleForRole(onlyDoor, door))
    }

    @Test
    fun aClusterMayPutTheBarOnBothRoles() {
        val both = config("""["indoor_panel","door_station"]""")
        assertTrue(SosSlideState.visibleForRole(both, indoor))
        assertTrue(SosSlideState.visibleForRole(both, door))
    }

    /** An empty list is a deliberate "nowhere", which is what it used to read as "everywhere". */
    @Test
    fun anEmptyListHidesTheBarOnEveryRole() {
        val none = config("[]")
        assertFalse(SosSlideState.visibleForRole(none, indoor))
        assertFalse(SosSlideState.visibleForRole(none, door))
    }

    @Test
    fun anUnknownRoleNeverGetsTheBar() {
        assertFalse(SosSlideState.visibleForRole(config("""["indoor_panel"]"""), "kiosk"))
        assertFalse(SosSlideState.visibleForRole(null, ""))
    }

    /** A value of the wrong shape is treated as unset, which is what every other shell does. */
    @Test
    fun aNonListValueFallsBackToTheDefault() {
        val text = config(""""indoor_panel"""")
        assertTrue(SosSlideState.visibleForRole(text, indoor))
        assertFalse(SosSlideState.visibleForRole(text, door))
    }

    @Test
    fun coreDefaultRoleIsTheIndoorPanel() {
        assertTrue(SosSlideState.DEFAULT_BUTTON_ROLE == "indoor_panel")
    }
}
