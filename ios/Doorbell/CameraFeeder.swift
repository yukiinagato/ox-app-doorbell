// AVCaptureSession 前面カメラ → NV12 (420YpCbCr8BiPlanarVideoRange) フレームを core へ push
// (Android CameraFeeder と同役)。CVPixelBuffer の 2 面 (Y / 交錯 UV) を core が期待する
// 連続レイアウト (stride=width) の使い回しバッファへ詰め替えて
// db_core_on_camera_frame(format=1) に渡す。
// H.264 硬編 (Phase 6a) への分岐は encoder に CVPixelBuffer をそのまま渡す
// (VideoToolbox は biplanar を直接食える — 変換不要)。
import AVFoundation
import Foundation

final class CameraFeeder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let core: CoreBridge
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "doorbell-camera")
    private var nv12: [UInt8] = []  // 詰め替え用の使い回しバッファ

    /// H.264 硬編への分岐先 (Phase 6a)。稼働中のみ feed される (nil = 分岐なし)。
    /// MainViewController が wanted ポーリングで start/stop を切り替える。
    var encoder: VideoEncoderVT?

    init(core: CoreBridge) {
        self.core = core
        super.init()
    }

    /// プレビュー層 (待機画面の自機映り込み確認用 — 無くても採集は動く)。
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    /// 前面カメラ (無ければ背面) を開いて採集開始。失敗時 false。
    /// targetW/H: 解像度目標 (codec=h264/auto では h264_resolution を渡す —
    /// MJPEG 側は core の frame_bus が max_width へ縮小するので大きくても無害)。
    @discardableResult
    func start(targetW: Int, targetH: Int) -> Bool {
        stop()
        guard case .authorized = AVCaptureDevice.authorizationStatus(for: .video) else {
            return false
        }
        let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        guard let device = dev, let input = try? AVCaptureDeviceInput(device: device) else {
            return false
        }
        let s = AVCaptureSession()
        s.beginConfiguration()
        // 目標解像度に一番近い preset (旧端末の帯域・CPU を考慮して控えめに選ぶ)
        let pixels = targetW * targetH
        if pixels >= 1280 * 720, s.canSetSessionPreset(.hd1280x720) {
            s.sessionPreset = .hd1280x720
        } else if s.canSetSessionPreset(.vga640x480) {
            s.sessionPreset = .vga640x480
        }
        guard s.canAddInput(input) else { return false }
        s.addInput(input)

        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // NV12
        ]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(out) else { return false }
        s.addOutput(out)
        s.commitConfiguration()

        previewLayer = AVCaptureVideoPreviewLayer(session: s)
        session = s
        queue.async { s.startRunning() }
        return true
    }

    func stop() {
        let s = session
        session = nil
        previewLayer = nil
        queue.async { s?.stopRunning() }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (camera queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let tsMs = Int64(Date().timeIntervalSince1970 * 1000)

        // H.264 硬編への分岐 (稼働中のみ — encoder 側で fps 間引き)
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
            // Y 面 (stride 詰め)
            var src = yBase
            var off = 0
            for _ in 0..<h {
                memcpy(d + off, src, w)
                src += yStride
                off += w
            }
            // 交錯 UV 面 (NV12 のまま)
            src = uvBase
            for _ in 0..<(h / 2) {
                memcpy(d + off, src, w)
                src += uvStride
                off += w
            }
        }
        nv12.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            core.onCameraFrame(base, format: 1, width: Int32(w), height: Int32(h),
                               stride: Int32(w), tsMs: tsMs)
        }
    }
}
