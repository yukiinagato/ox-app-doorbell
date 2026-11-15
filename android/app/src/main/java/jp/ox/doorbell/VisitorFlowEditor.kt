// The native editor of the door-station visitor flow (docs/en/visitor-flow-contract.md, section 8).
//
// Everything is written the way the contract asks: the scalar keys as leaves, every step as one
// whole value, and one batch per save so Core validates the graph on the configuration the batch
// would leave. Core's validation answers are shown inside the open dialog, next to what was
// edited; an unresolved configuration conflict is shown with a pointer instead of a retry.
package jp.ox.doorbell

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.text.InputFilter
import android.text.InputType
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
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

    private fun item(title: String, value: String = "", note: String = "", onClick: (() -> Unit)?): View =
        ShellUi.row(a, a.palette, title, value, note, enabled = !a.readOnly, onClick = onClick)

    // ---------- the settings group ----------

    fun section() {
        val state = FlowEdit.read(cfg)
        val card = a.section(L("flow_editor.title"))
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
                a.write("visitor_flow.start", JSONObject.quote(it)) { }
            }
        })
        val doorStarts = FlowEdit.doorStarts(cfg)
        for (door in a.doorIds()) {
            val own = doorStarts[door]
            add(card, item(L("flow_editor.door_start") + " · " + a.doorLabel(door),
                           if (own == null) L("flow_editor.door_start_inherit") else stepName(state, own)) {
                val options = listOf("" to L("flow_editor.door_start_inherit")) +
                    pages.map { it to stepName(state, it) }
                pickStep(L("flow_editor.door_start"), options) { picked ->
                    if (picked.isEmpty()) a.deleteKey(FlowEdit.doorStartKey(door))
                    else a.write(FlowEdit.doorStartKey(door), JSONObject.quote(picked)) { }
                }
            })
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
                            if (id == state.start) L("flow_editor.start") else "") { stepMenu(state, id) })
        }
        if (state.steps.size < FlowEdit.MAX_STEPS)
            add(steps, item(L("flow_editor.add_step")) { addStep(state) })
        templates(state)
        add(card, a.destructiveRow(L("flow_editor.reset_default"), L("flow_editor.reset_default_confirm")) {
            confirm(L("flow_editor.reset_default"), L("flow_editor.reset_default_confirm"),
                    L("flow_editor.reset_default")) {
                writeBatch(FlowEdit.resetOps(cfg))
            }
        })
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
        options.add("duplicate" to L("flow_editor.duplicate_step"))
        options.add("delete" to L("flow_editor.delete_step"))
        pickStep(stepName(state, id), options) { pick ->
            when (pick) {
                "edit" -> editStep(id, false, step)
                "start" -> a.write("visitor_flow.start", JSONObject.quote(id)) { }
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
            failure(L("visitor_flow.too_many_steps"))
            return
        }
        val copy = JSONObject(step.toString())
        val target = FlowEdit.newId(FlowEdit.prefixFor(step.optString("kind")), state.steps.keys, random.nextLong())
        writeBatch(FlowEdit.saveStepOps(mapOf(target to copy)))
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
        a.writeOpsReporting(ops) { result ->
            if (result != null && !result.ok) failure(errorText(result.error))
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
                val problem = FlowEdit.localProblem(session.draft)
                if (problem != null) {
                    fail(errorText(problem))
                } else {
                    val steps = LinkedHashMap<String, JSONObject>()
                    steps[session.id] = session.draft
                    steps.putAll(session.created)
                    a.writeOpsReporting(FlowEdit.saveStepOps(steps)) { result ->
                        when {
                            result == null -> fail(L("settings.offline"))
                            result.ok -> close()
                            else -> fail(errorText(result.error))
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
                                       FlowEdit.MAX_TITLE)
                val body = langFields(box, L("flow_editor.field_body"), draft.optJSONObject("body"),
                                      FlowEdit.MAX_BODY, multiline = true)
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
                                         FlowEdit.MAX_MESSAGE, multiline = true)
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
            box.addView(item(label, place, a.localizedLabel(image.optJSONObject("alt"), "")) {
                imageMenu(images, index, draft, change)
            }, ShellUi.matchWrap())
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
                "alt" -> altDialog(image) { change { } }
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

    private fun altDialog(image: JSONObject, done: () -> Unit) {
        formDialog(
            title = L("flow_editor.image_alt"),
            build = { box, _ ->
                val alt = langFields(box, L("flow_editor.image_alt"), image.optJSONObject("alt"), FlowEdit.MAX_ALT)
                val sync: () -> Unit = { putText(image, "alt", alt()) }
                sync
            },
            onSave = { sync, _, close -> sync(); close(); done() },
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
            val target = option.optString("to").takeIf { it.isNotEmpty() }?.let { stepName(shown, it) } ?: unset
            box.addView(item(label, target, flags) {
                optionMenu(session, known, options, index, change)
            }, ShellUi.matchWrap())
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
        val icon = option.optString("icon").ifEmpty { VisitPurposes.icon(cfg, purpose) }
        return if (icon.isEmpty()) base else "$icon  $base"
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
                           options: MutableList<JSONObject>, change: (() -> Unit) -> Unit) {
        val option = JSONObject(original.toString())
        formDialog(
            title = L("flow_editor.field_options"),
            build = { box, rebuild ->
                val label = langFields(box, L("flow_editor.option_label"), option.optJSONObject("label"),
                                       FlowEdit.MAX_LABEL)
                val icon = field(box, L("flow_editor.option_icon"), option.optString("icon"))
                val primary = checkbox(box, L("flow_editor.option_primary"), option.optString("style") == "primary")
                val shown = checkbox(box, L("flow_editor.option_enabled"), option.optBoolean("enabled", true))
                val sync: () -> Unit = {
                    putText(option, "label", label())
                    putOrRemove(option, "icon", icon.text.toString().trim())
                    if (primary.isChecked) option.put("style", "primary") else option.remove("style")
                    if (shown.isChecked) option.remove("enabled") else option.put("enabled", false)
                }
                box.addView(item(L("flow_editor.option_purpose"), purposeName(option.optString("purpose"))) {
                    sync()
                    pickPurpose { picked -> putOrRemove(option, "purpose", picked); rebuild() }
                }, ShellUi.matchWrap())
                val names = FlowEdit.State(true, true, "", 0, true, known)
                box.addView(item(L("flow_editor.option_target"),
                    option.optString("to").takeIf { it.isNotEmpty() }?.let { stepName(names, it) } ?: unset) {
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
                }, ShellUi.matchWrap())
                sync
            },
            onSave = { sync, fail, close ->
                sync()
                if (option.optJSONObject("label") == null && option.optString("purpose").isEmpty()) {
                    fail(errorText("visitor_flow.option_needs_label"))
                } else if (option.optString("to").isEmpty()) {
                    fail(errorText("visitor_flow.unknown_target"))
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

    // ---------- shared pieces ----------

    private fun putText(into: JSONObject, key: String, values: Map<String, String>) {
        val map = FlowEdit.textMap(values)
        if (map == null) into.remove(key) else into.put(key, map)
    }

    private fun putOrRemove(into: JSONObject, key: String, value: Any?) {
        if (value == null || (value is String && value.isEmpty())) into.remove(key) else into.put(key, value)
    }

    private fun errorText(error: String): String {
        if (FlowEdit.isConflict(error)) return L("flow_editor.conflict")
        val (key, detail) = FlowEdit.errorParts(error)
        val message = if (key.startsWith("visitor_flow.")) L(key) else key
        if (key.startsWith("visitor_flow.") && message != key)
            return if (detail.isEmpty()) message else "$message ($detail)"
        return L("visitor_flow.invalid", error)
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

    private fun caption(box: LinearLayout, text: String) {
        box.addView(ShellUi.label(a, text, TextRole.LABEL).apply {
            setPadding(0, ShellUi.dp(a, 14), 0, ShellUi.dp(a, 2))
        }, ShellUi.matchWrap())
    }

    private fun checkbox(box: LinearLayout, title: String, value: Boolean): android.widget.CompoundButton =
        PlatformUi.checkbox(a).apply {
            text = title
            isChecked = value
            minHeight = ShellUi.dp(a, ShellUi.TOUCH_FLOOR_DP)
            box.addView(this, ShellUi.matchWrap())
        }

    private fun field(box: LinearLayout, title: String, value: String,
                      kind: Int = InputType.TYPE_CLASS_TEXT, max: Int = 0, lines: Int = 1): EditText {
        val entry = PlatformUi.field(a, title, value, kind, lines)
        if (max > 0) entry.input.filters = arrayOf(InputFilter.LengthFilter(max))
        box.addView(entry.view, ShellUi.matchWrap().apply { topMargin = ShellUi.dp(a, 8) })
        return entry.input
    }

    /** One text field per configured language; the reader returns what is typed now. */
    private fun langFields(box: LinearLayout, title: String, current: JSONObject?, max: Int,
                           multiline: Boolean = false): () -> Map<String, String> {
        caption(box, title)
        val fields = languages.associateWith { lang ->
            field(box, Texts.langDisplayName(lang), current?.optString(lang).orEmpty(),
                  if (multiline) InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
                  else InputType.TYPE_CLASS_TEXT, max, if (multiline) 3 else 1)
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
        onSave: (sync: () -> Unit, fail: (String) -> Unit, close: () -> Unit) -> Unit,
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
        rebuild = {
            box.removeAllViews()
            box.addView(error, ShellUi.matchWrap())
            sync = build(box) { rebuild() }
        }
        rebuild()
        val dialog = ShellDialogBuilder(a).setTitle(title).setView(scroll)
            .setPositiveButton(L("admin.save"), null)
            .setNegativeButton(L("admin.cancel"), null).create()
        dialog.setOnShowListener {
            dialog.getButton(android.content.DialogInterface.BUTTON_POSITIVE).setOnClickListener {
                error.visibility = View.GONE
                onSave({ sync() }, { message ->
                    error.text = message
                    error.visibility = View.VISIBLE
                    scroll.post { scroll.fullScroll(View.FOCUS_UP) }
                }, { dialog.dismiss() })
            }
        }
        dialog.show()
    }

    private companion object {
        const val NEW_CALL = "\u0000new_call"
        const val NEW_END = "\u0000new_end"
        const val UPLOAD = "\u0000upload"
        const val MAX_EDGE = 1280
        const val TARGET_BYTES = 400 * 1024
    }
}
