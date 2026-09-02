package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure batch-2 logic: labels, appearance, announcements, history paging, and the SOS slide. */
class BatchTwoModelTest {

    // ---------- deliberate two-part labels ----------

    @Test
    fun aLabelWithoutABreakStaysOneLine() {
        val label = TwoPartLabels.split("スライドで SOS")
        assertEquals("スライドで SOS", label.primary)
        assertEquals("", label.secondary)
        assertFalse(label.hasSecondary)
    }

    @Test
    fun theAuthoredBreakSplitsIntoAPrimaryAndASmallerSecondLine() {
        val label = TwoPartLabels.split("スライドで SOS\n3 秒後に発報")
        assertEquals("スライドで SOS", label.primary)
        assertEquals("3 秒後に発報", label.secondary)
        assertEquals(0.8f, TwoPartLabels.SECONDARY_SCALE, 1e-6f)
    }

    @Test
    fun onlyTheFirstBreakSplits() {
        val label = TwoPartLabels.split("a\nb\nc")
        assertEquals("a", label.primary)
        assertEquals("b c", label.secondary)
    }

    @Test
    fun windowsAndClassicMacBreaksAreAccepted() {
        assertEquals("a", TwoPartLabels.split("a\r\nb").primary)
        assertEquals("b", TwoPartLabels.split("a\r\nb").secondary)
        assertEquals("b", TwoPartLabels.split("a\rb").secondary)
    }

    @Test
    fun twoCatalogEntriesCombineAndAnOverrideWithItsOwnBreakWins() {
        assertEquals(
            TwoPartLabel("スライドで SOS", "3 秒後に発報"),
            TwoPartLabels.of("スライドで SOS", "3 秒後に発報"),
        )
        assertEquals(
            TwoPartLabel("上書き", "その二行目"),
            TwoPartLabels.of("上書き\nその二行目", "無視される"),
        )
        assertEquals(TwoPartLabel("一行だけ", ""), TwoPartLabels.of("一行だけ", "   "))
    }

    @Test
    fun flatteningIsUsedForAccessibilityAndTightControls() {
        assertEquals("A — B", TwoPartLabels.flatten(TwoPartLabel("A", "B")))
        assertEquals("A", TwoPartLabels.flatten(TwoPartLabel("A", "")))
    }

    // ---------- appearance ----------

    @Test
    fun explicitAppearancesIgnoreTheSystemAndTheSchedule() {
        assertFalse(Appearance.isDark(AppearanceMode.LIGHT, true, 23 * 60, 19 * 60, 390))
        assertTrue(Appearance.isDark(AppearanceMode.DARK, false, 12 * 60, 19 * 60, 390))
    }

    @Test
    fun autoSystemFollowsThePlatformAndFallsBackToTheScheduleWithoutOne() {
        assertTrue(Appearance.isDark(AppearanceMode.AUTO_SYSTEM, true, 12 * 60, 19 * 60, 390))
        assertFalse(Appearance.isDark(AppearanceMode.AUTO_SYSTEM, false, 23 * 60, 19 * 60, 390))
        // Android below API 29 reports null, so the cluster schedule decides instead.
        assertTrue(Appearance.isDark(AppearanceMode.AUTO_SYSTEM, null, 23 * 60, 19 * 60, 390))
        assertFalse(Appearance.isDark(AppearanceMode.AUTO_SYSTEM, null, 12 * 60, 19 * 60, 390))
    }

    @Test
    fun theScheduleWindowWrapsPastMidnight() {
        val darkFrom = 19 * 60
        val lightFrom = 6 * 60 + 30
        assertTrue(Appearance.inDarkWindow(19 * 60, darkFrom, lightFrom))
        assertTrue(Appearance.inDarkWindow(23 * 60 + 59, darkFrom, lightFrom))
        assertTrue(Appearance.inDarkWindow(0, darkFrom, lightFrom))
        assertTrue(Appearance.inDarkWindow(6 * 60 + 29, darkFrom, lightFrom))
        assertFalse(Appearance.inDarkWindow(6 * 60 + 30, darkFrom, lightFrom))
        assertFalse(Appearance.inDarkWindow(12 * 60, darkFrom, lightFrom))
        // A window that does not wrap still behaves as a half-open range.
        assertTrue(Appearance.inDarkWindow(9 * 60, 8 * 60, 10 * 60))
        assertFalse(Appearance.inDarkWindow(10 * 60, 8 * 60, 10 * 60))
        // An empty window is never dark.
        assertFalse(Appearance.inDarkWindow(8 * 60, 8 * 60, 8 * 60))
    }

    @Test
    fun clockTimesAreParsedStrictly() {
        assertEquals(19 * 60, Appearance.parseClock("19:00"))
        assertEquals(6 * 60 + 30, Appearance.parseClock("06:30"))
        assertNull(Appearance.parseClock("24:00"))
        assertNull(Appearance.parseClock("19:60"))
        assertNull(Appearance.parseClock("1900"))
        assertNull(Appearance.parseClock(null))
    }

    @Test
    fun theDeviceOverrideWinsOverTheClusterAppearance() {
        val config = JSONObject(
            """
            {"display":{"appearance":"dark",
                        "appearance_schedule":{"dark_from":"19:00","light_from":"06:30"}},
             "devices":{"n1":{"local":{"display":{"appearance":"light"}}}}}
            """.trimIndent(),
        )
        assertFalse(Appearance.resolve(config, "n1", null, 23 * 60).dark)
        assertTrue(Appearance.resolve(config, "other", null, 23 * 60).dark)
    }

    @Test
    fun bothPalettesKeepReadableTextOverTheirOwnSurfaces() {
        for (palette in listOf(Palette.LIGHT, Palette.DARK)) {
            assertTrue(UiContrast.contrast(palette.ink, palette.surface) >= 4.5)
            assertTrue(UiContrast.contrast(palette.ink, palette.ground) >= 4.5)
            assertTrue(UiContrast.contrast(palette.accentInk, palette.accent) >= 4.5)
            assertTrue(UiContrast.contrast(palette.noticeInk, palette.noticeBg) >= 4.5)
            assertTrue(UiContrast.contrast(palette.dangerInk, palette.dangerSoft) >= 4.5)
            assertTrue(UiContrast.contrast(palette.muted, palette.surface) >= 3.0)
        }
    }

    // ---------- announcements ----------

    private fun noticeConfig(doorText: String?, globalText: String?, expires: Long): JSONObject {
        val root = JSONObject()
        val doors = JSONObject()
        val front = JSONObject()
        if (doorText != null) front.put(
            "notice",
            JSONObject().put("text", doorText).put("expires_ms", expires)
                .put("from_device", "ipad1").put("created_ms", 1L),
        )
        doors.put("d_front", front)
        doors.put("d_back", JSONObject())
        root.put("doors", doors)
        if (globalText != null) root.put(
            "notice",
            JSONObject().put(
                "global",
                JSONObject().put("text", globalText).put("expires_ms", 0L),
            ),
        )
        return root
    }

    @Test
    fun aDoorSpecificAnnouncementWinsOverTheGlobalOne() {
        val config = noticeConfig("裏口へお回りください", "ただいま留守にしています", 0L)
        val effective = NoticeModel.effective(config, "d_front", 1_000L)
        assertNotNull(effective)
        assertEquals("裏口へお回りください", effective!!.text)
        assertTrue(effective.doorSpecific)
        // A door without its own value still shows the cluster-wide announcement.
        assertEquals(
            "ただいま留守にしています",
            NoticeModel.effective(config, "d_back", 1_000L)!!.text,
        )
    }

    @Test
    fun anExpiredDoorAnnouncementFallsBackToTheGlobalOne() {
        val config = noticeConfig("期限切れ", "全体のお知らせ", expires = 500L)
        assertEquals("全体のお知らせ", NoticeModel.effective(config, "d_front", 1_000L)!!.text)
        // Before the deadline the door value is still the one that shows.
        assertEquals("期限切れ", NoticeModel.effective(config, "d_front", 400L)!!.text)
    }

    @Test
    fun zeroMeansUntilCleared() {
        val notice = Notice("text", "n1", 0L, 0L, doorSpecific = true)
        assertTrue(notice.activeAt(Long.MAX_VALUE))
        assertFalse(Notice("", "n1", 0L, 0L, true).activeAt(0L))
    }

    @Test
    fun theTileChipListsOnlyDoorsThatCurrentlyShowSomething() {
        val config = noticeConfig("玄関だけ", null, 0L)
        assertEquals(
            setOf("d_front"),
            NoticeModel.activeDoors(null, config, listOf("d_front", "d_back"), 1_000L),
        )
    }

    @Test
    fun coresResolvedAnnouncementIsRenderedRatherThanMergedInTheShell() {
        // status.doors.<id>.notice already carries the value that door shows, with its scope.
        val status = JSONObject(
            """
            {"doors":{"d_front":{"notice":{"text":"裏口へお回りください","scope":"door",
                                           "expires_ms":0}},
                      "d_back":{"notice":{"text":"ただいま留守にしています","scope":"global",
                                          "expires_ms":0}},
                      "d_side":{"notice":null}}}
            """.trimIndent(),
        )
        val front = NoticeModel.fromStatus(status, "d_front", 1_000L)!!
        assertEquals("裏口へお回りください", front.text)
        assertTrue(front.doorSpecific)
        val back = NoticeModel.fromStatus(status, "d_back", 1_000L)!!
        assertEquals("ただいま留守にしています", back.text)
        assertFalse(back.doorSpecific)
        assertNull(NoticeModel.fromStatus(status, "d_side", 1_000L))
        assertNull(NoticeModel.fromStatus(null, "d_front", 1_000L))
    }

    @Test
    fun anExpiredResolvedAnnouncementIsTreatedAsAbsent() {
        val status = JSONObject(
            """{"doors":{"d_front":{"notice":{"text":"期限切れ","scope":"door",
                                              "expires_ms":500}}}}""",
        )
        assertNull(NoticeModel.fromStatus(status, "d_front", 1_000L))
        assertNotNull(NoticeModel.fromStatus(status, "d_front", 400L))
    }

    @Test
    fun theShellFallsBackToConfigurationOnlyWhenCorePublishesNoResolvedValue() {
        val config = noticeConfig("設定から", "全体", 0L)
        assertEquals("設定から", NoticeModel.resolve(null, config, "d_front", 1_000L)!!.text)
        val status = JSONObject(
            """{"doors":{"d_front":{"notice":{"text":"coreから","scope":"door",
                                              "expires_ms":0}}}}""",
        )
        assertEquals("coreから", NoticeModel.resolve(status, config, "d_front", 1_000L)!!.text)
    }

    @Test
    fun globalIsOneWriteToTheClusterWideAnnouncementAndADoorWritesOnlyItsOwn() {
        val doors = listOf("d_front", "d_back")
        // Core stores the cluster-wide value at notice.global, addressed by "*".
        assertEquals(
            listOf(DoorbellCore.GLOBAL_DOOR),
            NoticeModel.writeTargets(NoticeTarget.GLOBAL, "d_front", doors),
        )
        assertEquals(
            listOf("d_front"),
            NoticeModel.writeTargets(NoticeTarget.DOOR, "d_front", doors),
        )
        assertTrue(NoticeModel.writeTargets(NoticeTarget.DOOR, "", doors).isEmpty())
        // "*" is never treated as a door of its own.
        assertTrue(
            NoticeModel.writeTargets(NoticeTarget.DOOR, DoorbellCore.GLOBAL_DOOR, doors).isEmpty(),
        )
    }

    @Test
    fun presetsComeFromConfigurationAndFallBackToTheSeededDefaults() {
        val config = JSONObject().put(
            "notice",
            JSONObject().put(
                "presets",
                JSONArray()
                    .put(JSONObject().put("id", "a").put("text", "不在です"))
                    .put(JSONObject().put("id", "b").put("text", "裏口へ")),
            ),
        )
        val presets = NoticeModel.presets(config, listOf("既定"))
        assertEquals(2, presets.size)
        assertEquals(NoticePreset("a", "不在です"), presets[0])
        assertEquals(listOf(NoticePreset("default0", "既定")), NoticeModel.presets(null, listOf("既定")))
    }

    @Test
    fun presetsAreCappedAndOverlongEntriesAreDropped() {
        val array = JSONArray()
        for (index in 0 until 12)
            array.put(JSONObject().put("id", "p$index").put("text", "文$index"))
        array.put(JSONObject().put("id", "long").put("text", "x".repeat(201)))
        val config = JSONObject().put("notice", JSONObject().put("presets", array))
        assertEquals(NoticeModel.MAX_PRESETS, NoticeModel.presets(config, emptyList()).size)
    }

    @Test
    fun announcementTextIsValidatedAtTwoHundredCharacters() {
        assertEquals("empty", NoticeModel.validate("   "))
        assertNull(NoticeModel.validate("x".repeat(200)))
        assertEquals("too_long", NoticeModel.validate("x".repeat(201)))
    }

    @Test
    fun expiryPresetsProduceAbsoluteDeadlines() {
        val now = 1_000_000L
        val endOfDay = 9_000_000L
        assertEquals(now + 3_600_000L, NoticeModel.expiryFor(ExpiryChoice.ONE_HOUR, now, endOfDay, 1))
        assertEquals(endOfDay, NoticeModel.expiryFor(ExpiryChoice.TODAY, now, endOfDay, 1))
        assertEquals(0L, NoticeModel.expiryFor(ExpiryChoice.UNTIL_CLEARED, now, endOfDay, 1))
        assertEquals(
            now + 3 * 3_600_000L,
            NoticeModel.expiryFor(ExpiryChoice.CUSTOM, now, endOfDay, 3),
        )
    }

    // ---------- call history ----------

    private fun log(count: Int, unread: Int = 0): JSONObject {
        val rows = JSONArray()
        for (index in 0 until count) {
            rows.put(
                JSONObject()
                    .put("id", "o:$index")
                    .put("call_id", "c$index")
                    // Newest first, one hour apart, starting at a fixed instant.
                    .put("ts", 1_700_000_000_000L - index * 3_600_000L)
                    .put("door", if (index % 2 == 0) "d_front" else "d_back")
                    .put("outcome", if (index % 3 == 0) "missed" else "answered")
                    .put("hlc", "h$index")
                    .put("duration_ms", if (index % 3 == 0) 0L else 42_000L)
                    .put("seen", index > unread),
            )
        }
        return JSONObject().put("rows", rows).put("unread_missed", unread)
    }

    @Test
    fun rowsAreParsedAndMalformedEntriesAreSkipped() {
        val document = JSONObject()
            .put(
                "rows",
                JSONArray()
                    .put(JSONObject().put("id", "o:1").put("ts", 5L).put("outcome", "missed")
                             .put("hlc", "h1"))
                    .put(JSONObject().put("ts", 6L)),
            )
            .put("unread_missed", 3)
        val rows = CallHistoryModel.parse(document)
        assertEquals(1, rows.size)
        assertTrue(rows[0].missed)
        assertEquals(3, CallHistoryModel.unreadMissed(document))
        assertEquals("h1", CallHistoryModel.newestHlc(rows))
        assertTrue(CallHistoryModel.parse(null).isEmpty())
        assertEquals("", CallHistoryModel.newestHlc(emptyList()))
    }

    @Test
    fun filtersNarrowByOutcomeAndByDoor() {
        val rows = CallHistoryModel.parse(log(9))
        assertEquals(9, CallHistoryModel.filter(rows, HistoryFilter.ALL, "").size)
        assertEquals(3, CallHistoryModel.filter(rows, HistoryFilter.MISSED, "").size)
        assertEquals(5, CallHistoryModel.filter(rows, HistoryFilter.DOOR, "d_front").size)
        // An empty door filter never hides everything.
        assertEquals(9, CallHistoryModel.filter(rows, HistoryFilter.DOOR, "").size)
    }

    @Test
    fun pagingReturnsFiftyRowsAtATimeAndKnowsWhenMoreExist() {
        val rows = CallHistoryModel.parse(log(120))
        assertEquals(50, CallHistoryModel.page(rows, 1).size)
        assertEquals(100, CallHistoryModel.page(rows, 2).size)
        assertEquals(120, CallHistoryModel.page(rows, 3).size)
        assertEquals(51, CallHistoryModel.requestLimit(1))
        assertEquals(101, CallHistoryModel.requestLimit(2))
        assertEquals(500, CallHistoryModel.requestLimit(20))
        assertTrue(CallHistoryModel.hasMore(51, 1))
        assertFalse(CallHistoryModel.hasMore(50, 1))
        assertFalse(CallHistoryModel.hasMore(120, 3))
    }

    @Test
    fun theOldestShownTimestampIsTheWatermarkForTheNextPage() {
        val rows = CallHistoryModel.page(CallHistoryModel.parse(log(60)), 1)
        assertEquals(rows.last().tsMs, CallHistoryModel.beforeMs(rows))
        assertEquals(0L, CallHistoryModel.beforeMs(emptyList()))
    }

    @Test
    fun rowsAreGroupedByDayInTheOrderTheyArrive() {
        val rows = CallHistoryModel.parse(log(30))
        val groups = CallHistoryModel.group(rows) { ms -> "day${ms / 86_400_000L}" }
        assertTrue(groups.size >= 2)
        assertEquals(rows.size, groups.sumOf { it.rows.size })
        // Each group is contiguous, so no day key repeats.
        assertEquals(groups.size, groups.map { it.dayKey }.toSet().size)
        assertTrue(CallHistoryModel.group(emptyList()) { "x" }.isEmpty())
    }

    @Test
    fun durationsRenderAsMinutesAndSeconds() {
        assertEquals("", CallHistoryModel.durationText(0L))
        assertEquals("0:42", CallHistoryModel.durationText(42_000L))
        assertEquals("1:03", CallHistoryModel.durationText(63_500L))
    }

    // ---------- SOS slide ----------

    @Test
    fun aShortSlideSpringsBackWithoutArming() {
        val state = SosSlideState(3)
        state.begin()
        state.drag(0.5f)
        val released = state.release()
        assertEquals(SosPhase.IDLE, released.phase)
        assertEquals(0f, released.progress, 1e-6f)
        assertFalse(released.fireNow)
    }

    @Test
    fun slidingPastNinetyPercentStartsTheConfiguredCountdown() {
        val state = SosSlideState(3)
        state.begin()
        state.drag(0.95f)
        val armed = state.release()
        assertEquals(SosPhase.COUNTDOWN, armed.phase)
        assertEquals(3, armed.secondsLeft)
        assertFalse(armed.fireNow)
        assertTrue(state.armed)
        assertEquals(2, state.tick().secondsLeft)
        assertEquals(1, state.tick().secondsLeft)
        val fired = state.tick()
        assertEquals(SosPhase.FIRED, fired.phase)
        assertTrue(fired.fireNow)
        assertEquals(0, fired.secondsLeft)
    }

    @Test
    fun cancellingDuringTheCountdownNeverReportsTheAlarm() {
        val state = SosSlideState(3)
        state.begin()
        state.drag(1f)
        state.release()
        state.tick()
        val cancelled = state.cancel()
        assertEquals(SosPhase.IDLE, cancelled.phase)
        assertFalse(cancelled.fireNow)
        // A tick after cancelling is inert.
        assertFalse(state.tick().fireNow)
        assertEquals(SosPhase.IDLE, state.snapshot().phase)
    }

    @Test
    fun aZeroCountdownFiresOnRelease() {
        val state = SosSlideState(0)
        state.begin()
        state.drag(1f)
        val released = state.release()
        assertEquals(SosPhase.FIRED, released.phase)
        assertTrue(released.fireNow)
    }

    @Test
    fun aSlideCannotRestartWhileTheCountdownIsRunning() {
        val state = SosSlideState(3)
        state.begin()
        state.drag(1f)
        state.release()
        assertEquals(SosPhase.COUNTDOWN, state.begin().phase)
        assertEquals(SosPhase.COUNTDOWN, state.drag(0f).phase)
        assertEquals(3, state.snapshot().secondsLeft)
    }

    @Test
    fun aFiredAlarmIsNotCancelledByTheSlideControl() {
        val state = SosSlideState(0)
        state.begin()
        state.drag(1f)
        state.release()
        assertEquals(SosPhase.FIRED, state.cancel().phase)
        assertEquals(SosPhase.IDLE, state.reset().phase)
    }

    @Test
    fun theCountdownComesFromConfigurationAndIsClamped() {
        assertEquals(
            SosSlideState.DEFAULT_COUNTDOWN_S,
            SosSlideState.countdownFromConfig(null),
        )
        assertEquals(
            SosSlideState.DEFAULT_COUNTDOWN_S,
            SosSlideState.countdownFromConfig(JSONObject("""{"emergency":{"trigger":{}}}""")),
        )
        assertEquals(
            7,
            SosSlideState.countdownFromConfig(
                JSONObject("""{"emergency":{"trigger":{"countdown_s":7}}}"""),
            ),
        )
        assertEquals(
            SosSlideState.MAX_COUNTDOWN_S,
            SosSlideState.countdownFromConfig(
                JSONObject("""{"emergency":{"trigger":{"countdown_s":99}}}"""),
            ),
        )
        assertEquals(
            0,
            SosSlideState.countdownFromConfig(
                JSONObject("""{"emergency":{"trigger":{"countdown_s":-4}}}"""),
            ),
        )
    }

    @Test
    fun theLegacyHoldModeStillRendersAsASlide() {
        assertTrue(SosSlideState.slideMode(null))
        assertTrue(
            SosSlideState.slideMode(
                JSONObject("""{"emergency":{"trigger":{"mode":"hold"}}}"""),
            ),
        )
        assertTrue(
            SosSlideState.slideMode(
                JSONObject("""{"emergency":{"trigger":{"mode":"slide"}}}"""),
            ),
        )
    }

    // ---------- live-view counters ----------

    @Test
    fun theDebugLineReportsMeasuredFramesJitterAndDrops() {
        val counter = VideoStatsCounter()
        counter.setCodec("h264")
        var now = 10_000L
        // Twenty-five frames a second for just over a second, with a small wobble.
        for (index in 0 until 26) {
            counter.onFrame(now)
            now += if (index % 2 == 0) 38L else 42L
        }
        val stats = counter.snapshot(now)
        assertEquals("h264", stats.codec)
        assertTrue("fps was ${stats.fps}", stats.fps in 20..30)
        assertTrue("jitter was ${stats.jitterMs}", stats.jitterMs in 1..5)
        assertEquals(0, stats.dropped)
        counter.onDropped()
        assertEquals(1, counter.snapshot(now).dropped)
        counter.reset()
        assertEquals(0, counter.snapshot(now).fps)
        assertEquals(0, counter.snapshot(now).latencyMs)
    }

    @Test
    fun anImplausibleGapIsNotCountedAsJitter() {
        val counter = VideoStatsCounter()
        counter.onFrame(0L)
        counter.onFrame(60_000L)
        assertEquals(0, counter.jitter())
    }

    // ---------- version and battery line ----------

    @Test
    fun theVersionLineCarriesBothVersionsAndHidesAnAbsentBattery() {
        val battery = { value: Int -> "$value%" }
        assertEquals(
            "ipad1-monitor · core v0.4.0 · app v0.3.0 · 82%",
            ShellUi.versionLine("ipad1-monitor", "v0.4.0", "v0.3.0", 82, false, battery),
        )
        assertEquals(
            "ipad1-monitor · core v0.4.0 · app v0.3.0 · ⚡ 82%",
            ShellUi.versionLine("ipad1-monitor", "v0.4.0", "v0.3.0", 82, true, battery),
        )
        assertEquals(
            "wall-panel · core v0.4.0 · app v0.3.0",
            ShellUi.versionLine("wall-panel", "v0.4.0", "v0.3.0", -1, false, battery),
        )
    }

    // ---------- responsive visitor layout ----------

    @Test
    fun theVisitorScreenSplitsOnlyOnAWideLandscapeWindow() {
        assertEquals(
            VisitorLayout.Arrangement.STACKED, VisitorLayout.arrangementFor(360, 780),
        )
        // A landscape phone wide enough for two columns splits; a narrow one still stacks.
        assertEquals(
            VisitorLayout.Arrangement.SPLIT, VisitorLayout.arrangementFor(640, 360),
        )
        assertEquals(
            VisitorLayout.Arrangement.STACKED, VisitorLayout.arrangementFor(568, 320),
        )
        assertEquals(
            VisitorLayout.Arrangement.SPLIT, VisitorLayout.arrangementFor(1024, 768),
        )
        assertEquals(
            VisitorLayout.Arrangement.STACKED, VisitorLayout.arrangementFor(768, 1024),
        )
    }

    @Test
    fun tabletsGetATallerCallButtonAndALargerHint() {
        assertEquals(72, VisitorLayout.callButtonHeightDp(360))
        assertEquals(96, VisitorLayout.callButtonHeightDp(VisitorLayout.TABLET_MIN_DP))
        assertEquals(15f, VisitorLayout.hintTextSizeSp(360), 1e-6f)
        assertEquals(20f, VisitorLayout.hintTextSizeSp(800), 1e-6f)
        assertTrue(VisitorLayout.clockTextSizeSp(800, 1200) > VisitorLayout.clockTextSizeSp(360, 640))
    }

    // ---------- Pairing PIN minting ----------

    @Test
    fun thePinCardNeverOpensTheBulkAddWindow() {
        // There is no fallback path that opens pairing mode: minting is its own core export, so
        // showing a PIN can never start auto-inviting every discovered device.
        assertTrue(JoinTokenMinting.withinCoreRange(0))
        assertTrue(JoinTokenMinting.withinCoreRange(JoinTokenMinting.MIN_SECONDS))
        assertTrue(JoinTokenMinting.withinCoreRange(JoinTokenMinting.MAX_SECONDS))
        assertFalse(JoinTokenMinting.withinCoreRange(10))
        assertFalse(JoinTokenMinting.withinCoreRange(3600))
    }

    @Test
    fun aMintResultIsOnlyASuccessWhenCoreActuallyReturnedAPin() {
        val ok = JSONObject(
            """{"ok":true,"host":"10.0.1.10:47172","pin":"123456","expires_s":600}""",
        )
        assertTrue(JoinTokenMinting.succeeded(ok))
        assertEquals("", JoinTokenMinting.errorOf(ok))

        val failed = JSONObject("""{"ok":false,"err":"host_unpaired"}""")
        assertFalse(JoinTokenMinting.succeeded(failed))
        assertEquals("host_unpaired", JoinTokenMinting.errorOf(failed))

        // An "ok" without a PIN is not something the card may present as a code.
        assertFalse(JoinTokenMinting.succeeded(JSONObject("""{"ok":true}""")))
        assertFalse(JoinTokenMinting.succeeded(null))
        assertEquals("", JoinTokenMinting.errorOf(null))
    }

    // ---------- unlock button, as core reports it ----------

    @Test
    fun theUnlockControlFollowsCoresReportedVisibility() {
        val status = JSONObject(
            """
            {"doors":{"d_front":{"unlock":{"configured":true,"command":"open_front",
                                           "show_button":true,"source":"default"}},
                      "d_back":{"unlock":{"configured":false,"command":"",
                                          "show_button":false,"source":"default"}}}}
            """.trimIndent(),
        )
        val front = DoorUnlocks.read(status, "d_front")
        assertTrue(front.configured)
        assertTrue(front.showButton)
        assertEquals("default", front.source)
        val back = DoorUnlocks.read(status, "d_back")
        assertFalse(back.configured)
        assertFalse(back.showButton)
    }

    @Test
    fun anAdministratorCanForceTheUnlockControlEitherWay() {
        val forcedOn = JSONObject(
            """{"doors":{"d_front":{"unlock":{"configured":false,"show_button":true,
                                              "source":"admin"}}}}""",
        )
        val forcedOff = JSONObject(
            """{"doors":{"d_front":{"unlock":{"configured":true,"show_button":false,
                                              "source":"admin"}}}}""",
        )
        // Shown with nothing configured: the button appears and explains itself when pressed.
        assertTrue(DoorUnlocks.read(forcedOn, "d_front").showButton)
        assertFalse(DoorUnlocks.read(forcedOn, "d_front").configured)
        assertEquals("admin", DoorUnlocks.read(forcedOn, "d_front").source)
        assertFalse(DoorUnlocks.read(forcedOff, "d_front").showButton)
    }

    @Test
    fun withoutACoreAnswerTheUnlockControlStaysHidden() {
        assertEquals(DoorUnlock.UNKNOWN, DoorUnlocks.read(null, "d_front"))
        assertEquals(DoorUnlock.UNKNOWN, DoorUnlocks.read(JSONObject(), "d_front"))
        assertEquals(DoorUnlock.UNKNOWN, DoorUnlocks.read(JSONObject(), ""))
        assertFalse(DoorUnlock.UNKNOWN.showButton)
    }

    @Test
    fun coresOpenDoorResultsAreDistinguished() {
        assertTrue(DoorUnlocks.queued(0))
        assertFalse(DoorUnlocks.queued(-3))
        assertTrue(DoorUnlocks.unconfigured(-3))
        assertFalse(DoorUnlocks.unconfigured(-2))
        assertFalse(DoorUnlocks.unconfigured(0))
    }

    // ---------- administration link ----------

    @Test
    fun theAdminLinkPrefersTheNodesOwnAddressAndNamesTheLeaderSeparately() {
        val status = JSONObject(
            """
            {"node":{"addrs":["10.10.38.147:47172"]},
             "peers":[{"leader":false,"addrs":["10.10.38.150:47172"]},
                      {"leader":true,"addrs":["10.10.38.151:47172"]}]}
            """.trimIndent(),
        )
        val link = AdminLinks.resolve(status, 47180)
        assertEquals("http://10.10.38.147:47180/admin/", link.url)
        assertEquals("http://10.10.38.151:47180/admin/", link.leaderUrl)
        assertTrue(link.hasLeader)
    }

    @Test
    fun theAdminLinkFallsBackToLoopbackAndHidesAnIdenticalLeader() {
        val link = AdminLinks.resolve(null, 47180)
        assertEquals("http://127.0.0.1:47180/admin/", link.url)
        assertFalse(link.hasLeader)
        assertEquals("10.0.0.5", AdminLinks.firstHost(JSONArray().put("10.0.0.5:47172")))
        assertNull(AdminLinks.firstHost(JSONArray()))
        assertNull(AdminLinks.firstHost(null))
    }

    // ---------- cluster calendar arithmetic ----------

    @Test
    fun civilDatesRoundTripAcrossLeapYearsAndCenturies() {
        assertEquals(listOf(1970, 1, 1), CivilDate.fromDays(0L).toList())
        assertEquals(listOf(2026, 9, 2), CivilDate.fromDays(20698L).toList())
        // 2000 was a leap year, 1900 was not.
        assertEquals(listOf(2000, 2, 29), CivilDate.fromDays(11016L).toList())
        assertEquals(listOf(2024, 2, 29), CivilDate.fromDays(19782L).toList())
        // Instants before the epoch still land on the right civil date.
        assertEquals(listOf(1969, 12, 31), CivilDate.fromDays(-1L).toList())
        assertEquals(listOf(1900, 1, 1), CivilDate.fromDays(-25567L).toList())
    }

    @Test
    fun theWeekdayFollowsCoresSundayZeroConvention() {
        // 1970-01-01 was a Thursday, which is four in a Sunday-zero week.
        assertEquals(4, CivilDate.weekday(0L))
        assertEquals(5, CivilDate.weekday(1L))
        assertEquals(0, CivilDate.weekday(3L))
        assertEquals(3, CivilDate.weekday(-1L))
    }

    @Test
    fun floorDivisionRoundsTowardNegativeInfinity() {
        assertEquals(1L, CivilDate.floorDiv(10L, 7L))
        assertEquals(-2L, CivilDate.floorDiv(-10L, 7L))
        assertEquals(-1L, CivilDate.floorDiv(-7L, 7L))
        assertEquals(0L, CivilDate.floorDiv(0L, 7L))
    }
}
