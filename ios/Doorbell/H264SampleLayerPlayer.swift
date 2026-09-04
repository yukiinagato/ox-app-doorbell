import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

/// Live fMP4/H.264 playback without AVPlayer. AVPlayer treats `/stream.mp4` as a progressive
/// download and never gets past its opening probe of an endless, unseekable file; this streams the
/// bytes through `Fmp4Demuxer` and enqueues each access unit on an `AVSampleBufferDisplayLayer`
/// with `kCMSampleAttachmentKey_DisplayImmediately`, so the first keyframe is on screen as soon
/// as VideoToolbox has decoded it. Works on iOS 9+ and tvOS.
final class H264SampleLayerPlayer: NSObject, URLSessionDataDelegate {

    struct Stats {
        var frames = 0            // access units enqueued
        var dropped = 0           // units skipped (waiting for a keyframe, or layer not ready)
        var latencyMs = -1        // capture → enqueue, via the response's server-time header
        var width = 0
        var height = 0
        var firstFrameMs = -1
    }

    let layer = AVSampleBufferDisplayLayer()
    /// Called on the main thread once, after the first access unit was enqueued successfully.
    var onFirstFrame: (() -> Void)?
    /// Called on the main thread with a reason; the player has stopped itself.
    var onFailure: ((String) -> Void)?
    /// Picture size from the stream's SPS, on the main thread, whenever it changes.
    var onVideoSize: ((CGSize) -> Void)?

    private let url: URL
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let demuxer = Fmp4Demuxer()
    private var formatDescription: CMVideoFormatDescription?
    private var running = false
    private var waitingForKey = true
    private var startedAt: CFTimeInterval = 0
    private var serverOffsetMs: Int64 = 0
    private var firstFrameAnnounced = false
    private var stats = Stats()
    private let statsLock = NSLock()
    private var frameTimestamps: [CFTimeInterval] = []

    init(url: URL) {
        self.url = url
        super.init()
        layer.videoGravity = .resizeAspect
        demuxer.onConfig = { [weak self] config in self?.configure(config) }
        demuxer.onSample = { [weak self] unit in self?.enqueue(unit) }
    }

    deinit { stop() }

    func start() {
        guard !running else { return }
        running = true
        waitingForKey = true
        firstFrameAnnounced = false
        startedAt = CACurrentMediaTime()
        statsLock.lock()
        stats = Stats()
        frameTimestamps.removeAll()
        statsLock.unlock()
        demuxer.reset()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 86_400
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        let t = s.dataTask(with: url)
        task = t
        t.resume()
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        formatDescription = nil
        if Thread.isMainThread {
            layer.flushAndRemoveImage()
        } else {
            let layer = self.layer
            DispatchQueue.main.async { layer.flushAndRemoveImage() }
        }
    }

    func snapshot() -> Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return stats
    }

    /// Frame arrival times over the last two seconds, for the debug line's fps/jitter.
    func recentIntervals() -> [Double] {
        statsLock.lock()
        defer { statsLock.unlock() }
        guard frameTimestamps.count >= 2 else { return [] }
        return zip(frameTimestamps.dropFirst(), frameTimestamps).map { $0 - $1 }
    }

    // MARK: - URLSession

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard running else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
        if http.statusCode < 200 || http.statusCode >= 300 {
            completionHandler(.cancel)
            fail("http_status_\(http.statusCode)")
            return
        }
        for (key, value) in http.allHeaderFields {
            guard let k = key as? String, k.lowercased() == "x-doorbell-server-time-ms",
                  let s = value as? String, let serverMs = Int64(s.trimmingCharacters(in: .whitespaces))
            else { continue }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let offset = serverMs - nowMs
            serverOffsetMs = abs(offset) > 86_400_000 ? 0 : offset
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard running else { return }
        do {
            try demuxer.feed(data)
        } catch {
            fail("parse_error: \(error)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard running else { return }
        if let error = error as NSError? {
            fail("transport_error \(error.domain) \(error.code)")
        } else {
            fail("stream_ended")
        }
    }

    // MARK: - Decoding

    private func configure(_ config: Fmp4Demuxer.Config) {
        var description: CMVideoFormatDescription?
        let status: OSStatus = config.sps.withUnsafeBytes { spsRaw -> OSStatus in
            config.pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [config.sps.count, config.pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(config.nalLengthSize),
                    formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let created = description else {
            fail("format_description \(status)")
            return
        }
        formatDescription = created
        waitingForKey = true
        statsLock.lock()
        stats.width = config.width
        stats.height = config.height
        statsLock.unlock()
        let size = CGSize(width: config.width, height: config.height)
        let layer = self.layer
        DispatchQueue.main.async { [weak self] in
            layer.flush()
            if size.width > 0, size.height > 0 { self?.onVideoSize?(size) }
        }
    }

    private func enqueue(_ unit: Fmp4Demuxer.AccessUnit) {
        guard running, let description = formatDescription else { return }
        if waitingForKey {
            if !unit.key {
                note(dropped: true)
                return
            }
            waitingForKey = false
        }
        var block: CMBlockBuffer?
        let length = unit.avcc.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: 0, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let blockBuffer = block else {
            note(dropped: true)
            return
        }
        status = unit.avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0, dataLength: length)
        }
        guard status == kCMBlockBufferNoErr else {
            note(dropped: true)
            return
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(max(1, unit.durationMs)), timescale: 1000),
            presentationTimeStamp: CMTime(value: CMTimeValue(unit.dts), timescale: 1000),
            decodeTimeStamp: .invalid)
        var sampleSize = length
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: description, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        guard status == noErr, let buffer = sample else {
            note(dropped: true)
            return
        }
        // Render as soon as decoded: the layer then needs no timebase, and a late unit is shown
        // late rather than queued, which is what a live door camera wants.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let layer = self.layer
        let captureMs = unit.captureMs
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.running else { return }
            if layer.status == .failed {
                let reason = layer.error?.localizedDescription ?? "display layer failed"
                self.fail("display_layer_failed \(reason)")
                return
            }
            guard layer.isReadyForMoreMediaData else {
                self.note(dropped: true)
                return
            }
            layer.enqueue(buffer)
            self.note(dropped: false, captureMs: captureMs)
            if !self.firstFrameAnnounced {
                self.firstFrameAnnounced = true
                let elapsed = Int((CACurrentMediaTime() - self.startedAt) * 1000)
                self.statsLock.lock()
                self.stats.firstFrameMs = elapsed
                self.statsLock.unlock()
                NSLog("[doorbell][h264] first frame enqueued after %d ms", elapsed)
                self.onFirstFrame?()
            }
        }
    }

    private func note(dropped: Bool, captureMs: Int64 = 0) {
        statsLock.lock()
        if dropped {
            stats.dropped += 1
        } else {
            stats.frames += 1
            let now = CACurrentMediaTime()
            frameTimestamps.append(now)
            while let first = frameTimestamps.first, now - first > 2 { frameTimestamps.removeFirst() }
            if captureMs > 0 {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let latency = nowMs + serverOffsetMs - captureMs
                stats.latencyMs = Int(max(0, min(60_000, latency)))
            }
        }
        statsLock.unlock()
    }

    private func fail(_ reason: String) {
        guard running else { return }
        running = false
        task?.cancel()
        NSLog("[doorbell][h264] %@", reason)
        DispatchQueue.main.async { [weak self] in self?.onFailure?(reason) }
    }
}
