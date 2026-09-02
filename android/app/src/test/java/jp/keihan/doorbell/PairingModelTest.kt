package jp.keihan.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingModelTest {

    private fun snapshot(json: String) = JSONObject(json)

    @Test
    fun theDeclaredStateIsAuthoritativeAndNeverInferred() {
        assertEquals(
            PairingModel.JOINING,
            PairingModel.state(snapshot("""{"state":"joining","paired":true,
                "persistence_ready":true}""")),
        )
        assertEquals(
            PairingModel.PERSIST_ERROR,
            PairingModel.state(snapshot("""{"state":"persist_error","paired":true}""")),
        )
        assertEquals(PairingModel.UNPAIRED, PairingModel.state(null))
    }

    @Test
    fun aSnapshotFromAnOlderCoreStillProducesAUsableState() {
        assertEquals(
            PairingModel.READY,
            PairingModel.state(snapshot("""{"paired":true,"persistence_ready":true}""")),
        )
        assertEquals(
            PairingModel.PERSIST_ERROR,
            PairingModel.state(snapshot("""{"paired":true,"persistence_ready":false}""")),
        )
        assertEquals(PairingModel.UNPAIRED, PairingModel.state(snapshot("{}")))
    }

    @Test
    fun onlyReadyKeepsTheMainUiVisible() {
        assertTrue(PairingModel.isOnboarding(PairingModel.UNPAIRED))
        assertTrue(PairingModel.isOnboarding(PairingModel.JOINING))
        assertTrue(PairingModel.isOnboarding(PairingModel.PERSIST_ERROR))
        assertTrue(PairingModel.isOnboarding(PairingModel.REVOKED))
        assertFalse(PairingModel.isOnboarding(PairingModel.READY))
    }

    @Test
    fun pendingDevicesCarryTheCardFieldsAndNeverRenderBlank() {
        val devices = PairingModel.pending(
            snapshot(
                """{"pending":{"devices":[
                  {"id":"abcdef012345","addr":"10.0.1.9:47172","name":"玄関",
                   "role":"door_station","model":"Moto G","platform":"android","sw":"0.3.0",
                   "age_s":7,"invite_state":"sent","attempts":1,"last_error":""},
                  {"id":"ffeeddccbbaa","name":"","model":"Pixel 4a","role":"indoor_panel",
                   "platform":"android","sw":"0.3.0","age_s":2,"invite_state":"none"},
                  {"name":"no id at all"}
                ]}}""",
            ),
        )
        assertEquals(2, devices.size)
        assertEquals("玄関", devices[0].displayName())
        assertEquals("door_station · Moto G · android · 0.3.0", devices[0].detail())
        assertEquals(7, devices[0].ageSeconds)
        assertEquals("sent", devices[0].inviteState)
        // No human name: fall back to model plus a short identifier, never an empty row.
        assertEquals("Pixel 4a (ffeedd)", devices[1].displayName())
    }

    @Test
    fun theTokenExposesThePinOnlyWhileItIsLive() {
        val live = PairingModel.token(
            snapshot(
                """{"token":{"active":true,"expires_s":125,"attempts_left":2,
                   "host":"10.0.1.5:47172","pin":"418205"}}""",
            ),
        )
        assertTrue(live.active)
        assertEquals("418205", live.pin)
        assertEquals("10.0.1.5:47172", live.host)
        assertEquals(2, live.attemptsLeft)
        assertEquals("2", PairingModel.minutes(live.expiresSeconds))
        assertEquals("05", PairingModel.seconds(live.expiresSeconds))

        val expired = PairingModel.token(
            snapshot("""{"token":{"active":true,"expires_s":0,"pin":"418205"}}"""),
        )
        assertFalse(expired.active)
        assertEquals("", expired.pin)
        assertEquals(PairingModel.Token(false, 0, 0, "", ""), PairingModel.token(snapshot("{}")))
    }

    @Test
    fun bulkAddCarriesTheCountdownAndTheCount() {
        val bulk = PairingModel.bulkAdd(
            snapshot(
                """{"pending":{"pairing_mode":true,"pairing_mode_left_s":63,
                   "auto_added_count":3}}""",
            ),
        )
        assertTrue(bulk.active)
        assertEquals(63, bulk.leftSeconds)
        assertEquals(3, bulk.addedCount)
        assertEquals("1", PairingModel.minutes(bulk.leftSeconds))
        assertEquals("03", PairingModel.seconds(bulk.leftSeconds))
        assertFalse(PairingModel.bulkAdd(snapshot("{}")).active)
    }

    @Test
    fun membershipCountsAreReadFromHomeAndClampedAtZero() {
        val p = snapshot("""{"home":{"member_count":3,"connected_count":2},"is_founder":true}""")
        assertEquals(3, PairingModel.memberCount(p))
        assertEquals(2, PairingModel.connectedCount(p))
        assertTrue(PairingModel.isFounder(p))
        assertEquals(0, PairingModel.memberCount(snapshot("""{"home":{"member_count":-4}}""")))
        assertFalse(PairingModel.isFounder(snapshot("{}")))
    }

    @Test
    fun everyDocumentedErrorCodeHasItsOwnHumanMessageAndKey() {
        val documented = listOf(
            "bad_pin", "expired", "no_token", "host_unpaired", "connect_failed", "timeout",
            "closed", "join_in_progress", "already_paired", "decrypt_failed", "bad_payload",
            "bad_challenge", "local_persist_failed", "persist_failed", "host_zero_psk", "no_ack",
        )
        for (code in documented) {
            assertEquals("pair.err.$code", PairingModel.errorKey(code))
            assertTrue(
                "no message resource for $code",
                PairingModel.errorResource(code) != R.string.pair_err_unknown,
            )
        }
        // An unknown or empty code still produces a human message, never a raw code.
        assertEquals("pair.err.unknown", PairingModel.errorKey("something_new"))
        assertEquals(R.string.pair_err_unknown, PairingModel.errorResource(""))
    }

    @Test
    fun onlyACompleteAddQrPayloadIsAccepted() {
        assertTrue(PairingModel.isPairQr("doorbell-pair:10.0.1.9:47172|abcdef|0011aa"))
        assertFalse(PairingModel.isPairQr("doorbell-join:10.0.1.9:47172|abcdef|0011aa"))
        assertFalse(PairingModel.isPairQr("doorbell-pair:10.0.1.9:47172|abcdef|"))
        assertFalse(PairingModel.isPairQr("doorbell-pair:onlyaddress"))
        assertFalse(PairingModel.isPairQr(""))
    }
}
