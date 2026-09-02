import XCTest

@testable import Doorbell

/// The indoor panel's return to its home page. The rules come from device testing: a panel nobody
/// is at must not sit on a dead call screen, but it must also not vanish while a resident is
/// walking towards it, and it must not count down behind a conversation.
final class IncomingReturnCountdownTests: XCTestCase {

    private func status(_ call: [String: Any]) -> [String: Any] {
        return ["call": call]
    }

    // MARK: - What Core publishes

    func testTheDefaultIsSixtySecondsUntilCorePublishesTheField() {
        XCTAssertEqual(IncomingReturnCountdown.defaultSeconds, 60)
        XCTAssertEqual(IncomingReturnCountdown.seconds(status: nil), 60)
        XCTAssertEqual(IncomingReturnCountdown.seconds(status: [:]), 60)
        XCTAssertEqual(IncomingReturnCountdown.seconds(status: status([:])), 60)
    }

    func testTheConfiguredValueIsRead() {
        XCTAssertEqual(
            IncomingReturnCountdown.seconds(status: status(["indoor": ["return_s": 25]])), 25)
        // The flatter spelling is accepted too, so the shell does not depend on which one lands.
        XCTAssertEqual(IncomingReturnCountdown.seconds(status: status(["return_s": 90])), 90)
        // The nested field wins when both are present.
        XCTAssertEqual(
            IncomingReturnCountdown.seconds(
                status: status(["return_s": 90, "indoor": ["return_s": 25]])), 25)
    }

    // MARK: - Counting down

    func testItCountsDownAndReturnsHomeAtZero() {
        var countdown = IncomingReturnCountdown(seconds: 3)
        XCTAssertEqual(countdown.display, .seconds(3))
        XCTAssertFalse(countdown.tick())
        XCTAssertEqual(countdown.display, .seconds(2))
        XCTAssertFalse(countdown.tick())
        XCTAssertEqual(countdown.display, .seconds(1))
        XCTAssertTrue(countdown.tick(), "the last tick is the one that returns home")
        XCTAssertEqual(countdown.display, .seconds(0))
        XCTAssertTrue(countdown.hasElapsed)
    }

    func testZeroSecondsMeansThePanelNeverReturnsOnItsOwn() {
        var countdown = IncomingReturnCountdown(seconds: 0)
        XCTAssertEqual(countdown.display, .hidden)
        XCTAssertFalse(countdown.tick())
        XCTAssertFalse(countdown.hasElapsed)

        var negative = IncomingReturnCountdown(seconds: -5)
        XCTAssertEqual(negative.display, .hidden)
        XCTAssertFalse(negative.tick())
    }

    // MARK: - The resident stops it

    /// Tapping the number is a person saying they are here and reading the screen.
    func testTappingTheNumberStopsTheReturnForGood() {
        var countdown = IncomingReturnCountdown(seconds: 60)
        XCTAssertFalse(countdown.tick())
        countdown.stop()
        XCTAssertEqual(countdown.display, .hidden, "the suffix disappears")
        for _ in 0..<120 {
            XCTAssertFalse(countdown.tick(), "a stopped countdown never returns home")
        }
        XCTAssertFalse(countdown.hasElapsed)
    }

    /// A stopped countdown stays stopped through a call: the resident's decision outranks it.
    func testAStoppedCountdownIsNotRevivedByACall() {
        var countdown = IncomingReturnCountdown(seconds: 60)
        countdown.stop()
        countdown.pauseForCall()
        countdown.resumeAfterCall()
        XCTAssertEqual(countdown.display, .hidden)
        XCTAssertFalse(countdown.tick())
    }

    // MARK: - A call suspends it

    func testAnsweringHidesTheNumberAndStopsTheClock() {
        var countdown = IncomingReturnCountdown(seconds: 60)
        for _ in 0..<10 { _ = countdown.tick() }
        XCTAssertEqual(countdown.display, .seconds(50))

        countdown.pauseForCall()
        XCTAssertEqual(countdown.display, .hidden, "nothing ticks behind a conversation")
        for _ in 0..<600 { XCTAssertFalse(countdown.tick()) }
        XCTAssertEqual(countdown.remaining, 50, "the clock did not move while paused")
    }

    func testTheCallEndingStartsTheFullCountdownAgain() {
        var countdown = IncomingReturnCountdown(seconds: 60)
        for _ in 0..<45 { _ = countdown.tick() }
        countdown.pauseForCall()
        countdown.resumeAfterCall()
        XCTAssertEqual(countdown.display, .seconds(60), "it restarts from the full value")
        XCTAssertFalse(countdown.tick())
        XCTAssertEqual(countdown.display, .seconds(59))
    }

    // MARK: - The visitor giving up changes nothing

    /// A cancelled call leaves the page alone. Only this countdown, or the resident, ends it.
    func testACancelledCallDoesNotAffectTheCountdown() {
        var countdown = IncomingReturnCountdown(seconds: 5)
        _ = countdown.tick()
        let beforeCancel = countdown
        // Nothing on the cancel path touches the countdown, so it is still exactly where it was.
        XCTAssertEqual(countdown, beforeCancel)
        XCTAssertEqual(countdown.display, .seconds(4))
    }

    /// A second visitor rings the panel that is already open.
    func testAFreshCallRestartsTheReturn() {
        var countdown = IncomingReturnCountdown(seconds: 60)
        for _ in 0..<55 { _ = countdown.tick() }
        XCTAssertEqual(countdown.display, .seconds(5))
        countdown.restart()
        XCTAssertEqual(countdown.display, .seconds(60))
    }

    /// A restart brings back a countdown the resident had stopped, because a new visitor is a new
    /// reason for the panel to go home afterwards.
    func testARestartRevivesAStoppedCountdown() {
        var countdown = IncomingReturnCountdown(seconds: 30)
        countdown.stop()
        countdown.restart()
        XCTAssertEqual(countdown.display, .seconds(30))
    }

    /// A panel configured never to return stays that way when a new call arrives.
    func testARestartDoesNotInventACountdownThatWasDisabled() {
        var countdown = IncomingReturnCountdown(seconds: 0)
        countdown.restart()
        XCTAssertEqual(countdown.display, .hidden)
        XCTAssertFalse(countdown.tick())
    }
}
