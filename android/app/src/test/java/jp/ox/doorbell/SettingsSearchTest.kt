package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsSearchTest {

    @Test
    fun matchingIsTrimmedAndCaseInsensitive() {
        assertTrue(SettingsSearch.matches("", listOf("Sound")))
        assertTrue(SettingsSearch.matches("  sou ", listOf("Sound")))
        assertTrue(SettingsSearch.matches("RING", listOf("Indoor ringtone")))
        assertTrue(SettingsSearch.matches("音量", listOf("サウンド", "通知音量")))
        assertFalse(SettingsSearch.matches("wifi", listOf("Sound", "Volume")))
    }

    @Test
    fun filterKeepsCategoryOrderAndReturnsAllForAnEmptyQuery() {
        val labels = mapOf(
            SettingsCategory.SOUND to listOf("Sound", "Ringtone"),
            SettingsCategory.DISPLAY to listOf("Display", "Ringtone colour"),
        )
        val all = SettingsSearch.filter(" ") { labels[it].orEmpty() }
        assertEquals(SettingsCategory.values().toList(), all)
        assertEquals(
            listOf(SettingsCategory.SOUND, SettingsCategory.DISPLAY),
            SettingsSearch.filter("ringtone") { labels[it].orEmpty() },
        )
        assertTrue(SettingsSearch.filter("nothing") { labels[it].orEmpty() }.isEmpty())
    }
}
