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
