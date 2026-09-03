package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The clock anchor.
 *
 * db_core_local_time_json is a synchronous round trip onto core's run loop. Called once a second
 * from the main thread it made the dashboard clock advance in three-second jumps on the Moto,
 * because each tick waited behind whatever the loop was doing. The tick now projects from the
 * last anchor and the monotonic clock, and the anchor is renewed on a worker.
 */
class ClusterClockMathTest {

    private fun anchor(wallMs: Long = 1_700_000_000_000L, elapsedMs: Long = 10_000L) =
        TimeAnchor(wallMs, elapsedMs, offsetMin = 540, zone = "Asia/Tokyo", known = true)

    // ---------- projecting ----------

    @Test
    fun theClockAdvancesWithTheMonotonicClock() {
        val a = anchor()
        assertEquals(a.wallMs, ClusterClockMath.projectedWallMs(a, 10_000L))
        assertEquals(a.wallMs + 1_000L, ClusterClockMath.projectedWallMs(a, 11_000L))
        assertEquals(a.wallMs + 25_000L, ClusterClockMath.projectedWallMs(a, 35_000L))
    }

    /** One second of monotonic time is one second on the label, which is the whole fix. */
    @Test
    fun everySecondOfRealTimeIsOneSecondOnTheLabel() {
        val a = anchor()
        var previous = ClusterClockMath.projectedWallMs(a, 10_000L)
        for (tick in 1..30) {
            val now = ClusterClockMath.projectedWallMs(a, 10_000L + tick * 1_000L)
            assertEquals(1_000L, now - previous)
            previous = now
        }
    }

    // ---------- when core is asked again ----------

    @Test
    fun noAnchorIsAlwaysStale() {
        assertTrue(ClusterClockMath.stale(null, 0L))
        assertTrue(ClusterClockMath.stale(null, 999_999L))
    }

    @Test
    fun anAnchorIsTrustedForThirtySecondsAndThenRenewed() {
        val a = anchor()
        assertFalse(ClusterClockMath.stale(a, 10_000L))
        assertFalse(ClusterClockMath.stale(a, 10_000L + 29_999L))
        assertTrue(ClusterClockMath.stale(a, 10_000L + 30_000L))
        assertTrue(ClusterClockMath.stale(a, 10_000L + 60_000L))
    }

    @Test
    fun theRefreshIntervalIsThirtySeconds() {
        assertEquals(30_000L, ClusterClockMath.MAX_AGE_MS)
    }

    /** The monotonic clock cannot run backwards, so an anchor from the future is not usable. */
    @Test
    fun anAnchorFromTheFutureIsStale() {
        assertTrue(ClusterClockMath.stale(anchor(elapsedMs = 50_000L), 10_000L))
    }

    @Test
    fun aCallerMayAskForItsOwnMaximumAge() {
        val a = anchor()
        assertFalse(ClusterClockMath.stale(a, 10_500L, maxAgeMs = 1_000L))
        assertTrue(ClusterClockMath.stale(a, 11_000L, maxAgeMs = 1_000L))
        // Zero forces a refresh, which is what a time_changed event asks for.
        assertTrue(ClusterClockMath.stale(a, 10_000L, maxAgeMs = 0L))
    }
}
