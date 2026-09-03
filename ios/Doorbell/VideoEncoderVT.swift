import Foundation
import VideoToolbox

// A recursive lock serializes encoder lifecycle with capture delivery and a synchronous VT
// callback. VideoToolbox AVCC output is converted to Annex-B, with SPS/PPS prepended to keyframes.
final class VideoEncoderVT {

    private let core: CoreBridge
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var fps = 25
    private var bitrateKbps = 1500
    private var lastFeedMs: Int64 = 0
    private var failed = false
    private var started = false
    private var forceNextKeyframe = false
    private var sessionGeneration: UInt64 = 0
    private let lock = NSRecursiveLock()
    private let measurementLock = NSLock()
    private var lastMeasurement = ""

    var runtimeStatus: ((Bool, String) -> Void)?

    private static let gopSeconds = 2.0

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    var hasTerminalFailure: Bool {
        lock.lock(); defer { lock.unlock() }
        return failed
    }

    init(core: CoreBridge) {
        self.core = core
    }

    func start(fps: Int, bitrateKbps: Int) {
        lock.lock()
        self.fps = fps > 0 ? fps : 25
        self.bitrateKbps = bitrateKbps > 0 ? bitrateKbps : 1500
        releaseSessionLocked()
        width = 0
        height = 0
        lastFeedMs = 0
        failed = false
        forceNextKeyframe = false
        started = true
        sessionGeneration &+= 1
        lock.unlock()
        IOSAvailability.logDebug("h264 start fps=\(self.fps) bitrate_kbps=\(self.bitrateKbps)")
        reportRuntime(available: false, state: "testing")
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        started = false
        sessionGeneration &+= 1
        releaseSessionLocked()
        IOSAvailability.logDebug("h264 stop")
    }

    func requestKeyFrame() {
        lock.lock()
        if started && !failed { forceNextKeyframe = true }
        lock.unlock()
    }

    private func releaseSessionLocked() {
        if let s = session {
            VTCompressionSessionInvalidate(s)
            session = nil
        }
    }

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
                failed = true
                reportRuntime(available: false, state: "session_failed")
                return
            }
            session = s
            width = w
            height = h
        }
        guard let s = session else { return }
        let generation = sessionGeneration
        let pts = CMTime(value: tsMs, timescale: 1000)
        let forceKeyframe = forceNextKeyframe
        forceNextKeyframe = false
        let frameProperties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let rc = VTCompressionSessionEncodeFrame(
            s, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: frameProperties, infoFlagsOut: nil
        ) { [weak self] status, _, sbuf in
            guard let self = self else { return }
            guard self.isCurrentGeneration(generation) else { return }
            guard status == noErr, let sbuf = sbuf else {
                self.markTerminalFailure("encode_failed")
                return
            }
            if self.emit(sampleBuffer: sbuf) {
                self.reportRuntime(available: true, state: "verified")
            } else {
                self.markTerminalFailure("invalid_output")
            }
        }
        if rc != noErr {
            if forceKeyframe { forceNextKeyframe = true }
            failed = true
            IOSAvailability.logDebug("h264 encode frame failed status=\(rc)")
            reportRuntime(available: false, state: "encode_failed")
        }
    }

    private func isCurrentGeneration(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return started && sessionGeneration == value
    }

    private func createSessionLocked(w: Int32, h: Int32) -> VTCompressionSession? {
        var s: VTCompressionSession?
        let rc = VTCompressionSessionCreate(
            allocator: nil, width: w, height: h, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard rc == noErr, let sess = s else {
            IOSAvailability.logDebug("h264 session create failed status=\(rc) size=\(w)x\(h)")
            return nil
        }
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrateKbps * 1000))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: fps))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: VideoEncoderVT.gopSeconds))
        let prepare = VTCompressionSessionPrepareToEncodeFrames(sess)
        guard prepare == noErr else {
            IOSAvailability.logDebug("h264 session prepare failed status=\(prepare)")
            VTCompressionSessionInvalidate(sess)
            return nil
        }
        IOSAvailability.logDebug("h264 session ready size=\(w)x\(h)")
        return sess
    }

    private func markTerminalFailure(_ state: String) {
        lock.lock()
        failed = true
        lock.unlock()
        IOSAvailability.logDebug("h264 terminal failure state=\(state)")
        reportRuntime(available: false, state: state)
    }

    private func reportRuntime(available: Bool, state: String) {
        measurementLock.lock()
        guard lastMeasurement != state else {
            measurementLock.unlock()
            return
        }
        lastMeasurement = state
        let handler = runtimeStatus
        measurementLock.unlock()
        IOSAvailability.logDebug("h264 state=\(state) available=\(available)")
        DispatchQueue.main.async { handler?(available, state) }
    }

    private func emit(sampleBuffer: CMSampleBuffer) -> Bool {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            IOSAvailability.logDebug("h264 output missing data buffer")
            return false
        }

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
        var parameterSetCount = 0

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
                parameterSetCount += 1
                idx += 1
                if idx >= count { break }
            }
        }

        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLen,
                                          dataPointerOut: &dataPtr) == noErr,
              let base = dataPtr else {
            IOSAvailability.logDebug("h264 output block buffer inaccessible")
            return false
        }
        var off = 0
        var nalCount = 0
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
            nalCount += 1
        }
        guard nalCount > 0, off == totalLen, !annexb.isEmpty,
              !isKey || parameterSetCount >= 2 else {
            IOSAvailability.logDebug("h264 output invalid key=\(isKey) nals=\(nalCount) parameter_sets=\(parameterSetCount) bytes=\(totalLen)")
            return false
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let tsMs = pts.isValid ? Int64(CMTimeGetSeconds(pts) * 1000)
                               : Int64(Date().timeIntervalSince1970 * 1000)
        core.onEncodedFrame(annexb, isKeyframe: isKey, tsMs: tsMs)
        return true
    }
}
