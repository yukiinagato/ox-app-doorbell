// How many devices the cluster has, and how many of each kind are answering (spec §4.1).
//
// The dashboard header used to say "cluster - 3 devices - 3 connected", which tells a resident
// how many boxes exist but not which kind is missing. The counters answer the question actually
// being asked at a glance: are my door stations up, and are my panels up.
//
// Counted from status.peers, which core fills with every device it knows -- alive peers, peers it
// has lost, and devices that are configured but have never announced -- plus this node itself when
// core has not listed it.
package jp.ox.doorbell

import org.json.JSONObject

/** Online-out-of-total for one kind of device. */
internal data class RoleCount(val online: Int, val total: Int)

internal data class FleetCounts(
    /** Every device in the cluster, whatever its role and whether or not it is answering. */
    val devices: Int,
    val doorStations: RoleCount,
    val panels: RoleCount,
)

internal object FleetCounting {

    /**
     * [selfRole] and [selfId] describe this node, so it is counted exactly once: core normally
     * lists it among the peers with self=true, and a shell that asks before that has landed would
     * otherwise report one device fewer than there are.
     */
    fun of(
        status: JSONObject?,
        config: JSONObject?,
        selfRole: String,
        selfId: String,
    ): FleetCounts {
        var devices = 0
        var doorsOnline = 0
        var doors = 0
        var panelsOnline = 0
        var panels = 0
        var sawSelf = false

        val peers = status?.optJSONArray("peers")
        if (peers != null) for (index in 0 until peers.length()) {
            val peer = peers.optJSONObject(index) ?: continue
            val id = peer.optString("id").orEmpty()
            // This node is running, whatever a stale peer entry for it happens to say.
            val self = peer.optBoolean("self", false) || (selfId.isNotEmpty() && id == selfId)
            if (self) sawSelf = true
            devices++
            // Every other device is online exactly when core says so, which is the same single
            // liveness source core resolves served_by from. DoorStations.isAlive stays looser --
            // an unrecognised state is worth one still request there -- but a counter that says
            // "2/2 answering" must not reach that number on a state nobody recognises.
            val online = self || peer.optString("status") == ALIVE
            when (DoorStations.roleOf(config, peer)) {
                DoorStations.ROLE -> { doors++; if (online) doorsOnline++ }
                PANEL -> { panels++; if (online) panelsOnline++ }
            }
        }

        if (!sawSelf) {
            devices++
            when (selfRole) {
                DoorStations.ROLE -> { doors++; doorsOnline++ }
                PANEL -> { panels++; panelsOnline++ }
            }
        }
        return FleetCounts(devices, RoleCount(doorsOnline, doors), RoleCount(panelsOnline, panels))
    }

    const val PANEL = "indoor_panel"

    private const val ALIVE = "alive"
}
