package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The three header counters: how many devices the cluster has, and how many door stations and
 * indoor panels are answering.
 */
class FleetCountsTest {

    private val selfId = "n-self"

    private fun peer(
        id: String,
        role: String,
        state: String = "alive",
        self: Boolean = false,
    ) = """{"id":"$id","role":"$role","status":"$state","self":$self}"""

    private fun status(vararg peers: String): JSONObject =
        JSONObject("""{"peers":[${peers.joinToString(",")}]}""")

    private fun counts(status: JSONObject?, config: JSONObject? = null,
                       role: String = "indoor_panel") =
        FleetCounting.of(status, config, role, selfId)

    @Test
    fun aClusterOfThreeIsCountedByRole() {
        val result = counts(status(
            peer(selfId, "indoor_panel", self = true),
            peer("n-panel2", "indoor_panel"),
            peer("n-door", "door_station"),
        ))
        assertEquals(3, result.devices)
        assertEquals(RoleCount(1, 1), result.doorStations)
        assertEquals(RoleCount(2, 2), result.panels)
    }

    @Test
    fun aDeviceThatIsNotAnsweringCountsInTheTotalButNotAsOnline() {
        val result = counts(status(
            peer(selfId, "indoor_panel", self = true),
            peer("n-panel2", "indoor_panel", state = "offline"),
            peer("n-door", "door_station", state = "dead"),
            peer("n-door2", "door_station"),
        ))
        assertEquals(4, result.devices)
        assertEquals(RoleCount(1, 2), result.doorStations)
        assertEquals(RoleCount(1, 2), result.panels)
    }

    /** Core normally lists this node among the peers; asking before that must not lose it. */
    @Test
    fun thisNodeIsCountedExactlyOnce() {
        val listed = counts(status(peer(selfId, "indoor_panel", self = true)))
        assertEquals(1, listed.devices)
        assertEquals(RoleCount(1, 1), listed.panels)

        val notListed = counts(status(peer("n-door", "door_station")))
        assertEquals(2, notListed.devices)
        assertEquals(RoleCount(1, 1), notListed.panels)
        assertEquals(RoleCount(1, 1), notListed.doorStations)
    }

    @Test
    fun thisNodeIsMatchedByIdWhenCoreDidNotFlagIt() {
        val result = counts(status(peer(selfId, "indoor_panel")))
        assertEquals(1, result.devices)
        assertEquals(RoleCount(1, 1), result.panels)
    }

    /** A stale entry saying this node is offline cannot be right: it is the one running. */
    @Test
    fun thisNodeIsAlwaysOnline() {
        val result = counts(status(peer(selfId, "indoor_panel", state = "offline", self = true)))
        assertEquals(RoleCount(1, 1), result.panels)
    }

    @Test
    fun aConfiguredRoleOverridesWhatThePeerAdvertises() {
        val config = JSONObject(
            """{"devices":{"n-x":{"role":"door_station","door":"d1"}}}""",
        )
        val result = counts(status(
            peer(selfId, "indoor_panel", self = true),
            peer("n-x", "indoor_panel"),
        ), config)
        assertEquals(2, result.devices)
        assertEquals(RoleCount(1, 1), result.doorStations)
        assertEquals(RoleCount(1, 1), result.panels)
    }

    @Test
    fun aRoleNobodyHasCountsZero() {
        val result = counts(status(peer(selfId, "indoor_panel", self = true)))
        assertEquals(RoleCount(0, 0), result.doorStations)
    }

    @Test
    fun anEmptyOrAbsentStatusStillCountsThisDevice() {
        for (status in listOf(null, JSONObject(), JSONObject("""{"peers":[]}"""))) {
            val result = counts(status, role = "door_station")
            assertEquals(1, result.devices)
            assertEquals(RoleCount(1, 1), result.doorStations)
            assertEquals(RoleCount(0, 0), result.panels)
        }
    }

    /** A role the shell does not know is still a device in the cluster. */
    @Test
    fun anUnknownRoleCountsAsADeviceOnly() {
        val result = counts(status(
            peer(selfId, "indoor_panel", self = true),
            peer("n-kiosk", "kiosk"),
        ))
        assertEquals(2, result.devices)
        assertEquals(RoleCount(0, 0), result.doorStations)
        assertEquals(RoleCount(1, 1), result.panels)
    }
}
