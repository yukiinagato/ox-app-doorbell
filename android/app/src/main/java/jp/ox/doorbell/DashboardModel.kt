// Pure decisions behind the indoor dashboard (docs/en/ui-guidelines.md, "Dashboard"): what state
// each door tile shows, which status chips the header carries, and how the window is shared
// between navigation, door tiles and the recent-call list. No views, so it is unit tested.
package jp.ox.doorbell

import org.json.JSONObject

/** The state chip on a door tile. */
internal enum class TileState { IDLE, RINGING, IN_CALL, OFFLINE, NO_STATION }

/** The header's status chips, in the order they are shown. */
internal enum class HeaderChip { SOS, OFFLINE_DEVICES, MISSED }

/** Destinations reachable from the dashboard's tab bar or rail. */
internal enum class Destination(val id: String) { HOME("home"), HISTORY("history"), MONITOR("monitor"), SETTINGS("settings") }

/** How a recorded call ended, with the role its icon takes everywhere it is shown. */
internal enum class CallOutcome(val role: ActionRole) {
    ANSWERED(ActionRole.POSITIVE),
    MISSED(ActionRole.NEGATIVE),
    REPLIED(ActionRole.PRIMARY),
    CANCELLED(ActionRole.SECONDARY);

    companion object {
        fun of(outcome: String): CallOutcome = when (outcome) {
            "answered" -> ANSWERED
            "missed" -> MISSED
            "replied" -> REPLIED
            else -> CANCELLED
        }
    }
}

internal object DashboardModel {

    /** Width a navigation rail takes, in dp. */
    const val RAIL_WIDTH_DP = 96

    /**
     * The live call state per door from Core's `active_calls`. A door with one call in progress
     * and another ringing shows "in call": the operator is already busy with that door.
     */
    fun callStates(status: JSONObject?): Map<String, String> {
        val calls = status?.optJSONArray("active_calls") ?: return emptyMap()
        val states = HashMap<String, String>()
        for (index in 0 until calls.length()) {
            val call = calls.optJSONObject(index) ?: continue
            val door = call.optString("door")
            val state = call.optString("state")
            if (door.isEmpty() || (state != "ringing" && state != "in_call")) continue
            if (states[door] != "in_call") states[door] = state
        }
        return states
    }

    /** A live call outranks the station's service state: a ringing door is plainly reachable. */
    fun tileState(service: DoorService, callState: String?): TileState = when {
        callState == "in_call" -> TileState.IN_CALL
        callState == "ringing" -> TileState.RINGING
        service == DoorService.STATION_OFFLINE -> TileState.OFFLINE
        service == DoorService.NO_STATION -> TileState.NO_STATION
        else -> TileState.IDLE
    }

    fun chipRole(state: TileState): ActionRole = when (state) {
        TileState.IDLE, TileState.NO_STATION -> ActionRole.SECONDARY
        TileState.RINGING -> ActionRole.PRIMARY
        TileState.IN_CALL -> ActionRole.POSITIVE
        TileState.OFFLINE -> ActionRole.WARNING
    }

    /** Only a ringing tile is highlighted, so the eye goes straight to the door that needs it. */
    fun highlighted(state: TileState): Boolean = state == TileState.RINGING

    fun offlineDevices(counts: FleetCounts): Int =
        maxOf(0, counts.doorStations.total - counts.doorStations.online) +
            maxOf(0, counts.panels.total - counts.panels.online)

    fun headerChips(sosActive: Boolean, offlineDevices: Int, unreadMissed: Int): List<HeaderChip> {
        val chips = ArrayList<HeaderChip>(3)
        if (sosActive) chips.add(HeaderChip.SOS)
        if (offlineDevices > 0) chips.add(HeaderChip.OFFLINE_DEVICES)
        if (unreadMissed > 0) chips.add(HeaderChip.MISSED)
        return chips
    }

    fun sosActive(status: JSONObject?): Boolean =
        status?.optJSONObject("emergency")?.optBoolean("active", false) ?: false

    /** The newest recorded call for [door]; [rows] arrive newest first from Core. */
    fun lastCall(rows: List<CallRow>, door: String): CallRow? = rows.firstOrNull { it.door == door }

    /**
     * The width the tile grid gets: the window less the rail. The home surface shows no call
     * list, so the tiles have the whole content width. Tile columns follow this.
     */
    fun tileAreaWidthDp(window: WindowSpec): Int {
        val rail = if (ScreenLayouts.navStyle(window) == NavStyle.RAIL) RAIL_WIDTH_DP else 0
        return maxOf(0, window.widthDp - rail)
    }

    fun tileColumns(window: WindowSpec, tileCount: Int): Int =
        ScreenLayouts.tileColumns(window.copy(widthDp = tileAreaWidthDp(window)), tileCount)

    /** Grid rows needed for [count] tiles in [columns]. */
    fun tileRows(count: Int, columns: Int): Int =
        if (count <= 0) 0 else (count + maxOf(1, columns) - 1) / maxOf(1, columns)
}
