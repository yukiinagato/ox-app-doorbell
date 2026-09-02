package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidUiManifestTest {
    @Test
    fun capabilitiesPublishShellFeaturesInTheVersionedMap() {
        val features = AndroidRuntimeContracts.featureManifest()
        for (feature in listOf(
            "platform_v2", "call_flow_v2", "call_cancel_v2", "device_alert_v1",
            "call_lifecycle_v2", "ui_manifest_v1", "runtime_recovery_v1", "helper_policy_v1",
        )) assertTrue("missing nested feature $feature", features.getBoolean(feature))
        assertEquals(8, features.length())
    }

    @Test
    fun sosControlsAreSafetyCriticalAndTouchFloorIs48Dp() {
        val manifest = AndroidRuntimeContracts.uiManifest()
        assertEquals("dp", manifest.getString("units"))
        assertEquals(48, manifest.getJSONObject("viewport").getInt("minimum_touch"))
        val elements = manifest.getJSONObject("elements")
        assertTrue(elements.getJSONObject("sos.trigger").getBoolean("safety_critical"))
        assertTrue(elements.getJSONObject("sos.cancel").getBoolean("safety_critical"))
        val ids = elements.keys()
        while (ids.hasNext()) {
            val element = elements.getJSONObject(ids.next())
            val properties = element.getJSONArray("properties")
            val supported = (0 until properties.length()).map(properties::getString).toSet()
            assertEquals(UiStylePolicy.allProperties, supported)
            val defaults = element.getJSONObject("defaults")
            assertEquals(supported.size, defaults.length())
            assertEquals(1.0, defaults.getDouble("scale"), 0.0)
            assertEquals(1.0, defaults.getDouble("font_scale"), 0.0)
            val keys = defaults.keys()
            while (keys.hasNext()) assertTrue(keys.next() in supported)
            val foreground = defaults.optString("foreground")
            val background = defaults.optString("background")
            val accent = defaults.optString("accent")
            val border = defaults.optString("border")
            if (foreground.isNotEmpty()) assertTrue(UiStylePolicy.parseRgb(foreground) != null)
            if (background.isNotEmpty()) assertTrue(UiStylePolicy.parseRgb(background) != null)
            if (foreground.isNotEmpty() && background.isNotEmpty()) assertTrue(
                UiStylePolicy.contrast(
                    UiStylePolicy.parseRgb(foreground)!!,
                    UiStylePolicy.parseRgb(background)!!,
                ) >= 4.5,
            )
            assertTrue(UiStylePolicy.contrast(
                UiStylePolicy.parseRgb(accent)!!,
                UiStylePolicy.parseRgb(background)!!,
            ) >= 3.0)
            assertTrue(UiStylePolicy.contrast(
                UiStylePolicy.parseRgb(border)!!,
                UiStylePolicy.parseRgb(background)!!,
            ) >= 3.0)
            assertTrue(defaults.getDouble("radius") in 0.0..64.0)
        }
        val sos = elements.getJSONObject("sos.trigger").getJSONObject("defaults")
        assertEquals("#FFFFFF", sos.getString("foreground"))
        assertEquals("#B00020", sos.getString("background"))
        assertEquals(7, elements.getJSONObject("ring.title")
            .getJSONArray("properties").length())
        assertEquals(7, elements.getJSONObject("status.offline")
            .getJSONArray("properties").length())
    }
}
