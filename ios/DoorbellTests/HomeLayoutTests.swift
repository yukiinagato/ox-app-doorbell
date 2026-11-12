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

    func testThePictureIsAspectFittedInTheStage() {
        // 16:9, 4:3 and a rotated 9:16 source, in a portrait and a landscape stage.
        let portrait = CGSize(width: 400, height: 600), landscape = CGSize(width: 800, height: 400)
        XCTAssertEqual(VideoZoom.fittedSize(picture: CGSize(width: 1280, height: 720),
                                            stage: portrait), CGSize(width: 400, height: 225))
        XCTAssertEqual(VideoZoom.fittedSize(picture: CGSize(width: 640, height: 480),
                                            stage: portrait), CGSize(width: 400, height: 300))
        XCTAssertEqual(VideoZoom.fittedSize(picture: CGSize(width: 720, height: 1280),
                                            stage: portrait), CGSize(width: 337.5, height: 600))
        XCTAssertEqual(VideoZoom.fittedSize(picture: CGSize(width: 1280, height: 720),
                                            stage: landscape).height, 400, accuracy: 0.001)
        XCTAssertEqual(VideoZoom.fittedSize(picture: CGSize(width: 720, height: 1280),
                                            stage: landscape), CGSize(width: 225, height: 400))
        XCTAssertEqual(VideoZoom.fittedSize(picture: .zero, stage: portrait), portrait,
                       "an unknown picture fills the stage until the first frame says otherwise")
    }

    func testAZoomedPictureGrowsIntoTheLetterboxBars() {
        let stage = CGSize(width: 400, height: 600)
        let fitted = VideoZoom.fittedSize(picture: CGSize(width: 1280, height: 720), stage: stage)
        let zoomed = CGSize(width: fitted.width * 2, height: fitted.height * 2)
        let visible = VideoZoom.visibleSize(zoomed: zoomed, stage: stage)
        XCTAssertEqual(visible, CGSize(width: 400, height: 450))
        XCTAssertGreaterThan(visible.width * visible.height, fitted.width * fitted.height,
                             "the clip rectangle is the stage, not the fitted 1x rectangle")
        let covering = VideoZoom.visibleSize(zoomed: CGSize(width: fitted.width * 4,
                                                            height: fitted.height * 4),
                                             stage: stage)
        XCTAssertEqual(covering, stage, "at 4x this picture covers the whole stage")
    }

    func testPanIsClampedPerAxisAgainstTheStage() {
        let stage = CGSize(width: 400, height: 600)
        // Wider than the stage, shorter than it: free to pan sideways, centred vertically.
        let zoomed = CGSize(width: 800, height: 450)
        XCTAssertEqual(VideoZoom.clampedOrigin(.zero, zoomed: zoomed, stage: stage),
                       CGPoint(x: 0, y: 75))
        XCTAssertEqual(VideoZoom.clampedOrigin(CGPoint(x: 120, y: -300), zoomed: zoomed,
                                               stage: stage), CGPoint(x: 0, y: 75),
                       "the leading edge may not come inside the stage")
        XCTAssertEqual(VideoZoom.clampedOrigin(CGPoint(x: -9999, y: 0), zoomed: zoomed,
                                               stage: stage), CGPoint(x: -400, y: 75),
                       "nor the trailing edge")
        XCTAssertEqual(VideoZoom.clampedOrigin(CGPoint(x: -150, y: 0), zoomed: zoomed,
                                               stage: stage), CGPoint(x: -150, y: 75))
        // Larger on both axes: both clamp, neither is centred.
        let large = CGSize(width: 1600, height: 900)
        XCTAssertEqual(VideoZoom.clampedOrigin(CGPoint(x: -100, y: -100), zoomed: large,
                                               stage: stage), CGPoint(x: -100, y: -100))
        XCTAssertEqual(VideoZoom.clampedOrigin(CGPoint(x: 50, y: -1000), zoomed: large,
                                               stage: stage), CGPoint(x: 0, y: -300))
        // Not larger on either axis: centred on both.
        XCTAssertEqual(VideoZoom.clampedOrigin(CGPoint(x: 33, y: 44),
                                               zoomed: CGSize(width: 400, height: 225),
                                               stage: stage), CGPoint(x: 0, y: 187.5))
    }

    func testADoubleTapNearACornerStaysInsideThePicture() {
        let stage = CGSize(width: 400, height: 600), picture = CGSize(width: 400, height: 225)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 225), CGPoint(x: -50, y: 900)] {
            for scale in [CGFloat(1), 2, 4, 10] {
                let rect = VideoZoom.visibleRect(scale: scale, around: point, picture: picture,
                                                 stage: stage)
                XCTAssertGreaterThanOrEqual(rect.minX, 0)
                XCTAssertGreaterThanOrEqual(rect.minY, 0)
                XCTAssertLessThanOrEqual(rect.maxX, picture.width + 0.001)
                XCTAssertLessThanOrEqual(rect.maxY, picture.height + 0.001)
            }
        }
        XCTAssertEqual(VideoZoom.visibleRect(scale: 2, around: CGPoint(x: 200, y: 112.5),
                                             picture: picture, stage: stage),
                       CGRect(x: 100, y: 0, width: 200, height: 225),
                       "a short picture is shown whole on the axis the stage has room for")
    }

    /// The scroll view rounds offsets to the pixel grid, so frames are compared to half a point.
    private func assertFrame(_ frame: CGRect, _ expected: CGRect, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        for (got, want) in [(frame.minX, expected.minX), (frame.minY, expected.minY),
                            (frame.width, expected.width), (frame.height, expected.height)] {
            XCTAssertEqual(got, want, accuracy: 0.5, message, file: file, line: line)
        }
    }

    func testTheZoomViewFitsClampsAndResets() {
        let view = ZoomableVideoView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        view.host(UIView())
        view.pictureSize = CGSize(width: 1280, height: 720)
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 1)
        assertFrame(view.pictureFrameForTesting,
                    CGRect(x: 0, y: 187.5, width: 400, height: 225), "fitted and centred at 1x")

        view.setZoomForTesting(2, origin: CGPoint(x: 500, y: 500))
        assertFrame(view.pictureFrameForTesting, CGRect(x: 0, y: 75, width: 800, height: 450),
                    "wider than the stage: clamped; shorter: centred, into the bars")
        view.setZoomForTesting(9, origin: CGPoint(x: -5000, y: -5000))
        XCTAssertEqual(view.zoomScale, 4, accuracy: 0.001)
        assertFrame(view.pictureFrameForTesting,
                    CGRect(x: -1200, y: -300, width: 1600, height: 900),
                    "covering the stage, the far edges stop at the stage edges")

        view.pictureSize = CGSize(width: 720, height: 1280)
        XCTAssertEqual(view.zoomScale, 4, accuracy: 0.001, "a new aspect keeps the zoom")
        view.resetZoom()
        XCTAssertEqual(view.zoomScale, 1, accuracy: 0.001)
        assertFrame(view.pictureFrameForTesting,
                    CGRect(x: 31.25, y: 0, width: 337.5, height: 600))
        XCTAssertEqual(view.doubleTap.numberOfTapsRequired, 2,
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
