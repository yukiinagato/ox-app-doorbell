import AVFoundation
import ImageIO
import Foundation
import UIKit

/// Publishes measured capabilities and bounded crash-loop state to Core.
/// Stock Apple platforms cannot relaunch themselves; supervised Single App Mode/MDM is the
/// external recovery boundary and is reported honestly in the runtime manifest.
final class RuntimeSupervisor {
    private enum Key {
        static let generation = "runtime.generation"
        static let cleanExit = "runtime.clean_exit"
        static let launches = "runtime.unexpected_launches"
        static let safeMode = "runtime.safe_mode"
        static let lastReason = "runtime.last_exit_reason"
    }

    private let core: CoreBridge
    private let boot: BootConfig
    private var audioSessionReady: Bool
    private let defaults = UserDefaults.standard
    private var heartbeat: Timer?
    private var mainHeartbeat: Timer?
    private var uiStyleObserver: NSObjectProtocol?
    private var deviceInfoObservers: [NSObjectProtocol] = []
    private var generation = 0
    private var unexpectedLaunches: [TimeInterval] = []
    private var deviceAlertReport: [String: Any] = [
        "schema_version": 1,
        "result": "not_requested",
        "channels": [],
    ]
    private var cameraRuntimeState = "not_started"
    private var h264EncodeState = "not_tested"
    private var mainThreadHeartbeat = ProcessInfo.processInfo.systemUptime
    #if os(iOS)
    private var keepalive: KeepaliveClient?
    private var nativeKioskActive = false
    private var helperSupervising = false
    private var helperPolicy = "off"
    private lazy var hangMarkerPath = (BootConfig.dataDir() as NSString)
        .appendingPathComponent("runtime-hang.marker")
    private lazy var hangSentinel = MainRunLoopHangSentinel(markerPath: hangMarkerPath)
    #endif
    // The modern shell currently renders bounded MJPEG. Do not infer H.264 decode support from
    // VideoToolbox being present until an integrated decoder has completed a real frame test.
    private let h264DecodeState = "unsupported_no_decoder_path"

    private(set) var safeMode = false

    private var supportsUiManifest: Bool {
        boot.role == "door_station" || boot.role == "indoor_panel"
    }

    private var supportsCallLifecycle: Bool {
        #if os(tvOS)
        return false
        #else
        return core.sipBackend == "pjsip"
        #endif
    }

    init(core: CoreBridge, boot: BootConfig, audioSessionReady: Bool = false) {
        self.core = core
        self.boot = boot
        self.audioSessionReady = audioSessionReady
        #if os(iOS)
        self.helperPolicy = boot.keepaliveHelperPolicy
        #endif
    }

    func start() {
        guard heartbeat == nil else {
            refreshHelperPolicy()
            noteMainThreadResponsive()
            publishCapabilities()
            publishRuntime()
            return
        }
        let now = Date().timeIntervalSince1970
        generation = defaults.integer(forKey: Key.generation) + 1
        defaults.set(generation, forKey: Key.generation)

        unexpectedLaunches = (defaults.array(forKey: Key.launches) as? [Double] ?? [])
            .filter { now - $0 < 300 }
        if defaults.object(forKey: Key.cleanExit) != nil && !defaults.bool(forKey: Key.cleanExit) {
            unexpectedLaunches.append(now)
            defaults.set("unexpected_termination", forKey: Key.lastReason)
        }
        safeMode = defaults.bool(forKey: Key.safeMode) || unexpectedLaunches.count >= 3
        defaults.set(unexpectedLaunches, forKey: Key.launches)
        defaults.set(safeMode, forKey: Key.safeMode)
        defaults.set(false, forKey: Key.cleanExit)
        #if os(iOS)
        if MainRunLoopHangSentinel.consumeMarker(at: hangMarkerPath) {
            defaults.set("main_run_loop_stall_3x5s", forKey: Key.lastReason)
        }
        #endif
        noteMainThreadResponsive()

        #if os(iOS)
        refreshNativeKioskMeasurement()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshNativeKioskMeasurement()
        }
        hangSentinel.start()
        updateExternalSupervisorSnapshot()
        if UIApplication.shared.applicationState != .background {
            hangSentinel.armAfterForegroundGrace()
        }
        configureKeepaliveFallback()
        #endif

        beginDeviceInfoUpdates()
        publishCapabilities()
        if supportsUiManifest { publishUiManifest() }
        publishRuntime()
        uiStyleObserver = NotificationCenter.default.addObserver(
            forName: UIStyleApplier.reportChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.publishRuntime() }
        heartbeat = IOSAvailability.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.noteMainThreadResponsive()
            #if os(iOS)
            self?.refreshNativeKioskMeasurement()
            #endif
            self?.core.refreshDeviceInfoCache()
            self?.publishCapabilities()
            self?.publishRuntime()
        }
        mainHeartbeat = IOSAvailability.scheduledTimer(withTimeInterval: 3, repeats: true) {
            [weak self] _ in self?.noteMainThreadResponsive()
        }
    }

    func stop(clean: Bool) {
        heartbeat?.invalidate()
        heartbeat = nil
        mainHeartbeat?.invalidate()
        mainHeartbeat = nil
        #if os(iOS)
        keepalive?.stop()
        keepalive = nil
        helperSupervising = false
        updateExternalSupervisorSnapshot()
        hangSentinel.disarmForBackground()
        hangSentinel.stop()
        #endif
        endDeviceInfoUpdates()
        if let observer = uiStyleObserver { NotificationCenter.default.removeObserver(observer) }
        uiStyleObserver = nil
        if clean {
            defaults.set(true, forKey: Key.cleanExit)
            defaults.set("clean_exit", forKey: Key.lastReason)
        }
        publishRuntime()
    }

    private func beginDeviceInfoUpdates() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.beginDeviceInfoUpdates() }
            return
        }
        guard deviceInfoObservers.isEmpty else { return }
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        core.refreshDeviceInfoCache()

        let center = NotificationCenter.default
        #if os(iOS)
        let active = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.noteMainThreadResponsive()
            self?.hangSentinel.armAfterForegroundGrace()
            self?.refreshNativeKioskMeasurement()
            self?.core.refreshDeviceInfoCache()
        }
        deviceInfoObservers.append(active)
        let guidedAccess = center.addObserver(
            forName: UIAccessibility.guidedAccessStatusDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshNativeKioskMeasurement() }
        deviceInfoObservers.append(guidedAccess)
        let background = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hangSentinel.disarmForBackground() }
        deviceInfoObservers.append(background)
        let foreground = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hangSentinel.armAfterForegroundGrace() }
        deviceInfoObservers.append(foreground)
        for name in [UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.core.refreshDeviceInfoCache()
            }
            deviceInfoObservers.append(observer)
        }
        #endif
    }

    private func endDeviceInfoUpdates() {
        let center = NotificationCenter.default
        for observer in deviceInfoObservers { center.removeObserver(observer) }
        deviceInfoObservers.removeAll()
    }

    func handleMemoryPressure() {
        noteMainThreadResponsive()
        #if os(iOS)
        keepalive?.noteMemoryPressure()
        #endif
        safeMode = true
        defaults.set(true, forKey: Key.safeMode)
        defaults.set("memory_pressure", forKey: Key.lastReason)
        publishRuntime()
        publishCapabilities()
    }

    func clearSafeModeAfterMaintenance() {
        safeMode = false
        unexpectedLaunches.removeAll()
        defaults.set(false, forKey: Key.safeMode)
        defaults.set([], forKey: Key.launches)
        defaults.set("maintenance_reset", forKey: Key.lastReason)
        publishCapabilities()
        publishRuntime()
    }

    func recordDeviceAlert(_ report: [String: Any]) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.recordDeviceAlert(report) }
            return
        }
        deviceAlertReport = report
        publishRuntime()
    }

    func permissionsDidChange() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.permissionsDidChange() }
            return
        }
        publishCapabilities()
        publishRuntime()
    }

    func updateAudioSessionReady(_ value: Bool) {
        audioSessionReady = value
        refreshHelperPolicy()
        publishCapabilities()
        publishRuntime()
    }

    func configDidChange() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.configDidChange() }
            return
        }
        refreshHelperPolicy()
        publishCapabilities()
        publishRuntime()
    }

    private func noteMainThreadResponsive() {
        guard Thread.isMainThread else { return }
        mainThreadHeartbeat = ProcessInfo.processInfo.systemUptime
    }

    private func uiComponentState() -> String {
        return ProcessInfo.processInfo.systemUptime - mainThreadHeartbeat < 12 ? "responsive" : "stalled"
    }

    #if os(iOS)
    private func refreshNativeKioskMeasurement() {
        guard Thread.isMainThread else { return }
        let measured = UIAccessibility.isGuidedAccessEnabled
        guard measured != nativeKioskActive else { return }
        nativeKioskActive = measured
        updateExternalSupervisorSnapshot()
        configureKeepaliveFallback()
    }

    private func updateExternalSupervisorSnapshot() {
        hangSentinel.setExternalSupervisorActive(nativeKioskActive || helperSupervising)
    }

    private func refreshHelperPolicy() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshHelperPolicy() }
            return
        }
        var resolved = boot.keepaliveHelperPolicy
        if core.isRunning, let status = core.status(),
           let selfNode = status["self"] as? [String: Any],
           let id = selfNode["id"] as? String, !id.isEmpty,
           let value = ConfigUtil.str(core.config(), "devices.\(id).local.recovery.helper_mode"),
           value == "off" || value == "auto" || value == "on" {
            resolved = value
        }
        guard resolved != helperPolicy else {
            configureKeepaliveFallback()
            return
        }
        helperPolicy = resolved
        helperSupervising = false
        updateExternalSupervisorSnapshot()
        configureKeepaliveFallback()
    }

    private func configureKeepaliveFallback() {
        if let keepalive = keepalive {
            keepalive.reconfigure(policy: helperPolicy, nativeKioskActive: nativeKioskActive)
            return
        }
        let client = KeepaliveClient(policy: helperPolicy, role: boot.role,
                                     nativeKioskActive: nativeKioskActive) { [weak self] in
            self?.keepaliveState() ?? "unknown"
        }
        client.statusChanged = { [weak self] in
            guard let self = self else { return }
            self.helperSupervising = self.keepalive?.supervising ?? false
            self.updateExternalSupervisorSnapshot()
            self.publishCapabilities()
            self.publishRuntime()
        }
        keepalive = client
        client.start()
    }

    private func keepaliveState() -> String {
        return "ui_\(uiComponentState())_core_\(core.isRunning ? "running" : "stopped")"
    }
    #endif

    func recordCameraRuntime(active: Bool, state: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.recordCameraRuntime(active: active, state: state)
            }
            return
        }
        cameraRuntimeState = active ? "active" : measuredState(state, fallback: "unavailable")
        publishCapabilities()
        publishRuntime()
    }

    func recordH264Encode(available: Bool, state: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.recordH264Encode(available: available, state: state)
            }
            return
        }
        h264EncodeState = available ? "verified" : measuredState(state, fallback: "failed")
        publishCapabilities()
        publishRuntime()
    }

    private func measuredState(_ value: String, fallback: String) -> String {
        let allowed = Set(["not_started", "starting", "permission_denied", "restricted",
                           "no_device", "input_failed", "configuration_failed",
                           "runtime_failed", "stopped", "testing", "session_failed",
                           "encode_failed", "invalid_output", "failed",
                           "unsupported_no_decoder_path"])
        return allowed.contains(value) ? value : fallback
    }

    #if os(iOS)
    private func permissionState(_ mediaType: AVMediaType) -> String {
        return AvPermissions.state(mediaType)
    }
    #endif

    private func publishCapabilities() {
        #if os(tvOS)
        let camera = false
        let microphone = false
        let cameraPermission = "not_applicable"
        let microphonePermission = "not_applicable"
        let mains = true
        let nativeKiosk = false
        let cpuScore = 70
        let alertChannels = ["in_app"]
        #else
        UIDevice.current.isBatteryMonitoringEnabled = true
        let cameraPermission = permissionState(.video)
        let microphonePermission = permissionState(.audio)
        let camera = AvPermissions.cameraOffered(role: boot.role, permission: cameraPermission,
                                                 runtime: cameraRuntimeState)
        let microphone = microphonePermission == "authorized" && audioSessionReady &&
            !(AVAudioSession.sharedInstance().availableInputs?.isEmpty ?? true)
        let mains = UIDevice.current.batteryState == .charging ||
            UIDevice.current.batteryState == .full
        let nativeKiosk = nativeKioskActive
        let cpuScore = 60
        let alertChannels = ["in_app", "system_notification"]
        #endif
        let h264Encode = camera && h264EncodeState == "verified" && !safeMode
        core.setCapabilities([
            "schema_version": 2,
            "platform": {
                #if os(tvOS)
                return "tvos"
                #else
                return "ios"
                #endif
            }(),
            "tls12": true,
            // Internet reachability is not inferred from a LAN route. Administrators may opt in
            // through the operational caps override until a configured endpoint probe succeeds.
            "wan": false,
            "mains_power": mains,
            "mqtt_reachable": false,
            "wall_clock_sane": Date().timeIntervalSince1970 > 1_700_000_000,
            "cpu_score": cpuScore,
            "camera": camera,
            "microphone": microphone,
            "camera_permission": cameraPermission,
            "microphone_permission": microphonePermission,
            "h264_encode": h264Encode,
            "h264_decode": false,
            "sip_backend": core.sipBackend,
            "sip": core.sipBackend == "pjsip",
            "native_kiosk": nativeKiosk,
            "root_helper": {
                #if os(iOS)
                return keepalive?.available ?? false
                #else
                return false
                #endif
            }(),
            "device_alert_channels": alertChannels,
            "features": [
                "platform_v2": true,
                "call_flow_v2": true,
                "call_cancel_v2": true,
                "call_lifecycle_v2": supportsCallLifecycle,
                "device_alert_v1": true,
                "ui_manifest_v1": supportsUiManifest,
                "runtime_recovery_v1": true,
                "helper_policy_v1": {
                    #if os(iOS)
                    return helperPolicy != "off"
                    #else
                    return false
                    #endif
                }(),
            ],
        ])
    }

    private func publishUiManifest() {
        #if os(tvOS)
        let ids = ["sos.cancel", "ring.title", "ring.action", "reply.button",
                   "call.end", "monitor.close"]
        let minimumTouch = 44
        #else
        let ids = ["call.primary", "cancel.call", "call.end", "purpose.button",
                   "sos.trigger", "sos.cancel", "ring.title", "ring.action",
                   "reply.button", "monitor.close", "status.offline"]
        let minimumTouch = 44
        #endif
        let safety = Set(["cancel.call", "call.end", "sos.trigger", "sos.cancel"])
        var elements: [String: Any] = [:]
        for id in ids {
            elements[id] = [
                "properties": ["scale", "font_scale", "foreground", "background",
                               "accent", "border", "radius"],
                "safety_critical": safety.contains(id),
                "defaults": uiDefaults(for: id),
            ]
        }
        core.setUiManifest([
            "schema_version": 1,
            "units": "pt",
            "viewport": ["minimum_touch": minimumTouch, "scale_min": 0.75,
                         "scale_max": 2.0],
            "elements": elements,
        ])
    }

    private func uiDefaults(for semanticId: String) -> [String: Any] {
        var foreground = "#E8EDF2"
        var background = "#1A2027"
        var accent = "#4DA3FF"
        var border = "#4DA3FF"
        var radius = 12
        switch semanticId {
        case "call.primary":
            foreground = "#000000"
            background = "#FFCC40"
            accent = "#000000"
            border = "#000000"
            radius = 18
        case "call.end", "sos.trigger":
            foreground = "#FFFFFF"
            background = "#C7291F"
            accent = "#FFFFFF"
            border = "#FFFFFF"
            radius = 14
        case "sos.cancel":
            foreground = "#8C0D0A"
            background = "#FFFFFF"
            accent = "#8C0D0A"
            border = "#8C0D0A"
            radius = 14
        case "ring.title":
            foreground = "#FFFFFF"
            background = "#0A0D12"
        case "status.offline":
            foreground = "#FFFFFF"
            background = "#A21B00"
            accent = "#FFFFFF"
            border = "#FFFFFF"
        default:
            break
        }
        return [
            "scale": 1.0,
            "font_scale": 1.0,
            "foreground": foreground,
            "background": background,
            "accent": accent,
            "border": border,
            "radius": radius,
        ]
    }

    private func publishRuntime() {
        #if os(tvOS)
        let cameraPermission = "not_applicable"
        let microphonePermission = "not_applicable"
        let audioInputAvailable = false
        #else
        let cameraPermission = permissionState(.video)
        let microphonePermission = permissionState(.audio)
        let audioInputAvailable = !(AVAudioSession.sharedInstance().availableInputs?.isEmpty ?? true)
        #endif
        let codecHealth: String
        if safeMode {
            codecHealth = "safe_mode_low_resolution_mjpeg"
        } else if h264EncodeState == "verified" {
            codecHealth = "h264_encode_verified_mjpeg_decode"
        } else if h264EncodeState == "encode_failed" ||
                    h264EncodeState == "invalid_output" || h264EncodeState == "session_failed" ||
                    h264EncodeState == "failed" {
            codecHealth = "h264_encode_failed_mjpeg_fallback"
        } else {
            codecHealth = "h264_unverified_mjpeg_fallback"
        }
        core.setRuntimeStatus([
            "schema_version": 1,
            "generation": generation,
            "heartbeat_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "last_exit_reason": defaults.string(forKey: Key.lastReason) ?? "first_launch",
            "safe_mode": safeMode,
            "crash_count_5m": unexpectedLaunches.count,
            "codec_health": codecHealth,
            "helper_mode": {
                #if os(iOS)
                if helperPolicy == "off" { return "off" }
                // This field is the helper's effective protocol mode and remains within the
                // off/auto/on contract. Native kiosk ownership is reported separately below.
                return keepalive?.mode ?? "unavailable"
                #else
                return "off"
                #endif
            }(),
            "helper_available": {
                #if os(iOS)
                return keepalive?.available ?? false
                #else
                return false
                #endif
            }(),
            "native_kiosk": {
                #if os(iOS)
                return nativeKioskActive ? "guided_access_active" : "not_active"
                #else
                return "not_applicable"
                #endif
            }(),
            "native_kiosk_measurement": {
                #if os(iOS)
                return ["guided_access": nativeKioskActive]
                #else
                return ["guided_access": false]
                #endif
            }(),
            "active_call_recovery": "fail_closed_cancel_unless_dialog_restored",
            "device_alert": deviceAlertReport,
            "ui_style": UIStyleApplier.runtimeReport(),
            "camera": [
                "state": cameraRuntimeState,
                "permission": cameraPermission,
            ],
            "avc_encode": [
                "state": safeMode ? "disabled_safe_mode" : h264EncodeState,
                "codec": "h264",
            ],
            "avc_decode": [
                "state": safeMode ? "disabled_safe_mode" : h264DecodeState,
                "codec": "h264",
            ],
            "sip": [
                "state": audioSessionReady && audioInputAvailable
                    ? "audio_input_active" : "audio_input_unavailable",
                "permission": microphonePermission,
            ],
            "components": [
                "core": core.isRunning ? "running" : "stopped",
                "sip": core.sipBackend == "pjsip" ? "available" : "stub",
                "media": safeMode ? "degraded" : "available",
                "ui": uiComponentState(),
            ],
        ])
    }
}

/// Remote screenshot hook, for verifying a panel that has no capture tool of its own.
///
/// A jailbroken iPad mini 3 has no screencap binary and the Mac has no developer image for it, so
/// the only way to see what the app is actually drawing is to have the app draw it into a file.
/// Dropping `screenshot.request` next to `boot.json` produces `screenshot.png` beside it; the
/// request file is removed so the next one is unambiguous. The kiosk shell answers the same
/// contract, so one script drives both.
///
/// Nothing here runs unless `boot.json` carries `"debug_screenshots": true`: the timer is never
/// scheduled, so a shipped panel does not touch the file system for this at all.
final class ScreenshotResponder {

    private let requestPath: String
    private let imagePath: String
    private var timer: Timer?

    init(dataDir: String) {
        let dir = dataDir as NSString
        requestPath = dir.appendingPathComponent("screenshot.request")
        imagePath = dir.appendingPathComponent("screenshot.png")
    }

    deinit { stop() }

    func start() {
        guard timer == nil else { return }
        timer = IOSAvailability.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard FileManager.default.fileExists(atPath: requestPath) else { return }
        let body = (try? String(contentsOfFile: requestPath, encoding: .utf8)) ?? ""
        // The request is consumed first: a capture that fails must not leave the file behind for
        // this to spin on once a second.
        try? FileManager.default.removeItem(atPath: requestPath)

        // A panel left alone goes to its screensaver, and from then on every capture is a black
        // screen with a clock on it. `wake` asks for what a finger would have done, idle timer
        // included; an empty request captures whatever is actually on screen.
        guard body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "wake" else {
            capture()
            return
        }
        NotificationCenter.default.post(name: .doorbellWakeScreen, object: nil)
        // One turn of the run loop, so the screen the capture renders is the woken one.
        DispatchQueue.main.async { [weak self] in self?.capture() }
    }

    private func capture() {
        guard let window = ScreenshotResponder.keyWindow(),
              let png = ScreenshotResponder.render(window) else {
            IOSAvailability.logDebug("screenshot: no key window to capture")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: imagePath), options: .atomic)
            IOSAvailability.logDebug("screenshot: wrote \(png.count) bytes to \(imagePath)")
        } catch {
            IOSAvailability.logDebug("screenshot: could not write \(imagePath)")
        }
    }

    private static func keyWindow() -> UIWindow? {
        if let key = UIApplication.shared.keyWindow { return key }
        return UIApplication.shared.windows.first { !$0.isHidden }
    }

    /// `drawHierarchy` is what captures a live view tree, including anything drawn by the render
    /// server; `layer.render(in:)` misses visual effects and some media layers.
    private static func render(_ window: UIWindow) -> Data? {
        let bounds = window.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        if #available(iOS 10.0, tvOS 10.0, *) {
            let renderer = UIGraphicsImageRenderer(bounds: bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            return image.pngData()
        }
        UIGraphicsBeginImageContextWithOptions(bounds.size, false, 0)
        defer { UIGraphicsEndImageContext() }
        window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        guard let image = UIGraphicsGetImageFromCurrentImageContext(),
              let cg = image.cgImage else { return nil }
        // The modern spelling is unavailable before iOS 10, and the free function it replaced is
        // gone from the current SDK; ImageIO encodes the same PNG on both runtimes.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
