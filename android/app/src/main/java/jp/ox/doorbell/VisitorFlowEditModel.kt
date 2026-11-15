// What the visitor-flow editor reads and writes (docs/en/config-schema.md, "Visitor flow").
//
// Pure model code, host-tested. The scalar keys are written as leaves and every step as one whole
// value; a whole edit (a step and the steps it creates, a template, a reset) is one batch so Core
// validates the graph on the configuration the batch would leave.
package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject

internal object FlowEdit {

    const val ROOT = "visitor_flow"
    const val STEPS = "visitor_flow.steps"

    const val MAX_TITLE = 60
    const val MAX_BODY = 600
    const val MAX_LABEL = 40
    const val MAX_MESSAGE = 200
    const val MAX_ALT = 120
    const val MAX_STEPS = 32
    const val MAX_OPTIONS = 12
    const val MAX_IMAGES = 2
    const val IDLE_MIN = 15
    const val IDLE_MAX = 300
    const val IDLE_DEFAULT = 45
    const val RETURN_MIN = 3
    const val RETURN_MAX = 60
    const val RETURN_DEFAULT = 8

    val KINDS = listOf("page", "call", "notify", "end")
    const val CONFLICT = "unresolved_config_conflict"

    private val ID = Regex("^[A-Za-z0-9_-]{1,32}$")

    data class State(
        /** False while no step was ever written: Core serves the built-in wizard. */
        val written: Boolean,
        val enabled: Boolean,
        val start: String,
        val idleS: Int,
        val requireCall: Boolean,
        val steps: Map<String, JSONObject>,
    )

    fun read(config: JSONObject?): State {
        val root = config?.optJSONObject("visitor_flow")
        val raw = root?.optJSONObject("steps")
        val steps = LinkedHashMap<String, JSONObject>()
        if (raw != null) for (id in raw.keys().asSequence().sorted())
            raw.optJSONObject(id)?.let { steps[id] = it }
        return State(
            written = steps.isNotEmpty(),
            enabled = root?.optBoolean("enabled", true) ?: true,
            start = root?.optString("start").orEmpty(),
            idleS = (root?.opt("idle_s") as? Number)?.toInt()?.coerceIn(IDLE_MIN, IDLE_MAX) ?: IDLE_DEFAULT,
            requireCall = root?.optBoolean("require_call", true) ?: true,
            steps = steps,
        )
    }

    fun hasSteps(config: JSONObject?): Boolean = read(config).written

    fun validId(id: String): Boolean = ID.matches(id) && !id.startsWith("__")

    fun newId(prefix: String, taken: Collection<String>, seed: Long): String {
        var n = seed and 0xFFFFFF
        while (true) {
            val id = "%s_%06x".format(prefix, n)
            if (id !in taken) return id
            n = (n + 1) and 0xFFFFFF
        }
    }

    fun prefixFor(kind: String): String = when (kind) {
        "page" -> "s"
        "call" -> "c"
        "notify" -> "n"
        else -> "e"
    }

    /** The steps a step leads to: option targets, a notify's page, an unanswered branch. */
    fun targetsOf(step: JSONObject): List<String> {
        val out = ArrayList<String>()
        step.optJSONArray("options")?.let { options ->
            for (i in 0 until options.length())
                options.optJSONObject(i)?.optString("to")?.takeIf { it.isNotEmpty() }?.let(out::add)
        }
        step.optString("to").takeIf { it.isNotEmpty() }?.let(out::add)
        step.optString("on_unanswered").takeIf { it.isNotEmpty() }?.let(out::add)
        return out
    }

    /** Start page first, then in the order a visitor reaches them; unreachable steps last. */
    fun order(state: State): List<String> {
        val seen = LinkedHashSet<String>()
        val queue = ArrayDeque<String>()
        if (state.start in state.steps) queue.add(state.start)
        while (queue.isNotEmpty()) {
            val id = queue.removeFirst()
            if (!seen.add(id)) continue
            for (target in targetsOf(state.steps.getValue(id)))
                if (target in state.steps && target !in seen) queue.add(target)
        }
        for (id in state.steps.keys) if (id !in seen) seen.add(id)
        return seen.toList()
    }

    fun referencedBy(steps: Map<String, JSONObject>, id: String): List<String> =
        steps.filter { (other, step) -> other != id && id in targetsOf(step) }.keys.sorted()

    fun pages(steps: Map<String, JSONObject>): List<String> =
        steps.filter { it.value.optString("kind") == "page" }.keys.sorted()

    fun ends(steps: Map<String, JSONObject>): List<String> =
        steps.filter { it.value.optString("kind") == "end" }.keys.sorted()

    /** The configured languages in order; the catalogue's three while none are set. */
    fun languages(config: JSONObject?): List<String> {
        val array = config?.optJSONObject("ui")?.optJSONArray("languages")
        val out = ArrayList<String>()
        if (array != null) for (i in 0 until array.length()) array.optString(i).takeIf { it.isNotEmpty() }?.let(out::add)
        return out.ifEmpty { SettingsModel.LANGUAGES }
    }

    /** Only the filled languages; null when there is no text at all. */
    fun textMap(values: Map<String, String>): JSONObject? {
        val out = JSONObject()
        for ((lang, value) in values) {
            val text = value.trim()
            if (text.isNotEmpty()) out.put(lang, text)
        }
        return if (out.length() == 0) null else out
    }

    fun textOf(labels: JSONObject?, lang: String): String? = FlowText.textIn(labels, lang)

    /** Cameras the notify picker offers: configured external cameras with a snapshot URL. */
    fun snapshotCameras(config: JSONObject?): List<String> {
        val sources = config?.optJSONObject("media_sources") ?: return emptyList()
        return sources.keys().asSequence().sorted().filter {
            sources.optJSONObject(it)?.optJSONObject("streams")?.optJSONObject("snapshot")
                ?.optString("url").orEmpty().isNotEmpty()
        }.toList()
    }

    fun snapshotJson(source: String, id: String = ""): JSONObject? = when (source) {
        "door_station" -> JSONObject().put("source", "door_station")
        "media_source" -> JSONObject().put("source", "media_source").put("id", id)
        else -> null
    }

    /** Clears `primary` on every option of [options] except [id]. */
    fun makePrimary(options: JSONArray, id: String) {
        for (i in 0 until options.length()) {
            val option = options.optJSONObject(i) ?: continue
            if (option.optString("id") == id) option.put("style", "primary")
            else if (option.optString("style") == "primary") option.remove("style")
        }
    }

    fun <T> move(list: MutableList<T>, from: Int, delta: Int): Boolean {
        val to = from + delta
        if (from !in list.indices || to !in list.indices) return false
        list.add(to, list.removeAt(from))
        return true
    }

    fun toList(array: JSONArray?): MutableList<JSONObject> {
        val out = ArrayList<JSONObject>()
        if (array != null) for (i in 0 until array.length()) array.optJSONObject(i)?.let(out::add)
        return out
    }

    fun toArray(list: List<JSONObject>): JSONArray {
        val array = JSONArray()
        for (item in list) array.put(item)
        return array
    }

    // ---------- ops ----------

    fun saveStepOps(steps: Map<String, JSONObject>): List<ConfigOp> =
        steps.map { (id, step) -> ConfigOp.Set("$STEPS.$id", step.toString()) }

    fun deleteStepOps(id: String): List<ConfigOp> = listOf(ConfigOp.Delete("$STEPS.$id"))

    /** Deleting `visitor_flow` is the one op that returns to the built-in wizard. */
    fun resetOps(config: JSONObject?): List<ConfigOp> {
        val ops = ArrayList<ConfigOp>()
        ops.add(ConfigOp.Delete(ROOT))
        for (door in doorStarts(config).keys) ops.add(ConfigOp.Delete(doorStartKey(door)))
        return ops
    }

    fun doorStartKey(door: String): String = "doors.$door.visitor_flow.start"

    fun doorStarts(config: JSONObject?): Map<String, String> {
        val doors = config?.optJSONObject("doors") ?: return emptyMap()
        val out = LinkedHashMap<String, String>()
        for (door in doors.keys().asSequence().sorted()) {
            val start = doors.optJSONObject(door)?.optJSONObject("visitor_flow")?.optString("start").orEmpty()
            if (start.isNotEmpty()) out[door] = start
        }
        return out
    }

    /**
     * Replace the flow with a template (`flow` as Core's template call returns it): the scalar
     * leaves, one whole value per step, deletes for the steps that go away, and deletes for door
     * starts the template no longer has as a page.
     */
    fun templateOps(config: JSONObject?, flow: JSONObject): List<ConfigOp> {
        val ops = ArrayList<ConfigOp>()
        ops.add(ConfigOp.Set("$ROOT.enabled", flow.optBoolean("enabled", true).toString()))
        flow.optString("start").takeIf { it.isNotEmpty() }
            ?.let { ops.add(ConfigOp.Set("$ROOT.start", JSONObject.quote(it))) }
        ops.add(ConfigOp.Set("$ROOT.idle_s",
            flow.optInt("idle_s", IDLE_DEFAULT).coerceIn(IDLE_MIN, IDLE_MAX).toString()))
        ops.add(ConfigOp.Set("$ROOT.require_call", flow.optBoolean("require_call", true).toString()))
        val steps = flow.optJSONObject("steps") ?: JSONObject()
        for (id in steps.keys().asSequence().sorted())
            steps.optJSONObject(id)?.let { ops.add(ConfigOp.Set("$STEPS.$id", it.toString())) }
        for (id in read(config).steps.keys) if (!steps.has(id)) ops.add(ConfigOp.Delete("$STEPS.$id"))
        for ((door, start) in doorStarts(config))
            if (steps.optJSONObject(start)?.optString("kind") != "page")
                ops.add(ConfigOp.Delete(doorStartKey(door)))
        return ops
    }

    // ---------- errors ----------

    /** `visitor_flow.<code>[: <step>[.<option>]]` split into its i18n key and its detail. */
    fun errorParts(error: String): Pair<String, String> {
        val cut = error.indexOf(": ")
        return if (cut < 0) error to "" else error.substring(0, cut) to error.substring(cut + 2)
    }

    fun isConflict(error: String): Boolean = error == CONFLICT || error.startsWith("$CONFLICT:")

    /** Problems the shell can see before asking Core, as the catalogue keys Core would answer. */
    fun localProblem(step: JSONObject): String? {
        when (step.optString("kind")) {
            "page" -> {
                val options = step.optJSONArray("options")
                if (options == null || options.length() == 0) return "visitor_flow.no_options"
                if (options.length() > MAX_OPTIONS) return "visitor_flow.too_many_options"
                var primary = 0
                for (i in 0 until options.length()) {
                    val option = options.optJSONObject(i) ?: return "visitor_flow.invalid"
                    if (option.optString("style") == "primary") primary++
                    if (option.optJSONObject("label") == null && option.optString("purpose").isEmpty())
                        return "visitor_flow.option_needs_label"
                    if (option.optString("to").isEmpty()) return "visitor_flow.unknown_target"
                }
                if (primary > 1) return "visitor_flow.multiple_primary"
            }
            "notify" -> if (step.optString("to").isEmpty()) return "visitor_flow.unknown_target"
        }
        return null
    }
}
