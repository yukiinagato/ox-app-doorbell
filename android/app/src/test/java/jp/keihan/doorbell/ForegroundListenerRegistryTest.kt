package jp.keihan.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression cover for the listener leak: after pairing opened over the main UI, the single
 * listener slot was cleared by the pairing screen and never restored, so chimes and display
 * events stopped reaching the main UI until the process restarted.
 */
class ForegroundListenerRegistryTest {

    private class Recorder : DoorbellCore.Listener {
        val events = ArrayList<String>()
        override fun onUiEvent(ev: JSONObject) { events.add(ev.optString("t")) }
        override fun onTts(text: String, lang: String) = Unit
    }

    @Test
    fun theScreenBelowKeepsReceivingEventsAfterTheOneAboveCloses() {
        val registry = ForegroundListenerRegistry()
        val main = Recorder()
        val pairing = Recorder()

        registry.bind(main)
        assertSame(main, registry.current)

        // Pairing resumes above the main UI, then closes again.
        registry.bind(pairing)
        assertSame(pairing, registry.current)
        registry.unbind(pairing)

        assertSame(main, registry.current)
        registry.current?.onUiEvent(JSONObject().put("t", "chime"))
        assertEquals(listOf("chime"), main.events)
        assertTrue(pairing.events.isEmpty())
    }

    @Test
    fun unbindingABackgroundListenerNeverStealsTheForegroundSlot() {
        val registry = ForegroundListenerRegistry()
        val main = Recorder()
        val pairing = Recorder()

        registry.bind(main)
        registry.bind(pairing)
        // The paused screen below unbinds late; the resumed one above must stay in front.
        registry.unbind(main)

        assertSame(pairing, registry.current)
        assertFalse(registry.isBound(main))
    }

    @Test
    fun rebindingPromotesWithoutDuplicating() {
        val registry = ForegroundListenerRegistry()
        val main = Recorder()
        val pairing = Recorder()

        registry.bind(main)
        registry.bind(pairing)
        registry.bind(main)

        assertSame(main, registry.current)
        assertEquals(2, registry.depth())
        registry.unbind(main)
        assertSame(pairing, registry.current)
        registry.unbind(pairing)
        assertNull(registry.current)
        assertEquals(0, registry.depth())
    }

    @Test
    fun depthIsBoundedSoALeakedActivityCannotGrowTheStack() {
        val registry = ForegroundListenerRegistry()
        repeat(40) { registry.bind(Recorder()) }
        assertTrue(registry.depth() <= 8)
    }
}
