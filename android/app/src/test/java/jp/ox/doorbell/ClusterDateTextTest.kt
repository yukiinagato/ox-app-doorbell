package jp.ox.doorbell

import java.io.File
import java.util.Locale
import java.util.TimeZone
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Test

class ClusterDateTextTest {
    private fun catalog(language: String): Map<String, String> {
        val directory = if (language == "en") "values" else "values-$language"
        val relative = "src/main/res/$directory/strings.xml"
        val file = listOf(File(relative), File("app/$relative")).first { it.isFile }
        val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(file).getElementsByTagName("string")
        return (0 until nodes.length).associate {
            val node = nodes.item(it)
            node.attributes.getNamedItem("name").nodeValue to node.textContent
        }
    }

    private fun display(language: String, date: String, weekday: Int): String {
        val strings = catalog(language)
        return ClusterDateText.format(date, weekday) { key, args ->
            String.format(Locale.US, strings.getValue(key.replace('.', '_')), *args)
        }
    }

    @Test fun languageChangesUpdateTheSameCoreDateImmediately() {
        assertEquals("2026年09月22日 (火)", display("ja", "2026-09-22", 2))
        assertEquals("2026-09-22 (Tue)", display("en", "2026-09-22", 2))
        assertEquals("2026年09月22日（二）", display("zh", "2026-09-22", 2))
        assertEquals("2026年09月22日 (火)", display("ja", "2026-09-22", 2))
    }

    @Test fun deviceZoneCannotChangeTheCoreCalendarDate() {
        val original = TimeZone.getDefault()
        try {
            for (zone in listOf("Pacific/Honolulu", "Asia/Tokyo", "Pacific/Kiritimati")) {
                TimeZone.setDefault(TimeZone.getTimeZone(zone))
                assertEquals("2026-01-01 (Thu)", display("en", "2026-01-01", 4))
            }
        } finally { TimeZone.setDefault(original) }
    }

    @Test fun midnightAndCalendarChangesHaveNoCachedWeekday() {
        assertEquals("2026-09-22 (Tue)", display("en", "2026-09-22", 2))
        assertEquals("2026-09-23 (Wed)", display("en", "2026-09-23", 3))
        assertEquals("2026年09月23日（三）", display("zh", "2026-09-23", 3))
    }

    @Test fun unavailableCoreCalendarIsPreservedWithoutAnOsClockFallback() {
        assertEquals("", display("en", "", 0))
        assertEquals("unknown", display("ja", "unknown", 0))
    }
}
