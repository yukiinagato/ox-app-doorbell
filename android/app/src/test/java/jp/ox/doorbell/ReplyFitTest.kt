package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReplyFitTest {
    private fun wide(c: Char) = c.code in 0x3040..0x9fff

    /** CJK glyphs are 1.0 em, Latin 0.55 em; CJK wraps per character, Latin per word. */
    private fun measurer(text: String, width: Int): (Int) -> ReplyFit.Extent = { size ->
        var lines = 0
        var widest = 0.0
        for (par in text.split("\n")) {
            lines++
            val tokens = if (par.any(::wide)) par.map { it.toString() } else par.split(Regex("(?<= )"))
            var cur = 0.0
            for (tok in tokens) {
                val tw = tok.sumOf { (if (wide(it)) 1.0 else 0.55) * size }
                if (cur + tw > width && cur > 0) { widest = maxOf(widest, cur); lines++; cur = 0.0 }
                cur += tw
            }
            widest = maxOf(widest, cur)
        }
        ReplyFit.Extent(Math.ceil(widest).toInt(), Math.ceil(lines * size * 1.15).toInt())
    }

    private fun fit(text: String, w: Int, h: Int) = ReplyFit.fit(w, h, 28, h, measurer(text, w))

    private fun assertMaximal(text: String, w: Int, h: Int, r: ReplyFit.Result) {
        val at = measurer(text, w)(r.sizePx)
        val next = measurer(text, w)(r.sizePx + 1)
        assertTrue(at.width <= w && at.height <= h)
        assertTrue(r.sizePx >= h || next.width > w || next.height > h)
    }

    @Test fun shortTextFillsBox() {
        val r = fit("OK", 1000, 600)
        assertTrue(r.fits)
        assertTrue(r.sizePx >= 400)
        assertMaximal("OK", 1000, 600, r)
    }

    @Test fun sentencesInThreeLanguagesInLandscapeAndPortrait() {
        for (t in listOf("少々お待ちください", "One moment please, I will be right with you", "请稍等，我马上过来")) {
            for ((w, h) in listOf(1200 to 600, 340 to 500, 700 to 900)) {
                val r = fit(t, w, h)
                assertTrue(r.fits)
                assertMaximal(t, w, h, r)
            }
        }
    }

    @Test fun veryLongTextKeepsTheFloor() {
        val r = fit("あ".repeat(600), 340, 300)
        assertEquals(28, r.sizePx)
        assertFalse(r.fits)
    }

    @Test fun explicitNewlinesAddLines() {
        assertTrue(fit("a\nb\nc\nd", 600, 600).sizePx < fit("a b c d", 600, 600).sizePx)
    }

    @Test fun ceilingIsRespected() {
        assertEquals(20, ReplyFit.fit(10, 10, 10, 20) { ReplyFit.Extent(1, 1) }.sizePx)
    }
}
