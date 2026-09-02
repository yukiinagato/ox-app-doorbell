// Which device serves a door, and where its picture comes from.
//
// Two questions the dashboard tiles ask, kept here so both are host-tested:
//
//   1. Is this door served right now? Core answers with status.doors.<id>.served_by -- the node id
//      of the *alive* door station, or null. A null alone cannot tell "the station is down" from
//      "no station was ever set up", so the peer list and devices.<id> supply the difference.
//   2. Which URL carries its still? The peer's snapshot field when core publishes one, otherwise
//      the snapshot beside its MJPEG stream.
//
// Peer matching mirrors core: a configured devices.<id> role or door wins over what the peer
// advertises, because during commissioning a station announces itself before its configuration
// entry has replicated.
package jp.ox.doorbell

import org.json.JSONObject

/** What a door tile should say about the station behind it. */
internal enum class DoorService {
    /** A live station is serving this door. */
    SERVED,

    /** A station is configured for this door, but none is alive. */
    STATION_OFFLINE,

    /** No device is bound to this door at all. */
    NO_STATION,
}

internal object DoorStations {

    const val ROLE = "door_station"

    /**
     * The service state for one door.
     *
     * Core publishes status.doors.<id>.served_by; when it does, that is the whole answer for
     * "alive or not". An older core has no status.doors, and the peer list is then the only
     * evidence, which is what the tile used before -- so nothing regresses on a core that
     * predates the field.
     */
    fun serviceOf(status: JSONObject?, config: JSONObject?, door: String): DoorService {
        if (door.isEmpty()) return DoorService.NO_STATION
        val doors = status?.optJSONObject("doors")
        val entry = doors?.optJSONObject(door)
        val alive = if (entry != null) servedBy(entry).isNotEmpty()
        else alivePeer(status, config, door) != null
        if (alive) return DoorService.SERVED
        return if (anyStation(status, config, door)) DoorService.STATION_OFFLINE
        else DoorService.NO_STATION
    }

    /** status.doors.<id>.served_by, or an empty string for JSON null, absent, or the text "null". */
    fun servedBy(entry: JSONObject?): String {
        if (entry == null || entry.isNull("served_by")) return ""
        val id = entry.optString("served_by").orEmpty()
        return if (id == "null") "" else id
    }

    /**
     * The peer serving [door], alive only. Used for the still, which is pointless to fetch from a
     * station that is not answering.
     */
    fun alivePeer(status: JSONObject?, config: JSONObject?, door: String): JSONObject? {
        val peer = peerFor(status, config, door) ?: return null
        return if (isAlive(peer)) peer else null
    }

    /** The peer bound to [door] whatever its state, so a dead station is still distinguishable. */
    fun peerFor(status: JSONObject?, config: JSONObject?, door: String): JSONObject? {
        if (door.isEmpty()) return null
        val peers = status?.optJSONArray("peers") ?: return null
        var fallback: JSONObject? = null
        for (index in 0 until peers.length()) {
            val peer = peers.optJSONObject(index) ?: continue
            if (roleOf(config, peer) != ROLE) continue
            if (doorOf(config, peer) != door) continue
            // An alive station wins over a stale duplicate entry for the same door.
            if (isAlive(peer)) return peer
            if (fallback == null) fallback = peer
        }
        return fallback
    }

    /**
     * A peer counts as alive unless core says it is dead or offline. Core's own served_by uses
     * status == "alive"; this stays deliberately looser because it also runs against an older
     * core whose peers carry states this shell has never heard of, and a station that might be
     * reachable is worth one still request.
     */
    fun isAlive(peer: JSONObject?): Boolean {
        val state = peer?.optString("status").orEmpty()
        return state != "dead" && state != "offline"
    }

    /** Whether any device at all is bound to this door, in the peer list or in configuration. */
    fun anyStation(status: JSONObject?, config: JSONObject?, door: String): Boolean {
        if (door.isEmpty()) return false
        if (peerFor(status, config, door) != null) return true
        val devices = config?.optJSONObject("devices") ?: return false
        for (id in devices.keys()) {
            val device = devices.optJSONObject(id) ?: continue
            if (device.optString("role") == ROLE && device.optString("door") == door) return true
        }
        return false
    }

    /**
     * The still URL for a peer: core's snapshot field when it publishes one, else the snapshot
     * that sits beside the MJPEG stream on the same origin. Empty when the peer offers neither,
     * which is a station that has not advertised an address yet.
     */
    fun stillUrl(peer: JSONObject?): String {
        if (peer == null) return ""
        val snapshot = peer.optString("snapshot").orEmpty()
        if (snapshot.isNotEmpty() && snapshot != "null") return snapshot
        val stream = peer.optString("stream").orEmpty()
        if (stream.isEmpty() || stream == "null" || !stream.contains('/')) return ""
        return stream.substringBeforeLast('/') + "/snapshot.jpg"
    }

    /**
     * Why no station matched, for the log. Lists each peer as it was actually resolved, so a
     * door-id mismatch, a role mismatch and a station that is merely down are told apart from the
     * logcat line alone rather than by guessing.
     */
    fun why(status: JSONObject?, config: JSONObject?, door: String): String {
        val peers = status?.optJSONArray("peers")
            ?: return "status carries no peers array (core not reporting yet)"
        if (peers.length() == 0) return "peer list is empty"
        val parts = StringBuilder("want door=\"$door\"; peers:")
        for (index in 0 until peers.length()) {
            val peer = peers.optJSONObject(index) ?: continue
            parts.append(" [id=").append(peer.optString("id"))
                .append(" role=").append(roleOf(config, peer))
                .append(" door=\"").append(doorOf(config, peer))
                .append("\" status=").append(peer.optString("status"))
                .append("]")
        }
        return parts.toString()
    }

    /** A configured role overrides what the peer advertises, exactly as core resolves it. */
    private fun roleOf(config: JSONObject?, peer: JSONObject): String {
        val configured = deviceOf(config, peer)?.optString("role").orEmpty()
        return if (configured.isNotEmpty()) configured else peer.optString("role").orEmpty()
    }

    private fun doorOf(config: JSONObject?, peer: JSONObject): String {
        val configured = deviceOf(config, peer)?.optString("door").orEmpty()
        return if (configured.isNotEmpty()) configured else peer.optString("door").orEmpty()
    }

    private fun deviceOf(config: JSONObject?, peer: JSONObject): JSONObject? {
        val id = peer.optString("id").orEmpty()
        if (id.isEmpty()) return null
        return config?.optJSONObject("devices")?.optJSONObject(id)
    }
}
