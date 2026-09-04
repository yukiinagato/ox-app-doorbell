import Foundation
import QuartzCore
import UIKit

// Frames are reassembled by MjpegPartAssembler (which knows that CFNetwork strips the part
// headers of multipart/x-mixed-replace and announces every part through didReceive response),
// decoded off the main thread, and delivered to UI only after a running-state check.
final class MjpegClient: NSObject, URLSessionDataDelegate {

    private let url: URL
    private let onFrame: (UIImage, Int) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let assembler = MjpegPartAssembler()
    private var running = false
    private var startupAt: CFTimeInterval = 0
    private var responsesSeen = 0
    private var tracedHeaders = false
    private var tracedPartResponse = false
    private var tracedData = false
    private var tracedPart = false
    private var tracedDecode = false
    private var tracedMain = false

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
        tracedPartResponse = false
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
        assembler.reset()
        responsesSeen = 0
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

    /// CFNetwork calls this once for the multipart response and then once per part, with the
    /// part's own headers (Content-Length, X-Doorbell-Video-Rotation) on the HTTPURLResponse.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard running else { completionHandler(.cancel); return }
        responsesSeen += 1
        if !tracedHeaders {
            tracedHeaders = true
            trace("http_response_headers")
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        if http.statusCode < 200 || http.statusCode >= 300 {
            trace("http_status_\(http.statusCode)")
            completionHandler(.cancel)
            return
        }
        let mime = (http.mimeType ?? "").lowercased()
        let isPart = mime == "image/jpeg" || responsesSeen > 1
        if isPart {
            if !tracedPartResponse {
                tracedPartResponse = true
                trace("first_part_response")
            }
            let length = MjpegClient.intHeader("Content-Length", in: http)
                ?? Int(exactly: http.expectedContentLength) ?? -1
            let rotation = MjpegClient.intHeader("X-Doorbell-Video-Rotation", in: http)
            if let flushed = assembler.beginPart(contentLength: length, rotation: rotation) {
                deliver(flushed)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard running else { return }
        if !tracedData {
            tracedData = true
            trace("first_network_bytes")
        }
        for frame in assembler.append(data) { deliver(frame) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard running else { return }
        if let error = error as NSError? {
            trace("transport_error_\(error.domain)_\(error.code)")
        } else {
            trace("stream_ended")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.connect()
        }
    }

    private func deliver(_ frame: MjpegPartAssembler.Frame) {
        if !tracedPart {
            tracedPart = true
            trace("first_complete_multipart")
        }
        guard let img = UIImage(data: frame.jpeg) else { return }
        if !tracedDecode {
            tracedDecode = true
            trace("first_jpeg_decoded")
        }
        let rotation = frame.rotation
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.running else { return }
            if !self.tracedMain {
                self.tracedMain = true
                self.trace("first_frame_on_main_thread")
            }
            self.onFrame(img, rotation)
        }
    }

    /// Case-insensitive header lookup; `allHeaderFields` keys keep the server's casing on iOS 12.
    private static func intHeader(_ name: String, in response: HTTPURLResponse) -> Int? {
        let wanted = name.lowercased()
        for (key, value) in response.allHeaderFields {
            guard let k = key as? String, k.lowercased() == wanted else { continue }
            if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
            if let n = value as? NSNumber { return n.intValue }
        }
        return nil
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
}
