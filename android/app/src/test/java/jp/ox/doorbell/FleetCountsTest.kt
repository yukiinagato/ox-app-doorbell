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
    fun aLiveAdvertisedRoleOverridesStaleConfiguration() {
        val config = JSONObject(
            """{"devices":{"n-x":{"role":"door_station","door":"d1"}}}""",
        )
        val result = counts(status(
            peer(selfId, "indoor_panel", self = true),
            peer("n-x", "indoor_panel"),
        ), config)
        assertEquals(2, result.devices)
        assertEquals(RoleCount(0, 0), result.doorStations)
        assertEquals(RoleCount(2, 2), result.panels)
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

    /** Device-verified payload: peers keyed by name, one dead door, a remote alive panel. */
    @Test
    fun theDeviceReportedClusterCountsBothPanelsOnline() {
        val result = FleetCounting.of(
            JSONObject(
                """{"peers":[
                    {"name":"ipad1-monitor","role":"indoor_panel","status":"alive","self":false},
                    {"name":"doorbell-ios","role":"door_station","status":"dead"},
                    {"name":"doorbell-android","role":"indoor_panel","status":"alive","self":true}
                ]}""",
            ),
            null,
            "indoor_panel",
            "doorbell-android",
        )
        assertEquals(3, result.devices)
        assertEquals(RoleCount(0, 1), result.doorStations)
        assertEquals(RoleCount(2, 2), result.panels)
    }

    /**
     * The document db_core_status_json actually returns on the Moto G64y, field for field: peers
     * carry both an id and a name, and this node is flagged. It counts the same as the one
     * /api/status returns, because both come from one builder in core.
     */
    @Test
    fun theDeviceStatusDocumentCountsTheSameAsTheAdministrationApi() {
        val result = FleetCounting.of(
            JSONObject(
                """{"peers":[
                    {"id":"75cd2ca1a972de0d6672cd2730f284b5","name":"ipad1-monitor",
                     "role":"indoor_panel","status":"alive","self":false},
                    {"id":"787e91b5a11d87d5ac77f232afac84c0","name":"doorbell-ios",
                     "role":"door_station","status":"dead","self":false},
                    {"id":"8e98f79ed7837aa221a48e2e4e4a1c0a","name":"doorbell-android",
                     "role":"indoor_panel","status":"alive","self":true}
                ]}""",
            ),
            null,
            "indoor_panel",
            "8e98f79ed7837aa221a48e2e4e4a1c0a",
        )
        assertEquals(3, result.devices)
        assertEquals(RoleCount(0, 1), result.doorStations)
        assertEquals(RoleCount(2, 2), result.panels)
    }

    /**
     * The reported misreading, reconstructed from the same cluster at startup: before the mesh has
     * heard from either remote device they come from the configured-devices fallback, which core
     * writes as "offline" with the configured role. Counting that gives "3 - 0/1 - 1/2" exactly.
     * The header was wrong because it kept showing this document, not because it counted it wrongly.
     */
    @Test
    fun theStartupStatusDocumentIsTheReportedMisreading() {
        val result = FleetCounting.of(
            JSONObject(
                """{"peers":[
                    {"id":"75cd2ca1a972de0d6672cd2730f284b5","name":"ipad1-monitor",
                     "role":"indoor_panel","status":"offline","self":false},
                    {"id":"787e91b5a11d87d5ac77f232afac84c0","name":"doorbell-ios",
                     "role":"door_station","status":"offline","self":false},
                    {"id":"8e98f79ed7837aa221a48e2e4e4a1c0a","name":"doorbell-android",
                     "role":"indoor_panel","status":"alive","self":true}
                ]}""",
            ),
            null,
            "indoor_panel",
            "8e98f79ed7837aa221a48e2e4e4a1c0a",
        )
        assertEquals(3, result.devices)
        assertEquals(RoleCount(0, 1), result.doorStations)
        assertEquals(RoleCount(1, 2), result.panels)
    }

    /**
     * Observed on the device a second after launch: a peer the mesh has seen but whose advertised
     * role has not arrived. It is a device in the cluster, and belongs to no role total until
     * something names its role.
     */
    @Test
    fun aPeerWhoseRoleHasNotArrivedYetCountsAsADeviceOnly() {
        val result = FleetCounting.of(
            JSONObject(
                """{"peers":[
                    {"id":"75cd2ca1a972de0d6672cd2730f284b5","name":"ipad1-monitor",
                     "role":"","status":"alive","self":false},
                    {"id":"8e98f79ed7837aa221a48e2e4e4a1c0a","name":"doorbell-android",
                     "role":"indoor_panel","status":"alive","self":true}
                ]}""",
            ),
            null,
            "indoor_panel",
            "8e98f79ed7837aa221a48e2e4e4a1c0a",
        )
        assertEquals(2, result.devices)
        assertEquals(RoleCount(1, 1), result.panels)
    }

    /** Configuration supplies the role the mesh has not advertised yet, and the panel counts. */
    @Test
    fun theStartupDocumentCountsBothPanelsOnceConfigurationNamesTheRole() {
        val result = FleetCounting.of(
            JSONObject(
                """{"peers":[
                    {"id":"75cd2ca1a972de0d6672cd2730f284b5","name":"ipad1-monitor",
                     "role":"","status":"alive","self":false},
                    {"id":"8e98f79ed7837aa221a48e2e4e4a1c0a","name":"doorbell-android",
                     "role":"indoor_panel","status":"alive","self":true}
                ]}""",
            ),
            JSONObject(
                """{"devices":{"75cd2ca1a972de0d6672cd2730f284b5":{"role":"indoor_panel"}}}""",
            ),
            "indoor_panel",
            "8e98f79ed7837aa221a48e2e4e4a1c0a",
        )
        assertEquals(2, result.devices)
        assertEquals(RoleCount(2, 2), result.panels)
    }

    /**
     * Only core's own "alive" counts as answering. A state this shell does not recognise is not
     * evidence that a device is up, and the header must not claim it is.
     */
    @Test
    fun aPeerInAnUnrecognisedStateIsNotCountedAsAnswering() {
        val result = counts(status(
            peer(selfId, "indoor_panel", self = true),
            peer("n-panel2", "indoor_panel", state = "joining"),
            """{"id":"n-door","role":"door_station"}""",
        ))
        assertEquals(3, result.devices)
        assertEquals(RoleCount(0, 1), result.doorStations)
        assertEquals(RoleCount(1, 2), result.panels)
    }
}
