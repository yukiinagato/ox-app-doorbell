import XCTest

/// Real touch gestures against the running app: the SOS slide inside its confirmation sheet, and
/// pinch, drag and double tap on a live picture.
///
/// These need a simulator whose app is already an indoor panel in a cluster (the Home tab is
/// showing), and for the zoom test a door station in that cluster. They are in their own scheme
/// so the ordinary unit-test run does not depend on that state.
final class GestureUITests: XCTestCase {

    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.buttons["sos_trigger"].waitForExistence(timeout: 20),
                      "the indoor panel's Home tab is on screen")
    }

    /// Saves what is on screen when `DOORBELL_SHOT_DIR` names a directory (verification runs on
    /// a simulator); otherwise does nothing.
    private func capture(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["DOORBELL_SHOT_DIR"],
              !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    private func slide() -> XCUIElement {
        return app.descendants(matching: .any).matching(identifier: "sos_slider").firstMatch
    }

    private func drag(_ element: XCUIElement, to fraction: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: end)
    }

    /// The sheet's own pan must not take the drag: a full slide arms the countdown, an early
    /// release springs back, and a tap on the running countdown cancels it.
    func testTheSlideInsideTheSheetArmsOnlyWhenDraggedToTheEnd() {
        app.buttons["sos_trigger"].tap()
        let control = slide()
        XCTAssertTrue(control.waitForExistence(timeout: 5), "the confirmation surface opened")
        XCTAssertEqual(control.value as? String ?? "", "", "nothing is counting down yet")

        drag(control, to: 0.45)
        XCTAssertTrue(control.exists, "an early release leaves the sheet up")
        XCTAssertEqual(control.value as? String ?? "", "", "and arms nothing")

        drag(control, to: 0.99)
        let armed = NSPredicate(format: "value != %@ AND value != nil", "")
        expectation(for: armed, evaluatedWith: control)
        waitForExpectations(timeout: 3)

        // A tap during the countdown cancels it; nothing was sent.
        control.tap()
        let idle = NSPredicate(format: "value == nil OR value == %@", "")
        expectation(for: idle, evaluatedWith: control)
        waitForExpectations(timeout: 3)
        XCTAssertFalse(app.descendants(matching: .any)["visitor_sos_screen"].exists)

        app.buttons["sos_confirm_cancel"].tap()
        XCTAssertFalse(control.waitForExistence(timeout: 2) && control.isHittable)
    }

    /// Pinch zooms in up to 4x, a drag pans without leaving the picture, and a double tap
    /// toggles between fit and 2x.
    func testPinchDragAndDoubleTapOnTheLivePicture() {
        let monitor = app.buttons["home_monitor"]
        XCTAssertTrue(monitor.waitForExistence(timeout: 5))
        monitor.tap()
        let picture = app.descendants(matching: .any).matching(identifier: "live_picture")
            .firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 10))
        XCTAssertEqual(picture.value as? String, "1.0x")
        sleep(2)
        capture("zoom-monitor-1x")

        picture.pinch(withScale: 3, velocity: 3)
        let zoomed = Double((picture.value as? String ?? "1").dropLast()) ?? 1
        XCTAssertGreaterThan(zoomed, 1.05, "a pinch zooms in")
        XCTAssertLessThanOrEqual(zoomed, 4.0)

        for _ in 0..<3 { picture.pinch(withScale: 6, velocity: 6) }
        let capped = Double((picture.value as? String ?? "1").dropLast()) ?? 1
        XCTAssertLessThanOrEqual(capped, 4.0, "never past four times")
        XCTAssertGreaterThan(capped, zoomed, "and keeps zooming until then")
        capture("zoom-monitor-zoomed")

        let from = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        let to = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4))
        from.press(forDuration: 0.1, thenDragTo: to)
        XCTAssertTrue(picture.exists && picture.isHittable, "a drag pans; it closes nothing")
        XCTAssertEqual(picture.value as? String, String(format: "%.1fx", capped),
                       "and does not change the zoom")

        picture.doubleTap()
        XCTAssertEqual(picture.value as? String, "1.0x", "a double tap on a zoomed picture fits it")
        picture.doubleTap()
        XCTAssertEqual(picture.value as? String, "2.0x", "and from fit it goes to 2x")
        // The controls hid themselves while the picture was being handled. A single tap is not
        // swallowed by the zoom: it brings them back, and Close still works.
        sleep(1)
        picture.tap()
        let close = app.buttons["monitor_close"]
        XCTAssertTrue(close.waitForExistence(timeout: 4), "a single tap restores the controls")
        close.tap()
        XCTAssertTrue(app.buttons["sos_trigger"].waitForExistence(timeout: 5))
    }
}
