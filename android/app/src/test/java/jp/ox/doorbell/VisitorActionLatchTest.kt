package jp.ox.doorbell

import org.junit.Assert.*
import org.junit.Test

class VisitorActionLatchTest {
    @Test fun aHeldCancelNeverBecomesAnEndAction() {
        val latch = VisitorActionLatch()
        latch.begin(VisitorCallAction("one", CallUiPhase.RINGING))
        assertNull(latch.consume(VisitorCallAction("one", CallUiPhase.ESTABLISHED)))
    }

    @Test fun aHeldActionCannotAddressAReplacementCall() {
        val latch = VisitorActionLatch()
        latch.begin(VisitorCallAction("one", CallUiPhase.RINGING))
        assertNull(latch.consume(VisitorCallAction("two", CallUiPhase.RINGING)))
    }

    @Test fun accessibilityActivationUsesTheCurrentlyDisplayedAction() {
        val latch = VisitorActionLatch()
        val action = VisitorCallAction("one", CallUiPhase.ESTABLISHED)
        assertEquals(action, latch.consume(action))
        latch.begin(action)
        assertEquals(action, latch.consume(action))
    }

    @Test fun confirmedSosUsesTheSlideCountdownAndCanBeCancelled() {
        val slide = SosSlideState(3)
        slide.begin(); slide.drag(1f)
        val accessible = SosSlideState(3)
        assertEquals(slide.release(), accessible.confirm())
        assertEquals(accessible.snapshot(), accessible.confirm())
        assertFalse(accessible.tick().fireNow)
        assertEquals(SosPhase.IDLE, accessible.cancel().phase)
        repeat(5) { assertFalse(accessible.tick().fireNow) }
    }

    @Test fun confirmedZeroCountdownFiresOnceJustLikeACompletedSlide() {
        val state = SosSlideState(0)
        assertTrue(state.confirm().fireNow)
        assertFalse(state.confirm().fireNow)
        assertFalse(state.tick().fireNow)
    }
}
