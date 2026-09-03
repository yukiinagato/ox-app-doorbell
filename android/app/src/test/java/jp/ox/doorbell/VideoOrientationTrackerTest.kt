package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VideoOrientationTrackerTest {
    @Test fun requiresStableGravityAndIgnoresFlatOrDiagonalSamples() {
        val classifier = GravityOrientationClassifier()
        assertNull(classifier.observe(0.2f, 0.3f))
        assertNull(classifier.observe(6f, 5.5f))
        assertNull(classifier.observe(8f, 1f))
        assertEquals(90, classifier.observe(8.2f, 0.8f))
    }

    @Test fun publishesEachQuarterTurnOnlyAfterItStabilizes() {
        val classifier = GravityOrientationClassifier()
        assertNull(classifier.observe(0f, -9f))
        assertEquals(180, classifier.observe(0.1f, -9.2f))
        assertNull(classifier.observe(0f, -9.4f))
        assertNull(classifier.observe(-9f, 0f))
        assertEquals(270, classifier.observe(-9.1f, 0.1f))
    }
}
