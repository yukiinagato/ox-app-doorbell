package jp.keihan.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HelperModePolicyTest {
    @Test
    fun nativeKioskRequiresThreeConsecutiveFailedMeasurements() {
        val tracker = NativeKioskHealthTracker(NativeKioskHealth.UNKNOWN)
        assertEquals(NativeKioskHealth.UNKNOWN, tracker.record(false))
        assertEquals(NativeKioskHealth.UNKNOWN, tracker.record(false))
        assertEquals(NativeKioskHealth.UNHEALTHY, tracker.record(false))
        assertEquals(3, tracker.consecutiveFailures)
        assertEquals(NativeKioskHealth.HEALTHY, tracker.record(true))
        assertEquals(0, tracker.consecutiveFailures)
        assertEquals(NativeKioskHealth.UNKNOWN, tracker.record(false))
    }

    @Test
    fun offNeverUsesTheHelper() {
        for (health in NativeKioskHealth.values()) {
            assertFalse(HelperModePolicy.decide("off", true, health).shouldUseHelper)
        }
    }

    @Test
    fun onForcesTheHelperAndReportsMissingInstallation() {
        assertTrue(
            HelperModePolicy.decide("on", true, NativeKioskHealth.HEALTHY).shouldUseHelper,
        )
        val missing = HelperModePolicy.decide("on", false, NativeKioskHealth.HEALTHY)
        assertTrue(missing.shouldUseHelper)
        assertEquals("helper_unavailable", missing.targetEffective)
    }

    @Test
    fun autoUsesAnInstalledHelperOnlyForUnavailableOrUnhealthyNativeKiosk() {
        for (health in listOf(NativeKioskHealth.UNKNOWN, NativeKioskHealth.HEALTHY)) {
            assertFalse(HelperModePolicy.decide("auto", true, health).shouldUseHelper)
        }
        for (health in listOf(NativeKioskHealth.UNAVAILABLE, NativeKioskHealth.UNHEALTHY)) {
            assertTrue(HelperModePolicy.decide("auto", true, health).shouldUseHelper)
            assertFalse(HelperModePolicy.decide("auto", false, health).shouldUseHelper)
        }
    }

    @Test
    fun missingDefaultsToAutoButArbitraryInputFailsClosedToOff() {
        val missing = HelperModePolicy.decide(null, true, NativeKioskHealth.UNHEALTHY)
        assertEquals("auto", missing.configured)
        assertTrue(missing.configValid)
        assertTrue(missing.shouldUseHelper)

        val invalid = HelperModePolicy.decide("shell", true, NativeKioskHealth.UNHEALTHY)
        assertEquals("off", invalid.configured)
        assertFalse(invalid.configValid)
        assertFalse(invalid.shouldUseHelper)
    }
}
