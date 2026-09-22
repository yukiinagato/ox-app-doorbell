import Foundation

@main
private struct ModernCallRevisionTest {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data(("FAIL: \(message)\n").utf8))
            exit(1)
        }
    }

    static func main() {
        func snapshot(_ remaining: Any?, at time: TimeInterval) -> CallTiming.Snapshot {
            var call: [String: Any] = ["call_id": "call-a", "door": "front",
                "state": "ringing", "stage_revision": 0, "snapshot_generation": "sample-a"]
            call["remaining_ms"] = remaining
            return CallTiming.Snapshot(document: ["snapshot_generation": "sample-a",
                "snapshot_age_ms": 2_000, "active_calls": [call]], coreGeneration: 1,
                requestedAt: time)
        }
        var timing = CallTiming()
        func remaining(_ duration: Any?, at time: TimeInterval) -> TimeInterval? {
            guard case .active(let reading) = timing.observe(snapshot(duration, at: time),
                callId: "call-a", door: "front", now: time) else { return nil }
            return reading.remainingSeconds
        }
        require(abs((remaining(12_345, at: 100) ?? 0) - 10.345) < 0.000001,
                "Core snapshot age is subtracted before using the local timer")
        require(abs((remaining(12_345, at: 105) ?? 0) - 5.345) < 0.000001,
                "a repeated cached sample cannot renew its deadline")
        require(remaining(-20, at: 106) == nil, "invalid duration requires a fresh Core check")
        require(remaining(nil, at: 107) == nil, "missing duration never falls back to wall time")
        require(remaining(Double.nan, at: 108) == nil, "non-finite duration cannot reach a timer")
        require(remaining(12_345, at: 111) == 0, "elapsed cached duration reaches zero")
        var lifecycle = CallRevisionLifecycle(stageRevision: 0)
        lifecycle.beginAnswer()
        require(lifecycle.observeWinningRevision(1) == .answerSuperseded,
                "a higher winning purpose must supersede the stale answer binding")
        require(lifecycle.stageRevision == 1, "the incoming screen must advance to revision 1")
        require(lifecycle.consumeSupersededIdle(),
                "the losing SIP leg idle must be consumed without closing revision 1")
        require(!lifecycle.consumeSupersededIdle(), "only one losing idle may be suppressed")
        require(lifecycle.observeWinningRevision(1) == .stale,
                "same-revision purpose updates must remain deduplicated")
        require(lifecycle.observeWinningRevision(0) == .stale,
                "stale purpose updates must remain deduplicated")

        var monitor = CallRevisionLifecycle(stageRevision: 0)
        require(monitor.observeWinningRevision(1) == .advanced,
                "monitoring without an answer binding must not be demoted as a losing answer")
        require(!monitor.consumeSupersededIdle(), "monitor idle must not be suppressed")

        var chimes = CallChimeRevisionGate(capacity: 2)
        require(chimes.accept(callId: "call-a", stageRevision: 0),
                "initial chime must be accepted")
        require(!chimes.accept(callId: "call-a", stageRevision: 0),
                "same-revision chime must be rejected")
        require(chimes.accept(callId: "call-a", stageRevision: 1),
                "the corrected revision chime must be accepted once")
        require(!chimes.accept(callId: "call-a", stageRevision: 0),
                "stale chime must be rejected")

        print("modern call revision lifecycle test passed")
    }
}
