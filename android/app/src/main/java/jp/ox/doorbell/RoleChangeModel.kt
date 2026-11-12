// The rules behind the "Change role" form (native settings, This device and Cluster > Devices).
//
// A role is local identity: boot.json holds name, role and door, and Core republishes them as
// devices.<self>.* when it starts. Changing this device therefore persists boot.json and restarts
// Core; changing another device writes devices.<id>.role and .door, which that device applies
// itself. Pure, so the picker and the validation are host-tested.
package jp.ox.doorbell

import org.json.JSONObject

internal object RoleChangeModel {
    const val DOOR_STATION = "door_station"
    const val INDOOR_PANEL = "indoor_panel"

    /** A configured door and, when another door station already serves it, that station's name. */
    data class DoorChoice(val id: String, val servedBy: String) {
        val free: Boolean get() = servedBy.isEmpty()
    }

    enum class Problem { NONE, ROLE, DOOR }

    /** Every configured door, sorted, marked with the other door station bound to it if any. */
    fun doorChoices(config: JSONObject?, deviceId: String): List<DoorChoice> {
        val doors = config?.optJSONObject("doors") ?: return emptyList()
        val devices = config.optJSONObject("devices")
        val owners = HashMap<String, String>()
        devices?.keys()?.forEach { id ->
            if (id == deviceId) return@forEach
            val device = devices.optJSONObject(id) ?: return@forEach
            if (device.optString("role") != DOOR_STATION) return@forEach
            val door = device.optString("door")
            if (door.isNotEmpty() && door != "null")
                owners[door] = device.optString("name").ifEmpty { id.take(8) }
        }
        return doors.keys().asSequence().sorted().map { DoorChoice(it, owners[it].orEmpty()) }.toList()
    }

    /** The doors the picker offers first: configured and served by nobody else. */
    fun freeDoors(config: JSONObject?, deviceId: String): List<String> =
        doorChoices(config, deviceId).filter { it.free }.map { it.id }

    /** The name of another door station already bound to [door], or empty. Warned, not refused. */
    fun otherOwner(config: JSONObject?, deviceId: String, door: String): String =
        doorChoices(config, deviceId).firstOrNull { it.id == door }?.servedBy.orEmpty()

    fun validate(role: String, door: String): Problem = when {
        !BootConfig.validRole(role) -> Problem.ROLE
        role == DOOR_STATION && !BootConfig.validDoor(door.trim()) -> Problem.DOOR
        else -> Problem.NONE
    }

    /** The door a role ends up with: its door for a door station, none for an indoor panel. */
    fun doorFor(role: String, door: String): String = if (role == DOOR_STATION) door.trim() else ""

    fun unchanged(currentRole: String, currentDoor: String, role: String, door: String): Boolean =
        currentRole == role && currentDoor.ifEmpty { "" } == doorFor(role, door)

    /** One batch for another device: the role and its door together, never one without the other. */
    fun ops(deviceId: String, role: String, door: String): List<ConfigOp> = listOf(
        ConfigOp.Set("devices.$deviceId.role", JSONObject.quote(role)),
        ConfigOp.Set("devices.$deviceId.door", JSONObject.quote(doorFor(role, door))),
    )

    /** A role change restarts Core, so it waits for a call or an SOS to end. */
    fun blocked(status: JSONObject?, originatedCallActive: Boolean, incomingShown: Boolean): Boolean =
        originatedCallActive || incomingShown ||
            status?.optJSONObject("sip")?.optString("call") == "in_call" ||
            DashboardModel.sosActive(status)
}
