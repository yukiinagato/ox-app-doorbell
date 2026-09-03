package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The doorbell:// pairing link: parsing, expiry, and what the screen does with it. */
class PairUriTest {

    private val nowMs = 1_700_000_000_000L
    private val nowS = nowMs / 1000L

    private fun link(
        host: String = "10.0.1.10:47172",
        pin: String = "123456",
        exp: Long = nowS + 600,
        cluster: String = "我が家",
    ) = PairUri.build(host, pin, exp, cluster)

    @Test
    fun aValidLinkRoundTrips() {
        val result = PairUri.parse(link(), nowMs)
        assertTrue(result is PairUriResult.Ok)
        val invite = (result as PairUriResult.Ok).invite
        assertEquals("10.0.1.10:47172", invite.host)
        assertEquals("123456", invite.pin)
        assertEquals(nowS + 600, invite.expiresAtS)
        assertEquals("我が家", invite.cluster)
        assertFalse(invite.expiredAt(nowMs))
        assertEquals(600L, invite.secondsLeft(nowMs))
    }

    @Test
    fun anExpiredLinkIsRefusedRatherThanStartingADoomedJoin() {
        val result = PairUri.parse(link(exp = nowS - 1), nowMs)
        assertEquals(PairUriError.EXPIRED, (result as PairUriResult.Invalid).error)
        // Exactly at the deadline counts as expired.
        assertTrue(PairUri.parse(link(exp = nowS), nowMs) is PairUriResult.Invalid)
    }

    @Test
    fun aMissingOrMalformedPinIsRefused() {
        assertEquals(
            PairUriError.BAD_PIN,
            (PairUri.parse("doorbell://pair?host=10.0.1.10:47172", nowMs)
                as PairUriResult.Invalid).error,
        )
        for (bad in listOf("12345", "1234567", "12345a", "")) {
            val result = PairUri.parse(link(pin = bad), nowMs)
            assertTrue("pin $bad was accepted", result is PairUriResult.Invalid)
        }
    }

    @Test
    fun aMissingOrMalformedHostIsRefused() {
        assertEquals(
            PairUriError.BAD_HOST,
            (PairUri.parse("doorbell://pair?pin=123456", nowMs) as PairUriResult.Invalid).error,
        )
        assertFalse(PairUri.validHost(""))
        assertFalse(PairUri.validHost("10.0.1.10:0"))
        assertFalse(PairUri.validHost("10.0.1.10:70000"))
        assertFalse(PairUri.validHost("10.0.1.10:abc"))
        assertFalse(PairUri.validHost("has space:1"))
        assertTrue(PairUri.validHost("10.0.1.10"))
        assertTrue(PairUri.validHost("10.0.1.10:47172"))
    }

    @Test
    fun anythingThatIsNotAPairLinkIsRejected() {
        for (bad in listOf(
            "", "https://example.com", "doorbell://other?host=a&pin=123456",
            "doorbell://pair", "doorbell-pair:10.0.1.10|id|pk",
        )) {
            val result = PairUri.parse(bad, nowMs)
            assertTrue("$bad was accepted", result is PairUriResult.Invalid)
        }
        assertTrue(PairUri.looksLikePairLink("doorbell://pair?host=a&pin=123456"))
        assertFalse(PairUri.looksLikePairLink("doorbell-pair:x"))
    }

    @Test
    fun aClusterNameSurvivesEncoding() {
        val result = PairUri.parse(link(cluster = "Ann & Bob's 家"), nowMs)
        assertEquals("Ann & Bob's 家", (result as PairUriResult.Ok).invite.cluster)
    }

    @Test
    fun aLinkWithoutAnExpiryNeverExpires() {
        val result = PairUri.parse(link(exp = 0), nowMs)
        val invite = (result as PairUriResult.Ok).invite
        assertEquals(0L, invite.expiresAtS)
        assertFalse(invite.expiredAt(nowMs + 10_000_000L))
    }

    // ---------- core's parser ----------

    @Test
    fun coresAnswerIsAdoptedWhenItHasOne() {
        val ok = JSONObject(
            """{"ok":true,"host":"10.0.1.10:47172","pin":"123456","exp":${nowS + 60},
                "cluster":"家"}""",
        )
        val result = PairUri.fromCore(ok, nowMs)
        assertEquals("10.0.1.10:47172", (result as PairUriResult.Ok).invite.host)
        assertEquals(
            PairUriError.EXPIRED,
            (PairUri.fromCore(JSONObject("""{"ok":false,"err":"expired"}"""), nowMs)
                as PairUriResult.Invalid).error,
        )
        // Null means "this core cannot answer", so the caller uses its own parse.
        assertNull(PairUri.fromCore(null, nowMs))
        assertNull(PairUri.fromCore(JSONObject("""{"ok":false}"""), nowMs))
    }

    @Test
    fun coresAnswerIsStillCheckedForExpiryAndShape() {
        val stale = JSONObject(
            """{"ok":true,"host":"10.0.1.10:47172","pin":"123456","exp":${nowS - 1}}""",
        )
        assertTrue(PairUri.fromCore(stale, nowMs) is PairUriResult.Invalid)
        // A malformed success is not trusted either.
        assertNull(
            PairUri.fromCore(JSONObject("""{"ok":true,"host":"","pin":"123456"}"""), nowMs),
        )
    }

    // ---------- the QR payload ----------

    @Test
    fun thePinCardPrefersCoresLinkAndFallsBackToTheLegacyPayload() {
        val withUri = JSONObject(
            """{"uri":"doorbell://pair?host=a:1&pin=123456","pair_qr":"doorbell-pair:a|b|c"}""",
        )
        assertEquals("doorbell://pair?host=a:1&pin=123456", PairUri.qrPayload(withUri))
        val legacy = JSONObject("""{"pair_qr":"doorbell-pair:a|b|c"}""")
        assertEquals("doorbell-pair:a|b|c", PairUri.qrPayload(legacy))
        assertEquals("", PairUri.qrPayload(JSONObject()))
        assertEquals("", PairUri.qrPayload(null))
    }

    /**
     * db_core_pairing_json carries the link on its token object, not at the top level. Reading
     * only the top level meant the pairing screen never showed core's link at all.
     */
    @Test
    fun thePinCardTakesTheLinkFromCoresTokenObject() {
        val pairing = JSONObject(
            """{"pair_qr":"doorbell-pair:a|b|c",
                "token":{"active":true,"pin":"123456","host":"a:1",
                         "uri":"doorbell://pair?host=a%3A1&pin=123456&cluster=%E6%88%91"}}""",
        )
        assertEquals(
            "doorbell://pair?host=a%3A1&pin=123456&cluster=%E6%88%91",
            PairUri.qrPayload(pairing),
        )
    }

    @Test
    fun aTokenWithoutALinkFallsBackToTheLegacyPayload() {
        // No PIN is active, so core publishes the token without a uri.
        val pairing = JSONObject(
            """{"pair_qr":"doorbell-pair:a|b|c","token":{"active":false}}""",
        )
        assertEquals("doorbell-pair:a|b|c", PairUri.qrPayload(pairing))
        // An explicit JSON null must not become the string "null" on the QR.
        val nulled = JSONObject(
            """{"pair_qr":"doorbell-pair:a|b|c","uri":null,"token":{"uri":null}}""",
        )
        assertEquals("doorbell-pair:a|b|c", PairUri.qrPayload(nulled))
    }

    /** A mint or start-pairing result carries the link at its own top level. */
    @Test
    fun aMintResultCarriesTheLinkAtTheTopLevel() {
        val minted = JSONObject(
            """{"ok":true,"host":"a:1","pin":"123456",
                "uri":"doorbell://pair?host=a%3A1&pin=123456"}""",
        )
        assertEquals("doorbell://pair?host=a%3A1&pin=123456", PairUri.qrPayload(minted))
    }

    // ---------- what the screen does ----------

    @Test
    fun anUnpairedDeviceGoesStraightToTheConfirmButton() {
        val ok = PairUri.parse(link(), nowMs)
        assertEquals(PairLinkAction.CONFIRM, PairLinkPolicy.actionFor(ok, alreadyPaired = false))
    }

    @Test
    fun anAlreadyPairedDeviceIsAskedBeforeLeavingItsCluster() {
        val ok = PairUri.parse(link(), nowMs)
        assertEquals(
            PairLinkAction.CONFIRM_LEAVE_CURRENT,
            PairLinkPolicy.actionFor(ok, alreadyPaired = true),
        )
    }

    @Test
    fun anInvalidLinkIsRejectedWhateverTheDeviceState() {
        val expired = PairUri.parse(link(exp = nowS - 1), nowMs)
        assertEquals(PairLinkAction.REJECT, PairLinkPolicy.actionFor(expired, false))
        assertEquals(PairLinkAction.REJECT, PairLinkPolicy.actionFor(expired, true))
    }

    @Test
    fun everyErrorHasAMessageToShowInline() {
        for (error in PairUriError.values())
            assertTrue(PairLinkPolicy.messageKey(error).startsWith("pair."))
        assertEquals("pair.err.expired", PairLinkPolicy.messageKey(PairUriError.EXPIRED))
    }
}
