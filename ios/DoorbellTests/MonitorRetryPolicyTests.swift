import XCTest

@testable import Doorbell

/// The backoff behind SIP monitor (listen) dialogs. From a device run: an indoor panel reopened a
/// monitor dialog to an iPad 1 door station roughly 1.5 times a second for 39 seconds, each one
/// ending with no RTP either way. The retries saturated the door station and took its HTTP down,
/// which removed the video frame whose absence was driving the retry.
final class MonitorRetryPolicyTests: XCTestCase {

    // MARK: - The wait grows

    func testTheWaitDoublesFromOneSecondAndStopsAtThirty() {
        var policy = MonitorRetryPolicy()
        let waits = (0..<8).map { _ in policy.nextDelay(after: .endedWithoutMedia) ?? -1 }
        XCTAssertEqual(waits, [1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(MonitorRetryPolicy.maxDelayS, 30)
    }

    func testARefusedInvitationBacksOffTheSameWay() {
        var policy = MonitorRetryPolicy()
        XCTAssertEqual(policy.nextDelay(after: .refused), 1)
        XCTAssertEqual(policy.nextDelay(after: .refused), 2)
        XCTAssertEqual(policy.nextDelay(after: .endedWithoutMedia), 4,
                       "the two failures share one ladder")
    }

    /// The storm was ~1.5 attempts a second. Even the very first wait is longer than that, and by
    /// the sixth failure the panel is asking once every thirty seconds.
    func testTheLadderIsNeverFasterThanTheObservedStorm() {
        var policy = MonitorRetryPolicy()
        var elapsed: TimeInterval = 0
        var attempts = 0
        while elapsed < 39 {
            guard let wait = policy.nextDelay(after: .endedWithoutMedia) else { break }
            elapsed += wait
            attempts += 1
        }
        XCTAssertLessThanOrEqual(attempts, 7,
                                 "39 s of failure costs a handful of attempts, not ~58")
    }

    // MARK: - Success resets it

    func testAListenThatCarriedAudioClearsTheWait() {
        var policy = MonitorRetryPolicy()
        _ = policy.nextDelay(after: .endedWithoutMedia)
        _ = policy.nextDelay(after: .endedWithoutMedia)
        XCTAssertNil(policy.nextDelay(after: .carriedAudio), "success schedules nothing")
        XCTAssertEqual(policy.failures, 0)
        XCTAssertEqual(policy.nextDelay(after: .endedWithoutMedia), 1, "back to the first rung")
    }

    // MARK: - A door with no microphone

    func testADoorWithNoAudioIsNotAskedAgain() {
        var policy = MonitorRetryPolicy()
        XCTAssertNil(policy.nextDelay(after: .doorHasNoAudio))
        XCTAssertTrue(policy.hasGivenUp)
        XCTAssertNil(policy.nextDelay(after: .endedWithoutMedia),
                     "nothing reopens a dialog to a door that cannot be listened to")
        XCTAssertFalse(policy.mayAttempt(wanted: true))
    }

    /// Selecting the door by hand is a person asking again, and that is always allowed.
    func testADeliberateRequestStartsOver() {
        var policy = MonitorRetryPolicy()
        _ = policy.nextDelay(after: .doorHasNoAudio)
        policy.reset()
        XCTAssertFalse(policy.hasGivenUp)
        XCTAssertTrue(policy.mayAttempt(wanted: true))
        XCTAssertEqual(policy.nextDelay(after: .endedWithoutMedia), 1)
    }

    // MARK: - The toggle

    /// The storm kept reopening dialogs with nothing on screen asking for them. An automatic
    /// retry behind a toggle the user has switched off is exactly that.
    func testNothingIsAttemptedWhileTheToggleIsOff() {
        var policy = MonitorRetryPolicy()
        XCTAssertFalse(policy.mayAttempt(wanted: false))
        _ = policy.nextDelay(after: .endedWithoutMedia)
        XCTAssertFalse(policy.mayAttempt(wanted: false), "a pending wait does not override it")
        XCTAssertTrue(policy.mayAttempt(wanted: true))
    }

    func testAFreshPolicyMayAttemptImmediately() {
        let policy = MonitorRetryPolicy()
        XCTAssertTrue(policy.mayAttempt(wanted: true))
        XCTAssertEqual(policy.failures, 0)
        XCTAssertFalse(policy.hasGivenUp)
    }
}
