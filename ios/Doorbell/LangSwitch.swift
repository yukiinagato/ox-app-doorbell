import Foundation

/// Which visitor-language selection is current. Taps are applied to the screen at once; Core is
/// told only the final value after a short debounce, and Core's own echoes of earlier values
/// (events and status reads that were produced before the final one was stored) are ignored so
/// they cannot flip the screen back. Times are monotonic seconds.
struct LangSelectionCoalescer {
    static let debounce: TimeInterval = 0.2
    static let echoQuarantine: TimeInterval = 2

    private(set) var generation = 0
    private(set) var pending: String?
    private var selected: String?
    private var selectedAt: TimeInterval = 0

    /// Records a tap and returns its generation; any earlier generation is now stale.
    mutating func select(_ lang: String, at time: TimeInterval) -> Int {
        generation += 1
        pending = lang
        selected = lang
        selectedAt = time
        return generation
    }

    /// The value to send to Core for `generation`, or nil when a later tap superseded it or it
    /// was already sent.
    mutating func commit(generation committed: Int) -> String? {
        guard committed == generation, let value = pending else { return nil }
        pending = nil
        return value
    }

    /// The value still waiting for Core, taken immediately (before a press needs Core's state).
    mutating func flush() -> String? {
        guard let value = pending else { return nil }
        pending = nil
        return value
    }

    func acceptsEcho(_ lang: String, at time: TimeInterval) -> Bool {
        guard let selected = selected else { return true }
        if pending != nil || time - selectedAt < LangSelectionCoalescer.echoQuarantine {
            return lang == selected
        }
        return true
    }
}
