// H.264 ハードウェアエンコード (VideoToolbox) — Phase 6a の流暢档 (Android VideoEncoder と同役)。
// CameraFeeder の CVPixelBuffer (NV12) をそのまま食わせ、AVCC 出力を AnnexB へ変換して
// core (db_core_on_encoded_frame → fMP4 → /stream.mp4) へ流す。SPS/PPS はキーフレームに前置。
// 稼働制御は MainViewController の 5 秒毎ポーリング (db_core_video_encoder_wanted —
// /stream.mp4 の購読者がいる間だけ回す。購読者ゼロ = エンコードゼロで省電力)。
import Foundation
import VideoToolbox

final class VideoEncoderVT {

    private let core: CoreBridge
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var fps = 25
    private var bitrateKbps = 1500
    private var lastFeedMs: Int64 = 0
    private var failed = false     // セッション生成失敗 (次の start まで再試行しない)
    private var started = false    // start()..stop() の間 true (稼働指示)
    private let lock = NSLock()

    private static let gopSeconds = 2.0  // キーフレーム間隔 — MSE 参加者の初描画待ちに直結

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    init(core: CoreBridge) {
        self.core = core
    }

    /// config camera.h264_* を適用して開始 (セッション生成は最初のフレームまで遅延)。
    func start(fps: Int, bitrateKbps: Int) {
        lock.lock(); defer { lock.unlock() }
        self.fps = fps > 0 ? fps : 25
        self.bitrateKbps = bitrateKbps > 0 ? bitrateKbps : 1500
        releaseSessionLocked()
        width = 0
        height = 0
        failed = false
        started = true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        started = false
        releaseSessionLocked()
    }

    private func releaseSessionLocked() {
        if let s = session {
            VTCompressionSessionInvalidate(s)
            session = nil
        }
    }

    /// カメラスレッドから CVPixelBuffer を投入。fps 間引き → VTCompressionSession →
    /// 出力コールバックで AnnexB 化して core へ。
    func feed(pixelBuffer: CVPixelBuffer, tsMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard started, !failed else { return }
        if lastFeedMs != 0 && tsMs - lastFeedMs < Int64(1000 / fps) { return }
        lastFeedMs = tsMs

        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if session == nil || w != width || h != height {
            releaseSessionLocked()
            guard let s = createSessionLocked(w: w, h: h) else {
                failed = true  // 硬編なし — auto の回落先は MJPEG (core 側で 503)
                return
            }
            session = s
            width = w
            height = h
        }
        guard let s = session else { return }
        let pts = CMTime(value: tsMs, timescale: 1000)
        VTCompressionSessionEncodeFrame(s, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: nil,
                                        infoFlagsOut: nil) { [weak self] status, _, sbuf in
            guard status == noErr, let sbuf = sbuf else { return }
            self?.emit(sampleBuffer: sbuf)
        }
    }

    private func createSessionLocked(w: Int32, h: Int32) -> VTCompressionSession? {
        var s: VTCompressionSession?
        let rc = VTCompressionSessionCreate(
            allocator: nil, width: w, height: h, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard rc == noErr, let sess = s else { return nil }
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)  // B フレームなし (fMP4 ライブ配信)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrateKbps * 1000))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: fps))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: VideoEncoderVT.gopSeconds))
        VTCompressionSessionPrepareToEncodeFrames(sess)
        return sess
    }

    // MARK: - AVCC → AnnexB (VT コールバックスレッド)

    private func emit(sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // キーフレーム判定 (kCMSampleAttachmentKey_NotSync が無い = sync sample)
        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                             createIfNecessary: false),
           CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFDictionary.self)
            let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            isKey = !CFDictionaryContainsKey(dict, key)
        }

        var annexb = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]

        // SPS/PPS (format description のパラメータセット) をキーフレームへ前置
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var idx = 0
            while true {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                let rc = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: idx, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: nil)
                guard rc == noErr, let p = ptr else { break }
                annexb.append(contentsOf: startCode)
                annexb.append(p, count: size)
                idx += 1
                if idx >= count { break }
            }
        }

        // AVCC (4 バイト長前置) の NAL 群を start code 区切りへ
        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLen,
                                          dataPointerOut: &dataPtr) == noErr,
              let base = dataPtr else { return }
        var off = 0
        while off + 4 <= totalLen {
            var beLen: UInt32 = 0
            memcpy(&beLen, base + off, 4)
            let nalLen = Int(UInt32(bigEndian: beLen))
            off += 4
            guard nalLen > 0, off + nalLen <= totalLen else { break }
            annexb.append(contentsOf: startCode)
            base.withMemoryRebound(to: UInt8.self, capacity: totalLen) { u8 in
                annexb.append(u8 + off, count: nalLen)
            }
            off += nalLen
        }
        guard !annexb.isEmpty else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let tsMs = pts.isValid ? Int64(CMTimeGetSeconds(pts) * 1000)
                               : Int64(Date().timeIntervalSince1970 * 1000)
        core.onEncodedFrame(annexb, isKeyframe: isKey, tsMs: tsMs)
    }
}
