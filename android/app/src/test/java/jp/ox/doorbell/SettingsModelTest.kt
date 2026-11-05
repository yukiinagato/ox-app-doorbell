package jp.ox.doorbell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsModelTest {

    @Test
    fun everyCategoryHasAUniqueIdAndResolvesById() {
        val ids = SettingsCategory.values().map { it.id }
        assertEquals(ids.size, ids.toSet().size)
        for (category in SettingsCategory.values())
            assertEquals(category, SettingsCategory.byId(category.id))
        assertNull(SettingsCategory.byId("missing"))
        assertNull(SettingsCategory.byId(null))
    }

    @Test
    fun specKeysAreUniqueWithinEachCategoryAndNodeKeysResolve() {
        for (role in listOf("indoor_panel", "door_station")) for (category in SettingsCategory.values()) {
            val keys = SettingsModel.specs(category, role).map { it.key }
            assertEquals("$category/$role", keys.size, keys.toSet().size)
        }
        assertEquals("devices.abc.local.ui_lang",
                     SettingsModel.resolve("devices.{node}.local.ui_lang", "abc"))
        assertEquals("sip.accounts.n1.user", SettingsModel.resolve("sip.accounts.{node}.user", "n1"))
    }

    @Test
    fun roleSpecificDeviceSettingsFollowTheRole() {
        val door = SettingsModel.specs(SettingsCategory.DEVICE, "door_station").map { it.key }
        val indoor = SettingsModel.specs(SettingsCategory.DEVICE, "indoor_panel").map { it.key }
        assertTrue("devices.{node}.local.motion.wake_screen" in door)
        assertFalse("devices.{node}.local.call.return_s" in door)
        assertTrue("devices.{node}.local.call.return_s" in indoor)
        val answer = SettingsModel.specs(SettingsCategory.SIP, "door_station")
            .filterIsInstance<SettingSpec.Choice>().first { it.key.endsWith("answer_mode") }
        assertEquals("auto", answer.default)
    }

    @Test
    fun defaultsLieInsideTheirRangesAndOptions() {
        for (category in SettingsCategory.values()) for (spec in SettingsModel.specs(category, "indoor_panel")) {
            when (spec) {
                is SettingSpec.IntRange -> assertTrue(spec.key, spec.default in spec.min..spec.max)
                is SettingSpec.Choice -> assertTrue(spec.key, spec.default in spec.options)
                is SettingSpec.MultiChoice -> assertTrue(spec.key, spec.options.containsAll(spec.default))
                is SettingSpec.Time -> assertNotNull(spec.key, SettingsModel.normalizeTime(spec.default))
                else -> Unit
            }
        }
    }

    @Test
    fun integersAreRangeChecked() {
        val spec = SettingSpec.IntRange("display.brightness", "t", 0, 100, 70)
        assertEquals("0", SettingsModel.encodeInt(spec, "0"))
        assertEquals("100", SettingsModel.encodeInt(spec, " 100 "))
        assertNull(SettingsModel.encodeInt(spec, "101"))
        assertNull(SettingsModel.encodeInt(spec, "-1"))
        assertNull(SettingsModel.encodeInt(spec, "seven"))
    }

    @Test
    fun choicesEncodeStringsOrNumbersAndRejectUnknownOptions() {
        val sound = SettingSpec.Choice("ui.call_sound", "t", listOf("outdoor_call_alert", ""),
                                       "outdoor_call_alert", "settings.sound_")
        assertEquals("\"outdoor_call_alert\"", SettingsModel.encodeChoice(sound, "outdoor_call_alert"))
        assertEquals("\"\"", SettingsModel.encodeChoice(sound, ""))
        assertNull(SettingsModel.encodeChoice(sound, "siren"))
        val rotation = SettingSpec.Choice("r", "t", listOf("0", "90"), "0", "p", numeric = true)
        assertEquals("90", SettingsModel.encodeChoice(rotation, "90"))
    }

    @Test
    fun multiChoiceKeepsOptionOrderAndHonoursTheMinimum() {
        val languages = SettingSpec.MultiChoice("ui.languages", "t", listOf("ja", "en", "zh"),
                                                listOf("ja"), "lang.")
        assertEquals("[\"ja\",\"zh\"]", SettingsModel.encodeMulti(languages, listOf("zh", "ja")))
        assertNull(SettingsModel.encodeMulti(languages, emptyList()))
        val roles = SettingSpec.MultiChoice("emergency.button_on_roles", "t",
                                            SettingsModel.ROLES, listOf(), "r", minSelected = 0)
        assertEquals("[]", SettingsModel.encodeMulti(roles, emptyList()))
    }

    @Test
    fun timesAreValidatedAndNormalised() {
        assertEquals("06:05", SettingsModel.normalizeTime("6:05"))
        assertEquals("23:59", SettingsModel.normalizeTime("23:59"))
        assertNull(SettingsModel.normalizeTime("24:00"))
        assertNull(SettingsModel.normalizeTime("12:60"))
        assertNull(SettingsModel.normalizeTime("noon"))
        assertEquals("\"22:00\"", SettingsModel.encodeTime("22:00"))
    }

    @Test
    fun textKindsAreValidated() {
        assertEquals("\"pbx.local\"", SettingsModel.encodeText(TextKind.HOST, "pbx.local"))
        assertEquals("\"10.0.1.5\"", SettingsModel.encodeText(TextKind.HOST, "10.0.1.5"))
        assertEquals("\"fd00::5\"", SettingsModel.encodeText(TextKind.HOST, "fd00::5"))
        assertEquals("\"\"", SettingsModel.encodeText(TextKind.HOST, " "))
        assertNull(SettingsModel.encodeText(TextKind.HOST, "bad host"))
        assertNull(SettingsModel.encodeText(TextKind.HOST, "-x.local"))
        assertEquals("\"201\"", SettingsModel.encodeText(TextKind.EXTENSION, "201"))
        assertNull(SettingsModel.encodeText(TextKind.EXTENSION, "20 1"))
        assertEquals("\"unlock_1\"", SettingsModel.encodeText(TextKind.UNLOCK_COMMAND, "unlock_1"))
        assertNull(SettingsModel.encodeText(TextKind.UNLOCK_COMMAND, "a".repeat(33)))
        assertNull(SettingsModel.encodeText(TextKind.LABEL, "x".repeat(65)))
    }

    @Test
    fun currentValuesAreReadFromTheConfigTree() {
        val config = JSONObject("""{"ui":{"call_flow":"ring_then_purpose","languages":["en"]},
            "display":{"brightness":40,"night":{"enabled":false}},"sip":{"server":null}}""")
        assertEquals("ring_then_purpose",
                     SettingsModel.currentString(config, "ui.call_flow", "purpose_first"))
        assertEquals(40, SettingsModel.currentInt(config, "display.brightness", 70))
        assertFalse(SettingsModel.currentBool(config, "display.night.enabled", true))
        assertEquals(listOf("en"), SettingsModel.currentList(config, "ui.languages", listOf("ja")))
        assertEquals("fallback", SettingsModel.currentString(config, "sip.server", "fallback"))
        assertEquals(7, SettingsModel.currentInt(null, "x.y", 7))
    }

    @Test
    fun doorLabelsSetFilledLanguagesAndDeleteBlankOnes() {
        val ops = SettingsModel.doorLabelOps("d_front", mapOf("ja" to " 正面 ", "en" to "", "zh" to "正门"))
        assertEquals(ConfigOp.Set("doors.d_front.label.ja", "\"正面\""), ops[0])
        assertEquals(ConfigOp.Delete("doors.d_front.label.en"), ops[1])
        assertEquals(ConfigOp.Set("doors.d_front.label.zh", "\"正门\""), ops[2])
    }

    @Test
    fun quickRepliesNeedOneLabelAndGetFreshIdsAndOrders() {
        assertNull(SettingsModel.quickReplyJson(mapOf("ja" to " "), true, 10))
        val json = JSONObject(SettingsModel.quickReplyJson(mapOf("en" to "Wait"), false, 20)!!)
        assertEquals("Wait", json.getJSONObject("label").getString("en"))
        assertFalse(json.getJSONObject("label").has("ja"))
        assertFalse(json.getBoolean("speak"))
        assertEquals(20, json.getInt("order"))
        val id = SettingsModel.nextQuickReplyId(listOf("qr_000001"), 1L)
        assertEquals("qr_000002", id)
        val replies = JSONObject("""{"a":{"order":3},"b":{"order":40}}""")
        assertEquals(50, SettingsModel.nextQuickReplyOrder(replies))
        assertEquals(10, SettingsModel.nextQuickReplyOrder(null))
    }

    @Test
    fun quietHoursAreOneObject() {
        assertEquals(JSONObject().put("from", "22:00").put("to", "07:00").toString(),
                     SettingsModel.quietHoursJson("22:00", "7:00"))
        assertNull(SettingsModel.quietHoursJson("25:00", "07:00"))
    }

    @Test
    fun newPasswordsFollowTheV3Policy() {
        assertEquals(PasswordCheck.TOO_SHORT, SettingsModel.checkNewPassword("1234567", "1234567"))
        assertEquals(PasswordCheck.MISMATCH, SettingsModel.checkNewPassword("12345678", "12345679"))
        assertEquals(PasswordCheck.TOO_LONG,
                     SettingsModel.checkNewPassword("x".repeat(129), "x".repeat(129)))
        assertEquals(PasswordCheck.OK, SettingsModel.checkNewPassword("12345678", "12345678"))
    }

    @Test
    fun twoPaneFollowsTheTabletBreakpoints() {
        assertFalse(SettingsModel.twoPane(360, 360, false))
        assertFalse(SettingsModel.twoPane(411, 891, false))
        assertFalse(SettingsModel.twoPane(411, 700, true))
        assertFalse(SettingsModel.twoPane(411, 891, true))
        assertTrue(SettingsModel.twoPane(552, 960, true))
        assertFalse(SettingsModel.twoPane(552, 552, false))
        assertTrue(SettingsModel.twoPane(600, 600, false))
        assertTrue(SettingsModel.twoPane(800, 1280, true))
    }

    @Test
    fun batchDocumentsCarrySetsAndDeletes() {
        val doc = JSONObject(ConfigOps.buildOps(listOf(
            ConfigOp.Set("display.brightness", "40"),
            ConfigOp.Delete("notify.quiet_hours"),
        )))
        val ops = doc.getJSONArray("ops")
        assertEquals("set", ops.getJSONObject(0).getString("op"))
        assertEquals(40, ops.getJSONObject(0).getInt("value"))
        assertEquals("delete", ops.getJSONObject(1).getString("op"))
        assertFalse(ops.getJSONObject(1).has("value"))
    }
}
