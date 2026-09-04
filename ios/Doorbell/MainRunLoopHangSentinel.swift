import Foundation

#if os(iOS)
import Darwin

/// A foreground-only probe state machine. Every mutable field is owned by `queue`, so the fatal
/// path neither waits for the main thread nor enters another subsystem's lock.
final class MainRunLoopHangSentinel {
    private static let foregroundGrace: TimeInterval = 5
    private static let probeInterval: TimeInterval = 5
    private static let failureLimit = 3
    private static let marker = Array("main_run_loop_stall_3x5s\n".utf8)

    private let queue = DispatchQueue(label: "jp.ox.doorbell.main-hang-sentinel", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var markerDescriptor: Int32
    private var externalSupervisorActive = false
    private var armed = false
    private var tripped = false
    private var graceUntil: TimeInterval = 0
    private var nextProbe: TimeInterval = 0
    private var probeSequence: UInt64 = 0
    private var pendingProbe: UInt64?
    private var pendingDeadline: TimeInterval = 0
    private var consecutiveFailures = 0

    init(markerPath: String) {
        markerDescriptor = open(markerPath, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC,
                                S_IRUSR | S_IWUSR)
    }

    deinit { stop() }

    static func consumeMarker(at path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer {
            close(descriptor)
            unlink(path)
        }
        var bytes = [UInt8](repeating: 0, count: marker.count)
        let capacity = bytes.count
        let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, capacity) }
        return count == ssize_t(marker.count) && bytes == marker
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.check() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            if markerDescriptor >= 0 { close(markerDescriptor) }
            markerDescriptor = -1
        }
    }

    func setExternalSupervisorActive(_ active: Bool) {
        queue.async { [weak self] in self?.externalSupervisorActive = active }
    }

    func armAfterForegroundGrace() {
        let now = ProcessInfo.processInfo.systemUptime
        queue.async { [weak self] in
            guard let self = self else { return }
            self.armed = true
            self.tripped = false
            self.pendingProbe = nil
            self.consecutiveFailures = 0
            self.graceUntil = now + MainRunLoopHangSentinel.foregroundGrace
            self.nextProbe = self.graceUntil
        }
    }

    func disarmForBackground() {
        queue.sync {
            armed = false
            tripped = false
            pendingProbe = nil
            consecutiveFailures = 0
        }
    }

    private func acknowledgeProbe(_ probe: UInt64) {
        queue.async { [weak self] in
            guard let self = self, self.pendingProbe == probe else { return }
            self.pendingProbe = nil
            self.consecutiveFailures = 0
        }
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        guard armed, !tripped, now >= graceUntil, now >= nextProbe else { return }
        if pendingProbe != nil && now >= pendingDeadline {
            pendingProbe = nil
            consecutiveFailures += 1
            if consecutiveFailures >= MainRunLoopHangSentinel.failureLimit {
                tripped = true
                if externalSupervisorActive { recordAndAbort() }
                else {
                    tripped = false
                    consecutiveFailures = 0
                    nextProbe = now + MainRunLoopHangSentinel.probeInterval
                }
                return
            }
        }
        nextProbe = now + MainRunLoopHangSentinel.probeInterval
        probeSequence &+= 1
        let probe = probeSequence
        pendingProbe = probe
        pendingDeadline = now + MainRunLoopHangSentinel.probeInterval
        DispatchQueue.main.async { [weak self] in self?.acknowledgeProbe(probe) }
    }

    private func recordAndAbort() -> Never {
        if markerDescriptor >= 0 {
            _ = MainRunLoopHangSentinel.marker.withUnsafeBytes {
                write(markerDescriptor, $0.baseAddress, MainRunLoopHangSentinel.marker.count)
            }
            _ = fsync(markerDescriptor)
            close(markerDescriptor)
            markerDescriptor = -1
        }
        Darwin.raise(SIGABRT)
        abort()
    }
}
#endif
