import XCTest

@testable import Doorbell

final class LangSwitchTests: XCTestCase {

    func testOnlyTheLastOfRapidTapsIsCommitted() {
        var c = LangSelectionCoalescer()
        let a = c.select("en", at: 0)
        let b = c.select("zh", at: 0.05)
        let d = c.select("ja", at: 0.1)
        XCTAssertNil(c.commit(generation: a))
        XCTAssertNil(c.commit(generation: b))
        XCTAssertEqual(c.commit(generation: d), "ja")
        XCTAssertNil(c.commit(generation: d), "a value is sent once")
    }

    func testEchoesOfEarlierSelectionsAreIgnoredWhilePendingAndForTheQuarantine() {
        var c = LangSelectionCoalescer()
        XCTAssertTrue(c.acceptsEcho("zh", at: 0))
        let a = c.select("en", at: 1)
        _ = c.select("zh", at: 1.1)
        XCTAssertFalse(c.acceptsEcho("en", at: 1.2))
        XCTAssertTrue(c.acceptsEcho("zh", at: 1.2))
        XCTAssertNil(c.commit(generation: a))
        XCTAssertEqual(c.flush(), "zh")
        XCTAssertFalse(c.acceptsEcho("en", at: 2))
        XCTAssertTrue(c.acceptsEcho("en", at: 1.1 + LangSelectionCoalescer.echoQuarantine + 0.1))
    }

    func testFlushTakesThePendingValueOnce() {
        var c = LangSelectionCoalescer()
        XCTAssertNil(c.flush())
        _ = c.select("en", at: 0)
        XCTAssertEqual(c.flush(), "en")
        XCTAssertNil(c.flush())
    }
}
