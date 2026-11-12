// Settings the web Admin offers that the native screen lacked: the door station's camera and
// motion, cluster volume defaults, the cluster appearance and its schedule, the idle screen,
// the wallpaper's dimming layer, text-colour overrides, per-element UI overrides, cluster
// rebuild and the raw key editor.
//
// Every row writes one configuration leaf, never a whole object: Core's materialization lets a
// leaf mask an object member regardless of age, so an object write could be silently undone by
// an older leaf.
package jp.ox.doorbell

import android.text.InputType
import android.widget.LinearLayout
import android.widget.ScrollView
import org.json.JSONObject

internal class SettingsParitySections(private val a: SettingsActivity) {

    private fun L(key: String, vararg args: Any): String = a.label(key, *args)
    private val local: String get() = "devices.${a.nodeId}.local"
    private fun add(card: LinearLayout, view: android.view.View) = with(a) { card.row(view) }
    private fun str(key: String, fallback: String): String = a.currentString(key, fallback)
    private fun int(key: String, fallback: Int): Int =
        (SettingsModel.dig(a.config, key) as? Number)?.toInt() ?: fallback
    private fun bool(key: String, fallback: Boolean): Boolean =
        (SettingsModel.dig(a.config, key) as? Boolean) ?: fallback

    private fun choice(title: String, key: String, options: List<Pair<String, String>>,
                       default: String, numeric: Boolean = false) = a.choiceRow(
        title, key, options.map { it.first },
        { value -> options.firstOrNull { it.first == value }?.second ?: value },
        str(key, default), asNumber = numeric,
    )

    // ---------- This device: door-station camera, motion, visitor layout ----------

    /** Shown on a door station only; an indoor panel has no capture pipeline to configure. */
    fun doorStation() {
        if (a.app.boot.role != RoleChangeModel.DOOR_STATION || a.nodeId.isEmpty()) return
        val camera = a.section(L("admin.camera"))
        add(camera, choice(L("settings.cam_codec"), "$local.camera.codec", listOf(
            "auto" to L("admin.codec_auto"), "mjpeg" to L("settings.codec_mjpeg"),
            "h264" to L("settings.codec_h264")), "auto"))
        add(camera, choice(L("settings.cam_resolution"), "$local.camera.resolution",
                           CAMERA_SIZES.map { it to L("settings.res_$it") }, "640x480"))
        add(camera, a.intSliderRow(L("settings.cam_fps"), "$local.camera.mjpeg_fps", 1, 15,
                                   int("$local.camera.mjpeg_fps", 8)))
        add(camera, a.intSliderRow(L("settings.cam_quality"), "$local.camera.mjpeg_quality", 30, 95,
                                   int("$local.camera.mjpeg_quality", 60)))
        add(camera, choice(L("settings.cam_h264_resolution"), "$local.camera.h264_resolution",
                           H264_SIZES.map { it to L("settings.res_$it") }, "640x360"))
        add(camera, choice(L("settings.cam_h264_fps"), "$local.camera.h264_fps",
                           H264_FPS.map { it to L("settings.fps_$it") }, "30", numeric = true))
        add(camera, a.numberRow(L("settings.cam_h264_bitrate"), "$local.camera.h264_bitrate_kbps",
                                int("$local.camera.h264_bitrate_kbps", 700), 200, 4000))
        add(camera, a.textRow(L("settings.cam_hint"), "$local.camera.device_hint", TextKind.LABEL,
                              str("$local.camera.device_hint", ""), ""))

        // An external camera can stand in for the built-in one; none set means built-in.
        val sourceKey = "$local.camera.source_ref"
        val sources = (SettingsModel.dig(a.config, "media_sources") as? JSONObject)
            ?.keys()?.asSequence()?.sorted()?.toList().orEmpty()
        val source = str(sourceKey, "")
        add(camera, ShellUi.row(
            a, a.palette, L("settings.cam_source"),
            source.ifEmpty { L("settings.cam_source_builtin") }, L("settings.cam_source_desc"),
            enabled = !a.readOnly,
        ) {
            val options = listOf("" to L("settings.cam_source_builtin")) + sources.map { it to it }
            ShellDialogBuilder(a)
                .setTitle(L("settings.cam_source"))
                .setItems(options.map { it.second as CharSequence }.toTypedArray()) { _, which ->
                    val picked = options[which].first
                    if (picked.isEmpty()) a.deleteKey(sourceKey)
                    else a.write(sourceKey, JSONObject.quote(picked)) { }
                }
                .setNegativeButton(L("admin.cancel"), null)
                .show()
        })

        val motion = a.section(L("admin.motion"))
        add(motion, a.toggleRow(L("settings.motion_enabled"), "$local.motion.enabled",
                                bool("$local.motion.enabled", true)))
        add(motion, a.intSliderRow(L("settings.motion_sensitivity"), "$local.motion.sensitivity",
                                   1, 100, int("$local.motion.sensitivity", 40)))
        add(motion, a.numberRow(L("settings.motion_interval"), "$local.motion.min_interval_s",
                                int("$local.motion.min_interval_s", 30), 5, 600))

        val layout = a.section(L("settings.visitor_layout"))
        add(layout, choice(L("settings.visitor_layout"), "$local.visitor_layout",
                           VISITOR_LAYOUTS.map { it to L("settings.visitor_layout_$it") },
                           "standard"))
    }

    // ---------- Sound: cluster volume defaults ----------

    fun volumeDefaults() {
        val card = a.section(L("settings.volume_defaults"))
        for ((level, default) in listOf("call" to 80, "sos" to 100, "idle" to 60))
            add(card, a.intSliderRow(L("settings.volume_${level}_default"), "audio.volume.$level",
                                     0, 100, int("audio.volume.$level", default)))
    }

    // ---------- Display: cluster appearance, idle screen, dimming layer, text colours ----------

    fun clusterAppearance() {
        val card = a.section(L("settings.appearance_cluster"))
        add(card, choice(L("theme.appearance"), "display.appearance", listOf(
            "auto_system" to L("theme.appearance_auto_system"),
            "auto_schedule" to L("theme.appearance_auto_schedule"),
            "light" to L("theme.appearance_light"), "dark" to L("theme.appearance_dark"),
        ), "auto_system"))
        for ((leaf, title, default) in listOf(
            Triple("dark_from", "settings.dark_from", "19:00"),
            Triple("light_from", "settings.light_from", "06:30"),
        )) {
            val key = "display.appearance_schedule.$leaf"
            add(card, a.timeRow(L(title), key, str(key, default)) { value ->
                SettingsModel.encodeTime(value)?.let { listOf(ConfigOp.Set(key, it)) }
            })
        }
    }

    fun idleScreen() {
        val card = a.section(L("settings.grp_idle_screen"))
        val root = "display.screensaver"
        add(card, a.toggleRow(L("settings.saver_enabled"), "$root.enabled", bool("$root.enabled", true)))
        add(card, choice(L("settings.saver_mode"), "$root.mode", listOf(
            "dim" to L("prefs.saver_dim"), "minimal" to L("prefs.saver_minimal"),
            "clock" to L("prefs.saver_clock")), "dim"))
        add(card, choice(L("settings.saver_schedule"), "$root.schedule", listOf(
            "always" to L("prefs.saver_always"), "daily" to L("prefs.saver_daily")), "always"))
        for ((leaf, title, default) in listOf(
            Triple("from", "settings.saver_from", "22:00"),
            Triple("to", "settings.saver_to", "06:00"),
        )) {
            val key = "$root.$leaf"
            add(card, a.timeRow(L(title), key, str(key, default)) { value ->
                SettingsModel.encodeTime(value)?.let { listOf(ConfigOp.Set(key, it)) }
            })
        }
        add(card, a.numberRow(L("settings.saver_after"), "$root.after_s", int("$root.after_s", 120),
                              5, 86_400))
        add(card, a.intSliderRow(L("settings.saver_brightness"), "$root.brightness", 1, 100,
                                 int("$root.brightness", 10)))
    }

    fun themeExtras() {
        val card = a.section(L("settings.grp_theme"))
        val backdrop = "display.theme.backdrop"
        add(card, a.toggleRow(L("settings.backdrop"), "$backdrop.enabled",
                              bool("$backdrop.enabled", true)))
        add(card, a.intSliderRow(L("settings.backdrop_opacity"), "$backdrop.opacity", 0, 100,
                                 int("$backdrop.opacity", 62)))
        add(card, a.colourRow(L("settings.backdrop_color"), "$backdrop.color",
                              str("$backdrop.color", "#000000"),
                              note = L("settings.backdrop_color_native")))
        if (a.nodeId.isNotEmpty()) add(card, a.colourRow(
            L("settings.call_button_color"), "$local.theme.call_button_bg",
            str("$local.theme.call_button_bg", ""), note = L("settings.call_button_color_native"),
            clearable = true,
        ))

        val ink = a.section(L("settings.grp_ink"))
        for (region in CoreDisplays.INK_REGIONS) {
            val key = "display.theme.ink_override.$region"
            add(ink, a.colourRow(L("settings.ink_$region"), key, str(key, ""),
                                 note = L("settings.ink_${region}_native"), clearable = true))
        }
    }

    // ---------- This device: per-element UI overrides ----------

    /** One row per semantic ID of the UI manifest; each property is its own leaf. */
    fun uiOverrides() {
        if (a.nodeId.isEmpty()) return
        val card = a.section(L("settings.ui_overrides"))
        for (id in SEMANTIC_IDS) {
            val root = "$local.ui.elements.$id"
            val current = SettingsModel.dig(a.config, root) as? JSONObject
            val summary = current?.keys()?.asSequence()?.sorted()
                ?.joinToString(", ") { "$it=${current.opt(it)}" }.orEmpty()
            add(card, ShellUi.row(a, a.palette, id, summary, enabled = !a.readOnly) {
                editElement(id, root, current)
            })
        }
    }

    private fun editElement(id: String, root: String, current: JSONObject?) {
        val box = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            val pad = ShellUi.dp(a, 24)
            setPadding(pad, ShellUi.dp(a, 8), pad, 0)
        }
        box.addView(ShellUi.label(a, L("settings.ui_overrides_note"), TextRole.SUPPORTING))
        val fields = UiStylePolicy.allProperties.toList().sorted().associateWith { property ->
            val numeric = property in NUMERIC_PROPERTIES
            PlatformUi.field(
                a, property, current?.opt(property)?.toString().orEmpty(),
                if (numeric) InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
                else InputType.TYPE_CLASS_TEXT,
            ).also {
                box.addView(it.view, ShellUi.matchWrap().apply { topMargin = ShellUi.dp(a, 8) })
            }
        }
        ShellDialogBuilder(a)
            .setTitle(id)
            .setView(ScrollView(a).apply { addView(box) })
            .setPositiveButton(L("admin.save")) { _, _ ->
                val ops = ArrayList<ConfigOp>()
                for ((property, field) in fields) {
                    val raw = field.text.trim()
                    val key = "$root.$property"
                    val before = current?.opt(property)?.toString().orEmpty()
                    when {
                        raw == before -> Unit
                        raw.isEmpty() -> ops.add(ConfigOp.Delete(key))
                        property in NUMERIC_PROPERTIES -> {
                            if (raw.toDoubleOrNull() == null) {
                                a.toast(L("settings.invalid_value"))
                                return@setPositiveButton
                            }
                            ops.add(ConfigOp.Set(key, raw))
                        }
                        UiStylePolicy.parseRgb(raw) == null -> {
                            a.toast(L("settings.invalid_value"))
                            return@setPositiveButton
                        }
                        else -> ops.add(ConfigOp.Set(key, JSONObject.quote(raw)))
                    }
                }
                if (ops.isEmpty()) a.toast(L("settings.role_unchanged")) else a.writeOps(ops)
            }
            .setNegativeButton(L("admin.cancel"), null)
            .show()
    }

    // ---------- Cluster: rebuild, raw key editor ----------

    fun advanced() {
        val card = a.section(L("settings.raw_config"))
        add(card, ShellUi.row(a, a.palette, L("settings.raw_config"), note = L("settings.raw_config_desc"),
                              enabled = !a.readOnly) { rawConfig() })
        add(card, a.destructiveRow(L("security.rebuild"), L("security.rebuild_hint")) {
            ShellDialogBuilder(a)
                .setTitle(L("security.rebuild"))
                .setMessage(L("security.rebuild_confirm"))
                .setPositiveButton(L("security.rebuild")) { _, _ -> rebuildCluster() }
                .setNegativeButton(L("admin.cancel"), null)
                .show()
        })
    }

    private fun rebuildCluster() {
        val session = a.adminSession
        if (session == null) {
            a.reauthenticateThen { if (a.adminSession != null) rebuildCluster() }
            return
        }
        a.coreCall({
            val (code, body) = session.request("POST", "/api/pairing/rebuild", JSONObject())
            (body ?: JSONObject()).put("http", code)
        }) { result ->
            val ok = result?.optInt("http") == 200 && result.optString("err").isEmpty()
            a.toast(if (ok) L("security.rebuild_done") else L("admin.save_failed"))
            a.refreshSnapshots()
            a.render()
        }
    }

    /** Read, write or delete one key. Core validates the value; nothing is checked here. */
    private fun rawConfig() {
        val box = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            val pad = ShellUi.dp(a, 24)
            setPadding(pad, ShellUi.dp(a, 8), pad, 0)
        }
        val key = PlatformUi.field(a, L("settings.raw_key"))
        val value = PlatformUi.field(a, L("settings.raw_value"), lines = 3)
        box.addView(key.view, ShellUi.matchWrap())
        box.addView(ShellUi.button(a, L("settings.raw_read"), a.palette) {
            val found = SettingsModel.dig(a.config, key.text.trim())
            if (found == null) a.toast(L("settings.raw_absent"))
            else value.text = if (found is String) JSONObject.quote(found) else found.toString()
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT,
                                     LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = ShellUi.dp(a, 8)
        })
        box.addView(value.view, ShellUi.matchWrap().apply { topMargin = ShellUi.dp(a, 8) })
        fun confirm(message: String, action: String, run: () -> Unit) = ShellDialogBuilder(a)
            .setMessage(message)
            .setPositiveButton(action) { _, _ -> run() }
            .setNegativeButton(L("admin.cancel"), null)
            .show()
        ShellDialogBuilder(a)
            .setTitle(L("settings.raw_config"))
            .setView(ScrollView(a).apply { addView(box) })
            .setPositiveButton(L("settings.raw_write")) { _, _ ->
                val name = key.text.trim()
                val json = value.text.trim()
                if (name.isEmpty() || !validJson(json)) {
                    a.toast(L("settings.raw_invalid_json"))
                    return@setPositiveButton
                }
                confirm(L("settings.raw_write_confirm", name), L("settings.raw_write")) {
                    a.write(name, json) { }
                }
            }
            .setNeutralButton(L("settings.raw_delete")) { _, _ ->
                val name = key.text.trim()
                if (name.isNotEmpty())
                    confirm(L("settings.raw_delete_confirm", name), L("settings.raw_delete")) {
                        a.deleteKey(name)
                    }
            }
            .setNegativeButton(L("admin.cancel"), null)
            .show()
    }

    private fun validJson(text: String): Boolean = try {
        text.isNotEmpty() && JSONObject("{\"v\":$text}").has("v")
    } catch (_: Exception) {
        false
    }

    companion object {
        val CAMERA_SIZES = listOf("320x240", "640x480", "1280x720")
        val H264_SIZES = listOf("640x360", "1280x720")
        val H264_FPS = listOf("15", "24", "30")
        val VISITOR_LAYOUTS = listOf("standard", "left", "right", "edges")
        val NUMERIC_PROPERTIES = setOf("scale", "font_scale", "radius")

        /** The semantic IDs the Android UI manifest advertises. */
        val SEMANTIC_IDS = listOf(
            "call.primary", "cancel.call", "call.end", "purpose.button", "ring.title",
            "ring.action", "reply.button", "monitor.close", "status.offline", "sos.trigger",
            "sos.cancel",
        )
    }
}
