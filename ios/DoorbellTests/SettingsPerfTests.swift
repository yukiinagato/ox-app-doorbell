import XCTest

@testable import Doorbell

final class SettingsPerfTests: XCTestCase {

    func testBurstOfRequestsSchedulesOneRefreshAndKeepsTheForce() {
        var c = SettingsRefreshCoalescer()
        XCTAssertTrue(c.request())
        XCTAssertFalse(c.request())
        XCTAssertFalse(c.request(force: true))
        XCTAssertTrue(c.fire())
        XCTAssertTrue(c.request(), "a request after the refresh starts a new one")
        XCTAssertFalse(c.fire())
    }

    func testPendingWritesCountOverlappingWritesOfOneItem() {
        var p = SettingsPendingWrites()
        p.begin("a")
        p.begin("a")
        p.finish("a")
        XCTAssertTrue(p.isPending("a"))
        p.finish("a")
        XCTAssertFalse(p.isPending("a"))
        p.finish("a")
        XCTAssertEqual(p.ids, [])
    }

    private func page(_ rows: [[(String, String)]]) -> [[(id: String, print: String)]] {
        return rows.map { $0.map { (id: $0.0, print: $0.1) } }
    }

    func testDiffReportsOnlyChangedRowsAndSkipsPendingOnes() {
        let old = page([[("a", "1"), ("b", "1")], [("c", "1")]])
        XCTAssertEqual(SettingsRowDiff.compare(old: old, new: old), .same)
        let new = page([[("a", "2"), ("b", "1")], [("c", "2")]])
        XCTAssertEqual(SettingsRowDiff.compare(old: old, new: new),
                       .rows([IndexPath(row: 0, section: 0), IndexPath(row: 0, section: 1)]))
        XCTAssertEqual(SettingsRowDiff.compare(old: old, new: new, skip: ["a"]),
                       .rows([IndexPath(row: 0, section: 1)]))
        XCTAssertEqual(SettingsRowDiff.compare(old: old, new: new, skip: ["a", "c"]), .same)
    }

    func testDiffCallsAnyStructuralChangeStructure() {
        let old = page([[("a", "1"), ("b", "1")]])
        XCTAssertEqual(SettingsRowDiff.compare(old: old, new: page([[("a", "1")]])), .structure)
        XCTAssertEqual(SettingsRowDiff.compare(old: old, new: page([[("a", "1"), ("x", "1")]])),
                       .structure)
        XCTAssertEqual(SettingsRowDiff.compare(old: old, new: page([[("a", "1")], []])), .structure)
    }

    func testFingerprintChangesWithTheShownValue() {
        let off = SettingItem("t", "Title", .toggle(false))
        let on = SettingItem("t", "Title", .toggle(true))
        XCTAssertNotEqual(off.fingerprint, on.fingerprint)
        XCTAssertEqual(off.fingerprint, SettingItem("t", "Title", .toggle(false)).fingerprint)
    }
}
