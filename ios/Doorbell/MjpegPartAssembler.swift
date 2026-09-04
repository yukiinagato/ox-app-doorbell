import Foundation

/// Reassembles JPEG frames from a `multipart/x-mixed-replace` stream.
///
/// CFNetwork (URLSession and NSURLConnection alike) parses that content type itself: the delegate
/// gets one `didReceive response` per part carrying the part headers, and `didReceive data` then
/// delivers only the part *body*. The old client searched the body bytes for the part headers,
/// which are never there, so it never produced a frame (see the mini 3's video-startup.log:
/// headers and bytes arrived, `first_complete_multipart` never did).
///
/// Two inputs therefore feed this assembler: `beginPart` from each per-part response, and
/// `append` with the body bytes. A stream whose part headers are still in-band (a proxy that
/// rewrote the content type, a plain TCP fetch in tests) is detected from the first bytes and
/// parsed the old way. Foundation only, so it is host-testable.
final class MjpegPartAssembler {

    struct Frame: Equatable {
        let jpeg: Data
        let rotation: Int
    }

    enum Layout {
        case undecided
        case headersInBand
        case bodiesOnly
    }

    static let maxFrame = 4 * 1024 * 1024
    static let maxBuffer = 8 * 1024 * 1024

    private var buf = Data()
    private var layout = Layout.undecided
    /// Body bytes still expected for the current part; -1 when unknown (marker-delimited).
    private var expecting = -1
    /// True while an in-band part without Content-Length is being read up to its EOI; the body
    /// bytes must not be searched for another header until then.
    private var inMarkerBody = false
    private var partRotation = 0
    private var lastRotation = 0

    private(set) var partsBegun = 0
    private(set) var framesEmitted = 0
    private(set) var discardedBytes = 0

    func reset() {
        buf.removeAll(keepingCapacity: true)
        layout = .undecided
        expecting = -1
        inMarkerBody = false
        partRotation = 0
        lastRotation = 0
        partsBegun = 0
        framesEmitted = 0
        discardedBytes = 0
    }

    /// Called for every per-part response CFNetwork delivers. `contentLength` is the part's
    /// Content-Length (or a value <= 0 when absent); `rotation` the X-Doorbell-Video-Rotation
    /// header when present. Returns the frame of the previous part if that part was
    /// marker-delimited and complete but not yet emitted.
    @discardableResult
    func beginPart(contentLength: Int, rotation: Int?) -> Frame? {
        partsBegun += 1
        layout = .bodiesOnly
        var flushed: Frame?
        if expecting < 0, let frame = takeMarkerDelimitedFrame() {
            flushed = frame
        }
        if !buf.isEmpty {
            discardedBytes += buf.count
            buf.removeAll(keepingCapacity: true)
        }
        expecting = (contentLength > 0 && contentLength <= MjpegPartAssembler.maxFrame)
            ? contentLength : -1
        inMarkerBody = false
        if let r = rotation { lastRotation = MjpegPartAssembler.normalize(r) }
        partRotation = lastRotation
        return flushed
    }

    /// Appends body bytes and returns every frame completed by them, in order.
    func append(_ data: Data) -> [Frame] {
        guard !data.isEmpty else { return [] }
        buf.append(data)
        if buf.count > MjpegPartAssembler.maxBuffer {
            discardedBytes += buf.count
            buf.removeAll(keepingCapacity: true)
            expecting = -1
            inMarkerBody = false
            return []
        }
        if layout == .undecided {
            guard let decided = MjpegPartAssembler.detectLayout(buf) else { return [] }
            layout = decided
        }
        var frames: [Frame] = []
        while let frame = nextFrame() { frames.append(frame) }
        return frames
    }

    // MARK: - Parsing

    private func nextFrame() -> Frame? {
        switch layout {
        case .undecided:
            return nil
        case .bodiesOnly:
            if expecting > 0 { return takeCountedFrame() }
            return takeMarkerDelimitedFrame()
        case .headersInBand:
            if expecting < 0 && !inMarkerBody {
                guard consumeInBandHeader() else { return nil }
            }
            if expecting > 0 { return takeCountedFrame() }
            return takeMarkerDelimitedFrame()
        }
    }

    /// Parses one in-band part header (`--boundary\r\nContent-Length: …\r\n\r\n`). Returns false
    /// when the header is not complete yet. Parts without a Content-Length are marker-delimited.
    private func consumeInBandHeader() -> Bool {
        guard let end = findHeaderEnd() else {
            if buf.count > 16 * 1024 {
                // Never a header in 16 KB: this is not a multipart body after all.
                discardedBytes += buf.count
                buf.removeAll(keepingCapacity: true)
            }
            return false
        }
        let header = String(data: buf.prefix(end.headerLen), encoding: .ascii) ?? ""
        buf.removeFirst(end.consumed)
        var len = -1
        var rotation: Int?
        // Swift treats "\r\n" as one Character, so split on the newline character set, not "\n".
        for line in header.components(separatedBy: CharacterSet.newlines) {
            let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let p = l.split(separator: ":", maxSplits: 1)
            guard p.count == 2 else { continue }
            let name = p[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = p[1].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                len = Int(value) ?? -1
            } else if name == "x-doorbell-video-rotation" {
                rotation = Int(value)
            }
        }
        if let r = rotation { lastRotation = MjpegPartAssembler.normalize(r) }
        partRotation = lastRotation
        expecting = (len > 0 && len <= MjpegPartAssembler.maxFrame) ? len : -1
        // Without a Content-Length the body runs up to its EOI marker; header parsing resumes only
        // after that frame is out, since JPEG bytes can contain CRLFCRLF.
        inMarkerBody = expecting < 0
        return true
    }

    private func takeCountedFrame() -> Frame? {
        guard expecting > 0, buf.count >= expecting else { return nil }
        let jpeg = Data(buf.prefix(expecting))
        buf.removeFirst(expecting)
        expecting = -1
        framesEmitted += 1
        return Frame(jpeg: jpeg, rotation: partRotation)
    }

    /// Extracts one SOI…EOI JPEG when no Content-Length is known. Bytes before the SOI are
    /// dropped (a boundary tail, or junk from an interrupted part).
    private func takeMarkerDelimitedFrame() -> Frame? {
        let soi = Data([0xFF, 0xD8])
        let eoi = Data([0xFF, 0xD9])
        guard let start = buf.range(of: soi) else {
            if buf.count > 16 * 1024 {
                discardedBytes += buf.count
                buf.removeAll(keepingCapacity: true)
                inMarkerBody = false
            }
            return nil
        }
        if start.lowerBound > buf.startIndex {
            discardedBytes += start.lowerBound - buf.startIndex
            buf.removeSubrange(buf.startIndex..<start.lowerBound)
        }
        let searchFrom = buf.index(buf.startIndex, offsetBy: 2)
        guard searchFrom < buf.endIndex,
              let end = buf.range(of: eoi, in: searchFrom..<buf.endIndex) else {
            if buf.count > MjpegPartAssembler.maxFrame {
                discardedBytes += buf.count
                buf.removeAll(keepingCapacity: true)
                inMarkerBody = false
            }
            return nil
        }
        let jpeg = Data(buf[buf.startIndex..<end.upperBound])
        buf.removeSubrange(buf.startIndex..<end.upperBound)
        inMarkerBody = false
        framesEmitted += 1
        return Frame(jpeg: jpeg, rotation: partRotation)
    }

    private func findHeaderEnd() -> (headerLen: Int, consumed: Int)? {
        let crlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        if let r = buf.range(of: crlf) {
            return (r.lowerBound - buf.startIndex, r.upperBound - buf.startIndex)
        }
        let lflf = Data([0x0A, 0x0A])
        if let r = buf.range(of: lflf) {
            return (r.lowerBound - buf.startIndex, r.upperBound - buf.startIndex)
        }
        return nil
    }

    /// Decides from the first bytes whether the part headers are in the body. A JPEG SOI means
    /// CFNetwork already stripped them; a boundary line or header text means they are in-band.
    /// Leading CR/LF (a boundary tail) is skipped. Returns nil while undecidable.
    static func detectLayout(_ data: Data) -> Layout? {
        var index = data.startIndex
        while index < data.endIndex, data[index] == 0x0D || data[index] == 0x0A {
            index = data.index(after: index)
        }
        guard data.endIndex - index >= 2 else { return nil }
        let a = data[index], b = data[index + 1]
        if a == 0xFF && b == 0xD8 { return .bodiesOnly }
        if a == 0x2D && b == 0x2D { return .headersInBand }   // "--"
        // Printable ASCII means header text ("Content-Type: …"); anything else is a body.
        if a >= 0x20 && a < 0x7F && b >= 0x20 && b < 0x7F { return .headersInBand }
        return .bodiesOnly
    }

    private static func normalize(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }
}

// Host tests inspect the layout decision; production code never needs to.
extension MjpegPartAssembler {
    static func layoutName(for data: Data) -> String {
        guard let layout = detectLayout(data) else { return "undecided" }
        switch layout {
        case .undecided: return "undecided"
        case .headersInBand: return "headers_in_band"
        case .bodiesOnly: return "bodies_only"
        }
    }
}
