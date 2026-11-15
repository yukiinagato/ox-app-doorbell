package jp.ox.doorbell

import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Replays the shared `walk` cases of tools/conformance/fixtures/visitor-flow-v1.json. */
class VisitorFlowTest {

    private val suite: JSONObject by lazy {
        // Gradle runs unit tests from android/app; the fixture is read from the source tree.
        val file = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "tools/conformance/fixtures/visitor-flow-v1.json") }
            .first { it.isFile }
        JSONObject(file.readText(Charsets.UTF_8))
    }

    private val flows: Map<String, JSONObject> by lazy {
        val out = HashMap<String, JSONObject>()
        val resolve = suite.getJSONArray("resolve")
        for (i in 0 until resolve.length()) {
            val case = resolve.getJSONObject(i)
            out[case.getString("name")] = case.getJSONObject("expect")
        }
        out
    }

    private fun walkCase(name: String): JSONObject {
        val walks = suite.getJSONArray("walk")
        return (0 until walks.length()).map { walks.getJSONObject(it) }.first { it.getString("name") == name }
    }

    private fun expected(snapshot: FlowSnapshot): JSONObject {
        val options = JSONArray()
        for (option in snapshot.options) options.put(JSONObject()
            .put("id", option.id).put("semantic_id", option.semanticId).put("label", option.label))
        return JSONObject()
            .put("mode", snapshot.mode)
            .put("page", snapshot.page ?: JSONObject.NULL)
            .put("title", snapshot.title ?: JSONObject.NULL)
            .put("options", options)
            .put("back", snapshot.back)
            .put("done", snapshot.done)
            .put("notice", snapshot.notice ?: JSONObject.NULL)
            .put("reply", snapshot.reply)
    }

    private fun eventOf(raw: JSONObject): FlowEvent = when {
        raw.has("reply") -> FlowEvent.Reply(raw.getBoolean("reply"))
        raw.has("lang") -> FlowEvent.Language(raw.getString("lang"))
        raw.has("flow_changed") -> FlowEvent.FlowChanged(flows.getValue(raw.getString("flow_changed")))
        raw.has("tap") -> FlowEvent.Tap(
            raw.getString("tap"),
            notifyOk = raw.optJSONObject("notify_result")?.optBoolean("ok", true) ?: true,
            pressFailed = raw.optString("press_result") == "failed",
        )
        raw.optBoolean("back") -> FlowEvent.Back
        raw.optBoolean("idle_timeout") -> FlowEvent.IdleTimeout
        raw.optBoolean("done") || raw.optBoolean("end_timeout") -> FlowEvent.Done
        raw.has("call_ended") -> FlowEvent.CallEnded(raw.getString("call_ended"))
        else -> throw AssertionError("unknown walk event $raw")
    }

    private fun callsOf(calls: List<FlowCall>): JSONArray {
        val out = JSONArray()
        for (call in calls) out.put(when (call) {
            is FlowCall.Press -> JSONObject().put("press", call.purpose)
            is FlowCall.Notify -> JSONObject().put("notify", call.step)
        })
        return out
    }

    /** Every JSON value compared structurally; org.json offers no deep equals. */
    private fun same(a: Any?, b: Any?): Boolean = when {
        a is JSONObject && b is JSONObject -> a.length() == b.length() &&
            a.keys().asSequence().all { b.has(it) && same(a.get(it), b.get(it)) }
        a is JSONArray && b is JSONArray -> a.length() == b.length() &&
            (0 until a.length()).all { same(a.get(it), b.get(it)) }
        a === JSONObject.NULL || a == null -> b === JSONObject.NULL || b == null
        else -> a == b
    }

    @Test
    fun everyWalkCaseMatchesTheReferenceWalker() {
        val walks = suite.getJSONArray("walk")
        assertTrue(walks.length() >= 15)
        var checked = 0
        for (i in 0 until walks.length()) {
            val case = walks.getJSONObject(i)
            val name = case.getString("name")
            val walker = FlowWalker(flows.getValue(case.getString("flow")), case.optString("lang", "ja"))
            if (case.has("start"))
                assertTrue("$name: start", same(case.getJSONObject("start"), expected(walker.snapshot())))
            val steps = case.getJSONArray("steps")
            for (j in 0 until steps.length()) {
                val entry = steps.getJSONObject(j)
                val calls = walker.apply(eventOf(entry.getJSONObject("event")))
                val want = entry.optJSONArray("calls") ?: JSONArray()
                assertTrue("$name[$j]: calls $want vs ${callsOf(calls)}", same(want, callsOf(calls)))
                val got = expected(walker.snapshot())
                assertTrue("$name[$j]: ${entry.getJSONObject("expect")} vs $got",
                           same(entry.getJSONObject("expect"), got))
                checked++
            }
        }
        assertTrue(checked > 40)
    }

    @Test
    fun targetOfTellsTheShellWhichCoreCallToRunFirst() {
        val walker = FlowWalker(flows.getValue("explicit-flow"))
        val snapshot = walker.snapshot()
        assertEquals("page", snapshot.mode)
        assertNotNull(snapshot.page)
        for (option in snapshot.options) assertTrue(walker.targetOf(option.id) !== FlowTarget.Nothing)
        assertEquals(FlowTarget.Nothing, walker.targetOf("no-such-option"))
    }

    @Test
    fun aPressThatFailsAfterANotifyFallbackLeavesThePageWithAnError() {
        val case = walkCase("failed-notify-rings")
        val walker = FlowWalker(flows.getValue(case.getString("flow")), case.optString("lang", "ja"))
        val steps = case.getJSONArray("steps")
        for (j in 0 until steps.length()) {
            val calls = walker.apply(eventOf(steps.getJSONObject(j).getJSONObject("event")))
            if (calls.any { it is FlowCall.Press }) break
        }
        assertEquals(FlowWalker.MODE_CALLING, walker.mode)
        walker.callFailed()
        assertEquals(FlowWalker.MODE_PAGE, walker.mode)
        assertEquals(FlowWalker.PRESS_FAILED_NOTICE, walker.snapshot().notice)
    }

    @Test
    fun aDisabledOrBrokenDocumentIsNotUsable() {
        assertEquals(null, FlowDocuments.usable(null))
        assertEquals(null, FlowDocuments.usable(flows.getValue("legacy-call-flow")))
        assertEquals(null, FlowDocuments.usable(JSONObject().put("enabled", true).put("start", "x")))
        assertNotNull(FlowDocuments.usable(flows.getValue("explicit-flow")))
        assertTrue(!FlowDocuments.notifyOk(null))
        assertTrue(FlowDocuments.notifyOk(JSONObject("{\"ok\":true,\"throttled\":true}")))
    }
}
