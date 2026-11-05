// Pure models behind the native settings editors that replaced every "open in Admin" row
// (.worktrees/native-settings-spec.md). Nothing here touches Android views, so each rule is
// covered by JVM unit tests: secret references, ordered lists, purposes, notice presets, quiet
// hours, the trigger-rule editor, DTMF actions, households, media sources, panel identities,
// asset sniffing, the WAV recorder container, wording-override keys and configuration import.
package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject

/**
 * `secret:<name>` references. The value lives only in this device's Keystore-backed secure store
 * (AndroidSecureStore, the same store Core reads through its secure_get callback, keyed by the
 * name without the prefix); configuration replicates the reference alone.
 */
internal object SecretRefs {
    const val PREFIX = "secret:"
    private val NAME = Regex("^[A-Za-z0-9._-]{1,153}$")

    fun validName(name: String): Boolean = NAME.matches(name)

    fun ref(name: String): String {
        require(validName(name)) { "invalid secret name" }
        return PREFIX + name
    }

    /** The secure-store key Core asks for: the reference without its prefix. */
    fun storeKey(ref: String): String? =
        if (ref.startsWith(PREFIX) && validName(ref.substring(PREFIX.length)))
            ref.substring(PREFIX.length) else null

    /** Config ops that point [configKey] at the secret [name]; the value is stored separately. */
    fun assignOps(configKey: String, name: String): List<ConfigOp> =
        listOf(ConfigOp.Set(configKey, JSONObject.quote(ref(name))))

    fun sipName(nodeId: String) = "sip.$nodeId"
    const val MQTT = "mqtt"
    const val TELEGRAM = "tg_bot"
    const val WEBPUSH_VAPID = "webpush.vapid_private"
    const val WEBPUSH_SENDER = "webpush.sender"
    fun webrtcName(user: String) = "webrtc.$user"
    fun mediaName(sourceId: String) = "media.$sourceId"
    fun panelName(panelId: String) = "panel.$panelId"
}

/** Fresh ids for configuration maps ("d_3f2a1c" style), never colliding with [existing]. */
internal object ConfigIds {
    private val SAFE = Regex("^[a-z][a-z0-9_]{0,31}$")

    fun valid(id: String): Boolean = SAFE.matches(id)

    fun next(prefix: String, existing: Collection<String>, seed: Long): String {
        var n = seed and 0xFFFFFF
        while (true) {
            val id = "%s_%06x".format(prefix, n)
            if (id !in existing) return id
            n = (n + 1) and 0xFFFFFF
        }
    }

    fun keysOf(map: JSONObject?): List<String> =
        map?.keys()?.asSequence()?.toList().orEmpty()
}

/** Shared "order" handling for quick replies and visit purposes. */
internal object OrderedEntries {
    fun sorted(map: JSONObject?): List<String> {
        if (map == null) return emptyList()
        return ConfigIds.keysOf(map).sortedWith(
            compareBy({ map.optJSONObject(it)?.optInt("order", 999) ?: 999 }, { it }))
    }

    /**
     * Move [id] by [delta] places and renumber 1..n so later inserts stay predictable. Only
     * entries whose order actually changes are written. Empty when the move is impossible.
     */
    fun moveOps(root: String, map: JSONObject?, id: String, delta: Int): List<ConfigOp> {
        val ids = sorted(map).toMutableList()
        val from = ids.indexOf(id)
        val to = from + delta
        if (from < 0 || to < 0 || to >= ids.size || delta == 0) return emptyList()
        ids.removeAt(from)
        ids.add(to, id)
        val ops = ArrayList<ConfigOp>()
        ids.forEachIndexed { index, entry ->
            val wanted = index + 1
            if (map?.optJSONObject(entry)?.optInt("order", -1) != wanted)
                ops.add(ConfigOp.Set("$root.$entry.order", wanted.toString()))
        }
        return ops
    }
}

/** Visit purposes: `visit_purposes.<id>{label{ja,en,zh},icon,order,enabled}`. */
internal object PurposeModel {
    const val MAX_ICON = 8

    fun json(labels: Map<String, String>, icon: String, order: Int, enabled: Boolean): String? {
        val label = labelObject(labels) ?: return null
        val out = JSONObject().put("label", label).put("order", order).put("enabled", enabled)
        val glyph = icon.trim()
        if (glyph.length > MAX_ICON) return null
        if (glyph.isNotEmpty()) out.put("icon", glyph)
        return out.toString()
    }

    fun nextOrder(map: JSONObject?): Int =
        (ConfigIds.keysOf(map).maxOfOrNull { map?.optJSONObject(it)?.optInt("order", 0) ?: 0 } ?: 0) + 1

    /** ja/en/zh labels with blanks dropped; null when none is left. */
    fun labelObject(labels: Map<String, String>): JSONObject? {
        val label = JSONObject()
        for (lang in SettingsModel.LANGUAGES) {
            val text = labels[lang].orEmpty().trim().take(80)
            if (text.isNotEmpty()) label.put(lang, text)
        }
        return if (label.length() == 0) null else label
    }
}

/** `notice.presets`: at most eight `{id,text}` entries, written as one array. */
internal object NoticePresetsModel {
    const val MAX = 8
    const val MAX_TEXT = 200

    fun read(config: JSONObject?): MutableList<Pair<String, String>> {
        val out = ArrayList<Pair<String, String>>()
        val stored = config?.optJSONObject("notice")?.optJSONArray("presets") ?: return out
        for (i in 0 until stored.length()) {
            val entry = stored.optJSONObject(i) ?: continue
            val text = entry.optString("text").trim()
            if (text.isNotEmpty()) out.add(entry.optString("id").ifEmpty { "p$i" } to text)
        }
        return out
    }

    /** Null when a text is blank/too long or the list is too long. */
    fun json(presets: List<Pair<String, String>>): String? {
        if (presets.size > MAX) return null
        val array = JSONArray()
        for ((id, text) in presets) {
            val clean = text.trim()
            if (clean.isEmpty() || clean.length > MAX_TEXT) return null
            array.put(JSONObject().put("id", id).put("text", clean))
        }
        return array.toString()
    }

    fun nextId(presets: List<Pair<String, String>>, seed: Long): String =
        ConfigIds.next("np", presets.map { it.first }, seed)
}

/**
 * Top-level `quiet_hours.default{windows[{from,to,days?}],suppress[],never_suppress[]}` -- the
 * key RuleEngine reads. The old Android screen wrote `notify.quiet_hours`, which nothing reads;
 * [legacyKey] is deleted in the same batch so the stale value disappears.
 */
internal object QuietHoursModel {
    const val KEY = "quiet_hours.default"
    const val LEGACY_KEY = "notify.quiet_hours"
    val ACTION_TYPES = listOf("chime", "sip_call", "telegram", "ha_event", "device_alert",
                              "auto_reply")

    data class Window(val from: String, val to: String)

    data class State(
        val windows: List<Window>,
        val suppress: List<String>,
        val neverSuppress: List<String>,
    )

    fun read(config: JSONObject?): State {
        val def = config?.optJSONObject("quiet_hours")?.optJSONObject("default")
        val windows = ArrayList<Window>()
        val array = def?.optJSONArray("windows")
        if (array != null) for (i in 0 until array.length()) {
            val w = array.optJSONObject(i) ?: continue
            windows.add(Window(w.optString("from"), w.optString("to")))
        }
        return State(windows, strings(def?.optJSONArray("suppress"), listOf("chime")),
                     strings(def?.optJSONArray("never_suppress"), emptyList()))
    }

    /** Null when a window is malformed. A window may end at 24:00. */
    fun ops(state: State, original: JSONObject?, config: JSONObject?): List<ConfigOp>? {
        val out = JSONObject(original?.toString() ?: "{}")
        val windows = JSONArray()
        val previous = original?.optJSONArray("windows")
        state.windows.forEachIndexed { index, w ->
            val from = SettingsModel.normalizeTime(w.from) ?: return null
            val to = if (w.to == "24:00") "24:00" else SettingsModel.normalizeTime(w.to) ?: return null
            // Keep any "days" filter the web admin set on the same window.
            val base = previous?.optJSONObject(index)?.let { JSONObject(it.toString()) } ?: JSONObject()
            windows.put(base.put("from", from).put("to", to))
        }
        out.put("windows", windows)
        out.put("suppress", JSONArray(state.suppress))
        out.put("never_suppress", JSONArray(state.neverSuppress))
        val ops = ArrayList<ConfigOp>()
        ops.add(ConfigOp.Set(KEY, out.toString()))
        if (SettingsModel.dig(config, LEGACY_KEY) != null) ops.add(ConfigOp.Delete(LEGACY_KEY))
        return ops
    }

    private fun strings(array: JSONArray?, fallback: List<String>): List<String> {
        if (array == null) return fallback
        return (0 until array.length()).map { array.optString(it) }.filter { it.isNotEmpty() }
    }
}

/**
 * The trigger-rule editor, a port of the web admin's normalizeRuleEditor/mergeRuleEditor:
 * fields the editor does not show (vendor matchers, presentation, never_suppress, unknown
 * actions) survive a save unchanged, and an untouched field is not rewritten.
 */
internal data class RuleDraft(
    val enabled: Boolean,
    val whenType: String,
    val doors: List<String>,
    /** null means "all". */
    val devices: List<String>?,
    val purposes: List<String>,
    val always: Boolean,
    val windows: List<JSONObject>,
    val actions: List<JSONObject>,
)

internal object RuleEditorModel {
    const val ROOT = "trigger_rules"
    val WHEN_TYPES = listOf("button", "motion", "device_offline", "emergency_on",
                            "emergency_off", "call_missed")
    val ACTION_TYPES = listOf("sip_call", "telegram", "ha_event", "chime", "device_alert",
                              "auto_reply")
    val DAYS = listOf("mon", "tue", "wed", "thu", "fri", "sat", "sun")

    fun normalize(rule: JSONObject?): RuleDraft {
        val r = rule ?: JSONObject()
        val whenObj = r.optJSONObject("when") ?: JSONObject()
        val schedule = r.optJSONObject("schedule")
        val devicesValue = whenObj.opt("devices")
        val windowsArray = schedule?.optJSONArray("windows")
        return RuleDraft(
            enabled = r.optBoolean("enabled", true),
            whenType = whenObj.optString("type").ifEmpty { "button" },
            doors = strings(whenObj.optJSONArray("doors")),
            devices = if (devicesValue is JSONArray) strings(devicesValue) else null,
            purposes = strings(whenObj.optJSONArray("purposes")),
            always = schedule == null || schedule.optBoolean("always", false) || windowsArray == null,
            windows = objects(windowsArray),
            actions = objects(r.optJSONArray("actions")),
        )
    }

    fun merge(original: JSONObject?, draft: RuleDraft): JSONObject {
        val has = original != null
        val out = JSONObject(original?.toString() ?: "{}")
        val before = normalize(original)
        if (!has || draft.enabled != before.enabled) out.put("enabled", draft.enabled)

        val whenObj = out.optJSONObject("when") ?: JSONObject()
        if (!has || draft.whenType != before.whenType || out.optJSONObject("when") == null)
            whenObj.put("type", draft.whenType)
        when (draft.whenType) {
            "device_offline" -> if (!has || draft.devices != before.devices)
                whenObj.put("devices", draft.devices?.let { JSONArray(it) } ?: "all")
            "button", "motion" -> {
                if (!has || draft.doors != before.doors) {
                    if (draft.doors.isEmpty()) whenObj.remove("doors")
                    else whenObj.put("doors", JSONArray(draft.doors))
                }
                if (draft.whenType == "button" && (!has || draft.purposes != before.purposes)) {
                    if (draft.purposes.isEmpty()) whenObj.remove("purposes")
                    else whenObj.put("purposes", JSONArray(draft.purposes))
                }
            }
        }
        out.put("when", whenObj)

        if (!has || draft.always != before.always ||
            (!draft.always && !sameObjects(draft.windows, before.windows))) {
            val schedule = out.optJSONObject("schedule") ?: JSONObject()
            if (draft.always) {
                schedule.put("always", true)
                schedule.remove("windows")
            } else {
                schedule.remove("always")
                schedule.put("windows", JSONArray(draft.windows.map { JSONObject(it.toString()) }))
            }
            out.put("schedule", schedule)
        }
        if (!has || !sameObjects(draft.actions, before.actions))
            out.put("actions", JSONArray(draft.actions.map { JSONObject(it.toString()) }))
        return out
    }

    /** Problems the editor reports before writing; empty means savable. */
    fun validate(draft: RuleDraft): List<String> {
        val problems = ArrayList<String>()
        if (draft.actions.isEmpty()) problems.add("actions_required")
        if (!draft.always && draft.windows.isEmpty()) problems.add("windows_required")
        for (w in draft.windows) {
            if (SettingsModel.normalizeTime(w.optString("from")) == null) problems.add("window_time")
            val to = w.optString("to")
            if (to != "24:00" && SettingsModel.normalizeTime(to) == null) problems.add("window_time")
        }
        for (a in draft.actions) when (a.optString("type")) {
            "sip_call" -> if (a.optString("target_extension").isBlank()) problems.add("sip_target")
            "auto_reply" -> if (a.optString("reply_id").isBlank()) problems.add("reply_id")
        }
        return problems.distinct()
    }

    fun ops(id: String, original: JSONObject?, draft: RuleDraft): List<ConfigOp> =
        listOf(ConfigOp.Set("$ROOT.$id", merge(original, draft).toString()))

    fun newRule(): RuleDraft = RuleDraft(true, "button", emptyList(), null, emptyList(), true,
                                         emptyList(), listOf(defaultAction("chime", "button")))

    /** A fresh action of [type] with the same defaults the web admin creates. */
    fun defaultAction(type: String, whenType: String): JSONObject = when (type) {
        "sip_call" -> JSONObject().put("type", type).put("target_extension", "")
        "telegram" -> JSONObject().put("type", type).put("households", "all")
            .put("with_snapshot", whenType == "button" || whenType == "motion")
        "chime" -> JSONObject().put("type", type)
        "auto_reply" -> JSONObject().put("type", type).put("reply_id", "")
        "device_alert" -> {
            val sos = whenType == "emergency_on"
            JSONObject().put("type", type)
                .put("targets", JSONObject().put("roles", "all"))
                .put("channels", JSONArray(listOf("in_app", "system_notification")))
                .put("presentation", JSONObject().put("visual", true).put("sticky", sos)
                    .put("ttl_s", if (sos) 0 else 10))
        }
        else -> JSONObject().put("type", type)
    }

    private fun strings(array: JSONArray?): List<String> =
        if (array == null) emptyList()
        else (0 until array.length()).map { array.optString(it) }.filter { it.isNotEmpty() }

    private fun objects(array: JSONArray?): List<JSONObject> =
        if (array == null) emptyList()
        else (0 until array.length()).mapNotNull { array.optJSONObject(it) }
            .map { JSONObject(it.toString()) }

    private fun sameObjects(a: List<JSONObject>, b: List<JSONObject>): Boolean =
        a.size == b.size && a.indices.all { JsonSame.equal(a[it], b[it]) }
}

/** Structural JSON equality (key order independent). */
internal object JsonSame {
    fun equal(a: Any?, b: Any?): Boolean = when {
        a is JSONObject && b is JSONObject -> {
            val ak = a.keys().asSequence().toSet()
            ak == b.keys().asSequence().toSet() && ak.all { equal(a.opt(it), b.opt(it)) }
        }
        a is JSONArray && b is JSONArray ->
            a.length() == b.length() && (0 until a.length()).all { equal(a.opt(it), b.opt(it)) }
        a is Number && b is Number -> a.toDouble() == b.toDouble()
        else -> a == b
    }
}

/** `sip.dtmf_actions.<code>`: hangup | ha_command{command,door} | quick_reply{reply_id} | decline. */
internal object DtmfModel {
    val TYPES = listOf("hangup", "ha_command", "quick_reply", "decline")
    private val CODE = Regex("^[0-9*#A-D]{1,8}$")
    private val COMMAND = Regex("^[A-Za-z0-9_-]{1,32}$")

    fun validCode(code: String): Boolean = CODE.matches(code)

    /** Null when the action is incomplete. [door] is "self" or a door id. */
    fun actionJson(type: String, command: String, door: String, replyId: String): String? =
        when (type) {
            "hangup", "decline" -> JSONObject().put("type", type).toString()
            "ha_command" -> if (!COMMAND.matches(command.trim())) null
                else JSONObject().put("type", type).put("command", command.trim())
                    .put("door", door.ifEmpty { "self" }).toString()
            "quick_reply" -> if (replyId.isEmpty()) null
                else JSONObject().put("type", type).put("reply_id", replyId).toString()
            else -> null
        }

    fun key(code: String) = "sip.dtmf_actions.$code"
}

/** `households.<id>{label{...},telegram_chat_ids[],sip_extensions[]}`. */
internal object HouseholdModel {
    private val EXTENSION = Regex("^[A-Za-z0-9*#+._-]{1,32}$")

    /** Chat ids are integers (groups are negative); null when any entry is not. */
    fun parseChatIds(raw: String): List<Long>? = split(raw).map { it.toLongOrNull() ?: return null }

    fun parseExtensions(raw: String): List<String>? =
        split(raw).onEach { if (!EXTENSION.matches(it)) return null }

    fun json(original: JSONObject?, labels: Map<String, String>, chatIds: List<Long>,
             extensions: List<String>): String? {
        val label = PurposeModel.labelObject(labels) ?: return null
        val out = JSONObject(original?.toString() ?: "{}")
        out.put("label", label)
        out.put("telegram_chat_ids", JSONArray(chatIds))
        out.put("sip_extensions", JSONArray(extensions))
        return out.toString()
    }

    fun split(raw: String): List<String> =
        raw.split(',', '\n', ' ').map { it.trim() }.filter { it.isNotEmpty() }
}

/** `media_sources.<id>`: explicit IP cameras; credentials only through `secret:media.<id>`. */
internal object MediaSourceModel {
    data class Draft(val mjpeg: String, val snapshot: String, val h264: String,
                     val transport: String, val hasSecret: Boolean)

    fun read(source: JSONObject?): Draft {
        val streams = source?.optJSONObject("streams")
        return Draft(
            streams?.optJSONObject("mjpeg")?.optString("url").orEmpty(),
            streams?.optJSONObject("snapshot")?.optString("url").orEmpty(),
            streams?.optJSONObject("h264")?.optString("url").orEmpty(),
            streams?.optJSONObject("h264")?.optString("transport").orEmpty().ifEmpty { "tcp" },
            source?.optString("secret_ref").orEmpty().isNotEmpty(),
        )
    }

    /** http(s) for MJPEG/snapshot, rtsp for H.264; userinfo is always refused. */
    fun validUrl(url: String, schemes: Set<String>): Boolean {
        if (url.isEmpty()) return true
        val scheme = url.substringBefore("://", "").lowercase()
        if (scheme !in schemes) return false
        val authority = url.substringAfter("://").substringBefore('/')
        return authority.isNotEmpty() && '@' !in authority && ' ' !in url
    }

    fun json(id: String, original: JSONObject?, draft: Draft): String? {
        val http = setOf("http", "https")
        if (!validUrl(draft.mjpeg, http) || !validUrl(draft.snapshot, http) ||
            !validUrl(draft.h264, setOf("rtsp", "rtsps"))) return null
        if (draft.mjpeg.isEmpty() && draft.snapshot.isEmpty() && draft.h264.isEmpty()) return null
        val out = JSONObject(original?.toString() ?: "{}")
        out.put("schema_version", 1).put("kind", "ip_camera")
        val streams = out.optJSONObject("streams") ?: JSONObject()
        fun stream(name: String, url: String, extra: (JSONObject) -> Unit = {}) {
            if (url.isEmpty()) streams.remove(name)
            else streams.put(name, (streams.optJSONObject(name) ?: JSONObject()).put("url", url)
                .also(extra))
        }
        stream("mjpeg", draft.mjpeg)
        stream("snapshot", draft.snapshot)
        stream("h264", draft.h264) { it.put("transport", draft.transport) }
        out.put("streams", streams)
        if (draft.hasSecret) out.put("secret_ref", SecretRefs.ref(SecretRefs.mediaName(id)))
        else out.remove("secret_ref")
        return out.toString()
    }
}

/** Independent Web panel identities, written as `panel.identities.<32-hex>` records. */
internal object PanelIdentityModel {
    val GRANTS = listOf("view", "call.monitor", "call.answer", "call.initiate", "sos.trigger",
                        "door.open", "media.publish", "notice.write")
    private val HEX32 = Regex("^[0-9a-f]{32}$")

    fun validId(id: String) = HEX32.matches(id)

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    fun record(credentialRef: String, generation: String, doors: List<String>,
               grants: List<String>, revoked: Boolean = false): JSONObject? {
        if (!validId(generation) || SecretRefs.storeKey(credentialRef) == null) return null
        if (grants.isEmpty() || grants.any { it !in GRANTS }) return null
        // Door-scoped grants need at least one door; sos.trigger alone does not.
        if (doors.isEmpty() && grants.any { it != "sos.trigger" }) return null
        return JSONObject().put("credential_ref", credentialRef)
            .put("credential_generation", generation)
            .put("door_scope", JSONArray(doors.distinct().sorted()))
            .put("grants", JSONArray(grants.distinct().sorted()))
            .put("revoked", revoked)
    }

    fun key(id: String) = "panel.identities.$id"
}

/** Ledger types Core accepts, recognised from the bytes rather than a file name. */
internal object AssetTypes {
    const val MAX_BYTES = 3 * 1024 * 1024
    val IMAGES = listOf("image/jpeg", "image/png")
    val SOUNDS = listOf("audio/mpeg", "audio/wav")

    fun sniff(head: ByteArray): String? {
        fun at(i: Int) = if (i < head.size) head[i].toInt() and 0xFF else -1
        return when {
            at(0) == 0xFF && at(1) == 0xD8 && at(2) == 0xFF -> "image/jpeg"
            at(0) == 0x89 && at(1) == 0x50 && at(2) == 0x4E && at(3) == 0x47 -> "image/png"
            ascii(head, 0, "RIFF") && ascii(head, 8, "WAVE") -> "audio/wav"
            ascii(head, 0, "ID3") -> "audio/mpeg"
            at(0) == 0xFF && (at(1) and 0xE0) == 0xE0 -> "audio/mpeg"
            else -> null
        }
    }

    private fun ascii(b: ByteArray, off: Int, s: String): Boolean =
        b.size >= off + s.length && s.indices.all { b[off + it].toInt() == s[it].code }

    /** Assets of one kind from `assets.<sha>{type,label,size}`, label-sorted. */
    fun list(config: JSONObject?, kinds: List<String>): List<Pair<String, JSONObject>> {
        val ledger = config?.optJSONObject("assets") ?: return emptyList()
        return ConfigIds.keysOf(ledger).mapNotNull { hash ->
            val entry = ledger.optJSONObject(hash) ?: return@mapNotNull null
            if (entry.optString("type") in kinds) hash to entry else null
        }.sortedBy { it.second.optString("label").lowercase() }
    }
}

/** 16-bit mono PCM to a RIFF/WAVE file -- the recorder's container (audio/wav). */
internal object WavFormat {
    fun wrap(pcm: ByteArray, sampleRate: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream(44 + pcm.size)
        fun le32(v: Int) = out.write(byteArrayOf(v.toByte(), (v shr 8).toByte(),
                                                 (v shr 16).toByte(), (v shr 24).toByte()))
        fun le16(v: Int) = out.write(byteArrayOf(v.toByte(), (v shr 8).toByte()))
        out.write("RIFF".toByteArray(Charsets.US_ASCII)); le32(36 + pcm.size)
        out.write("WAVE".toByteArray(Charsets.US_ASCII))
        out.write("fmt ".toByteArray(Charsets.US_ASCII)); le32(16); le16(1); le16(1)
        le32(sampleRate); le32(sampleRate * 2); le16(2); le16(16)
        out.write("data".toByteArray(Charsets.US_ASCII)); le32(pcm.size)
        out.write(pcm)
        return out.toByteArray()
    }

    /** Longest recording that still fits the ledger's 3 MiB limit. */
    fun maxSeconds(sampleRate: Int): Int = (AssetTypes.MAX_BYTES - 44) / (sampleRate * 2)
}

/** strings.yaml keys from generated Android resource names (dots became underscores). */
internal object I18nKeys {
    private val MULTI = listOf("web_admin_" to "web_admin.", "pair_err_" to "pair.err.")

    fun fromResourceName(name: String): String? {
        for ((resource, key) in MULTI)
            if (name.startsWith(resource) && name.length > resource.length)
                return key + name.substring(resource.length)
        val cut = name.indexOf('_')
        if (cut <= 0 || cut == name.length - 1) return null
        return name.substring(0, cut) + "." + name.substring(cut + 1)
    }

    /**
     * Catalogue keys contain dots, so overrides are written the way the web admin writes them:
     * one whole `i18n_overrides.<lang>` object per changed language, deleted once empty.
     */
    fun overrideOps(overrides: JSONObject?, key: String, values: Map<String, String>): List<ConfigOp> {
        val ops = ArrayList<ConfigOp>()
        for ((lang, raw) in values) {
            val before = overrides?.optJSONObject(lang)
            val next = JSONObject(before?.toString() ?: "{}")
            val text = raw.trim()
            if (text.isEmpty()) next.remove(key) else next.put(key, text)
            if (JsonSame.equal(before ?: JSONObject(), next)) continue
            ops.add(if (next.length() == 0) ConfigOp.Delete("i18n_overrides.$lang")
                    else ConfigOp.Set("i18n_overrides.$lang", next.toString()))
        }
        return ops
    }

    fun current(overrides: JSONObject?, lang: String, key: String): String =
        overrides?.optJSONObject(lang)?.optString(key).orEmpty()

    /** Placeholders like {name} must survive an override unchanged. */
    fun placeholdersMatch(original: String, replacement: String): Boolean {
        val re = Regex("\\{(\\w+)\\}|%(\\d+\\$)?[sd]")
        fun set(s: String) = re.findAll(s).map { it.value.replace(Regex("^%\\d+\\$"), "%") }
            .toList().sorted()
        return set(original).size == set(replacement).size
    }
}

/** Export/import of the whole mutable configuration (schema 2). */
internal object ConfigTransfer {
    fun exportDocument(snapshot: JSONObject): JSONObject = JSONObject()
        .put("schema_version", 2)
        .put("config", snapshot.optJSONObject("config") ?: JSONObject())

    /** The `config` object of an exported file or a raw snapshot; null when unusable. */
    fun importedConfig(document: JSONObject): JSONObject? {
        if (document.optInt("schema_version", 0) != 2) return null
        return document.optJSONObject("config")
    }

    /** The stage request db_core_config_import_json_v2 takes. */
    fun stageRequest(revision: String, config: JSONObject): String = JSONObject()
        .put("schema_version", 2).put("expected_revision", revision)
        .put("document", JSONObject().put("schema_version", 2).put("config", config))
        .toString()

    fun randomOperationId(random: java.util.Random = java.security.SecureRandom()): String {
        val bytes = ByteArray(16)
        random.nextBytes(bytes)
        return PanelIdentityModel.hex(bytes)
    }
}
