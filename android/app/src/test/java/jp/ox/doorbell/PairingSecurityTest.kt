package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingSecurityTest {

    @Test
    fun confirmCodesAreEightDigitsAndGroupedForReading() {
        assertTrue(PairingModel.validConfirmCode("01234567"))
        assertFalse(PairingModel.validConfirmCode("1234567"))
        assertFalse(PairingModel.validConfirmCode("1234567a"))
        assertEquals("0123 4567", PairingModel.groupedConfirmCode("01234567"))
        val pairing = JSONObject("""{"self":{"confirm_code":"87654321"}}""")
        assertEquals("87654321", PairingModel.selfConfirmCode(pairing))
        assertEquals("", PairingModel.selfConfirmCode(JSONObject("""{"self":{"confirm_code":"12"}}""")))
        assertEquals("", PairingModel.selfConfirmCode(null))
    }

    @Test
    fun pendingDevicesCarryTheIdentityConflictFlag() {
        val pairing = JSONObject("""{"pending":{"devices":[
            {"id":"aa","pk_conflict":true},{"id":"bb"}]}}""")
        val pending = PairingModel.pending(pairing)
        assertTrue(pending.first { it.id == "aa" }.pkConflict)
        assertFalse(pending.first { it.id == "bb" }.pkConflict)
    }

    @Test
    fun securityStateParsesCountsAndNulls() {
        val pairing = JSONObject("""{"security":{"legacy_peers":["x","y"],"rekey_required":true,
            "psk_id":"k3","prev_psk_id":null,"prev_psk_until_ms":0,"identity_pk":"ab"}}""")
        val security = PairingModel.security(pairing)!!
        assertEquals(2, security.legacyPeers)
        assertTrue(security.rekeyRequired)
        assertEquals("k3", security.pskId)
        assertEquals("", security.prevPskId)
        assertNull(PairingModel.security(JSONObject()))
        assertEquals(4, PairingModel.security(
            JSONObject("""{"security":{"legacy_peers":4}}"""))!!.legacyPeers)
    }

    @Test
    fun upgradeRejoinAcceptsBothDocumentShapes() {
        assertNull(PairingModel.upgradeRejoinReason(JSONObject()))
        assertNull(PairingModel.upgradeRejoinReason(
            JSONObject("""{"upgrade_rejoin_required":false}""")))
        assertEquals("not_founder", PairingModel.upgradeRejoinReason(JSONObject(
            """{"upgrade_rejoin_required":true,"upgrade_rejoin_reason":"not_founder"}""")))
        assertEquals("v2_peer", PairingModel.upgradeRejoinReason(JSONObject(
            """{"upgrade_rejoin_required":{"reason":"v2_peer"}}""")))
        assertEquals("upgrade_rejoin_required", PairingModel.upgradeRejoinReason(
            JSONObject("""{"upgrade_rejoin_required":true}""")))
    }

    @Test
    fun newPairingErrorsHaveTheirOwnMessages() {
        for (code in listOf("confirm_code_required", "confirm_code_mismatch", "pk_conflict",
                            "protocol_upgrade_required"))
            assertEquals("pair.err.$code", PairingModel.errorKey(code))
    }
}
