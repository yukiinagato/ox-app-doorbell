// The native editor of the door-station visitor flow (docs/en/visitor-flow-contract.md, section 8).
//
// Everything is written the way the contract asks: the scalar keys as leaves, every step as one
// whole value, and one batch per save so Core validates the graph on the configuration the batch
// would leave. Core's validation answers are shown next to the control they name (inside the open
// dialog, or on the settings row); an unresolved configuration conflict is shown with a pointer
// instead of a retry.
package jp.ox.doorbell

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.text.InputFilter
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.io.ByteArrayOutputStream
import java.security.SecureRandom
import org.json.JSONArray
import org.json.JSONObject

internal class VisitorFlowEditor(
    private val a: SettingsActivity,
    private val assets: NativeSettingsSections,
) {
    private val random = SecureRandom()

    private fun L(key: String, vararg args: Any): String = a.label(key, *args)
    private val cfg: JSONObject? get() = a.config
    private val languages: List<String> get() = FlowEdit.languages(cfg)
    private fun add(card: LinearLayout, view: View) = with(a) { card.row(view) }
    private val unset: String get() = L("settings.value_unset")

    /** A localized answer and the parsed error it came from (null for a shell-side message). */
    private class Problem(val message: String, val error: FlowEdit.FlowError?)

    /** A note under a control of an open dialog; [open] reopens the dialog that edits a row's field. */
    private class Spot(val note: TextView, val control: View, val open: ((Problem) -> Unit)?)

    private class Notes {
        val spots = LinkedHashMap<String, Spot>()
    }

    /** The notes of the dialog being built; read only synchronously while its build runs. */
    private var notes: Notes? = null

    /** List-level answers: "start", "door:<door>", "step:<id>"; the empty key is the banner. */
    private val listProblems = HashMap<String, String>()
    private var revealList: String? = null

    private fun problem(error: String, detail: JSONObject?): Problem {
        if (FlowEdit.isConflict(error)) return Problem(L("flow_editor.conflict"), null)
        val parsed = FlowEdit.parseError(error, detail, Texts::langDisplayName)
            ?: return Problem(L("visitor_flow.invalid", error), null)
        return problem(parsed)
    }

    private fun problem(error: FlowEdit.FlowError): Problem {
        val key = "flow_error." + error.code
        val message = L(key, *error.args())
        return if (message.isEmpty() || message == key) Problem(L("visitor_flow.invalid", error.raw), error)
        else Problem(message, error)
    }

    private fun errorInk(): Int = ShellUi.roleInk(a.palette.danger, a.palette)

    private fun noteView(): TextView = ShellUi.label(a, "", TextRole.SUPPORTING, errorInk()).apply {
        visibility = View.GONE
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
    }

    /** Puts a note under [control] (just added to [box]) and registers it under [key]. */
    private fun attachNote(box: LinearLayout, key: String, control: View,
                           open: ((Problem) -> Unit)? = null) {
        val note = noteView()
        box.addView(note, ShellUi.matchWrap())
        notes?.spots?.put(key, Spot(note, control, open))
    }

    /** Hides one note of the dialog being built; the returned function stays valid after the build. */
    private fun noteClearer(): (String) -> Unit {
        val owner = notes
        return { key -> owner?.spots?.get(key)?.note?.visibility = View.GONE }
    }

    /** The spots, most specific first, that an error location can land on in a dialog. */
    private fun spotKeys(at: FlowEdit.Location): List<String> {
        val lang = at.lang
        val image = at.image
        val option = at.option
        val field = at.field
        return when {
            image != null && field == "alt" -> listOfNotNull(lang?.let { "alt.$it" }, "alt", "img.$image")
            image != null -> listOf("img.$image")
            option != null && field == "label" ->
                listOfNotNull(lang?.let { "label.$it" }, "label", "o.$option")
            option != null && field != null -> listOf(field, "o.$option")
            option != null -> listOf("o.$option")
            field != null -> listOfNotNull(lang?.let { "$field.$it" }, field)
            else -> emptyList()
        }
    }

    private fun item(title: String, value: String = "", note: String = "", onClick: (() -> Unit)?): View =
        ShellUi.row(a, a.palette, title, value, note, enabled = !a.readOnly, onClick = onClick)

    // ---------- the settings group ----------

    fun section() {
        val state = FlowEdit.read(cfg)
        val card = a.section(L("flow_editor.title"))
        listProblem(card, "")
        add(card, a.toggleRow(L("flow_editor.enabled"), "visitor_flow.enabled", state.enabled,
                              L("flow_editor.enabled_hint")))
        if (!state.written) {
            add(card, a.rowNote(L("flow_editor.default_note")))
            add(card, item(L("flow_editor.customize")) { applyTemplate("default", confirmFirst = false) })
            templates(state)
            return
        }
        val pages = FlowEdit.pages(state.steps)
        add(card, item(L("flow_editor.start"), stepName(state, state.start)) {
            pickStep(L("flow_editor.start"), pages.map { it to stepName(state, it) }) {
                writeLeaf("start", "visitor_flow.start", it)
            }
        })
        listProblem(card, "start")
        val doorStarts = FlowEdit.doorStarts(cfg)
        for (door in a.doorIds()) {
            val own = doorStarts[door]
            add(card, item(L("flow_editor.door_start") + " · " + a.doorLabel(door),
                           if (own == null) L("flow_editor.door_start_inherit") else stepName(state, own)) {
                val options = listOf("" to L("flow_editor.door_start_inherit")) +
                    pages.map { it to stepName(state, it) }
                pickStep(L("flow_editor.door_start"), options) { picked ->
                    listProblems.remove("door:$door")
                    if (picked.isEmpty()) a.deleteKey(FlowEdit.doorStartKey(door))
                    else writeLeaf("door:$door", FlowEdit.doorStartKey(door), picked)
                }
            })
            listProblem(card, "door:$door")
        }
        add(card, a.numberRow(L("flow_editor.idle_s"), "visitor_flow.idle_s", state.idleS,
                              FlowEdit.IDLE_MIN, FlowEdit.IDLE_MAX))
        add(card, a.toggleRow(L("flow_editor.require_call"), "visitor_flow.require_call",
                              state.requireCall,
                              if (state.requireCall) "" else L("flow_editor.require_call_off_warning")))

        val steps = a.section(L("flow_editor.steps"))
        for (id in FlowEdit.order(state)) {
            val step = state.steps.getValue(id)
            val summary = kindLabel(step.optString("kind")) + " · " + id + summaryOf(step)
            add(steps, item(stepName(state, id), summary,
                            if (id == state.start) L("flow_editor.start") else "") {
                listProblems.remove("step:$id")
                stepMenu(state, id)
            })
            listProblem(steps, "step:$id")
        }
        if (state.steps.size < FlowEdit.MAX_STEPS)
            add(steps, item(L("flow_editor.add_step")) { addStep(state) })
        add(steps, item(L("flow_editor.preview")) { preview(state.steps, state.start) })
        templates(state)
        add(card, a.destructiveRow(L("flow_editor.reset_default"), L("flow_editor.reset_default_confirm")) {
            confirm(L("flow_editor.reset_default"), L("flow_editor.reset_default_confirm"),
                    L("flow_editor.reset_default")) {
                writeBatch(FlowEdit.resetOps(cfg))
            }
        })
    }

    /** The answer of a refused list-level write, under the row it names. */
    private fun listProblem(card: LinearLayout, key: String) {
        val text = listProblems[key] ?: return
        val note = noteView().apply {
            this.text = text
            visibility = View.VISIBLE
            val pad = ShellUi.dp(a, 16)
            setPadding(pad, ShellUi.dp(a, 4), pad, ShellUi.dp(a, 8))
        }
        add(card, note)
        if (revealList == key) {
            revealList = null
            note.post { note.requestRectangleOnScreen(android.graphics.Rect(0, 0, note.width, note.height), true) }
        }
    }

    private fun showListProblem(answer: Problem) {
        val at = answer.error?.location
        val key = when {
            at == null -> ""
            at.start && at.door != null -> "door:${at.door}"
            at.start -> "start"
            at.step != null -> "step:${at.step}"
            else -> ""
        }
        listProblems.clear()
        listProblems[key] = answer.message
        revealList = key
        a.render()
    }

    /** A scalar flow key through the batch route, so a refusal comes back with its code and location. */
    private fun writeLeaf(listKey: String, key: String, value: String) {
        listProblems.remove(listKey)
        a.writeOpsReporting(listOf(ConfigOp.Set(key, JSONObject.quote(value)))) { result ->
            if (result != null && !result.ok) showListProblem(problem(result.error, result.detail))
        }
    }

    private fun templates(state: FlowEdit.State) {
        val card = a.section(L("flow_editor.templates"))
        for ((name, key) in listOf("purposes" to "flow_editor.template_purposes",
                                    "delivery" to "flow_editor.template_delivery")) {
            add(card, item(L(key)) { applyTemplate(name, confirmFirst = state.written) })
        }
    }

    private fun summaryOf(step: JSONObject): String =
        if (step.optString("kind") == "page")
            " · " + L("flow_editor.summary_options", (step.optJSONArray("options")?.length() ?: 0).toString())
        else ""

    private fun kindLabel(kind: String): String = when (kind) {
        "page", "call", "notify", "end" -> L("flow_editor.kind_$kind")
        else -> kind
    }

    /** A step's own words when it has any, otherwise what it is and its id. */
    private fun stepName(state: FlowEdit.State, id: String): String {
        if (id.isEmpty()) return unset
        val step = state.steps[id] ?: return id
        val text = a.localizedLabel(step.optJSONObject("title") ?: step.optJSONObject("message"), "")
        if (text.isNotEmpty()) return text
        val purpose = step.optString("purpose")
        val kind = kindLabel(step.optString("kind"))
        return when {
            purpose.isNotEmpty() -> kind + " · " + a.purposeLabel(purpose)
            step.optString("kind") == "call" -> kind + " · " + L("flow_editor.purpose_none")
            else -> kind + " · " + id
        }
    }

    // ---------- list-level actions ----------

    private fun stepMenu(state: FlowEdit.State, id: String) {
        val step = state.steps[id] ?: return
        val options = ArrayList<Pair<String, String>>()
        options.add("edit" to L("admin.edit"))
        if (step.optString("kind") == "page" && id != state.start)
            options.add("start" to L("flow_editor.set_start"))
        val sequence = FlowEdit.order(state)
        val at = sequence.indexOf(id)
        options.add("preview" to L("flow_editor.preview"))
        if (at > 0) options.add("up" to L("nset.move_up"))
        if (at in 0 until sequence.size - 1) options.add("down" to L("nset.move_down"))
        options.add("duplicate" to L("flow_editor.duplicate_step"))
        options.add("delete" to L("flow_editor.delete_step"))
        pickStep(stepName(state, id), options) { pick ->
            when (pick) {
                "edit" -> editStep(id, false, step)
                "start" -> writeLeaf("start", "visitor_flow.start", id)
                "preview" -> preview(state.steps, if (step.optString("kind") == "page") id else state.start)
                "up" -> writeBatch(FlowEdit.moveOps(state, id, -1))
                "down" -> writeBatch(FlowEdit.moveOps(state, id, 1))
                "duplicate" -> duplicate(state, id, step)
                "delete" -> deleteStep(state, id)
            }
        }
    }

    private fun addStep(state: FlowEdit.State) {
        pickStep(L("flow_editor.step_kind"), FlowEdit.KINDS.map { it to kindLabel(it) }) { kind ->
            val id = FlowEdit.newId(FlowEdit.prefixFor(kind), state.steps.keys, random.nextLong())
            editStep(id, true, newStep(kind))
        }
    }

    private fun duplicate(state: FlowEdit.State, id: String, step: JSONObject) {
        if (state.steps.size >= FlowEdit.MAX_STEPS) {
            showListProblem(problem(FlowEdit.FlowError("too_many_steps", null,
                mapOf("limit" to FlowEdit.MAX_STEPS.toString(), "value" to (state.steps.size + 1).toString()),
                "visitor_flow.too_many_steps")))
            return
        }
        val copy = JSONObject(step.toString())
        val target = FlowEdit.newId(FlowEdit.prefixFor(step.optString("kind")), state.steps.keys, random.nextLong())
        writeBatch(FlowEdit.duplicateOps(state, id, target, copy))
    }

    private fun deleteStep(state: FlowEdit.State, id: String) {
        val users = FlowEdit.referencedBy(state.steps, id)
        if (users.isNotEmpty()) {
            failure(L("flow_editor.step_in_use", users.joinToString(", ") { stepName(state, it) }))
            return
        }
        confirm(L("flow_editor.delete_step"), stepName(state, id), L("admin.delete")) {
            writeBatch(FlowEdit.deleteStepOps(id))
        }
    }

    private fun applyTemplate(name: String, confirmFirst: Boolean) {
        val run = {
            a.coreCall({ a.app.core.visitorFlowTemplate(name) }) { result ->
                val flow = result?.optJSONObject("flow")
                if (result?.optBoolean("ok") != true || flow == null) failure(L("admin.save_failed"))
                else writeBatch(FlowEdit.templateOps(cfg, flow))
            }
        }
        if (confirmFirst) confirm(L("flow_editor.templates"), L("flow_editor.template_confirm"),
                                  L("admin.save")) { run() }
        else run()
    }

    private fun writeBatch(ops: List<ConfigOp>) {
        if (ops.isEmpty()) return
        listProblems.clear()
        a.writeOpsReporting(ops) { result ->
            if (result != null && !result.ok) showListProblem(problem(result.error, result.detail))
        }
    }

    // ---------- the step dialog ----------

    /** Steps a step dialog creates on the way (a call or an end page picked as a target). */
    private class Session(val id: String, val isNew: Boolean, val draft: JSONObject) {
        val created = LinkedHashMap<String, JSONObject>()
    }

    private fun editStep(id: String, isNew: Boolean, initial: JSONObject) {
        val session = Session(id, isNew, JSONObject(initial.toString()))
        val kind = session.draft.optString("kind")
        formDialog(
            title = kindLabel(kind) + " · " + id,
            build = { box, rebuild -> buildStepForm(session, box, rebuild) },
            onSave = { sync, fail, close ->
                sync()
                val local = FlowEdit.localProblem(session.id, session.draft)
                if (local != null) {
                    fail(problem(local))
                } else {
                    // New steps take the next order; an edited step keeps the one it has.
                    val fresh = LinkedHashMap<String, JSONObject>()
                    if (session.isNew) fresh[session.id] = session.draft
                    fresh.putAll(session.created)
                    val steps = LinkedHashMap<String, JSONObject>()
                    if (!session.isNew) steps[session.id] = session.draft
                    steps.putAll(FlowEdit.withNextOrders(FlowEdit.read(cfg).steps, fresh))
                    a.writeOpsReporting(FlowEdit.saveStepOps(steps)) { result ->
                        when {
                            result == null -> fail(Problem(L("settings.offline"), null))
                            result.ok -> close()
                            else -> fail(problem(result.error, result.detail))
                        }
                    }
                }
            },
        )
    }

    private fun buildStepForm(session: Session, box: LinearLayout, rebuild: () -> Unit): () -> Unit {
        val draft = session.draft
        val syncs = ArrayList<() -> Unit>()
        fun sync() { for (s in syncs) s() }
        // Structural edits first copy what was typed, then change the draft, then redraw.
        fun change(edit: () -> Unit) { sync(); edit(); rebuild() }
        val state = FlowEdit.read(cfg)
        val known = LinkedHashMap<String, JSONObject>(state.steps).apply { putAll(session.created) }
        known[session.id] = draft

        when (draft.optString("kind")) {
            "page", "end" -> {
                val title = langFields(box, L("flow_editor.field_title"), draft.optJSONObject("title"),
                                       FlowEdit.MAX_TITLE, name = "title")
                val body = langFields(box, L("flow_editor.field_body"), draft.optJSONObject("body"),
                                      FlowEdit.MAX_BODY, multiline = true, name = "body")
                syncs.add {
                    putText(draft, "title", title())
                    putText(draft, "body", body())
                }
                imagesSection(draft, box, ::change)
                if (draft.optString("kind") == "end") {
                    val seconds = field(box, L("flow_editor.field_return_s"),
                        draft.optInt("return_s", FlowEdit.RETURN_DEFAULT).toString(), InputType.TYPE_CLASS_NUMBER)
                    syncs.add {
                        seconds.text.toString().trim().toIntOrNull()?.let {
                            draft.put("return_s", it.coerceIn(FlowEdit.RETURN_MIN, FlowEdit.RETURN_MAX))
                        }
                    }
                } else {
                    optionsSection(session, known, box, ::change)
                }
            }
            "call" -> {
                caption(box, L("flow_editor.field_purpose"))
                box.addView(item(L("flow_editor.field_purpose"), purposeName(draft.optString("purpose"))) {
                    pickPurpose { picked -> change { putOrRemove(draft, "purpose", picked) } }
                }, ShellUi.matchWrap())
                val pages = FlowEdit.pages(known)
                box.addView(item(L("flow_editor.field_on_unanswered"),
                    draft.optString("on_unanswered").takeIf { it.isNotEmpty() }
                        ?.let { stepName(FlowEdit.State(true, true, "", 0, true, known), it) }
                        ?: L("flow_editor.on_unanswered_none")) {
                    val options = listOf("" to L("flow_editor.on_unanswered_none")) +
                        pages.map { it to stepName(FlowEdit.State(true, true, "", 0, true, known), it) }
                    pickStep(L("flow_editor.field_on_unanswered"), options) { picked ->
                        change { putOrRemove(draft, "on_unanswered", picked) }
                    }
                }, ShellUi.matchWrap())
            }
            "notify" -> {
                val message = langFields(box, L("flow_editor.field_message"), draft.optJSONObject("message"),
                                         FlowEdit.MAX_MESSAGE, multiline = true, name = "message")
                syncs.add { putText(draft, "message", message()) }
                box.addView(item(L("flow_editor.field_purpose"), purposeName(draft.optString("purpose"))) {
                    pickPurpose { picked -> change { putOrRemove(draft, "purpose", picked) } }
                }, ShellUi.matchWrap())
                box.addView(item(L("flow_editor.field_snapshot"), snapshotName(draft.optJSONObject("snapshot"))) {
                    pickSnapshot { picked -> change { putOrRemove(draft, "snapshot", picked) } }
                }, ShellUi.matchWrap())
                val shown = FlowEdit.State(true, true, "", 0, true, known)
                box.addView(item(L("flow_editor.field_to"),
                    draft.optString("to").takeIf { it.isNotEmpty() }?.let { stepName(shown, it) } ?: unset) {
                    val options = FlowEdit.ends(known).map { it to stepName(shown, it) } +
                        listOf(NEW_END to L("flow_editor.target_new_end"))
                    pickStep(L("flow_editor.field_to"), options) { picked ->
                        change {
                            draft.put("to", if (picked == NEW_END) createStep(session, "end") else picked)
                        }
                    }
                }, ShellUi.matchWrap())
            }
        }
        box.addView(item(L("flow_editor.preview")) {
            sync()
            preview(known, if (draft.optString("kind") == "page") session.id else state.start)
        }, ShellUi.matchWrap())
        return ::sync
    }

    private fun purposeName(id: String): String =
        if (id.isEmpty()) L("flow_editor.purpose_none") else a.purposeLabel(id)

    private fun snapshotName(snapshot: JSONObject?): String = when (snapshot?.optString("source")) {
        "door_station" -> L("flow_editor.snapshot_door_station")
        "media_source" -> L("flow_editor.snapshot_camera", snapshot.optString("id"))
        else -> L("flow_editor.snapshot_none")
    }

    private fun pickPurpose(onPick: (String) -> Unit) {
        val options = listOf("" to L("flow_editor.purpose_none")) +
            VisitPurposes.all(cfg).map { it to a.purposeLabel(it) }
        pickStep(L("flow_editor.field_purpose"), options, onPick)
    }

    private fun pickSnapshot(onPick: (JSONObject?) -> Unit) {
        val cameras = FlowEdit.snapshotCameras(cfg)
        val options = ArrayList<Pair<String, String>>()
        options.add("none" to L("flow_editor.snapshot_none"))
        for (camera in cameras) options.add("cam:$camera" to L("flow_editor.snapshot_camera", camera))
        options.add("door" to L("flow_editor.snapshot_door_station"))
        pickStep(L("flow_editor.field_snapshot") + if (cameras.isEmpty()) "\n" + L("flow_editor.snapshot_no_camera") else "",
                 options) { picked ->
            onPick(when {
                picked == "door" -> FlowEdit.snapshotJson("door_station")
                picked.startsWith("cam:") -> FlowEdit.snapshotJson("media_source", picked.removePrefix("cam:"))
                else -> null
            })
        }
    }

    // ---------- images ----------

    private fun imagesSection(draft: JSONObject, box: LinearLayout, change: (() -> Unit) -> Unit) {
        caption(box, L("flow_editor.field_images"))
        val images = FlowEdit.toList(draft.optJSONArray("images"))
        images.forEachIndexed { index, image ->
            val hash = image.optString("asset")
            val label = cfg?.optJSONObject("assets")?.optJSONObject(hash)?.optString("label").orEmpty()
                .ifEmpty { hash.take(8) }
            val place = if (image.optString("place") == "below") L("flow_editor.image_below")
                        else L("flow_editor.image_above")
            val clear = noteClearer()
            val row = item(label, place, a.localizedLabel(image.optJSONObject("alt"), "")) {
                clear("img.$index")
                imageMenu(images, index, draft, change)
            }
            box.addView(row, ShellUi.matchWrap())
            attachNote(box, "img.$index", row) { answer -> altDialog(image, { change { } }, answer) }
        }
        if (images.size < FlowEdit.MAX_IMAGES) box.addView(item(L("flow_editor.add_image")) {
            val existing = AssetTypes.list(cfg, AssetTypes.IMAGES)
            val options = existing.map { (hash, entry) ->
                hash to entry.optString("label").ifEmpty { hash.take(8) }
            } + listOf(UPLOAD to L("flow_editor.image_upload"))
            pickStep(L("flow_editor.add_image"), options) { picked ->
                if (picked == UPLOAD) uploadImage { hash -> change { appendImage(draft, hash) } }
                else change { appendImage(draft, picked) }
            }
        }, ShellUi.matchWrap())
    }

    private fun appendImage(draft: JSONObject, hash: String) {
        val images = FlowEdit.toList(draft.optJSONArray("images"))
        images.add(JSONObject().put("asset", hash).put("place", "above"))
        draft.put("images", FlowEdit.toArray(images))
    }

    private fun imageMenu(images: MutableList<JSONObject>, index: Int, draft: JSONObject,
                          change: (() -> Unit) -> Unit) {
        val image = images[index]
        val below = image.optString("place") == "below"
        val options = ArrayList<Pair<String, String>>()
        options.add("alt" to L("flow_editor.image_alt"))
        options.add("place" to L("flow_editor.image_place_current",
            if (below) L("flow_editor.image_above") else L("flow_editor.image_below")))
        if (index > 0) options.add("up" to L("nset.move_up"))
        if (index < images.size - 1) options.add("down" to L("nset.move_down"))
        options.add("delete" to L("admin.delete"))
        pickStep(L("flow_editor.field_images"), options) { pick ->
            when (pick) {
                "alt" -> altDialog(image, { change { } })
                "place" -> change { image.put("place", if (below) "above" else "below") }
                "up" -> change { FlowEdit.move(images, index, -1); draft.put("images", FlowEdit.toArray(images)) }
                "down" -> change { FlowEdit.move(images, index, 1); draft.put("images", FlowEdit.toArray(images)) }
                "delete" -> change {
                    images.removeAt(index)
                    if (images.isEmpty()) draft.remove("images") else draft.put("images", FlowEdit.toArray(images))
                }
            }
        }
    }

    private fun altDialog(image: JSONObject, done: () -> Unit, initial: Problem? = null) {
        formDialog(
            title = L("flow_editor.image_alt"),
            build = { box, _ ->
                val alt = langFields(box, L("flow_editor.image_alt"), image.optJSONObject("alt"), FlowEdit.MAX_ALT,
                                     name = "alt")
                val sync: () -> Unit = { putText(image, "alt", alt()) }
                sync
            },
            onSave = { sync, _, close -> sync(); close(); done() },
            initial = initial,
        )
    }

    /** Pick a JPEG or PNG, shrink it to about 1280 px and 400 KB, add it to the ledger. */
    private fun uploadImage(done: (String) -> Unit) {
        assets.pick("image/*", arrayOf("image/jpeg", "image/png", "image/*")) { bytes, name ->
            Thread({
                val prepared = try { shrink(bytes) } catch (_: OutOfMemoryError) { null }
                a.ui.post {
                    if (prepared == null) a.toast(L("admin.asset_format_unsupported"))
                    else assets.addAsset(prepared.first, prepared.second, name.ifEmpty { "image" }, done)
                }
            }, "doorbell-flow-image").apply { isDaemon = true }.start()
        }
    }

    private fun shrink(bytes: ByteArray): Pair<ByteArray, String>? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_EDGE * 2) sample *= 2
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
            BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        val scale = minOf(1f, MAX_EDGE.toFloat() / maxOf(bitmap.width, bitmap.height))
        val scaled = if (scale < 1f) Bitmap.createScaledBitmap(bitmap,
            (bitmap.width * scale).toInt().coerceAtLeast(1),
            (bitmap.height * scale).toInt().coerceAtLeast(1), true) else bitmap
        var last: ByteArray? = null
        for (quality in intArrayOf(85, 75, 65, 55, 45, 35)) {
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, quality, out)
            last = out.toByteArray()
            if (last.size <= TARGET_BYTES) break
        }
        return last?.takeIf { it.size <= AssetTypes.MAX_BYTES }?.let { it to "image/jpeg" }
    }

    // ---------- options ----------

    private fun optionsSection(session: Session, known: Map<String, JSONObject>, box: LinearLayout,
                               change: (() -> Unit) -> Unit) {
        val draft = session.draft
        caption(box, L("flow_editor.field_options"))
        val options = FlowEdit.toList(draft.optJSONArray("options"))
        val shown = FlowEdit.State(true, true, "", 0, true, known)
        options.forEachIndexed { index, option ->
            val label = optionName(option)
            val flags = listOfNotNull(
                if (option.optString("style") == "primary") L("flow_editor.option_primary") else null,
                if (!option.optBoolean("enabled", true)) L("flow_editor.option_enabled") + " ✗" else null,
            ).joinToString(" · ")
            val purpose = option.optString("purpose")
            val switchedOff = purpose.isNotEmpty() && !VisitPurposes.isEnabled(cfg, purpose)
            val note = if (switchedOff) listOf(flags, L("flow_error.disabled_purpose"))
                .filter { it.isNotEmpty() }.joinToString("\n") else flags
            val target = option.optString("to").takeIf { it.isNotEmpty() }?.let { stepName(shown, it) } ?: unset
            val optionId = option.optString("id")
            val clear = noteClearer()
            val row = item(label, target, note) {
                clear("o.$optionId")
                optionMenu(session, known, options, index, change)
            }
            box.addView(row, ShellUi.matchWrap())
            attachNote(box, "o.$optionId", row) { answer ->
                editOption(session, known, option, index, options, change, answer)
            }
        }
        if (options.size < FlowEdit.MAX_OPTIONS) box.addView(item(L("flow_editor.add_option")) {
            val fresh = JSONObject().put("id", FlowEdit.newId("o", options.map { it.optString("id") }, random.nextLong()))
            editOption(session, known, fresh, null, options, change)
        }, ShellUi.matchWrap())
    }

    private fun optionName(option: JSONObject): String {
        val own = a.localizedLabel(option.optJSONObject("label"), "")
        val purpose = option.optString("purpose")
        val base = own.ifEmpty { if (purpose.isNotEmpty()) a.purposeLabel(purpose) else option.optString("id") }
        return base
    }

    private fun optionMenu(session: Session, known: Map<String, JSONObject>, options: MutableList<JSONObject>,
                           index: Int, change: (() -> Unit) -> Unit) {
        val menu = ArrayList<Pair<String, String>>()
        menu.add("edit" to L("admin.edit"))
        if (index > 0) menu.add("up" to L("nset.move_up"))
        if (index < options.size - 1) menu.add("down" to L("nset.move_down"))
        menu.add("delete" to L("admin.delete"))
        pickStep(optionName(options[index]), menu) { pick ->
            val save = { session.draft.put("options", FlowEdit.toArray(options)); Unit }
            when (pick) {
                "edit" -> editOption(session, known, options[index], index, options, change)
                "up" -> change { FlowEdit.move(options, index, -1); save() }
                "down" -> change { FlowEdit.move(options, index, 1); save() }
                "delete" -> change { options.removeAt(index); save() }
            }
        }
    }

    private fun editOption(session: Session, known: Map<String, JSONObject>, original: JSONObject, index: Int?,
                           options: MutableList<JSONObject>, change: (() -> Unit) -> Unit,
                           initial: Problem? = null) {
        val option = JSONObject(original.toString())
        formDialog(
            title = L("flow_editor.field_options"),
            build = { box, rebuild ->
                val label = langFields(box, L("flow_editor.option_label"), option.optJSONObject("label"),
                                       FlowEdit.MAX_LABEL, name = "label")
                val primary = checkbox(box, L("flow_editor.option_primary"), option.optString("style") == "primary")
                val shown = checkbox(box, L("flow_editor.option_enabled"), option.optBoolean("enabled", true))
                val sync: () -> Unit = {
                    putText(option, "label", label())
                    if (primary.isChecked) option.put("style", "primary") else option.remove("style")
                    if (shown.isChecked) option.remove("enabled") else option.put("enabled", false)
                }
                box.addView(item(L("flow_editor.option_purpose"), purposeName(option.optString("purpose"))) {
                    sync()
                    pickPurpose { picked -> putOrRemove(option, "purpose", picked); rebuild() }
                }, ShellUi.matchWrap())
                val chosen = option.optString("purpose")
                if (chosen.isNotEmpty() && !VisitPurposes.isEnabled(cfg, chosen))
                    box.addView(noteView().apply {
                        text = L("flow_error.disabled_purpose")
                        visibility = View.VISIBLE
                    }, ShellUi.matchWrap())
                val own = option.optString("icon")
                box.addView(item(L("flow_editor.icon_title"),
                    if (own.isEmpty()) L("flow_editor.icon_inherit")
                    else L(FlowIcons.glyph(option.optString("purpose"), own).labelKey)) {
                    sync()
                    pickIcon { picked -> putOrRemove(option, "icon", picked); rebuild() }
                }, ShellUi.matchWrap())
                val names = FlowEdit.State(true, true, "", 0, true, known)
                val clear = noteClearer()
                val targetRow = item(L("flow_editor.option_target"),
                    option.optString("to").takeIf { it.isNotEmpty() }?.let { stepName(names, it) } ?: unset) {
                    clear("to")
                    sync()
                    val choices = known.filterKeys { it != session.id }.keys.sorted().map { it to stepName(names, it) } +
                        listOf(NEW_CALL to L("flow_editor.target_new_call"), NEW_END to L("flow_editor.target_new_end"))
                    pickStep(L("flow_editor.option_target"), choices) { picked ->
                        option.put("to", when (picked) {
                            NEW_CALL -> createStep(session, "call")
                            NEW_END -> createStep(session, "end")
                            else -> picked
                        })
                        rebuild()
                    }
                }
                box.addView(targetRow, ShellUi.matchWrap())
                attachNote(box, "to", targetRow)
                sync
            },
            initial = initial,
            onSave = { sync, fail, close ->
                sync()
                val at = FlowEdit.Location(session.id, option.optString("id"))
                if (option.optJSONObject("label") == null && option.optString("purpose").isEmpty()) {
                    fail(problem(FlowEdit.FlowError("option_needs_label", at.copy(field = "label"),
                        emptyMap(), "visitor_flow.option_needs_label")))
                } else if (option.optString("to").isEmpty()) {
                    fail(problem(FlowEdit.FlowError("missing_target", at.copy(field = "to"),
                        emptyMap(), "visitor_flow.missing_target")))
                } else {
                    change {
                        if (index == null) options.add(option) else options[index] = option
                        // One main button per page: choosing it here releases the others.
                        val array = FlowEdit.toArray(options)
                        if (option.optString("style") == "primary") FlowEdit.makePrimary(array, option.optString("id"))
                        session.draft.put("options", array)
                    }
                    close()
                }
            },
        )
    }

    /** A new call or end step that is written in the same batch as the step that points to it. */
    private fun createStep(session: Session, kind: String): String {
        val taken = FlowEdit.read(cfg).steps.keys + session.created.keys + session.id
        val id = FlowEdit.newId(FlowEdit.prefixFor(kind), taken, random.nextLong())
        session.created[id] = newStep(kind)
        return id
    }

    private fun newStep(kind: String): JSONObject = when (kind) {
        "page" -> JSONObject().put("kind", "page").put("options", JSONArray())
        "call" -> JSONObject().put("kind", "call")
        "notify" -> JSONObject().put("kind", "notify")
        else -> JSONObject().put("kind", "end").put("return_s", FlowEdit.RETURN_DEFAULT)
            .also { step -> thanks()?.let { step.put("title", it) } }
    }

    /** "Message sent" in every configured language, so a new end page reads sensibly at once. */
    private fun thanks(): JSONObject? {
        val out = JSONObject()
        for (lang in languages) {
            val texts = Texts(a)
            texts.setLang(lang)
            val text = texts.t("flow.sent", R.string.flow_sent)
            if (text.isNotEmpty()) out.put(lang, text)
        }
        return if (out.length() == 0) null else out
    }

    // ---------- icon picker and preview ----------

    /** The vendored icons by name; the choice is stored as the emoji every shell maps to its own set. */
    private fun pickIcon(onPick: (String) -> Unit) {
        val roles = UiRoles.from(a.palette)
        var dialog: android.content.DialogInterface? = null
        val column = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            val pad = ShellUi.dp(a, 20)
            setPadding(pad, ShellUi.dp(a, 8), pad, ShellUi.dp(a, 8))
        }
        fun entry(label: String, drawable: Int, value: String) {
            val button = UiKit.actionButton(a, label, roles, ActionRole.SECONDARY, 56) {
                dialog?.dismiss()
                onPick(value)
            }
            if (drawable != 0) PlatformUi.setButtonIcon(button, drawable)
            column.addView(button, ShellUi.matchWrap().apply { topMargin = ShellUi.dp(a, 6) })
        }
        entry(L("flow_editor.icon_inherit"), 0, "")
        for (glyph in FlowIcons.Glyph.values()) entry(L(glyph.labelKey), glyph.drawable, glyph.emoji)
        dialog = ShellDialogBuilder(a).setTitle(L("flow_editor.icon_title"))
            .setView(ScrollView(a).apply { addView(column) })
            .setNegativeButton(L("admin.cancel"), null).create()
        dialog.show()
    }

    /**
     * Walks [steps] from the page [start] with the door station's own walker and page renderer.
     * The terminal action is only described: nobody is called and nothing is sent.
     */
    private fun preview(steps: Map<String, JSONObject>, start: String) {
        val first = if (steps[start]?.optString("kind") == "page") start
            else FlowEdit.pages(steps).firstOrNull()
        if (first == null) {
            a.toast(problem(FlowEdit.FlowError("no_options", null, emptyMap(), "visitor_flow.no_options")).message)
            return
        }
        val langs = languages
        val walker = FlowWalker(FlowPreview.document(cfg, steps, first), langs.first())
        val texts = Texts(a).apply { setLang(langs.first()) }
        val roles = UiRoles.from(a.palette)
        val pad = ShellUi.dp(a, 16)
        val root = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(ShellUi.opaque(a.palette.ground))
            layoutParams = android.view.ViewGroup.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                (a.resources.displayMetrics.heightPixels * PREVIEW_HEIGHT_SHARE).toInt())
        }
        val note = ShellUi.label(a, L("flow_editor.preview_note"), TextRole.LABEL,
                                 ShellUi.opaque(a.palette.muted)).apply { setPadding(pad, pad / 2, pad, 0) }
        val action = ShellUi.label(a, "", TextRole.BODY).apply {
            setPadding(pad, pad / 4, pad, 0)
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        val content = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            gravity = android.view.Gravity.CENTER
            setPadding(pad, pad / 2, pad, pad / 2)
        }
        val dock = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad / 2, pad, pad)
        }
        var outcome: FlowPreview.Outcome = FlowPreview.Outcome.None
        var waiting = false
        lateinit var panel: VisitorFlowPanel
        fun draw() {
            val snapshot = walker.snapshot()
            action.text = when (val o = outcome) {
                FlowPreview.Outcome.None -> ""
                is FlowPreview.Outcome.Ring ->
                    if (o.purpose.isEmpty()) L("flow_editor.preview_would_call_none")
                    else L("flow_editor.preview_would_call", a.purposeLabel(o.purpose))
                is FlowPreview.Outcome.Message ->
                    L("flow_editor.preview_would_notify", snapshot.title ?: o.then.orEmpty())
            }
            action.visibility = if (action.text.isEmpty()) View.GONE else View.VISIBLE
            if (snapshot.mode == FlowWalker.MODE_PAGE || snapshot.mode == FlowWalker.MODE_END) {
                panel.render(snapshot, texts, roles, roles, null, "", 0, true)
                return
            }
            panel.hide()
            dock.visibility = View.VISIBLE
            dock.addView(UiKit.actionButton(a, L("flow_editor.preview_restart"), roles,
                                            ActionRole.PRIMARY, 56) {
                walker.apply(FlowEvent.CallEnded("ended"))
                outcome = FlowPreview.Outcome.None
                dock.removeAllViews()
                draw()
            }, ShellUi.matchWrap())
        }
        panel = VisitorFlowPanel(
            a, content, dock, a.ui, { a.resources.displayMetrics.heightPixels },
            onOption = { id ->
                if (waiting) return@VisitorFlowPanel
                val target = walker.targetOf(id)
                val notify = target is FlowTarget.Notify
                val finish = {
                    waiting = false
                    outcome = FlowPreview.outcome(walker.apply(FlowEvent.Tap(id)), walker.currentPageId)
                    draw()
                }
                if (target == FlowTarget.Nothing || target == FlowTarget.Page || target == FlowTarget.End) {
                    finish()
                } else {
                    // The same indicator as the door station, for a simulated second; nothing is sent.
                    waiting = true
                    val busy = texts.t(if (notify) "flow.pending_notify" else "flow.pending_call",
                        if (notify) R.string.flow_pending_notify else R.string.flow_pending_call)
                    panel.setStatus("")
                    panel.setPending(id, busy)
                    a.ui.postDelayed({ panel.setStatus(busy) }, PREVIEW_STATUS_MS)
                    a.ui.postDelayed({ panel.setPending(null); finish() }, PREVIEW_PENDING_MS)
                }
            },
            onBack = { walker.apply(FlowEvent.Back); outcome = FlowPreview.Outcome.None; draw() },
            onDone = { walker.apply(FlowEvent.Done); outcome = FlowPreview.Outcome.None; draw() },
            maxColumns = 1,
        )
        val languageRow = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(pad, pad / 2, pad, 0)
        }
        for (lang in langs) languageRow.addView(
            UiKit.actionButton(a, Texts.langDisplayName(lang), roles, ActionRole.SECONDARY, 40) {
                texts.setLang(lang)
                walker.apply(FlowEvent.Language(lang))
                draw()
            }, LinearLayout.LayoutParams(0, android.view.ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                rightMargin = ShellUi.dp(a, 6)
            })
        root.addView(note, ShellUi.matchWrap())
        if (langs.size > 1) root.addView(languageRow, ShellUi.matchWrap())
        root.addView(action, ShellUi.matchWrap())
        root.addView(ScrollView(a).apply { addView(content) },
                     LinearLayout.LayoutParams(android.view.ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(dock, ShellUi.matchWrap())
        draw()
        ShellDialogBuilder(a).setTitle(L("flow_editor.preview")).setView(root)
            .setPositiveButton(L("admin.menu_close"), null).show()
    }

    // ---------- shared pieces ----------

    private fun putText(into: JSONObject, key: String, values: Map<String, String>) {
        val map = FlowEdit.textMap(values)
        if (map == null) into.remove(key) else into.put(key, map)
    }

    private fun putOrRemove(into: JSONObject, key: String, value: Any?) {
        if (value == null || (value is String && value.isEmpty())) into.remove(key) else into.put(key, value)
    }

    private fun failure(message: String) {
        ShellDialogBuilder(a).setMessage(message)
            .setPositiveButton(L("admin.menu_close"), null).show()
    }

    private fun confirm(title: String, message: String, action: String, onYes: () -> Unit) {
        ShellDialogBuilder(a).setTitle(title).setMessage(message)
            .setPositiveButton(action) { _, _ -> onYes() }
            .setNegativeButton(L("admin.cancel"), null).show()
    }

    private fun pickStep(title: String, options: List<Pair<String, String>>, onPick: (String) -> Unit) {
        ShellDialogBuilder(a).setTitle(title)
            .setItems(options.map { it.second as CharSequence }.toTypedArray()) { _, which ->
                onPick(options[which].first)
            }
            .setNegativeButton(L("admin.cancel"), null).show()
    }

    private fun caption(box: LinearLayout, text: String): View {
        val view = ShellUi.label(a, text, TextRole.LABEL).apply {
            setPadding(0, ShellUi.dp(a, 14), 0, ShellUi.dp(a, 2))
        }
        box.addView(view, ShellUi.matchWrap())
        return view
    }

    private fun checkbox(box: LinearLayout, title: String, value: Boolean): android.widget.CompoundButton =
        PlatformUi.checkbox(a).apply {
            text = title
            isChecked = value
            minHeight = ShellUi.dp(a, ShellUi.TOUCH_FLOOR_DP)
            box.addView(this, ShellUi.matchWrap())
        }

    private fun field(box: LinearLayout, title: String, value: String,
                      kind: Int = InputType.TYPE_CLASS_TEXT, max: Int = 0, lines: Int = 1,
                      noteKey: String? = null): EditText {
        val entry = PlatformUi.field(a, title, value, kind, lines)
        if (max > 0) entry.input.filters = arrayOf(InputFilter.LengthFilter(max))
        box.addView(entry.view, ShellUi.matchWrap().apply { topMargin = ShellUi.dp(a, 8) })
        if (noteKey != null) {
            attachNote(box, noteKey, entry.input)
            // Editing the field withdraws the answer that named it.
            val owner = notes
            entry.input.addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    owner?.spots?.get(noteKey)?.note?.visibility = View.GONE
                }
            })
        }
        return entry.input
    }

    /** One text field per configured language; the reader returns what is typed now. */
    private fun langFields(box: LinearLayout, title: String, current: JSONObject?, max: Int,
                           multiline: Boolean = false, name: String): () -> Map<String, String> {
        attachNote(box, name, caption(box, title))
        val fields = languages.associateWith { lang ->
            field(box, Texts.langDisplayName(lang), current?.optString(lang).orEmpty(),
                  if (multiline) InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
                  else InputType.TYPE_CLASS_TEXT, max, if (multiline) 3 else 1, noteKey = "$name.$lang")
        }
        return { fields.mapValues { it.value.text.toString() } }
    }

    /**
     * A scrolling form in a dialog. [build] fills the box and returns the function that copies what
     * is typed into the draft; calling the supplied rebuild redraws the form. [onSave] gets that
     * function, a way to show Core's answer inside the dialog, and a way to close it.
     */
    private fun formDialog(
        title: String,
        build: (LinearLayout, () -> Unit) -> (() -> Unit),
        onSave: (sync: () -> Unit, fail: (Problem) -> Unit, close: () -> Unit) -> Unit,
        initial: Problem? = null,
    ) {
        val box = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            val pad = ShellUi.dp(a, 24)
            setPadding(pad, ShellUi.dp(a, 8), pad, ShellUi.dp(a, 8))
        }
        val scroll = ScrollView(a).apply { addView(box) }
        val error = ShellUi.label(a, "", TextRole.BODY, ShellUi.roleInk(a.palette.danger, a.palette)).apply {
            visibility = View.GONE
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        var sync: () -> Unit = {}
        lateinit var rebuild: () -> Unit
        val own = Notes()
        rebuild = {
            box.removeAllViews()
            own.spots.clear()
            box.addView(error, ShellUi.matchWrap())
            notes = own
            sync = build(box) { rebuild() }
            notes = null
        }
        rebuild()
        // The answer goes under the control the location names, scrolled into view; without a
        // control here it is the form's banner at the top.
        fun place(answer: Problem) {
            val at = answer.error?.location
            val keys = if (at == null) emptyList() else spotKeys(at)
            val key = keys.firstOrNull { own.spots.containsKey(it) }
            val spot = key?.let { own.spots[it] }
            val rowField = at != null && (at.field == "label" || at.field == "alt") && key != null &&
                (key.startsWith("o.") || key.startsWith("img."))
            if (spot?.open != null && rowField) {
                spot.open.invoke(answer)
                return
            }
            if (spot == null) {
                error.text = answer.message
                error.visibility = View.VISIBLE
                scroll.post { scroll.fullScroll(View.FOCUS_UP) }
                return
            }
            spot.note.text = answer.message
            spot.note.visibility = View.VISIBLE
            scroll.post {
                spot.note.requestRectangleOnScreen(
                    android.graphics.Rect(0, 0, spot.note.width, spot.note.height), true)
                if (spot.control is EditText) spot.control.requestFocus()
            }
        }
        val dialog = ShellDialogBuilder(a).setTitle(title).setView(scroll)
            .setPositiveButton(L("admin.save"), null)
            .setNegativeButton(L("admin.cancel"), null).create()
        dialog.setOnShowListener {
            dialog.getButton(android.content.DialogInterface.BUTTON_POSITIVE).setOnClickListener {
                error.visibility = View.GONE
                for (spot in own.spots.values) spot.note.visibility = View.GONE
                onSave({ sync() }, { answer -> place(answer) }, { dialog.dismiss() })
            }
        }
        dialog.show()
        if (initial != null) scroll.post { place(initial) }
    }

    private companion object {
        const val NEW_CALL = "\u0000new_call"
        const val NEW_END = "\u0000new_end"
        const val UPLOAD = "\u0000upload"
        const val MAX_EDGE = 1280
        const val TARGET_BYTES = 400 * 1024
        const val PREVIEW_HEIGHT_SHARE = 0.7f
        const val PREVIEW_STATUS_MS = 800L
        const val PREVIEW_PENDING_MS = 1000L
    }
}
