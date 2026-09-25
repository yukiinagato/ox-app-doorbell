import Foundation

// Compile this file with the UNMODIFIED production DoorbellClock.swift.
// These adapters replace platform boundaries, not DoorbellClock or its source.
// ProcessInfo is intentionally shadowed within this test-only executable so
// boundary instants are deterministic. It must never be linked into an app.
enum ProcessInfo {
    final class Uptime {
        var systemUptime: TimeInterval = 100
    }
    static let processInfo = Uptime()
}

enum ConfigUtil {
    static func int(_ doc: [String: Any], _ key: String, _ fallback: Int) -> Int {
        return (doc[key] as? NSNumber)?.intValue ?? fallback
    }
    static func double(_ doc: [String: Any], _ key: String, _ fallback: Double) -> Double {
        return (doc[key] as? NSNumber)?.doubleValue ?? fallback
    }
    static func bool(_ doc: [String: Any], _ key: String, _ fallback: Bool) -> Bool {
        return doc[key] as? Bool ?? fallback
    }
    static func str(_ doc: [String: Any], _ key: String) -> String? {
        return doc[key] as? String
    }
}
class Texts { func t(_ key: String) -> String { return key } }
class CoreBridge {
    var isRunning = true
    var generation: UInt64 = 1
    var runningGeneration: UInt64? { return isRunning ? generation : nil }
    var document: [String: Any]?
    private(set) var reads = 0
    func localTime(wallMs: Int64) -> [String: Any]? {
        reads += 1
        return document
    }
}

final class DeliveryQueue {
    private let condition = NSCondition()
    private var pending: (() -> Void)?
    func enqueue(_ job: @escaping () -> Void) {
        condition.lock()
        pending = job
        condition.signal()
        condition.unlock()
    }
    func drain() throws {
        condition.lock()
        let deadline = Date().addingTimeInterval(5)
        while pending == nil {
            if !condition.wait(until: deadline) {
                condition.unlock()
                throw ProbeError.failed("Clock refresh did not produce a delivery")
            }
        }
        let job = pending
        pending = nil
        condition.unlock()
        job?()
    }
}
enum ProbeError: Error { case failed(String) }

@main
struct ClockProbe {
    static func check(_ ok: Bool, _ message: String) throws {
        if !ok { throw ProbeError.failed(message) }
    }
    static func document(_ hour: Int, _ minute: Int, _ second: Int,
                         _ fraction: Int) -> [String: Any] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26,
                           hour: hour, minute: minute, second: second))!
        return ["hh": hour, "mm": minute, "ss": second,
                "date": "2026-09-26", "weekday": "sat", "tz": "UTC", "known": true,
                "wall_ms": Int64(instant.timeIntervalSince1970 * 1000) + Int64(fraction)]
    }
    static func phase(hour: Int = 12, minute: Int = 0, second: Int = 0,
                      fraction: Int, elapsed: Double, expected: String,
                      date: String = "2026-09-26") throws {
        ProcessInfo.processInfo.systemUptime = 100
        let core = CoreBridge()
        core.document = document(hour, minute, second, fraction)
        let queue = DeliveryQueue()
        let source = DoorbellClockSource(deliver: queue.enqueue)
        source.refresh(core)
        try queue.drain()
        ProcessInfo.processInfo.systemUptime = 100 + elapsed
        guard let value = source.reading() else { throw ProbeError.failed("No reading") }
        try check(value.hhmmss == expected && value.date == date,
                  "expected \(date) \(expected), actual \(value.date) \(value.hhmmss); base_ms=\(fraction), elapsed=\(elapsed)")
        try check(core.reads == 1, "Drawing must not call Core every tick")
    }
    static func main() {
        var results: [[String: Any]] = []
        func test(_ id: String, _ body: () throws -> Void) {
            do { try body(); results.append(["id": id, "status": "PASS"]) }
            catch { results.append(["id": id, "status": "FAIL", "detail": "\(error)"]) }
        }
        test("qa_v2.swift.exact_second_control") {
            try phase(fraction: 0, elapsed: 1.25, expected: "12:00:01")
        }
        test("qa_v2.swift.before_boundary_control") {
            try phase(fraction: 100, elapsed: 0.25, expected: "12:00:00")
        }
        test("qa_v2.swift.fractional_second_boundary") {
            try phase(fraction: 900, elapsed: 0.25, expected: "12:00:01")
        }
        test("qa_v2.swift.fractional_multi_second_boundary") {
            try phase(fraction: 900, elapsed: 1.25, expected: "12:00:02")
        }
        test("qa_v2.swift.minute_boundary") {
            try phase(second: 59, fraction: 900, elapsed: 0.25, expected: "12:01:00")
        }
        test("qa_v2.swift.midnight_boundary") {
            try phase(hour: 23, minute: 59, second: 59, fraction: 900, elapsed: 0.25,
                      expected: "00:00:00", date: "2026-09-27")
        }
        test("qa_v2.swift.unstarted_core_control") {
            let core = CoreBridge(); core.isRunning = false
            let source = DoorbellClockSource()
            source.refresh(core)
            try check(core.reads == 0 && source.reading() == nil && source.waitingForCore,
                      "Unstarted Core must not be queried")
        }
        test("qa_v2.swift.obsolete_generation_control") {
            ProcessInfo.processInfo.systemUptime = 100
            let core = CoreBridge(); core.document = document(12, 0, 0, 0)
            let queue = DeliveryQueue()
            let source = DoorbellClockSource(deliver: queue.enqueue)
            source.refresh(core)
            // A restart happens after scheduling and before main-thread delivery.
            core.generation += 1
            try queue.drain()
            try check(source.reading() == nil && source.waitingForCore,
                      "An old generation must not replace a restarted Core clock")
        }
        let output: [String: Any] = ["suite": "swift-production-clock-host", "results": results]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        exit(results.contains { $0["status"] as? String != "PASS" } ? 1 : 0)
    }
}
