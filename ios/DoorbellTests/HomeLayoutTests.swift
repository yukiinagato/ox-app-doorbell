import UIKit
import XCTest

@testable import Doorbell

/// The geometry the redesigned screens decide for themselves: live-picture zoom limits, the door
/// grid's columns, and the shape of the indoor panel's tab shell.
final class HomeLayoutTests: XCTestCase {

    // MARK: - Live-picture zoom

    func testZoomScaleIsClampedBetweenFitAndFourTimes() {
        XCTAssertEqual(VideoZoom.clampedScale(0.2), 1)
        XCTAssertEqual(VideoZoom.clampedScale(1), 1)
        XCTAssertEqual(VideoZoom.clampedScale(2.5), 2.5)
        XCTAssertEqual(VideoZoom.clampedScale(9), 4)
        XCTAssertEqual(VideoZoom.clampedScale(.nan), 1)
        XCTAssertEqual(VideoZoom.clampedScale(.infinity), 1)
    }

    func testDoubleTapTogglesBetweenFitAndTwoTimes() {
        XCTAssertEqual(VideoZoom.doubleTapTarget(from: 1), 2)
        XCTAssertEqual(VideoZoom.doubleTapTarget(from: 2), 1)
        XCTAssertEqual(VideoZoom.doubleTapTarget(from: 3.7), 1)
    }

    func testAZoomNearACornerNeverShowsBeyondThePicture() {
        let bounds = CGSize(width: 400, height: 300)
        let centre = VideoZoom.visibleRect(scale: 2, around: CGPoint(x: 200, y: 150), in: bounds)
        XCTAssertEqual(centre, CGRect(x: 100, y: 75, width: 200, height: 150))
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 300), CGPoint(x: -50, y: 900),
                      CGPoint(x: 399, y: 1)] {
            for scale in [CGFloat(1), 2, 4, 10] {
                let rect = VideoZoom.visibleRect(scale: scale, around: point, in: bounds)
                XCTAssertGreaterThanOrEqual(rect.minX, 0)
                XCTAssertGreaterThanOrEqual(rect.minY, 0)
                XCTAssertLessThanOrEqual(rect.maxX, bounds.width + 0.001)
                XCTAssertLessThanOrEqual(rect.maxY, bounds.height + 0.001)
            }
        }
    }

    func testPanOffsetStopsAtThePictureEdges() {
        let bounds = CGSize(width: 400, height: 300)
        XCTAssertEqual(VideoZoom.clampedOffset(CGPoint(x: 50, y: 50), scale: 1, bounds: bounds),
                       .zero, "a fitted picture cannot be dragged")
        XCTAssertEqual(VideoZoom.clampedOffset(CGPoint(x: -20, y: -20), scale: 2, bounds: bounds),
                       .zero)
        XCTAssertEqual(VideoZoom.clampedOffset(CGPoint(x: 9999, y: 9999), scale: 2,
                                               bounds: bounds), CGPoint(x: 400, y: 300))
        XCTAssertEqual(VideoZoom.clampedOffset(CGPoint(x: 120, y: 80), scale: 4, bounds: bounds),
                       CGPoint(x: 120, y: 80))
    }

    func testTheZoomViewClampsAndResets() {
        let view = ZoomableVideoView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let picture = UIView()
        view.host(picture)
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 1)
        view.setZoomForTesting(9, offset: CGPoint(x: 5000, y: 5000))
        XCTAssertEqual(view.zoomScale, 4, accuracy: 0.001)
        XCTAssertLessThanOrEqual(view.contentOffsetForTesting.x, 1200.5)
        XCTAssertLessThanOrEqual(view.contentOffsetForTesting.y, 900.5)
        view.resetZoom()
        XCTAssertEqual(view.zoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(view.contentOffsetForTesting, .zero)
        XCTAssertFalse(view.doubleTap.cancelsTouchesInView && view.doubleTap.numberOfTapsRequired == 1,
                       "only a double tap is claimed; single taps reach the screen")
    }

    // MARK: - Door grid

    func testDoorTilesTakeOneTwoOrThreeColumnsFromTheWidth() {
        XCTAssertEqual(DashboardView.columnCount(forWidth: 343), 1)
        XCTAssertEqual(DashboardView.columnCount(forWidth: 599), 1)
        XCTAssertEqual(DashboardView.columnCount(forWidth: 600), 2)
        XCTAssertEqual(DashboardView.columnCount(forWidth: 899), 2)
        XCTAssertEqual(DashboardView.columnCount(forWidth: 900), 3)
        XCTAssertEqual(DashboardView.columnCount(forWidth: 1920), 3)
    }

    func testTilesFillTheRowAndKeepATouchableHeight() {
        for (width, columns) in [(CGFloat(343), 1), (704, 2), (1000, 3)] {
            let size = DashboardView.tileSize(contentWidth: width, columns: columns, spacing: 12)
            XCTAssertLessThanOrEqual(size.width * CGFloat(columns) + 12 * CGFloat(columns - 1),
                                     width)
            XCTAssertGreaterThanOrEqual(size.height, 160)
            XCTAssertLessThanOrEqual(size.height, 360)
        }
    }

    // MARK: - Tabs

    func testThePanelHasThreeTabsAndSettingsStaysLockedWithoutThePassword() {
        let texts = Texts()
        let core = CoreBridge()
        let boot = BootConfig()
        let dashboard = DashboardView(core: core, boot: boot, texts: texts,
                                      sosControl: SosTriggerButton(texts: texts))
        let gate = SettingsGateViewController(texts: texts)
        var requests = 0
        gate.onUnlockRequested = { requests += 1 }
        let tabs = PanelTabBarController(
            home: HomeViewController(dashboard: dashboard, title: "Home"),
            history: CallHistoryViewController(core: core, texts: texts, lang: "en",
                                               embedded: true),
            settingsGate: gate, texts: texts)
        XCTAssertEqual(tabs.viewControllers?.count, 3)
        XCTAssertTrue(tabs.viewControllers?.first is UINavigationController)
        XCTAssertEqual(tabs.currentTab, .home)

        XCTAssertFalse(tabs.tabBarController(tabs, shouldSelect: gate),
                       "the Settings tab does not open by itself")
        tabs.show(.settings)
        XCTAssertEqual(requests, 2, "both ways in ask for the password instead")
        XCTAssertEqual(tabs.currentTab, .home)
        XCTAssertFalse(gate.isUnlocked)

        tabs.show(.history)
        XCTAssertEqual(tabs.currentTab, .history)
        tabs.setUnreadMissed(3)
        XCTAssertEqual(tabs.history.tabBarItem.badgeValue, "3")
        tabs.setUnreadMissed(0)
        XCTAssertNil(tabs.history.tabBarItem.badgeValue)
        tabs.returnHome()
        XCTAssertEqual(tabs.currentTab, .home)
    }

    // MARK: - SOS confirmation

    func testTheTriggerOnlyOpensTheConfirmationAndTheSlideThereConfirms() {
        let texts = Texts()
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let trigger = SosTriggerButton(texts: texts)
        trigger.countdownSeconds = 0
        host.view.addSubview(trigger)
        var triggers = 0
        trigger.onTriggered = { triggers += 1 }

        trigger.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(triggers, 0, "a tap raises nothing")
        let surface = try? XCTUnwrap(host.presentedViewController as? SosConfirmViewController)
        XCTAssertNotNil(surface)
        XCTAssertTrue(trigger.isConfirming)
        surface?.loadViewIfNeeded()
        XCTAssertFalse(surface?.slide.gestureRecognizerShouldBegin(UIPanGestureRecognizer()) ?? true,
                       "the sheet's own pan may not take a drag that starts on the slide")
        XCTAssertTrue(surface?.slide.gestureRecognizerShouldBegin(UITapGestureRecognizer()) ?? false)

        let confirmed = expectation(description: "the slide confirms after the surface closes")
        trigger.onTriggered = { triggers += 1; confirmed.fulfill() }
        surface?.slide.startCountdown()
        wait(for: [confirmed], timeout: 5)
        XCTAssertEqual(triggers, 1)
    }

    func testAbandoningTheConfirmationFiresNothing() {
        let texts = Texts()
        var confirmations = 0
        let surface = SosConfirmViewController(texts: texts, purpose: .send(countdown: 3)) {
            confirmations += 1
        }
        surface.loadViewIfNeeded()
        surface.slide.startCountdown()
        XCTAssertTrue(surface.slide.isCountingDown)
        surface.abandon()
        XCTAssertFalse(surface.slide.isCountingDown)
        XCTAssertEqual(confirmations, 0)
        XCTAssertEqual(SosConfirmation.idleTimeout, 10)
    }
}
