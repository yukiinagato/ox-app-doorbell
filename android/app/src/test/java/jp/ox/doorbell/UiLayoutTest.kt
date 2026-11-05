package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UiLayoutTest {

    private fun w(width: Int, height: Int = 800, font: Float = 1f) = WindowSpec(width, height, font)

    @Test
    fun sizeClassBoundariesFollowTheGuidelines() {
        assertEquals(SizeClass.COMPACT, SizeClass.fromWidthDp(0))
        assertEquals(SizeClass.COMPACT, SizeClass.fromWidthDp(599))
        assertEquals(SizeClass.MEDIUM, SizeClass.fromWidthDp(600))
        assertEquals(SizeClass.MEDIUM, SizeClass.fromWidthDp(899))
        assertEquals(SizeClass.EXPANDED, SizeClass.fromWidthDp(900))
        assertEquals(SizeClass.EXPANDED, SizeClass.fromWidthDp(2000))
    }

    @Test
    fun windowSpecDerivesOrientationAndLargeText() {
        assertTrue(w(800, 400).landscape)
        assertFalse(w(400, 800).landscape)
        assertFalse(w(400, 800, 1.3f).largeText)
        assertTrue(w(400, 800, 1.5f).largeText)
        assertTrue(w(400, 800, 2f).largeText)
    }

    @Test
    fun purposeColumnsShrinkAtLargeText() {
        assertEquals(2, ScreenLayouts.purposeColumns(w(400)))
        assertEquals(3, ScreenLayouts.purposeColumns(w(700)))
        assertEquals(4, ScreenLayouts.purposeColumns(w(1000)))
        assertEquals(1, ScreenLayouts.purposeColumns(w(400, font = 2f)))
        assertEquals(3, ScreenLayouts.purposeColumns(w(1000, font = 2f)))
    }

    @Test
    fun tileColumnsFitTheWindowAndTheDoorCount() {
        assertEquals(1, ScreenLayouts.tileColumns(w(400), 6))
        assertEquals(2, ScreenLayouts.tileColumns(w(700), 6))
        assertEquals(3, ScreenLayouts.tileColumns(w(1000), 6))
        assertEquals(4, ScreenLayouts.tileColumns(w(1300), 6))
        assertEquals(2, ScreenLayouts.tileColumns(w(1300, font = 2f), 6))
        assertEquals(1, ScreenLayouts.tileColumns(w(700, font = 2f), 6))
        // Never more columns than doors, never fewer than one.
        assertEquals(2, ScreenLayouts.tileColumns(w(1300), 2))
        assertEquals(1, ScreenLayouts.tileColumns(w(1300), 0))
    }

    @Test
    fun navigationIsTabsOnCompactAndARailAbove() {
        assertEquals(NavStyle.BOTTOM_TABS, ScreenLayouts.navStyle(w(599)))
        assertEquals(NavStyle.RAIL, ScreenLayouts.navStyle(w(600)))
        assertEquals(NavStyle.RAIL, ScreenLayouts.navStyle(w(1200)))
    }

    @Test
    fun incomingCallGoesSideBySideOnlyInWideLandscape() {
        assertFalse(ScreenLayouts.incomingSideBySide(w(400, 800)))
        // A landscape phone (compact width) keeps the stacked layout.
        assertFalse(ScreenLayouts.incomingSideBySide(w(560, 360)))
        assertTrue(ScreenLayouts.incomingSideBySide(w(800, 400)))
        assertFalse(ScreenLayouts.incomingSideBySide(w(800, 1200)))
        assertEquals(0.6f, ScreenLayouts.incomingVideoFraction(w(1000, 600)), 0f)
        assertEquals(0.65f, ScreenLayouts.incomingVideoFraction(w(1280, 800)), 0f)
        assertEquals(ActionEdge.END, ScreenLayouts.actionEdge(true))
        assertEquals(ActionEdge.BOTTOM, ScreenLayouts.actionEdge(false))
    }

    @Test
    fun sheetsAndPanesFollowTheSizeClass() {
        assertFalse(ScreenLayouts.replySheetAtSide(w(400)))
        assertTrue(ScreenLayouts.replySheetAtSide(w(600)))
        assertFalse(ScreenLayouts.historyTwoPane(w(599)))
        assertTrue(ScreenLayouts.historyTwoPane(w(600)))
        assertFalse(ScreenLayouts.monitorSideList(w(899)))
        assertTrue(ScreenLayouts.monitorSideList(w(900)))
    }

    @Test
    fun touchTargetsNeverDropBelowTheirFloor() {
        assertEquals(48, ScreenLayouts.touchTargetDp(w(400)))
        assertEquals(48, ScreenLayouts.touchTargetDp(w(400, font = 1.3f)))
        assertEquals(72, ScreenLayouts.touchTargetDp(w(400, font = 2f)))
        // Font scale beyond 200 % does not keep growing the control.
        assertEquals(72, ScreenLayouts.touchTargetDp(w(400, font = 3f)))
        assertEquals(72, ScreenLayouts.touchTargetDp(w(400), UiTokens.VISITOR_TOUCH_MIN_DP))
        assertEquals(72, ScreenLayouts.visitorActionHeightDp(w(400)))
        assertEquals(88, ScreenLayouts.visitorActionHeightDp(w(400, font = 2f)))
        assertEquals(96, ScreenLayouts.visitorActionHeightDp(w(1000)))
        assertTrue(ScreenLayouts.visitorActionHeightDp(w(400)) >= UiTokens.VISITOR_TOUCH_MIN_DP)
    }

    @Test
    fun secondaryActionsWrapIntoOrderedRows() {
        assertEquals(4, ScreenLayouts.secondaryPerRow(w(1000)))
        assertEquals(3, ScreenLayouts.secondaryPerRow(w(400)))
        assertEquals(2, ScreenLayouts.secondaryPerRow(w(400, font = 2f)))
        assertEquals(
            listOf(listOf(1, 2), listOf(3, 4), listOf(5)),
            ScreenLayouts.rows(listOf(1, 2, 3, 4, 5), 2),
        )
        assertEquals(listOf(listOf(1, 2, 3)), ScreenLayouts.rows(listOf(1, 2, 3), 0))
        assertEquals(emptyList<List<Int>>(), ScreenLayouts.rows(emptyList<Int>(), 3))
    }

    @Test
    fun rolesTakeCoreAccentAndKeepReadableInk() {
        for (palette in listOf(Palette.LIGHT, Palette.DARK)) {
            val plain = UiRoles.from(palette)
            assertEquals(palette.accent, plain.fill(ActionRole.PRIMARY))
            assertEquals(palette.surface, plain.fill(ActionRole.SECONDARY))
            assertEquals(palette.danger, plain.fill(ActionRole.NEGATIVE))
            for (role in ActionRole.values()) {
                val ratio = UiContrast.contrast(plain.fill(role), plain.ink(role))
                assertTrue("$role on ${if (palette.dark) "dark" else "light"}: $ratio", ratio >= 4.5)
            }
            val core = UiRoles.from(palette, 0x123456 to 0xFFFFFF)
            assertEquals(0x123456, core.fill(ActionRole.PRIMARY))
            assertEquals(0xFFFFFF, core.ink(ActionRole.PRIMARY))
        }
    }
}
