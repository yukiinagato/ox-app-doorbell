package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject

internal data class DeviceAlertChannelResult(
    val channel: String,
    val requested: Boolean,
    val applied: Boolean,
    val rejected: Boolean,
    val unsupported: Boolean,
    val permission: String,
    val result: String,
    val visualApplied: Boolean = false,
    val soundApplied: Boolean = false,
    val stickyApplied: Boolean = false,
    val ttlSeconds: Int = 0,
    val limitation: String = "",
) {
    fun toJson(): JSONObject = JSONObject()
        .put("channel", channel)
        .put("requested", requested)
        .put("applied", applied)
        .put("rejected", rejected)
        .put("unsupported", unsupported)
        .put("permission", permission)
        .put("result", result)
        .put("visual_applied", visualApplied)
        .put("sound_applied", soundApplied)
        .put("sticky_applied", stickyApplied)
        .put("ttl_s", ttlSeconds)
        .also { if (limitation.isNotEmpty()) it.put("limitation", limitation) }
}

/** Canonical Android support and delivery-result contract for device_alert channels. */
internal object AndroidDeviceAlertChannels {
    const val IN_APP = "in_app"
    const val SYSTEM_NOTIFICATION = "system_notification"
    const val WEB_PUSH = "web_push"

    const val PERMISSION_GRANTED = "granted"
    const val PERMISSION_DENIED = "denied"
    const val PERMISSION_REQUIRED = "required"
    const val PERMISSION_NOT_REQUIRED = "not_required"
    const val PERMISSION_NOT_APPLICABLE = "not_applicable"

    private val supported = listOf(IN_APP, SYSTEM_NOTIFICATION)

    fun supportedJson(): JSONArray = JSONArray(supported)

    fun supportJson(notificationPermission: String): JSONObject = JSONObject()
        .put("schema_version", 1)
        .put("channels", JSONObject()
            .put(IN_APP, supportEntry(
                supported = true,
                available = true,
                permission = PERMISSION_NOT_REQUIRED,
            ))
            .put(SYSTEM_NOTIFICATION, supportEntry(
                supported = true,
                available = notificationPermission == PERMISSION_GRANTED ||
                    notificationPermission == PERMISSION_NOT_REQUIRED,
                permission = notificationPermission,
            ))
            .put(WEB_PUSH, supportEntry(
                supported = false,
                available = false,
                permission = PERMISSION_NOT_APPLICABLE,
                limitation = "unsupported_on_android_native",
            )))

    fun notRequested(channel: String, permission: String): DeviceAlertChannelResult =
        DeviceAlertChannelResult(
            channel = channel,
            requested = false,
            applied = false,
            rejected = false,
            unsupported = channel == WEB_PUSH,
            permission = permission,
            result = if (channel == WEB_PUSH) "unsupported" else "not_requested",
            limitation = if (channel == WEB_PUSH) "unsupported_on_android_native" else "",
        )

    fun unsupportedWebPush(requested: Boolean): DeviceAlertChannelResult =
        DeviceAlertChannelResult(
            channel = WEB_PUSH,
            requested = requested,
            applied = false,
            rejected = false,
            unsupported = true,
            permission = PERMISSION_NOT_APPLICABLE,
            result = "unsupported",
            limitation = "unsupported_on_android_native",
        )

    fun report(
        value: EmergencyPresentation,
        summaryResult: String,
        restored: Boolean,
        statePersisted: Boolean,
        channelResults: List<DeviceAlertChannelResult>,
        updatedAtMs: Long,
    ): JSONObject {
        val results = JSONArray()
        channelResults.forEach { results.put(it.toJson()) }
        return JSONObject()
            .put("schema_version", 1)
            .put("active", value.active)
            .put("event_hlc", value.eventHlc)
            .put("result", summaryResult)
            .put("restored", restored)
            .put("state_persisted", statePersisted)
            // Keep the schema-v1 requested-channel summary for existing Admin consumers.
            .put("channels", JSONArray(value.channels.toList().sorted()))
            .put("channel_results", results)
            .put("updated_at_ms", updatedAtMs)
    }

    fun expired(results: List<DeviceAlertChannelResult>): List<DeviceAlertChannelResult> =
        results.map { current ->
            if (!current.requested || current.unsupported) current
            else current.copy(
                result = if (current.applied) "ttl_expired" else current.result,
                visualApplied = false,
                soundApplied = false,
                stickyApplied = false,
            )
        }

    private fun supportEntry(
        supported: Boolean,
        available: Boolean,
        permission: String,
        limitation: String = "",
    ): JSONObject = JSONObject()
        .put("status", if (supported) "supported" else "unsupported")
        .put("supported", supported)
        .put("available", available)
        .put("permission", permission)
        .also { if (limitation.isNotEmpty()) it.put("limitation", limitation) }
}
