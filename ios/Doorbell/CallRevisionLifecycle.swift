import Foundation
import CoreFoundation

struct CallTiming {
    struct Snapshot {
        let document: [String: Any]
        let coreGeneration: UInt64
        let requestedAt: TimeInterval
    }

    struct Reading {
        let call: [String: Any]
        let coreGeneration: UInt64
        let remainingSeconds: TimeInterval?
        let recoveryRemainingSeconds: TimeInterval?

        var mayRestore: Bool {
            return call["recovery_required"] as? Bool == true &&
                call["recovery_eligible"] as? Bool == true &&
                (remainingSeconds ?? 0) > 0 && (recoveryRemainingSeconds ?? 0) > 0
        }
    }

    enum Observation {
        case unavailable
        case absent
        case active(Reading)
    }

    private struct Identity: Equatable {
        let core: UInt64
        let snapshot: String
        let call: String
        let door: String
        let revision: Double
        let owner: String
        let state: String
    }

    private var identity: Identity?
    private var deadline: TimeInterval?
    private var recoveryDeadline: TimeInterval?
    private struct SampleIdentity: Equatable {
        let core: UInt64
        let snapshot: String
    }
    private var lastSample: SampleIdentity?
    private var refreshBaseline: SampleIdentity?
    private(set) var waitingForFreshSnapshot = false

    mutating func reset() {
        identity = nil
        deadline = nil
        recoveryDeadline = nil
    }

    /// Historical monotonic clocks may stop during system sleep. A foreground read of the old
    /// cache therefore cannot prove freshness even when its reported age remains small.
    mutating func requireFreshSnapshot(_ snapshot: Snapshot? = nil) {
        if !waitingForFreshSnapshot {
            refreshBaseline = snapshot.flatMap { value in
                guard let generation = value.document["snapshot_generation"] as? String,
                      !generation.isEmpty else { return nil }
                return SampleIdentity(core: value.coreGeneration, snapshot: generation)
            } ?? lastSample
        }
        waitingForFreshSnapshot = true
        reset()
    }

    mutating func accepts(_ snapshot: Snapshot?) -> Bool {
        guard let snapshot = snapshot,
              snapshot.requestedAt.isFinite,
              let generation = snapshot.document["snapshot_generation"] as? String,
              !generation.isEmpty,
              Self.milliseconds(snapshot.document["snapshot_age_ms"]) != nil,
              snapshot.document["active_calls"] is [[String: Any]] else { return false }
        let sample = SampleIdentity(core: snapshot.coreGeneration, snapshot: generation)
        lastSample = sample
        if waitingForFreshSnapshot {
            guard let baseline = refreshBaseline else {
                refreshBaseline = sample
                return false
            }
            guard sample != baseline else { return false }
            waitingForFreshSnapshot = false
            refreshBaseline = nil
        }
        return true
    }

    /// A repeated cached sample may only shorten its existing anchor. Reading an unchanged
    /// duration again cannot renew either the call or Core's recovery window.
    mutating func observeRecovery(_ snapshot: Snapshot?, callId: String, role: String,
                                  nodeId: String, door: String, now: TimeInterval) -> Observation {
        guard !nodeId.isEmpty, let calls = snapshot?.document["active_calls"] as? [[String: Any]],
              let call = calls.first(where: { $0["call_id"] as? String == callId }) else {
            return .unavailable
        }
        let state = call["state"] as? String
        let ownsDialog = state == "in_call" && call["dialog_owner"] as? String == nodeId
        let ownsWaiting = state == "ringing" && role == "door_station" &&
            call["origin"] as? String == nodeId && call["door"] as? String == door
        guard ownsDialog || ownsWaiting else { return .unavailable }
        return observe(snapshot, callId: callId, door: call["door"] as? String ?? "", now: now)
    }

    mutating func observe(_ snapshot: Snapshot?, callId: String, door: String,
                          now: TimeInterval) -> Observation {
        guard accepts(snapshot), let snapshot = snapshot, !callId.isEmpty,
              snapshot.requestedAt.isFinite, now.isFinite, now >= snapshot.requestedAt,
              let generation = snapshot.document["snapshot_generation"] as? String,
              !generation.isEmpty,
              let age = Self.milliseconds(snapshot.document["snapshot_age_ms"]),
              let calls = snapshot.document["active_calls"] as? [[String: Any]] else {
            return .unavailable
        }
        guard let call = calls.first(where: {
            $0["call_id"] as? String == callId && $0["door"] as? String == door
        }) else {
            reset()
            return .absent
        }
        guard call["snapshot_generation"] as? String == generation,
              let revision = Self.milliseconds(call["stage_revision"]),
              let state = call["state"] as? String,
              state == "ringing" || state == "in_call" else { return .unavailable }
        let key = Identity(core: snapshot.coreGeneration, snapshot: generation, call: callId,
                           door: door, revision: revision,
                           owner: call["dialog_owner"] as? String ?? "", state: state)
        let freshDeadline = Self.milliseconds(call["remaining_ms"]).map {
            snapshot.requestedAt + max(0, $0 - age) / 1000
        }
        let freshRecovery = Self.milliseconds(call["recovery_remaining_ms"]).flatMap {
            $0 <= 10000 ? snapshot.requestedAt + max(0, $0 - age) / 1000 : nil
        }
        if identity == key {
            if let fresh = freshDeadline { deadline = deadline.map { min($0, fresh) } ?? fresh }
            if let fresh = freshRecovery {
                recoveryDeadline = recoveryDeadline.map { min($0, fresh) } ?? fresh
            }
        } else {
            identity = key
            deadline = freshDeadline
            recoveryDeadline = freshRecovery
        }
        return .active(Reading(call: call, coreGeneration: snapshot.coreGeneration,
            remainingSeconds: freshDeadline == nil ? nil : deadline.map { max(0, $0 - now) },
            recoveryRemainingSeconds: freshRecovery == nil ? nil :
                recoveryDeadline.map { max(0, $0 - now) }))
    }

    private static func milliseconds(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= 9007199254740991,
              value.rounded(.towardZero) == value else { return nil }
        return value
    }
}

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

    /// `status.call.return_s`, as Core publishes it. `call.indoor.return_s` is accepted first as
    /// the more specific spelling should Core ever nest it. A Core that predates the field, or a
    /// value that is not a number, falls back to the documented default rather than to no
    /// countdown at all.
    ///
    /// The dotted lookup is spelled out here rather than borrowed from `ConfigUtil`: this file is
    /// pure Foundation and is compiled into all three application targets, and a helper that is
    /// not is exactly the kind of dependency that breaks one target and not the others.
    static func seconds(status: [String: Any]?) -> Int {
        for path in ["call.indoor.return_s", "call.return_s"] {
            guard let value = lookup(path, in: status) else { continue }
            if let number = value as? NSNumber { return number.intValue }
            if let text = value as? String, let parsed = Int(text) { return parsed }
            return defaultSeconds
        }
        return defaultSeconds
    }

    private static func lookup(_ dotted: String, in root: [String: Any]?) -> Any? {
        var current: Any? = root
        for part in dotted.split(separator: ".") {
            guard let level = current as? [String: Any], let next = level[String(part)],
                  !(next is NSNull) else { return nil }
            current = next
        }
        return current
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

/// How soon the shell may open another SIP monitor (listen) dialog to a door station after one
/// ended without carrying anything.
///
/// From a device run: an indoor panel reopened a monitor dialog to an iPad 1 door station about
/// 1.5 times a second for 39 seconds, every one of them ending immediately with no RTP in either
/// direction. There was no backoff, so the retries themselves saturated the door station and took
/// its HTTP server down with them — which removed the video frame whose absence was triggering the
/// retry. A failed listen has to get quieter, not louder.
struct MonitorRetryPolicy: Equatable {

    /// The first wait, and the ceiling the doubling stops at.
    static let firstDelayS: TimeInterval = 1
    static let maxDelayS: TimeInterval = 30

    /// What became of one monitor attempt.
    enum Outcome: Equatable {
        /// Media actually flowed: the door can be listened to and the wait resets.
        case carriedAudio
        /// The dialog came up and ended with nothing sent or received.
        case endedWithoutMedia
        /// The door never accepted the invitation.
        case refused
        /// The door says it has no microphone. Retrying cannot fix that.
        case doorHasNoAudio
    }

    private(set) var failures = 0
    /// Set once the door has said it has nothing to listen to. Only a deliberate request clears it.
    private(set) var hasGivenUp = false

    /// The wait before the next automatic attempt, or nil when there must not be one.
    mutating func nextDelay(after outcome: Outcome) -> TimeInterval? {
        switch outcome {
        case .carriedAudio:
            failures = 0
            return nil
        case .doorHasNoAudio:
            hasGivenUp = true
            failures = 0
            return nil
        case .endedWithoutMedia, .refused:
            guard !hasGivenUp else { return nil }
            failures += 1
            return MonitorRetryPolicy.delay(forFailure: failures)
        }
    }

    /// 1, 2, 4, 8, 16, then 30 for as long as it keeps failing.
    static func delay(forFailure attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return firstDelayS }
        // Doubling is computed by halving the ceiling instead of shifting, so a long-lived panel
        // cannot overflow the exponent.
        var delay = firstDelayS
        for _ in 1..<attempt {
            delay *= 2
            if delay >= maxDelayS { return maxDelayS }
        }
        return min(delay, maxDelayS)
    }

    /// Whether a monitor dialog may be opened at all. `wanted` is the user's toggle: an automatic
    /// retry behind a toggle the user has switched off is exactly the storm this prevents.
    func mayAttempt(wanted: Bool) -> Bool {
        return wanted && !hasGivenUp
    }

    /// A deliberate request — the user selecting a door, or turning the toggle back on — starts
    /// over, including after the door said it had no audio.
    mutating func reset() {
        failures = 0
        hasGivenUp = false
    }
}
