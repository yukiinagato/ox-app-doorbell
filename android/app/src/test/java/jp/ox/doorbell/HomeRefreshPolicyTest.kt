package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Test

/** How often the home screen may rebuild itself while core emits peers_changed per heartbeat. */
class HomeRefreshPolicyTest {

    @Test
    fun theFirstRefreshRunsImmediately() {
        assertEquals(0L, HomeRefreshPolicy.delayMs(lastRunMs = 0L, nowMs = 12_345L))
    }

    @Test
    fun aRefreshInsideTheWindowWaitsForTheRestOfIt() {
        assertEquals(700L, HomeRefreshPolicy.delayMs(lastRunMs = 1_000L, nowMs = 1_300L))
        assertEquals(1L, HomeRefreshPolicy.delayMs(lastRunMs = 1_000L, nowMs = 1_999L))
    }

    @Test
    fun aRefreshAfterTheWindowRunsImmediately() {
        assertEquals(0L, HomeRefreshPolicy.delayMs(lastRunMs = 1_000L, nowMs = 2_000L))
        assertEquals(0L, HomeRefreshPolicy.delayMs(lastRunMs = 1_000L, nowMs = 90_000L))
    }

    /**
     * A burst of events inside one window collapses to a single later refresh: each of them asks
     * for the same instant, and the caller only ever has one refresh queued.
     */
    @Test
    fun aBurstOfEventsAsksForOneRefreshAtTheSameInstant() {
        val lastRun = 5_000L
        val due = listOf(5_010L, 5_100L, 5_500L, 5_900L)
            .map { it + HomeRefreshPolicy.delayMs(lastRun, it) }
        assertEquals(listOf(6_000L, 6_000L, 6_000L, 6_000L), due)
    }

    /** A monotonic reading cannot really go backwards; treat it as due rather than as a long wait. */
    @Test
    fun aReadingThatWentBackwardsIsDue() {
        assertEquals(0L, HomeRefreshPolicy.delayMs(lastRunMs = 9_000L, nowMs = 1_000L))
    }

    @Test
    fun theWindowIsConfigurable() {
        assertEquals(4_500L, HomeRefreshPolicy.delayMs(1_000L, 1_500L, minIntervalMs = 5_000L))
    }
}
