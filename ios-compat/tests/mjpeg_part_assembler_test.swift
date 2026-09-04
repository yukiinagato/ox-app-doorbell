import Foundation

// Host test for ios/Doorbell/MjpegPartAssembler.swift. It replays the two ways a
// multipart/x-mixed-replace stream reaches a Swift client:
//  1. the way CFNetwork actually delivers it (one beginPart per part, bodies only) — the case the
//     iPad mini 3 hit, where the old header-searching parser never produced a frame;
//  2. the in-band form (headers inside the body), which must keep working.

func require(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        exit(1)
    }
}

func jpeg(_ payload: [UInt8]) -> Data {
    Data([0xFF, 0xD8, 0xFF, 0xE0] + payload + [0xFF, 0xD9])
}

@main
struct MjpegPartAssemblerTest {
    static func main() {
        let first = jpeg([0x01, 0x02, 0x03])
        let second = jpeg([0x0A, 0x0A, 0x0D, 0x0A, 0x0D, 0x0A, 0x04])   // contains CRLFCRLF and LFLF
        let third = jpeg([0x05])

        // 1a. CFNetwork layout with Content-Length on every part, bodies fragmented byte by byte.
        do {
            let a = MjpegPartAssembler()
            var frames: [MjpegPartAssembler.Frame] = []
            for (body, rotation) in [(first, 270), (second, 270), (third, 90)] {
                require(a.beginPart(contentLength: body.count, rotation: rotation) == nil,
                        "counted parts never leave a frame to flush")
                for byte in body { frames += a.append(Data([byte])) }
            }
            require(frames.map { $0.jpeg } == [first, second, third],
                    "bodies-only stream with Content-Length yields exactly the three JPEGs")
            require(frames.map { $0.rotation } == [270, 270, 90],
                    "rotation comes from the per-part response headers")
            require(a.discardedBytes == 0, "nothing discarded on a clean counted stream")
        }

        // 1b. CFNetwork layout without Content-Length: frames are marker-delimited and the last one is
        //     flushed by the next part's beginPart.
        do {
            let a = MjpegPartAssembler()
            var frames: [MjpegPartAssembler.Frame] = []
            a.beginPart(contentLength: -1, rotation: 180)
            frames += a.append(first)
            require(frames.count == 1 && frames[0].jpeg == first && frames[0].rotation == 180,
                    "marker-delimited body emits once the EOI arrives")
            frames += a.append(second.prefix(4))
            require(frames.count == 1, "a partial body is held")
            frames += a.append(second.suffix(from: 4))
            require(frames.count == 2 && frames[1].jpeg == second,
                    "JPEG bytes that look like header delimiters do not split a marker-delimited frame")
            frames += a.append(third.prefix(third.count - 1))
            if let flushed = a.beginPart(contentLength: -1, rotation: nil) { frames.append(flushed) }
            require(frames.count == 2, "an incomplete body is dropped at the next part, not emitted")
            require(a.discardedBytes == third.count - 1, "the dropped tail is accounted for")
            frames += a.append(third)
            require(frames.count == 3 && frames[2].rotation == 180,
                    "a part without a rotation header keeps the last known rotation")
        }

        // 1c. Bodies arrive before any beginPart (a stack that never announces parts): the SOI decides
        //     the layout and marker-delimited parsing still produces frames.
        do {
            let a = MjpegPartAssembler()
            let frames = a.append(first + second)
            require(frames.map { $0.jpeg } == [first, second],
                    "bodies-only layout is detected from the JPEG SOI without any beginPart")
        }

        // 2. In-band headers (the old wire format), fragmented, with a boundary tail after the part.
        do {
            let a = MjpegPartAssembler()
            var stream = Data()
            stream += "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(first.count)\r\n".data(using: .ascii)!
            stream += "X-Doorbell-Video-Rotation: 270\r\n\r\n".data(using: .ascii)!
            stream += first
            stream += "\r\n--frame\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .ascii)!   // no length
            stream += second
            stream += "\r\n--frame\r\n".data(using: .ascii)!
            var frames: [MjpegPartAssembler.Frame] = []
            for byte in stream { frames += a.append(Data([byte])) }
            require(frames.map { $0.jpeg } == [first, second],
                    "in-band Content-Length and marker-delimited parts are both emitted")
            require(frames.map { $0.rotation } == [270, 270],
                    "in-band rotation header applies and persists to the next part")
        }

        // 3. Layout detection.
        require(MjpegPartAssembler.layoutName(for: Data([0xFF])) == "undecided",
                "one byte is not enough to decide")
        require(MjpegPartAssembler.layoutName(for: Data([0xFF, 0xD8])) == "bodies_only",
                "a JPEG SOI means CFNetwork already consumed the headers")
        require(MjpegPartAssembler.layoutName(for: "\r\n--frame".data(using: .ascii)!) == "headers_in_band",
                "a boundary line after a CRLF tail means in-band headers")
        require(MjpegPartAssembler.layoutName(for: "Content-Type".data(using: .ascii)!) == "headers_in_band",
                "header text means in-band headers")

        // 4. Bounds: an endless body without EOI is dropped once it exceeds the frame limit.
        do {
            let a = MjpegPartAssembler()
            a.beginPart(contentLength: -1, rotation: nil)
            _ = a.append(Data([0xFF, 0xD8]) + Data(count: MjpegPartAssembler.maxFrame))
            require(a.discardedBytes >= MjpegPartAssembler.maxFrame, "oversized marker body released")
            let bad = a.beginPart(contentLength: MjpegPartAssembler.maxFrame + 1, rotation: nil)
            require(bad == nil, "an oversized Content-Length falls back to marker delimiting")
            let frames = a.append(first)
            require(frames.count == 1, "marker delimiting still works after an oversized length")
        }

        print("PASS: MJPEG part assembler handles CFNetwork per-part delivery and in-band headers")
    }
}
