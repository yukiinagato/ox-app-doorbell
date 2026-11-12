package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DashboardModelTest {

    private fun row(door: String, outcome: String, ts: Long) =
        CallRow("id$ts", "c$ts", ts, door, "", "ja", outcome, "", 0L, "h$ts", true)

    @Test
    fun activeCallsMapToDoorStatesAndInCallWins() {
        val status = JSONObject("""{"active_calls":[
            {"door":"front","state":"ringing"},
            {"door":"back","state":"in_call"},
            {"door":"back","state":"ringing"},
            {"door":"side","state":"ended"},
            {"state":"ringing"}]}""")
        val states = DashboardModel.callStates(status)
        assertEquals("ringing", states["front"])
        assertEquals("in_call", states["back"])
        assertNull(states["side"])
        assertEquals(2, states.size)
        assertTrue(DashboardModel.callStates(null).isEmpty())
        assertTrue(DashboardModel.callStates(JSONObject("{}")).isEmpty())
    }

    @Test
    fun tileStatePrefersTheLiveCall() {
        assertEquals(TileState.IDLE, DashboardModel.tileState(DoorService.SERVED, null))
        assertEquals(TileState.RINGING, DashboardModel.tileState(DoorService.SERVED, "ringing"))
        assertEquals(TileState.IN_CALL, DashboardModel.tileState(DoorService.STATION_OFFLINE, "in_call"))
        assertEquals(TileState.OFFLINE, DashboardModel.tileState(DoorService.STATION_OFFLINE, null))
        assertEquals(TileState.NO_STATION, DashboardModel.tileState(DoorService.NO_STATION, null))
        assertTrue(DashboardModel.highlighted(TileState.RINGING))
        for (state in TileState.values().filter { it != TileState.RINGING })
            assertFalse(DashboardModel.highlighted(state))
        assertEquals(ActionRole.POSITIVE, DashboardModel.chipRole(TileState.IN_CALL))
        assertEquals(ActionRole.WARNING, DashboardModel.chipRole(TileState.OFFLINE))
    }

    @Test
    fun headerChipsAppearOnlyWhenTheyHaveSomethingToSay() {
        assertTrue(DashboardModel.headerChips(false, 0, 0).isEmpty())
        assertEquals(
            listOf(HeaderChip.SOS, HeaderChip.OFFLINE_DEVICES, HeaderChip.MISSED),
            DashboardModel.headerChips(true, 2, 1),
        )
        assertEquals(listOf(HeaderChip.MISSED), DashboardModel.headerChips(false, 0, 3))
        val counts = FleetCounts(5, RoleCount(1, 3), RoleCount(2, 2))
        assertEquals(2, DashboardModel.offlineDevices(counts))
        assertTrue(DashboardModel.sosActive(JSONObject("""{"emergency":{"active":true}}""")))
        assertFalse(DashboardModel.sosActive(JSONObject("""{"emergency":{}}""")))
        assertFalse(DashboardModel.sosActive(null))
    }

    @Test
    fun lastCallIsTheNewestForThatDoor() {
        val rows = listOf(row("back", "missed", 3), row("front", "answered", 2), row("front", "missed", 1))
        assertEquals(2L, DashboardModel.lastCall(rows, "front")?.tsMs)
        assertNull(DashboardModel.lastCall(rows, "side"))
    }

    @Test
    fun outcomesKeepOneRoleEverywhere() {
        assertEquals(CallOutcome.ANSWERED, CallOutcome.of("answered"))
        assertEquals(CallOutcome.MISSED, CallOutcome.of("missed"))
        assertEquals(CallOutcome.REPLIED, CallOutcome.of("replied"))
        assertEquals(CallOutcome.CANCELLED, CallOutcome.of("cancelled"))
        assertEquals(CallOutcome.CANCELLED, CallOutcome.of(""))
        assertEquals(ActionRole.NEGATIVE, CallOutcome.MISSED.role)
    }

    @Test
    fun tileGridFollowsTheAreaItActuallyGets() {
        // Phone portrait: tabs, stacked, one column.
        val phone = WindowSpec(390, 840)
        assertEquals(390, DashboardModel.tileAreaWidthDp(phone))
        assertEquals(1, DashboardModel.tileColumns(phone, 4))
        // Tablet portrait: rail, stacked, two columns.
        val tabletPortrait = WindowSpec(800, 1280)
        assertEquals(704, DashboardModel.tileAreaWidthDp(tabletPortrait))
        assertEquals(2, DashboardModel.tileColumns(tabletPortrait, 4))
        // Tablet landscape: the rail only; the home surface has no call list beside the tiles.
        val tabletLandscape = WindowSpec(1280, 800)
        assertEquals(1184, DashboardModel.tileAreaWidthDp(tabletLandscape))
        assertEquals(3, DashboardModel.tileColumns(tabletLandscape, 4))
        // Large desktop window: the tiles have the full width, so four columns.
        assertEquals(4, DashboardModel.tileColumns(WindowSpec(1920, 1080), 6))
        // 200 % text drops a column.
        assertEquals(1, DashboardModel.tileColumns(WindowSpec(800, 1280, 2f), 4))
        assertEquals(0, DashboardModel.tileRows(0, 2))
        assertEquals(2, DashboardModel.tileRows(3, 2))
        assertEquals(3, DashboardModel.tileRows(3, 1))
    }
}
