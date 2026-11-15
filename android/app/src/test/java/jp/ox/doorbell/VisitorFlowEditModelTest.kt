package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VisitorFlowEditModelTest {

    private val config = JSONObject("""
        {"ui":{"languages":["ja","en"]},
         "doors":{"d_front":{"visitor_flow":{"start":"s_home"}},"d_back":{}},
         "media_sources":{"porch":{"streams":{"snapshot":{"url":"http://cam/snap"}}},
                          "rtsp_only":{"streams":{"h264":{"url":"rtsp://cam/x"}}}},
         "visitor_flow":{"enabled":false,"start":"s_home","idle_s":60,"require_call":false,
          "steps":{
           "s_home":{"kind":"page","options":[
              {"id":"o_call","label":{"en":"Call"},"style":"primary","to":"c_any"},
              {"id":"o_d","purpose":"p_delivery","to":"s_parcel"}]},
           "s_parcel":{"kind":"page","options":[{"id":"o_l","label":{"en":"Leave"},"to":"n_left"}]},
           "c_any":{"kind":"call","on_unanswered":"s_home"},
           "n_left":{"kind":"notify","message":{"en":"x"},"to":"e_thanks"},
           "e_thanks":{"kind":"end"},
           "s_orphan":{"kind":"page","options":[{"id":"o","label":{"en":"x"},"to":"c_any"}]}}}}
    """)

    @Test
    fun readsTheScalarsAndTheStepPool() {
        val state = FlowEdit.read(config)
        assertTrue(state.written)
        assertFalse(state.enabled)
        assertEquals("s_home", state.start)
        assertEquals(60, state.idleS)
        assertFalse(state.requireCall)
        assertEquals(6, state.steps.size)
    }

    @Test
    fun anEmptyConfigurationIsTheBuiltInWizard() {
        val state = FlowEdit.read(JSONObject())
        assertFalse(state.written)
        assertTrue(state.enabled)
        assertEquals(FlowEdit.IDLE_DEFAULT, state.idleS)
        assertTrue(state.requireCall)
        assertFalse(FlowEdit.hasSteps(null))
    }

    @Test
    fun stepsListStartFirstThenInTheOrderTheyAreReachedAndOrphansLast() {
        val order = FlowEdit.order(FlowEdit.read(config))
        assertEquals(listOf("s_home", "c_any", "s_parcel", "n_left", "e_thanks", "s_orphan"), order)
    }

    @Test
    fun findsWhoLeadsToAStep() {
        val steps = FlowEdit.read(config).steps
        assertEquals(listOf("s_home", "s_orphan"), FlowEdit.referencedBy(steps, "c_any"))
        assertEquals(listOf("n_left"), FlowEdit.referencedBy(steps, "e_thanks"))
        assertEquals(listOf("c_any"), FlowEdit.referencedBy(steps, "s_home"))
        assertEquals(listOf("s_home", "s_orphan", "s_parcel"), FlowEdit.pages(steps))
        assertEquals(listOf("e_thanks"), FlowEdit.ends(steps))
    }

    @Test
    fun idsFollowTheContract() {
        assertTrue(FlowEdit.validId("s_home"))
        assertTrue(FlowEdit.validId("A-b_9"))
        assertFalse(FlowEdit.validId(""))
        assertFalse(FlowEdit.validId("__call"))
        assertFalse(FlowEdit.validId("has space"))
        assertFalse(FlowEdit.validId("x".repeat(33)))
        val id = FlowEdit.newId("s", setOf("s_000001"), 1L)
        assertTrue(FlowEdit.validId(id))
        assertEquals("s_000002", id)
    }

    @Test
    fun textMapsKeepOnlyFilledLanguages() {
        val map = FlowEdit.textMap(mapOf("ja" to " こんにちは ", "en" to "", "zh" to "  "))!!
        assertEquals(1, map.length())
        assertEquals("こんにちは", map.getString("ja"))
        assertNull(FlowEdit.textMap(mapOf("ja" to "", "en" to " ")))
    }

    @Test
    fun languagesComeFromTheConfigurationOrTheCatalogue() {
        assertEquals(listOf("ja", "en"), FlowEdit.languages(config))
        assertEquals(SettingsModel.LANGUAGES, FlowEdit.languages(JSONObject()))
    }

    @Test
    fun onlyCamerasWithASnapshotUrlArePickable() {
        assertEquals(listOf("porch"), FlowEdit.snapshotCameras(config))
        assertEquals(emptyList<String>(), FlowEdit.snapshotCameras(null))
        assertEquals("""{"source":"door_station"}""", FlowEdit.snapshotJson("door_station")!!.toString())
        assertEquals("porch", FlowEdit.snapshotJson("media_source", "porch")!!.getString("id"))
        assertNull(FlowEdit.snapshotJson("none"))
    }

    @Test
    fun makingAnOptionPrimaryClearsTheOthers() {
        val options = JSONArray("""[{"id":"a","style":"primary"},{"id":"b"},{"id":"c","style":"normal"}]""")
        FlowEdit.makePrimary(options, "b")
        assertFalse(options.getJSONObject(0).has("style"))
        assertEquals("primary", options.getJSONObject(1).getString("style"))
        assertEquals("normal", options.getJSONObject(2).getString("style"))
    }

    @Test
    fun movingStaysInsideTheList() {
        val list = mutableListOf(1, 2, 3)
        assertTrue(FlowEdit.move(list, 2, -1))
        assertEquals(listOf(1, 3, 2), list)
        assertFalse(FlowEdit.move(list, 0, -1))
        assertFalse(FlowEdit.move(list, 2, 1))
    }

    @Test
    fun aStepIsWrittenAsOneWholeValue() {
        val ops = FlowEdit.saveStepOps(mapOf("c_x" to JSONObject("""{"kind":"call","purpose":"p_a"}""")))
        assertEquals(1, ops.size)
        val set = ops[0] as ConfigOp.Set
        assertEquals("visitor_flow.steps.c_x", set.key)
        assertEquals("p_a", JSONObject(set.valueJson).getString("purpose"))
        assertEquals("visitor_flow.steps.c_x", FlowEdit.deleteStepOps("c_x")[0].key)
    }

    @Test
    fun resetDeletesTheContainerOnceAndTheDoorStarts() {
        val ops = FlowEdit.resetOps(config)
        assertEquals(listOf("visitor_flow", "doors.d_front.visitor_flow.start"), ops.map { it.key })
        assertTrue(ops.all { it is ConfigOp.Delete })
    }

    @Test
    fun aTemplateWritesLeavesAndStepsAndDropsWhatGoesAway() {
        val template = JSONObject("""
            {"enabled":true,"start":"s_start","idle_s":45,"require_call":true,
             "steps":{"s_start":{"kind":"page","options":[{"id":"o","label":{"en":"Call"},"style":"primary","to":"c_any"}]},
                      "c_any":{"kind":"call"}}}
        """)
        val ops = FlowEdit.templateOps(config, template)
        val keys = ops.map { it.key }
        assertTrue("visitor_flow.enabled" in keys)
        assertTrue("visitor_flow.start" in keys)
        assertTrue("visitor_flow.steps.s_start" in keys)
        assertTrue(ops.none { it.key == "visitor_flow" || it.key == "visitor_flow.steps" })
        for (gone in listOf("s_home", "s_parcel", "n_left", "e_thanks", "s_orphan"))
            assertTrue(ops.any { it is ConfigOp.Delete && it.key == "visitor_flow.steps.$gone" })
        assertTrue(ops.any { it is ConfigOp.Delete && it.key == "doors.d_front.visitor_flow.start" })
        assertEquals("true", (ops.first { it.key == "visitor_flow.require_call" } as ConfigOp.Set).valueJson)
    }

    @Test
    fun errorsSplitIntoCodeLocationAndDetail() {
        val located = FlowEdit.parseError("visitor_flow.missing_target: s_home.o_visit")!!
        assertEquals("missing_target", located.code)
        assertEquals(FlowEdit.Location("s_home", "o_visit"), located.location)
        assertNull(FlowEdit.parseError("visitor_flow.cycle")!!.location)
        assertNull(FlowEdit.parseError("unresolved_config_conflict"))
        assertTrue(FlowEdit.isConflict("unresolved_config_conflict"))
        assertFalse(FlowEdit.isConflict("visitor_flow.cycle"))
    }

    @Test
    fun locationsNameTheControl() {
        fun at(where: String, code: String = "x") = FlowEdit.parseLocation(code, where)
        assertEquals(FlowEdit.Location("s"), at("s"))
        assertEquals(FlowEdit.Location("s", field = "title", lang = "ja"), at("s.title.ja"))
        assertEquals(FlowEdit.Location("s", field = "body", lang = "en"), at("s.body.en"))
        assertEquals(FlowEdit.Location("s", field = "message", lang = "zh"), at("s.message.zh"))
        assertEquals(FlowEdit.Location("s", field = "message"), at("s.message"))
        assertEquals(FlowEdit.Location("s", "o1", "label", "ja"), at("s.o1.label.ja"))
        assertEquals(FlowEdit.Location("s", "o1", "label"), at("s.o1.label"))
        assertEquals(FlowEdit.Location("s", "o1"), at("s.o1"))
        assertEquals(FlowEdit.Location("s", image = 1), at("s.images[1]"))
        assertEquals(FlowEdit.Location("s", field = "alt", lang = "ja", image = 0), at("s.images[0].alt.ja"))
        assertEquals(FlowEdit.Location(start = true), at("start"))
        assertEquals(FlowEdit.Location(start = true, door = "d_front"), at("doors.d_front.start"))
        assertEquals(FlowEdit.Location(start = true, door = "d_front"), at("d_front", "no_reachable_call"))
        assertNull(at(""))
    }

    @Test
    fun detailFillsThePlaceholdersInTheOrderTheResourceNumbersThem() {
        val detail = JSONObject("""{"lang":"ja","limit":60,"value":71}""")
        val error = FlowEdit.parseError("visitor_flow.text_too_long: s.title.ja", detail) { "日本語" }!!
        assertEquals(listOf<Any>("日本語", "60", "71"), error.args().toList())
        val range = FlowEdit.parseError("visitor_flow.bad_idle_s", JSONObject("""{"min":15,"max":300}"""))!!
        assertEquals(listOf<Any>("15", "300"), range.args().toList())
        assertEquals(0, FlowEdit.parseError("visitor_flow.cycle: s")!!.args().size)
    }

    @Test
    fun obviousProblemsAreCaughtBeforeAskingCoreWithCoreCodes() {
        val none = FlowEdit.localProblem("s", JSONObject("""{"kind":"page","options":[]}"""))!!
        assertEquals("no_options", none.code)
        assertEquals(FlowEdit.Location("s"), none.location)
        val unlabeled = FlowEdit.localProblem("s", JSONObject(
            """{"kind":"page","options":[{"id":"o","to":"c"}]}"""))!!
        assertEquals("option_needs_label", unlabeled.code)
        assertEquals(FlowEdit.Location("s", "o"), unlabeled.location)
        val untargeted = FlowEdit.localProblem("s", JSONObject(
            """{"kind":"page","options":[{"id":"o","purpose":"p"}]}"""))!!
        assertEquals("missing_target", untargeted.code)
        assertEquals(FlowEdit.Location("s", "o"), untargeted.location)
        assertEquals("missing_target", FlowEdit.localProblem("n", JSONObject("""{"kind":"notify"}"""))!!.code)
        assertEquals("multiple_primary", FlowEdit.localProblem("s", JSONObject(
            """{"kind":"page","options":[{"id":"a","purpose":"p","style":"primary","to":"c"},
                {"id":"b","purpose":"p","style":"primary","to":"c"}]}"""))!!.code)
        assertNull(FlowEdit.localProblem("s", JSONObject(
            """{"kind":"page","options":[{"id":"a","purpose":"p","to":"c"}]}""")))
        assertNull(FlowEdit.localProblem("c", JSONObject("""{"kind":"call"}""")))
    }

    // ---------- step order ----------

    private fun stateWithOrders(orders: Map<String, Int?>): FlowEdit.State {
        val base = FlowEdit.read(config)
        val steps = LinkedHashMap<String, JSONObject>()
        for ((id, step) in base.steps) {
            val copy = JSONObject(step.toString())
            orders[id]?.let { copy.put("order", it) }
            steps[id] = copy
        }
        return base.copy(steps = steps)
    }

    @Test
    fun anOrderMemberLeadsAndTiesKeepReadingOrder() {
        val state = stateWithOrders(mapOf("e_thanks" to 0, "s_orphan" to 1, "n_left" to 1))
        // n_left is read before s_orphan; steps without an order follow in reading order.
        assertEquals(listOf("e_thanks", "n_left", "s_orphan", "s_home", "c_any", "s_parcel"),
                     FlowEdit.order(state))
    }

    @Test
    fun anUnusableOrderCountsAsNone() {
        val steps = LinkedHashMap(FlowEdit.read(config).steps)
        steps["s_orphan"] = JSONObject("""{"kind":"page","order":10000,"options":[]}""")
        steps["n_left"] = JSONObject("""{"kind":"notify","order":-1,"to":"e_thanks"}""")
        steps["c_any"] = JSONObject("""{"kind":"call","order":"3"}""")
        val state = FlowEdit.read(config).copy(steps = steps)
        assertEquals(listOf("s_home", "c_any", "s_parcel", "n_left", "e_thanks", "s_orphan"),
                     FlowEdit.order(state))
    }

    @Test
    fun theFirstMoveNumbersEveryStepAsWholeSteps() {
        val state = FlowEdit.read(config)
        val ops = FlowEdit.moveOps(state, "c_any", -1)
        // Reading order was s_home, c_any, ...; after the move c_any is first.
        val written = ops.associate { (it as ConfigOp.Set).key to JSONObject(it.valueJson) }
        assertEquals(6, written.size)
        assertEquals(0, written.getValue("visitor_flow.steps.c_any").getInt("order"))
        assertEquals(1, written.getValue("visitor_flow.steps.s_home").getInt("order"))
        assertEquals(5, written.getValue("visitor_flow.steps.s_orphan").getInt("order"))
        // Whole steps: every other member is kept.
        assertEquals("s_home", written.getValue("visitor_flow.steps.c_any").getString("on_unanswered"))
        assertEquals("page", written.getValue("visitor_flow.steps.s_home").getString("kind"))
    }

    @Test
    fun aLaterMoveRewritesOnlyWhatMoved() {
        val numbered = LinkedHashMap<String, Int?>()
        FlowEdit.order(FlowEdit.read(config)).forEachIndexed { i, id -> numbered[id] = i }
        val state = stateWithOrders(numbered)
        val ops = FlowEdit.moveOps(state, "s_parcel", 1)
        assertEquals(setOf("visitor_flow.steps.s_parcel", "visitor_flow.steps.n_left"),
                     ops.map { it.key }.toSet())
        val parcel = JSONObject((ops.first { it.key.endsWith("s_parcel") } as ConfigOp.Set).valueJson)
        val left = JSONObject((ops.first { it.key.endsWith("n_left") } as ConfigOp.Set).valueJson)
        assertEquals(3, parcel.getInt("order"))
        assertEquals(2, left.getInt("order"))
    }

    @Test
    fun theEndsOfTheListCannotMoveFurther() {
        val state = FlowEdit.read(config)
        assertTrue(FlowEdit.moveOps(state, "s_home", -1).isEmpty())
        assertTrue(FlowEdit.moveOps(state, "s_orphan", 1).isEmpty())
        assertTrue(FlowEdit.moveOps(state, "missing", 1).isEmpty())
    }

    @Test
    fun anotherEditKeepsTheOrderAndANewStepGetsTheNext() {
        val numbered = LinkedHashMap<String, Int?>()
        FlowEdit.order(FlowEdit.read(config)).forEachIndexed { i, id -> numbered[id] = i * 2 }
        val state = stateWithOrders(numbered)
        val edited = JSONObject(state.steps.getValue("s_parcel").toString())
        val rewritten = FlowEdit.saveStepOps(mapOf("s_parcel" to edited))
        assertEquals(4, JSONObject((rewritten.single() as ConfigOp.Set).valueJson).getInt("order"))

        val fresh = linkedMapOf("c_new" to JSONObject("""{"kind":"call"}"""),
                                "e_new" to JSONObject("""{"kind":"end"}"""))
        val ordered = FlowEdit.withNextOrders(state.steps, fresh)
        assertEquals(11, ordered.getValue("c_new").getInt("order"))
        assertEquals(12, ordered.getValue("e_new").getInt("order"))
    }

    @Test
    fun aNewStepStaysUnorderedWhileNoStepHasAnOrder() {
        val state = FlowEdit.read(config)
        assertNull(FlowEdit.nextOrder(state.steps))
        val ordered = FlowEdit.withNextOrders(state.steps, mapOf("c_new" to JSONObject("""{"kind":"call"}""")))
        assertFalse(ordered.getValue("c_new").has("order"))
    }

    @Test
    fun aDuplicateLandsRightAfterTheOriginal() {
        val state = FlowEdit.read(config)
        val ops = FlowEdit.duplicateOps(state, "c_any", "c_copy", state.steps.getValue("c_any"))
        val written = ops.associate { it.key.removePrefix("visitor_flow.steps.") to
            JSONObject((it as ConfigOp.Set).valueJson).getInt("order") }
        assertEquals(1, written.getValue("c_any"))
        assertEquals(2, written.getValue("c_copy"))
        assertEquals(3, written.getValue("s_parcel"))
        assertEquals(0, written.getValue("s_home"))
    }

    // ---------- option icons and preview ----------

    @Test
    fun optionsNeverShowEmojiButAVendoredGlyph() {
        fun cp(point: Int) = String(Character.toChars(point))
        assertEquals(FlowIcons.Glyph.VISIT, FlowIcons.glyph("p_visit", cp(0x1F3E0)))
        assertEquals(FlowIcons.Glyph.DELIVERY, FlowIcons.glyph("anything", cp(0x1F4E6)))
        assertEquals(FlowIcons.Glyph.MAIL, FlowIcons.glyph("", cp(0x2709) + cp(0xFE0F)))
        assertEquals(FlowIcons.Glyph.SALES, FlowIcons.glyph("p_sales", ""))
        assertEquals(FlowIcons.Glyph.WORK, FlowIcons.glyph("p_utility_work", cp(0x1F9D1)))
        assertEquals(FlowIcons.Glyph.OTHER, FlowIcons.glyph("p_other", ""))
        assertEquals(FlowIcons.Glyph.PERSON, FlowIcons.glyph("p_unknown", cp(0x1F984)))
        assertEquals(FlowIcons.Glyph.PERSON, FlowIcons.glyph("", ""))
        // What the editor stores maps back to the glyph it was picked for.
        for (glyph in FlowIcons.Glyph.values()) assertEquals(glyph, FlowIcons.glyph("", glyph.emoji))
    }

    @Test
    fun thePreviewDocumentResolvesPurposeLabelsAndWalksLikeTheDoor() {
        val withPurpose = JSONObject(config.toString()).put("visit_purposes", JSONObject(
            """{"p_delivery":{"label":{"en":"Delivery"},"icon":"x"}}"""))
        val document = FlowPreview.document(withPurpose, FlowEdit.read(withPurpose).steps, "s_home")
        val walker = FlowWalker(document, "en")
        val options = walker.snapshot().options
        assertEquals(listOf("Call", "Delivery"), options.map { it.label })
        assertTrue(options[0].primary && options[0].call)
        assertFalse(options[1].call)
        val calls = walker.apply(FlowEvent.Tap("o_d"))
        assertTrue(calls.isEmpty())
        assertEquals("s_parcel", walker.currentPageId)
        val notify = walker.apply(FlowEvent.Tap("o_l"))
        assertEquals(FlowPreview.Outcome.Message("n_left", "e_thanks"),
                     FlowPreview.outcome(notify, walker.currentPageId))
    }
}
