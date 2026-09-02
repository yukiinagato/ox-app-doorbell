package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Backwards paging with before_ms (spec §5.5), and the v1 fallback that has no upper bound. */
class HistoryPagingTest {

    /** Rows newest first, one hour apart, starting at a fixed instant. */
    private fun rows(count: Int, startIndex: Int = 0): List<CallRow> {
        val array = JSONArray()
        for (index in startIndex until startIndex + count) {
            array.put(
                JSONObject()
                    .put("id", "o:$index")
                    .put("ts", 1_700_000_000_000L - index * 3_600_000L)
                    .put("door", "d_front")
                    .put("outcome", "answered")
                    .put("hlc", "h$index"),
            )
        }
        return CallHistoryModel.parse(JSONObject().put("rows", array))
    }

    @Test
    fun theNextPageContinuesFromTheOldestRowAlreadyShown() {
        val first = rows(CallHistoryModel.PAGE_SIZE)
        val before = CallHistoryModel.beforeMs(first)
        assertEquals(first.last().tsMs, before)
        // Every row already held is newer than the bound handed to core.
        assertTrue(first.all { it.tsMs >= before })
    }

    @Test
    fun anEmptyListAsksCoreForTheNewestRows() {
        assertEquals(0L, CallHistoryModel.beforeMs(emptyList()))
    }

    @Test
    fun aFullPageMeansThereMayBeMoreAndAShortOneIsTheEnd() {
        assertTrue(CallHistoryModel.hasMoreAfterPage(50, 50))
        assertFalse(CallHistoryModel.hasMoreAfterPage(49, 50))
        assertFalse(CallHistoryModel.hasMoreAfterPage(0, 50))
    }

    @Test
    fun appendingAPageKeepsOrderAndDropsRowsAlreadyHeld() {
        val first = rows(50)
        val second = rows(50, startIndex = 50)
        val merged = CallHistoryModel.append(first, second)
        assertEquals(100, merged.size)
        assertEquals(first.first().id, merged.first().id)
        assertEquals(second.last().id, merged.last().id)
        // Still strictly newest first across the join.
        for (index in 1 until merged.size)
            assertTrue(merged[index - 1].tsMs >= merged[index].tsMs)
    }

    @Test
    fun anOverlappingPageIsDeduplicatedByRowIdentity() {
        val first = rows(50)
        // Two calls in the same millisecond can straddle an exclusive bound.
        val overlapping = rows(50, startIndex = 45)
        val merged = CallHistoryModel.append(first, overlapping)
        assertEquals(95, merged.size)
        assertEquals(merged.size, merged.map { it.id }.toSet().size)
    }

    @Test
    fun anEmptyPageLeavesWhatIsAlreadyShownUntouched() {
        val first = rows(20)
        assertEquals(first, CallHistoryModel.append(first, emptyList()))
    }

    @Test
    fun theV1FallbackStillSlicesAGrowingPrefix() {
        val all = rows(120)
        assertEquals(50, CallHistoryModel.page(all, 1).size)
        assertEquals(100, CallHistoryModel.page(all, 2).size)
        assertEquals(51, CallHistoryModel.requestLimit(1))
        assertTrue(CallHistoryModel.hasMore(51, 1))
        assertFalse(CallHistoryModel.hasMore(50, 1))
    }
}
