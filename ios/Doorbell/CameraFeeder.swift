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

    var encoder: VideoEncoderVT?

    init(core: CoreBridge, runtimeStatus: @escaping (Bool, String) -> Void = { _, _ in }) {
        self.core = core
        self.runtimeStatus = runtimeStatus
        super.init()
    }

    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    @discardableResult
    func start(targetW: Int, targetH: Int) -> Bool {
        stop()
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
        s.commitConfiguration()

        previewLayer = AVCaptureVideoPreviewLayer(session: s)
        session = s
        setAcceptingFrames(true)
        reportRuntime(active: false, state: "starting")
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: s, queue: nil
        ) { [weak self] _ in
            self?.reportRuntime(active: false, state: "runtime_failed")
        }
        queue.async { s.startRunning() }
        return true
    }

    func stop() {
        stop(waitUntilIdle: false)
    }

    /// Stops capture and waits for every queued sample-buffer callback to leave Core.
    /// Call this before destroying Core; the ordinary stop path stays asynchronous so a camera
    /// restart does not block the main thread on AVCaptureSession.
    func stopAndWait() {
        stop(waitUntilIdle: true)
    }

    private func stop(waitUntilIdle: Bool) {
        setAcceptingFrames(false)
        if let observer = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            runtimeErrorObserver = nil
        }
        let s = session
        session = nil
        previewLayer = nil
        if waitUntilIdle {
            queue.sync { s?.stopRunning() }
        } else {
            queue.async { s?.stopRunning() }
        }
        if s != nil { reportRuntime(active: false, state: "stopped") }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isAcceptingFrames() else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        reportRuntime(active: true, state: "active")
        let tsMs = Int64(Date().timeIntervalSince1970 * 1000)

        encoder?.feed(pixelBuffer: pb, tsMs: tsMs)

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
                               stride: Int32(w), tsMs: tsMs)
        }
    }

    private func reportRuntime(active: Bool, state: String) {
        runtimeLock.lock()
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
        runtimeLock.unlock()
        IOSAvailability.logDebug("camera state=\(state) active=\(active)")
        runtimeStatus(active, state)
    }

    private func setAcceptingFrames(_ value: Bool) {
        runtimeLock.lock()
        acceptingFrames = value
        runtimeLock.unlock()
    }

    private func isAcceptingFrames() -> Bool {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        return acceptingFrames
    }
}
