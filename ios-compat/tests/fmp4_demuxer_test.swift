import Foundation

// Host test for ios/Doorbell/Fmp4Demuxer.swift: synthesizes the init segment and the per-frame
// dbts/moof/mdat triples exactly as core's fmp4::buildInit / VideoTrack lay them out, and checks
// the demuxer returns the AVCC access units, keyframe flags, decode and capture times through
// whole-stream, byte-wise and odd-chunk feeding.

func require(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        exit(1)
    }
}

struct BoxWriter {
    var buf = Data()
    mutating func u8(_ v: UInt8) { buf.append(v) }
    mutating func u16(_ v: UInt16) { buf.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }
    mutating func u32(_ v: UInt32) {
        buf.append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)])
    }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xffff_ffff)) }
    mutating func bytes(_ d: Data) { buf.append(d) }
    mutating func zeros(_ n: Int) { buf.append(Data(count: n)) }
    mutating func fourcc(_ s: String) { buf.append(s.data(using: .ascii)!) }
    mutating func open(_ type: String) -> Int {
        let at = buf.count
        u32(0)
        fourcc(type)
        return at
    }
    mutating func openFull(_ type: String, _ version: UInt8, _ flags: UInt32) -> Int {
        let at = open(type)
        u32((UInt32(version) << 24) | (flags & 0x00ff_ffff))
        return at
    }
    mutating func close(_ at: Int) {
        let size = UInt32(buf.count - at)
        buf[at] = UInt8(size >> 24); buf[at + 1] = UInt8((size >> 16) & 0xff)
        buf[at + 2] = UInt8((size >> 8) & 0xff); buf[at + 3] = UInt8(size & 0xff)
    }
}

// SPS/PPS synthesized the way core's test_fmp4 helper does it (baseline, 40x23 macroblocks =
// 640x368, no cropping), including emulation-prevention bytes.
struct BitWriter {
    var out = [UInt8]()
    var cur: UInt32 = 0
    var nbits = 0
    mutating func bit(_ b: UInt32) {
        cur = (cur << 1) | (b & 1)
        nbits += 1
        if nbits == 8 { out.append(UInt8(cur & 0xff)); cur = 0; nbits = 0 }
    }
    mutating func u(_ v: UInt32, _ n: Int) { for i in stride(from: n - 1, through: 0, by: -1) { bit((v >> UInt32(i)) & 1) } }
    mutating func ue(_ v: UInt32) {
        let k = v + 1
        var n = 0
        while (k >> UInt32(n)) > 1 { n += 1 }
        u(0, n); u(k, n + 1)
    }
    mutating func trailing() { bit(1); while nbits != 0 { bit(0) } }
}

func makeNal(_ header: UInt8, _ rbsp: [UInt8]) -> Data {
    var nal = Data([header])
    var zeros = 0
    for b in rbsp {
        if zeros >= 2 && b <= 3 { nal.append(0x03); zeros = 0 }
        nal.append(b)
        zeros = b == 0 ? zeros + 1 : 0
    }
    return nal
}

func makeSps(mbsW: UInt32, mapH: UInt32) -> Data {
    var bw = BitWriter()
    bw.u(66, 8); bw.u(0, 8); bw.u(30, 8)
    bw.ue(0); bw.ue(0); bw.ue(2); bw.ue(1); bw.u(0, 1)
    bw.ue(mbsW - 1); bw.ue(mapH - 1)
    bw.u(1, 1); bw.u(0, 1); bw.u(0, 1); bw.u(0, 1)
    bw.trailing()
    return makeNal(0x67, bw.out)
}

func makePps() -> Data {
    var bw = BitWriter()
    bw.ue(0); bw.ue(0); bw.u(0, 2)
    bw.ue(0); bw.ue(0); bw.ue(0); bw.u(0, 1); bw.u(0, 2)
    bw.ue(0); bw.ue(0); bw.ue(0); bw.u(0, 3)
    bw.trailing()
    return makeNal(0x68, bw.out)
}

let sps = makeSps(mbsW: 40, mapH: 23)
let pps = makePps()

func avcc(_ nals: [Data]) -> Data {
    var out = Data()
    for n in nals {
        let len = UInt32(n.count)
        out.append(contentsOf: [UInt8(len >> 24), UInt8((len >> 16) & 0xff), UInt8((len >> 8) & 0xff), UInt8(len & 0xff)])
        out.append(n)
    }
    return out
}

func slice(idr: Bool, payload: Int, seed: UInt8) -> Data {
    var d = Data([idr ? 0x65 : 0x41])
    for i in 0..<payload { d.append(seed &+ UInt8(i % 0x40)) }
    return d
}

func initSegment() -> Data {
    var w = BoxWriter()
    let ftyp = w.open("ftyp"); w.fourcc("isom"); w.u32(0x200); w.fourcc("isom"); w.fourcc("iso5"); w.close(ftyp)
    let moov = w.open("moov")
    let mvhd = w.openFull("mvhd", 0, 0); w.zeros(96); w.close(mvhd)
    let trak = w.open("trak")
    let tkhd = w.openFull("tkhd", 0, 3); w.zeros(80); w.close(tkhd)
    let mdia = w.open("mdia")
    let mdhd = w.openFull("mdhd", 0, 0); w.zeros(20); w.close(mdhd)
    let hdlr = w.openFull("hdlr", 0, 0); w.u32(0); w.fourcc("vide"); w.zeros(13); w.close(hdlr)
    let minf = w.open("minf")
    let stbl = w.open("stbl")
    let stsd = w.openFull("stsd", 0, 0); w.u32(1)
    let avc1 = w.open("avc1"); w.zeros(6); w.u16(1); w.zeros(16); w.u16(640); w.u16(368)
    w.u32(0x0048_0000); w.u32(0x0048_0000); w.u32(0); w.u16(1); w.zeros(32); w.u16(0x18); w.u16(0xffff)
    let avcC = w.open("avcC"); w.u8(1); w.u8(sps[1]); w.u8(sps[2]); w.u8(sps[3]); w.u8(0xff); w.u8(0xe1)
    w.u16(UInt16(sps.count)); w.bytes(sps); w.u8(1); w.u16(UInt16(pps.count)); w.bytes(pps); w.close(avcC)
    w.close(avc1); w.close(stsd)
    w.close(stbl); w.close(minf); w.close(mdia); w.close(trak)
    let mvex = w.open("mvex"); let trex = w.openFull("trex", 0, 0); w.u32(1); w.u32(1); w.u32(0); w.u32(0); w.u32(0); w.close(trex); w.close(mvex)
    w.close(moov)
    return w.buf
}

func fragment(seq: UInt32, baseDt: UInt64, sample: Data, key: Bool, dur: UInt32, captureMs: Int64) -> Data {
    var w = BoxWriter()
    let dbts = w.open("dbts"); w.u32(1); w.u64(UInt64(bitPattern: captureMs)); w.close(dbts)
    let moof = w.open("moof")
    let mfhd = w.openFull("mfhd", 0, 0); w.u32(seq); w.close(mfhd)
    let traf = w.open("traf")
    let tfhd = w.openFull("tfhd", 0, 0x020000); w.u32(1); w.close(tfhd)
    let tfdt = w.openFull("tfdt", 1, 0); w.u64(baseDt); w.close(tfdt)
    let trun = w.openFull("trun", 0, 0x000701); w.u32(1)
    let dataOffsetAt = w.buf.count; w.u32(0)
    w.u32(dur); w.u32(UInt32(sample.count)); w.u32(key ? 0x0200_0000 : 0x0101_0000)
    w.close(trun); w.close(traf); w.close(moof)
    // data_offset is relative to the moof start: moof size + mdat header.
    let dataOffset = UInt32(w.buf.count - moof + 8)
    w.buf[dataOffsetAt] = UInt8(dataOffset >> 24); w.buf[dataOffsetAt + 1] = UInt8((dataOffset >> 16) & 0xff)
    w.buf[dataOffsetAt + 2] = UInt8((dataOffset >> 8) & 0xff); w.buf[dataOffsetAt + 3] = UInt8(dataOffset & 0xff)
    let mdat = w.open("mdat"); w.bytes(sample); w.close(mdat)
    return w.buf
}

@main
struct Fmp4DemuxerTest {
    static func main() {
        let idr = avcc([sps, pps, slice(idr: true, payload: 300, seed: 0x80)])
        let p1 = avcc([slice(idr: false, payload: 120, seed: 0x90)])
        let p2 = avcc([slice(idr: false, payload: 130, seed: 0xa0)])
        var stream = initSegment()
        stream.append(fragment(seq: 1, baseDt: 0, sample: idr, key: true, dur: 40, captureMs: 1000))
        stream.append(fragment(seq: 2, baseDt: 40, sample: p1, key: false, dur: 40, captureMs: 1040))
        stream.append(Data([0, 0, 0, 8]) + "free".data(using: .ascii)!)
        stream.append(fragment(seq: 3, baseDt: 80, sample: p2, key: false, dur: 40, captureMs: 1080))

        for mode in ["whole", "bytewise", "chunks"] {
            let d = Fmp4Demuxer()
            var configs: [Fmp4Demuxer.Config] = []
            var units: [Fmp4Demuxer.AccessUnit] = []
            d.onConfig = { configs.append($0) }
            d.onSample = { units.append($0) }
            do {
                switch mode {
                case "whole":
                    try d.feed(stream)
                case "bytewise":
                    for b in stream { try d.feed(Data([b])) }
                default:
                    var i = 0
                    var n = 7
                    while i < stream.count {
                        let take = min(n, stream.count - i)
                        try d.feed(stream.subdata(in: i..<(i + take)))
                        i += take
                        n = (n * 3) % 61 + 1
                    }
                }
            } catch {
                require(false, "\(mode): unexpected failure \(error)")
            }
            require(configs.count == 1, "\(mode): one configuration")
            require(configs[0].sps == sps && configs[0].pps == pps, "\(mode): SPS/PPS from avcC")
            require(configs[0].nalLengthSize == 4, "\(mode): 4-byte NAL lengths")
            require(configs[0].width == 640 && configs[0].height == 368,
                    "\(mode): dimensions from the SPS, got \(configs[0].width)x\(configs[0].height)")
            require(units.count == 3, "\(mode): three access units, got \(units.count)")
            require(units[0].key && !units[1].key && !units[2].key, "\(mode): keyframe flags")
            require(units[0].avcc == idr && units[1].avcc == p1 && units[2].avcc == p2,
                    "\(mode): AVCC payloads pass through untouched")
            require(units.map { $0.captureMs } == [1000, 1040, 1080], "\(mode): capture times from dbts")
            require(units.map { $0.dts } == [0, 40, 80], "\(mode): decode times from tfdt")
            require(d.buffered == 0 && d.samples == 3, "\(mode): nothing left buffered")
        }

        // Failures are terminal until reset.
        do {
            let d = Fmp4Demuxer()
            var threw: Fmp4Demuxer.Failure?
            do { try d.feed(fragment(seq: 1, baseDt: 0, sample: idr, key: true, dur: 40, captureMs: 0)) }
            catch let e as Fmp4Demuxer.Failure { threw = e } catch {}
            require(threw == .moofBeforeInit, "moof before init is rejected")
            var again: Fmp4Demuxer.Failure?
            do { try d.feed(initSegment()) } catch let e as Fmp4Demuxer.Failure { again = e } catch {}
            require(again == .moofBeforeInit, "stays failed until reset")
            d.reset()
            do { try d.feed(initSegment()) } catch { require(false, "feed after reset") }
            require(d.config != nil, "configured after reset")
        }
        do {
            let d = Fmp4Demuxer()
            var threw: Fmp4Demuxer.Failure?
            do { try d.feed(Data([0x01, 0, 0, 0]) + "mdat".data(using: .ascii)!) }
            catch let e as Fmp4Demuxer.Failure { threw = e } catch {}
            require(threw == .boxTooLarge("mdat"), "oversized mdat header is rejected before buffering")
        }
        do {
            let d = Fmp4Demuxer()
            var threw: Fmp4Demuxer.Failure?
            do { try d.feed(Data([0, 0, 0, 16]) + "moov".data(using: .ascii)! + Data([0, 0, 0, 8]) + "free".data(using: .ascii)!) }
            catch let e as Fmp4Demuxer.Failure { threw = e } catch {}
            require(threw == .moovWithoutAvcC, "moov without avcC is rejected")
        }

        print("PASS: fMP4 demuxer reproduces core's access units from whole, byte-wise and chunked input")
    }
}
