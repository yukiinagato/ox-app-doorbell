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
    fun errorsSplitIntoTheCatalogueKeyAndTheDetail() {
        assertEquals("visitor_flow.unknown_target" to "s_home.o_visit",
                     FlowEdit.errorParts("visitor_flow.unknown_target: s_home.o_visit"))
        assertEquals("visitor_flow.cycle" to "", FlowEdit.errorParts("visitor_flow.cycle"))
        assertTrue(FlowEdit.isConflict("unresolved_config_conflict"))
        assertFalse(FlowEdit.isConflict("visitor_flow.cycle"))
    }

    @Test
    fun obviousProblemsAreCaughtBeforeAskingCore() {
        assertEquals("visitor_flow.no_options",
                     FlowEdit.localProblem(JSONObject("""{"kind":"page","options":[]}""")))
        assertEquals("visitor_flow.option_needs_label", FlowEdit.localProblem(
            JSONObject("""{"kind":"page","options":[{"id":"o","to":"c"}]}""")))
        assertEquals("visitor_flow.multiple_primary", FlowEdit.localProblem(JSONObject(
            """{"kind":"page","options":[{"id":"a","purpose":"p","style":"primary","to":"c"},
                {"id":"b","purpose":"p","style":"primary","to":"c"}]}""")))
        assertNull(FlowEdit.localProblem(JSONObject(
            """{"kind":"page","options":[{"id":"a","purpose":"p","to":"c"}]}""")))
        assertNull(FlowEdit.localProblem(JSONObject("""{"kind":"call"}""")))
    }
}
