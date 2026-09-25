package jp.ox.doorbell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RuntimeGenerationTest {
    @Test
    fun priorSuccessfulAndFailedRefreshesAreStaleAfterRestart() {
        val generation = RuntimeGeneration()
        val prior = generation.begin()
        assertTrue(generation.isCurrent(prior))

        val restarted = generation.begin()
        assertFalse(generation.isCurrent(prior))
        assertTrue(generation.isCurrent(restarted))

        val failedRefreshGeneration = restarted
        generation.begin()
        assertFalse(generation.isCurrent(failedRefreshGeneration))
    }

    @Test
    fun delayedUiWorkFromPreviousCoreCannotBecomeCurrent() {
        val generation = RuntimeGeneration()
        val delayedUiGeneration = generation.begin()
        generation.begin()

        assertFalse(generation.isCurrent(delayedUiGeneration))
    }

    @Test
    fun repeatedIdentityRestartsRetireEveryPriorRefresh() {
        val generation = RuntimeGeneration()
        val prior = ArrayList<Long>()
        repeat(100) {
            prior += generation.begin()
        }

        val current = generation.begin()
        assertTrue(generation.isCurrent(current))
        prior.forEach { assertFalse(generation.isCurrent(it)) }
    }
}
