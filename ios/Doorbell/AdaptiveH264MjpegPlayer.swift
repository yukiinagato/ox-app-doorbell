import AVFoundation
import Foundation
import UIKit

/// Plays MJPEG continuously as the availability layer and promotes H.264 only after it renders.
/// H.264 goes through `H264SampleLayerPlayer` (demuxed fMP4 on an AVSampleBufferDisplayLayer);
/// AVPlayer was the previous route and never opened the door station's endless live stream.
final class AdaptiveH264MjpegPlayer: NSObject {
    private let h264Host: UIView
    private let mjpegView: UIImageView
    private let noVideoLabel: UILabel
    private var h264Player: H264SampleLayerPlayer?
    private var mjpeg: MjpegClient?
    private var h264URL: URL?
    private var mjpegURL = ""
    private var firstFrameTimer: Timer?
    private var retryTimer: Timer?
    private var rotationTimer: Timer?
    private var h264Attempt = 0
    private var h264Visible = false
    private var running = false
    private var rotation = 0
    private var h264Size: CGSize = .zero

    /// Reported whenever the source's picture geometry becomes known or changes, already rotated
    /// the way it is displayed. The incoming screen sizes its video box from this so a portrait
    /// door camera is shown portrait instead of being letterboxed into a landscape frame.
    var onVideoSize: ((CGSize) -> Void)?

    private var frameTimestamps: [CFTimeInterval] = []
    private var lastReportedSize: CGSize = .zero

    /// What the unobtrusive debug line on the incoming screen shows.
    struct Stats {
        var codec = "-"
        var latencyMs = 0
        var jitterMs = 0
        var fps = 0
        var dropped = 0
    }

    private static let firstFrameTimeout: TimeInterval = 3
    private static let retryInterval: TimeInterval = 5

    /// Measured decode outcome for the runtime supervisor: (verified, state). Set once by the
    /// main view controller; "verified" only after a frame was actually shown.
    static var onDecodeState: ((Bool, String) -> Void)?

    /// Kept for the app delegates: the sample-buffer player has nothing to warm up.
    static func prewarm() {}
    static func purgeWarmResources() {}

    init(h264Host: UIView, mjpegView: UIImageView, noVideoLabel: UILabel) {
        self.h264Host = h264Host
        self.mjpegView = mjpegView
        self.noVideoLabel = noVideoLabel
        super.init()
        h264Host.clipsToBounds = true
    }

    deinit {
        stop()
    }

    func start(h264URLString: String, mjpegURL: String, h264Enabled: Bool) {
        stop()
        running = true
        self.mjpegURL = mjpegURL
        h264URL = URL(string: h264URLString)
        noVideoLabel.isHidden = false
        mjpegView.image = nil
        mjpegView.isHidden = false
        startMjpeg()
        guard h264Enabled, h264URL != nil else { return }
        startH264()
        startRotationPolling()
    }

    func stop() {
        running = false
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        rotationTimer?.invalidate()
        rotationTimer = nil
        mjpeg?.stop()
        mjpeg = nil
        tearDownH264()
        h264URL = nil
        h264Visible = false
    }

    func layout() {
        applyH264Transform()
    }

    private func startMjpeg() {
        guard mjpeg == nil, !mjpegURL.isEmpty else { return }
        mjpeg = MjpegClient(urlString: mjpegURL) { [weak self] image, degrees in
            guard let self = self, self.running else { return }
            self.mjpegView.image = image
            self.applyMjpegTransform(degrees, image: image)
            self.noteFrame()
            self.reportSize(image.size, degrees: degrees)
            if !self.h264Visible { self.noVideoLabel.isHidden = true }
        }
        mjpeg?.start()
    }

    private func startH264() {
        guard running, let url = h264URL else { return }
        let attempt = h264Attempt + 1
        h264Attempt = attempt
        firstFrameTimer?.invalidate()
        retryTimer?.invalidate()
        tearDownH264()
        h264Visible = false
        mjpegView.isHidden = false

        let player = H264SampleLayerPlayer(url: url)
        player.layer.isHidden = true
        player.layer.frame = h264Host.bounds
        h264Host.layer.addSublayer(player.layer)
        player.onVideoSize = { [weak self] size in
            guard let self = self, self.running else { return }
            self.h264Size = size
            self.applyH264Transform()
            if self.h264Visible { self.reportSize(size, degrees: self.rotation) }
        }
        player.onFirstFrame = { [weak self] in
            guard let self = self, self.running, self.h264Attempt == attempt else { return }
            self.showH264()
        }
        player.onFailure = { [weak self] reason in
            guard let self = self, self.running, self.h264Attempt == attempt else { return }
            self.h264Failed(reason)
        }
        h264Player = player
        player.start()
        firstFrameTimer = IOSAvailability.scheduledTimer(
            withTimeInterval: Self.firstFrameTimeout, repeats: false
        ) { [weak self] _ in
            guard let self = self, self.running, self.h264Attempt == attempt,
                  !self.h264Visible else { return }
            self.h264Failed("H.264 first-frame timeout")
        }
    }

    private func tearDownH264() {
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        if let player = h264Player {
            player.onFirstFrame = nil
            player.onFailure = nil
            player.onVideoSize = nil
            player.stop()
            player.layer.removeFromSuperlayer()
        }
        h264Player = nil
        h264Size = .zero
    }

    private func showH264() {
        guard running, let player = h264Player else { return }
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        h264Visible = true
        player.layer.isHidden = false
        mjpegView.isHidden = true
        noVideoLabel.isHidden = true
        applyH264Transform()
        Self.onDecodeState?(true, "verified")
        if h264Size.width > 0 { reportSize(h264Size, degrees: rotation) }
        // The MJPEG availability layer has done its job; a later H.264 failure restarts it.
        mjpeg?.stop()
        mjpeg = nil
    }

    private func h264Failed(_ reason: String) {
        guard running, h264URL != nil else { return }
        h264Visible = false
        mjpegView.isHidden = false
        tearDownH264()
        startMjpeg()
        retryTimer?.invalidate()
        retryTimer = IOSAvailability.scheduledTimer(
            withTimeInterval: Self.retryInterval, repeats: false
        ) { [weak self] _ in self?.startH264() }
        NSLog("[doorbell] H.264 fallback to MJPEG: %@", reason)
        Self.onDecodeState?(false, reason.hasPrefix("display_layer_failed") ||
                                   reason.hasPrefix("format_description") ? "failed" : "runtime_failed")
    }

    private func startRotationPolling() {
        guard h264URL != nil else { return }
        rotationTimer = IOSAvailability.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in self?.fetchRotation()
        }
        fetchRotation()
    }

    private func fetchRotation() {
        guard let url = h264URL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.path = "/video-meta"
        guard let metaURL = components.url else { return }
        URLSession.shared.dataTask(with: metaURL) { [weak self] data, response, _ in
            guard let self = self, self.running,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = json["rotation"] as? Int else { return }
            DispatchQueue.main.async {
                guard self.running else { return }
                let normalized = ((value % 360) + 360) % 360
                let changed = normalized != self.rotation
                self.rotation = normalized
                self.applyH264Transform()
                if changed, self.h264Visible, self.h264Size.width > 0 {
                    self.reportSize(self.h264Size, degrees: normalized)
                }
            }
        }.resume()
    }

    /// Frame arrival times over the last two seconds drive both the frame rate and the jitter the
    /// debug line reports; nothing else in the player depends on them.
    private func noteFrame() {
        let now = CACurrentMediaTime()
        frameTimestamps.append(now)
        while let first = frameTimestamps.first, now - first > 2 { frameTimestamps.removeFirst() }
    }

    private func reportSize(_ size: CGSize, degrees: Int) {
        guard size.width > 0, size.height > 0 else { return }
        let value = ((degrees % 360) + 360) % 360
        let displayed = (value == 90 || value == 270)
            ? CGSize(width: size.height, height: size.width) : size
        guard displayed != lastReportedSize else { return }
        lastReportedSize = displayed
        onVideoSize?(displayed)
    }

    /// Live counters for the incoming screen's debug line. Everything here is measured, never
    /// guessed: an unavailable number stays zero rather than being invented.
    func statsSnapshot() -> Stats {
        var stats = Stats()
        stats.codec = h264Visible ? "h264" : (mjpeg != nil ? "mjpeg" : "-")
        var intervals: [Double] = []
        if h264Visible, let player = h264Player {
            intervals = player.recentIntervals()
            let snapshot = player.snapshot()
            stats.dropped = snapshot.dropped
            if snapshot.latencyMs >= 0 { stats.latencyMs = snapshot.latencyMs }
        } else if frameTimestamps.count >= 2 {
            intervals = zip(frameTimestamps.dropFirst(), frameTimestamps).map { $0 - $1 }
            if let last = frameTimestamps.last {
                stats.latencyMs = Int(((CACurrentMediaTime() - last) * 1000).rounded())
            }
        }
        if !intervals.isEmpty {
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            if mean > 0 { stats.fps = Int((1 / mean).rounded()) }
            let variance = intervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                / Double(intervals.count)
            stats.jitterMs = Int((variance.squareRoot() * 1000).rounded())
        }
        return stats
    }

    private func applyMjpegTransform(_ degrees: Int, image: UIImage) {
        let value = ((degrees % 360) + 360) % 360
        var scale: CGFloat = 1
        if (value == 90 || value == 270), mjpegView.bounds.width > 0, mjpegView.bounds.height > 0,
           image.size.width > 0, image.size.height > 0 {
            let base = min(mjpegView.bounds.width / image.size.width,
                           mjpegView.bounds.height / image.size.height)
            let rotated = min(mjpegView.bounds.width / image.size.height,
                              mjpegView.bounds.height / image.size.width)
            if base > 0 { scale = rotated / base }
        }
        mjpegView.transform = CGAffineTransform(rotationAngle: CGFloat(value) * .pi / 180)
            .scaledBy(x: scale, y: scale)
    }

    private func applyH264Transform() {
        guard let layer = h264Player?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.setAffineTransform(.identity)
        layer.frame = h264Host.bounds
        guard (rotation == 90 || rotation == 270), layer.bounds.width > 0,
              layer.bounds.height > 0 else { return }
        let size = h264Size
        guard size.width > 0, size.height > 0 else { return }
        let base = min(layer.bounds.width / size.width, layer.bounds.height / size.height)
        let rotated = min(layer.bounds.width / size.height, layer.bounds.height / size.width)
        let scale = base > 0 ? rotated / base : 1
        layer.setAffineTransform(
            CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180).scaledBy(x: scale, y: scale)
        )
    }
}
