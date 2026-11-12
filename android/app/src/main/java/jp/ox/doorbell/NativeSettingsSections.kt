// Native editors for everything the settings screen used to hand to the web admin
// (.worktrees/native-settings-spec.md): secrets in the Keystore-backed secure store with
// `secret:<name>` references, images and sounds through the asset ledger (file picker or the
// built-in recorder), the trigger-rule editor, quiet hours, households, Telegram, Web Push,
// MQTT/Home Assistant, SIP DTMF and WebRTC, doors/buildings, external cameras, notice presets,
// visit purposes, quick-reply order and audio, wording overrides, devices, Web panel identities
// and configuration export/import. Every write goes through the same Core validation as before.
package jp.ox.doorbell

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.View
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import java.io.ByteArrayOutputStream
import java.security.SecureRandom
import org.json.JSONArray
import org.json.JSONObject

internal class NativeSettingsSections(private val a: SettingsActivity) {

    private val random = SecureRandom()

    // ---------- small helpers ----------

    private fun L(key: String, vararg args: Any): String = a.label(key, *args)
    private val cfg: JSONObject? get() = a.config
    private fun dig(key: String): Any? = SettingsModel.dig(cfg, key)
    private fun str(key: String, fallback: String = ""): String =
        SettingsModel.currentString(cfg, key, fallback).let { if (it == "null") fallback else it }
    private fun obj(key: String): JSONObject? = dig(key) as? JSONObject
    private fun seed(): Long = random.nextLong()
    private fun add(card: LinearLayout, view: View) = with(a) { card.row(view) }
    private val unset: String get() = L("settings.value_unset")

    private fun item(title: String, value: String = "", note: String = "",
                     onClick: (() -> Unit)?): View =
        ShellUi.row(a, a.palette, title, value, note, enabled = !a.readOnly, onClick = onClick)

    private fun info(card: LinearLayout, text: String) =
        add(card, ShellUi.label(a, text, TextRole.SUPPORTING).apply {
            setPadding(ShellUi.dp(a, 16), ShellUi.dp(a, 8), ShellUi.dp(a, 16), ShellUi.dp(a, 8))
        })

    private fun hexToken(bytes: Int): String {
        val b = ByteArray(bytes)
        random.nextBytes(b)
        return PanelIdentityModel.hex(b)
    }

    /** A padded vertical form inside a ScrollView, so long editors stay usable on a phone. */
    private fun form(): Pair<ScrollView, LinearLayout> {
        val box = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            val pad = ShellUi.dp(a, 24)
            setPadding(pad, ShellUi.dp(a, 8), pad, ShellUi.dp(a, 8))
        }
        return ScrollView(a).apply { addView(box) } to box
    }

    private fun caption(box: LinearLayout, text: String) {
        box.addView(ShellUi.label(a, text, TextRole.LABEL).apply {
            setPadding(0, ShellUi.dp(a, 10), 0, ShellUi.dp(a, 2))
        }, ShellUi.matchWrap())
    }

    /** A labelled text field; the title floats as the field's own label. */
    private fun field(box: LinearLayout, title: String, value: String, kind: Int =
        InputType.TYPE_CLASS_TEXT, multiline: Boolean = false): EditText {
        val entry = PlatformUi.field(a, title, value, kind, if (multiline) 2 else 1)
        box.addView(entry.view, ShellUi.matchWrap().apply { topMargin = ShellUi.dp(a, 8) })
        return entry.input
    }

    private fun check(box: LinearLayout, title: String, value: Boolean): CompoundButton =
        PlatformUi.checkbox(a).apply {
            text = title
            isChecked = value
            minHeight = ShellUi.dp(a, ShellUi.TOUCH_FLOOR_DP)
            box.addView(this, ShellUi.matchWrap())
        }

    /** Radio choice; returns a reader for the selected value. */
    private fun radio(box: LinearLayout, title: String, options: List<Pair<String, String>>,
                      selected: String, onChange: ((String) -> Unit)? = null): () -> String {
        caption(box, title)
        val group = RadioGroup(a).apply { orientation = RadioGroup.VERTICAL }
        options.forEachIndexed { index, (value, text) ->
            group.addView(PlatformUi.radio(a).apply {
                id = 0x5100 + index
                this.text = text
                isChecked = value == selected
                minHeight = ShellUi.dp(a, ShellUi.TOUCH_FLOOR_DP)
            })
        }
        if (options.none { it.first == selected } && options.isNotEmpty())
            (group.getChildAt(0) as RadioButton).isChecked = true
        if (onChange != null) group.setOnCheckedChangeListener { _, id ->
            options.getOrNull(id - 0x5100)?.let { onChange(it.first) }
        }
        box.addView(group, ShellUi.matchWrap())
        return {
            val index = group.checkedRadioButtonId - 0x5100
            options.getOrNull(index)?.first ?: options.firstOrNull()?.first.orEmpty()
        }
    }

    /** A dialog whose positive button only closes when [onSave] returns true. */
    private fun dialog(title: String, view: View, neutral: String? = null,
                       onNeutral: (() -> Unit)? = null, onSave: () -> Boolean) {
        val builder = ShellDialogBuilder(a).setTitle(title).setView(view)
            .setPositiveButton(L("admin.save"), null)
            .setNegativeButton(L("admin.cancel"), null)
        if (neutral != null) builder.setNeutralButton(neutral) { _, _ -> onNeutral?.invoke() }
        val d = builder.create()
        d.setOnShowListener {
            d.getButton(android.content.DialogInterface.BUTTON_POSITIVE).setOnClickListener { if (onSave()) d.dismiss() }
        }
        d.show()
    }

    private fun choose(title: String, options: List<Pair<String, String>>, onPick: (String) -> Unit) {
        ShellDialogBuilder(a).setTitle(title)
            .setItems(options.map { it.second as CharSequence }.toTypedArray()) { _, which ->
                onPick(options[which].first)
            }
            .setNegativeButton(L("admin.cancel"), null).show()
    }

    private fun multi(title: String, options: List<Pair<String, String>>, selected: Collection<String>,
                      onDone: (List<String>) -> Unit) {
        val checked = BooleanArray(options.size) { options[it].first in selected }
        ShellDialogBuilder(a).setTitle(title)
            .setMultiChoiceItems(options.map { it.second as CharSequence }.toTypedArray(), checked) {
                _, which, on -> checked[which] = on
            }
            .setPositiveButton(L("admin.save")) { _, _ ->
                onDone(options.filterIndexed { i, _ -> checked[i] }.map { it.first })
            }
            .setNegativeButton(L("admin.cancel"), null).show()
    }

    private fun confirm(title: String, message: String, action: String, onYes: () -> Unit) {
        ShellDialogBuilder(a).setTitle(title).setMessage(message)
            .setPositiveButton(action) { _, _ -> onYes() }
            .setNegativeButton(L("admin.cancel"), null).show()
    }

    /** Free text for one key, validated; blank deletes the key so it inherits. */
    private fun textRow(title: String, key: String, note: String = "", secretLooking: Boolean = false,
                        valid: (String) -> Boolean): View {
        val current = str(key)
        return item(title, current.ifEmpty { unset }, note) {
            val (scroll, box) = form()
            val input = field(box, title, current,
                InputType.TYPE_CLASS_TEXT or (if (secretLooking) 0 else InputType.TYPE_TEXT_VARIATION_URI))
            dialog(title, scroll) {
                val raw = input.text.toString().trim()
                when {
                    raw.isEmpty() -> { a.deleteKey(key); true }
                    !valid(raw) -> { a.toast(L("settings.invalid_value")); false }
                    else -> { a.write(key, JSONObject.quote(raw)) { }; true }
                }
            }
        }
    }

    private fun labelsOf(value: JSONObject?): Map<String, String> =
        SettingsModel.LANGUAGES.associateWith { value?.optString(it).orEmpty() }

    private fun langFields(box: LinearLayout, current: JSONObject?): Map<String, EditText> =
        SettingsModel.LANGUAGES.associateWith { lang ->
            field(box, L("admin.label_$lang"), current?.optString(lang).orEmpty())
        }

    private fun local(value: JSONObject?, fallback: String) = a.localizedLabel(value, fallback)

    // ---------- secrets ----------

    /**
     * A password/token row. The value goes into this device's secure store under [name]; the
     * configuration key [refKey] then carries `secret:<name>`. Secrets do not replicate, so the
     * note says which device holds it.
     */
    fun secretRow(card: LinearLayout, title: String, refKey: String, name: String,
                  note: String = L("nset.secret_local_note")) {
        val configured = str(refKey).isNotEmpty()
        val stored = a.app.core.hasPlatformSecret(name)
        val value = when {
            configured && stored -> L("admin.secret_configured")
            configured -> L("nset.secret_missing_here")
            else -> unset
        }
        add(card, item(title, value, note) { editSecret(title, refKey, name, configured) })
    }

    private fun editSecret(title: String, refKey: String, name: String, configured: Boolean) {
        val (scroll, box) = form()
        val input = field(box, title, "",
                          InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        caption(box, L("nset.secret_hint"))
        dialog(title, scroll, if (configured) L("admin.delete") else null, {
            Thread({
                a.app.core.deletePlatformSecret(name)
                a.ui.post { a.writeOps(listOf(ConfigOp.Delete(refKey))) }
            }, "doorbell-secret-delete").apply { isDaemon = true }.start()
        }) {
            val secret = input.text.toString()
            if (secret.isEmpty() || secret.length > 4096) {
                a.toast(L("settings.invalid_value")); return@dialog false
            }
            storeSecret(name, secret) { ok ->
                if (ok) a.writeOps(SecretRefs.assignOps(refKey, name))
                else a.toast(L("nset.secret_store_failed"))
            }
            true
        }
    }

    /** Write first, reference second, so a reference never points at a missing value. */
    private fun storeSecret(name: String, value: String, done: (Boolean) -> Unit) {
        Thread({
            val ok = a.app.core.putPlatformSecret(name, value)
            a.ui.post { done(ok) }
        }, "doorbell-secret-put").apply { isDaemon = true }.start()
    }

    // ---------- files, images and sounds ----------

    private fun readUri(uri: Uri, limit: Int): ByteArray? = try {
        a.contentResolver.openInputStream(uri)?.use { input ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
                if (out.size() > limit) return null
            }
            out.toByteArray()
        }
    } catch (e: Exception) {
        ShellLog.ignored("NativeSettings", e)
        null
    }

    private fun displayName(uri: Uri): String = try {
        a.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
                                null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0).orEmpty() else ""
        }.orEmpty()
    } catch (_: Exception) {
        ""
    }.ifEmpty { uri.lastPathSegment.orEmpty() }.take(64)

    private fun pick(mime: String, extra: Array<String>, onBytes: (ByteArray, String) -> Unit) {
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_MIME_TYPES, extra)
        }
        a.launchForResult(Intent.createChooser(intent, L("admin.asset_choose_file"))) { data ->
            val uri = data?.data ?: return@launchForResult
            Thread({
                val bytes = readUri(uri, MAX_PICK)
                val name = displayName(uri)
                a.ui.post {
                    if (bytes == null) a.toast(L("admin.asset_too_large")) else onBytes(bytes, name)
                }
            }, "doorbell-pick").apply { isDaemon = true }.start()
        }
    }

    /** JPEG/PNG under 3 MiB as-is; anything decodable otherwise becomes a 1920 px JPEG. */
    private fun prepareImage(bytes: ByteArray): Pair<ByteArray, String>? {
        val sniffed = AssetTypes.sniff(bytes)
        if (sniffed in AssetTypes.IMAGES && bytes.size <= AssetTypes.MAX_BYTES) return bytes to sniffed!!
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 1920 * 2) sample *= 2
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
            BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        val scale = minOf(1f, 1920f / maxOf(bitmap.width, bitmap.height))
        val scaled = if (scale < 1f) Bitmap.createScaledBitmap(bitmap,
            (bitmap.width * scale).toInt().coerceAtLeast(1),
            (bitmap.height * scale).toInt().coerceAtLeast(1), true) else bitmap
        for (quality in intArrayOf(85, 70, 55)) {
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, quality, out)
            if (out.size() <= AssetTypes.MAX_BYTES) return out.toByteArray() to "image/jpeg"
        }
        return null
    }

    /** Add bytes to the ledger; [done] gets the sha256 or null (already toasted). */
    private fun addAsset(bytes: ByteArray, type: String, label: String, done: (String) -> Unit) {
        if (bytes.size > AssetTypes.MAX_BYTES) { a.toast(L("admin.asset_too_large")); return }
        a.coreCall({ a.app.core.assetAdd(bytes, type, label) }) { result ->
            val hash = result?.optString("hash").orEmpty()
            if (result?.optBoolean("ok") == true && hash.isNotEmpty()) {
                a.toast(L("admin.asset_registered"))
                done(hash)
            } else {
                a.toast(when (result?.optString("err")) {
                    "too_large" -> L("admin.asset_too_large")
                    "bad_type" -> L("admin.asset_format_unsupported")
                    else -> L("admin.asset_failed")
                })
            }
        }
    }

    private fun pickImage(done: (String) -> Unit) =
        pick("image/*", arrayOf("image/jpeg", "image/png", "image/*")) { bytes, name ->
            Thread({
                val prepared = try { prepareImage(bytes) } catch (_: OutOfMemoryError) { null }
                a.ui.post {
                    if (prepared == null) a.toast(L("admin.asset_format_unsupported"))
                    else addAsset(prepared.first, prepared.second, name.ifEmpty { "image" }, done)
                }
            }, "doorbell-image").apply { isDaemon = true }.start()
        }

    private fun pickSound(done: (String) -> Unit) =
        pick("audio/*", arrayOf("audio/mpeg", "audio/wav", "audio/x-wav", "audio/*")) { bytes, name ->
            val type = AssetTypes.sniff(bytes)
            if (type !in AssetTypes.SOUNDS) a.toast(L("admin.asset_format_unsupported"))
            else addAsset(bytes, type!!, name.ifEmpty { "sound" }, done)
        }

    /** Record from the microphone into a WAV and add it to the ledger. */
    private fun recordSound(done: (String) -> Unit) {
        if (!WavRecorder.permitted(a)) {
            WavRecorder.requestPermission(a)
            a.toast(L("nset.record_permission"))
            return
        }
        val recorder = WavRecorder()
        val (scroll, box) = form()
        val state = TextView(a).apply { text = L("nset.record_ready"); textSize = 15f }
        box.addView(state, ShellUi.matchWrap())
        val name = field(box, L("admin.asset_label"), L("nset.record_default_name"))
        val toggle = ShellUi.button(a, L("nset.record_start"), a.palette) { }
        box.addView(toggle, ShellUi.matchWrap())
        toggle.setOnClickListener {
            if (recorder.recording) {
                recorder.stop()
                state.text = L("nset.record_done", recorder.seconds().toString())
                toggle.text = L("nset.record_again")
            } else if (recorder.start { secs -> a.ui.post { state.text = L("nset.record_running", secs.toString()) } }) {
                toggle.text = L("nset.record_stop")
            } else state.text = L("nset.record_failed")
        }
        dialog(L("nset.record_title"), scroll) {
            if (recorder.recording) recorder.stop()
            val wav = recorder.wav() ?: run { a.toast(L("nset.record_empty")); return@dialog false }
            addAsset(wav, "audio/wav", name.text.toString().trim().ifEmpty { "recording" }.take(64), done)
            true
        }
    }

    /** Sound picker: none, bundled names, the ledger, or add one now. */
    private fun chooseSound(title: String, bundled: List<String>, allowNone: Boolean,
                            onPick: (String) -> Unit) {
        val options = ArrayList<Pair<String, String>>()
        if (allowNone) options.add("" to L("settings.sound_none"))
        for (name in bundled) options.add(name to L("settings.sound_$name").let {
            if (it == "settings.sound_$name") name else it })
        for ((hash, entry) in AssetTypes.list(cfg, AssetTypes.SOUNDS))
            options.add("asset:$hash" to entry.optString("label").ifEmpty { hash.take(8) })
        options.add(ADD_FILE to L("nset.sound_add_file"))
        options.add(ADD_RECORD to L("nset.sound_record"))
        choose(title, options) { value ->
            when (value) {
                ADD_FILE -> pickSound { onPick("asset:$it") }
                ADD_RECORD -> recordSound { onPick("asset:$it") }
                else -> onPick(value)
            }
        }
    }

    private fun assetLabel(reference: String): String {
        val hash = reference.removePrefix("asset:")
        val entry = obj("assets")?.optJSONObject(hash) ?: return reference.ifEmpty { unset }
        return entry.optString("label").ifEmpty { hash.take(8) }
    }

    private companion object {
        const val MAX_PICK = 24 * 1024 * 1024
        const val ADD_FILE = "\u0000file"
        const val ADD_RECORD = "\u0000record"
        val TOPIC = Regex("^[A-Za-z0-9_/-]{1,64}$")
    }

    // ---------- Display: background image ----------

    fun backgroundImageRow(card: LinearLayout) {
        val key = "display.theme.bg_image"
        val current = str(key)
        add(card, item(L("settings.background_image"),
                       if (current.isEmpty()) L("nset.none") else assetLabel(current)) {
            val options = ArrayList<Pair<String, String>>()
            options.add(ADD_FILE to L("nset.image_choose"))
            for ((hash, entry) in AssetTypes.list(cfg, AssetTypes.IMAGES))
                options.add(hash to entry.optString("label").ifEmpty { hash.take(8) })
            if (current.isNotEmpty()) options.add("" to L("nset.image_remove"))
            choose(L("settings.background_image"), options) { value ->
                when (value) {
                    ADD_FILE -> pickImage { hash -> a.write(key, JSONObject.quote(hash)) { } }
                    "" -> a.write(key, "null") { }
                    else -> a.write(key, JSONObject.quote(value)) { }
                }
            }
        })
    }

    // ---------- Sound: the asset ledger ----------

    fun soundLibrary() {
        val card = a.section(L("admin.sound_manager"))
        val sounds = AssetTypes.list(cfg, AssetTypes.SOUNDS)
        if (sounds.isEmpty()) info(card, L("admin.assets_empty"))
        for ((hash, entry) in sounds) {
            val size = entry.optLong("size", 0L)
            add(card, item(entry.optString("label").ifEmpty { hash.take(8) },
                           "${entry.optString("type")} · ${size / 1024} KB") { soundMenu(hash) })
        }
        add(card, item(L("nset.sound_add_file"), "", L("nset.sound_formats")) { pickSound { } })
        add(card, item(L("nset.sound_record"), "", L("nset.record_note",
            minOf(60, WavFormat.maxSeconds(WavRecorder.RATE)).toString())) { recordSound { } })
        // Which sound each slot plays; asset choices come from the ledger above.
        add(card, item(L("admin.indoor_ringtone"), soundName(str("ui.ringtone", "school_chime"))) {
            chooseSound(L("admin.indoor_ringtone"), SettingsModel.RINGTONES, false) {
                a.write("ui.ringtone", JSONObject.quote(it)) { }
            }
        })
        add(card, item(L("nset.sos_alarm_sound"), soundName(str("emergency.alarm_sound", "siren1"))) {
            chooseSound(L("nset.sos_alarm_sound"), listOf("siren1"), false) {
                a.write("emergency.alarm_sound", JSONObject.quote(it)) { }
            }
        })
    }

    private fun soundName(value: String): String = when {
        value.isEmpty() -> L("settings.sound_none")
        value.startsWith("asset:") -> assetLabel(value)
        else -> L("settings.sound_$value").let { if (it == "settings.sound_$value") value else it }
    }

    /** Anything outside the ledger itself that still names this hash. */
    private fun referencesTo(hash: String): Boolean {
        val copy = JSONObject(cfg?.toString() ?: return false)
        copy.remove("assets")
        return copy.toString().contains(hash)
    }

    private fun soundMenu(hash: String) {
        val options = listOf(
            "ringtone" to L("nset.use_as_ringtone"),
            "alarm" to L("nset.use_as_sos_alarm"),
            "delete" to L("admin.delete"),
        )
        choose(assetLabel(hash), options) { pick ->
            when (pick) {
                "ringtone" -> a.write("ui.ringtone", JSONObject.quote("asset:$hash")) { }
                "alarm" -> a.write("emergency.alarm_sound", JSONObject.quote("asset:$hash")) { }
                "delete" -> deleteAsset(hash)
            }
        }
    }

    private fun deleteAsset(hash: String) {
        val inUse = referencesTo(hash)
        confirm(L("admin.delete"), if (inUse) L("admin.asset_delete_in_use") else assetLabel(hash),
                L("admin.delete")) {
            a.coreCall({ a.app.core.assetRemove(hash) }) { result ->
                a.toast(if (result?.optBoolean("ok") == true) L("admin.removed") else L("admin.save_failed"))
                a.refreshSnapshots(); a.render()
            }
        }
    }

    // ---------- Display: wording overrides (i18n_overrides.<lang>.<key>) ----------

    fun wording() {
        val card = a.section(L("nset.wording"))
        val overrides = obj("i18n_overrides")
        var count = 0
        for (lang in ConfigIds.keysOf(overrides)) {
            val map = overrides?.optJSONObject(lang) ?: continue
            for (key in ConfigIds.keysOf(map).sorted()) {
                count++
                add(card, item("$key · ${Texts.langDisplayName(lang)}", map.optString(key)) {
                    editOverride(key)
                })
            }
        }
        if (count == 0) info(card, L("nset.wording_none"))
        add(card, item(L("nset.wording_add"), "", L("nset.wording_note")) { searchWording() })
    }

    private fun catalogue(): List<Pair<String, Int>> = R.string::class.java.fields.mapNotNull { f ->
        val key = I18nKeys.fromResourceName(f.name) ?: return@mapNotNull null
        try { key to f.getInt(null) } catch (_: Exception) { null }
    }.sortedBy { it.first }

    private fun searchWording() {
        val all = catalogue()
        val (scroll, box) = form()
        val query = field(box, L("settings.search"), "")
        val results = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
        box.addView(results, ShellUi.matchWrap())
        val d = ShellDialogBuilder(a).setTitle(L("nset.wording_add")).setView(scroll)
            .setNegativeButton(L("admin.cancel"), null).create()
        fun fill(q: String) {
            results.removeAllViews()
            val needle = q.trim().lowercase()
            if (needle.length < 2) return
            all.asSequence().filter { (key, id) ->
                key.contains(needle) || a.getString(id).lowercase().contains(needle)
            }.take(40).forEach { (key, id) ->
                results.addView(ShellUi.row(a, a.palette, a.getString(id), key) {
                    d.dismiss(); editOverride(key)
                }, ShellUi.matchWrap())
            }
        }
        query.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, x: Int, y: Int, z: Int) {}
            override fun onTextChanged(s: CharSequence?, x: Int, y: Int, z: Int) {}
            override fun afterTextChanged(s: Editable?) = fill(s?.toString().orEmpty())
        })
        d.show()
    }

    private fun builtIn(key: String, lang: String): String {
        val id = a.resources.getIdentifier(key.replace('.', '_'), "string", a.packageName)
        if (id == 0) return ""
        return try {
            val conf = android.content.res.Configuration(a.resources.configuration)
            conf.setLocale(java.util.Locale(lang))
            a.createConfigurationContext(conf).resources.getString(id)
        } catch (_: Exception) {
            a.getString(id)
        }
    }

    private fun editOverride(key: String) {
        val overrides = obj("i18n_overrides")
        val (scroll, box) = form()
        caption(box, key)
        val fields = SettingsModel.LANGUAGES.associateWith { lang ->
            val original = builtIn(key, lang)
            caption(box, "${Texts.langDisplayName(lang)} — ${L("nset.wording_builtin")}: $original")
            PlatformUi.field(a, value = I18nKeys.current(overrides, lang, key)).also {
                it.input.hint = original
                box.addView(it.view, ShellUi.matchWrap())
            }.input
        }
        caption(box, L("nset.wording_blank_resets"))
        dialog(L("nset.wording"), scroll) {
            val values = fields.mapValues { it.value.text.toString() }
            for ((lang, text) in values) {
                val clean = text.trim()
                if (clean.isNotEmpty() &&
                    (!I18nKeys.placeholdersMatch(builtIn(key, lang), clean) || clean.length > 500)) {
                    a.toast(L("nset.wording_placeholders")); return@dialog false
                }
            }
            val ops = I18nKeys.overrideOps(overrides, key, values)
            if (ops.isNotEmpty()) a.writeOps(ops)
            true
        }
    }

    // ---------- Calls: quick replies (order, audio) ----------

    /** Tapping a reply: edit, move, per-language audio, delete. */
    fun quickReplyMenu(id: String, reply: JSONObject, edit: () -> Unit) {
        val replies = obj("quick_replies")
        val options = listOf("edit" to L("admin.edit"), "up" to L("nset.move_up"),
                             "down" to L("nset.move_down"), "audio" to L("settings.item_reply_audio"),
                             "delete" to L("admin.delete"))
        choose(local(reply.optJSONObject("label"), id), options) { pick ->
            when (pick) {
                "edit" -> edit()
                "up", "down" -> OrderedEntries.moveOps("quick_replies", replies, id,
                    if (pick == "up") -1 else 1).takeIf { it.isNotEmpty() }?.let { a.writeOps(it) }
                "audio" -> replyAudio(id, reply)
                "delete" -> confirm(L("admin.delete"), local(reply.optJSONObject("label"), id),
                                    L("admin.delete")) {
                    a.writeOps(dtmfCleanup(id) + ConfigOp.Delete("quick_replies.$id"))
                }
            }
        }
    }

    /** DTMF codes that point at a deleted reply would make every later write fail validation. */
    private fun dtmfCleanup(replyId: String): List<ConfigOp> {
        val map = obj("sip.dtmf_actions") ?: return emptyList()
        return ConfigIds.keysOf(map).filter {
            map.optJSONObject(it)?.optString("reply_id") == replyId
        }.map { ConfigOp.Delete(DtmfModel.key(it)) }
    }

    private fun replyAudio(id: String, reply: JSONObject) {
        val audio = reply.optJSONObject("audio")
        val options = SettingsModel.LANGUAGES.map { lang ->
            lang to "${Texts.langDisplayName(lang)}: " +
                (audio?.optString(lang).orEmpty().let { if (it.isEmpty()) L("nset.audio_tts") else assetLabel(it) })
        }
        choose(L("settings.item_reply_audio"), options) { lang ->
            val key = "quick_replies.$id.audio.$lang"
            val choices = ArrayList<Pair<String, String>>()
            choices.add("" to L("nset.audio_tts"))
            for ((hash, entry) in AssetTypes.list(cfg, AssetTypes.SOUNDS))
                choices.add(hash to entry.optString("label").ifEmpty { hash.take(8) })
            choices.add(ADD_FILE to L("nset.sound_add_file"))
            choices.add(ADD_RECORD to L("nset.sound_record"))
            choose(Texts.langDisplayName(lang), choices) { value ->
                when (value) {
                    "" -> a.deleteKey(key)
                    ADD_FILE -> pickSound { a.write(key, JSONObject.quote(it)) { } }
                    ADD_RECORD -> recordSound { a.write(key, JSONObject.quote(it)) { } }
                    else -> a.write(key, JSONObject.quote(value)) { }
                }
            }
        }
    }

    // ---------- Calls: visit purposes ----------

    fun purposes() {
        val card = a.section(L("settings.purposes"))
        val map = obj("visit_purposes")
        val ids = OrderedEntries.sorted(map)
        if (ids.isEmpty()) info(card, L("info.no_data"))
        for (id in ids) {
            val p = map?.optJSONObject(id) ?: continue
            val enabled = p.optBoolean("enabled", true)
            add(card, item("${p.optString("icon")} ${local(p.optJSONObject("label"), id)}".trim(),
                           L(if (enabled) "purpose.enabled" else "purpose.disabled")) {
                purposeMenu(id, p, map)
            })
        }
        add(card, item(L("prefs.add_purpose"), "", L("admin.purpose_hint")) { editPurpose(null, null, map) })
    }

    private fun purposeMenu(id: String, p: JSONObject, map: JSONObject?) {
        val enabled = p.optBoolean("enabled", true)
        val options = listOf("edit" to L("admin.edit"),
                             "toggle" to L(if (enabled) "nset.purpose_hide" else "nset.purpose_show"),
                             "up" to L("nset.move_up"), "down" to L("nset.move_down"),
                             "delete" to L("admin.delete"))
        choose(local(p.optJSONObject("label"), id), options) { pick ->
            when (pick) {
                "edit" -> editPurpose(id, p, map)
                "toggle" -> a.write(VisitPurposes.enabledKey(id), if (enabled) "false" else "true") { }
                "up", "down" -> OrderedEntries.moveOps("visit_purposes", map, id,
                    if (pick == "up") -1 else 1).takeIf { it.isNotEmpty() }?.let { a.writeOps(it) }
                "delete" -> confirm(L("admin.delete"), local(p.optJSONObject("label"), id), L("admin.delete")) {
                    a.writeOps(listOf(ConfigOp.Delete("visit_purposes.$id")))
                }
            }
        }
    }

    private fun editPurpose(id: String?, p: JSONObject?, map: JSONObject?) {
        val (scroll, box) = form()
        val labels = langFields(box, p?.optJSONObject("label"))
        val icon = field(box, L("admin.purpose_icon"), p?.optString("icon").orEmpty())
        dialog(L(if (id == null) "prefs.add_purpose" else "admin.edit"), scroll) {
            val json = PurposeModel.json(labels.mapValues { it.value.text.toString() },
                icon.text.toString(), p?.optInt("order") ?: PurposeModel.nextOrder(map),
                p?.optBoolean("enabled", true) ?: true)
            if (json == null) { a.toast(L("settings.invalid_value")); return@dialog false }
            val target = id ?: ConfigIds.next("p", ConfigIds.keysOf(map), seed())
            a.writeOps(listOf(ConfigOp.Set("visit_purposes.$target", json)))
            true
        }
    }

    // ---------- Doors: presets, doors, buildings ----------

    fun noticePresets() {
        val card = a.section(L("settings.notice_presets"))
        val presets = NoticePresetsModel.read(cfg)
        presets.forEachIndexed { index, (id, text) ->
            add(card, item(text, "") {
                choose(text, listOf("edit" to L("admin.edit"), "up" to L("nset.move_up"),
                                    "down" to L("nset.move_down"), "delete" to L("admin.delete"))) { pick ->
                    val list = presets.toMutableList()
                    when (pick) {
                        "edit" -> editPreset(list, index)
                        "up" -> if (index > 0) { list.add(index - 1, list.removeAt(index)); savePresets(list) }
                        "down" -> if (index < list.size - 1) { list.add(index + 1, list.removeAt(index)); savePresets(list) }
                        "delete" -> { list.removeAt(index); savePresets(list) }
                    }
                }
            })
        }
        if (presets.size < NoticePresetsModel.MAX)
            add(card, item(L("notice.preset_add"), "", L("settings.notice_presets_desc")) {
                editPreset(presets.toMutableList(), -1)
            })
        else info(card, L("notice.presets_full"))
    }

    private fun editPreset(list: MutableList<Pair<String, String>>, index: Int) {
        val (scroll, box) = form()
        val input = field(box, L("settings.preset_text"), list.getOrNull(index)?.second.orEmpty(),
                          multiline = true)
        dialog(L("settings.notice_presets"), scroll) {
            val text = input.text.toString().trim()
            if (text.isEmpty() || text.length > NoticePresetsModel.MAX_TEXT) {
                a.toast(L("notice.preset_invalid")); return@dialog false
            }
            if (index < 0) list.add(NoticePresetsModel.nextId(list, seed()) to text)
            else list[index] = list[index].first to text
            savePresets(list)
            true
        }
    }

    private fun savePresets(list: List<Pair<String, String>>) {
        val json = NoticePresetsModel.json(list) ?: run { a.toast(L("notice.preset_invalid")); return }
        a.writeOps(listOf(ConfigOp.Set("notice.presets", json)))
    }

    /** Per-door building assignment and removal, appended under each door's rows. */
    fun doorExtras(card: LinearLayout, door: String) {
        val buildings = obj("buildings")
        val current = str("doors.$door.building")
        add(card, item(L("admin.building_assign"),
                       if (current.isEmpty()) L("nset.none") else local(buildings?.optJSONObject(current)?.optJSONObject("label"), current)) {
            val options = listOf("" to L("nset.none")) + ConfigIds.keysOf(buildings).sorted().map {
                it to local(buildings?.optJSONObject(it)?.optJSONObject("label"), it)
            }
            choose(L("admin.building_assign"), options) { value ->
                if (value.isEmpty()) a.deleteKey("doors.$door.building")
                else a.write("doors.$door.building", JSONObject.quote(value)) { }
            }
        })
        add(card, a.destructiveRow(L("nset.door_delete"), "") {
            val stations = ConfigIds.keysOf(obj("devices")).filter { str("devices.$it.door") == door }
            confirm(L("nset.door_delete"),
                    if (stations.isEmpty()) a.doorLabel(door) else L("nset.door_delete_in_use", stations.size.toString()),
                    L("admin.delete")) {
                a.writeOps(listOf(ConfigOp.Delete("doors.$door")))
            }
        })
    }

    fun addDoorRow(card: LinearLayout) {
        add(card, item(L("admin.add_door"), "", "") {
            a.labelDialog(L("admin.add_door"), null) { labels ->
                val label = PurposeModel.labelObject(labels) ?: run {
                    a.toast(L("settings.invalid_value")); return@labelDialog
                }
                val id = ConfigIds.next("d", a.doorIds(), seed())
                val value = JSONObject().put("label", label)
                ConfigIds.keysOf(obj("buildings")).singleOrNull()?.let { value.put("building", it) }
                a.writeOps(listOf(ConfigOp.Set("doors.$id", value.toString())))
            }
        })
    }

    fun buildings() {
        val card = a.section(L("admin.buildings"))
        val map = obj("buildings")
        for (id in ConfigIds.keysOf(map).sorted()) {
            val label = map?.optJSONObject(id)?.optJSONObject("label")
            val doors = a.doorIds().count { str("doors.$it.building") == id }
            add(card, item(local(label, id), L("nset.doors_count", doors.toString())) {
                a.labelDialog(L("admin.edit"), label, onDelete = {
                    val ops = ArrayList<ConfigOp>()
                    for (door in a.doorIds()) if (str("doors.$door.building") == id)
                        ops.add(ConfigOp.Delete("doors.$door.building"))
                    ops.add(ConfigOp.Delete("buildings.$id"))
                    a.writeOps(ops)
                }) { labels ->
                    val obj = PurposeModel.labelObject(labels) ?: run {
                        a.toast(L("settings.invalid_value")); return@labelDialog
                    }
                    a.writeOps(listOf(ConfigOp.Set("buildings.$id.label", obj.toString())))
                }
            })
        }
        add(card, item(L("admin.add_building"), "", "") {
            a.labelDialog(L("admin.add_building"), null) { labels ->
                val obj = PurposeModel.labelObject(labels) ?: run {
                    a.toast(L("settings.invalid_value")); return@labelDialog
                }
                val id = ConfigIds.next("b", ConfigIds.keysOf(map), seed())
                a.writeOps(listOf(ConfigOp.Set("buildings.$id", JSONObject().put("label", obj).toString())))
            }
        })
    }

    // ---------- Doors: external cameras (media_sources) ----------

    fun mediaSources() {
        val card = a.section(L("settings.media_sources"))
        val map = obj("media_sources")
        for (id in ConfigIds.keysOf(map).sorted()) {
            val d = MediaSourceModel.read(map?.optJSONObject(id))
            add(card, item(id, listOf(d.mjpeg, d.snapshot, d.h264).filter { it.isNotEmpty() }
                .joinToString("\n")) { editMediaSource(id, map?.optJSONObject(id)) })
        }
        add(card, item(L("nset.camera_add"), "", L("nset.camera_note")) { editMediaSource(null, null) })
    }

    private fun editMediaSource(id: String?, source: JSONObject?) {
        val d = MediaSourceModel.read(source)
        val (scroll, box) = form()
        val idField = if (id == null) field(box, L("nset.camera_id"),
            ConfigIds.next("cam", ConfigIds.keysOf(obj("media_sources")), seed())) else null
        val uri = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
        val mjpeg = field(box, L("nset.camera_mjpeg"), d.mjpeg, uri)
        val snapshot = field(box, L("nset.camera_snapshot"), d.snapshot, uri)
        val h264 = field(box, L("nset.camera_rtsp"), d.h264, uri)
        val transport = radio(box, L("nset.camera_transport"),
                              listOf("tcp" to "TCP", "udp" to "UDP"), d.transport)
        caption(box, L("nset.camera_credentials"))
        val user = field(box, L("admin.user"), "")
        val pass = field(box, L("nset.password"), "",
                         InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        val clearCreds = if (d.hasSecret) check(box, L("nset.camera_clear_credentials"), false) else null
        dialog(if (id == null) L("nset.camera_add") else id, scroll,
               if (id != null) L("admin.delete") else null, {
            id?.let { existing ->
                Thread({ a.app.core.deletePlatformSecret(SecretRefs.mediaName(existing)) },
                       "doorbell-secret-delete").apply { isDaemon = true }.start()
                a.writeOps(listOf(ConfigOp.Delete("media_sources.$existing")))
            }
        }) {
            val target = id ?: idField?.text.toString().trim()
            if (!ConfigIds.valid(target)) { a.toast(L("settings.invalid_value")); return@dialog false }
            val newCreds = user.text.isNotEmpty() || pass.text.isNotEmpty()
            val hasSecret = newCreds || (d.hasSecret && clearCreds?.isChecked != true)
            val json = MediaSourceModel.json(target, source, MediaSourceModel.Draft(
                mjpeg.text.toString().trim(), snapshot.text.toString().trim(),
                h264.text.toString().trim(), transport(), hasSecret))
            if (json == null) { a.toast(L("nset.camera_invalid")); return@dialog false }
            val ops = listOf(ConfigOp.Set("media_sources.$target", json))
            if (newCreds) {
                val secret = JSONObject().put("username", user.text.toString())
                    .put("password", pass.text.toString()).toString()
                storeSecret(SecretRefs.mediaName(target), secret) { ok ->
                    if (ok) a.writeOps(ops) else a.toast(L("nset.secret_store_failed"))
                }
            } else {
                if (clearCreds?.isChecked == true) Thread({
                    a.app.core.deletePlatformSecret(SecretRefs.mediaName(target))
                }, "doorbell-secret-delete").apply { isDaemon = true }.start()
                a.writeOps(ops)
            }
            true
        }
    }

    // ---------- Notifications: households ----------

    fun households() {
        val card = a.section(L("settings.households"))
        val map = obj("households")
        for (id in ConfigIds.keysOf(map).sorted()) {
            val h = map?.optJSONObject(id) ?: continue
            val chats = h.optJSONArray("telegram_chat_ids")?.length() ?: 0
            val exts = (0 until (h.optJSONArray("sip_extensions")?.length() ?: 0))
                .joinToString(", ") { h.optJSONArray("sip_extensions").optString(it) }
            add(card, item(local(h.optJSONObject("label"), id),
                           L("nset.household_summary", chats.toString(), exts.ifEmpty { "-" })) {
                editHousehold(id, h)
            })
        }
        add(card, item(L("admin.add_household"), "", L("settings.households_desc")) { editHousehold(null, null) })
    }

    private fun editHousehold(id: String?, h: JSONObject?) {
        val (scroll, box) = form()
        val labels = langFields(box, h?.optJSONObject("label"))
        fun joined(key: String) = h?.optJSONArray(key)?.let { arr ->
            (0 until arr.length()).joinToString("\n") { arr.opt(it).toString() } }.orEmpty()
        val chats = field(box, L("admin.tg_chat_ids"), joined("telegram_chat_ids"),
                          InputType.TYPE_CLASS_TEXT, multiline = true)
        val exts = field(box, L("nset.sip_extensions"), joined("sip_extensions"),
                         InputType.TYPE_CLASS_TEXT, multiline = true)
        dialog(L(if (id == null) "admin.add_household" else "admin.edit"), scroll,
               if (id != null) L("admin.delete") else null, {
            id?.let { a.writeOps(listOf(ConfigOp.Delete("households.$it"))) }
        }) {
            val chatIds = HouseholdModel.parseChatIds(chats.text.toString())
            val extensions = HouseholdModel.parseExtensions(exts.text.toString())
            val json = if (chatIds == null || extensions == null) null
                else HouseholdModel.json(h, labels.mapValues { it.value.text.toString() }, chatIds, extensions)
            if (json == null) { a.toast(L("settings.invalid_value")); return@dialog false }
            val target = id ?: ConfigIds.next("h", ConfigIds.keysOf(obj("households")), seed())
            a.writeOps(listOf(ConfigOp.Set("households.$target", json)))
            true
        }
    }

    // ---------- Notifications: trigger rules ----------

    fun rules() {
        val card = a.section(L("settings.rules"))
        val map = obj(RuleEditorModel.ROOT)
        for (id in ConfigIds.keysOf(map).sorted()) {
            val rule = map?.optJSONObject(id) ?: continue
            val draft = RuleEditorModel.normalize(rule)
            val title = rule.optString("name").ifEmpty { "${whenLabel(draft.whenType)} · $id" }
            add(card, item(title, ruleSummary(draft),
                           if (draft.enabled) "" else L("nset.rule_disabled")) { editRule(id, rule) })
        }
        add(card, item(L("admin.add_rule"), "", "") { editRule(null, null) })
    }

    private fun whenLabel(type: String): String = when (type) {
        "button" -> L("admin.when_button")
        "motion" -> L("admin.when_motion")
        "device_offline" -> L("admin.when_offline")
        "emergency_on" -> L("admin.when_emergency_on")
        "emergency_off" -> L("admin.when_emergency_off")
        "call_missed" -> L("nset.when_call_missed")
        else -> type
    }

    private fun actionLabel(type: String): String = when (type) {
        "sip_call" -> L("admin.act_sip")
        "telegram" -> L("admin.act_telegram")
        "ha_event" -> L("admin.act_ha")
        "chime" -> L("admin.act_chime")
        "device_alert" -> L("admin.act_device_alert")
        "auto_reply" -> L("nset.act_auto_reply")
        else -> type
    }

    private fun ruleSummary(d: RuleDraft): String {
        val parts = ArrayList<String>()
        if (d.doors.isNotEmpty()) parts.add(d.doors.joinToString(", ") { a.doorLabel(it) })
        if (d.purposes.isNotEmpty()) parts.add(d.purposes.joinToString(", ") { a.purposeLabel(it) })
        parts.add(if (d.always) L("admin.always") else d.windows.joinToString(", ") { windowText(it) })
        parts.add(d.actions.joinToString(", ") { actionLabel(it.optString("type")) })
        return parts.joinToString(" · ")
    }

    private fun windowText(w: JSONObject): String {
        val days = w.optJSONArray("days")
        val dayText = if (days == null || days.length() == 7) "" else
            (0 until days.length()).joinToString("") { L("day.${days.optString(it)}") } + " "
        return dayText + w.optString("from") + "–" + w.optString("to")
    }

    private fun doorOptions() = a.doorIds().map { it to a.doorLabel(it) }

    private fun deviceOptions(role: String? = null): List<Pair<String, String>> {
        val devices = obj("devices")
        return ConfigIds.keysOf(devices).filter { role == null || devices?.optJSONObject(it)?.optString("role") == role }
            .sorted().map { it to (devices?.optJSONObject(it)?.optString("name").orEmpty().ifEmpty { it.take(8) }) }
    }

    private fun householdOptions() = ConfigIds.keysOf(obj("households")).sorted().map {
        it to local(obj("households")?.optJSONObject(it)?.optJSONObject("label"), it)
    }

    private fun replyOptions() = OrderedEntries.sorted(obj("quick_replies")).map {
        it to local(obj("quick_replies")?.optJSONObject(it)?.optJSONObject("label"), it)
    }

    private fun editRule(id: String?, original: JSONObject?) {
        var draft = if (original == null) RuleEditorModel.newRule() else RuleEditorModel.normalize(original)
        val (scroll, box) = form()
        fun render() {
            box.removeAllViews()
            val enabled = check(box, L("admin.enabled"), draft.enabled)
            enabled.setOnCheckedChangeListener { _, on -> draft = draft.copy(enabled = on) }
            fun sub(title: String, value: String, onClick: () -> Unit) {
                box.addView(ShellUi.row(a, a.palette, title, value, onClick = onClick),
                            ShellUi.matchWrap().apply { topMargin = ShellUi.dp(a, 6) })
            }
            sub(L("admin.rule_when"), whenLabel(draft.whenType)) {
                choose(L("admin.rule_when"), RuleEditorModel.WHEN_TYPES.map { it to whenLabel(it) }) {
                    draft = draft.copy(whenType = it); render()
                }
            }
            if (draft.whenType == "button" || draft.whenType == "motion")
                sub(L("admin.rule_doors"), if (draft.doors.isEmpty()) L("nset.all") else
                    draft.doors.joinToString(", ") { a.doorLabel(it) }) {
                    multi(L("admin.rule_doors"), doorOptions(), draft.doors) { draft = draft.copy(doors = it); render() }
                }
            if (draft.whenType == "button")
                sub(L("settings.purposes"), if (draft.purposes.isEmpty()) L("nset.all") else
                    draft.purposes.joinToString(", ") { a.purposeLabel(it) }) {
                    multi(L("settings.purposes"), VisitPurposes.all(cfg).map { it to a.purposeLabel(it) },
                          draft.purposes) { draft = draft.copy(purposes = it); render() }
                }
            if (draft.whenType == "device_offline")
                sub(L("admin.rule_devices"), draft.devices?.joinToString(", ") ?: L("nset.all")) {
                    multi(L("admin.rule_devices"), deviceOptions(), draft.devices.orEmpty()) {
                        draft = draft.copy(devices = it.ifEmpty { null }); render()
                    }
                }
            caption(box, L("admin.schedule"))
            val always = check(box, L("admin.always"), draft.always)
            always.setOnCheckedChangeListener { _, on -> draft = draft.copy(always = on); render() }
            if (!draft.always) {
                draft.windows.forEachIndexed { index, w ->
                    sub(L("admin.windows"), windowText(w)) {
                        editWindow(w, onDelete = {
                            draft = draft.copy(windows = draft.windows.filterIndexed { i, _ -> i != index }); render()
                        }) { changed ->
                            draft = draft.copy(windows = draft.windows.mapIndexed { i, old -> if (i == index) changed else old })
                            render()
                        }
                    }
                }
                sub(L("admin.add_window"), "") {
                    editWindow(JSONObject().put("from", "22:00").put("to", "06:00"), null) {
                        draft = draft.copy(windows = draft.windows + it); render()
                    }
                }
            }
            caption(box, L("nset.actions"))
            draft.actions.forEachIndexed { index, action ->
                sub(actionLabel(action.optString("type")), actionSummary(action)) {
                    editAction(action, draft.whenType, onDelete = {
                        draft = draft.copy(actions = draft.actions.filterIndexed { i, _ -> i != index }); render()
                    }) { changed ->
                        draft = draft.copy(actions = draft.actions.mapIndexed { i, old -> if (i == index) changed else old })
                        render()
                    }
                }
            }
            sub(L("admin.add_action"), "") {
                choose(L("admin.add_action"), RuleEditorModel.ACTION_TYPES.map { it to actionLabel(it) }) { type ->
                    val fresh = RuleEditorModel.defaultAction(type, draft.whenType)
                    editAction(fresh, draft.whenType, null) { draft = draft.copy(actions = draft.actions + it); render() }
                }
            }
        }
        render()
        val target = id ?: ConfigIds.next("r", ConfigIds.keysOf(obj(RuleEditorModel.ROOT)), seed())
        dialog(if (id == null) L("admin.add_rule") else id, scroll,
               if (id != null) L("admin.delete") else null, {
            confirm(L("admin.delete"), id.orEmpty(), L("admin.delete")) {
                a.writeOps(listOf(ConfigOp.Delete("${RuleEditorModel.ROOT}.$id")))
            }
        }) {
            val problems = RuleEditorModel.validate(draft)
            if (problems.isNotEmpty()) {
                a.toast(L("nset.rule_problem_${problems.first()}")); return@dialog false
            }
            a.writeOps(RuleEditorModel.ops(target, original, draft))
            true
        }
    }

    private fun actionSummary(action: JSONObject): String = when (action.optString("type")) {
        "sip_call" -> action.optString("target_extension")
        "telegram" -> (if (action.opt("households") == "all") L("nset.all") else
            action.optJSONArray("households")?.let { arr -> (0 until arr.length()).joinToString(", ") { arr.optString(it) } }
                .orEmpty()) + if (action.optBoolean("with_snapshot")) " · " + L("admin.with_snapshot") else ""
        "chime" -> soundName(action.optString("sound")).takeIf { action.has("sound") } ?: ""
        "auto_reply" -> replyOptions().firstOrNull { it.first == action.optString("reply_id") }?.second
            ?: action.optString("reply_id")
        "device_alert" -> action.optJSONArray("channels")?.let { arr ->
            (0 until arr.length()).joinToString(", ") { L("admin.channel_${arr.optString(it)}") } }.orEmpty()
        else -> ""
    }

    private fun editWindow(w: JSONObject, onDelete: (() -> Unit)?, onSave: (JSONObject) -> Unit) {
        val (scroll, box) = form()
        val from = field(box, L("settings.item_quiet_from"), w.optString("from"))
        val to = field(box, L("settings.item_quiet_to"), w.optString("to"))
        caption(box, L("nset.days"))
        val days = w.optJSONArray("days")
        val dayChecks = RuleEditorModel.DAYS.associateWith { day ->
            check(box, L("day.$day"), days == null || (0 until days.length()).any { days.optString(it) == day })
        }
        dialog(L("admin.windows"), scroll, if (onDelete != null) L("admin.delete") else null, onDelete) {
            val f = SettingsModel.normalizeTime(from.text.toString())
            val t = to.text.toString().trim().let { if (it == "24:00") it else SettingsModel.normalizeTime(it) }
            val chosen = dayChecks.filter { it.value.isChecked }.keys.toList()
            if (f == null || t == null || chosen.isEmpty()) { a.toast(L("settings.invalid_value")); return@dialog false }
            val out = JSONObject(w.toString()).put("from", f).put("to", t)
            if (chosen.size == 7) out.remove("days") else out.put("days", JSONArray(chosen))
            onSave(out)
            true
        }
    }

    private fun editAction(action: JSONObject, whenType: String, onDelete: (() -> Unit)?,
                           onSave: (JSONObject) -> Unit) {
        val out = JSONObject(action.toString())
        val (scroll, box) = form()
        var collect: () -> Boolean = { true }
        when (out.optString("type")) {
            "sip_call" -> {
                val target = field(box, L("admin.target_ext"), out.optString("target_extension"))
                collect = {
                    val v = target.text.toString().trim()
                    HouseholdModel.parseExtensions(v)?.singleOrNull()?.let { out.put("target_extension", it); true } ?: false
                }
            }
            "telegram" -> {
                var households: Any = out.opt("households") ?: "all"
                val allBox = check(box, L("nset.all_households"), households == "all")
                val pick = ShellUi.button(a, L("admin.households"), a.palette) {
                    val current = (households as? JSONArray)?.let { arr -> (0 until arr.length()).map { arr.optString(it) } }.orEmpty()
                    multi(L("admin.households"), householdOptions(), current) {
                        households = JSONArray(it); allBox.isChecked = it.isEmpty()
                    }
                }
                box.addView(pick, ShellUi.matchWrap())
                val snapshot = check(box, L("admin.with_snapshot"), out.optBoolean("with_snapshot"))
                val never = check(box, L("nset.never_suppress"), out.optBoolean("never_suppress"))
                collect = {
                    out.put("households", if (allBox.isChecked) "all" else households)
                    out.put("with_snapshot", snapshot.isChecked)
                    if (never.isChecked) out.put("never_suppress", true) else out.remove("never_suppress")
                    true
                }
            }
            "chime" -> {
                var devices: Any? = out.opt("devices")
                var sound = out.optString("sound")
                val label = TextView(a).apply { text = soundName(sound).takeIf { sound.isNotEmpty() } ?: L("nset.default_sound") }
                box.addView(ShellUi.button(a, L("admin.sound"), a.palette) {
                    chooseSound(L("admin.sound"), SettingsModel.RINGTONES, true) {
                        sound = it; label.text = if (it.isEmpty()) L("nset.default_sound") else soundName(it)
                    }
                }, ShellUi.matchWrap())
                box.addView(label, ShellUi.matchWrap())
                box.addView(ShellUi.button(a, L("admin.devices"), a.palette) {
                    val current = (devices as? JSONArray)?.let { arr -> (0 until arr.length()).map { arr.optString(it) } }.orEmpty()
                    multi(L("admin.devices"), deviceOptions("indoor_panel"), current) {
                        devices = if (it.isEmpty()) null else JSONArray(it)
                    }
                }, ShellUi.matchWrap())
                collect = {
                    if (sound.isEmpty()) out.remove("sound") else out.put("sound", sound)
                    if (devices == null) out.remove("devices") else out.put("devices", devices)
                    true
                }
            }
            "auto_reply" -> {
                val options = replyOptions()
                if (options.isEmpty()) caption(box, L("nset.no_replies"))
                val read = radio(box, L("admin.quick_replies"), options, out.optString("reply_id"))
                collect = { read().takeIf { it.isNotEmpty() }?.let { out.put("reply_id", it); true } ?: false }
            }
            "device_alert" -> {
                val current = out.optJSONArray("channels")?.let { arr -> (0 until arr.length()).map { arr.optString(it) } }
                    ?: listOf("in_app")
                caption(box, L("admin.alert_channels"))
                val channels = listOf("in_app", "system_notification", "web_push").associateWith {
                    check(box, L("admin.channel_$it"), it in current)
                }
                val never = check(box, L("nset.never_suppress"), out.optBoolean("never_suppress"))
                collect = {
                    val chosen = channels.filter { it.value.isChecked }.keys.toList()
                    if (chosen.isEmpty()) false else {
                        out.put("channels", JSONArray(chosen))
                        if (never.isChecked) out.put("never_suppress", true) else out.remove("never_suppress")
                        true
                    }
                }
            }
            "ha_event" -> caption(box, L("nset.ha_event_note"))
            else -> caption(box, L("nset.action_unknown", out.optString("type")))
        }
        dialog(actionLabel(out.optString("type")), scroll,
               if (onDelete != null) L("admin.delete") else null, onDelete) {
            if (!collect()) { a.toast(L("settings.invalid_value")); return@dialog false }
            onSave(out)
            true
        }
    }

    // ---------- Notifications: quiet hours ----------

    fun quietHours() {
        val card = a.section(L("settings.quiet_hours"))
        val state = QuietHoursModel.read(cfg)
        val original = obj(QuietHoursModel.KEY)
        fun save(next: QuietHoursModel.State) {
            val ops = QuietHoursModel.ops(next, original, cfg) ?: run { a.toast(L("settings.invalid_value")); return }
            a.writeOps(ops)
        }
        state.windows.forEachIndexed { index, w ->
            val dayText = w.days?.joinToString(" ") { L("day.$it") }.orEmpty()
            add(card, item("${w.from}–${w.to}", dayText) {
                val json = JSONObject().put("from", w.from).put("to", w.to)
                if (w.days != null) json.put("days", JSONArray(w.days))
                editWindow(json, onDelete = {
                    save(state.copy(windows = state.windows.filterIndexed { i, _ -> i != index }))
                }) { changed ->
                    val days = changed.optJSONArray("days")?.let { list ->
                        (0 until list.length()).map { list.optString(it) }
                    }
                    save(state.copy(windows = state.windows.mapIndexed { i, old ->
                        if (i == index) QuietHoursModel.Window(
                            changed.optString("from"), changed.optString("to"), days,
                        ).also { it.source = old.source } else old
                    }))
                }
            })
        }
        if (state.windows.isEmpty()) info(card, L("nset.quiet_none"))
        add(card, item(L("admin.add_window"), "", L("prefs.quiet_footer")) {
            save(state.copy(windows = state.windows + QuietHoursModel.Window("23:00", "07:00")))
        })
        val types = QuietHoursModel.ACTION_TYPES.map { it to actionLabel(it) }
        add(card, item(L("nset.quiet_suppress"), state.suppress.joinToString(", ") { actionLabel(it) }) {
            multi(L("nset.quiet_suppress"), types, state.suppress) { save(state.copy(suppress = it)) }
        })
        add(card, item(L("nset.never_suppress"), state.neverSuppress.joinToString(", ") { actionLabel(it) }) {
            multi(L("nset.never_suppress"), types, state.neverSuppress) { save(state.copy(neverSuppress = it)) }
        })
        if (dig(QuietHoursModel.LEGACY_KEY) != null)
            add(card, item(L("nset.quiet_legacy"), "", L("nset.quiet_legacy_note")) {
                a.writeOps(listOf(ConfigOp.Delete(QuietHoursModel.LEGACY_KEY)))
            })
    }

    // ---------- Notifications: Telegram, Web Push, MQTT / Home Assistant ----------

    fun telegram() {
        val card = a.section(L("settings.telegram"))
        secretRow(card, L("admin.bot_token"), "integrations.telegram.bot_token_ref", SecretRefs.TELEGRAM,
                  L("nset.secret_leader_note"))
        add(card, a.toggleRow(L("nset.telegram_poll"), "integrations.telegram.poll_updates",
                              SettingsModel.currentBool(cfg, "integrations.telegram.poll_updates", true),
                              L("nset.telegram_poll_note")))
        add(card, item(L("nset.telegram_template"), str("integrations.telegram.text_template.${a.texts.lang}"),
                       L("nset.telegram_template_note", "{door}", "{time}")) {
            a.labelDialog(L("nset.telegram_template"), obj("integrations.telegram.text_template")) { values ->
                a.writeOps(SettingsModel.LANGUAGES.map { lang ->
                    val text = values[lang].orEmpty().trim().take(500)
                    val key = "integrations.telegram.text_template.$lang"
                    if (text.isEmpty()) ConfigOp.Delete(key) else ConfigOp.Set(key, JSONObject.quote(text))
                })
            }
        })
        add(card, item(L("admin.test_send"), "", L("admin.telegram_test_chat")) { telegramTest() })
    }

    private fun telegramTest() {
        val session = a.adminSession
        if (session == null) { a.toast(L("nset.needs_session")); return }
        val (scroll, box) = form()
        val first = obj("households")?.let { h ->
            ConfigIds.keysOf(h).asSequence().mapNotNull { h.optJSONObject(it)?.optJSONArray("telegram_chat_ids")?.opt(0) }
                .firstOrNull()?.toString()
        }.orEmpty()
        val chat = field(box, L("admin.telegram_test_chat"), first)
        dialog(L("admin.test_send"), scroll) {
            val id = chat.text.toString().trim()
            if (id.toLongOrNull() == null) { a.toast(L("settings.invalid_value")); return@dialog false }
            Thread({
                val (status, reply) = session.request("POST", "/api/test/telegram", JSONObject().put("chat_id", id))
                var polled = reply
                val request = reply?.optString("request").orEmpty()
                if (reply?.optBoolean("pending") == true && request.isNotEmpty()) {
                    for (attempt in 0 until 20) {
                        Thread.sleep(500)
                        polled = session.request("GET", "/api/test/telegram/$request", null).second
                        if (polled?.optBoolean("pending") != true) break
                    }
                }
                val result = polled
                a.ui.post {
                    when {
                        status == 401 || status == 403 -> a.reauthenticateThen { telegramTest() }
                        result != null && result.optBoolean("ok") && !result.optBoolean("pending") ->
                            a.toast(L("admin.test_sent"))
                        else -> a.toast(L("nset.test_failed", result?.optString("err").orEmpty().ifEmpty { "$status" }))
                    }
                }
            }, "doorbell-telegram-test").apply { isDaemon = true }.start()
            true
        }
    }

    fun webPush() {
        val card = a.section(L("settings.web_push"))
        val root = "integrations.web_push"
        add(card, textRow(L("admin.web_push_sender_url"), "$root.sender_url") { it.startsWith("https://") && ' ' !in it })
        add(card, textRow(L("admin.web_push_public_key"), "$root.vapid_public_key", secretLooking = true) {
            it.matches(Regex("^[A-Za-z0-9_-]{86,88}$"))
        })
        add(card, textRow(L("admin.web_push_subject"), "$root.vapid_subject") {
            it.startsWith("mailto:") || it.startsWith("https://")
        })
        secretRow(card, L("admin.web_push_private_key"), "$root.vapid_private_key_ref", SecretRefs.WEBPUSH_VAPID,
                  L("nset.secret_leader_note"))
        secretRow(card, L("admin.web_push_sender_bearer"), "$root.sender_secret_ref", SecretRefs.WEBPUSH_SENDER,
                  L("nset.secret_leader_note"))
    }

    fun mqtt() {
        val card = a.section(L("nset.mqtt"))
        val root = "integrations.mqtt"
        add(card, textRow(L("admin.host"), "$root.host", L("nset.mqtt_host_note")) { SettingsModel.validHost(it) })
        add(card, a.numberRow(L("admin.port"), "$root.port", SettingsModel.currentInt(cfg, "$root.port", 1883), 1, 65535))
        add(card, a.toggleRow(L("nset.mqtt_tls"), "$root.tls", SettingsModel.currentBool(cfg, "$root.tls", false),
                              L("nset.mqtt_tls_note")))
        add(card, textRow(L("nset.mqtt_fingerprint"), "$root.tls_sha256", secretLooking = true) {
            it.lowercase().replace(":", "").matches(Regex("^[0-9a-f]{64}$"))
        })
        add(card, textRow(L("admin.user"), "$root.user", secretLooking = true) { it.length <= 128 })
        secretRow(card, L("nset.password"), "$root.pass_ref", SecretRefs.MQTT, L("nset.secret_leader_note"))
        add(card, textRow(L("nset.mqtt_discovery"), "$root.discovery_prefix") { it.matches(TOPIC) })
        add(card, textRow(L("nset.mqtt_base_topic"), "$root.base_topic") { it.matches(TOPIC) })
        add(card, a.choiceRow(L("nset.ha_language"), "integrations.ha.language", SettingsModel.LANGUAGES,
                              { Texts.langDisplayName(it) }, str("integrations.ha.language", "ja")))
        add(card, a.toggleRow(L("nset.ha_allow_sos"), "integrations.ha.allow_sos_control",
                              SettingsModel.currentBool(cfg, "integrations.ha.allow_sos_control", false),
                              L("nset.ha_allow_note")))
        add(card, a.toggleRow(L("nset.ha_allow_notice"), "integrations.ha.allow_notice_control",
                              SettingsModel.currentBool(cfg, "integrations.ha.allow_notice_control", false),
                              L("nset.ha_allow_note")))
        val bridge = a.status?.optJSONObject("bridge")?.optString("mqtt").orEmpty()
        if (bridge.isNotEmpty()) info(card, L("nset.mqtt_status", bridge))
    }

    // ---------- SIP: password, DTMF, WebRTC ----------

    fun sipExtras(card: LinearLayout) {
        secretRow(card, L("settings.item_sip_password"), "sip.accounts.${a.nodeId}.pass_ref",
                  SecretRefs.sipName(a.nodeId))
    }

    fun dtmf() {
        val card = a.section(L("settings.sip_dtmf"))
        val map = obj("sip.dtmf_actions")
        for (code in ConfigIds.keysOf(map).sorted()) {
            val action = map?.optJSONObject(code) ?: continue
            add(card, item(code, dtmfSummary(action)) { editDtmf(code, action) })
        }
        if (ConfigIds.keysOf(map).isEmpty()) info(card, L("nset.dtmf_none"))
        add(card, item(L("nset.dtmf_add"), "", L("nset.dtmf_note")) { editDtmf(null, null) })
        add(card, item(L("nset.dtmf_voice_menu"), "", L("nset.dtmf_voice_menu_note")) { seedVoiceMenu() })
    }

    private fun dtmfSummary(action: JSONObject): String = when (action.optString("type")) {
        "hangup" -> L("nset.dtmf_hangup")
        "decline" -> L("nset.dtmf_decline")
        "ha_command" -> L("nset.dtmf_ha", action.optString("command"),
                           action.optString("door").let { if (it == "self" || it.isEmpty()) L("nset.dtmf_self") else a.doorLabel(it) })
        "quick_reply" -> L("nset.dtmf_reply", replyOptions().firstOrNull { it.first == action.optString("reply_id") }?.second
            ?: action.optString("reply_id"))
        else -> action.optString("type")
    }

    private fun editDtmf(code: String?, action: JSONObject?) {
        val (scroll, box) = form()
        val codeField = field(box, L("nset.dtmf_code"), code.orEmpty())
        val type = radio(box, L("nset.dtmf_action"), DtmfModel.TYPES.map {
            it to when (it) {
                "hangup" -> L("nset.dtmf_hangup")
                "decline" -> L("nset.dtmf_decline")
                "ha_command" -> L("nset.dtmf_ha_type")
                else -> L("nset.dtmf_reply_type")
            }
        }, action?.optString("type") ?: "quick_reply")
        val command = field(box, L("unlock.command"), action?.optString("command").orEmpty())
        val door = radio(box, L("settings.door"), listOf("self" to L("nset.dtmf_self")) + doorOptions(),
                         action?.optString("door").orEmpty().ifEmpty { "self" })
        val reply = radio(box, L("admin.quick_replies"), replyOptions(), action?.optString("reply_id").orEmpty())
        dialog(code ?: L("nset.dtmf_add"), scroll, if (code != null) L("admin.delete") else null, {
            a.writeOps(listOf(ConfigOp.Delete(DtmfModel.key(code!!))))
        }) {
            val newCode = codeField.text.toString().trim().uppercase()
            if (!DtmfModel.validCode(newCode)) { a.toast(L("nset.dtmf_code_invalid")); return@dialog false }
            val json = DtmfModel.actionJson(type(), command.text.toString(), door(), reply())
                ?: run { a.toast(L("settings.invalid_value")); return@dialog false }
            val ops = ArrayList<ConfigOp>()
            if (code != null && code != newCode) ops.add(ConfigOp.Delete(DtmfModel.key(code)))
            ops.add(ConfigOp.Set(DtmfModel.key(newCode), json))
            a.writeOps(ops)
            true
        }
    }

    /** The phone-side voice menu mapping: #21..#29 for the replies in order, #90 to decline. */
    private fun seedVoiceMenu() {
        val existing = ConfigIds.keysOf(obj("sip.dtmf_actions")).toSet()
        val ops = ArrayList<ConfigOp>()
        OrderedEntries.sorted(obj("quick_replies")).take(9).forEachIndexed { index, id ->
            val code = "#2${index + 1}"
            if (code !in existing) ops.add(ConfigOp.Set(DtmfModel.key(code), DtmfModel.actionJson("quick_reply", "", "", id)!!))
        }
        if ("#90" !in existing) ops.add(ConfigOp.Set(DtmfModel.key("#90"), DtmfModel.actionJson("decline", "", "", "")!!))
        if (ops.isEmpty()) a.toast(L("nset.dtmf_voice_menu_present")) else a.writeOps(ops)
    }

    fun webrtc() {
        val card = a.section(L("nset.webrtc"))
        val root = "integrations.webrtc"
        add(card, textRow(L("nset.webrtc_ws_url"), "$root.ws_url", L("nset.webrtc_note")) {
            (it.startsWith("ws://") || it.startsWith("wss://")) && ' ' !in it &&
                '@' !in it.substringAfter("://").substringBefore('/')
        })
        add(card, textRow(L("nset.webrtc_user"), "$root.sip_user") { HouseholdModel.parseExtensions(it)?.size == 1 })
        val user = str("$root.sip_user")
        if (user.isNotEmpty()) secretRow(card, L("nset.webrtc_password"), "$root.sip_pass_ref", SecretRefs.webrtcName(user))
    }

    // ---------- Cluster: devices ----------

    fun devices() {
        val card = a.section(L("admin.devices"))
        val devices = obj("devices")
        for (id in ConfigIds.keysOf(devices).sortedBy { devices?.optJSONObject(it)?.optString("name").orEmpty() }) {
            val d = devices?.optJSONObject(id) ?: continue
            val self = id == a.nodeId
            val name = d.optString("name").ifEmpty { id.take(8) }
            val detail = listOfNotNull(a.roleLabel(d.optString("role")),
                d.optString("door").takeIf { it.isNotEmpty() && it != "null" }?.let { a.doorLabel(it) },
                if (self) L("nset.this_device") else null).joinToString(" · ")
            add(card, item(name, detail, id) {
                val options = ArrayList<Pair<String, String>>()
                options.add("rename" to L("nset.rename"))
                options.add("role" to L("settings.change_role"))
                if (d.optString("role") == "door_station") options.add("door" to L("admin.door_assign"))
                if (!self) options.add("remove" to L("admin.remove_device"))
                choose(name, options) { pick ->
                    when (pick) {
                        "rename" -> renameDevice(id, name)
                        "role" -> a.changeRole(id, d.optString("role"), d.optString("door"), self, name)
                        "door" -> choose(L("admin.door_assign"), doorOptions()) {
                            a.write("devices.$id.door", JSONObject.quote(it)) { }
                        }
                        "remove" -> confirm(L("admin.remove_device"), L("admin.remove_device_confirm"),
                                            L("admin.remove_device")) { removeDevice(id) }
                    }
                }
            })
        }
    }

    private fun renameDevice(id: String, current: String) {
        val (scroll, box) = form()
        val input = field(box, L("settings.device_name"), current)
        dialog(L("nset.rename"), scroll) {
            val name = input.text.toString().trim()
            if (name.isEmpty() || name.length > 64) { a.toast(L("settings.invalid_value")); return@dialog false }
            a.write("devices.$id.name", JSONObject.quote(name)) { }
            true
        }
    }

    private fun removeDevice(id: String) {
        a.coreCall({ JSONObject().put("result", a.app.core.removeDevice(id)) }) { result ->
            when (result?.optInt("result", -1)) {
                0 -> a.toast(L("admin.removed"))
                DoorbellCore.RESULT_ADMIN_REQUIRED -> a.reauthenticateThen { removeDevice(id) }
                else -> a.toast(L("admin.save_failed"))
            }
            a.refreshSnapshots(); a.render()
        }
    }

    // ---------- Cluster: Web panel identities ----------

    fun panels() {
        val card = a.section(L("settings.panels_manage"))
        val map = obj("panel.identities")
        val ids = ConfigIds.keysOf(map).filter { PanelIdentityModel.validId(it) }.sorted()
        if (ids.isEmpty()) info(card, L("panels.empty"))
        for (id in ids) {
            val p = map?.optJSONObject(id) ?: continue
            val revoked = p.optBoolean("revoked", true)
            val doors = p.optJSONArray("door_scope")?.let { arr -> (0 until arr.length()).joinToString(", ") { a.doorLabel(arr.optString(it)) } }.orEmpty()
            val grants = p.optJSONArray("grants")?.let { arr -> (0 until arr.length()).joinToString(", ") { grantLabel(arr.optString(it)) } }.orEmpty()
            val stored = SecretRefs.storeKey(p.optString("credential_ref"))?.let { a.app.core.hasPlatformSecret(it) } ?: false
            add(card, item("${L("panels.title")} ${id.take(8)}",
                           "${L(if (revoked) "panels.revoked" else "panels.active")} · $doors",
                           grants + if (!revoked && !stored) "\n" + L("panels.provisioning_required") else "") {
                if (revoked) return@item
                choose(id.take(8), listOf("edit" to L("admin.edit"), "rotate" to L("nset.panel_rotate"),
                                          "revoke" to L("panels.revoke"))) { pick ->
                    when (pick) {
                        "edit" -> editPanel(id, p)
                        "rotate" -> confirm(L("nset.panel_rotate"), L("panels.rotate_confirm"), L("nset.panel_rotate")) {
                            rotatePanel(id, p)
                        }
                        "revoke" -> confirm(L("panels.revoke"), L("panels.revoke_confirm"), L("panels.revoke")) {
                            savePanel("revoke", id, p, null, null, null)
                        }
                    }
                }
            })
        }
        add(card, item(L("panels.create"), "", L("nset.panel_note")) { editPanel(null, null) })
    }

    private fun grantLabel(grant: String) = L("panels.grant_" + grant.replace('.', '_'))

    private fun editPanel(id: String?, p: JSONObject?) {
        val doorsNow = p?.optJSONArray("door_scope")?.let { arr -> (0 until arr.length()).map { arr.optString(it) } }.orEmpty()
        val grantsNow = p?.optJSONArray("grants")?.let { arr -> (0 until arr.length()).map { arr.optString(it) } } ?: listOf("view")
        val (scroll, box) = form()
        caption(box, L("panels.door_scope"))
        val doorChecks = a.doorIds().associateWith { check(box, a.doorLabel(it), it in doorsNow) }
        if (doorChecks.isEmpty()) caption(box, L("panels.no_doors"))
        caption(box, L("panels.grants"))
        val grantChecks = PanelIdentityModel.GRANTS.associateWith { check(box, grantLabel(it), it in grantsNow) }
        dialog(if (id == null) L("panels.create") else id.take(8), scroll) {
            val doors = doorChecks.filter { it.value.isChecked }.keys.toList()
            val grants = grantChecks.filter { it.value.isChecked }.keys.toList()
            if (grants.isEmpty() || (doors.isEmpty() && grants.any { it != "sos.trigger" })) {
                a.toast(L("panels.scope_required")); return@dialog false
            }
            if (id == null) {
                val credential = hexToken(32)
                val name = SecretRefs.panelName(hexToken(8))
                storeSecret(name, credential) { ok ->
                    if (!ok) a.toast(L("nset.secret_store_failed"))
                    else savePanel("create", null, null, SecretRefs.ref(name), doors, grants) { showPanelLinks(credential) }
                }
            } else savePanel("update", id, p, null, doors, grants)
            true
        }
    }

    private fun rotatePanel(id: String, p: JSONObject) {
        val credential = hexToken(32)
        val name = SecretRefs.panelName(hexToken(8))
        storeSecret(name, credential) { ok ->
            if (!ok) a.toast(L("nset.secret_store_failed"))
            else savePanel("rotate", id, p, SecretRefs.ref(name), null, null) {
                // The old value is useless once the generation changed; drop it from this device.
                SecretRefs.storeKey(p.optString("credential_ref"))?.let { old ->
                    Thread({ a.app.core.deletePlatformSecret(old) }, "doorbell-secret-delete")
                        .apply { isDaemon = true }.start()
                }
                showPanelLinks(credential)
            }
        }
    }

    /**
     * Prefer Core's panel-identity service through the HTTP administrator session (it checks
     * credential reuse and bumps the generation); without one, write the same validated record.
     */
    private fun savePanel(action: String, id: String?, p: JSONObject?, ref: String?,
                          doors: List<String>?, grants: List<String>?, onDone: (() -> Unit)? = null) {
        val session = a.adminSession
        if (session != null && session.canCallSessionApis) {
            a.coreCall({
                val revision = a.app.core.configSnapshotV2()?.optString("revision").orEmpty()
                val body = JSONObject().put("expected_revision", revision)
                if (id != null) body.put("panel_id", id)
                if (action != "revoke") {
                    ref?.let { body.put("credential_ref", it) }
                    doors?.let { body.put("door_scope", JSONArray(it)) }
                    grants?.let { body.put("grants", JSONArray(it)) }
                }
                a.app.core.panelIdentityV2(action, body.toString(), session.sessionToken, session.csrf)
            }) { result ->
                when {
                    result?.optBoolean("ok") == true -> {
                        a.toast(L(if (action == "revoke") "panels.revoked_done" else "admin.saved"))
                        onDone?.invoke()
                    }
                    result?.optString("error_code") == "permission_denied" ->
                        a.reauthenticateThen { savePanel(action, id, p, ref, doors, grants, onDone) }
                    else -> a.toast(L("panels.failed_reason", result?.optString("error_code").orEmpty()))
                }
                a.refreshSnapshots(); a.render()
            }
            return
        }
        val record = when (action) {
            "create" -> PanelIdentityModel.record(ref!!, hexToken(16), doors!!, grants!!)
            "revoke" -> JSONObject(p.toString()).put("revoked", true).put("credential_generation", hexToken(16))
            else -> PanelIdentityModel.record(ref ?: p!!.optString("credential_ref"), hexToken(16),
                doors ?: listOfStrings(p!!.optJSONArray("door_scope")), grants ?: listOfStrings(p!!.optJSONArray("grants")))
        } ?: run { a.toast(L("panels.scope_required")); return }
        p?.optString("sip_account_id")?.takeIf { it.isNotEmpty() }?.let { record.put("sip_account_id", it) }
        val target = id ?: hexToken(16)
        a.writeOps(listOf(ConfigOp.Set(PanelIdentityModel.key(target), record.toString())))
        onDone?.invoke()
    }

    private fun listOfStrings(arr: JSONArray?): List<String> =
        if (arr == null) emptyList() else (0 until arr.length()).map { arr.optString(it) }

    /** The credential is shown once, as links and a QR for the door page. */
    private fun showPanelLinks(credential: String) {
        val base = AdminLinks.resolve(a.status, a.app.boot.httpPort).url.removeSuffix("/admin/")
        val (scroll, box) = form()
        caption(box, L("panels.one_time_warning"))
        for ((page, key) in listOf("door" to "panels.link_door", "monitor" to "panels.link_monitor",
                                   "call" to "panels.link_call")) {
            val link = "$base/panel/$page#k=$credential"
            caption(box, L(key))
            box.addView(TextView(a).apply {
                text = link
                setTextIsSelectable(true)
                textSize = 12f
            }, ShellUi.matchWrap())
            if (page == "door") AdminQrCache.get(a.app.core, link, ShellUi.dp(a, 180))?.let { bmp ->
                box.addView(android.widget.ImageView(a).apply { setImageBitmap(bmp) },
                            LinearLayout.LayoutParams(ShellUi.dp(a, 180), ShellUi.dp(a, 180)))
            }
        }
        ShellDialogBuilder(a).setTitle(L("panels.one_time_title")).setView(scroll)
            .setPositiveButton(L("panels.one_time_done"), null).show()
    }

    // ---------- Cluster: configuration export / import ----------

    fun transfer() {
        val card = a.section(L("settings.import_export"))
        add(card, item(L("admin.export"), "", L("nset.export_note")) { exportConfig() })
        add(card, item(L("admin.import"), "", L("nset.import_note")) { importConfig() })
    }

    private fun exportConfig() {
        val stamp = java.text.SimpleDateFormat("yyyyMMdd-HHmm", java.util.Locale.ROOT).format(java.util.Date())
        val intent = Intent("android.intent.action.CREATE_DOCUMENT").apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(Intent.EXTRA_TITLE, "doorbell-config-$stamp.json")
        }
        a.launchForResult(intent) { data ->
            val uri = data?.data ?: return@launchForResult
            Thread({
                val ok = try {
                    val snapshot = a.app.core.configSnapshotV2() ?: throw IllegalStateException("snapshot")
                    val text = ConfigTransfer.exportDocument(snapshot).toString(2)
                    a.contentResolver.openOutputStream(uri)?.use { it.write(text.toByteArray(Charsets.UTF_8)) } != null
                } catch (e: Exception) {
                    ShellLog.ignored("NativeSettings", e); false
                }
                a.ui.post { a.toast(L(if (ok) "nset.export_done" else "admin.save_failed")) }
            }, "doorbell-export").apply { isDaemon = true }.start()
        }
    }

    private fun importConfig() {
        val session = a.adminSession
        if (session == null || !session.canCallSessionApis) { a.toast(L("nset.needs_session")); return }
        pick("application/json", arrayOf("application/json", "text/plain", "application/octet-stream")) { bytes, _ ->
            val document = try { JSONObject(String(bytes, Charsets.UTF_8)) } catch (_: Exception) { null }
            val wanted = document?.let { ConfigTransfer.importedConfig(it) }
            if (wanted == null) { a.toast(L("admin.import_schema")); return@pick }
            a.coreCall({
                val revision = a.app.core.configSnapshotV2()?.optString("revision").orEmpty()
                val staged = a.app.core.configImportV2("stage", ConfigTransfer.stageRequest(revision, wanted),
                                                       session.sessionToken, session.csrf)
                if (staged?.optBoolean("ok") != true) return@coreCall staged
                val ref = JSONObject().put("schema_version", 2)
                    .put("stage_token", staged.optString("stage_token")).put("digest", staged.optString("digest"))
                val preflight = a.app.core.configImportV2("preflight", ref.toString(), session.sessionToken, session.csrf)
                preflight?.put("_ref", ref)
            }) { result ->
                if (result == null || !result.optBoolean("ok") || !result.has("_ref")) {
                    if (result?.optString("error_code") == "permission_denied") a.reauthenticateThen { importConfig() }
                    else a.toast(L("admin.import_error") + " " + result?.optString("error_code").orEmpty())
                    return@coreCall
                }
                confirmImport(result, session)
            }
        }
    }

    private fun confirmImport(preflight: JSONObject, session: AdminSession) {
        val ref = preflight.getJSONObject("_ref")
        val changes = preflight.optJSONArray("differences")?.length() ?: 0
        val missingSecrets = preflight.optJSONArray("missing_secret_refs")?.length() ?: 0
        val missingAssets = preflight.optJSONArray("missing_assets")?.length() ?: 0
        val problems = preflight.optJSONArray("problems")?.length() ?: 0
        val message = L("nset.import_summary", changes.toString(), missingSecrets.toString(),
                        missingAssets.toString(), problems.toString())
        if (!preflight.optBoolean("can_commit", false)) {
            ShellDialogBuilder(a).setTitle(L("admin.import_blocked")).setMessage(message)
                .setPositiveButton(L("admin.menu_close")) { _, _ -> cancelImport(ref, session) }.show()
            return
        }
        ShellDialogBuilder(a).setTitle(L("admin.import_commit")).setMessage(message)
            .setPositiveButton(L("admin.import_commit")) { _, _ ->
                val commit = JSONObject(ref.toString()).put("operation_id", ConfigTransfer.randomOperationId())
                a.coreCall({
                    a.app.core.configImportV2("commit", commit.toString(), session.sessionToken, session.csrf)
                }) { result ->
                    a.toast(if (result?.optBoolean("ok") == true) L("admin.imported")
                            else L("admin.import_error") + " " + result?.optString("error_code").orEmpty())
                    a.refreshSnapshots(); a.texts.setConfig(a.config); a.render()
                }
            }
            .setNegativeButton(L("admin.cancel")) { _, _ -> cancelImport(ref, session) }.show()
    }

    private fun cancelImport(ref: JSONObject, session: AdminSession) {
        Thread({ a.app.core.configImportV2("cancel", ref.toString(), session.sessionToken, session.csrf) },
               "doorbell-import-cancel").apply { isDaemon = true }.start()
    }

    /** Titles for settings search. */
    fun searchLabels(category: SettingsCategory): List<String> = when (category) {
        SettingsCategory.SOUND -> listOf(L("admin.sound_manager"), L("nset.sound_record"), L("nset.sos_alarm_sound"))
        SettingsCategory.DISPLAY -> listOf(L("settings.background_image"), L("nset.wording"))
        SettingsCategory.CALLS -> listOf(L("admin.quick_replies"), L("settings.purposes"), L("settings.item_reply_audio"))
        SettingsCategory.DOORS -> listOf(L("admin.add_door"), L("admin.buildings"), L("settings.notice_presets"),
                                         L("settings.media_sources"))
        SettingsCategory.NOTIFICATIONS -> listOf(L("settings.rules"), L("settings.quiet_hours"), L("settings.households"),
                                                 L("settings.telegram"), L("settings.web_push"), L("nset.mqtt"))
        SettingsCategory.SIP -> listOf(L("settings.item_sip_password"), L("settings.sip_dtmf"), L("nset.webrtc"))
        SettingsCategory.CLUSTER -> listOf(L("admin.devices"), L("settings.panels_manage"), L("settings.import_export"))
        else -> emptyList()
    }
}
