package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeSettingsModelTest {

    // ---------- secret references ----------

    @Test
    fun secretReferencesPointAtTheStoreKeyAndNeverCarryTheValue() {
        assertEquals("secret:sip.n1", SecretRefs.ref(SecretRefs.sipName("n1")))
        assertEquals("tg_bot", SecretRefs.storeKey("secret:tg_bot"))
        assertNull(SecretRefs.storeKey("tg_bot"))
        assertNull(SecretRefs.storeKey("secret:bad name"))
        val ops = SecretRefs.assignOps("integrations.mqtt.pass_ref", SecretRefs.MQTT)
        assertEquals(listOf(ConfigOp.Set("integrations.mqtt.pass_ref", "\"secret:mqtt\"")), ops)
        val doc = JSONObject(ConfigOps.buildOps(ops))
        assertEquals("secret:mqtt", doc.getJSONArray("ops").getJSONObject(0).getString("value"))
        assertFalse(SecretRefs.validName(""))
        assertFalse(SecretRefs.validName("a/b"))
    }

    // ---------- ordered lists (quick replies, purposes) ----------

    private val replies = JSONObject("""{
        "qr_a":{"label":{"ja":"A"},"order":1},
        "qr_b":{"label":{"ja":"B"},"order":2},
        "qr_c":{"label":{"ja":"C"},"order":30}}""")

    @Test
    fun movingAReplyRenumbersOnlyWhatChanged() {
        val ops = OrderedEntries.moveOps("quick_replies", replies, "qr_c", -1)
        assertEquals(listOf(ConfigOp.Set("quick_replies.qr_c.order", "2"),
                            ConfigOp.Set("quick_replies.qr_b.order", "3")), ops)
        assertTrue(OrderedEntries.moveOps("quick_replies", replies, "qr_a", -1).isEmpty())
        assertTrue(OrderedEntries.moveOps("quick_replies", replies, "missing", 1).isEmpty())
        assertEquals(listOf("qr_a", "qr_b", "qr_c"), OrderedEntries.sorted(replies))
    }

    @Test
    fun quickReplyJsonKeepsOnlyFilledLanguages() {
        val json = JSONObject(SettingsModel.quickReplyJson(mapOf("ja" to " 留守 ", "en" to ""), true, 4)!!)
        assertEquals("留守", json.getJSONObject("label").getString("ja"))
        assertFalse(json.getJSONObject("label").has("en"))
        assertNull(SettingsModel.quickReplyJson(mapOf("ja" to " "), true, 1))
    }

    @Test
    fun purposesCarryIconOrderAndEnabled() {
        val json = JSONObject(PurposeModel.json(mapOf("ja" to "宅配", "en" to "Parcel"), "📦", 7, false)!!)
        assertEquals(7, json.getInt("order"))
        assertFalse(json.getBoolean("enabled"))
        assertEquals("📦", json.getString("icon"))
        assertNull(PurposeModel.json(mapOf("ja" to ""), "", 1, true))
        assertNull(PurposeModel.json(mapOf("ja" to "x"), "123456789", 1, true))
        assertEquals(31, PurposeModel.nextOrder(replies))
    }

    @Test
    fun freshIdsNeverCollide() {
        val first = ConfigIds.next("d", emptyList(), 0x10)
        assertEquals("d_000010", first)
        assertEquals("d_000011", ConfigIds.next("d", listOf(first), 0x10))
        assertTrue(ConfigIds.valid(first))
        assertFalse(ConfigIds.valid("Bad-Id"))
    }

    // ---------- notice presets ----------

    @Test
    fun noticePresetsAreBoundedAndWrittenAsOneArray() {
        val list = listOf("np_1" to "Side gate", "np_2" to " Back soon ")
        val arr = JSONArray(NoticePresetsModel.json(list)!!)
        assertEquals("Back soon", arr.getJSONObject(1).getString("text"))
        assertNull(NoticePresetsModel.json((1..9).map { "p$it" to "x" }))
        assertNull(NoticePresetsModel.json(listOf("p" to "")))
        val cfg = JSONObject().put("notice", JSONObject().put("presets", arr))
        assertEquals(list.map { it.first }, NoticePresetsModel.read(cfg).map { it.first })
    }

    // ---------- quiet hours ----------

    @Test
    fun quietHoursUseTheKeyTheRuleEngineReadsAndRetireTheLegacyOne() {
        val cfg = JSONObject("""{"notify":{"quiet_hours":{"from":"22:00","to":"07:00"}},
            "quiet_hours":{"default":{"windows":[{"from":"23:00","to":"07:00","days":["sat"]}],
            "suppress":["chime"],"extra":1}}}""")
        val state = QuietHoursModel.read(cfg)
        assertEquals(listOf(QuietHoursModel.Window("23:00", "07:00", listOf("sat"))), state.windows)
        // An edit of the times carries the window's own day filter with it.
        val edited = state.windows[0].copy(from = "21:30", to = "24:00")
            .also { it.source = state.windows[0].source }
        val ops = QuietHoursModel.ops(state.copy(windows = listOf(edited)),
                                      cfg.getJSONObject("quiet_hours").getJSONObject("default"), cfg)!!
        val set = ops[0] as ConfigOp.Set
        assertEquals(QuietHoursModel.KEY, set.key)
        val value = JSONObject(set.valueJson)
        assertEquals(1, value.getInt("extra"))
        val window = value.getJSONArray("windows").getJSONObject(0)
        assertEquals("21:30", window.getString("from"))
        assertEquals("24:00", window.getString("to"))
        assertEquals("sat", window.getJSONArray("days").getString(0))
        assertEquals(ConfigOp.Delete(QuietHoursModel.LEGACY_KEY), ops[1])
        assertNull(QuietHoursModel.ops(state.copy(windows = listOf(QuietHoursModel.Window("25:00", "07:00"))), null, cfg))
    }

    @Test
    fun quietHoursKeepEachWindowsDaysThroughEditsAndDeletes() {
        val cfg = JSONObject("""{"quiet_hours":{"default":{"windows":[
            {"from":"22:00","to":"06:00","days":["sat","sun"],"note":"weekend"},
            {"from":"13:00","to":"14:00"}]}}}""")
        val original = cfg.getJSONObject("quiet_hours").getJSONObject("default")
        val state = QuietHoursModel.read(cfg)
        assertEquals(listOf("sat", "sun"), state.windows[0].days)
        assertNull(state.windows[1].days)
        fun windows(next: QuietHoursModel.State) = JSONObject(
            (QuietHoursModel.ops(next, original, cfg)!![0] as ConfigOp.Set).valueJson,
        ).getJSONArray("windows")
        // Deleting the first window must not hand its day filter to the one that moves up.
        val afterDelete = windows(state.copy(windows = state.windows.drop(1)))
        assertEquals(1, afterDelete.length())
        assertEquals("13:00", afterDelete.getJSONObject(0).getString("from"))
        assertFalse(afterDelete.getJSONObject(0).has("days"))
        assertFalse(afterDelete.getJSONObject(0).has("note"))
        // Editing the days writes the edited days and keeps the window's other stored fields.
        val edited = QuietHoursModel.Window("22:00", "06:00", listOf("fri")).also {
            it.source = state.windows[0].source
        }
        val afterEdit = windows(state.copy(windows = listOf(edited, state.windows[1])))
        assertEquals("[\"fri\"]", afterEdit.getJSONObject(0).getJSONArray("days").toString())
        assertEquals("weekend", afterEdit.getJSONObject(0).getString("note"))
        // Every day selected clears the filter.
        val everyDay = QuietHoursModel.Window("22:00", "06:00", null).also {
            it.source = state.windows[0].source
        }
        assertFalse(windows(state.copy(windows = listOf(everyDay))).getJSONObject(0).has("days"))
    }

    // ---------- trigger rules ----------

    @Test
    fun ruleEditorPreservesFieldsItDoesNotShow() {
        val original = JSONObject("""{"enabled":true,"name":"Front",
            "when":{"type":"button","doors":["d_front"],"vendor_match":["x"]},
            "schedule":{"always":true},
            "actions":[{"type":"device_alert","presentation":{"sticky":true}},{"type":"ha_event"}]}""")
        val draft = RuleEditorModel.normalize(original)
        assertEquals(listOf("d_front"), draft.doors)
        val merged = RuleEditorModel.merge(original, draft.copy(enabled = false))
        assertFalse(merged.getBoolean("enabled"))
        assertEquals("Front", merged.getString("name"))
        assertEquals("x", merged.getJSONObject("when").getJSONArray("vendor_match").getString(0))
        assertTrue(merged.getJSONArray("actions").getJSONObject(0).getJSONObject("presentation").getBoolean("sticky"))
    }

    @Test
    fun ruleEditorClearsDoorsAndSwitchesToWindows() {
        val original = JSONObject("""{"when":{"type":"motion","doors":["d1"]},"actions":[{"type":"chime"}]}""")
        val window = JSONObject().put("from", "22:00").put("to", "06:00")
        val merged = RuleEditorModel.merge(original, RuleEditorModel.normalize(original)
            .copy(doors = emptyList(), always = false, windows = listOf(window)))
        assertFalse(merged.getJSONObject("when").has("doors"))
        assertFalse(merged.getJSONObject("schedule").has("always"))
        assertEquals("22:00", merged.getJSONObject("schedule").getJSONArray("windows").getJSONObject(0).getString("from"))
    }

    @Test
    fun ruleEditorWritesPurposesAndOfflineDevices() {
        val created = RuleEditorModel.merge(null, RuleEditorModel.newRule().copy(purposes = listOf("p_delivery")))
        assertEquals("button", created.getJSONObject("when").getString("type"))
        assertEquals("p_delivery", created.getJSONObject("when").getJSONArray("purposes").getString(0))
        assertTrue(created.getJSONObject("schedule").getBoolean("always"))
        val offline = RuleEditorModel.merge(null, RuleEditorModel.newRule().copy(whenType = "device_offline"))
        assertEquals("all", offline.getJSONObject("when").getString("devices"))
        val ops = RuleEditorModel.ops("r9", null, RuleEditorModel.newRule())
        assertEquals("trigger_rules.r9", ops.single().key)
    }

    @Test
    fun ruleEditorValidatesBeforeWriting() {
        val draft = RuleEditorModel.newRule()
        assertTrue(RuleEditorModel.validate(draft).isEmpty())
        assertEquals(listOf("actions_required"), RuleEditorModel.validate(draft.copy(actions = emptyList())))
        assertEquals(listOf("windows_required"), RuleEditorModel.validate(draft.copy(always = false)))
        val sip = RuleEditorModel.defaultAction("sip_call", "button")
        assertEquals(listOf("sip_target"), RuleEditorModel.validate(draft.copy(actions = listOf(sip))))
        val alert = RuleEditorModel.defaultAction("device_alert", "emergency_on")
        assertTrue(alert.getJSONObject("presentation").getBoolean("sticky"))
    }

    @Test
    fun jsonEqualityIgnoresKeyOrder() {
        assertTrue(JsonSame.equal(JSONObject("""{"a":1,"b":[1,{"c":2}]}"""), JSONObject("""{"b":[1,{"c":2}],"a":1.0}""")))
        assertFalse(JsonSame.equal(JSONObject("""{"a":1}"""), JSONObject("""{"a":2}""")))
    }

    // ---------- SIP DTMF ----------

    @Test
    fun dtmfCodesAndActionsMatchCoreValidation() {
        assertTrue(DtmfModel.validCode("#21"))
        assertTrue(DtmfModel.validCode("*0A"))
        assertFalse(DtmfModel.validCode(""))
        assertFalse(DtmfModel.validCode("123456789"))
        assertFalse(DtmfModel.validCode("x"))
        assertEquals("""{"type":"hangup"}""", DtmfModel.actionJson("hangup", "", "", ""))
        val ha = JSONObject(DtmfModel.actionJson("ha_command", " unlock ", "", "")!!)
        assertEquals("unlock", ha.getString("command"))
        assertEquals("self", ha.getString("door"))
        assertNull(DtmfModel.actionJson("ha_command", "bad cmd", "self", ""))
        assertNull(DtmfModel.actionJson("quick_reply", "", "", ""))
        assertEquals("qr_a", JSONObject(DtmfModel.actionJson("quick_reply", "", "", "qr_a")!!).getString("reply_id"))
    }

    // ---------- households, cameras, panels ----------

    @Test
    fun householdsParseChatIdsAndExtensions() {
        assertEquals(listOf(123L, -100200L), HouseholdModel.parseChatIds("123, -100200"))
        assertNull(HouseholdModel.parseChatIds("12a"))
        assertEquals(listOf("201", "202"), HouseholdModel.parseExtensions("201\n202"))
        assertNull(HouseholdModel.parseExtensions("20 1;"))
        val json = JSONObject(HouseholdModel.json(JSONObject().put("x", 1), mapOf("ja" to "家"), listOf(1L), listOf("201"))!!)
        assertEquals(1, json.getInt("x"))
        assertEquals(1L, json.getJSONArray("telegram_chat_ids").getLong(0))
    }

    @Test
    fun mediaSourcesRefuseUserinfoAndUseASecretReference() {
        val draft = MediaSourceModel.Draft("http://192.0.2.20/live.mjpeg", "", "rtsp://192.0.2.20/live", "tcp", true)
        val json = JSONObject(MediaSourceModel.json("cam_1", null, draft)!!)
        assertEquals("ip_camera", json.getString("kind"))
        assertEquals("secret:media.cam_1", json.getString("secret_ref"))
        assertEquals("tcp", json.getJSONObject("streams").getJSONObject("h264").getString("transport"))
        assertFalse(json.getJSONObject("streams").has("snapshot"))
        assertNull(MediaSourceModel.json("cam_1", null, draft.copy(mjpeg = "http://user:pw@192.0.2.20/")))
        assertNull(MediaSourceModel.json("cam_1", null, draft.copy(h264 = "http://192.0.2.20/")))
        assertNull(MediaSourceModel.json("cam_1", null, MediaSourceModel.Draft("", "", "", "tcp", false)))
        val noSecret = JSONObject(MediaSourceModel.json("cam_1", json, draft.copy(hasSecret = false))!!)
        assertFalse(noSecret.has("secret_ref"))
    }

    @Test
    fun panelIdentityRecordsMatchCoreValidation() {
        val gen = "0123456789abcdef0123456789abcdef"
        val record = PanelIdentityModel.record("secret:panel.0011223344556677", gen,
                                               listOf("d_b", "d_a"), listOf("view", "door.open"))!!
        assertEquals("d_a", record.getJSONArray("door_scope").getString(0))
        assertFalse(record.getBoolean("revoked"))
        assertNull(PanelIdentityModel.record("panel.x", gen, listOf("d"), listOf("view")))
        assertNull(PanelIdentityModel.record("secret:p", gen, emptyList(), listOf("view")))
        assertNotNull(PanelIdentityModel.record("secret:p", gen, emptyList(), listOf("sos.trigger")))
        assertNull(PanelIdentityModel.record("secret:p", gen, listOf("d"), listOf("root")))
        assertNull(PanelIdentityModel.record("secret:p", "short", listOf("d"), listOf("view")))
        assertEquals("panel.identities.$gen", PanelIdentityModel.key(gen))
    }

    // ---------- assets and recording ----------

    @Test
    fun assetTypesComeFromTheBytes() {
        assertEquals("image/jpeg", AssetTypes.sniff(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0)))
        assertEquals("image/png", AssetTypes.sniff(byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47)))
        assertEquals("audio/mpeg", AssetTypes.sniff("ID3x".toByteArray()))
        assertEquals("audio/wav", AssetTypes.sniff(WavFormat.wrap(ByteArray(10), 16000)))
        assertNull(AssetTypes.sniff("hello".toByteArray()))
        val cfg = JSONObject("""{"assets":{"h2":{"type":"audio/wav","label":"b"},"h1":{"type":"audio/mpeg","label":"A"},
            "h3":{"type":"image/png","label":"c"}}}""")
        assertEquals(listOf("h1", "h2"), AssetTypes.list(cfg, AssetTypes.SOUNDS).map { it.first })
    }

    @Test
    fun recorderWavHeaderIsCanonicalAndFitsTheLedger() {
        val wav = WavFormat.wrap(ByteArray(32000), 16000)
        assertEquals(44 + 32000, wav.size)
        assertEquals("RIFF", String(wav, 0, 4, Charsets.US_ASCII))
        assertEquals("WAVE", String(wav, 8, 4, Charsets.US_ASCII))
        assertEquals("data", String(wav, 36, 4, Charsets.US_ASCII))
        assertEquals(16000, (wav[24].toInt() and 0xFF) or ((wav[25].toInt() and 0xFF) shl 8))
        assertTrue(WavFormat.maxSeconds(16000) >= 60)
    }

    // ---------- wording overrides and import ----------

    @Test
    fun resourceNamesMapBackToCatalogueKeys() {
        assertEquals("admin.when_button", I18nKeys.fromResourceName("admin_when_button"))
        assertEquals("web_admin.open", I18nKeys.fromResourceName("web_admin_open"))
        assertEquals("pair.err.bad_pin", I18nKeys.fromResourceName("pair_err_bad_pin"))
        assertNull(I18nKeys.fromResourceName("nounderscore"))
        val overrides = JSONObject("""{"ja":{"idle.touch_to_call":"押してね","x.y":"keep"},"en":{"idle.touch_to_call":"Tap"}}""")
        val ops = I18nKeys.overrideOps(overrides, "idle.touch_to_call",
                                       mapOf("ja" to "", "en" to "", "zh" to "点"))
        val ja = ops.first { it.key == "i18n_overrides.ja" } as ConfigOp.Set
        assertEquals("keep", JSONObject(ja.valueJson).getString("x.y"))
        assertFalse(JSONObject(ja.valueJson).has("idle.touch_to_call"))
        assertEquals(ConfigOp.Delete("i18n_overrides.en"), ops.first { it.key == "i18n_overrides.en" })
        assertEquals("点", JSONObject((ops.first { it.key == "i18n_overrides.zh" } as ConfigOp.Set).valueJson)
            .getString("idle.touch_to_call"))
        assertTrue(I18nKeys.overrideOps(overrides, "x.y", mapOf("ja" to "keep")).isEmpty())
        assertEquals("Tap", I18nKeys.current(overrides, "en", "idle.touch_to_call"))
        assertTrue(I18nKeys.placeholdersMatch("Call {unit}", "{unit} を呼ぶ"))
        assertFalse(I18nKeys.placeholdersMatch("Call {unit}", "Call"))
    }

    @Test
    fun importStagesTheWholeDocumentAtTheSnapshotRevision() {
        val snapshot = JSONObject().put("schema_version", 2).put("revision", "r1")
            .put("config", JSONObject().put("ui", JSONObject().put("ringtone", "ding1")))
        val exported = ConfigTransfer.exportDocument(snapshot)
        assertFalse(exported.has("revision"))
        val config = ConfigTransfer.importedConfig(exported)!!
        val stage = JSONObject(ConfigTransfer.stageRequest("r2", config))
        assertEquals("r2", stage.getString("expected_revision"))
        assertEquals(2, stage.getJSONObject("document").getInt("schema_version"))
        assertEquals("ding1", stage.getJSONObject("document").getJSONObject("config")
            .getJSONObject("ui").getString("ringtone"))
        assertNull(ConfigTransfer.importedConfig(JSONObject().put("schema_version", 1)))
        assertTrue(ConfigTransfer.randomOperationId().matches(Regex("^[0-9a-f]{32}$")))
    }
}
