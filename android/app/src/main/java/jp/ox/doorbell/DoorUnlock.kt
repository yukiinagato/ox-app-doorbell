// The 開錠 control (spec §5.2). Core owns the action and its visibility:
// status.doors.<id>.unlock reports {"configured","command","show_button","source"}, and
// db_core_open_door triggers the configured feature-code path. A shell that shows the button
// when nothing is configured must say so when it is pressed rather than reporting a silent
// success, so the -3 result is surfaced.
package jp.ox.doorbell

import org.json.JSONObject

internal data class DoorUnlock(
    val configured: Boolean,
    val showButton: Boolean,
    /** "admin" when an administrator forced the visibility, "default" when it follows configured. */
    val source: String,
) {
    companion object {
        /** No core answer yet: hide the control rather than offering an action that cannot run. */
        val UNKNOWN = DoorUnlock(configured = false, showButton = false, source = "default")
    }
}

internal object DoorUnlocks {

    /** Read core's answer for one door. Falls back to hidden when status has nothing to say. */
    fun read(status: JSONObject?, door: String): DoorUnlock {
        if (door.isEmpty()) return DoorUnlock.UNKNOWN
        val entry = status?.optJSONObject("doors")?.optJSONObject(door)
            ?.optJSONObject("unlock") ?: return DoorUnlock.UNKNOWN
        val configured = entry.optBoolean("configured", false)
        return DoorUnlock(
            configured = configured,
            showButton = entry.optBoolean("show_button", configured),
            source = entry.optString("source").ifEmpty { "default" },
        )
    }

    /** db_core_open_door results: 0 queued, -3 nothing configured, anything else a failure. */
    const val OK = 0
    const val NOT_CONFIGURED = -3

    fun queued(result: Int): Boolean = result == OK

    fun unconfigured(result: Int): Boolean = result == NOT_CONFIGURED
}
