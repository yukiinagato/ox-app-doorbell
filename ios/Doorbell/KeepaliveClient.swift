import Foundation

#if os(iOS)
import Darwin

/// Main-run-loop client for the optional fixed-purpose root supervisor. It persists the configured
/// mode, while a renewable maintenance lease suspends `auto` supervision under native kiosk.
final class KeepaliveClient {
    private static let socketPath = "/var/run/doorbell-keepalive.sock"
    private static let interval: TimeInterval = 3
    private static let statusEvery = 5
    private static let nativeKioskLeaseSeconds = 15

    private var policy: String
    private var nativeKioskActive: Bool
    private let role: String
    private let stateProvider: () -> String
    private let statusQueue = DispatchQueue(label: "jp.ox.doorbell.keepalive-status", qos: .utility)
    private var socket: Int32 = -1
    private var timer: Timer?
    private var sequence: UInt64 = 0
    private var controlSequence: UInt64 = 0
    private var memoryWarnings: UInt64 = 0
    private var heartbeatCount = 0
    private var controlGeneration: UInt64 = 0
    private var modeAcknowledged = false
    private var started = false

    private(set) var available = false
    private(set) var mode = "unavailable"
    private(set) var supervising = false
    var statusChanged: (() -> Void)?

    init(policy: String, role: String, nativeKioskActive: Bool,
         stateProvider: @escaping () -> String) {
        self.policy = KeepaliveClient.validPolicy(policy) ? policy : "off"
        self.nativeKioskActive = nativeKioskActive
        self.role = String(role.prefix(80))
        self.stateProvider = stateProvider
    }

    deinit { stop() }

    func start() {
        guard !started else { return }
        started = true
        configureTimer()
        applyConfiguration()
        if policy != "off" { send(event: "started") }
    }

    func reconfigure(policy: String, nativeKioskActive: Bool) {
        let normalized = KeepaliveClient.validPolicy(policy) ? policy : "off"
        guard normalized != self.policy || nativeKioskActive != self.nativeKioskActive else { return }
        let releasePreviousLease = self.policy == "auto" && self.nativeKioskActive &&
            !(normalized == "auto" && nativeKioskActive)
        self.policy = normalized
        self.nativeKioskActive = nativeKioskActive
        controlGeneration &+= 1
        modeAcknowledged = false
        configureTimer()
        if started { applyConfiguration(releasePreviousLease: releasePreviousLease) }
    }

    func stop() {
        guard started else { return }
        let previousPolicy = policy
        let previousNativeKiosk = nativeKioskActive
        controlGeneration &+= 1
        started = false
        timer?.invalidate()
        timer = nil
        if previousPolicy != "off" { send(event: "stopping") }
        if previousPolicy == "auto" && previousNativeKiosk {
            // Retain the client until the fixed lease-release command is sent. RuntimeSupervisor
            // drops its reference immediately after stop, so a weak capture can silently leave the
            // helper paused until lease expiry.
            statusQueue.async { _ = self.control("MAINTENANCE_END") }
        }
        if socket >= 0 { close(socket) }
        socket = -1
        modeAcknowledged = false
        updateStatus(available: false, mode: "unavailable", supervising: false)
    }

    func noteMemoryPressure() {
        memoryWarnings &+= 1
        if policy != "off" { send(event: "memory_pressure") }
        refreshStatus()
    }

    private func configureTimer() {
        if policy == "off" {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = IOSAvailability.scheduledTimer(withTimeInterval: KeepaliveClient.interval,
                                                    repeats: true) { [weak self] _ in
                self?.heartbeat()
            }
        }
    }

    private func heartbeat() {
        if policy != "off" { send(event: "heartbeat") }
        heartbeatCount += 1
        if policy == "auto" && nativeKioskActive {
            renewNativeKioskLease()
        } else if heartbeatCount % KeepaliveClient.statusEvery == 0 {
            refreshStatus()
        }
    }

    private func applyConfiguration(releasePreviousLease: Bool = false) {
        let requestedMode = policy
        let nativeKiosk = nativeKioskActive
        let generation = controlGeneration
        statusQueue.async { [weak self] in
            guard let self = self else { return }
            if releasePreviousLease { _ = self.control("MAINTENANCE_END") }
            let modeReply = self.control("MODE \(requestedMode)")
            var acknowledged = modeReply?["ok"] as? Bool == true
            if acknowledged && requestedMode == "auto" {
                let command = nativeKiosk
                    ? "MAINTENANCE_BEGIN \(KeepaliveClient.nativeKioskLeaseSeconds)"
                    : "MAINTENANCE_END"
                acknowledged = self.control(command)?["ok"] as? Bool == true
            }
            let status = acknowledged ? self.control("STATUS") : nil
            let helperMode = status?["mode"] as? String
            let armed = status?["armed"] as? Bool ?? false
            let available = modeReply?["ok"] as? Bool == true &&
                helperMode == requestedMode && KeepaliveClient.validPolicy(helperMode ?? "")
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.started, self.controlGeneration == generation else { return }
                self.modeAcknowledged = acknowledged && available
                self.updateStatus(available: available,
                                  mode: available ? helperMode! : "unavailable",
                                  supervising: available && armed && !nativeKiosk)
            }
        }
    }

    private func renewNativeKioskLease() {
        guard modeAcknowledged else { return }
        let generation = controlGeneration
        statusQueue.async { [weak self] in
            guard let self = self else { return }
            let reply = self.control("MAINTENANCE_BEGIN \(KeepaliveClient.nativeKioskLeaseSeconds)")
            let acknowledged = reply?["ok"] as? Bool == true
            let status = acknowledged ? self.control("STATUS") : nil
            let helperMode = status?["mode"] as? String
            let available = acknowledged && helperMode == "auto"
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.started, self.controlGeneration == generation else { return }
                self.modeAcknowledged = available
                self.updateStatus(available: available,
                                  mode: available ? helperMode! : "unavailable",
                                  supervising: false)
            }
        }
    }

    private func refreshStatus() {
        let requestedMode = policy
        let nativeKiosk = nativeKioskActive
        let generation = controlGeneration
        statusQueue.async { [weak self] in
            guard let self = self else { return }
            let status = self.control("STATUS")
            let helperMode = status?["mode"] as? String
            let armed = status?["armed"] as? Bool ?? false
            let available = helperMode == requestedMode && KeepaliveClient.validPolicy(helperMode ?? "")
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.started, self.controlGeneration == generation else { return }
                self.updateStatus(available: self.modeAcknowledged && available,
                                  mode: self.modeAcknowledged && available ? helperMode! : "unavailable",
                                  supervising: self.modeAcknowledged && available && armed && !nativeKiosk)
            }
        }
    }

    private func send(event: String) {
        guard policy != "off", let payload = payload(event: event) else { return }
        if socket < 0 { socket = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0) }
        guard socket >= 0, let address = unixAddress(KeepaliveClient.socketPath) else { return }
        let sent = payload.withUnsafeBytes { bytes -> ssize_t in
            withUnsafePointer(to: address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(socket, bytes.baseAddress, payload.count, 0, $0,
                                  socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        if sent != ssize_t(payload.count) {
            modeAcknowledged = false
            updateStatus(available: false, mode: "unavailable", supervising: false)
        }
    }

    private func payload(event: String) -> Data? {
        sequence &+= 1
        let bundle = Bundle.main
        let state = String(stateProvider().prefix(120))
        let message: [String: Any] = [
            "protocol": 1, "event": event, "pid": Int(getpid()),
            "bundle_id": bundle.bundleIdentifier ?? "jp.ox.doorbell",
            "app_version": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "role": role.isEmpty ? "unknown" : role, "policy": policy,
            "state": state.isEmpty ? "unknown" : state, "sequence": sequence,
            "memory_warnings": memoryWarnings, "unix_time": Date().timeIntervalSince1970,
        ]
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message), data.count <= 2_048
        else { return nil }
        return data
    }

    private func updateStatus(available: Bool, mode: String, supervising: Bool) {
        guard self.available != available || self.mode != mode || self.supervising != supervising else { return }
        self.available = available
        self.mode = mode
        self.supervising = supervising
        statusChanged?()
    }

    private func control(_ command: String) -> [String: Any]? {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        controlSequence &+= 1
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "dbka-\(getpid())-\(controlSequence).sock")
        unlink(path)
        defer { unlink(path) }
        guard let local = unixAddress(path), let helper = unixAddress(KeepaliveClient.socketPath) else { return nil }
        var mutableLocal = local
        let bound = withUnsafePointer(to: &mutableLocal) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { return nil }
        _ = chmod(path, S_IRUSR | S_IWUSR)
        let commandData = Data(command.utf8)
        let sent = commandData.withUnsafeBytes { bytes -> ssize_t in
            withUnsafePointer(to: helper) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(descriptor, bytes.baseAddress, commandData.count, 0, $0,
                                  socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        guard sent == ssize_t(commandData.count) else { return nil }
        var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 250) > 0, (ready.revents & Int16(POLLIN)) != 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 512)
        let capacity = buffer.count
        let length = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, capacity, 0) }
        guard length > 0,
              let raw = try? JSONSerialization.jsonObject(with: Data(buffer.prefix(Int(length)))),
              let object = raw as? [String: Any] else { return nil }
        return object
    }

    private func unixAddress(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        return address
    }

    private static func validPolicy(_ value: String) -> Bool {
        return value == "off" || value == "auto" || value == "on"
    }
}
#endif
