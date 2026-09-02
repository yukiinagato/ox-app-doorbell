package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The monitor-leg backoff, from the storm seen on the iPad 1 door station: an indoor panel opened
 * a monitor dialog roughly 1.5 times a second for 39 s, each ending with RTP tx=0 rx=0.
 */
class MonitorBackoffTest {

    @Test
    fun aDeadDialogDoublesTheWaitUpToTheCap() {
        val backoff = MonitorBackoff()
        var now = 0L
        assertEquals(1_000L, backoff.onDeadDialog(now))
        assertEquals(2_000L, backoff.onDeadDialog(now))
        assertEquals(4_000L, backoff.onDeadDialog(now))
        assertEquals(8_000L, backoff.onDeadDialog(now))
        assertEquals(16_000L, backoff.onDeadDialog(now))
        // Capped, and it stays capped however long the door keeps failing.
        assertEquals(30_000L, backoff.onDeadDialog(now))
        repeat(20) { now += 1 }
        assertEquals(30_000L, backoff.onDeadDialog(now))
        assertEquals(MonitorBackoff.CAP_MS, backoff.currentDelayMs())
    }

    @Test
    fun theStormIsBoundedInsteadOfUnbounded() {
        // 39 s of the observed behaviour was ~58 dialogs. With backoff, the same window allows a
        // handful: 1 + 2 + 4 + 8 + 16 s covers it with five retries.
        val backoff = MonitorBackoff()
        var now = 0L
        var attempts = 0
        val deadline = 39_000L
        while (now <= deadline) {
            if (!backoff.mayStart(now)) { now += 100; continue }
            attempts += 1
            backoff.onDeadDialog(now)
            now += 100
        }
        assertTrue("expected a handful of attempts, got $attempts", attempts in 2..8)
    }

    @Test
    fun mediaFlowingClearsTheBackoff() {
        val backoff = MonitorBackoff()
        backoff.onDeadDialog(0L)
        backoff.onDeadDialog(0L)
        assertEquals(2, backoff.failureCount)
        backoff.onMediaFlowed()
        assertEquals(0, backoff.failureCount)
        assertEquals(0L, backoff.currentDelayMs())
        assertTrue(backoff.mayStart(0L))
    }

    @Test
    fun aRefusedDialogIsTreatedLikeADeadOne() {
        val backoff = MonitorBackoff()
        assertEquals(1_000L, backoff.onRefused(0L))
        assertEquals(2_000L, backoff.onRefused(0L))
        assertFalse(backoff.mayStart(0L))
    }

    @Test
    fun aDoorWithNoAudioIsNeverRetried() {
        val backoff = MonitorBackoff()
        backoff.onNoAudioCapability()
        assertEquals(MonitorStop.NO_AUDIO, backoff.stopReason)
        assertFalse(backoff.mayStart(0L))
        assertFalse(backoff.mayStart(Long.MAX_VALUE / 2))
        assertEquals(-1L, backoff.retryDelayMs(0L))
        // Not even the operator toggling it can revive that.
        backoff.onToggledOff()
        backoff.onToggledOn()
        assertEquals(MonitorStop.NO_AUDIO, backoff.stopReason)
        assertFalse(backoff.mayStart(0L))
    }

    @Test
    fun nothingIsRetriedWhileTheToggleIsOff() {
        val backoff = MonitorBackoff()
        backoff.onToggledOff()
        assertEquals(MonitorStop.TOGGLE_OFF, backoff.stopReason)
        assertFalse(backoff.mayStart(0L))
        assertEquals(-1L, backoff.retryDelayMs(0L))
        backoff.onToggledOn()
        assertEquals(MonitorStop.NONE, backoff.stopReason)
        assertTrue(backoff.mayStart(0L))
    }

    @Test
    fun theToggleDoesNotWipeAnAccumulatedDelay() {
        // A door failing a moment ago is still probably failing; a toggle is not evidence of a fix.
        val backoff = MonitorBackoff()
        backoff.onDeadDialog(0L)
        backoff.onDeadDialog(0L)
        backoff.onToggledOff()
        backoff.onToggledOn()
        assertEquals(2, backoff.failureCount)
        assertFalse(backoff.mayStart(0L))
        assertTrue(backoff.mayStart(2_000L))
    }

    @Test
    fun theWaitIsMeasuredFromWhenTheDialogFailed() {
        val backoff = MonitorBackoff()
        backoff.onDeadDialog(10_000L)
        assertFalse(backoff.mayStart(10_500L))
        assertTrue(backoff.mayStart(11_000L))
        assertEquals(500L, backoff.retryDelayMs(10_500L))
        assertEquals(0L, backoff.retryDelayMs(11_000L))
    }

    @Test
    fun aDialogCountsAsAliveWhenEitherDirectionCarriedMedia() {
        assertFalse(MonitorBackoff.carriedMedia(0L, 0L))
        assertTrue(MonitorBackoff.carriedMedia(1L, 0L))
        assertTrue(MonitorBackoff.carriedMedia(0L, 1L))
        assertTrue(MonitorBackoff.carriedMedia(160L, 160L))
    }

    @Test
    fun aFreshBackoffAllowsTheFirstAttemptImmediately() {
        val backoff = MonitorBackoff()
        assertTrue(backoff.mayStart(0L))
        assertEquals(0L, backoff.currentDelayMs())
        assertEquals(MonitorStop.NONE, backoff.stopReason)
    }
}
