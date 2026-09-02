package jp.keihan.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallRevisionLifecycleTest {
    @Test
    fun answeredRevisionZeroYieldsToPurposeRevisionOneAndItsIdleKeepsRinging() {
        val lifecycle = CallRevisionLifecycle(0)
        lifecycle.beginAnswer()

        assertEquals(CallRevisionUpdate.ANSWER_SUPERSEDED,
            lifecycle.observeWinningRevision(1))
        assertEquals(1, lifecycle.stageRevision)
        assertTrue(lifecycle.consumeSupersededIdle())
        assertFalse(lifecycle.consumeSupersededIdle())
        assertEquals(CallRevisionUpdate.STALE, lifecycle.observeWinningRevision(1))
        assertEquals(CallRevisionUpdate.STALE, lifecycle.observeWinningRevision(0))
    }

    @Test
    fun monitorOnlyRevisionAdvanceDoesNotSuppressItsIdle() {
        val lifecycle = CallRevisionLifecycle(0)

        assertEquals(CallRevisionUpdate.ADVANCED, lifecycle.observeWinningRevision(1))
        assertFalse(lifecycle.consumeSupersededIdle())
    }
}
