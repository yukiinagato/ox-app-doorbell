import XCTest

/// Real taps on the visitor flow of a door station.
///
/// These need an isolated simulator whose app is a single-node door station (never paired with
/// real devices) already holding the delivery template: the start page offers the purposes, the
/// delivery purpose leads to a page with a primary option; that leads to a page whose primary option sends the notify. They are
/// in their own scheme so the ordinary unit-test run does not depend on that state.
final class FlowUITests: XCTestCase {

    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "system permission") { alert in
            for label in ["許可しない", "Don\u{2019}t Allow", "Don't Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        let later = app.buttons.matching(NSPredicate(format: "label == 'Set up later' OR label == 'あとで設定'")).firstMatch
        if later.waitForExistence(timeout: 6) { later.tap() }
        XCTAssertTrue(app.buttons["purpose_p_delivery"].waitForExistence(timeout: 20),
                      "the flow's start page is on screen")
        app.staticTexts["flow_title"].tap()
        capture("ui-flow-start")
    }

    private func capture(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["DOORBELL_SHOT_DIR"],
              !directory.isEmpty else { return }
        let prefix = ProcessInfo.processInfo.environment["DOORBELL_SHOT_PREFIX"] ?? ""
        let url = URL(fileURLWithPath: directory).appendingPathComponent(prefix + name + ".png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    func testStartPageOptionOpensAPageAndBackReturns() {
        XCTAssertFalse(app.buttons["flow_back"].exists, "the start page has no Back")
        app.buttons["purpose_p_delivery"].tap()
        XCTAssertTrue(app.buttons["flow_back"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["call_primary"].exists)
        capture("ui-flow-delivery-page")
        app.buttons["flow_back"].tap()
        XCTAssertTrue(app.buttons["purpose_p_delivery"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["flow_back"].exists)
    }

    func testNotifyPathReachesTheEndPageAndDoneReturnsToTheStart() {
        app.buttons["purpose_p_delivery"].tap()
        let primary = app.buttons["call_primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        primary.tap()
        XCTAssertTrue(app.staticTexts["flow_title"].waitForExistence(timeout: 5), "the where-to-leave page")
        capture("ui-flow-where-page")
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        primary.tap()
        let done = app.buttons["flow_done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20), "the notify result shows the end page")
        XCTAssertFalse(app.buttons["flow_back"].exists)
        capture("ui-flow-end-page")
        done.tap()
        XCTAssertTrue(app.buttons["purpose_p_delivery"].waitForExistence(timeout: 5))
    }
}
