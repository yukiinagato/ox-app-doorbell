package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HistoryModelTest {

    private fun row(id: String, outcome: String, seen: Boolean) =
        CallRow(id, "c$id", 1L, "front", "", "ja", outcome, "", 0L, "h$id", seen)

    @Test
    fun onlyUnseenMissedCallsAreUnread() {
        assertTrue(HistoryModel.unread(row("1", "missed", false)))
        assertFalse(HistoryModel.unread(row("2", "missed", true)))
        assertFalse(HistoryModel.unread(row("3", "answered", false)))
    }

    @Test
    fun selectionKeepsTheChosenRowAndDefaultsOnlyInTwoPanes() {
        val rows = listOf(row("a", "missed", false), row("b", "answered", true))
        assertEquals("b", HistoryModel.selection(rows, "b", twoPane = true)?.id)
        assertEquals("b", HistoryModel.selection(rows, "b", twoPane = false)?.id)
        // A filtered-out or unknown selection falls back to the newest row beside the list...
        assertEquals("a", HistoryModel.selection(rows, "gone", twoPane = true)?.id)
        assertEquals("a", HistoryModel.selection(rows, "", twoPane = true)?.id)
        // ...and to nothing when the detail would cover the list.
        assertNull(HistoryModel.selection(rows, "gone", twoPane = false))
        assertNull(HistoryModel.selection(emptyList(), "a", twoPane = true))
    }
}
