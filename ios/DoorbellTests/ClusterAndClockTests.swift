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
}
