import Foundation
import QuartzCore
import UIKit

// Content-Length, header, and aggregate buffer limits bound untrusted multipart input. Frames are
// decoded off the main thread and delivered to UI only after a running-state check.
final class MjpegClient: NSObject, URLSessionDataDelegate {

    private let url: URL
    private let onFrame: (UIImage, Int) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buf = Data()
    private var expecting = -1
    private var expectingRotation = 0
    private var running = false
    private var startupAt: CFTimeInterval = 0
    private var tracedHeaders = false
    private var tracedData = false
    private var tracedPart = false
    private var tracedDecode = false
    private var tracedMain = false

    private static let maxFrame = 4 * 1024 * 1024
    private static let maxBuffer = 8 * 1024 * 1024

    init?(urlString: String, onFrame: @escaping (UIImage, Int) -> Void) {
        guard let u = URL(string: urlString) else { return nil }
        self.url = u
        self.onFrame = onFrame
        super.init()
    }

    func start() {
        guard !running else { return }
        running = true
        startupAt = CACurrentMediaTime()
        tracedHeaders = false
        tracedData = false
        tracedPart = false
        tracedDecode = false
        tracedMain = false
        trace("request_start")
        connect()
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func connect() {
        guard running else { return }
        buf.removeAll(keepingCapacity: true)
        expecting = -1
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


    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard running else { return }
        if !tracedData {
            tracedData = true
            trace("first_network_bytes")
        }
        buf.append(data)
        if buf.count > MjpegClient.maxBuffer {
            buf.removeAll(keepingCapacity: true)
            expecting = -1
            return
        }
        parseLoop()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard running else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.connect()
        }
    }


    private func parseLoop() {
        while true {
            if expecting < 0 {
                guard let headerEnd = findHeaderEnd() else { return }
                let header = String(data: buf.prefix(headerEnd.headerLen), encoding: .ascii) ?? ""
                buf.removeFirst(headerEnd.consumed)
                var len = -1
                var rotation = 0
                for line in header.split(separator: "\n") {
                    let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    let p = l.split(separator: ":", maxSplits: 1)
                    if p.count == 2,
                       p[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                        len = Int(p[1].trimmingCharacters(in: .whitespaces)) ?? -1
                    } else if p.count == 2,
                              p[0].trimmingCharacters(in: .whitespaces).lowercased() ==
                                  "x-doorbell-video-rotation" {
                        rotation = Int(p[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
                if len <= 0 || len > MjpegClient.maxFrame { continue }
                expecting = len
                expectingRotation = ((rotation % 360) + 360) % 360
            }
            guard buf.count >= expecting else { return }
            let jpeg = buf.prefix(expecting)
            buf.removeFirst(expecting)
            expecting = -1
            if !tracedPart {
                tracedPart = true
                trace("first_complete_multipart")
            }
            if let img = UIImage(data: jpeg) {
                if !tracedDecode {
                    tracedDecode = true
                    trace("first_jpeg_decoded")
                }
                let rotation = expectingRotation
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.running else { return }
                    if !self.tracedMain {
                        self.tracedMain = true
                        self.trace("first_frame_on_main_thread")
                    }
                    self.onFrame(img, rotation)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if !tracedHeaders {
            tracedHeaders = true
            trace("http_response_headers")
        }
        completionHandler(.allow)
    }

    private func trace(_ stage: String) {
        let elapsed = max(0, Int((CACurrentMediaTime() - startupAt) * 1000))
        let line = "\(stage) +\(elapsed)ms\n"
        NSLog("[doorbell][video-startup] %@", line.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).last
        else { return }
        let target = directory.appendingPathComponent("video-startup.log")
        let data = line.data(using: .utf8) ?? Data()
        if !FileManager.default.fileExists(atPath: target.path) {
            FileManager.default.createFile(atPath: target.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: target) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
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
}
