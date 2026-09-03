package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The indoor incoming page's return-to-home countdown (batch 3). */
class ReturnCountdownTest {

    @Test
    fun itCountsDownAndThenReturnsHome() {
        val countdown = ReturnCountdown(3)
        assertEquals("(3)", countdown.snapshot().suffix)
        assertEquals("(2)", countdown.tick().suffix)
        assertEquals("(1)", countdown.tick().suffix)
        val last = countdown.tick()
        assertTrue(last.shouldReturnHome)
        assertEquals(ReturnPhase.ELAPSED, last.phase)
        // Nothing is appended once it has elapsed, and it does not go negative.
        assertEquals("", last.suffix)
        assertEquals(0, countdown.tick().secondsLeft)
    }

    @Test
    fun tappingTheNumberStopsTheCountdownAndKeepsThePage() {
        val countdown = ReturnCountdown(60)
        countdown.tick()
        val cancelled = countdown.cancelByUser()
        assertEquals(ReturnPhase.CANCELLED, cancelled.phase)
        // No suffix, no ticking, and nothing ever closes the page.
        assertEquals("", cancelled.suffix)
        assertFalse(cancelled.ticking)
        assertFalse(cancelled.shouldReturnHome)
        assertFalse(countdown.tick().shouldReturnHome)
        assertEquals(ReturnPhase.CANCELLED, countdown.snapshot().phase)
    }

    @Test
    fun aVisitorCancellingTheCallDoesNotCloseThePage() {
        // The live view has to stay up so the resident can still see who was there.
        val countdown = ReturnCountdown(10)
        countdown.tick()
        val afterCancel = countdown.onVisitorCancelled()
        assertEquals(ReturnPhase.RUNNING, afterCancel.phase)
        assertEquals(9, afterCancel.secondsLeft)
        assertFalse(afterCancel.shouldReturnHome)
        // It still closes when the countdown eventually runs out.
        repeat(9) { countdown.tick() }
        assertTrue(countdown.snapshot().shouldReturnHome)
    }

    @Test
    fun answeringPausesTheCountdownAndHidesTheSuffix() {
        val countdown = ReturnCountdown(60)
        countdown.tick()
        val paused = countdown.pauseForCall()
        assertEquals(ReturnPhase.PAUSED, paused.phase)
        assertEquals("", paused.suffix)
        assertFalse(paused.ticking)
        // Talking never pulls the page away.
        repeat(120) { countdown.tick() }
        assertFalse(countdown.snapshot().shouldReturnHome)
    }

    @Test
    fun endingTheCallRestartsFromTheFullValueNotTheRemainder() {
        val countdown = ReturnCountdown(60)
        repeat(50) { countdown.tick() }
        assertEquals(10, countdown.snapshot().secondsLeft)
        countdown.pauseForCall()
        val resumed = countdown.resumeAfterCall()
        assertEquals(ReturnPhase.RUNNING, resumed.phase)
        assertEquals(60, resumed.secondsLeft)
        assertEquals("(60)", resumed.suffix)
    }

    @Test
    fun aCancelledCountdownIsNotRevivedByACall() {
        val countdown = ReturnCountdown(60)
        countdown.cancelByUser()
        assertEquals(ReturnPhase.CANCELLED, countdown.pauseForCall().phase)
        assertEquals(ReturnPhase.CANCELLED, countdown.resumeAfterCall().phase)
        assertFalse(countdown.snapshot().ticking)
    }

    @Test
    fun anElapsedCountdownStaysElapsed() {
        val countdown = ReturnCountdown(1)
        assertTrue(countdown.tick().shouldReturnHome)
        assertEquals(ReturnPhase.ELAPSED, countdown.pauseForCall().phase)
        assertEquals(ReturnPhase.ELAPSED, countdown.cancelByUser().phase)
    }

    @Test
    fun theLengthComesFromStatusThenConfigurationThenSixtySeconds() {
        assertEquals(60, ReturnCountdown.secondsFrom(null, null))
        assertEquals(
            45,
            ReturnCountdown.secondsFrom(JSONObject("""{"call":{"return_s":45}}"""), null),
        )
        assertEquals(
            30,
            ReturnCountdown.secondsFrom(null, JSONObject("""{"call":{"indoor":{"return_s":30}}}""")),
        )
        // Status wins over configuration when core publishes it.
        assertEquals(
            45,
            ReturnCountdown.secondsFrom(
                JSONObject("""{"call":{"return_s":45}}"""),
                JSONObject("""{"call":{"indoor":{"return_s":30}}}"""),
            ),
        )
        // Nonsense falls back rather than producing a page that never leaves or leaves at once.
        assertEquals(
            60,
            ReturnCountdown.secondsFrom(JSONObject("""{"call":{"return_s":0}}"""), null),
        )
        assertEquals(
            ReturnCountdown.MAX_SECONDS,
            ReturnCountdown.secondsFrom(JSONObject("""{"call":{"return_s":99999}}"""), null),
        )
    }

    @Test
    fun theSuffixIsOnlyEverShownWhileRunning() {
        val countdown = ReturnCountdown(5)
        assertEquals("(5)", countdown.snapshot().suffix)
        countdown.pauseForCall()
        assertEquals("", countdown.snapshot().suffix)
        countdown.resumeAfterCall()
        assertEquals("(5)", countdown.snapshot().suffix)
        countdown.cancelByUser()
        assertEquals("", countdown.snapshot().suffix)
    }
}
