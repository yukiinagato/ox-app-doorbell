// MJPEG (multipart/x-mixed-replace) の自前デコーダ — 外部ライブラリ禁止の方針のため
// URLSession のストリーム受信 + 境界パース + UIImage で組む (Android MjpegStreamer と同役)。
// 子機 httpd の /stream.mjpeg はパート毎に Content-Length を必ず付ける (httpd.cpp) ので
// ヘッダの Content-Length を読んで本文をそのまま切り出す。
// 接続断は 2 秒後に自動再接続 (stop まで)。コールバックは main queue で呼ばれる。
import Foundation
import UIKit

final class MjpegClient: NSObject, URLSessionDataDelegate {

    private let url: URL
    private let onFrame: (UIImage) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buf = Data()
    private var expecting = -1  // 現パートの Content-Length (-1 = ヘッダ読み中)
    private var running = false

    private static let maxFrame = 4 * 1024 * 1024  // JPEG 1 枚の上限 (安全弁)
    private static let maxBuffer = 8 * 1024 * 1024 // 受信バッファの上限 (異常ストリーム対策)

    init?(urlString: String, onFrame: @escaping (UIImage) -> Void) {
        guard let u = URL(string: urlString) else { return nil }
        self.url = u
        self.onFrame = onFrame
        super.init()
    }

    func start() {
        guard !running else { return }
        running = true
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
        cfg.timeoutIntervalForRequest = 10       // 受信間隔の上限 (フレームが来なければ切る)
        cfg.timeoutIntervalForResource = 86_400  // ストリームは長寿命
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        let t = s.dataTask(with: url)
        task = t
        t.resume()
    }

    // MARK: - URLSessionDataDelegate (delegate queue — main ではない)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard running else { return }
        buf.append(data)
        if buf.count > MjpegClient.maxBuffer {  // パース不能なストリーム — 仕切り直し
            buf.removeAll(keepingCapacity: true)
            expecting = -1
            return
        }
        parseLoop()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard running else { return }
        // 接続断 — 2 秒後に再接続 (Android 版と同じ)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.connect()
        }
    }

    // MARK: - 境界パース

    private func parseLoop() {
        while true {
            if expecting < 0 {
                // ヘッダ行 (--frame, Content-Type, Content-Length, 空行)。空行でヘッダ終了。
                guard let headerEnd = findHeaderEnd() else { return }  // ヘッダ未着
                let header = String(data: buf.prefix(headerEnd.headerLen), encoding: .ascii) ?? ""
                buf.removeFirst(headerEnd.consumed)
                var len = -1
                for line in header.split(separator: "\n") {
                    let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    let p = l.split(separator: ":", maxSplits: 1)
                    if p.count == 2,
                       p[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                        len = Int(p[1].trimmingCharacters(in: .whitespaces)) ?? -1
                    }
                }
                if len <= 0 || len > MjpegClient.maxFrame { continue }  // 次の境界を探し直す
                expecting = len
            }
            guard buf.count >= expecting else { return }  // 本文未着
            let jpeg = buf.prefix(expecting)
            buf.removeFirst(expecting)
            expecting = -1
            if let img = UIImage(data: jpeg) {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.running else { return }
                    self.onFrame(img)
                }
            }
        }
    }

    /// 空行 (\r\n\r\n or \n\n) までをヘッダとして探す。戻り: (ヘッダ長, 消費長)。
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
