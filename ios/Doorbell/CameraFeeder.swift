import AVFoundation
import Foundation

// Camera callbacks arrive on the dedicated capture queue. Each bi-planar NV12 frame is repacked
// into tightly packed Y+UV storage whose lifetime covers the synchronous Core callback.
final class CameraFeeder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let core: CoreBridge
    private let runtimeStatus: (Bool, String) -> Void
    private var session: AVCaptureSession?
    private var runtimeErrorObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "doorbell-camera")
    private let runtimeLock = NSLock()
    private var nv12: [UInt8] = []
    private var reportedActive = false
    private var reportedState = "not_started"
    private var acceptingFrames = false
    private var captureCoreGeneration: UInt64?
    private var sessionGeneration: UInt64 = 0
    private weak var currentOutput: AVCaptureOutput?
    private var interruptionObservers: [NSObjectProtocol] = []
    // Monotonic seconds of the last start() and of the last delivered frame; read by the
    // stall watchdog so a session that was started but never (or no longer) delivers frames —
    // started while backgrounded, or robbed of the device by the pairing QR scanner — is
    // restarted instead of leaving every indoor panel without a picture.
    private var lastStartAt: CFTimeInterval = 0
    private var lastFrameAt: CFTimeInterval = 0

    private var currentEncoder: VideoEncoderVT?
    var encoder: VideoEncoderVT? {
        get { runtimeLock.lock(); defer { runtimeLock.unlock() }; return currentEncoder }
        set { runtimeLock.lock(); currentEncoder = newValue; runtimeLock.unlock() }
    }

    init(core: CoreBridge, runtimeStatus: @escaping (Bool, String) -> Void = { _, _ in }) {
        self.core = core
        self.runtimeStatus = runtimeStatus
        super.init()
    }

    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    @discardableResult
    func start(targetW: Int, targetH: Int) -> Bool {
        stop()
        guard let coreGeneration = core.runningGeneration else { return false }
        let generation = beginSession(coreGeneration: coreGeneration)
        IOSAvailability.logDebug("camera start target=\(targetW)x\(targetH)")
        guard case .authorized = AVCaptureDevice.authorizationStatus(for: .video) else {
            reportRuntime(active: false, state: "permission_denied")
            return false
        }
        guard let device = IOSAvailability.videoCaptureDevice() else {
            reportRuntime(active: false, state: "no_device")
            return false
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            reportRuntime(active: false, state: "input_failed")
            return false
        }
        let s = AVCaptureSession()
        s.beginConfiguration()
        let pixels = targetW * targetH
        if pixels >= 1280 * 720, s.canSetSessionPreset(.hd1280x720) {
            s.sessionPreset = .hd1280x720
        } else if s.canSetSessionPreset(.vga640x480) {
            s.sessionPreset = .vga640x480
        }
        guard s.canAddInput(input) else {
            reportRuntime(active: false, state: "configuration_failed")
            return false
        }
        s.addInput(input)

        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // NV12
        ]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(out) else {
            reportRuntime(active: false, state: "configuration_failed")
            return false
        }
        s.addOutput(out)
        // Rotation metadata uses portrait pixels as its reference, independent of the
        // front/back sensor's native mounting. Keep this fixed while the device moves.
        if let connection = out.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        } else {
            s.commitConfiguration()
            reportRuntime(active: false, state: "configuration_failed")
            return false
        }
        s.commitConfiguration()

        previewLayer = AVCaptureVideoPreviewLayer(session: s)
        session = s
        runtimeLock.lock()
        currentOutput = out
        acceptingFrames = true
        runtimeLock.unlock()
        runtimeLock.lock()
        lastStartAt = CACurrentMediaTime()
        runtimeLock.unlock()
        reportRuntime(active: false, state: "starting")
        installRuntimeErrorObserver(session: s, generation: generation)
        installInterruptionObservers(session: s, generation: generation)
        queue.async { s.startRunning() }
        return true
    }

    func stop() {
        runtimeLock.lock()
        acceptingFrames = false
        sessionGeneration &+= 1
        runtimeLock.unlock()
        if let observer = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            runtimeErrorObserver = nil
        }
        interruptionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        interruptionObservers.removeAll()
        let s = session
        session = nil
        previewLayer = nil
        queue.async { s?.stopRunning() }
        if s != nil { reportRuntime(active: false, state: "stopped") }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isAcceptingFrames() else { return }
        guard let token = frameGeneration(output: output) else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        runtimeLock.lock()
        lastFrameAt = CACurrentMediaTime()
        runtimeLock.unlock()
        reportRuntime(active: true, state: "active", generation: token.session)
        let tsMs = Int64(Date().timeIntervalSince1970 * 1000)

        encoder?.feed(pixelBuffer: pb, tsMs: tsMs, coreGeneration: token.core)

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pb) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let need = w * h * 3 / 2
        if nv12.count != need { nv12 = [UInt8](repeating: 0, count: need) }

        nv12.withUnsafeMutableBytes { dst in
            guard let d = dst.baseAddress else { return }
            var src = yBase
            var off = 0
            for _ in 0..<h {
                memcpy(d + off, src, w)
                src += yStride
                off += w
            }
            src = uvBase
            for _ in 0..<(h / 2) {
                memcpy(d + off, src, w)
                src += uvStride
                off += w
            }
        }
        nv12.withUnsafeBufferPointer { p in
            guard isAcceptingFrames(), let base = p.baseAddress else { return }
            core.onCameraFrame(base, format: 1, width: Int32(w), height: Int32(h),
                               stride: Int32(w), tsMs: tsMs, coreGeneration: token.core)
        }
    }

    private func reportRuntime(active: Bool, state: String, generation: UInt64? = nil) {
        runtimeLock.lock()
        guard generation == nil || generation == sessionGeneration else {
            runtimeLock.unlock()
            return
        }
        if active && !acceptingFrames {
            runtimeLock.unlock()
            return
        }
        guard reportedActive != active || reportedState != state else {
            runtimeLock.unlock()
            return
        }
        reportedActive = active
        reportedState = state
        let expectedGeneration = sessionGeneration
        let coreGeneration = captureCoreGeneration
        runtimeLock.unlock()
        IOSAvailability.logDebug("camera state=\(state) active=\(active)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.runtimeLock.lock()
            let current = self.sessionGeneration == expectedGeneration
            self.runtimeLock.unlock()
            guard current, coreGeneration != nil,
                  self.core.runningGeneration == coreGeneration else { return }
            self.runtimeStatus(active, state)
        }
    }

    private func beginSession(coreGeneration: UInt64) -> UInt64 {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        sessionGeneration &+= 1
        captureCoreGeneration = coreGeneration
        reportedActive = false
        reportedState = "not_started"
        return sessionGeneration
    }

    private func isAcceptingFrames() -> Bool {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        return acceptingFrames
    }

    private func frameGeneration(output: AVCaptureOutput) -> (core: UInt64, session: UInt64)? {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        guard acceptingFrames, currentOutput === output, let core = captureCoreGeneration else {
            return nil
        }
        return (core, sessionGeneration)
    }

    private func runtimeErrorHandler(generation: UInt64) -> () -> Void {
        return { [weak self] in
            self?.reportRuntime(active: false, state: "runtime_failed", generation: generation)
        }
    }

    /// Seconds since the capture last made progress (a start or a frame); nil when no session
    /// is meant to be running.
    func secondsWithoutFrames(now: CFTimeInterval = CACurrentMediaTime()) -> CFTimeInterval? {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        guard acceptingFrames, session != nil else { return nil }
        return now - max(lastStartAt, lastFrameAt)
    }

    private func installInterruptionObservers(session: AVCaptureSession, generation: UInt64) {
        let center = NotificationCenter.default
        interruptionObservers.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil
        ) { [weak self] note in
            var reason = "interrupted"
            if let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
               let r = AVCaptureSession.InterruptionReason(rawValue: raw) {
                switch r {
                case .videoDeviceNotAvailableInBackground: reason = "interrupted_background"
                case .videoDeviceInUseByAnotherClient: reason = "interrupted_device_in_use"
                case .videoDeviceNotAvailableWithMultipleForegroundApps:
                    reason = "interrupted_multitasking"
                case .audioDeviceInUseByAnotherClient: reason = "interrupted_audio_in_use"
                case .videoDeviceNotAvailableDueToSystemPressure: reason = "interrupted_pressure"
                @unknown default: reason = "interrupted"
                }
            }
            self?.reportRuntime(active: false, state: reason, generation: generation)
        })
        interruptionObservers.append(center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.runtimeLock.lock()
            self.lastStartAt = CACurrentMediaTime()
            self.runtimeLock.unlock()
            self.reportRuntime(active: false, state: "starting", generation: generation)
        })
    }

    private func installRuntimeErrorObserver(session: AVCaptureSession, generation: UInt64) {
        let handler = runtimeErrorHandler(generation: generation)
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
        ) { _ in handler() }
    }

    #if DEBUG
    // Use real AVCaptureSession notifications without requiring camera hardware or permission.
    func beginSessionForTesting(_ session: AVCaptureSession) -> () -> Void {
        stop()
        guard let coreGeneration = core.runningGeneration else { return {} }
        let generation = beginSession(coreGeneration: coreGeneration)
        self.session = session
        installRuntimeErrorObserver(session: session, generation: generation)
        return runtimeErrorHandler(generation: generation)
    }
    #endif
}
