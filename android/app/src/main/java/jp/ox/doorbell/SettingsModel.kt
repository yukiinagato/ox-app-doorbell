// The native settings catalogue: which categories exist, which configuration keys each one
// edits, and how a value typed or picked on the device becomes the JSON document Core accepts.
//
// Nothing here touches Android, so the mapping and every validation rule are host-tested. The
// activity renders these specs and writes through ConfigWriter, which is the same validated
// configuration path the Web admin uses.
package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject

/** The left-hand list of the settings screen, in display order. */
internal enum class SettingsCategory(val id: String, val titleKey: String) {
    DEVICE("device", "settings.cat_device"),
    SOUND("sound", "settings.cat_sound"),
    DISPLAY("display", "settings.cat_display"),
    CALLS("calls", "settings.cat_calls"),
    DOORS("doors", "settings.cat_doors"),
    EMERGENCY("emergency", "settings.cat_emergency"),
    NOTIFICATIONS("notifications", "settings.cat_notifications"),
    TIME("time", "settings.cat_time"),
    SIP("sip", "settings.cat_sip"),
    NETWORK("network", "settings.cat_network"),
    CLUSTER("cluster", "settings.cat_cluster"),
    ABOUT("about", "settings.cat_about");

    companion object {
        fun byId(id: String?): SettingsCategory? = values().firstOrNull { it.id == id }
    }
}

/**
 * One editable setting. [key] may contain `{node}`, replaced by this device's node id, for the
 * per-device overrides under `devices.<id>.local`.
 */
internal sealed class SettingSpec {
    abstract val key: String
    abstract val titleKey: String
    open val noteKey: String = ""

    data class Toggle(
        override val key: String,
        override val titleKey: String,
        val default: Boolean,
        override val noteKey: String = "",
    ) : SettingSpec()

    /** One of a fixed set. [optionKeyPrefix] + option is the label key; "" maps to [noneKey]. */
    data class Choice(
        override val key: String,
        override val titleKey: String,
        val options: List<String>,
        val default: String,
        val optionKeyPrefix: String,
        val numeric: Boolean = false,
        val noneKey: String = "settings.sound_none",
        override val noteKey: String = "",
    ) : SettingSpec()

    data class MultiChoice(
        override val key: String,
        override val titleKey: String,
        val options: List<String>,
        val default: List<String>,
        val optionKeyPrefix: String,
        val minSelected: Int = 1,
    ) : SettingSpec()

    /** An integer; [slider] shows a SeekBar, otherwise a number field. */
    data class IntRange(
        override val key: String,
        override val titleKey: String,
        val min: Int,
        val max: Int,
        val default: Int,
        val slider: Boolean = false,
        override val noteKey: String = "",
    ) : SettingSpec()

    /** "HH:MM" in the cluster time zone. */
    data class Time(
        override val key: String,
        override val titleKey: String,
        val default: String,
    ) : SettingSpec()

    data class Text(
        override val key: String,
        override val titleKey: String,
        val kind: TextKind,
        val default: String = "",
        override val noteKey: String = "",
    ) : SettingSpec()
}

internal enum class TextKind { HOST, EXTENSION, UNLOCK_COMMAND, LABEL }

internal enum class PasswordCheck { OK, TOO_SHORT, TOO_LONG, MISMATCH }

internal object SettingsModel {

    const val NODE = "{node}"

    /** Bundled sound names Core and every shell know; "" disables the sound. */
    val RINGTONES = listOf("school_chime", "ding1", "ding2", "classic")
    val ROLES = listOf("indoor_panel", "door_station")
    val LANGUAGES = listOf("ja", "en", "zh")

    fun resolve(key: String, nodeId: String): String = key.replace(NODE, nodeId)

    /**
     * The generic specs a category shows. Categories with structured content (doors, quick
     * replies, rules, cluster members) add custom rows around these in the activity.
     */
    fun specs(category: SettingsCategory, role: String): List<SettingSpec> = when (category) {
        SettingsCategory.DEVICE -> listOfNotNull(
            SettingSpec.Choice("devices.$NODE.local.ui_lang", "settings.ui_lang", LANGUAGES, "ja",
                               "lang."),
            SettingSpec.IntRange("devices.$NODE.local.call.return_s", "settings.item_return_s",
                                 5, 600, 60, noteKey = "settings.item_return_s_note")
                .takeIf { role != "door_station" },
            SettingSpec.Toggle("devices.$NODE.local.motion.wake_screen",
                               "settings.item_motion_wake", false)
                .takeIf { role == "door_station" },
            SettingSpec.Choice("devices.$NODE.local.recovery.helper_mode", "settings.helper_mode",
                               listOf("off", "auto", "on"), "auto", "admin.helper_"),
        )
        SettingsCategory.SOUND -> listOf(
            SettingSpec.Choice("ui.ringtone", "admin.indoor_ringtone", RINGTONES, "school_chime",
                               "settings.sound_"),
            SettingSpec.Choice("ui.call_sound", "admin.door_call_sound",
                               listOf("outdoor_call_alert", ""), "outdoor_call_alert",
                               "settings.sound_"),
            SettingSpec.Toggle("ui.call_sound_loop", "admin.call_sound_loop", false),
            SettingSpec.Choice("ui.button_sound", "admin.button_sound",
                               listOf("button_click", ""), "button_click", "settings.sound_"),
            SettingSpec.Choice("ui.update_sound", "admin.update_sound",
                               listOf("indoor_update", ""), "indoor_update", "settings.sound_"),
            SettingSpec.Choice("ui.launch_sound", "admin.launch_sound",
                               listOf("title_display", ""), "title_display", "settings.sound_"),
        )
        SettingsCategory.DISPLAY -> listOf(
            SettingSpec.Choice("devices.$NODE.local.video.playback", "settings.video_playback",
                               listOf("auto", "h264", "mjpeg"), "auto", "settings.playback_"),
            SettingSpec.Choice("devices.$NODE.local.video.rotation", "settings.video_rotation",
                               listOf("0", "90", "180", "270"), "0", "settings.rotation_",
                               numeric = true),
            SettingSpec.IntRange("display.brightness", "settings.item_brightness", 0, 100, 70,
                                 slider = true),
            SettingSpec.Toggle("display.night.enabled", "settings.item_night", true),
            SettingSpec.Time("display.night.from", "settings.item_night_from", "22:00"),
            SettingSpec.Time("display.night.to", "settings.item_night_to", "06:00"),
            SettingSpec.IntRange("display.night.brightness", "settings.item_night_brightness",
                                 0, 100, 15, slider = true),
            SettingSpec.Toggle("display.screensaver.enabled", "settings.item_saver", true),
            SettingSpec.IntRange("display.screensaver.after_s", "settings.item_saver_after",
                                 1, 86_400, 120),
            SettingSpec.IntRange("display.screensaver.brightness", "display.saver_brightness",
                                 1, 100, 10, slider = true),
            SettingSpec.IntRange("display.theme.backdrop.opacity", "theme.backdrop", 0, 100, 62,
                                 slider = true, noteKey = "theme.backdrop_hint"),
            SettingSpec.IntRange("display.theme.glass.blur_radius", "theme.glass_blur_radius",
                                 0, 40, 32, slider = true, noteKey = "theme.glass_blur_hint"),
            SettingSpec.IntRange("display.pixel_shift_s", "settings.item_pixel_shift", 0, 3600,
                                 300),
        )
        SettingsCategory.CALLS -> listOf(
            SettingSpec.Choice("ui.call_flow", "admin.call_flow",
                               listOf("purpose_first", "ring_then_purpose"), "purpose_first",
                               "settings.call_flow_"),
            SettingSpec.MultiChoice("ui.languages", "admin.visitor_languages", LANGUAGES,
                                    LANGUAGES, "lang."),
            SettingSpec.IntRange("ui.visitor_lang_revert_s", "admin.visitor_language_revert",
                                 0, 3600, 60),
            SettingSpec.IntRange("call.indoor.return_s", "settings.item_cluster_return_s",
                                 5, 600, 60),
            SettingSpec.IntRange("reply.display_ttl_s", "settings.item_reply_ttl", 5, 600, 30),
        )
        SettingsCategory.EMERGENCY -> listOf(
            SettingSpec.IntRange("emergency.trigger.countdown_s", "sos.countdown_s", 0, 10, 3,
                                 slider = true),
            SettingSpec.MultiChoice("emergency.button_on_roles", "sos.button_on_roles", ROLES,
                                    listOf("indoor_panel"), "settings.role_", minSelected = 0),
            SettingSpec.Toggle("emergency.cancel_requires_pin", "sos.cancel_requires_pin", true),
            SettingSpec.Toggle("emergency.web_active_page_alerts", "admin.web_sos_enabled", true),
        )
        SettingsCategory.SIP -> listOf(
            SettingSpec.Text("sip.server", "settings.item_sip_server", TextKind.HOST,
                             noteKey = "settings.item_sip_server_note"),
            SettingSpec.IntRange("sip.port", "admin.port", 1, 65_535, 5060),
            SettingSpec.Choice("sip.transport", "admin.transport", listOf("udp", "tcp", "tls"),
                               "udp", "settings.transport_"),
            SettingSpec.Text("sip.accounts.$NODE.user", "settings.item_sip_user",
                             TextKind.EXTENSION),
            SettingSpec.Choice("sip.accounts.$NODE.answer_mode", "settings.item_answer_mode",
                               listOf("auto", "ring"),
                               if (role == "door_station") "auto" else "ring",
                               "settings.answer_mode_"),
            SettingSpec.IntRange("sip.direct_port", "settings.item_direct_port", 1024, 65_535,
                                 47_190),
        )
        else -> emptyList()
    }

    // ---------- reading the current value ----------

    fun currentString(config: JSONObject?, key: String, default: String): String {
        val value = dig(config, key) ?: return default
        return if (value is String) value else value.toString()
    }

    fun currentInt(config: JSONObject?, key: String, default: Int): Int =
        (dig(config, key) as? Number)?.toInt() ?: default

    fun currentBool(config: JSONObject?, key: String, default: Boolean): Boolean =
        dig(config, key) as? Boolean ?: default

    fun currentList(config: JSONObject?, key: String, default: List<String>): List<String> {
        val array = dig(config, key) as? JSONArray ?: return default
        return (0 until array.length()).map { array.optString(it) }.filter { it.isNotEmpty() }
    }

    fun dig(root: JSONObject?, dotted: String): Any? {
        var current: Any? = root ?: return null
        for (part in dotted.split('.')) {
            current = (current as? JSONObject)?.opt(part) ?: return null
            if (current == JSONObject.NULL) return null
        }
        return current
    }

    // ---------- encoding a new value ----------

    /** JSON for a toggle. */
    fun encodeBool(value: Boolean): String = if (value) "true" else "false"

    /** JSON for an integer, or null when it is outside the spec's range. */
    fun encodeInt(spec: SettingSpec.IntRange, raw: String): String? {
        val value = raw.trim().toIntOrNull() ?: return null
        return if (value in spec.min..spec.max) value.toString() else null
    }

    fun encodeChoice(spec: SettingSpec.Choice, option: String): String? {
        if (option !in spec.options) return null
        return if (spec.numeric) option else JSONObject.quote(option)
    }

    /** JSON array in the spec's option order, or null when too few are selected. */
    fun encodeMulti(spec: SettingSpec.MultiChoice, selected: Collection<String>): String? {
        val ordered = spec.options.filter { it in selected }
        if (ordered.size < spec.minSelected) return null
        return JSONArray(ordered).toString()
    }

    fun encodeTime(raw: String): String? =
        normalizeTime(raw)?.let { JSONObject.quote(it) }

    fun encodeText(kind: TextKind, raw: String): String? {
        val value = raw.trim()
        val ok = when (kind) {
            TextKind.HOST -> value.isEmpty() || validHost(value)
            TextKind.EXTENSION -> value.isEmpty() || EXTENSION.matches(value)
            TextKind.UNLOCK_COMMAND -> value.isEmpty() || UNLOCK_COMMAND.matches(value)
            TextKind.LABEL -> value.length <= MAX_LABEL
        }
        return if (ok) JSONObject.quote(value) else null
    }

    /** "H:MM" or "HH:MM" with a valid hour and minute, normalised to "HH:MM". */
    fun normalizeTime(raw: String): String? {
        val match = TIME.matchEntire(raw.trim()) ?: return null
        val hour = match.groupValues[1].toInt()
        val minute = match.groupValues[2].toInt()
        if (hour > 23 || minute > 59) return null
        return "%02d:%02d".format(hour, minute)
    }

    fun validHost(value: String): Boolean {
        if (value.length > 253 || value.isEmpty()) return false
        if (value.contains(':')) return IPV6.matches(value)
        return value.split('.').all { HOST_LABEL.matches(it) }
    }

    // ---------- structured editors ----------

    /** The three label leaves for a door; blank languages are deleted so they fall back. */
    fun doorLabelOps(door: String, labels: Map<String, String>): List<ConfigOp> =
        LANGUAGES.map { lang ->
            val text = labels[lang].orEmpty().trim().take(MAX_LABEL)
            val key = "doors.$door.label.$lang"
            if (text.isEmpty()) ConfigOp.Delete(key) else ConfigOp.Set(key, JSONObject.quote(text))
        }

    /** A quick reply document as Core stores it; null when every label is blank. */
    fun quickReplyJson(labels: Map<String, String>, speak: Boolean, order: Int): String? {
        val label = JSONObject()
        for (lang in LANGUAGES) {
            val text = labels[lang].orEmpty().trim().take(MAX_LABEL)
            if (text.isNotEmpty()) label.put(lang, text)
        }
        if (label.length() == 0) return null
        return JSONObject().put("label", label).put("speak", speak).put("order", order).toString()
    }

    /** A fresh quick-reply id that does not collide with [existing]. */
    fun nextQuickReplyId(existing: Collection<String>, seed: Long): String {
        var n = seed and 0xFFFFFF
        while (true) {
            val id = "qr_%06x".format(n)
            if (id !in existing) return id
            n = (n + 1) and 0xFFFFFF
        }
    }

    /** Order after the last existing reply, in steps of ten. */
    fun nextQuickReplyOrder(replies: JSONObject?): Int {
        var max = 0
        replies?.keys()?.forEach { id ->
            max = maxOf(max, replies.optJSONObject(id)?.optInt("order", 0) ?: 0)
        }
        return max + 10
    }

    /** notify.quiet_hours as one object; null clears it. */
    fun quietHoursJson(from: String, to: String): String? {
        val start = normalizeTime(from) ?: return null
        val end = normalizeTime(to) ?: return null
        return JSONObject().put("from", start).put("to", end).toString()
    }

    /**
     * Two panes like Android Settings on tablets: at least 600 dp in the smallest width, or a
     * small tablet (smallest width 480 dp and up) held in landscape at least 720 dp wide. A phone
     * held sideways stays single-pane: its smallest width is well below 480 dp.
     */
    fun twoPane(smallestWidthDp: Int, widthDp: Int, landscape: Boolean): Boolean =
        smallestWidthDp >= 600 || (landscape && smallestWidthDp >= 480 && widthDp >= 720)

    /** Security v3: new administrator passwords are 8..128 characters. */
    fun checkNewPassword(next: String, confirm: String): PasswordCheck = when {
        next.length < MIN_PASSWORD -> PasswordCheck.TOO_SHORT
        next.length > MAX_PASSWORD -> PasswordCheck.TOO_LONG
        next != confirm -> PasswordCheck.MISMATCH
        else -> PasswordCheck.OK
    }

    const val MIN_PASSWORD = 8
    const val MAX_PASSWORD = 128
    const val MAX_LABEL = 64
    private val TIME = Regex("^(\\d{1,2}):(\\d{2})$")
    private val EXTENSION = Regex("^[A-Za-z0-9_.+-]{1,32}$")
    private val UNLOCK_COMMAND = Regex("^[A-Za-z0-9_-]{1,32}$")
    private val HOST_LABEL = Regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
    private val IPV6 = Regex("^[0-9A-Fa-f:]{2,39}$")
}

/** One operation of a configuration batch. */
internal sealed class ConfigOp {
    abstract val key: String
    data class Set(override val key: String, val valueJson: String) : ConfigOp()
    data class Delete(override val key: String) : ConfigOp()
}

/** Settings search (guidelines "Settings": category list with search). */
internal object SettingsSearch {
    fun normalize(query: String): String = query.trim().lowercase(java.util.Locale.ROOT)

    /** Case-insensitive substring match against any of [labels]; an empty query matches. */
    fun matches(query: String, labels: List<String>): Boolean {
        val needle = normalize(query)
        if (needle.isEmpty()) return true
        return labels.any { it.lowercase(java.util.Locale.ROOT).contains(needle) }
    }

    fun filter(query: String, labelsOf: (SettingsCategory) -> List<String>): List<SettingsCategory> =
        if (normalize(query).isEmpty()) SettingsCategory.values().toList()
        else SettingsCategory.values().filter { matches(query, labelsOf(it)) }
}
