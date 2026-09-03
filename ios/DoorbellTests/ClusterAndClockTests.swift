import UIKit
import XCTest

@testable import Doorbell

/// The dashboard's cluster counts, the camera gate on door tiles, and the clock arithmetic that
/// replaced a synchronous Core call on every tick.
final class ClusterAndClockTests: XCTestCase {

    // MARK: - Cluster counts

    private func peer(_ role: String, id: String, online: Bool = true,
                      isSelf: Bool = false) -> [String: Any] {
        return ["id": id, "role": role, "status": online ? "alive" : "dead", "self": isSelf]
    }

    func testCountsEveryDeviceAndEachKindSeparately() {
        let status: [String: Any] = ["peers": [
            peer("indoor_panel", id: "me", isSelf: true),
            peer("door_station", id: "front"),
            peer("door_station", id: "back", online: false),
            peer("indoor_panel", id: "kitchen"),
        ]]
        let counts = ClusterCounts.from(status: status, selfRole: "indoor_panel")
        XCTAssertEqual(counts.devices, 4)
        XCTAssertEqual(counts.doorStations, 2)
        XCTAssertEqual(counts.doorStationsOnline, 1, "the dead one is counted but not online")
        XCTAssertEqual(counts.indoorPanels, 2)
        XCTAssertEqual(counts.indoorPanelsOnline, 2)
    }

    /// This device is the one asking, so it is reachable by definition even if a stale snapshot
    /// still calls it dead.
    func testThisDeviceIsAlwaysCountedAsReachable() {
        let status: [String: Any] = ["peers": [
            peer("indoor_panel", id: "me", online: false, isSelf: true),
        ]]
        let counts = ClusterCounts.from(status: status, selfRole: "indoor_panel")
        XCTAssertEqual(counts.indoorPanelsOnline, 1)
        XCTAssertEqual(counts.devices, 1)
    }

    /// A snapshot that does not list this device still has to count it.
    func testAMissingSelfEntryIsAddedFromTheRole() {
        let status: [String: Any] = ["peers": [peer("door_station", id: "front")]]
        let counts = ClusterCounts.from(status: status, selfRole: "indoor_panel")
        XCTAssertEqual(counts.devices, 2)
        XCTAssertEqual(counts.doorStations, 1)
        XCTAssertEqual(counts.indoorPanels, 1)
        XCTAssertEqual(counts.indoorPanelsOnline, 1)
    }

    func testAnEmptyOrAbsentStatusCountsOnlyThisDevice() {
        XCTAssertEqual(ClusterCounts.from(status: nil, selfRole: "indoor_panel").devices, 1)
        XCTAssertEqual(ClusterCounts.from(status: [:], selfRole: "door_station").doorStations, 1)
        XCTAssertEqual(ClusterCounts.from(status: nil).devices, 0,
                       "with no role to assume, nothing is invented")
    }

    /// A role this build has never heard of is still a device in the cluster.
    func testAnUnknownRoleCountsAsADeviceAndNothingElse() {
        let status: [String: Any] = ["peers": [
            peer("indoor_panel", id: "me", isSelf: true),
            peer("weather_station", id: "roof"),
        ]]
        let counts = ClusterCounts.from(status: status, selfRole: "indoor_panel")
        XCTAssertEqual(counts.devices, 2)
        XCTAssertEqual(counts.doorStations, 0)
        XCTAssertEqual(counts.indoorPanels, 1)
    }

    // MARK: - A door with no camera has no tile

    private func doorStatus(camera: Any?) -> [String: Any] {
        var peer: [String: Any] = ["id": "front", "role": "door_station", "door": "front",
                                   "status": "alive"]
        if let camera = camera { peer["caps"] = ["camera": camera] }
        return ["peers": [peer]]
    }

    private let doorsConfig: [String: Any] = ["doors": ["front": ["order": 1]]]

    func testADoorStationWithoutACameraGetsNoTile() {
        XCTAssertEqual(ConfigUtil.doorsWithCamera(config: doorsConfig,
                                                  status: doorStatus(camera: false)), [],
                       "there is nothing on that door to watch")
    }

    func testADoorStationWithACameraGetsATile() {
        XCTAssertEqual(ConfigUtil.doorsWithCamera(config: doorsConfig,
                                                  status: doorStatus(camera: true)), ["front"])
    }

    /// Every door station shipped so far has a camera, so an absent capability means it has one.
    /// Hiding a working camera because a field is missing would be the worse failure.
    func testAnAbsentCapabilityShowsTheTile() {
        XCTAssertEqual(ConfigUtil.doorsWithCamera(config: doorsConfig,
                                                  status: doorStatus(camera: nil)), ["front"])
        XCTAssertEqual(ConfigUtil.doorsWithCamera(config: doorsConfig, status: [:]), ["front"],
                       "an unreachable door keeps its tile; its capabilities are unknown")
        XCTAssertTrue(ConfigUtil.doorHasCamera(nil))
    }

    // MARK: - The clock advances without asking Core

    private func reading(hour: Int, minute: Int, second: Int, date: String = "2026-09-03",
                         weekday: String = "thu") -> DoorbellClock.Reading {
        return DoorbellClock.Reading(hour: hour, minute: minute, second: second, date: date,
                                     weekday: weekday, tz: "Asia/Tokyo", known: true,
                                     wallMs: 1_772_000_000_000, raw: [:])
    }

    func testAdvancingSecondsWalksTheClock() {
        let base = reading(hour: 3, minute: 17, second: 19)
        XCTAssertEqual(DoorbellClock.advance(base, bySeconds: 1).hhmmss, "03:17:20")
        XCTAssertEqual(DoorbellClock.advance(base, bySeconds: 41).hhmmss, "03:18:00")
        XCTAssertEqual(DoorbellClock.advance(base, bySeconds: 0).hhmmss, "03:17:19")
        XCTAssertEqual(DoorbellClock.advance(base, bySeconds: 30).wallMs,
                       base.wallMs + 30_000)
    }

    /// Between two refreshes the clock can cross midnight, and the date has to cross with it.
    func testCrossingMidnightMovesTheDateAndWeekday() {
        let base = reading(hour: 23, minute: 59, second: 50, date: "2026-09-03", weekday: "thu")
        let next = DoorbellClock.advance(base, bySeconds: 15)
        XCTAssertEqual(next.hhmmss, "00:00:05")
        XCTAssertEqual(next.date, "2026-09-04")
        XCTAssertEqual(next.weekday, "fri")
    }

    func testTheDateArithmeticHandlesMonthAndLeapYearEnds() {
        XCTAssertEqual(DoorbellClock.addDays(1, to: "2026-09-30"), "2026-10-01")
        XCTAssertEqual(DoorbellClock.addDays(1, to: "2026-12-31"), "2027-01-01")
        XCTAssertEqual(DoorbellClock.addDays(1, to: "2028-02-28"), "2028-02-29")
        XCTAssertEqual(DoorbellClock.addDays(1, to: "2026-02-28"), "2026-03-01")
        XCTAssertEqual(DoorbellClock.addDays(1, to: "1900-02-28"), "1900-03-01")
        XCTAssertEqual(DoorbellClock.addDays(1, to: "2000-02-28"), "2000-02-29")
        XCTAssertEqual(DoorbellClock.addDays(0, to: "2026-09-03"), "2026-09-03")
        XCTAssertEqual(DoorbellClock.addDays(1, to: "nonsense"), "nonsense")
    }

    /// The source has nothing to draw until Core has answered once, and must not invent a time.
    func testTheSourceDrawsNothingBeforeItsFirstReading() {
        let source = DoorbellClockSource()
        XCTAssertFalse(source.hasReading)
        XCTAssertNil(source.reading())
    }

    // MARK: - Nothing reads Core before Core has started

    /// A Core that counts what is asked of it and can be switched from "starting" to "started".
    ///
    /// The distinction is the whole point: `db_core_create_v2` returns a handle while Core's run
    /// loop is still manual, and in that state a loop-backed export runs its body on the calling
    /// thread instead of Core's. The clock refreshes off a utility queue, so it is exactly the
    /// caller that must not do that while `db_core_start` is assembling the node.
    private final class CoreSpy: DoorbellClockCore {
        var isRunning = false
        private(set) var reads = 0

        func localTime(wallMs: Int64) -> [String: Any]? {
            reads += 1
            return ["hh": 21, "mm": 30, "ss": 0, "date": "2026-09-03", "weekday": "thu",
                    "tz": "Asia/Tokyo", "known": true, "wall_ms": 1_772_000_000_000]
        }
    }

    func testTheClockAsksAnUnstartedCoreForNothing() {
        let core = CoreSpy()
        let source = DoorbellClockSource()

        source.refresh(core)
        XCTAssertEqual(core.reads, 0, "no Core call may be made while start is in flight")
        XCTAssertTrue(source.waitingForCore, "and the refusal is remembered, so it can be retried")
        XCTAssertNil(source.reading(), "with no base there is no time to draw")
        XCTAssertNil(DoorbellClock.read(core), "nor through the plain reader")
        XCTAssertEqual(core.reads, 0)

        // Repeated attempts — the 1 Hz retry — still ask Core nothing.
        for _ in 0..<10 { source.refresh(core) }
        XCTAssertEqual(core.reads, 0)
    }

    func testTheClockTakesExactlyOneReadingOnceCoreHasStarted() {
        let core = CoreSpy()
        let source = DoorbellClockSource()
        source.refresh(core)
        XCTAssertEqual(core.reads, 0)

        core.isRunning = true
        let refreshed = expectation(description: "the base is taken once Core is up")
        source.refresh(core) { _ in refreshed.fulfill() }
        wait(for: [refreshed], timeout: 5)

        XCTAssertEqual(core.reads, 1, "one reading, not one per tick")
        XCTAssertFalse(source.waitingForCore)
        XCTAssertEqual(source.reading()?.hhmm, "21:30")

        // Drawing a second is arithmetic on that base: still one Core call.
        for _ in 0..<30 { _ = source.reading() }
        XCTAssertEqual(core.reads, 1)
    }

    /// The two home screens are built before anything has confirmed Core is up. Neither may read
    /// through it until it is: `CoreBridge` hands out its handle only after `db_core_start`
    /// returned, so every read here answers nil instead of entering a half-built node.
    func testTheHomeScreensReadNothingFromACoreThatHasNotStarted() {
        let core = CoreBridge()
        XCTAssertFalse(core.isRunning, "an unstarted bridge never reports itself running")
        XCTAssertNil(core.status())
        XCTAssertNil(core.config())
        XCTAssertNil(core.localTime())
        XCTAssertNil(core.callLog())
        XCTAssertNil(DoorbellClock.read(core))

        let texts = Texts()
        let boot = BootConfig()
        let dashboard = DashboardView(core: core, boot: boot, texts: texts,
                                      sosControl: SosSlideControl(texts: texts))
        dashboard.reload(config: nil, skin: .plain(.dark))
        dashboard.updateClock(DoorbellClock.Reading(
            hour: 21, minute: 30, second: 0, date: "2026-09-03", weekday: "thu",
            tz: "Asia/Tokyo", known: true, wallMs: 0, raw: [:]))

        let visitor = VisitorScreenView(texts: texts, callButton: UIButton(type: .system),
                                        langBar: UIStackView(),
                                        purposeSection: UIStackView(),
                                        sosControl: SosSlideControl(texts: texts))
        visitor.applyLayout(for: CGSize(width: 768, height: 1024))
        visitor.apply(skin: .plain(.dark))

        XCTAssertFalse(core.isRunning, "and building them started nothing")
    }
}

/// The panel must not let the device auto-lock, and no lifecycle transition may take the node off
/// the mesh.
///
/// When iOS auto-locks it suspends the foreground app: the listening sockets are closed, so 47180
/// and 47172 start refusing connections, the cluster marks the node dead, and the process is
/// evicted later. Nothing is written — no crash report, no jetsam event, no resource report — so
/// from the outside it is indistinguishable from a hang. These are the two properties that keep
/// it from happening.
final class PanelStaysAwakeTests: XCTestCase {

    override func tearDown() {
        ScreenAwake.want(true)
        super.tearDown()
    }

    func testTheOverrideIsWantedByDefaultAndIsActuallyApplied() {
        ScreenAwake.want(true)
        XCTAssertTrue(ScreenAwake.wanted)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled,
                      "a door station must never let the device auto-lock")
    }

    /// Re-asserting is the whole point: several screens clear the flag, and one of them — the iOS
    /// 9 admin alert — used to restore it from a single one of its three ways out.
    func testReapplyingPutsTheOverrideBackAfterSomethingClearedIt() {
        ScreenAwake.want(true)
        UIApplication.shared.isIdleTimerDisabled = false
        ScreenAwake.apply()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
    }

    /// Leaving kiosk mode is the one deliberate exception, and re-applying must not undo it.
    func testLeavingKioskModeIsRememberedAcrossAReassert() {
        ScreenAwake.want(false)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        ScreenAwake.apply()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled,
                       "an administrator's choice survives the next activation")
    }
}

/// The record the shell keeps of its own life, so that the next death that leaves no crash report,
/// no jetsam event and no resource report can still be explained from the device.
final class ShellLogTests: XCTestCase {

    private var dir = ""

    override func setUp() {
        super.setUp()
        dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("shell-log-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        ShellLog.enabled = true
    }

    override func tearDown() {
        ShellLog.enabled = false
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private var logPath: String {
        return (dir as NSString).appendingPathComponent("shell.log")
    }

    /// The writes happen on the log's own queue, so the file is polled rather than assumed.
    @discardableResult
    private func waitForLog(containing needle: String) -> String {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let body = try? String(contentsOfFile: logPath, encoding: .utf8),
               body.contains(needle) {
                return body
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    }

    func testItRecordsTheLaunchCoreAndEveryLifecycleTransition() {
        ShellLog.start(dataDir: dir, note: "role=door_station door=front")
        ShellLog.note("core.start ok=true")
        ShellLog.note("lifecycle didEnterBackground idle_timer_disabled=false")

        let body = waitForLog(containing: "didEnterBackground")
        XCTAssertTrue(body.contains("=== launch role=door_station door=front"))
        XCTAssertTrue(body.contains("core.start ok=true"))
        XCTAssertTrue(body.contains("lifecycle didEnterBackground idle_timer_disabled=false"))
        // Every line carries a wall clock and the uptime, so it lines up with idevicesyslog and
        // with the device's own crash reports.
        for line in body.split(separator: "\n") {
            XCTAssertTrue(line.contains(" +"), "each line is stamped: \(line)")
            XCTAssertEqual(line.prefix(2), "20", "and starts with a date: \(line)")
        }
    }

    /// Core announces `peers_changed` several times a second, so the events are buffered and
    /// bounded rather than written one file append at a time.
    func testUiEventsAreKeptButBounded() {
        ShellLog.start(dataDir: dir, note: "role=door_station")
        for index in 0..<200 { ShellLog.uiEvent("peers_changed", detail: "n\(index)") }
        ShellLog.flush()

        // The first event flushes straight away and the rest are buffered, so the newest one is
        // what says the explicit flush has landed.
        let body = waitForLog(containing: "n199")
        let uiLines = body.split(separator: "\n").filter { $0.contains("ui peers_changed") }
        XCTAssertTrue(body.contains("n199"), "the most recent event is kept")
        XCTAssertLessThan(uiLines.count, 200, "but not all two hundred of them")
        XCTAssertFalse(body.contains(" n5 "), "the oldest have fallen off the front")
    }

    func testItWritesNothingWhenTimingsAreOff() {
        ShellLog.enabled = false
        ShellLog.start(dataDir: dir, note: "role=door_station")
        ShellLog.note("core.start ok=true")
        ShellLog.uiEvent("peers_changed")
        ShellLog.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logPath),
                       "a shipped panel writes nothing")
    }
}

/// What the cluster is told about this device's camera.
///
/// An indoor panel now hides the tile of a door station whose `caps.camera` is false, so the
/// difference between "the resident refused" and "nobody has asked yet" is the difference between
/// a door that is genuinely blind and one that has simply not finished launching. The rule is
/// pulled out here because `AVCaptureDevice` cannot be driven from a test.
final class CameraCapabilityTests: XCTestCase {

    func testAnAuthorizedRunningCameraIsOffered() {
        XCTAssertTrue(AvPermissions.cameraOffered(role: "door_station", permission: "authorized",
                                                  runtime: "active"))
        XCTAssertFalse(AvPermissions.shouldWarn(role: "door_station", permission: "authorized"))
    }

    /// The state this device was actually in: asked for, not yet answered. It is not a refusal,
    /// so nothing is claimed and nothing is warned about.
    func testAnUnansweredPromptOffersNoCameraAndRaisesNoBanner() {
        XCTAssertFalse(AvPermissions.cameraOffered(role: "door_station",
                                                   permission: "not_determined",
                                                   runtime: "active"))
        XCTAssertFalse(AvPermissions.shouldWarn(role: "door_station",
                                                permission: "not_determined"),
                       "a prompt nobody has answered is not a refusal")

        // Once the resident allows it and capture comes up, the camera is offered.
        XCTAssertTrue(AvPermissions.cameraOffered(role: "door_station", permission: "authorized",
                                                  runtime: "active"))
    }

    func testARefusalOffersNoCameraAndIsWorthSayingOutLoud() {
        XCTAssertFalse(AvPermissions.cameraOffered(role: "door_station", permission: "denied",
                                                   runtime: "active"))
        XCTAssertTrue(AvPermissions.shouldWarn(role: "door_station", permission: "denied"))
        XCTAssertTrue(AvPermissions.shouldWarn(role: "door_station", permission: "restricted"),
                      "a device under management is refused just as firmly")
    }

    /// A permission on its own is a promise the mesh cannot rely on: capture has to be running.
    func testAPermissionWithoutRunningCaptureIsNotACamera() {
        for runtime in ["idle", "starting", "failed", ""] {
            XCTAssertFalse(AvPermissions.cameraOffered(role: "door_station",
                                                       permission: "authorized",
                                                       runtime: runtime), runtime)
        }
    }

    func testAnIndoorPanelNeverOffersACameraAndIsNeverWarned() {
        XCTAssertFalse(AvPermissions.cameraOffered(role: "indoor_panel", permission: "authorized",
                                                   runtime: "active"))
        XCTAssertFalse(AvPermissions.shouldWarn(role: "indoor_panel", permission: "denied"))
    }
}

/// The icon set is vendored, not drawn.
final class TablerIconTests: XCTestCase {

    private let everyIcon = ["TablerTopologyStar3", "TablerDoor", "TablerDeviceTablet",
                             "TablerChevronRight", "TablerChevronsRight", "TablerHome",
                             "TablerPackage", "TablerMail", "TablerBackspace", "TablerWorld"]

    func testEveryVendoredIconIsInTheCatalogAndIsATemplate() {
        for name in everyIcon {
            guard let image = TablerIcon.image(name) else {
                XCTFail("\(name) is missing from Assets.xcassets")
                continue
            }
            XCTAssertEqual(image.renderingMode, .alwaysTemplate,
                           "\(name) must take the ink of the region it sits in")
            XCTAssertGreaterThan(image.size.width, 0, name)
        }
    }

    func testAnIconNobodyVendoredDrawsNothingRatherThanSomethingWrong() {
        XCTAssertNil(TablerIcon.image("TablerNoSuchGlyph"))
    }

    /// Core's seeded purposes wear a glyph; one an administrator invented keeps their own text.
    func testOnlyTheSeededPurposesHaveAnIcon() {
        XCTAssertNotNil(TablerIcon.purpose("p_visit"))
        XCTAssertNotNil(TablerIcon.purpose("p_delivery"))
        XCTAssertNotNil(TablerIcon.purpose("p_mail"))
        XCTAssertNil(TablerIcon.purpose("p_gardener"))
        XCTAssertNil(TablerIcon.purpose(""))
        XCTAssertEqual(TablerIcon.purposeIcons["p_visit"], "TablerHome")
        XCTAssertEqual(TablerIcon.purposeIcons["p_delivery"], "TablerPackage")
        XCTAssertEqual(TablerIcon.purposeIcons["p_mail"], "TablerMail")
    }

    /// The three counter marks come from the catalog, and each is one of the vendored icons.
    func testTheCounterMarksAreVendoredIcons() {
        for kind in [ClusterIconView.Kind.cluster, .doorStation, .indoorPanel] {
            XCTAssertTrue(everyIcon.contains(kind.iconName), kind.iconName)
            XCTAssertNotNil(TablerIcon.image(kind.iconName), kind.iconName)
        }
        XCTAssertEqual(ClusterIconView.Kind.cluster.iconName, "TablerTopologyStar3")
        XCTAssertEqual(ClusterIconView.Kind.doorStation.iconName, "TablerDoor")
        XCTAssertEqual(ClusterIconView.Kind.indoorPanel.iconName, "TablerDeviceTablet")
    }
}
