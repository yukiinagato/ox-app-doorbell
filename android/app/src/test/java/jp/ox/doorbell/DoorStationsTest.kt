package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Which device serves a door, and where its picture comes from.
 *
 * Two observed failures are pinned here: a door tile that could not say whether its station was
 * merely down or had never existed, and a still that never loaded because the peer behind the
 * tile was resolved once, at build time, before the station had appeared.
 */
class DoorStationsTest {

    private val door = "door-mini3"
    private val stationId = "n-mini3"

    private fun status(peers: String, doors: String = "{}"): JSONObject =
        JSONObject("""{"peers":$peers,"doors":$doors}""")

    private fun peer(
        id: String = stationId,
        role: String = "door_station",
        door: String = "door-mini3",
        state: String = "alive",
        stream: String = "http://10.10.38.79:47180/stream.mjpeg",
    ) = """{"id":"$id","role":"$role","door":"$door","status":"$state","stream":"$stream"}"""

    // ---------- served_by decides alive ----------

    @Test
    fun aServedDoorReportsServed() {
        val st = status("[${peer()}]", """{"$door":{"served_by":"$stationId"}}""")
        assertEquals(DoorService.SERVED, DoorStations.serviceOf(st, null, door))
    }

    /**
     * served_by null with a station that exists is "the station is offline"; the same null with
     * no station anywhere is "no station". That difference is the whole point of the field.
     */
    @Test
    fun aNullServedByWithAKnownStationIsOffline() {
        val st = status(
            "[${peer(state = "dead")}]",
            """{"$door":{"served_by":null}}""",
        )
        assertEquals(DoorService.STATION_OFFLINE, DoorStations.serviceOf(st, null, door))
    }

    @Test
    fun aNullServedByWithNoStationAnywhereIsNoStation() {
        val st = status("[]", """{"$door":{"served_by":null}}""")
        assertEquals(DoorService.NO_STATION, DoorStations.serviceOf(st, null, door))
    }

    @Test
    fun aStationConfiguredButNeverSeenIsOfflineNotAbsent() {
        val st = status("[]", """{"$door":{"served_by":null}}""")
        val cfg = JSONObject(
            """{"devices":{"$stationId":{"role":"door_station","door":"$door"}}}""",
        )
        assertEquals(DoorService.STATION_OFFLINE, DoorStations.serviceOf(st, cfg, door))
    }

    /** A door station bound to a different door must not rescue this door's tile. */
    @Test
    fun aStationOnAnotherDoorDoesNotCount() {
        val st = status(
            "[${peer(door = "door-front")}]",
            """{"$door":{"served_by":null}}""",
        )
        assertEquals(DoorService.NO_STATION, DoorStations.serviceOf(st, null, door))
    }

    @Test
    fun anIndoorPanelIsNeverAStation() {
        val st = status(
            """[{"id":"n-panel","role":"indoor_panel","door":"$door","status":"alive"}]""",
            """{"$door":{"served_by":null}}""",
        )
        assertEquals(DoorService.NO_STATION, DoorStations.serviceOf(st, null, door))
    }

    @Test
    fun anEmptyDoorIdIsNeverServed() {
        assertEquals(DoorService.NO_STATION, DoorStations.serviceOf(null, null, ""))
    }

    // ---------- an older core with no status.doors ----------

    @Test
    fun withoutStatusDoorsThePeerListDecides() {
        val alive = JSONObject("""{"peers":[${peer()}]}""")
        assertEquals(DoorService.SERVED, DoorStations.serviceOf(alive, null, door))
        val dead = JSONObject("""{"peers":[${peer(state = "dead")}]}""")
        assertEquals(DoorService.STATION_OFFLINE, DoorStations.serviceOf(dead, null, door))
        val none = JSONObject("""{"peers":[]}""")
        assertEquals(DoorService.NO_STATION, DoorStations.serviceOf(none, null, door))
    }

    // ---------- door / peer matching ----------

    @Test
    fun theAlivePeerForADoorIsFoundByRoleAndDoor() {
        val st = status("[${peer(id = "other", door = "door-front")},${peer()}]")
        val found = DoorStations.alivePeer(st, null, door)
        assertNotNull(found)
        assertEquals(stationId, found!!.optString("id"))
    }

    @Test
    fun aDeadStationIsNotAskedForAPicture() {
        val st = status("[${peer(state = "dead")}]")
        assertNull(DoorStations.alivePeer(st, null, door))
        // It is still the door's station, which is what makes the tile say "offline".
        assertNotNull(DoorStations.peerFor(st, null, door))
    }

    @Test
    fun anAlivePeerWinsOverAStaleDuplicateForTheSameDoor() {
        val st = status("[${peer(id = "stale", state = "offline")},${peer()}]")
        assertEquals(stationId, DoorStations.peerFor(st, null, door)!!.optString("id"))
    }

    /**
     * Core lets a configured devices.<id> entry override what a peer advertises, because during
     * commissioning a station announces itself before its configuration has replicated.
     */
    @Test
    fun configuredRoleAndDoorOverrideWhatThePeerAdvertises() {
        val st = status("""[{"id":"$stationId","role":"indoor_panel","status":"alive"}]""")
        val cfg = JSONObject(
            """{"devices":{"$stationId":{"role":"door_station","door":"$door"}}}""",
        )
        assertNotNull(DoorStations.alivePeer(st, cfg, door))
        // Without the configuration it is just an indoor panel with no door.
        assertNull(DoorStations.alivePeer(st, null, door))
    }

    /**
     * The tile is built from the configured door list, which can exist before the station has
     * announced itself. Resolving the peer per refresh -- not once at build time -- is what makes
     * the picture appear when the station shows up, instead of staying blank.
     */
    @Test
    fun aStationThatAppearsAfterItsTileIsPickedUpOnTheNextPass() {
        val before = status("[]", """{"$door":{"served_by":null}}""")
        assertNull(DoorStations.alivePeer(before, null, door))
        assertEquals(DoorService.NO_STATION, DoorStations.serviceOf(before, null, door))

        val after = status("[${peer()}]", """{"$door":{"served_by":"$stationId"}}""")
        val peerNow = DoorStations.alivePeer(after, null, door)
        assertNotNull(peerNow)
        assertEquals(DoorService.SERVED, DoorStations.serviceOf(after, null, door))
        assertEquals(
            "http://10.10.38.79:47180/snapshot.jpg",
            DoorStations.stillUrl(peerNow),
        )
    }

    // ---------- the still URL ----------

    @Test
    fun theStillSitsBesideTheMjpegStream() {
        assertEquals(
            "http://10.10.38.79:47180/snapshot.jpg",
            DoorStations.stillUrl(JSONObject(peer())),
        )
    }

    @Test
    fun anExplicitSnapshotFieldWins() {
        val withSnapshot = JSONObject(
            """{"snapshot":"http://h:1/custom.jpg","stream":"http://h:1/stream.mjpeg"}""",
        )
        assertEquals("http://h:1/custom.jpg", DoorStations.stillUrl(withSnapshot))
    }

    @Test
    fun aStationWithNoAddressYetHasNoStill() {
        assertEquals("", DoorStations.stillUrl(JSONObject("""{"id":"x"}""")))
        assertEquals("", DoorStations.stillUrl(JSONObject("""{"stream":null}""")))
        assertEquals("", DoorStations.stillUrl(null))
    }

    // ---------- served_by reading ----------

    @Test
    fun servedByTreatsNullAndTheTextNullAsUnserved() {
        assertEquals("", DoorStations.servedBy(JSONObject("""{"served_by":null}""")))
        assertEquals("", DoorStations.servedBy(JSONObject("""{"served_by":"null"}""")))
        assertEquals("", DoorStations.servedBy(JSONObject()))
        assertEquals("", DoorStations.servedBy(null))
        assertEquals("n1", DoorStations.servedBy(JSONObject("""{"served_by":"n1"}""")))
    }
}
