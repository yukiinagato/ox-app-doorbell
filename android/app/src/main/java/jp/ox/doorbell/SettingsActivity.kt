// Native settings (spec §3): the device-level and common cluster settings, always behind the
// 管理パスワード. Every write goes through the same configuration keys and the same server-side
// validation the web admin uses; everything deliberately left to the web admin says so in place
// and links to the administration page rather than silently disappearing.
package jp.ox.doorbell

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import java.util.Locale
import java.util.TimeZone
import org.json.JSONArray
import org.json.JSONObject

class SettingsActivity : Activity(), DoorbellCore.Listener {

    private val ui = Handler(Looper.getMainLooper())
    private lateinit var app: App
    private lateinit var texts: Texts
    private lateinit var clock: ClusterClock
    private lateinit var palette: Palette
    private lateinit var listView: LinearLayout

    private var config: JSONObject? = null
    private var status: JSONObject? = null
    private var nodeId = ""
    private var session: AdminSession? = null

    /** Set when the operator unlocked locally because the administration API was unreachable. */
    private var readOnly = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        texts = Texts(this)
        clock = ClusterClock(app.core)
        session = pendingSession
        readOnly = pendingSession == null
        pendingSession = null
        refreshSnapshots()
        texts.setConfig(config)
        texts.setLang(app.boot.uiLang)
        palette = resolvePalette()
        setContentView(buildShell())
        render()
    }

    override fun onResume() {
        super.onResume()
        app.bindForeground(this)
        refreshSnapshots()
        render()
    }

    override fun onPause() {
        app.unbindForeground(this)
        super.onPause()
    }

    override fun onDestroy() {
        session = null
        super.onDestroy()
    }

    override fun onUiEvent(ev: JSONObject) {
        when (ev.optString("t")) {
            "config_changed", "peers_changed", "notice_changed", "time_changed",
            "power_changed",
            -> ui.post {
                if (isFinishing) return@post
                refreshSnapshots()
                texts.setConfig(config)
                render()
            }
        }
    }

    override fun onTts(text: String, lang: String) {}

    private fun refreshSnapshots() {
        config = if (app.coreOk) app.core.config() else null
        status = if (app.coreOk) app.core.status() else null
        nodeId = status?.optJSONObject("node")?.optString("id").orEmpty()
    }

    private fun resolvePalette(): Palette =
        Appearance.resolve(config, nodeId, systemDarkMode(this), clock.now().minuteOfDay())

    private fun buildShell(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(ShellUi.opaque(palette.ground))
            val pad = ShellUi.dp(this@SettingsActivity, 16)
            setPadding(pad, pad, pad, pad)
        }
        root.addView(
            ShellUi.text(this, texts.t("settings.title", R.string.settings_title), 22f,
                         palette.ink, bold = true),
            ShellUi.matchWrap(),
        )
        listView = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(
            ScrollView(this).apply {
                isFillViewport = true
                addView(listView, LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                ))
            },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f),
        )
        root.addView(
            ShellUi.button(this, texts.t("admin.menu_close", R.string.admin_menu_close),
                           palette) { finish() },
            ShellUi.matchWrap().apply { topMargin = ShellUi.dp(this@SettingsActivity, 8) },
        )
        return root
    }

    private fun render() {
        listView.removeAllViews()
        if (readOnly) listView.addView(
            ShellUi.pill(this, texts.t("settings.offline", R.string.settings_offline),
                         palette.noticeBg, palette.noticeInk, 13f),
            ShellUi.matchWrap(),
        )
        sectionThisDevice()
        sectionVolume()
        sectionTime()
        sectionDoors()
        sectionPurposes()
        sectionRules()
        sectionCluster()
        sectionHistory()
        sectionWebAdmin()
        sectionAbout()
    }

    // ---------- sections ----------

    private fun section(title: String): LinearLayout {
        listView.addView(ShellUi.sectionHeading(this, palette, title), ShellUi.matchWrap())
        val card = ShellUi.card(this, palette)
        listView.addView(card, ShellUi.matchWrap())
        return card
    }

    private fun LinearLayout.row(view: View) {
        addView(view, ShellUi.matchWrap().apply {
            topMargin = if (childCount == 0) 0 else ShellUi.dp(this@SettingsActivity, 6)
        })
    }

    private fun sectionThisDevice() {
        val card = section(texts.t("settings.this_device", R.string.settings_this_device))
        card.row(ShellUi.row(
            this, palette,
            texts.t("settings.device_name", R.string.settings_device_name),
            app.boot.name,
        ) { startActivity(BootSetupActivity.reentryIntent(this)) })
        card.row(ShellUi.row(
            this, palette,
            texts.t("settings.role", R.string.settings_role),
            roleLabel(app.boot.role),
            texts.t("settings.restart_required", R.string.settings_restart_required),
        ) { startActivity(BootSetupActivity.reentryIntent(this)) })
        if (app.boot.role == "door_station") card.row(ShellUi.row(
            this, palette,
            texts.t("settings.door", R.string.settings_door),
            doorLabel(app.boot.door),
        ) { startActivity(BootSetupActivity.reentryIntent(this)) })

        card.row(choiceRow(
            texts.t("settings.ui_lang", R.string.settings_ui_lang),
            "devices.$nodeId.local.ui_lang",
            listOf("ja", "en", "zh"),
            { Texts.langDisplayName(it) },
            currentString("devices.$nodeId.local.ui_lang", app.boot.uiLang),
        ))
        card.row(choiceRow(
            texts.t("settings.video_playback", R.string.settings_video_playback),
            "devices.$nodeId.local.video.playback",
            listOf("auto", "h264", "mjpeg"),
            { it },
            currentString("devices.$nodeId.local.video.playback", "auto"),
        ))
        card.row(choiceRow(
            texts.t("settings.video_rotation", R.string.settings_video_rotation),
            "devices.$nodeId.local.video.rotation",
            listOf("0", "90", "180", "270"),
            { "$it°" },
            currentString("devices.$nodeId.local.video.rotation", "0"),
            asNumber = true,
        ))
        card.row(choiceRow(
            texts.t("settings.helper_mode", R.string.settings_helper_mode),
            "devices.$nodeId.local.recovery.helper_mode",
            listOf("off", "auto", "on"),
            { it },
            currentString("devices.$nodeId.local.recovery.helper_mode", "auto"),
        ))

        // Appearance: light and dark on every UI, with the schedule shown in place.
        val schedule = app.core.dig(config, "display.appearance_schedule") as? JSONObject
        val darkFrom = schedule?.optString("dark_from").orEmpty().ifEmpty { "19:00" }
        val lightFrom = schedule?.optString("light_from").orEmpty().ifEmpty { "06:30" }
        card.row(choiceRow(
            texts.t("settings.appearance", R.string.settings_appearance),
            "devices.$nodeId.local.display.appearance",
            listOf("auto_system", "auto_schedule", "light", "dark"),
            { appearanceLabel(it) },
            currentString(
                "devices.$nodeId.local.display.appearance",
                currentString("display.appearance", "auto_system"),
            ),
            note = texts.t("settings.appearance_range", R.string.settings_appearance_range,
                           darkFrom, lightFrom),
        ))
        card.row(colourRow(
            texts.t("settings.background_color", R.string.settings_background_color),
            "display.theme.bg_color",
            currentString("display.theme.bg_color", "#10151B"),
        ))
        card.row(webOnlyRow(
            texts.t("settings.background_image", R.string.settings_background_image),
            texts.t("settings.web_only_upload", R.string.settings_web_only_upload),
        ))
        if (app.boot.kiosk) card.row(ShellUi.row(
            this, palette,
            texts.t("admin.menu_exit_kiosk", R.string.admin_menu_exit_kiosk),
        ) {
            app.runtime.kioskController.leaveForMaintenance(this)
            finish()
        })
    }

    private fun sectionVolume() {
        val card = section(texts.t("volume.title", R.string.volume_title))
        val effective = if (app.coreOk) app.core.audio(nodeId) else null
        for ((level, titleKey, titleRes) in listOf(
            Triple("call", "volume.call", R.string.volume_call),
            Triple("sos", "volume.sos", R.string.volume_sos),
            Triple("idle", "volume.idle", R.string.volume_idle),
        )) {
            val deviceKey = "devices.$nodeId.local.audio.volume.$level"
            val inherited = app.core.dig(config, deviceKey) == null
            val value = (effective?.optInt(level, -1) ?: -1).takeIf { it >= 0 }
                ?: defaultVolume(level)
            card.row(volumeRow(texts.t(titleKey, titleRes), deviceKey, value, inherited, level))
        }
        card.row(ShellUi.text(
            this, texts.t("volume.hint", R.string.volume_hint), 12.5f, palette.muted,
        ))
    }

    private fun sectionTime() {
        val card = section(texts.t("time.title", R.string.time_title))
        val timeStatus = status?.optJSONObject("time")
        card.row(timeZoneRow(currentString("time.zone", "Asia/Tokyo")))
        card.row(toggleRow(
            texts.t("time.ntp_enabled", R.string.time_ntp_enabled),
            "time.ntp.enabled",
            (app.core.dig(config, "time.ntp.enabled") as? Boolean) ?: false,
            texts.t("time.ntp_hint", R.string.time_ntp_hint),
        ))
        card.row(listRow(
            texts.t("time.servers", R.string.time_servers),
            "time.ntp.servers",
            (app.core.dig(config, "time.ntp.servers") as? JSONArray),
            texts.t("time.servers_hint", R.string.time_servers_hint),
        ))
        card.row(numberRow(
            texts.t("time.interval_s", R.string.time_interval_s),
            "time.ntp.interval_s",
            (app.core.dig(config, "time.ntp.interval_s") as? Number)?.toInt() ?: 900,
            60, 86400,
        ))
        val now = clock.now()
        val source = if (timeStatus?.optString("source") == "ntp")
            texts.t("time.source_ntp", R.string.time_source_ntp)
        else texts.t("time.source_system", R.string.time_source_system)
        val lastSync = timeStatus?.optLong("last_sync_ms", 0L) ?: 0L
        val detail = buildString {
            append(texts.t("time.source", R.string.time_source)).append(": ").append(source)
            append(" · ").append(texts.t("time.local_now", R.string.time_local_now)).append(' ')
            append(now.clockText())
            append(" · ").append(texts.t("time.offset", R.string.time_offset)).append(' ')
            append(timeStatus?.optLong("offset_ms", 0L) ?: 0L).append(" ms")
            append(" · ").append(texts.t("time.last_sync", R.string.time_last_sync)).append(' ')
            append(
                if (lastSync <= 0L) texts.t("time.never", R.string.time_never)
                else clock.format(lastSync).clockText(),
            )
        }
        card.row(ShellUi.row(this, palette,
                             texts.t("time.status", R.string.time_status), detail))
        card.row(ShellUi.button(
            this, texts.t("time.sync_now", R.string.time_sync_now), palette,
        ) {
            Thread({
                val started = app.core.timeSyncNow()
                ui.post {
                    toast(
                        if (started) texts.t("time.sync_started", R.string.time_sync_started)
                        else texts.t("time.sync_failed", R.string.time_sync_failed),
                    )
                }
            }, "doorbell-time-sync").apply { isDaemon = true }.start()
        })
    }

    private fun sectionDoors() {
        val card = section(texts.t("settings.doors", R.string.settings_doors))
        val doors = doorIds()
        if (doors.isEmpty()) {
            card.row(ShellUi.text(this, texts.t("dash.no_doors", R.string.dash_no_doors), 14f,
                                  palette.muted))
            return
        }
        val nowMs = clock.now().wallMs
        for (door in doors) {
            val notice = NoticeModel.effective(config, door, nowMs)
            val value = notice?.text ?: texts.t("notice.none", R.string.notice_none)
            card.row(ShellUi.row(this, palette, doorLabel(door), value) {
                NoticeDialog.show(this, app, texts, palette, door, doors, ::doorLabel) {
                    refreshSnapshots()
                    render()
                }
            })
            card.row(toggleRow(
                texts.t("settings.unlock_button", R.string.settings_unlock_button),
                "doors.$door.unlock.show_button",
                unlockButtonVisible(config, door),
            ))
        }
        card.row(webOnlyRow(
            texts.t("admin.doors", R.string.admin_doors),
            texts.t("settings.web_only_text", R.string.settings_web_only_text),
        ))
    }

    private fun sectionPurposes() {
        val card = section(texts.t("settings.purposes", R.string.settings_purposes))
        val purposes = app.core.dig(config, "visit_purposes") as? JSONObject
        if (purposes == null || purposes.length() == 0) {
            card.row(ShellUi.text(this, texts.t("info.no_data", R.string.info_no_data), 14f,
                                  palette.muted))
        } else {
            for (id in sortedByOrder(purposes)) {
                val entry = purposes.optJSONObject(id)
                val enabled = entry?.optBoolean("enabled", true) ?: true
                card.row(toggleRow(purposeLabel(id), "visit_purposes.$id.enabled", enabled))
            }
        }
        card.row(webOnlyRow(
            texts.t("admin.quick_replies", R.string.admin_quick_replies),
            texts.t("settings.web_only_text", R.string.settings_web_only_text),
        ))
    }

    private fun sectionRules() {
        val card = section(texts.t("settings.rules", R.string.settings_rules))
        val rules = app.core.dig(config, "rules") as? JSONObject
        if (rules != null) {
            for (id in sortedByOrder(rules)) {
                val rule = rules.optJSONObject(id)
                val name = rule?.optString("name").orEmpty().ifEmpty { id }
                card.row(toggleRow(
                    name, "rules.$id.enabled", rule?.optBoolean("enabled", true) ?: true,
                    ruleSummary(rule),
                ))
            }
        }
        val quiet = app.core.dig(config, "notify.quiet_hours") as? JSONObject
        card.row(ShellUi.row(
            this, palette,
            texts.t("settings.quiet_hours", R.string.settings_quiet_hours),
            if (quiet == null) texts.t("settings.value_unset", R.string.settings_value_unset)
            else "${quiet.optString("from")} – ${quiet.optString("to")}",
            texts.t("settings.web_only", R.string.settings_web_only),
        ) { openAdminPage() })
        for ((label, key) in listOf(
            "Telegram" to "notify.telegram.token_ref",
            "Web Push" to "notify.web_push.vapid_public",
        )) {
            val configured = app.core.dig(config, key)?.toString().orEmpty().isNotEmpty()
            card.row(ShellUi.row(
                this, palette, label,
                if (configured) texts.t("admin.configured", R.string.admin_configured)
                else texts.t("settings.value_unset", R.string.settings_value_unset),
                texts.t("settings.web_only_secrets", R.string.settings_web_only_secrets),
            ) { openAdminPage() })
        }
        card.row(webOnlyRow(
            texts.t("admin.rules", R.string.admin_rules),
            texts.t("settings.web_only_rule_actions", R.string.settings_web_only_rule_actions),
        ))
    }

    private fun sectionCluster() {
        val card = section(texts.t("settings.cluster", R.string.settings_cluster))
        card.row(ShellUi.row(
            this, palette, texts.t("pair.panel_title", R.string.pair_panel_title),
        ) {
            if (app.pairingReady()) AddDeviceActivity.launch(this)
            else {
                app.resumePairingSetup()
                PairingActivity.launch(this)
            }
        })
        val peers = status?.optJSONArray("peers")
        if (peers != null) {
            for (index in 0 until peers.length()) {
                val peer = peers.optJSONObject(index) ?: continue
                val name = peer.optString("name").ifEmpty { peer.optString("id") }
                val power = peer.optJSONObject("power")
                val battery = power?.optInt("battery_pct", -1) ?: -1
                val detail = ShellUi.versionLine(
                    roleLabel(peer.optString("role")),
                    peer.optString("version").ifEmpty { "-" },
                    peer.optString("app_version").ifEmpty { appVersion() },
                    battery,
                    power?.optBoolean("charging", false) ?: false,
                ) { texts.t("power.percent", R.string.power_percent, it.toString()) }
                card.row(ShellUi.row(this, palette, name, detail))
            }
        }
        card.row(ShellUi.row(
            this, palette, texts.t("pair.clear_title", R.string.pair_clear_title),
            note = texts.t("pair.clear_confirm", R.string.pair_clear_confirm),
        ) { confirmUnpair() })
    }

    private fun sectionHistory() {
        val card = section(texts.t("history.title", R.string.history_title))
        card.row(ShellUi.row(
            this, palette, texts.t("dash.see_all", R.string.dash_see_all),
        ) { HistoryActivity.launch(this, app.boot.door) })
    }

    private fun sectionWebAdmin() {
        listView.addView(
            ShellUi.sectionHeading(this, palette,
                                   texts.t("web_admin.open", R.string.web_admin_open)),
            ShellUi.matchWrap(),
        )
        val card = ShellUi.card(this, palette)
        card.addView(
            AdminLinks.view(
                this, palette, app.core, AdminLinks.resolve(status, app.boot.httpPort),
                texts.t("web_admin.scan_hint", R.string.web_admin_scan_hint), 96,
            ),
            ShellUi.matchWrap(),
        )
        listView.addView(card, ShellUi.matchWrap())
    }

    private fun sectionAbout() {
        val card = section(texts.t("settings.about", R.string.settings_about))
        val power = status?.optJSONObject("self")?.optJSONObject("power")
        card.row(ShellUi.row(
            this, palette, texts.t("info.version", R.string.info_version),
            ShellUi.versionLine(
                app.boot.name,
                status?.optJSONObject("node")?.optString("version").orEmpty().ifEmpty {
                    app.core.version()
                },
                appVersion(),
                power?.optInt("battery_pct", -1) ?: -1,
                power?.optBoolean("charging", false) ?: false,
            ) { texts.t("power.percent", R.string.power_percent, it.toString()) },
        ))
        card.row(ShellUi.row(
            this, palette, texts.t("info.title", R.string.info_title),
        ) { DeviceInfoActivity.launch(this) })
    }

    // ---------- row builders ----------

    private fun webOnlyRow(title: String, reason: String): View =
        ShellUi.row(this, palette, title, note = reason) { openAdminPage() }

    private fun toggleRow(
        title: String,
        key: String,
        value: Boolean,
        note: String = "",
    ): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ShellUi.dp(this@SettingsActivity, ShellUi.TOUCH_FLOOR_DP)
            background = ShellUi.rounded(this@SettingsActivity, palette.surface,
                                         ShellUi.PILL_RADIUS_DP, palette.line)
            val padH = ShellUi.dp(this@SettingsActivity, ShellUi.PILL_PADDING_H_DP)
            setPadding(padH, ShellUi.dp(this@SettingsActivity, 8), padH,
                       ShellUi.dp(this@SettingsActivity, 8))
        }
        val labels = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        labels.addView(ShellUi.text(this, title, 15f, palette.ink))
        if (note.isNotEmpty())
            labels.addView(ShellUi.text(this, note, 12.5f, palette.muted))
        row.addView(labels, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
        ))
        // A framework Switch keeps D-pad focus without pulling in a support library.
        val toggle = android.widget.Switch(this).apply {
            isChecked = value
            isFocusable = true
            isEnabled = !readOnly
            minimumHeight = ShellUi.dp(this@SettingsActivity, ShellUi.TOUCH_FLOOR_DP)
        }
        toggle.setOnCheckedChangeListener { _, checked ->
            write(key, if (checked) "true" else "false") { ok ->
                if (!ok) toggle.isChecked = !checked
            }
        }
        row.addView(toggle)
        return row
    }

    private fun choiceRow(
        title: String,
        key: String,
        options: List<String>,
        label: (String) -> String,
        current: String,
        note: String = "",
        asNumber: Boolean = false,
    ): View = ShellUi.row(
        this, palette, title, label(current), note, enabled = !readOnly,
    ) {
        AlertDialog.Builder(this)
            .setTitle(title)
            .setItems(options.map { label(it) as CharSequence }.toTypedArray()) { _, which ->
                val chosen = options[which]
                write(key, if (asNumber) chosen else JSONObject.quote(chosen)) { }
            }
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
            .show()
    }

    private fun numberRow(title: String, key: String, current: Int, min: Int, max: Int): View =
        ShellUi.row(this, palette, title, current.toString(), enabled = !readOnly) {
            val field = EditText(this).apply {
                inputType = InputType.TYPE_CLASS_NUMBER
                setText(current.toString())
            }
            AlertDialog.Builder(this)
                .setTitle(title)
                .setView(field)
                .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                    val value = field.text.toString().toIntOrNull()
                    if (value == null || value < min || value > max) {
                        toast(texts.t("admin.save_failed", R.string.admin_save_failed))
                        return@setPositiveButton
                    }
                    write(key, value.toString()) { }
                }
                .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
                .show()
        }

    private fun listRow(title: String, key: String, current: JSONArray?, note: String): View {
        val values = ArrayList<String>()
        if (current != null) for (index in 0 until current.length()) {
            val value = current.optString(index)
            if (value.isNotEmpty()) values.add(value)
        }
        return ShellUi.row(
            this, palette, title, values.joinToString(", "), note, enabled = !readOnly,
        ) {
            val field = EditText(this).apply {
                setSingleLine(false)
                minLines = 2
                setText(values.joinToString("\n"))
            }
            AlertDialog.Builder(this)
                .setTitle(title)
                .setView(field)
                .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                    val entries = field.text.toString().split("\n")
                        .map { it.trim() }.filter { it.isNotEmpty() }
                    if (entries.isEmpty() || entries.size > 4) {
                        toast(texts.t("time.invalid_servers", R.string.time_invalid_servers))
                        return@setPositiveButton
                    }
                    write(key, JSONArray(entries).toString()) { }
                }
                .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
                .show()
        }
    }

    /** A searchable IANA time-zone list; deliberately a list, never a spinner wheel. */
    private fun timeZoneRow(current: String): View = ShellUi.row(
        this, palette, texts.t("time.zone", R.string.time_zone), current,
        texts.t("time.zone_hint", R.string.time_zone_hint), enabled = !readOnly,
    ) {
        val zones = TimeZone.getAvailableIDs()
            .filter { it.contains('/') && !it.startsWith("SystemV") }
            .sorted()
        val container = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val search = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT
            hint = texts.t("time.zone", R.string.time_zone)
        }
        val results = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        container.addView(search, ShellUi.matchWrap())
        container.addView(
            ScrollView(this).apply { addView(results) },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ShellUi.dp(this@SettingsActivity, 280),
            ),
        )
        val dialog = AlertDialog.Builder(this)
            .setTitle(texts.t("time.zone", R.string.time_zone))
            .setView(container)
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
            .create()
        fun fill(query: String) {
            results.removeAllViews()
            val filtered = zones.filter { it.contains(query, ignoreCase = true) }.take(60)
            for (zone in filtered) results.addView(
                ShellUi.row(this, palette, zone) {
                    dialog.dismiss()
                    write("time.zone", JSONObject.quote(zone)) { }
                },
                ShellUi.matchWrap().apply { topMargin = ShellUi.dp(this@SettingsActivity, 4) },
            )
        }
        search.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) { fill(s?.toString().orEmpty()) }
        })
        fill(current.substringBefore('/'))
        dialog.show()
    }

    private fun volumeRow(
        title: String,
        deviceKey: String,
        value: Int,
        inherited: Boolean,
        level: String,
    ): View {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = ShellUi.rounded(this@SettingsActivity, palette.surface,
                                         ShellUi.PILL_RADIUS_DP, palette.line)
            val padH = ShellUi.dp(this@SettingsActivity, ShellUi.PILL_PADDING_H_DP)
            setPadding(padH, ShellUi.dp(this@SettingsActivity, 8), padH,
                       ShellUi.dp(this@SettingsActivity, 8))
        }
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val readout = ShellUi.text(this, value.toString(), 15f, palette.muted)
        header.addView(ShellUi.text(this, title, 15f, palette.ink),
                       LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        header.addView(readout)
        box.addView(header, ShellUi.matchWrap())

        val bar = SeekBar(this).apply {
            max = 100
            progress = value.coerceIn(0, 100)
            isFocusable = true
            isEnabled = !readOnly
            minimumHeight = ShellUi.dp(this@SettingsActivity, ShellUi.TOUCH_FLOOR_DP)
        }
        bar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                readout.text = progress.toString()
            }
            override fun onStartTrackingTouch(seekBar: SeekBar) {}
            override fun onStopTrackingTouch(seekBar: SeekBar) {
                write(deviceKey, seekBar.progress.toString()) { }
            }
        })
        box.addView(bar, ShellUi.matchWrap())

        val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val inheritToggle = android.widget.Switch(this).apply {
            text = texts.t("volume.inherit", R.string.volume_inherit)
            isChecked = inherited
            isFocusable = true
            isEnabled = !readOnly
            minimumHeight = ShellUi.dp(this@SettingsActivity, ShellUi.TOUCH_FLOOR_DP)
        }
        inheritToggle.setOnCheckedChangeListener { _, checked ->
            if (checked) deleteKey(deviceKey) else write(deviceKey, bar.progress.toString()) { }
        }
        actions.addView(inheritToggle, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
        ))
        actions.addView(ShellUi.button(
            this, texts.t("volume.preview", R.string.volume_preview), palette,
        ) { previewVolume(level, bar.progress) })
        box.addView(actions, ShellUi.matchWrap())
        return box
    }

    /**
     * A colour field never rejects the operator's value; it saves and shows the advisory WCAG
     * warning next to it when the contrast falls short (§5.2).
     */
    private fun colourRow(title: String, key: String, current: String): View {
        val warning = contrastWarning(current)
        return ShellUi.row(this, palette, title, current, warning, enabled = !readOnly) {
            val field = EditText(this).apply {
                inputType = InputType.TYPE_CLASS_TEXT
                setText(current)
            }
            val advice = ShellUi.text(this, warning, 12.5f, palette.noticeInk)
            val container = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                val pad = ShellUi.dp(this@SettingsActivity, 16)
                setPadding(pad, ShellUi.dp(this@SettingsActivity, 8), pad, 0)
                addView(field, ShellUi.matchWrap())
                addView(advice, ShellUi.matchWrap())
            }
            field.addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    advice.text = contrastWarning(s?.toString().orEmpty())
                }
            })
            AlertDialog.Builder(this)
                .setTitle(title)
                .setView(container)
                .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                    val value = field.text.toString().trim()
                    if (UiContrast.parseRgb(value) == null) {
                        toast(texts.t("admin.save_failed", R.string.admin_save_failed))
                        return@setPositiveButton
                    }
                    write(key, JSONObject.quote(value)) { }
                }
                .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
                .show()
        }
    }

    /** Advisory only: the value is still saved, exactly as the web admin now does. */
    private fun contrastWarning(value: String): String {
        val rgb = UiContrast.parseRgb(value) ?: return ""
        val ink = palette.inkOver(rgb)
        val ratio = UiContrast.contrast(ink, rgb)
        if (ratio >= UiContrast.TEXT_AA) return ""
        return texts.t("settings.contrast_warning", R.string.settings_contrast_warning,
                       UiContrast.ratioText(ratio))
    }

    // ---------- writes ----------

    private fun write(key: String, valueJson: String, done: (Boolean) -> Unit) {
        val active = session
        if (active == null) {
            toast(texts.t("settings.offline", R.string.settings_offline))
            done(false)
            return
        }
        Thread({
            val result = active.setKey(key, valueJson)
            ui.post {
                if (isFinishing) return@post
                if (result.ok) {
                    toast(texts.t("admin.saved", R.string.admin_saved))
                    refreshSnapshots()
                    texts.setConfig(config)
                    render()
                } else {
                    toast(
                        if (result.unauthorized)
                            texts.t("admin.pin_wrong", R.string.admin_pin_wrong)
                        else texts.t("admin.save_failed", R.string.admin_save_failed),
                    )
                }
                done(result.ok)
            }
        }, "doorbell-config-write").apply { isDaemon = true }.start()
    }

    private fun deleteKey(key: String) {
        val active = session ?: run {
            toast(texts.t("settings.offline", R.string.settings_offline))
            return
        }
        Thread({
            val result = active.deleteKey(key)
            ui.post {
                if (isFinishing) return@post
                toast(
                    if (result.ok) texts.t("admin.saved", R.string.admin_saved)
                    else texts.t("admin.save_failed", R.string.admin_save_failed),
                )
                refreshSnapshots()
                render()
            }
        }, "doorbell-config-delete").apply { isDaemon = true }.start()
    }

    // ---------- helpers ----------

    private fun previewVolume(level: String, value: Int) {
        try {
            val manager = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            val stream = when (level) {
                "sos" -> android.media.AudioManager.STREAM_ALARM
                "idle" -> android.media.AudioManager.STREAM_MUSIC
                else -> android.media.AudioManager.STREAM_RING
            }
            val tone = android.media.ToneGenerator(stream, value.coerceIn(0, 100))
            tone.startTone(android.media.ToneGenerator.TONE_PROP_BEEP, 250)
            ui.postDelayed({ try { tone.release() } catch (_: Exception) { } }, 400)
        } catch (_: Exception) { }
    }

    private fun confirmUnpair() {
        AlertDialog.Builder(this)
            .setTitle(texts.t("pair.clear_title", R.string.pair_clear_title))
            .setMessage(texts.t("pair.clear_confirm", R.string.pair_clear_confirm))
            .setPositiveButton(texts.t("admin.delete", R.string.admin_delete)) { _, _ ->
                // Leaving the cluster from the device itself is the same factory reset a
                // revocation performs: key, seeds, and the local identity all go.
                app.factoryResetClusterIdentity("admin_leave")
                finish()
            }
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
            .show()
    }

    private fun openAdminPage() {
        val link = AdminLinks.resolve(status, app.boot.httpPort)
        AlertDialog.Builder(this)
            .setTitle(texts.t("web_admin.open", R.string.web_admin_open))
            .setView(
                AdminLinks.view(
                    this, palette, app.core, link,
                    texts.t("web_admin.scan_hint", R.string.web_admin_scan_hint), 140,
                ).apply {
                    val pad = ShellUi.dp(this@SettingsActivity, 16)
                    setPadding(pad, pad, pad, pad)
                },
            )
            .setPositiveButton(texts.t("admin.menu_close", R.string.admin_menu_close), null)
            .show()
    }

    private fun currentString(key: String, fallback: String): String =
        app.core.dig(config, key)?.toString()?.takeIf { it.isNotEmpty() && it != "null" }
            ?: fallback

    private fun defaultVolume(level: String): Int = when (level) {
        "sos" -> 100
        "idle" -> 60
        else -> 80
    }

    private fun doorIds(): List<String> {
        val doors = app.core.dig(config, "doors") as? JSONObject ?: return emptyList()
        return doors.keys().asSequence().sorted().toList()
    }

    private fun doorLabel(door: String): String {
        if (door.isEmpty()) return ""
        val value = app.core.dig(config, "doors.$door.label.${texts.lang}")
            ?: app.core.dig(config, "doors.$door.label.ja")
        return value?.toString() ?: door
    }

    private fun purposeLabel(purpose: String): String {
        val labels = (app.core.dig(config, "visit_purposes.$purpose") as? JSONObject)
            ?.optJSONObject("label") ?: return purpose
        val value = labels.optString(texts.lang)
        if (value.isNotEmpty()) return value
        return labels.optString("ja").ifEmpty { purpose }
    }

    private fun roleLabel(role: String): String = when (role) {
        "door_station" -> texts.t("pair.role_door_station", R.string.pair_role_door_station)
        "indoor_panel" -> texts.t("pair.role_indoor_panel", R.string.pair_role_indoor_panel)
        else -> role
    }

    private fun appearanceLabel(value: String): String = when (value) {
        "auto_schedule" ->
            texts.t("settings.appearance_schedule", R.string.settings_appearance_schedule)
        "light" -> texts.t("settings.appearance_light", R.string.settings_appearance_light)
        "dark" -> texts.t("settings.appearance_dark", R.string.settings_appearance_dark)
        else -> texts.t("settings.appearance_system", R.string.settings_appearance_system)
    }

    private fun ruleSummary(rule: JSONObject?): String {
        if (rule == null) return ""
        val parts = ArrayList<String>(2)
        rule.optString("when").takeIf { it.isNotEmpty() }?.let(parts::add)
        rule.optJSONArray("actions")?.let { parts.add("${it.length()}") }
        return parts.joinToString(" · ")
    }

    private fun sortedByOrder(value: JSONObject): List<String> {
        val ids = value.keys().asSequence().toMutableList()
        ids.sortWith(compareBy({ value.optJSONObject(it)?.optInt("order", 999) ?: 999 }, { it }))
        return ids
    }

    private fun appVersion(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName.orEmpty()
    } catch (_: Exception) {
        ""
    }

    private fun toast(message: String) {
        android.widget.Toast.makeText(this, message, android.widget.Toast.LENGTH_SHORT).show()
    }

    companion object {
        /**
         * Handed over by [AdminGate] rather than serialised through the intent, so the session
         * token never leaves the process.
         */
        private var pendingSession: AdminSession? = null

        /** Open settings behind the 管理パスワード, from either entry point. */
        fun open(activity: Activity, app: App, texts: Texts) {
            AdminGate.unlock(activity, app.boot.httpPort, texts) { session ->
                pendingSession = session
                try {
                    activity.startActivity(Intent(activity, SettingsActivity::class.java))
                } catch (_: Exception) {
                    pendingSession = null
                }
            }
        }

        /** doors.<id>.unlock.show_button, defaulting to true only when an action is configured. */
        fun unlockButtonVisible(config: JSONObject?, door: String): Boolean {
            val entry = config?.optJSONObject("doors")?.optJSONObject(door)
            val unlock = entry?.optJSONObject("unlock")
            if (unlock != null && unlock.has("show_button"))
                return unlock.optBoolean("show_button", false)
            return unlockConfigured(config, door)
        }

        /** Whether the door has any unlock action wired up at all. */
        fun unlockConfigured(config: JSONObject?, door: String): Boolean {
            val unlock = config?.optJSONObject("doors")?.optJSONObject(door)
                ?.optJSONObject("unlock") ?: return false
            for (key in listOf("action", "relay", "dtmf", "url", "gpio"))
                if (unlock.optString(key).isNotEmpty()) return true
            return false
        }
    }
}
