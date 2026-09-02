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
        // -3 is a malformed call and proves nothing about the cluster password.
        assertEquals(AdminPasswordState.UNSUPPORTED, AdminPassword.stateOf(-3))
        // Null is "this core has no such export", not "wrong password".
        assertEquals(AdminPasswordState.UNSUPPORTED, AdminPassword.stateOf(null))
        assertEquals(AdminPasswordState.UNSUPPORTED, AdminPassword.stateOf(-100))
    }

    @Test
    fun anUnsetPasswordNeverBlocksClearingARunningAlarm() {
        // Core folds "cancel_requires_pin AND a password exists" into one published answer.
        val gated = JSONObject(
            """{"emergency":{"cancel_requires_password":true,"cancel_requires_pin":true,
                             "admin_password_set":true}}""",
        )
        val unset = JSONObject(
            """{"emergency":{"cancel_requires_password":false,"cancel_requires_pin":true,
                             "admin_password_set":false}}""",
        )
        assertTrue(AdminPassword.alarmClearNeedsPassword(gated))
        assertFalse(AdminPassword.alarmClearNeedsPassword(unset))
    }

    @Test
    fun anOlderCoreAppliesTheSameConjunctionRatherThanTheFlagAlone() {
        val requiresPinButNoPassword = JSONObject(
            """{"emergency":{"cancel_requires_pin":true,"admin_password_set":false}}""",
        )
        val requiresPinWithPassword = JSONObject(
            """{"emergency":{"cancel_requires_pin":true,"admin_password_set":true}}""",
        )
        assertFalse(AdminPassword.alarmClearNeedsPassword(requiresPinButNoPassword))
        assertTrue(AdminPassword.alarmClearNeedsPassword(requiresPinWithPassword))
    }

    @Test
    fun anAlarmIsNeverGatedWithoutTheSettingOrWithoutAStatus() {
        assertFalse(AdminPassword.alarmClearNeedsPassword(null))
        assertFalse(AdminPassword.alarmClearNeedsPassword(JSONObject()))
        assertFalse(
            AdminPassword.alarmClearNeedsPassword(
                JSONObject("""{"emergency":{"cancel_requires_pin":false}}"""),
            ),
        )
    }

    @Test
    fun whetherTheClusterHasAPasswordIsReadFromStatus() {
        assertTrue(
            AdminPassword.passwordSet(
                JSONObject("""{"emergency":{"admin_password_set":true}}"""),
            ),
        )
        assertFalse(
            AdminPassword.passwordSet(
                JSONObject("""{"emergency":{"admin_password_set":false}}"""),
            ),
        )
        assertFalse(AdminPassword.passwordSet(null))
    }

    @Test
    fun aNewPasswordMustMatchCoresLengthRule() {
        assertFalse(AdminPassword.newPasswordValid(""))
        assertFalse(AdminPassword.newPasswordValid("abc"))
        assertTrue(AdminPassword.newPasswordValid("abcd"))
        assertTrue(AdminPassword.newPasswordValid("x".repeat(AdminPassword.MAX_LENGTH)))
        assertFalse(AdminPassword.newPasswordValid("x".repeat(AdminPassword.MAX_LENGTH + 1)))
    }

    @Test
    fun theLegacyDigestIsRetiredOnlyOnceCoreAnswersAuthoritatively() {
        // An accepted password and a lockout both prove core owns the cluster secret.
        assertTrue(AdminPassword.retiresLocalDigest(AdminPasswordState.OK))
        assertTrue(AdminPassword.retiresLocalDigest(AdminPasswordState.LOCKED))
        // These do not, so the device keeps its only way in.
        assertFalse(AdminPassword.retiresLocalDigest(AdminPasswordState.WRONG))
        assertFalse(AdminPassword.retiresLocalDigest(AdminPasswordState.UNSET))
        assertFalse(AdminPassword.retiresLocalDigest(AdminPasswordState.UNSUPPORTED))
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
    fun theUnlockSettingIsThreeWayWithAbsenceMeaningAutomatic() {
        // source "default" is the absence of doors.<id>.unlock.show_button.
        assertEquals(
            UnlockVisibility.AUTO,
            DoorUnlocks.visibilityOf(DoorUnlock(configured = true, showButton = true,
                                                source = "default")),
        )
        assertEquals(
            UnlockVisibility.SHOW,
            DoorUnlocks.visibilityOf(DoorUnlock(configured = false, showButton = true,
                                                source = "admin")),
        )
        assertEquals(
            UnlockVisibility.HIDE,
            DoorUnlocks.visibilityOf(DoorUnlock(configured = true, showButton = false,
                                                source = "admin")),
        )
        assertEquals(UnlockVisibility.AUTO, DoorUnlocks.visibilityOf(DoorUnlock.UNKNOWN))
    }

    @Test
    fun anAdvisoryWarningRidesAlongWithASuccessfulWrite() {
        // A colour below the WCAG ratio is saved and the measured ratio is shown, not a rejection.
        val warnings = JSONArray().put(
            JSONObject()
                .put("key", "display.theme.call_button_bg")
                .put("property", "foreground")
                .put("contrast", 3.14)
                .put("message_key", "theme.low_contrast"),
        )
        val saved = ConfigWriteResult(true, status = 200, warnings = warnings)
        assertTrue(saved.ok)
        val warning = saved.warning!!
        assertEquals("display.theme.call_button_bg", warning.key)
        assertEquals("foreground", warning.property)
        assertEquals("theme.low_contrast", warning.messageKey)
        assertEquals("3.1", warning.ratioText())
    }

    @Test
    fun aWriteWithoutWarningsHasNoAdvisory() {
        assertEquals(null, ConfigWriteResult(true, status = 200).warning)
        assertEquals(null, ConfigWriteResult(true, status = 200, warnings = JSONArray()).warning)
        assertTrue(WriteWarnings.parse(null).isEmpty())
    }

    @Test
    fun everyWarningIsParsedAndAnUnknownMessageKeyStillRenders() {
        val warnings = JSONArray()
            .put(JSONObject().put("key", "a").put("contrast", 2.0)
                     .put("message_key", "theme.low_contrast"))
            .put(JSONObject().put("key", "b").put("contrast", 4.4))
            .put(JSONObject().put("key", "c").put("contrast", 1.5)
                     .put("message_key", "theme.something_new"))
        val parsed = WriteWarnings.parse(warnings)
        assertEquals(3, parsed.size)
        // An entry without message_key falls back to the documented low-contrast advisory.
        assertEquals(WriteWarnings.LOW_CONTRAST, parsed[1].messageKey)
        assertEquals("4.4", parsed[1].ratioText())
        // An unknown key from a newer core still produces a rendered sentence.
        assertEquals(
            "theme.something_new@1.5",
            WriteWarnings.message(parsed[2]) { key, ratio -> "$key@$ratio" },
        )
        assertEquals("", WriteWarnings.message(null) { _, _ -> "unused" })
    }
}
