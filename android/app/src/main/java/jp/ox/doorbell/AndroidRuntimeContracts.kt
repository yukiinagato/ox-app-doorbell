package jp.ox.doorbell

import android.os.Build
import org.json.JSONArray
import org.json.JSONObject

/** JSON contracts published through core ABI v2. Values are runtime observations, not a SKU claim. */
internal object AndroidRuntimeContracts {
    internal data class OperationalCapabilities(
        val wan: Boolean,
        val mainsPower: Boolean,
        val mqttReachable: Boolean,
    )

    internal data class UiDefaults(
        val foreground: String,
        val background: String,
        val accent: String,
        val border: String,
        val radius: Int,
    )

    internal fun featureManifest(): JSONObject = JSONObject()
        .put("platform_v2", true)
        .put("call_flow_v2", true)
        .put("call_cancel_v2", true)
        .put("call_lifecycle_v2", true)
        .put("device_alert_v1", true)
        .put("ui_manifest_v1", true)
        .put("runtime_recovery_v1", true)
        .put("helper_policy_v1", true)

    internal fun uiProperties(@Suppress("UNUSED_PARAMETER") semanticId: String): Set<String> =
        UiStylePolicy.allProperties

    internal fun deviceAlertChannels(): JSONArray =
        AndroidDeviceAlertChannels.supportedJson()

    internal fun deviceAlertChannelSupport(notificationPermission: String): JSONObject =
        AndroidDeviceAlertChannels.supportJson(notificationPermission)

    internal fun operationalCapabilities(mainsPower: Boolean): OperationalCapabilities =
        OperationalCapabilities(
            // LAN connectivity is not proof that a configured Internet endpoint is reachable.
            wan = false,
            mainsPower = mainsPower,
            mqttReachable = false,
        )

    internal fun uiDefaults(semanticId: String): UiDefaults = when (semanticId) {
        "call.primary" -> UiDefaults("#F2F5F8", "#1E5AA8", "#FFFFFF", "#FFFFFF", 24)
        "cancel.call" -> UiDefaults("#F2F5F8", "#243040", "#4DA3FF", "#8FA0B3", 12)
        "call.end" -> UiDefaults("#FFFFFF", "#B00020", "#FFFFFF", "#FFFFFF", 12)
        "purpose.button" -> UiDefaults("#F2F5F8", "#243040", "#4DA3FF", "#8FA0B3", 12)
        "ring.title" -> UiDefaults("#8FA0B3", "#10151B", "#4DA3FF", "#4DA3FF", 0)
        "ring.action" -> UiDefaults("#4DA3FF", "#243040", "#4DA3FF", "#8FA0B3", 12)
        "reply.button" -> UiDefaults("#F2F5F8", "#243040", "#4DA3FF", "#8FA0B3", 12)
        "monitor.close" -> UiDefaults("#8FA0B3", "#243040", "#4DA3FF", "#8FA0B3", 12)
        "status.offline" -> UiDefaults("#FFFFFF", "#A21B00", "#FFFFFF", "#FFFFFF", 0)
        "sos.trigger", "sos.cancel" ->
            UiDefaults("#FFFFFF", "#B00020", "#FFFFFF", "#FFFFFF", 12)
        else -> UiDefaults("#F2F5F8", "#243040", "#4DA3FF", "#8FA0B3", 12)
    }

    fun capabilities(
        app: App,
        encoder: VideoEncoder.Snapshot,
        decoderState: String,
        persistedEncoderCommissioning: Boolean = false,
        safeMode: Boolean = false,
        legacy19: Boolean = false,
        h264ReleaseQualified: Boolean = !legacy19,
    ): JSONObject {
        val operational = operationalCapabilities(app.core.isOnMainsPower())
        return JSONObject()
            .put("schema_version", 2)
            .put("platform", "android")
            .put("tls12", true)
            .put("wan", operational.wan)
            .put("mains_power", operational.mainsPower)
            .put("mqtt_reachable", operational.mqttReachable)
            .put("wall_clock_sane", System.currentTimeMillis() >= 1_577_836_800_000L)
            .put("cpu_score", 0)
            .put("platform_v2", true)
            .put("call_lifecycle_v2", true)
            .put("secure_store", app.core.secureStoreAvailable)
            .put("sip", true)
            .put("sip_backend", "pjsip")
            .put("emergency_rules_v1", true)
            .put("device_alert_v1", true)
            .put("ui_manifest_v1", true)
            .put("runtime_recovery_v1", true)
            .put("helper_policy_v1", true)
            .put("sos_trigger", true)
            .put("system_notifications", !app.emergencyAlerts.notificationPermissionNeeded())
            .put("device_alert_channels", deviceAlertChannels())
            .put("device_alert_channel_support", deviceAlertChannelSupport(
                app.emergencyAlerts.notificationPermissionStatus(),
            ))
            .put("safe_mode", safeMode)
            .put("android_sdk", Build.VERSION.SDK_INT)
            .put("h264_encode_baseline", (encoder.state == "active" && encoder.certified) ||
                persistedEncoderCommissioning)
            .put("h264_encode_commissioned", (encoder.state == "active" && encoder.certified) ||
                persistedEncoderCommissioning)
            .put("h264_encode_state", if (persistedEncoderCommissioning && encoder.state == "idle")
                "commissioned_idle" else encoder.state)
            .put("h264_release_qualified", h264ReleaseQualified)
            .put("h264_decode_baseline", !safeMode && decoderState == "active")
            .put("h264_decode_state", decoderState)
            .put("features", featureManifest())
    }

    fun uiManifest(): JSONObject {
        val safety = setOf("cancel.call", "call.end", "sos.trigger", "sos.cancel")
        val elements = JSONObject()
        for (id in arrayOf(
            "call.primary", "cancel.call", "call.end", "purpose.button", "ring.title",
            "ring.action", "reply.button", "monitor.close", "status.offline",
            "sos.trigger", "sos.cancel",
        )) {
            val values = uiDefaults(id)
            val defaults = JSONObject()
                .put("scale", 1.0)
                .put("font_scale", 1.0)
                .put("foreground", values.foreground)
                .put("background", values.background)
                .put("accent", values.accent)
                .put("border", values.border)
                .put("radius", values.radius)
            val properties = JSONArray()
            for (property in arrayOf(
                "scale", "font_scale", "foreground", "background", "accent", "border", "radius",
            ))
                if (property in uiProperties(id)) properties.put(property)
            elements.put(id, JSONObject()
                .put("properties", properties)
                .put("defaults", defaults)
                .put("safety_critical", id in safety))
        }
        return JSONObject()
            .put("schema_version", 1)
            .put("units", "dp")
            .put("viewport", JSONObject()
                .put("minimum_touch", 48)
                .put("scale_min", 0.75)
                .put("scale_max", 2.0))
            .put("elements", elements)
    }
}
