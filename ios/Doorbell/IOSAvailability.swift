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
