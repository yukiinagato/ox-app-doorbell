package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RoleChangeModelTest {
    private val config = JSONObject("""{
        "doors": {"front": {}, "back": {}, "garage": {}},
        "devices": {
            "aaaa": {"name": "Front station", "role": "door_station", "door": "front"},
            "bbbb": {"name": "Hall panel", "role": "indoor_panel", "door": ""},
            "cccc": {"name": "", "role": "door_station", "door": "back"}
        }}""")

    @Test
    fun thePickerOffersDoorsNoOtherStationServes() {
        assertEquals(listOf("garage"), RoleChangeModel.freeDoors(config, "bbbb"))
        // A station's own door is free for itself.
        assertEquals(listOf("front", "garage"), RoleChangeModel.freeDoors(config, "aaaa"))
        assertEquals("Front station", RoleChangeModel.otherOwner(config, "bbbb", "front"))
        assertEquals("cccc", RoleChangeModel.otherOwner(config, "bbbb", "back"))
        assertEquals("", RoleChangeModel.otherOwner(config, "bbbb", "garage"))
        assertEquals("", RoleChangeModel.otherOwner(config, "bbbb", "not-a-door"))
        assertTrue(RoleChangeModel.freeDoors(null, "bbbb").isEmpty())
    }

    @Test
    fun aDoorStationNeedsAValidDoorAndAnIndoorPanelNone() {
        assertEquals(RoleChangeModel.Problem.NONE,
                     RoleChangeModel.validate("door_station", "door-1a2b"))
        assertEquals(RoleChangeModel.Problem.DOOR, RoleChangeModel.validate("door_station", ""))
        assertEquals(RoleChangeModel.Problem.DOOR,
                     RoleChangeModel.validate("door_station", "front door"))
        assertEquals(RoleChangeModel.Problem.NONE, RoleChangeModel.validate("indoor_panel", ""))
        assertEquals(RoleChangeModel.Problem.ROLE, RoleChangeModel.validate("monitor", ""))
        assertEquals("", RoleChangeModel.doorFor("indoor_panel", "front"))
        assertEquals("front", RoleChangeModel.doorFor("door_station", " front "))
    }

    @Test
    fun anotherDevicesRoleAndDoorAreWrittenTogether() {
        val ops = RoleChangeModel.ops("bbbb", "door_station", "garage")
        assertEquals(listOf(
            ConfigOp.Set("devices.bbbb.role", "\"door_station\""),
            ConfigOp.Set("devices.bbbb.door", "\"garage\""),
        ), ops)
        assertEquals(ConfigOp.Set("devices.aaaa.door", "\"\""),
                     RoleChangeModel.ops("aaaa", "indoor_panel", "front")[1])
        assertTrue(RoleChangeModel.unchanged("door_station", "front", "door_station", "front"))
        assertFalse(RoleChangeModel.unchanged("door_station", "front", "indoor_panel", "front"))
        assertTrue(RoleChangeModel.unchanged("indoor_panel", "", "indoor_panel", "anything"))
    }

    @Test
    fun theChangeWaitsForACallOrAnSosToEnd() {
        assertFalse(RoleChangeModel.blocked(JSONObject(), false, false))
        assertTrue(RoleChangeModel.blocked(JSONObject(), true, false))
        assertTrue(RoleChangeModel.blocked(JSONObject(), false, true))
        assertTrue(RoleChangeModel.blocked(JSONObject("""{"sip":{"call":"in_call"}}"""), false, false))
        assertTrue(RoleChangeModel.blocked(JSONObject("""{"emergency":{"active":true}}"""), false, false))
    }
}
