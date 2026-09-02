package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceAlertChannelContractTest {
    @Test
    fun capabilitiesPublishOnlyNativeChannelsAndExplicitlyRejectWebPush() {
        val supported = AndroidRuntimeContracts.deviceAlertChannels()
        assertEquals(2, supported.length())
        assertEquals("in_app", supported.getString(0))
        assertEquals("system_notification", supported.getString(1))

        val support = AndroidRuntimeContracts.deviceAlertChannelSupport(
            AndroidDeviceAlertChannels.PERMISSION_REQUIRED,
        ).getJSONObject("channels")
        assertTrue(support.getJSONObject("in_app").getBoolean("supported"))
        assertTrue(support.getJSONObject("in_app").getBoolean("available"))
        val notification = support.getJSONObject("system_notification")
        assertTrue(notification.getBoolean("supported"))
        assertFalse(notification.getBoolean("available"))
        assertEquals("required", notification.getString("permission"))
        val webPush = support.getJSONObject("web_push")
        assertEquals("unsupported", webPush.getString("status"))
        assertFalse(webPush.getBoolean("supported"))
        assertFalse(webPush.getBoolean("available"))
        assertEquals("not_applicable", webPush.getString("permission"))
    }

    @Test
    fun runtimeReportKeepsLegacySummaryAndAddsMeasuredChannelResults() {
        val value = EmergencyPresentation(
            active = true,
            eventHlc = "50:0:a",
            channels = setOf("in_app", "web_push"),
        )
        val results = listOf(
            DeviceAlertChannelResult(
                channel = "in_app",
                requested = true,
                applied = true,
                rejected = false,
                unsupported = false,
                permission = "not_required",
                result = "presented",
                visualApplied = true,
                stickyApplied = true,
            ),
            AndroidDeviceAlertChannels.notRequested("system_notification", "granted"),
            AndroidDeviceAlertChannels.unsupportedWebPush(requested = true),
        )
        val report = AndroidDeviceAlertChannels.report(
            value,
            summaryResult = "in_app",
            restored = false,
            statePersisted = true,
            channelResults = results,
            updatedAtMs = 123_456L,
        )

        assertEquals(1, report.getInt("schema_version"))
        assertEquals("in_app", report.getString("result"))
        assertTrue(report.getBoolean("state_persisted"))
        assertEquals(2, report.getJSONArray("channels").length())
        assertEquals(3, report.getJSONArray("channel_results").length())
        val inApp = report.getJSONArray("channel_results").getJSONObject(0)
        assertTrue(inApp.getBoolean("requested"))
        assertTrue(inApp.getBoolean("applied"))
        assertFalse(inApp.getBoolean("rejected"))
        assertFalse(inApp.getBoolean("unsupported"))
        assertEquals("not_required", inApp.getString("permission"))
        val webPush = report.getJSONArray("channel_results").getJSONObject(2)
        assertTrue(webPush.getBoolean("requested"))
        assertFalse(webPush.getBoolean("applied"))
        assertFalse(webPush.getBoolean("rejected"))
        assertTrue(webPush.getBoolean("unsupported"))
        assertEquals("unsupported", webPush.getString("result"))
        assertEquals(123_456L, report.getLong("updated_at_ms"))
    }

    @Test
    fun rejectionAndExpiryRemainDistinctFromUnsupported() {
        val permissionRejected = DeviceAlertChannelResult(
            channel = "system_notification",
            requested = true,
            applied = false,
            rejected = true,
            unsupported = false,
            permission = "required",
            result = "rejected",
            limitation = "notification_permission_required",
        )
        val webPush = AndroidDeviceAlertChannels.unsupportedWebPush(requested = true)
        val applied = DeviceAlertChannelResult(
            channel = "in_app",
            requested = true,
            applied = true,
            rejected = false,
            unsupported = false,
            permission = "not_required",
            result = "presented",
            visualApplied = true,
        )

        val expired = AndroidDeviceAlertChannels.expired(
            listOf(applied, permissionRejected, webPush),
        )
        assertEquals("ttl_expired", expired[0].result)
        assertFalse(expired[0].visualApplied)
        assertEquals("rejected", expired[1].result)
        assertTrue(expired[1].rejected)
        assertEquals("unsupported", expired[2].result)
        assertTrue(expired[2].unsupported)
    }
}
