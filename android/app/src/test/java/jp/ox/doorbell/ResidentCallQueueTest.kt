package jp.ox.doorbell
import org.junit.Assert.*
import org.junit.Test

class ResidentCallQueueTest {
    @Test fun newVisitorDoesNotStealSelectionAndStaleEventsCannotResurrectCalls() {
        val queue = ResidentCallQueue()
        val a = ResidentCallQueue.Item(ResidentCallQueue.Key("front", "a"), 0)
        val b = ResidentCallQueue.Item(ResidentCallQueue.Key("side", "b"), 2)
        queue.admit(a); queue.admit(b); queue.admit(b)
        assertEquals(a.key, queue.selected)
        assertEquals(2, queue.items.size)
        assertEquals(b, queue.select(b.key))
        queue.retire(b.key, 1)
        assertEquals(2, queue.items.size)
        queue.retire(b.key, 2); queue.admit(b)
        assertEquals(listOf(a), queue.items)
        assertEquals(b.key, queue.selected)
        val replacement = b.copy(key = ResidentCallQueue.Key("side", "new-b"), revision = 0)
        queue.admit(replacement)
        assertEquals(b.key, queue.selected)
        assertNull(queue.select(b.key))
    }
}
