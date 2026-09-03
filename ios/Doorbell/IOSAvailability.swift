import AVFoundation
import Foundation
#if !IOS9_COMPAT
import os.log
#endif
import UIKit

/// Centralizes APIs whose modern spelling is unavailable on the iOS 9 runtime.
/// Both the current target and the iOS 9 compatibility target compile this file.
enum IOSAvailability {
    private static let timerDispatcher = LegacyTimerDispatcher()

#if os(iOS)
    /// Returns the clockwise transform receivers need for an unrotated camera sample buffer.
    /// `UIDeviceOrientation` names the physical edge facing left/right, so its landscape values
    /// are the inverse of the transform that makes the captured pixels upright remotely.
    static func cameraFrameRotation(for orientation: UIDeviceOrientation) -> Int32? {
        switch orientation {
        case .portrait:
            return 0
        case .landscapeLeft:
            return 270
        case .portraitUpsideDown:
            return 180
        case .landscapeRight:
            return 90
        default:
            return nil
        }
    }
#endif

    static func scheduledTimer(withTimeInterval interval: TimeInterval,
                               repeats: Bool,
                               block: @escaping (Timer) -> Void) -> Timer {
        let invocation = LegacyTimerInvocation(block: block)
        return Timer.scheduledTimer(timeInterval: interval,
                                    target: timerDispatcher,
                                    selector: #selector(LegacyTimerDispatcher.invoke(_:)),
                                    userInfo: invocation,
                                    repeats: repeats)
    }

    /// Spinner whose style name differs by platform minimum: the modern cases exist only from
    /// iOS/tvOS 13, and the iOS build still has to run on iOS 9.
    static func activityIndicator(large: Bool) -> UIActivityIndicatorView {
#if os(tvOS)
        return UIActivityIndicatorView(style: large ? .large : .medium)
#else
        return UIActivityIndicatorView(style: large ? .whiteLarge : .white)
#endif
    }

    static func safeAreaLayoutGuide(for view: UIView) -> UILayoutGuide {
        if #available(iOS 11.0, tvOS 11.0, *) {
            return view.safeAreaLayoutGuide
        }
        return view.layoutMarginsGuide
    }

#if os(iOS)
    @discardableResult
    static func configureCallAudioSession(_ session: AVAudioSession) -> Bool {
        do {
            if #available(iOS 10.0, tvOS 10.0, *) {
                try session.setCategory(.playAndRecord, mode: .videoChat,
                                        options: [.defaultToSpeaker, .allowBluetoothHFP])
            } else {
                // The iOS 9 option uses the same bit that newer SDKs renamed allowBluetoothHFP.
                let legacyBluetooth = AVAudioSession.CategoryOptions(rawValue: 1 << 2)
                try session.setCategory(.playAndRecord,
                                        options: [.defaultToSpeaker, legacyBluetooth])
                try session.setMode(.videoChat)
            }
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }
#endif

    static func setCustomSpacing(_ spacing: CGFloat, after view: UIView,
                                 in stack: UIStackView) {
        if #available(iOS 11.0, tvOS 11.0, *) {
            stack.setCustomSpacing(spacing, after: view)
        }
        // iOS 9 keeps the stack's regular spacing. Content remains usable and ordered.
    }

    static func logCore(level: Int32, message: String) {
#if IOS9_COMPAT
        NSLog("[core][%d] %@", level, message)
#else
        let log = OSLog(subsystem: "jp.ox.doorbell", category: "core")
        let type: OSLogType = level >= 3 ? .error : (level >= 2 ? .default : .info)
        os_log("%{public}s", log: log, type: type, message)
#endif
    }

    static func logDebug(_ message: String) {
        logCore(level: 1, message: "[debug] \(message)")
    }

    /// The screen's scale, captured on the main thread and cached. Background work that has to
    /// size a bitmap needs it, and `UIScreen` may only be read from the main thread.
    private static var cachedScreenScale: CGFloat = 0

    static func cacheScreenScale() {
        cachedScreenScale = UIScreen.main.scale
    }

    static func screenScale() -> CGFloat {
        return cachedScreenScale > 0 ? cachedScreenScale : 2
    }

    /// Main-thread cost of one named section, accumulated and reported as a summary rather than a
    /// line per call: on an old panel the logging itself would otherwise be the stall being
    /// measured. Off unless `boot.json` asks for it, so a shipped panel pays nothing.
    struct PerfProbe {
        static var enabled = false
        private static var totals: [String: (calls: Int, seconds: Double)] = [:]
        private static var lastReport = CFAbsoluteTimeGetCurrent()
        private static let reportEverySeconds: Double = 15

        static func measure<T>(_ name: String, _ body: () -> T) -> T {
            guard enabled else { return body() }
            let started = CFAbsoluteTimeGetCurrent()
            let result = body()
            record(name, CFAbsoluteTimeGetCurrent() - started)
            return result
        }

        static func record(_ name: String, _ seconds: Double) {
            guard enabled else { return }
            var entry = totals[name] ?? (calls: 0, seconds: 0)
            entry.calls += 1
            entry.seconds += seconds
            totals[name] = entry
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastReport >= reportEverySeconds else { return }
            lastReport = now
            report()
        }

        static func report() {
            let window = totals.keys.sorted().map { name -> String in
                let entry = totals[name] ?? (calls: 0, seconds: 0)
                let mean = entry.calls > 0 ? entry.seconds / Double(entry.calls) * 1000 : 0
                return String(format: "%@ n=%d mean=%.2fms total=%.1fms", name, entry.calls,
                              mean, entry.seconds * 1000)
            }
            totals = [:]
            guard !window.isEmpty else { return }
            logDebug("perf " + window.joined(separator: " | "))
        }
    }

    static func jsonData(withJSONObject object: Any,
                         prettyPrinted: Bool) throws -> Data {
        var options: JSONSerialization.WritingOptions = prettyPrinted ? [.prettyPrinted] : []
        if #available(iOS 11.0, tvOS 11.0, *) {
            options.insert(.sortedKeys)
        }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

#if os(iOS)
    /// Camera used to read an Add QR. The rear lens is preferred: the user points the device at
    /// the screen of the device being added.
    static func qrScanCaptureDevice() -> AVCaptureDevice? {
#if IOS9_COMPAT
        let devices = AVCaptureDevice.devices(for: .video)
        return devices.first(where: { $0.position == .back }) ?? devices.first
#else
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
#endif
    }

    static func videoCaptureDevice() -> AVCaptureDevice? {
#if IOS9_COMPAT
        let devices = AVCaptureDevice.devices(for: .video)
        return devices.first(where: { $0.position == .front }) ?? devices.first
#else
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
#endif
    }
#endif
}

private final class LegacyTimerInvocation: NSObject {
    let block: (Timer) -> Void

    init(block: @escaping (Timer) -> Void) {
        self.block = block
    }
}

private final class LegacyTimerDispatcher: NSObject {
    @objc func invoke(_ timer: Timer) {
        (timer.userInfo as? LegacyTimerInvocation)?.block(timer)
    }
}

/// The panel's screen must never sleep, and the override that keeps it awake has to be re-asserted
/// rather than set once.
///
/// When the device auto-locks, iOS suspends the foreground app. A suspended node's listening
/// sockets are closed, so 47180 and 47172 start *refusing* connections rather than stalling, the
/// cluster stops hearing from it, and the process is evicted later — with no crash report, no
/// jetsam event and nothing in syslog, because nothing went wrong from the OS's point of view.
/// That is indistinguishable from a hang unless you know to look for it.
///
/// `isIdleTimerDisabled` was previously set exactly once, in `didFinishLaunchingWithOptions`,
/// before the window was ever key. Several screens clear it and put it back only on one of the
/// ways out of them — the iOS 9 admin alert restores it from its OK button, so dismissing that
/// alert through either of its other two actions left the panel able to lock, permanently. This
/// holds the shell's intent instead, so it can be re-applied whenever the app becomes active.
enum ScreenAwake {

    /// What the shell wants. Only an administrator deliberately leaving kiosk mode sets it false.
    private(set) static var wanted = true

    static func want(_ awake: Bool) {
        wanted = awake
        apply()
    }

    /// Puts the override back the way the shell wants it. Cheap and idempotent, so it is safe to
    /// call on every activation and from anything that might have cleared it.
    static func apply() {
        UIApplication.shared.isIdleTimerDisabled = wanted
    }
}

/// A small persistent record of the shell's own life, written to `<dataDir>/shell.log` so that a
/// death that leaves nothing behind — no crash, no jetsam, no resource report — can still be
/// explained afterwards from the device. It records the launch, Core starting and stopping, every
/// lifecycle transition, and the most recent UI events.
///
/// Off unless `boot.json` carries `"debug_timings": true`, so a shipped panel writes nothing.
/// Lifecycle lines are flushed immediately, because those are the ones that matter when the app
/// is about to be suspended; UI events are buffered and flushed at most once a second, because
/// Core announces `peers_changed` several times a second and this must not become its own load.
enum ShellLog {

    static var enabled = false

    /// How many UI-event lines are kept. Older ones fall off the front.
    private static let uiEventLimit = 50
    /// The file is trimmed to its last lines once it passes this, so it cannot grow without end.
    private static let maxBytes = 64 * 1024
    private static let keepLines = 400
    private static let minFlushIntervalS: TimeInterval = 1

    private static let queue = DispatchQueue(label: "jp.ox.doorbell.shell-log")
    private static var path = ""
    private static var pending: [String] = []
    private static var uiEvents: [String] = []
    private static var lastFlush: TimeInterval = 0

    static func start(dataDir: String, note: String) {
        guard enabled, !dataDir.isEmpty else { return }
        queue.async {
            path = (dataDir as NSString).appendingPathComponent("shell.log")
            pending.append(stamp("=== launch " + note))
            writeOut()
        }
    }

    /// A line that must survive the next suspension: the launch, Core starting or stopping, a
    /// lifecycle transition. Written through to the file at once.
    static func note(_ line: String) {
        guard enabled else { return }
        queue.async {
            pending.append(stamp(line))
            writeOut()
        }
    }

    /// One UI event from Core. Kept to the last `uiEventLimit` and flushed at most once a second.
    static func uiEvent(_ kind: String, detail: String = "") {
        guard enabled else { return }
        let line = stamp("ui " + kind + (detail.isEmpty ? "" : " " + detail))
        queue.async {
            uiEvents.append(line)
            if uiEvents.count > uiEventLimit { uiEvents.removeFirst(uiEvents.count - uiEventLimit) }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastFlush >= minFlushIntervalS else { return }
            flushUiEvents(now)
        }
    }

    /// Empties the UI-event buffer into the file. Called on the way into a lifecycle transition so
    /// that what the app was doing before it went away is on disk.
    static func flush() {
        guard enabled else { return }
        queue.async { flushUiEvents(ProcessInfo.processInfo.systemUptime) }
    }

    // MARK: - On the log's own queue

    private static func flushUiEvents(_ now: TimeInterval) {
        guard !uiEvents.isEmpty else { return }
        lastFlush = now
        pending.append(contentsOf: uiEvents)
        uiEvents.removeAll()
        writeOut()
    }

    private static func stamp(_ line: String) -> String {
        let uptime = ProcessInfo.processInfo.systemUptime
        return String(format: "%@ +%.1f %@", isoNow(), uptime, line)
    }

    /// The OS clock, not Core's: this file exists to be read next to `idevicesyslog` and the
    /// device's own crash reports, which are all stamped the same way.
    private static func isoNow() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    private static func writeOut() {
        guard !path.isEmpty, !pending.isEmpty else { return }
        let blob = pending.joined(separator: "\n") + "\n"
        pending.removeAll()
        let url = URL(fileURLWithPath: path)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(blob.utf8))
            handle.closeFile()
        } else {
            try? blob.write(to: url, atomically: true, encoding: .utf8)
        }
        trimIfLarge(url)
    }

    private static func trimIfLarge(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        guard let bytes = size?.intValue, bytes > maxBytes,
              let whole = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = whole.components(separatedBy: "\n")
        guard lines.count > keepLines else { return }
        lines.removeFirst(lines.count - keepLines)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Camera and microphone permission, and what the cluster is told about them.
///
/// A door station that never asks is a door station with no picture: `authorizationStatus` starts
/// at `notDetermined` and stays there until something calls `requestAccess`, and a capability
/// document published before that says the camera is unavailable. Since an indoor panel now hides
/// the tile of a door with `caps.camera` false, "we never asked" and "there is no camera" look
/// identical from the other side of the mesh. So the ask happens at launch, before the first
/// capability document goes out, and what came back is written down.
enum AvPermissions {

    static let settled = Notification.Name("DoorbellAvPermissionsSettled")

    /// The contract's spelling of one permission. `not_determined` is reported honestly: it is
    /// not a refusal, and calling it one loses the difference between a resident who said no and
    /// a prompt nobody has answered yet.
    ///
    /// tvOS has no capture device to ask about before tvOS 17, and the TV shell is never a door
    /// station, so there the answer is that the question does not apply.
    static func state(_ mediaType: AVMediaType) -> String {
#if os(tvOS)
        return "not_applicable"
#else
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "not_determined"
        }
#endif
    }

    /// Whether `caps.camera` may be true. A camera is offered only by a door station, only once
    /// the resident has allowed it, and only while capture is actually running — a permission on
    /// its own is a promise the mesh cannot rely on.
    static func cameraOffered(role: String, permission: String, runtime: String) -> Bool {
        return role == "door_station" && permission == "authorized" && runtime == "active"
    }

    /// Whether the screen should say so. Only a real refusal earns a banner; a prompt that has
    /// not been answered is about to be.
    static func shouldWarn(role: String, permission: String) -> Bool {
        return role == "door_station" && (permission == "denied" || permission == "restricted")
    }

    /// Asks for everything this role needs, before the first capability document is published.
    /// `completion` runs on the main thread each time an answer arrives, so the capabilities can
    /// be republished and capture started the moment the resident allows it.
    static func requestAtLaunch(role: String, completion: @escaping () -> Void) {
        ShellLog.note("permissions at launch camera=\(state(.video)) mic=\(state(.audio))")
        let settle = {
            DispatchQueue.main.async {
                ShellLog.note("permissions settled camera=\(state(.video)) mic=\(state(.audio))")
                completion()
                NotificationCenter.default.post(name: settled, object: nil)
            }
        }
#if os(tvOS)
        settle()
#else
        if role == "door_station" {
            AVCaptureDevice.requestAccess(for: .video) { _ in settle() }
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in settle() }
#endif
    }
}
