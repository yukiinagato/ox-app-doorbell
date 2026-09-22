import Foundation
import AVFoundation
import UIKit
import XCTest

@testable import Doorbell

final class CoreBridgeLifecycleTests: XCTestCase {
    private final class Locked<Value> {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
        func change(_ body: (inout Value) -> Void) {
            lock.lock(); defer { lock.unlock() }; body(&value)
        }
    }

    private var directories: [URL] = []
    private var bridges: [CoreBridge] = []
    private let boot = "{\"name\":\"T20 lifecycle\",\"role\":\"indoor_panel\",\"listen_port\":0,\"http_port\":0}"

    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("doorbell-t20-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        directories.append(path)
        return path
    }

    private func runningBridge() throws -> (CoreBridge, URL) {
        let bridge = CoreBridge()
        let path = try directory()
        bridges.append(bridge)
        XCTAssertTrue(bridge.start(dataDir: path.path, bootJson: boot))
        XCTAssertTrue(bridge.isRunning)
        return (bridge, path)
    }

    func testPeerFrameLateCallCannotDisplayOrClearSuccessorBusy() throws {
        let (bridge, _) = try runningBridge()
        var boot = BootConfig()
        boot.door = "front"
        let screen = MainViewController(core: bridge, boot: boot, runtime: nil)
        var currentCall = "call-A"
        screen.callTimingSnapshotForTesting = {
            guard let generation = bridge.runningGeneration else { return nil }
            return CallTiming.Snapshot(document: ["active_calls": [["call_id": currentCall,
                "door": "front", "state": "in_call", "stage_revision": 0,
                "dialog_owner": "web-owner"]]], coreGeneration: generation, requestedAt: 0)
        }
        var requests: [(URLRequest, (Data?, URLResponse?) -> Void)] = []
        screen.peerFrameLoadForTesting = { requests.append(($0, $1)) }
        UIGraphicsBeginImageContext(CGSize(width: 2, height: 2))
        UIColor.red.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(UIGraphicsGetImageFromCurrentImageContext()?.pngData())
        UIGraphicsEndImageContext()
        func reply(_ index: Int, call: String, sequence: String = "10", owner: String = "web-owner") {
            let headers = ["X-Doorbell-Call-Id": call, "X-Doorbell-Stage-Revision": "0",
                "X-Doorbell-Dialog-Owner": owner,
                "X-Doorbell-Media-Generation": "0123456789abcdef0123456789abcdef",
                "X-Doorbell-Frame-Sequence": sequence]
            requests[index].1(image, HTTPURLResponse(url: requests[index].0.url!, statusCode: 200,
                                                   httpVersion: "HTTP/1.1", headerFields: headers))
        }
        func drain() {
            let completed = expectation(description: "queued production image delivery")
            DispatchQueue.main.async { completed.fulfill() }
            wait(for: [completed], timeout: 2)
        }
        screen.setPeerCallForTesting(currentCall)
        screen.pollPeerFrameForTesting()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].0.url!.absoluteString.contains("call_id=call-A"))
        XCTAssertTrue(requests[0].0.url!.absoluteString.contains("stage_revision=0"))
        currentCall = "call-B"
        screen.setPeerCallForTesting(currentCall)
        screen.pollPeerFrameForTesting()
        XCTAssertEqual(requests.count, 2)
        reply(0, call: "call-A")
        drain()
        XCTAssertNil(screen.peerFrameForTesting)
        XCTAssertTrue(screen.peerPollBusyForTesting, "A cannot clear the pending B request")
        reply(1, call: "call-B", owner: "other-owner")
        drain()
        XCTAssertNil(screen.peerFrameForTesting, "a mismatched response owner cannot display")
        XCTAssertFalse(screen.peerPollBusyForTesting)
        screen.pollPeerFrameForTesting()
        reply(2, call: "call-B")
        drain()
        XCTAssertNotNil(screen.peerFrameForTesting)
        let acceptedImage = screen.peerFrameForTesting
        screen.pollPeerFrameForTesting()
        reply(3, call: "call-B", sequence: "10")
        drain()
        XCTAssertTrue(screen.peerFrameForTesting === acceptedImage, "duplicate ten cannot redraw the same frame")
        screen.pollPeerFrameForTesting()
        reply(4, call: "call-B", sequence: "9")
        drain()
        XCTAssertTrue(screen.peerFrameForTesting === acceptedImage, "sequence nine cannot replace ten")
        screen.pollPeerFrameForTesting()
        currentCall = ""
        screen.setPeerCallForTesting("")
        reply(5, call: "call-B", sequence: "11")
        drain()
        XCTAssertNil(screen.peerFrameForTesting, "end clears the image and rejects late B delivery")
    }

    override func tearDown() {
        let stopped = expectation(description: "all owned Core instances stopped")
        stopped.expectedFulfillmentCount = max(bridges.count, 1)
        if bridges.isEmpty { stopped.fulfill() }
        for bridge in bridges {
            bridge.setLifecycleTestHooks(.init())
            bridge.stop { stopped.fulfill() }
        }
        wait(for: [stopped], timeout: 15)
        for path in directories { try? FileManager.default.removeItem(at: path) }
        super.tearDown()
    }

    func testTimingSnapshotHoldsLeaseAndDropsResultWhenCoreStops() throws {
        let (bridge, _) = try runningBridge()
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var hooks = CoreBridge.LifecycleTestHooks()
        hooks.afterAcquire = {
            acquired.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        }
        bridge.setLifecycleTestHooks(hooks)
        let read = expectation(description: "stale timing snapshot discarded")
        DispatchQueue.global().async {
            XCTAssertNil(bridge.callTimingSnapshot())
            read.fulfill()
        }
        XCTAssertEqual(acquired.wait(timeout: .now() + 5), .success)
        let stopped = expectation(description: "snapshot lease drains before stop")
        bridge.stop { stopped.fulfill() }
        XCTAssertEqual(bridge.lifecycleTestSnapshot.inFlight, 1)
        XCTAssertNil(bridge.callTimingSnapshot())
        release.signal()
        wait(for: [read, stopped], timeout: 15)
    }

    func testForegroundRefreshRetiresVisibleCallMissingFromRealCoreSnapshot() throws {
        let (bridge, _) = try runningBridge()
        var boot = BootConfig()
        boot.door = "front"
        let screen = MainViewController(core: bridge, boot: boot, runtime: nil)
        var held = try XCTUnwrap(bridge.callTimingSnapshot())
        let oldGeneration = held.document["snapshot_generation"] as? String
        screen.callTimingSnapshotForTesting = { held }
        screen.setVisibleCallForTimingTest("already-ended")
        screen.suspendCallTimingForTesting()
        screen.resumeCallTimingForTesting()
        for _ in 0..<3 { screen.refreshCallTimingForTesting() }
        XCTAssertEqual(screen.visibleCallForTimingTest, "already-ended",
                       "the frozen pre-sleep sample, including unchanged age, is only Checking")
        XCTAssertNotNil(screen.callDetailForTimingTest)
        let resampled = expectation(description: "a new real Core sample clears the stale view")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let fresh = bridge.callTimingSnapshot() else {
                XCTFail("Core must still be available")
                resampled.fulfill()
                return
            }
            XCTAssertNotEqual(fresh.document["snapshot_generation"] as? String, oldGeneration)
            held = fresh
            screen.refreshCallTimingForTesting()
            XCTAssertEqual(screen.visibleCallForTimingTest, "")
            resampled.fulfill()
        }
        wait(for: [resampled], timeout: 6)
    }

    func testQueuedCallTimerCannotMutateRestartedCoreOrNewCall() throws {
        let (bridge, path) = try runningBridge()
        let stopped = expectation(description: "first Core stops")
        bridge.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 15)
        var boot = BootConfig()
        boot.door = "front"
        let screen = MainViewController(core: bridge, boot: boot, runtime: nil)
        screen.setVisibleCallForTimingTest("old-call")
        screen.refreshCallTimingForTesting()
        let oldCallback = try XCTUnwrap(screen.callTimerCallbackForTesting)
        XCTAssertTrue(bridge.start(dataDir: path.path, bootJson: self.boot))
        let revision = screen.callTimerRevisionForTesting
        oldCallback()
        XCTAssertEqual(screen.visibleCallForTimingTest, "old-call",
                       "even an unchanged call ID cannot admit the old Core timer")
        XCTAssertEqual(screen.callTimerRevisionForTesting, revision)
        screen.setVisibleCallForTimingTest("replacement-call")
        oldCallback()
        XCTAssertEqual(screen.visibleCallForTimingTest, "replacement-call")
        XCTAssertEqual(screen.callTimerRevisionForTesting, revision)
        screen.resumeCallTimingForTesting()
        let resumedCall = screen.visibleCallForTimingTest
        let resumedRevision = screen.callTimerRevisionForTesting
        oldCallback()
        XCTAssertEqual(screen.visibleCallForTimingTest, resumedCall)
        XCTAssertEqual(screen.callTimerRevisionForTesting, resumedRevision)
    }

    func testLeaseHeldBetweenAcquireAndCReadDelaysDestroy() throws {
        let (bridge, _) = try runningBridge()
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let destroyed = Locked(0)
        var hooks = CoreBridge.LifecycleTestHooks()
        hooks.afterAcquire = {
            acquired.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        }
        hooks.afterDestroy = { destroyed.change { $0 += 1 } }
        bridge.setLifecycleTestHooks(hooks)
        let read = expectation(description: "real clock C call copied its result")
        DispatchQueue.global().async {
            XCTAssertNotNil(bridge.localTime())
            read.fulfill()
        }
        XCTAssertEqual(acquired.wait(timeout: .now() + 5), .success)
        let stopped = expectation(description: "stop waits for the call lease")
        bridge.stop { stopped.fulfill() }
        XCTAssertTrue(bridge.lifecycleTestSnapshot.stopping)
        XCTAssertEqual(bridge.lifecycleTestSnapshot.inFlight, 1)
        XCTAssertEqual(destroyed.read(), 0)
        release.signal()
        wait(for: [read, stopped], timeout: 15)
        XCTAssertEqual(destroyed.read(), 1)
        XCTAssertFalse(bridge.isRunning)
    }

    func testStoppingRejectsNewReadsAndCameraCalls() throws {
        let (bridge, _) = try runningBridge()
        let generation = try XCTUnwrap(bridge.runningGeneration)
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var hooks = CoreBridge.LifecycleTestHooks()
        hooks.afterAcquire = {
            acquired.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        }
        bridge.setLifecycleTestHooks(hooks)
        let oldRead = expectation(description: "entered read finishes")
        DispatchQueue.global().async { _ = bridge.status(); oldRead.fulfill() }
        XCTAssertEqual(acquired.wait(timeout: .now() + 5), .success)
        let stopped = expectation(description: "stopped")
        bridge.stop { stopped.fulfill() }
        XCTAssertNil(bridge.status())
        XCTAssertNil(bridge.localTime())
        XCTAssertNil(bridge.audioVolumes())
        XCTAssertNil(bridge.config())
        XCTAssertFalse(bridge.videoEncoderWanted())
        XCTAssertFalse(bridge.takeVideoKeyframeRequest())
        bridge.onEncodedFrame(Data([0, 0, 1, 5]), isKeyframe: true, tsMs: 0,
                              coreGeneration: generation)
        var pixel: UInt8 = 0
        withUnsafePointer(to: &pixel) {
            bridge.onCameraFrame($0, format: 3, width: 1, height: 1, stride: 4, tsMs: 0,
                                 coreGeneration: generation)
        }
        XCTAssertEqual(bridge.lifecycleTestSnapshot.inFlight, 1)
        release.signal()
        wait(for: [oldRead, stopped], timeout: 15)
    }

    func testCoreCallbackCanReachMainWhileMainRequestsStop() throws {
        let (bridge, _) = try runningBridge()
        let entered = Locked(false)
        let mainReached = expectation(description: "Core callback gets main-queue work")
        let stopped = expectation(description: "teardown drains the callback off main")
        var hooks = CoreBridge.LifecycleTestHooks()
        hooks.uiCallback = {
            var first = false
            entered.change { if !$0 { $0 = true; first = true } }
            guard first else { return }
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                bridge.stop { stopped.fulfill() }
                mainReached.fulfill()
                finished.signal()
            }
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        }
        bridge.setLifecycleTestHooks(hooks)
        DispatchQueue.global().async { bridge.pairingMode(seconds: 0) }
        wait(for: [mainReached, stopped], timeout: 15)
    }

    func testOldCoreUiDeliveryIsRejectedAfterRestart() throws {
        let (bridge, path) = try runningBridge()
        let queued = Locked<[() -> Void]>([])
        let verdicts = Locked<[Bool]>([])
        let callbackQueued = expectation(description: "actual Core event copied for delivery")
        callbackQueued.assertForOverFulfill = false
        var hooks = CoreBridge.LifecycleTestHooks()
        hooks.enqueueUi = { work in
            queued.change { $0.append(work) }
            callbackQueued.fulfill()
        }
        hooks.uiDelivery = { _, current in verdicts.change { $0.append(current) } }
        bridge.setLifecycleTestHooks(hooks)
        bridge.pairingMode(seconds: 0)
        wait(for: [callbackQueued], timeout: 5)
        let stopped = expectation(description: "old generation stopped")
        bridge.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 15)
        let oldCallbacks = queued.read()
        XCTAssertFalse(oldCallbacks.isEmpty, "actual Core callback must reach the deferred executor")
        XCTAssertTrue(bridge.start(dataDir: path.path, bootJson: boot))
        verdicts.change { $0.removeAll() }
        oldCallbacks.forEach { $0() }
        XCTAssertEqual(verdicts.read().count, oldCallbacks.count)
        XCTAssertTrue(verdicts.read().allSatisfy { !$0 })
    }

    func testOldClockResultCannotPublishIntoRestartedCoreUi() throws {
        let (bridge, path) = try runningBridge()
        let queued = Locked<[() -> Void]>([])
        let hasDelivery = expectation(description: "clock result copied for delivery")
        let clock = DoorbellClockSource(deliver: { work in
            queued.change { $0.append(work) }
            hasDelivery.fulfill()
        })
        clock.refresh(bridge)
        wait(for: [hasDelivery], timeout: 5)
        let oldGeneration = bridge.runningGeneration
        let stopped = expectation(description: "clock source generation retired")
        bridge.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 15)
        XCTAssertTrue(bridge.start(dataDir: path.path, bootJson: boot))
        XCTAssertNotEqual(bridge.runningGeneration, oldGeneration)
        queued.read().forEach { $0() }
        XCTAssertFalse(clock.hasReading)
        XCTAssertTrue(clock.waitingForCore)
    }

    func testConcurrentStopCompletionsDestroyOnceAndAllowRestart() throws {
        let (bridge, path) = try runningBridge()
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let destroys = Locked(0)
        var hooks = CoreBridge.LifecycleTestHooks()
        hooks.afterAcquire = {
            acquired.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        }
        hooks.afterDestroy = { destroys.change { $0 += 1 } }
        bridge.setLifecycleTestHooks(hooks)
        let read = expectation(description: "held reader completes")
        DispatchQueue.global().async { _ = bridge.debugInfo(); read.fulfill() }
        XCTAssertEqual(acquired.wait(timeout: .now() + 5), .success)
        let accepted = DispatchGroup()
        let stopped = expectation(description: "both reset/stop continuations complete")
        stopped.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            accepted.enter()
            DispatchQueue.global().async {
                bridge.stop { stopped.fulfill() }
                accepted.leave()
            }
        }
        XCTAssertEqual(accepted.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(bridge.start(dataDir: path.path, bootJson: boot), "stopping cannot publish a new handle")
        release.signal()
        wait(for: [read, stopped], timeout: 15)
        XCTAssertEqual(destroys.read(), 1)
        bridge.setLifecycleTestHooks(.init())
        XCTAssertTrue(bridge.start(dataDir: path.path, bootJson: boot))
        XCTAssertNotNil(bridge.localTime())
    }

    func testStopDuringStartNeverPublishesStartingHandle() throws {
        let bridge = CoreBridge()
        let path = try directory()
        bridges.append(bridge)
        let created = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let destroys = Locked(0)
        var hooks = CoreBridge.LifecycleTestHooks()
        hooks.beforeStart = {
            created.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        }
        hooks.afterDestroy = { destroys.change { $0 += 1 } }
        bridge.setLifecycleTestHooks(hooks)
        let startReturned = expectation(description: "cancelled start returns false")
        let boot = self.boot
        DispatchQueue.global().async {
            XCTAssertFalse(bridge.start(dataDir: path.path, bootJson: boot))
            startReturned.fulfill()
        }
        XCTAssertEqual(created.wait(timeout: .now() + 5), .success)
        XCTAssertNil(bridge.localTime())
        let stopped = expectation(description: "cancelled startup destroyed once")
        bridge.stop { stopped.fulfill() }
        release.signal()
        wait(for: [startReturned, stopped], timeout: 15)
        XCTAssertEqual(destroys.read(), 1)
        bridge.setLifecycleTestHooks(.init())
        XCTAssertTrue(bridge.start(dataDir: path.path, bootJson: boot))
    }

    func testFailedStartIsDrainedBeforeRetry() throws {
        let bridge = CoreBridge()
        let path = try directory()
        bridges.append(bridge)
        let invalid = path.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: invalid)
        XCTAssertFalse(bridge.start(dataDir: invalid.path, bootJson: boot))
        XCTAssertNil(bridge.localTime())
        let stopped = expectation(description: "failed startup cleanup complete")
        bridge.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 15)
        XCTAssertTrue(bridge.start(dataDir: path.path, bootJson: boot))
    }

    func testOldCameraAndEncodedFramesCannotAcquireRestartedCore() throws {
        let (bridge, path) = try runningBridge()
        let generation = try XCTUnwrap(bridge.runningGeneration)
        let producerReady = expectation(description: "old producer has copied its generation")
        let release = DispatchSemaphore(value: 0)
        let producerFinished = expectation(description: "both old frame paths returned")
        DispatchQueue.global().async {
            producerReady.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
            bridge.onEncodedFrame(Data([0, 0, 1, 5]), isKeyframe: true, tsMs: 0,
                                  coreGeneration: generation)
            var pixel: UInt32 = 0
            withUnsafeBytes(of: &pixel) { buffer in
                bridge.onCameraFrame(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                     format: 3, width: 1, height: 1, stride: 4, tsMs: 0,
                                     coreGeneration: generation)
            }
            producerFinished.fulfill()
        }
        wait(for: [producerReady], timeout: 5)
        let stopped = expectation(description: "old producer's Core is destroyed")
        bridge.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 15)
        XCTAssertTrue(bridge.start(dataDir: path.path, bootJson: boot))
        let accepted = Locked(0)
        var hooks = CoreBridge.LifecycleTestHooks()
        hooks.afterAcquire = { accepted.change { $0 += 1 } }
        bridge.setLifecycleTestHooks(hooks)
        release.signal()
        wait(for: [producerFinished], timeout: 5)
        XCTAssertEqual(accepted.read(), 0, "old generations must fail inside acquire")
        XCTAssertEqual(bridge.lifecycleTestSnapshot.inFlight, 0)
        let currentGeneration = try XCTUnwrap(bridge.runningGeneration)
        bridge.onEncodedFrame(Data([0, 0, 1, 5]), isKeyframe: true, tsMs: 0,
                              coreGeneration: currentGeneration)
        var pixel: UInt32 = 0
        withUnsafeBytes(of: &pixel) { buffer in
            bridge.onCameraFrame(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                 format: 3, width: 1, height: 1, stride: 4, tsMs: 0,
                                 coreGeneration: currentGeneration)
        }
        XCTAssertEqual(accepted.read(), 2, "current producer generations remain admitted")
    }

    func testResetSupersedesIdentityRestartBeforeQueuedRestartRuns() throws {
        try checkResetSupersedesIdentityRestart(identityReachedStop: false)
    }

    func testResetSupersedesIdentityRestartWithStopAlreadyPending() throws {
        try checkResetSupersedesIdentityRestart(identityReachedStop: true)
    }

    private func checkResetSupersedesIdentityRestart(identityReachedStop: Bool) throws {
        let delegate = AppDelegate()
        let bridge = delegate.core
        let path = try directory()
        bridges.append(bridge)
        XCTAssertTrue(bridge.start(dataDir: path.path, bootJson: boot))
        delegate.window = ActivityWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        delegate.window?.rootViewController = UIViewController()
        let acquired = expectation(description: "hold an actual call while transitions overlap")
        let release = DispatchSemaphore(value: 0)
        let read = expectation(description: "held call completes")
        let destroys = Locked(0)
        var hooks = CoreBridge.LifecycleTestHooks()
        hooks.afterAcquire = {
            acquired.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        }
        hooks.afterDestroy = { destroys.change { $0 += 1 } }
        bridge.setLifecycleTestHooks(hooks)
        DispatchQueue.global().async { _ = bridge.localTime(); read.fulfill() }
        wait(for: [acquired], timeout: 5)
        let identityStopping = expectation(description: "identity transition reached stop")
        identityStopping.isInverted = !identityReachedStop
        let resetStopped = expectation(description: "reset owns the stopped continuation")
        let identityRestarts = Locked(0)
        delegate.lifecycleTransitionTestHooks.identityWillStop = { identityStopping.fulfill() }
        delegate.lifecycleTransitionTestHooks.identityDidStop = { identityRestarts.change { $0 += 1 } }
        // Intercept destructive persistence only after the production reset state machine and
        // real Core stop finish; this test must not erase the hosted application's own settings.
        delegate.lifecycleTransitionTestHooks.resetDidStop = { resetStopped.fulfill() }
        delegate.requestIdentityRestartForTesting()
        if identityReachedStop { wait(for: [identityStopping], timeout: 5) }
        delegate.resetLocalPairingForTesting()
        delegate.resetLocalPairingForTesting()
        release.signal()
        wait(for: [read, resetStopped], timeout: 15)
        if !identityReachedStop { wait(for: [identityStopping], timeout: 0.05) }
        let continuationsDrained = expectation(description: "main-queue continuations drained")
        DispatchQueue.main.async { continuationsDrained.fulfill() }
        wait(for: [continuationsDrained], timeout: 5)
        XCTAssertEqual(identityRestarts.read(), 0)
        XCTAssertEqual(destroys.read(), 1)
        XCTAssertFalse(bridge.isRunning)
    }

    func testOldEncoderFailureCannotPoisonReplacementInSameCore() throws {
        let (bridge, _) = try runningBridge()
        let encoder = VideoEncoderVT(core: bridge)
        var states: [String] = []
        encoder.runtimeStatus = { _, state in states.append(state) }
        encoder.start(fps: 25, bitrateKbps: 1500)
        let oldFailure = encoder.failureCallbackForTesting()
        oldFailure()
        XCTAssertTrue(encoder.hasTerminalFailure)
        encoder.stop()
        encoder.start(fps: 25, bitrateKbps: 1500)
        // Cover both an old status already queued for main and a callback resuming after restart.
        oldFailure()
        XCTAssertFalse(encoder.hasTerminalFailure)
        let delivered = expectation(description: "only the current encoder publishes status")
        DispatchQueue.main.async {
            XCTAssertEqual(states, ["testing"])
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 5)
        encoder.stop()
    }

    func testOldCaptureObserverCannotReportFailureForReplacementInSameCore() throws {
        let (bridge, _) = try runningBridge()
        var states: [String] = []
        let camera = CameraFeeder(core: bridge) { _, state in states.append(state) }
        let oldSession = AVCaptureSession()
        let oldObserver = camera.beginSessionForTesting(oldSession)
        NotificationCenter.default.post(name: .AVCaptureSessionRuntimeError, object: oldSession)
        let replacement = AVCaptureSession()
        _ = camera.beginSessionForTesting(replacement)
        // The returned closure is the same production handler used by the registered observer.
        // Invoking it now models an old notification already executing when its observer retired.
        oldObserver()
        let oldDelivered = expectation(description: "retired capture callbacks are discarded")
        DispatchQueue.main.async {
            XCTAssertTrue(states.isEmpty)
            oldDelivered.fulfill()
        }
        wait(for: [oldDelivered], timeout: 5)
        NotificationCenter.default.post(name: .AVCaptureSessionRuntimeError, object: replacement)
        let currentDelivered = expectation(description: "current capture notification still works")
        DispatchQueue.main.async {
            XCTAssertEqual(states, ["runtime_failed"])
            currentDelivered.fulfill()
        }
        wait(for: [currentDelivered], timeout: 5)
        camera.stop()
    }
}
