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
