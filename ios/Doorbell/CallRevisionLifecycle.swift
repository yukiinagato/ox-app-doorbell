import Foundation

enum CallRevisionUpdate: Equatable {
    case stale
    case advanced
    case answerSuperseded
}

struct CallRevisionLifecycle {
    private(set) var stageRevision: Int
    private var answerRevision: Int?
    private var suppressingLosingIdle = false

    init(stageRevision: Int) {
        self.stageRevision = max(0, stageRevision)
    }

    mutating func beginAnswer() {
        answerRevision = stageRevision
    }

    mutating func observeWinningRevision(_ revision: Int) -> CallRevisionUpdate {
        let normalized = max(0, revision)
        guard normalized > stageRevision else { return .stale }
        stageRevision = normalized
        guard let answered = answerRevision, normalized > answered else { return .advanced }
        answerRevision = nil
        suppressingLosingIdle = true
        return .answerSuperseded
    }

    mutating func consumeSupersededIdle() -> Bool {
        guard suppressingLosingIdle else { return false }
        suppressingLosingIdle = false
        return true
    }
}

struct CallChimeRevisionGate {
    private let capacity: Int
    private var revisions: [String: Int] = [:]
    private var order: [String] = []

    init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    mutating func accept(callId: String, stageRevision: Int) -> Bool {
        guard !callId.isEmpty else { return true }
        let normalized = max(0, stageRevision)
        if let accepted = revisions[callId] {
            guard normalized > accepted else { return false }
            revisions[callId] = normalized
            return true
        }
        revisions[callId] = normalized
        order.append(callId)
        while order.count > capacity {
            revisions.removeValue(forKey: order.removeFirst())
        }
        return true
    }
}

/// How long an indoor panel stays on a call it is showing before returning to its home page, and
/// what the number beside the title says while it does.
///
/// A panel nobody is standing at must not sit on a dead call screen forever, but leaving the page
/// the moment the visitor gives up is worse: a resident walking towards the panel arrives to find
/// nothing, and the live view is the whole point of the screen. So the visitor cancelling does not
/// close the page — only this countdown does. Answering suspends it, because someone is plainly
/// there, and it starts over at the full value when the call ends. Tapping the number stops it for
/// good: a resident who touched the screen is reading it.
struct IncomingReturnCountdown: Equatable {

    /// What to draw beside the title.
    enum Display: Equatable {
        /// Nothing: the countdown is paused for a call, stopped by the resident, or disabled.
        case hidden
        /// The seconds left, drawn as the title's `(n)` suffix.
        case seconds(Int)
    }

    /// The value Core publishes when it has not been configured.
    static let defaultSeconds = 60

    private(set) var total: Int
    private(set) var remaining: Int
    /// The resident stopped it by hand, or it was never running.
    private(set) var isStopped: Bool
    /// Suspended while a call is up.
    private(set) var isPaused = false

    /// `seconds` at or below zero means the panel never returns on its own.
    init(seconds: Int) {
        total = max(0, seconds)
        remaining = total
        isStopped = total == 0
    }

    /// `call.indoor.return_s` as Core publishes it in the runtime status. A Core that predates the
    /// field, or a value that is not a number, falls back to the documented default rather than to
    /// no countdown at all.
    static func seconds(status: [String: Any]?) -> Int {
        for path in ["call.indoor.return_s", "call.return_s"] {
            if ConfigUtil.dig(status, path) != nil {
                return ConfigUtil.int(status, path, defaultSeconds)
            }
        }
        return defaultSeconds
    }

    var display: Display {
        return (isStopped || isPaused) ? .hidden : .seconds(remaining)
    }

    /// True once the panel should return to its home page.
    var hasElapsed: Bool { return !isStopped && !isPaused && remaining <= 0 }

    /// One second passed. Returns true when the panel should return home now.
    mutating func tick() -> Bool {
        guard !isStopped, !isPaused else { return false }
        remaining = max(0, remaining - 1)
        return remaining == 0
    }

    /// A call was answered on this screen: someone is here, so the return stops and its number
    /// goes away rather than counting down behind the conversation.
    mutating func pauseForCall() {
        guard !isStopped else { return }
        isPaused = true
    }

    /// The call ended and the panel is unattended again, so the full countdown starts over.
    mutating func resumeAfterCall() {
        guard !isStopped else { return }
        isPaused = false
        remaining = total
    }

    /// A fresh call arrived on a screen that is already open.
    mutating func restart() {
        guard total > 0 else { return }
        isStopped = false
        isPaused = false
        remaining = total
    }

    /// The resident tapped the number. They are reading the screen, so it stays until they leave.
    mutating func stop() {
        isStopped = true
        isPaused = false
    }
}
