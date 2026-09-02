import AVFoundation
import Foundation
import UIKit

/// Plays MJPEG continuously as the availability layer and promotes H.264 only after it renders.
final class AdaptiveH264MjpegPlayer: NSObject {
    private let h264Host: UIView
    private let mjpegView: UIImageView
    private let noVideoLabel: UILabel
    private let playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var mjpeg: MjpegClient?
    private var h264URL: URL?
    private var mjpegURL = ""
    private var firstFrameTimer: Timer?
    private var retryTimer: Timer?
    private var rotationTimer: Timer?
    private var h264Attempt = 0
    private var h264Visible = false
    private var running = false
    private var observingReady = false
    private var observingItem = false
    private var rotation = 0

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

    init(h264Host: UIView, mjpegView: UIImageView, noVideoLabel: UILabel) {
        self.h264Host = h264Host
        self.mjpegView = mjpegView
        self.noVideoLabel = noVideoLabel
        super.init()
        h264Host.clipsToBounds = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.isHidden = true
        h264Host.layer.addSublayer(playerLayer)
    }

    deinit { stop() }

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
        playerLayer.isHidden = true
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
        playerLayer.isHidden = true
        mjpegView.isHidden = false

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .none
        if #available(iOS 10.0, tvOS 10.0, *) {
            newPlayer.automaticallyWaitsToMinimizeStalling = false
        }
        player = newPlayer
        playerItem = item
        playerLayer.player = newPlayer
        playerLayer.addObserver(self, forKeyPath: "readyForDisplay", options: [.new], context: nil)
        observingReady = true
        item.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        observingItem = true
        NotificationCenter.default.addObserver(self, selector: #selector(h264Stalled(_:)),
                                               name: .AVPlayerItemPlaybackStalled, object: item)
        NotificationCenter.default.addObserver(self, selector: #selector(h264Ended(_:)),
                                               name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        applyH264Transform()
        newPlayer.play()
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
        if observingReady {
            playerLayer.removeObserver(self, forKeyPath: "readyForDisplay")
            observingReady = false
        }
        if observingItem, let item = playerItem {
            item.removeObserver(self, forKeyPath: "status")
            observingItem = false
        }
        NotificationCenter.default.removeObserver(self)
        player?.pause()
        player = nil
        playerItem = nil
        playerLayer.player = nil
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "readyForDisplay", object as AnyObject? === playerLayer {
            DispatchQueue.main.async { [weak self] in self?.showH264IfReady() }
        } else if keyPath == "status", let item = object as? AVPlayerItem, item === playerItem,
                  item.status == .failed {
            DispatchQueue.main.async { [weak self] in
                self?.h264Failed(item.error?.localizedDescription ?? "H.264 playback failed")
            }
        }
    }

    private func showH264IfReady() {
        guard running, playerLayer.isReadyForDisplay else { return }
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        h264Visible = true
        playerLayer.isHidden = false
        mjpegView.isHidden = true
        noVideoLabel.isHidden = true
        applyH264Transform()
    }

    @objc private func h264Stalled(_ notification: Notification) {
        guard notification.object as? AVPlayerItem === playerItem else { return }
        h264Failed("H.264 playback stalled")
    }

    @objc private func h264Ended(_ notification: Notification) {
        guard notification.object as? AVPlayerItem === playerItem else { return }
        h264Failed("H.264 playback ended")
    }

    private func h264Failed(_ reason: String) {
        guard running, h264URL != nil else { return }
        h264Visible = false
        playerLayer.isHidden = true
        mjpegView.isHidden = false
        tearDownH264()
        startMjpeg()
        retryTimer?.invalidate()
        retryTimer = IOSAvailability.scheduledTimer(
            withTimeInterval: Self.retryInterval, repeats: false
        ) { [weak self] _ in self?.startH264() }
        NSLog("[doorbell] H.264 fallback to MJPEG: %@", reason)
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
                self.rotation = ((value % 360) + 360) % 360
                self.applyH264Transform()
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
        if frameTimestamps.count >= 2 {
            let intervals = zip(frameTimestamps.dropFirst(), frameTimestamps).map { $0 - $1 }
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            if mean > 0 { stats.fps = Int((1 / mean).rounded()) }
            let variance = intervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                / Double(intervals.count)
            stats.jitterMs = Int((variance.squareRoot() * 1000).rounded())
            if let last = frameTimestamps.last {
                stats.latencyMs = Int(((CACurrentMediaTime() - last) * 1000).rounded())
            }
        }
        guard h264Visible, let item = playerItem else { return stats }
        if let event = item.accessLog()?.events.last {
            stats.dropped = max(0, event.numberOfDroppedVideoFrames)
        }
        // Distance from the live edge is the only latency AVPlayer exposes for a live fMP4 feed.
        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            let edge = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            let now = CMTimeGetSeconds(item.currentTime())
            if edge.isFinite, now.isFinite, edge >= now {
                stats.latencyMs = Int(((edge - now) * 1000).rounded())
            }
        }
        let size = item.presentationSize
        if size.width > 0, size.height > 0 { reportSize(size, degrees: rotation) }
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
        playerLayer.setAffineTransform(.identity)
        playerLayer.frame = h264Host.bounds
        guard (rotation == 90 || rotation == 270), playerLayer.bounds.width > 0,
              playerLayer.bounds.height > 0 else { return }
        let size = playerItem?.presentationSize ?? .zero
        guard size.width > 0, size.height > 0 else { return }
        let base = min(playerLayer.bounds.width / size.width, playerLayer.bounds.height / size.height)
        let rotated = min(playerLayer.bounds.width / size.height, playerLayer.bounds.height / size.width)
        let scale = base > 0 ? rotated / base : 1
        playerLayer.setAffineTransform(
            CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180).scaledBy(x: scale, y: scale)
        )
    }
}
