package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The optional core exports (spec §5.5): which path each feature takes, the administrator-password
 * states, and the batch document shared with the web admin.
 */
class CoreExportsTest {

    @Test
    fun anOlderCoreOffersNothingAndEveryFeatureFallsBack() {
        assertEquals(CoreExports.NONE, CoreExports.parse(null))
        assertEquals(CoreExports.NONE, CoreExports.parse(JSONObject()))
        assertFalse(CoreExports.NONE.configWrite)
        assertFalse(CoreExports.NONE.complete)
    }

    @Test
    fun theExportProbeIsReadPerFeature() {
        val partial = CoreExports.parse(
            JSONObject(
                """{"config_write":true,"admin_password":false,"call_log_v2":true,
                    "mic_mute":false}""",
            ),
        )
        assertTrue(partial.configWrite)
        assertFalse(partial.adminPassword)
        assertTrue(partial.callLogV2)
        assertFalse(partial.micMute)
        assertFalse(partial.complete)

        val full = CoreExports.parse(
            JSONObject(
                """{"config_write":true,"admin_password":true,"call_log_v2":true,
                    "mic_mute":true}""",
            ),
        )
        assertTrue(full.complete)
    }

    // ---------- administrator password ----------

    @Test
    fun coresVerifyResultsMapToTheGatesStates() {
        assertEquals(AdminPasswordState.OK, AdminPassword.stateOf(1))
        assertEquals(AdminPasswordState.OK, AdminPassword.stateOf(42))
        assertEquals(AdminPasswordState.WRONG, AdminPassword.stateOf(0))
        assertEquals(AdminPasswordState.LOCKED, AdminPassword.stateOf(-1))
        assertEquals(AdminPasswordState.UNSET, AdminPassword.stateOf(-2))
        // Null is "this core has no such export", not "wrong password".
        assertEquals(AdminPasswordState.UNSUPPORTED, AdminPassword.stateOf(null))
        assertEquals(AdminPasswordState.UNSUPPORTED, AdminPassword.stateOf(-100))
    }

    @Test
    fun anUnsetPasswordNeverBlocksClearingARunningAlarm() {
        // cancel_requires_pin only applies once a cluster password exists.
        assertFalse(AdminPassword.alarmClearNeedsPassword(true, AdminPasswordState.UNSET))
        assertTrue(AdminPassword.alarmClearNeedsPassword(true, AdminPasswordState.OK))
        assertTrue(AdminPassword.alarmClearNeedsPassword(true, AdminPasswordState.WRONG))
        // An older core still gates, because the loopback login answers for it.
        assertTrue(AdminPassword.alarmClearNeedsPassword(true, AdminPasswordState.UNSUPPORTED))
    }

    @Test
    fun anAlarmIsNeverGatedWhenTheSettingIsOff() {
        for (state in AdminPasswordState.values())
            assertFalse(AdminPassword.alarmClearNeedsPassword(false, state))
    }

    @Test
    fun aNewPasswordIsRefusedOnlyForBeingEmpty() {
        assertFalse(AdminPassword.newPasswordValid(""))
        assertTrue(AdminPassword.newPasswordValid("a"))
        assertTrue(AdminPassword.newPasswordValid("correct horse battery staple"))
    }

    // ---------- the batch document ----------

    @Test
    fun theBatchDocumentIsTheOneTheWebAdminAlreadySends() {
        val json = JSONObject(
            ConfigOps.build(
                listOf(
                    "time.zone" to "\"Asia/Tokyo\"",
                    "time.ntp.enabled" to "true",
                    "time.ntp.interval_s" to "900",
                    "time.ntp.servers" to """["ntp.nict.jp"]""",
                ),
            ),
        )
        val ops = json.getJSONArray("ops")
        assertEquals(4, ops.length())
        assertEquals("set", ops.getJSONObject(0).getString("op"))
        assertEquals("time.zone", ops.getJSONObject(0).getString("key"))
        // Values stay typed: a string is a string, a bool is a bool, a list is a list.
        assertEquals("Asia/Tokyo", ops.getJSONObject(0).getString("value"))
        assertTrue(ops.getJSONObject(1).getBoolean("value"))
        assertEquals(900, ops.getJSONObject(2).getInt("value"))
        assertTrue(ops.getJSONObject(3).get("value") is JSONArray)
    }

    @Test
    fun anObjectValueSurvivesAsAnObjectAndGarbageStaysAString() {
        assertTrue(ConfigOps.parse("""{"dark_from":"19:00"}""") is JSONObject)
        assertTrue(ConfigOps.parse("""[1,2]""") is JSONArray)
        assertEquals("not json", ConfigOps.parse("not json"))
    }

    @Test
    fun anUnsupportedWriteIsDistinguishedFromARefusedOne() {
        val unsupported = ConfigWriteResult(false, ConfigWriters.ERR_UNSUPPORTED, 0)
        assertTrue(unsupported.unsupported)
        assertFalse(unsupported.unauthorized)

        val refused = ConfigWriteResult(false, "config_rejected", 400)
        assertFalse(refused.unsupported)

        val unauthorized = ConfigWriteResult(false, "", 401)
        assertTrue(unauthorized.unauthorized)
    }

    @Test
    fun anAdvisoryWarningRidesAlongWithASuccessfulWrite() {
        // A colour below the WCAG ratio is saved and the notice is shown, never a rejection.
        val saved = ConfigWriteResult(
            true, warning = "読みにくい可能性があります（3.1:1）", status = 200,
        )
        assertTrue(saved.ok)
        assertEquals("読みにくい可能性があります（3.1:1）", saved.warning)
    }
}
