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
    const val MAX_ORDER = 9999

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

    /** The step's `order` when it is a usable one (an integer 0..9999), otherwise null. */
    fun orderOf(step: JSONObject?): Int? {
        val number = when (val value = step?.opt("order")) {
            is Int -> value.toLong()
            is Long -> value
            else -> return null
        }
        return if (number in 0..MAX_ORDER.toLong()) number.toInt() else null
    }

    /**
     * Core's `step_order`: steps with an `order` by ascending value, ties and steps without one in
     * reading order.
     */
    fun order(state: State): List<String> {
        val reading = readingOrder(state)
        val ranked = reading.filter { orderOf(state.steps[it]) != null }
            .sortedBy { orderOf(state.steps.getValue(it)) }
        return ranked + reading.filter { orderOf(state.steps[it]) == null }
    }

    /** [sequence] with [id] moved by [delta] places; null when it cannot move that far. */
    fun moved(sequence: List<String>, id: String, delta: Int): List<String>? {
        val list = sequence.toMutableList()
        return if (move(list, list.indexOf(id), delta)) list else null
    }

    /**
     * The steps whose `order` must change for [sequence] to become the order: each gets its index
     * as a whole new object, every other member kept. Steps already carrying their index are left
     * out, so a move rewrites only what moved.
     */
    fun renumbered(steps: Map<String, JSONObject>, sequence: List<String>): Map<String, JSONObject> {
        val out = LinkedHashMap<String, JSONObject>()
        sequence.forEachIndexed { index, id ->
            val step = steps[id] ?: return@forEachIndexed
            if (orderOf(step) == index) return@forEachIndexed
            out[id] = JSONObject(step.toString()).put("order", index)
        }
        return out
    }

    /** One batch for moving [id] by [delta] in the listed order; empty when it cannot move. */
    fun moveOps(state: State, id: String, delta: Int): List<ConfigOp> {
        val sequence = moved(order(state), id, delta) ?: return emptyList()
        return saveStepOps(renumbered(state.steps, sequence))
    }

    /** The `order` a new step takes, or null while no step has one (reading order places it). */
    fun nextOrder(steps: Map<String, JSONObject>): Int? {
        val highest = steps.values.mapNotNull { orderOf(it) }.maxOrNull() ?: return null
        return minOf(highest + 1, MAX_ORDER)
    }

    /** Gives steps being created the next orders, in the sequence given. */
    fun withNextOrders(existing: Map<String, JSONObject>, created: Map<String, JSONObject>):
        Map<String, JSONObject> {
        var next = nextOrder(existing) ?: return created
        val out = LinkedHashMap<String, JSONObject>()
        for ((id, step) in created) {
            if (orderOf(step) != null) {
                out[id] = step
                continue
            }
            out[id] = JSONObject(step.toString()).put("order", next)
            next = minOf(next + 1, MAX_ORDER)
        }
        return out
    }

    /** The ops that add [copy] as [copyId] directly after [id], renumbering what follows. */
    fun duplicateOps(state: State, id: String, copyId: String, copy: JSONObject): List<ConfigOp> {
        val sequence = order(state).toMutableList()
        sequence.add(sequence.indexOf(id) + 1, copyId)
        val steps = LinkedHashMap(state.steps)
        steps[copyId] = JSONObject(copy.toString()).apply { remove("order") }
        return saveStepOps(renumbered(steps, sequence))
    }

    /** The start page, then breadth-first through the targets, then unreachable steps by id. */
    fun readingOrder(state: State): List<String> {
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

    /** Where a Core answer points, from the `<location>` of `visitor_flow.<code>[: <location>]`. */
    data class Location(
        val step: String? = null,
        val option: String? = null,
        /** title, body, message, label or alt. */
        val field: String? = null,
        val lang: String? = null,
        val image: Int? = null,
        /** True for the global start (door null) or a door's start. */
        val start: Boolean = false,
        val door: String? = null,
    )

    data class FlowError(
        val code: String,
        val location: Location?,
        val detail: Map<String, String>,
        val raw: String,
    ) {
        /** The arguments of `flow_error.<code>` in the order the generated resource numbers them. */
        fun args(): Array<Any> = (ARGS[code] ?: emptyList()).map { detail[it].orEmpty() }.toTypedArray()
    }

    private val ARGS: Map<String, List<String>> = buildMap {
        for (code in listOf("text_too_long", "too_many_paragraphs")) put(code, listOf("lang", "limit", "value"))
        put("bad_character", listOf("lang"))
        for (code in listOf("too_many_options", "too_many_languages", "too_many_images", "too_many_steps",
                            "too_deep")) put(code, listOf("limit", "value"))
        for (code in listOf("bad_order", "bad_return_s", "bad_idle_s")) put(code, listOf("min", "max"))
    }

    private val IMAGE_PART = Regex("^images\\[(\\d+)]$")

    /**
     * `visitor_flow.<code>[: <location>]` plus Core's `detail` object. Null when [error] is not a
     * visitor-flow answer. A language tag in the detail is shown by [langName].
     */
    fun parseError(error: String, detail: JSONObject? = null, langName: (String) -> String = { it }): FlowError? {
        if (!error.startsWith("visitor_flow.")) return null
        val cut = error.indexOf(": ")
        val code = (if (cut < 0) error else error.substring(0, cut)).removePrefix("visitor_flow.")
        val where = if (cut < 0) "" else error.substring(cut + 2)
        val values = LinkedHashMap<String, String>()
        if (detail != null) for (key in detail.keys()) {
            val value = detail.opt(key)?.toString().orEmpty()
            values[key] = if (key == "lang") langName(value) else value
        }
        return FlowError(code, parseLocation(code, where), values, error)
    }

    fun parseLocation(code: String, where: String): Location? {
        if (where.isEmpty()) return null
        if (where == "start") return Location(start = true)
        if (where.startsWith("doors.") && where.endsWith(".start") && where.length > 12)
            return Location(start = true, door = where.substring(6, where.length - 6))
        if (code == "no_reachable_call") return Location(start = true, door = where)
        val parts = where.split('.')
        val step = parts[0]
        val rest = parts.drop(1)
        if (rest.isEmpty()) return Location(step = step)
        val image = IMAGE_PART.matchEntire(rest[0])?.groupValues?.get(1)?.toIntOrNull()
        if (image != null) {
            return if (rest.getOrNull(1) == "alt") Location(step, field = "alt", lang = rest.getOrNull(2), image = image)
            else Location(step, image = image)
        }
        if (rest[0] == "title" || rest[0] == "body" || rest[0] == "message")
            return Location(step, field = rest[0], lang = rest.getOrNull(1))
        if (rest.getOrNull(1) == "label") return Location(step, rest[0], "label", rest.getOrNull(2))
        return Location(step, option = rest[0])
    }

    fun isConflict(error: String): Boolean = error == CONFLICT || error.startsWith("$CONFLICT:")

    /** Problems the shell can see before asking Core, with the codes and locations Core would answer. */
    fun localProblem(id: String, step: JSONObject): FlowError? {
        fun problem(code: String, where: Location, detail: Map<String, String> = emptyMap()) =
            FlowError(code, where, detail, "visitor_flow.$code")
        when (step.optString("kind")) {
            "page" -> {
                val options = step.optJSONArray("options")
                if (options == null || options.length() == 0) return problem("no_options", Location(id))
                if (options.length() > MAX_OPTIONS) return problem("too_many_options", Location(id),
                    mapOf("limit" to MAX_OPTIONS.toString(), "value" to options.length().toString()))
                var primary = 0
                for (i in 0 until options.length()) {
                    val option = options.optJSONObject(i) ?: return problem("bad_step", Location(id))
                    val at = Location(id, option.optString("id"))
                    if (option.optString("style") == "primary") primary++
                    if (option.optJSONObject("label") == null && option.optString("purpose").isEmpty())
                        return problem("option_needs_label", at)
                    if (option.optString("to").isEmpty()) return problem("missing_target", at)
                }
                if (primary > 1) return problem("multiple_primary", Location(id))
            }
            "notify" -> if (step.optString("to").isEmpty()) return problem("missing_target", Location(id))
        }
        return null
    }
}
