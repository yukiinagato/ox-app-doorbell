import XCTest

@testable import Doorbell

/// The `doorbell://pair` invitation: what the shell accepts, what it refuses, and why. Core is
/// adding `db_core_parse_pair_uri_json` so every shell reads one format; these cases are the
/// contract that call has to keep when it replaces the local parsing.
final class PairUriTests: XCTestCase {

    private let now: Int64 = 1_760_000_000

    private func uri(host: String = "10.0.1.5:47172", pin: String = "482913",
                     exp: Int64? = 1_760_000_600, cluster: String? = "Keihan%20House") -> String {
        var query = ["host=\(host)", "pin=\(pin)"]
        if let exp = exp { query.append("exp=\(exp)") }
        if let cluster = cluster { query.append("cluster=\(cluster)") }
        return "doorbell://pair?" + query.joined(separator: "&")
    }

    private func parse(_ text: String, at nowS: Int64? = nil) -> Result<PairUri, PairUri.Failure> {
        return PairUri.parse(text, nowS: nowS ?? now)
    }

    // MARK: - Valid

    func testAValidInvitationIsRead() {
        guard case .success(let invitation) = parse(uri()) else {
            return XCTFail("a well-formed invitation must parse")
        }
        XCTAssertEqual(invitation.host, "10.0.1.5:47172")
        XCTAssertEqual(invitation.pin, "482913")
        XCTAssertEqual(invitation.expiresAtS, 1_760_000_600)
        XCTAssertEqual(invitation.cluster, "Keihan House", "the name arrives percent-decoded")
    }

    func testAnInvitationWithoutAnExpiryNeverExpires() {
        guard case .success(let invitation) = parse(uri(exp: nil)) else {
            return XCTFail("an expiry is optional")
        }
        XCTAssertEqual(invitation.expiresAtS, 0)
    }

    func testAnInvitationWithoutAClusterNameIsStillUsable() {
        guard case .success(let invitation) = parse(uri(cluster: nil)) else {
            return XCTFail("the name is decoration, not identity")
        }
        XCTAssertEqual(invitation.cluster, "")
        XCTAssertEqual(invitation.pin, "482913")
    }

    /// A QR reader hands back exactly what was encoded, whitespace and all.
    func testSurroundingWhitespaceIsIgnored() {
        guard case .success = parse("  \(uri())\n") else {
            return XCTFail("a scanned string is trimmed before it is judged")
        }
    }

    // MARK: - Expired

    func testAnExpiredInvitationIsRefused() {
        XCTAssertEqual(parse(uri(exp: now - 1), at: now).failure, .expired)
    }

    /// The expiry is the second the token stops working, not the last second it works.
    func testAnInvitationExpiringThisSecondIsRefused() {
        XCTAssertEqual(parse(uri(exp: now), at: now).failure, .expired)
        XCTAssertNil(parse(uri(exp: now + 1), at: now).failure)
    }

    // MARK: - Missing or malformed

    func testAnInvitationWithoutAPinIsRefused() {
        XCTAssertEqual(parse("doorbell://pair?host=10.0.1.5:47172").failure, .missingPin)
        XCTAssertEqual(parse(uri(pin: "")).failure, .missingPin)
    }

    /// Five digits, seven digits, or six characters that are not all digits are a mis-scan. Sending
    /// one would burn an attempt on a token that only has a few.
    func testAPinThatIsNotSixDigitsIsRefused() {
        for bad in ["48291", "4829133", "48291a", "４８２９１３", "48 913"] {
            XCTAssertEqual(parse(uri(pin: bad)).failure, .missingPin, "rejects \(bad)")
        }
    }

    func testAnInvitationWithoutAHostIsRefused() {
        XCTAssertEqual(parse("doorbell://pair?pin=482913").failure, .missingHost)
    }

    func testAnythingThatIsNotAPairLinkIsRefused() {
        for bad in ["doorbell://debug/ping", "https://example.com/pair?pin=482913",
                    "doorbell-pair:10.0.1.5|node|key", "", "not a uri at all"] {
            XCTAssertEqual(parse(bad).failure, .notAPairUri, "rejects \(bad)")
        }
    }

    /// The scheme and action are matched case-insensitively, because a QR encoder may upper-case
    /// the whole payload to save modules.
    func testTheSchemeIsCaseInsensitive() {
        XCTAssertNil(parse("DOORBELL://PAIR?host=10.0.1.5:47172&pin=482913").failure)
    }

    // MARK: - Already paired

    /// A device already in a cluster must be asked before an invitation takes it out of one: the
    /// join is a full local reset. The snapshot's `paired` flag is what the screen gates on.
    func testAPairedSnapshotIsWhatTriggersTheConfirmation() {
        let paired = PairingSnapshot(["state": "ready", "paired": true])
        XCTAssertTrue(paired.paired, "a joined device confirms before leaving its cluster")

        let unpaired = PairingSnapshot(["state": "unpaired", "paired": false])
        XCTAssertFalse(unpaired.paired, "an unpaired device joins without a warning")
    }

    /// The invitation Core publishes on the PIN card is the same one this parser reads back.
    func testTheTokenUriTravelsOnTheSnapshot() {
        let snapshot = PairingSnapshot(["state": "ready",
                                        "token": ["host": "10.0.1.5:47172", "pin": "482913",
                                                  "uri": uri()]])
        XCTAssertEqual(snapshot.tokenUri, uri())
        guard case .success(let invitation) = parse(snapshot.tokenUri) else {
            return XCTFail("what the card draws must be what a scanner can read")
        }
        XCTAssertEqual(invitation.pin, snapshot.tokenPin)
        XCTAssertEqual(invitation.host, snapshot.tokenHost)
    }

    // MARK: - Core is the authority when it is running

    /// Core reads the code for every shell, and judges the expiry against corrected cluster time,
    /// which a shell cannot do. Its refusals are named in `err`.
    func testCoreRefusalNamesAreUnderstood() {
        XCTAssertEqual(PairUri.Failure(coreError: "bad_scheme"), .notAPairUri)
        XCTAssertEqual(PairUri.Failure(coreError: "missing_pin"), .missingPin)
        XCTAssertEqual(PairUri.Failure(coreError: "missing_host"), .missingHost)
        XCTAssertEqual(PairUri.Failure(coreError: "expired"), .expired)
        XCTAssertEqual(PairUri.Failure(coreError: "something_newer"), .notAPairUri,
                       "a refusal this build has never seen is still a refusal")
        XCTAssertEqual(PairUri.Failure(coreError: ""), .notAPairUri)
    }

    /// With Core not running — a code can be scanned before it starts — the shell's own reading
    /// stands in, and it has to agree with Core on the same input.
    func testTheLocalReadingStandsInWhenCoreIsNotRunning() {
        let core = CoreBridge()
        XCTAssertNil(core.parsePairUri(uri()), "a stopped core answers nothing")
        guard case .success(let invitation) = PairUri.parse(uri(), core: core, nowS: now) else {
            return XCTFail("the fallback must still read a good invitation")
        }
        XCTAssertEqual(invitation.pin, "482913")
        XCTAssertEqual(invitation.host, "10.0.1.5:47172")

        guard case .failure(let reason) = PairUri.parse(uri(exp: now - 1), core: core,
                                                        nowS: now) else {
            return XCTFail("the fallback must still refuse an expired one")
        }
        XCTAssertEqual(reason, .expired)
    }

    /// A Core that predates the field publishes no invitation, and the card falls back to the
    /// address and PIN it already showed.
    func testACoreWithoutTheFieldPublishesNoInvitation() {
        let snapshot = PairingSnapshot(["state": "ready",
                                        "token": ["host": "10.0.1.5:47172", "pin": "482913"]])
        XCTAssertEqual(snapshot.tokenUri, "")
        XCTAssertEqual(snapshot.tokenPin, "482913")
    }
}

private extension Result where Success == PairUri, Failure == PairUri.Failure {
    /// The refusal, or nil when the invitation was accepted.
    var failure: PairUri.Failure? {
        if case .failure(let reason) = self { return reason }
        return nil
    }
}
