package jp.ox.doorbell

import android.os.BatteryManager
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OperationalCapabilityMeasurementTest {
    @Test
    fun wanIsNotInferredFromLocalConnectivityAndMainsUsesMeasuredPower() {
        val powered = AndroidRuntimeContracts.operationalCapabilities(mainsPower = true)
        assertFalse(powered.wan)
        assertTrue(powered.mainsPower)
        assertFalse(powered.mqttReachable)

        val unplugged = AndroidRuntimeContracts.operationalCapabilities(mainsPower = false)
        assertFalse(unplugged.wan)
        assertFalse(unplugged.mainsPower)
    }

    @Test
    fun chargingFullOrPluggedStatesCountAsMainsPower() {
        assertTrue(AndroidPowerMeasurement.isOnMainsPower(
            BatteryManager.BATTERY_STATUS_CHARGING,
            0,
        ))
        assertTrue(AndroidPowerMeasurement.isOnMainsPower(
            BatteryManager.BATTERY_STATUS_FULL,
            0,
        ))
        assertTrue(AndroidPowerMeasurement.isOnMainsPower(
            BatteryManager.BATTERY_STATUS_NOT_CHARGING,
            BatteryManager.BATTERY_PLUGGED_AC,
        ))
        assertFalse(AndroidPowerMeasurement.isOnMainsPower(
            BatteryManager.BATTERY_STATUS_DISCHARGING,
            0,
        ))
    }
}
