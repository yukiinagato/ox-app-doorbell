package jp.ox.doorbell

import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AirSensorPlanTest {

    @Test
    fun parsesCorePlan() {
        val plan = AirSensorPlans.parse(JSONObject("""{"host":true,"scan":true,
            "sensors":[{"id":"s1","address":"aa:bb:cc:dd:ee:ff","kind":"mops_vida_pm25"},
                       {"id":"s2","address":"11:22:33:44:55:66","kind":"other"},
                       {"id":"","address":"x"}],
            "mops_vida_pm25":{"advertised_service":"7676","advertised_name":"测霾单品",
              "service":"6e400001-b5a3-f393-e0a9-e50e24dcca9e",
              "rx":"6e400002-b5a3-f393-e0a9-e50e24dcca9e",
              "tx":"6e400003-b5a3-f393-e0a9-e50e24dcca9e"}}"""))
        assertTrue(plan.host)
        assertTrue(plan.scan)
        assertEquals(listOf(AirSensorTarget("s1", "AA:BB:CC:DD:EE:FF", "mops_vida_pm25")), plan.sensors)
        assertEquals(0x7676, plan.advertisedService16)
        assertEquals(UUID.fromString("00007676-0000-1000-8000-00805f9b34fb"), plan.advertisedServiceUuid)
        assertEquals(AirSensorPlans.DEFAULT_TX, plan.tx)
        assertEquals("测霾单品", plan.advertisedName)
    }

    @Test
    fun missingPlanMeansNoBluetoothWork() {
        val plan = AirSensorPlans.parse(null)
        assertFalse(plan.host)
        assertFalse(plan.scan)
        assertTrue(plan.sensors.isEmpty())
        assertFalse(AirSensorPlans.parse(JSONObject("""{"host":false}""")).host)
    }

    @Test
    fun linkDiffClosesRemovedAndMovedSensors() {
        val changes = AirSensorPlans.linkChanges(
            mapOf("keep" to "A", "moved" to "B", "gone" to "C"),
            listOf(AirSensorTarget("keep", "A", "k"), AirSensorTarget("moved", "B2", "k"),
                   AirSensorTarget("new", "D", "k")),
        )
        assertEquals(setOf("moved", "gone"), changes.close)
        assertEquals(listOf("moved", "new"), changes.open.map { it.id })
    }

    @Test
    fun hexCommandDecodes() {
        assertArrayEquals(byteArrayOf(0xAA.toByte(), 0x01, 0x7f), AirSensorPlans.hexBytes("aa017F"))
        assertEquals(0, AirSensorPlans.hexBytes("abc").size)
        assertEquals(0, AirSensorPlans.hexBytes("zz").size)
        assertEquals(0, AirSensorPlans.hexBytes("").size)
    }

    @Test
    fun advertisementMatchesServiceOrName() {
        val name = "测霾单品".toByteArray(Charsets.UTF_8)
        val record = byteArrayOf(0x02, 0x01, 0x06, 0x03, 0x03, 0x76, 0x76) +
            byteArrayOf((name.size + 1).toByte(), 0x09) + name + byteArrayOf(0, 0, 0)
        val fields = AirSensorPlans.advertising(record)
        assertEquals(setOf(0x7676), fields.services16)
        assertEquals("测霾单品", fields.name)
        val plan = AirSensorPlan.NONE
        assertTrue(AirSensorPlans.matches(plan, fields.services16, ""))
        assertTrue(AirSensorPlans.matches(plan, emptySet(), "测霾单品"))
        assertFalse(AirSensorPlans.matches(plan, setOf(0x180f), "Other"))
        // A truncated structure is ignored rather than read past the end.
        assertTrue(AirSensorPlans.advertising(byteArrayOf(0x05, 0x03, 0x76)).services16.isEmpty())
        assertTrue(AirSensorPlans.advertising(null).services16.isEmpty())
    }

    @Test
    fun reportCarriesOnlyGivenSections() {
        val bare = AirSensorPlans.report("off", null, null)
        assertEquals("off", bare.getString("ble"))
        assertFalse(bare.has("discovered"))
        assertFalse(bare.has("links"))
        val full = AirSensorPlans.report(
            "ready",
            listOf(AirDiscovered("B", "n", -60), AirDiscovered("A", "m", -70)),
            mapOf("s1" to "connected"),
        )
        assertEquals("A", full.getJSONArray("discovered").getJSONObject(0).getString("address"))
        assertEquals(-60, full.getJSONArray("discovered").getJSONObject(1).getInt("rssi"))
        assertEquals("connected", full.getJSONObject("links").getString("s1"))
    }

    @Test
    fun reconnectBacksOffToTwoMinutes() {
        assertEquals(5_000L, AirSensorPlans.reconnectDelayMs(0))
        assertEquals(10_000L, AirSensorPlans.reconnectDelayMs(1))
        assertEquals(120_000L, AirSensorPlans.reconnectDelayMs(10))
    }

    @Test
    fun permissionsFollowTheApiLevel() {
        assertTrue(AirSensorPlans.runtimePermissions(19).isEmpty())
        assertTrue(AirSensorPlans.runtimePermissions(22).isEmpty())
        assertEquals(listOf(AirSensorPlans.PERMISSION_FINE_LOCATION), AirSensorPlans.runtimePermissions(30))
        assertEquals(listOf(AirSensorPlans.PERMISSION_SCAN, AirSensorPlans.PERMISSION_CONNECT),
                     AirSensorPlans.runtimePermissions(34))
    }
}
