import Foundation

/// Streaming demuxer for the repository's live fMP4 (`/stream.mp4`): the init segment from
/// core's `fmp4::buildInit`, then per-frame `dbts` + `moof` + `mdat` triples, with `free`
/// keepalive boxes in between. AVPlayer cannot open that endless, unseekable download in any
/// useful time, so the Swift shell feeds the bytes here and hands the access units to an
/// `AVSampleBufferDisplayLayer` (see `H264SampleLayerPlayer`). Mirrors `core/src/media/fmp4_demux`;
/// Foundation only, so it is host-testable.
final class Fmp4Demuxer {

    struct Config: Equatable {
        let sps: Data          // raw NAL, no start code / length prefix
        let pps: Data
        let nalLengthSize: Int // from avcC; the samples keep this length-prefixed layout
        let width: Int
        let height: Int
    }

    struct AccessUnit {
        let avcc: Data         // length-prefixed NAL units exactly as they sit in mdat
        let key: Bool
        let dts: UInt64        // 1000-unit timescale
        let durationMs: UInt32
        let captureMs: Int64   // from the dbts box; 0 when absent
    }

    enum Failure: Error, Equatable {
        case openEndedBox
        case boxSmallerThanHeader
        case boxTooLarge(String)
        case moovWithoutAvcC
        case invalidAvcC
        case moofBeforeInit
        case corruptMoof(String)
        case mdatWithoutMoof
        case sampleExceedsMdat
    }

    static let maxInitBox = 1 << 20
    static let maxFragmentBox = 64 << 10
    static let maxMdatBox = 8 << 20
    static let maxOtherBox = 64 << 10

    var onConfig: ((Config) -> Void)?
    var onSample: ((AccessUnit) -> Void)?

    private(set) var config: Config?
    private(set) var failure: Failure?
    private(set) var samples = 0
    var buffered: Int { buf.count }

    private var buf = Data()
    private var pending: [(dur: UInt32, size: UInt32, flags: UInt32)] = []
    private var captureTimes: [Int64] = []
    private var nextDts: UInt64 = 0

    func reset() {
        buf.removeAll(keepingCapacity: true)
        config = nil
        failure = nil
        samples = 0
        pending.removeAll()
        captureTimes.removeAll()
        nextDts = 0
    }

    /// Appends stream bytes and parses every complete top-level box. Throws on a corrupt stream;
    /// afterwards the demuxer stays failed until `reset()`.
    func feed(_ data: Data) throws {
        if let failure = failure { throw failure }
        buf.append(data)
        var consumed = 0
        do {
            while buf.count - consumed >= 8 {
                let at = buf.startIndex + consumed
                let size = be32(buf, at)
                let type = be32(buf, at + 4)
                var header = 8
                var boxSize = UInt64(size)
                if size == 1 {
                    if buf.count - consumed < 16 { break }
                    boxSize = be64(buf, at + 8)
                    header = 16
                } else if size == 0 {
                    throw Failure.openEndedBox
                }
                if boxSize < UInt64(header) { throw Failure.boxSmallerThanHeader }
                let name = fourcc(type)
                let max: Int
                switch name {
                case "moov": max = Fmp4Demuxer.maxInitBox
                case "moof", "dbts": max = Fmp4Demuxer.maxFragmentBox
                case "mdat": max = Fmp4Demuxer.maxMdatBox
                default: max = Fmp4Demuxer.maxOtherBox
                }
                if boxSize > UInt64(max) { throw Failure.boxTooLarge(name) }
                if UInt64(buf.count - consumed) < boxSize { break }
                let body = buf.subdata(in: (at + header)..<(at + Int(boxSize)))
                try handle(name, body)
                consumed += Int(boxSize)
            }
        } catch let error as Failure {
            failure = error
            buf.removeAll(keepingCapacity: true)
            pending.removeAll()
            throw error
        }
        if consumed > 0 { buf.removeSubrange(buf.startIndex..<(buf.startIndex + consumed)) }
    }

    // MARK: - Boxes

    private func handle(_ type: String, _ body: Data) throws {
        switch type {
        case "moov": try handleMoov(body)
        case "moof": try handleMoof(body)
        case "mdat": try handleMdat(body)
        case "dbts":
            captureTimes.removeAll()
            guard body.count >= 4 else { return }
            let count = Int(be32(body, body.startIndex))
            guard count <= 1024, body.count >= 4 + count * 8 else { return }
            for i in 0..<count {
                captureTimes.append(Int64(bitPattern: be64(body, body.startIndex + 4 + i * 8)))
            }
        default:
            break  // ftyp, styp, free, unknown
        }
    }

    private func handleMoov(_ body: Data) throws {
        guard let avcc = Fmp4Demuxer.findAvcC(body, depth: 0) else { throw Failure.moovWithoutAvcC }
        guard let parsed = Fmp4Demuxer.parseAvcC(avcc) else { throw Failure.invalidAvcC }
        let dims = Fmp4Demuxer.spsDimensions(parsed.sps) ?? (0, 0)
        let cfg = Config(sps: parsed.sps, pps: parsed.pps, nalLengthSize: parsed.nalLengthSize,
                         width: dims.0, height: dims.1)
        config = cfg
        pending.removeAll()
        onConfig?(cfg)
    }

    private func handleMoof(_ body: Data) throws {
        guard config != nil else { throw Failure.moofBeforeInit }
        pending.removeAll()
        var sawTrun = false
        var i = body.startIndex
        let end = body.endIndex
        while i + 8 <= end {
            let size = Int(be32(body, i))
            let type = fourcc(be32(body, i + 4))
            if size < 8 || i + size > end { throw Failure.corruptMoof("moof child") }
            if type == "traf" {
                var j = i + 8
                let trafEnd = i + size
                while j + 8 <= trafEnd {
                    let csize = Int(be32(body, j))
                    let ctype = fourcc(be32(body, j + 4))
                    if csize < 8 || j + csize > trafEnd { throw Failure.corruptMoof("traf child") }
                    let c = j + 8
                    let cn = csize - 8
                    if ctype == "tfdt" {
                        guard cn >= 4 else { throw Failure.corruptMoof("tfdt") }
                        if body[c] == 1 {
                            guard cn >= 12 else { throw Failure.corruptMoof("tfdt v1") }
                            nextDts = be64(body, c + 4)
                        } else {
                            guard cn >= 8 else { throw Failure.corruptMoof("tfdt v0") }
                            nextDts = UInt64(be32(body, c + 4))
                        }
                    } else if ctype == "trun" {
                        guard cn >= 8 else { throw Failure.corruptMoof("trun") }
                        let flags = be32(body, c) & 0x00ffffff
                        let count = Int(be32(body, c + 4))
                        guard count > 0, count <= 4096 else { throw Failure.corruptMoof("trun count") }
                        var k = c + 8
                        if flags & 0x1 != 0 { k += 4 }
                        var firstFlags: UInt32?
                        if flags & 0x4 != 0 {
                            guard k + 4 <= c + cn else { throw Failure.corruptMoof("trun first flags") }
                            firstFlags = be32(body, k)
                            k += 4
                        }
                        for s in 0..<count {
                            var dur: UInt32 = 0, sz: UInt32 = 0, fl: UInt32 = 0
                            if flags & 0x100 != 0 {
                                guard k + 4 <= c + cn else { throw Failure.corruptMoof("trun dur") }
                                dur = be32(body, k); k += 4
                            }
                            if flags & 0x200 != 0 {
                                guard k + 4 <= c + cn else { throw Failure.corruptMoof("trun size") }
                                sz = be32(body, k); k += 4
                            } else {
                                throw Failure.corruptMoof("trun without sizes")
                            }
                            if flags & 0x400 != 0 {
                                guard k + 4 <= c + cn else { throw Failure.corruptMoof("trun flags") }
                                fl = be32(body, k); k += 4
                            } else if s == 0, let first = firstFlags {
                                fl = first
                            }
                            if flags & 0x800 != 0 {
                                guard k + 4 <= c + cn else { throw Failure.corruptMoof("trun cts") }
                                k += 4
                            }
                            pending.append((dur, sz, fl))
                        }
                        sawTrun = true
                    }
                    j += csize
                }
            }
            i += size
        }
        if !sawTrun || pending.isEmpty { throw Failure.corruptMoof("no trun samples") }
    }

    private func handleMdat(_ body: Data) throws {
        guard !pending.isEmpty, let cfg = config else { throw Failure.mdatWithoutMoof }
        var off = body.startIndex
        for (index, sample) in pending.enumerated() {
            let size = Int(sample.size)
            guard size >= cfg.nalLengthSize, off + size <= body.endIndex else {
                throw Failure.sampleExceedsMdat
            }
            let avcc = body.subdata(in: off..<(off + size))
            // sample_is_non_sync_sample (bit 16) clear means a sync sample; an IDR NAL settles it.
            let nonSync = sample.flags & 0x0001_0000 != 0
            var idr = false
            var i = avcc.startIndex
            while i + cfg.nalLengthSize <= avcc.endIndex {
                var len = 0
                for b in 0..<cfg.nalLengthSize { len = (len << 8) | Int(avcc[i + b]) }
                i += cfg.nalLengthSize
                guard len > 0, i + len <= avcc.endIndex else { throw Failure.sampleExceedsMdat }
                if avcc[i] & 0x1f == 5 { idr = true }
                i += len
            }
            let au = AccessUnit(avcc: avcc, key: idr || (!nonSync && sample.flags != 0),
                                dts: nextDts, durationMs: sample.dur,
                                captureMs: index < captureTimes.count ? captureTimes[index] : 0)
            nextDts += UInt64(sample.dur)
            off += size
            samples += 1
            onSample?(au)
        }
        pending.removeAll()
        captureTimes.removeAll()
    }

    // MARK: - Helpers

    static func findAvcC(_ data: Data, depth: Int) -> Data? {
        if depth > 8 { return nil }
        var i = data.startIndex
        while i + 8 <= data.endIndex {
            let size = be32(data, i)
            let type = fourcc(be32(data, i + 4))
            var header = 8
            var boxSize = UInt64(size)
            if size == 1 {
                guard i + 16 <= data.endIndex else { return nil }
                boxSize = be64(data, i + 8)
                header = 16
            } else if size == 0 {
                boxSize = UInt64(data.endIndex - i)
            }
            if boxSize < UInt64(header) || UInt64(data.endIndex - i) < boxSize { return nil }
            let body = data.subdata(in: (i + header)..<(i + Int(boxSize)))
            if type == "avcC" { return body }
            var skip = 0
            var container = ["moov", "trak", "mdia", "minf", "stbl", "stsd"].contains(type)
            if type == "stsd" { skip = 8 }
            if type == "avc1" || type == "avc3" {
                container = true
                skip = 78
            }
            if container, body.count >= skip,
               let found = findAvcC(body.subdata(in: (body.startIndex + skip)..<body.endIndex),
                                    depth: depth + 1) {
                return found
            }
            i += Int(boxSize)
        }
        return nil
    }

    static func parseAvcC(_ p: Data) -> (sps: Data, pps: Data, nalLengthSize: Int)? {
        let n = p.count
        guard n >= 7, p[p.startIndex] == 1 else { return nil }
        let base = p.startIndex
        let lengthSize = Int(p[base + 4] & 0x03) + 1
        var i = 5
        let spsCount = Int(p[base + i] & 0x1f); i += 1
        var sps: Data?
        for _ in 0..<spsCount {
            guard i + 2 <= n else { return nil }
            let len = Int(be16(p, base + i)); i += 2
            guard len > 0, i + len <= n else { return nil }
            if sps == nil { sps = p.subdata(in: (base + i)..<(base + i + len)) }
            i += len
        }
        guard i < n else { return nil }
        let ppsCount = Int(p[base + i]); i += 1
        var pps: Data?
        for _ in 0..<ppsCount {
            guard i + 2 <= n else { return nil }
            let len = Int(be16(p, base + i)); i += 2
            guard len > 0, i + len <= n else { return nil }
            if pps == nil { pps = p.subdata(in: (base + i)..<(base + i + len)) }
            i += len
        }
        guard let s = sps, let q = pps else { return nil }
        return (s, q, lengthSize)
    }

    /// Coded picture size from an SPS (frame_mbs_only, cropping applied). Enough for the
    /// baseline/main streams the door stations produce; returns nil for anything it cannot read.
    static func spsDimensions(_ sps: Data) -> (Int, Int)? {
        guard sps.count > 4, sps[sps.startIndex] & 0x1f == 7 else { return nil }
        var rbsp = [UInt8]()
        var zeros = 0
        for b in sps.dropFirst() {
            if zeros >= 2 && b == 3 { zeros = 0; continue }
            rbsp.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        var reader = BitReader(rbsp)
        let profile = reader.u(8)
        _ = reader.u(8); _ = reader.u(8)
        _ = reader.ue()
        var chromaFormat: UInt32 = 1
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(Int(profile)) {
            chromaFormat = reader.ue()
            if chromaFormat == 3 { _ = reader.u(1) }
            _ = reader.ue(); _ = reader.ue(); _ = reader.u(1)
            if reader.u(1) == 1 {
                for i in 0..<(chromaFormat != 3 ? 8 : 12) {
                    if reader.u(1) == 1 { reader.skipScalingList(i < 6 ? 16 : 64) }
                }
            }
        }
        _ = reader.ue()
        let pocType = reader.ue()
        if pocType == 0 {
            _ = reader.ue()
        } else if pocType == 1 {
            _ = reader.u(1); _ = reader.se(); _ = reader.se()
            let n = reader.ue()
            for _ in 0..<n { _ = reader.se() }
        }
        _ = reader.ue(); _ = reader.u(1)
        let mbsW = Int(reader.ue()) + 1
        let mapH = Int(reader.ue()) + 1
        let frameMbsOnly = reader.u(1)
        if frameMbsOnly == 0 { _ = reader.u(1) }
        _ = reader.u(1)
        var cropL = 0, cropR = 0, cropT = 0, cropB = 0
        if reader.u(1) == 1 {
            cropL = Int(reader.ue()); cropR = Int(reader.ue())
            cropT = Int(reader.ue()); cropB = Int(reader.ue())
        }
        if reader.bad { return nil }
        let subW = (chromaFormat == 1 || chromaFormat == 2) ? 2 : 1
        let subH = chromaFormat == 1 ? 2 : 1
        let unitY = subH * (2 - Int(frameMbsOnly))
        let width = mbsW * 16 - (cropL + cropR) * subW
        let height = (2 - Int(frameMbsOnly)) * mapH * 16 - (cropT + cropB) * unitY
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        return (width, height)
    }

    private struct BitReader {
        let bytes: [UInt8]
        var pos = 0
        var bad = false
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func u(_ n: Int) -> UInt32 {
            var v: UInt32 = 0
            for _ in 0..<n {
                let byte = pos >> 3
                if byte >= bytes.count { bad = true; return 0 }
                v = (v << 1) | UInt32((bytes[byte] >> (7 - UInt8(pos & 7))) & 1)
                pos += 1
            }
            return v
        }
        mutating func ue() -> UInt32 {
            var zeros = 0
            while u(1) == 0 && !bad && zeros < 32 { zeros += 1 }
            if zeros >= 32 { bad = true; return 0 }
            return (1 << UInt32(zeros)) - 1 + u(zeros)
        }
        mutating func se() -> Int32 {
            let k = ue()
            return k & 1 == 1 ? Int32((k + 1) / 2) : -Int32(k / 2)
        }
        mutating func skipScalingList(_ size: Int) {
            var last: Int32 = 8, next: Int32 = 8
            for _ in 0..<size where !bad {
                if next != 0 { next = (last + se() + 256) % 256 }
                last = next == 0 ? last : next
            }
        }
    }
}

private func be16(_ d: Data, _ at: Int) -> UInt16 { UInt16(d[at]) << 8 | UInt16(d[at + 1]) }
private func be32(_ d: Data, _ at: Int) -> UInt32 {
    UInt32(d[at]) << 24 | UInt32(d[at + 1]) << 16 | UInt32(d[at + 2]) << 8 | UInt32(d[at + 3])
}
private func be64(_ d: Data, _ at: Int) -> UInt64 { UInt64(be32(d, at)) << 32 | UInt64(be32(d, at + 4)) }
private func fourcc(_ v: UInt32) -> String {
    String(bytes: [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)],
           encoding: .isoLatin1) ?? "????"
}
