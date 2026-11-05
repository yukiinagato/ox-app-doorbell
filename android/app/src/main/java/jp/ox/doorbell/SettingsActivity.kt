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
    /** The detail pane that every section renders into. */
    private lateinit var listView: LinearLayout
    private lateinit var categoryList: LinearLayout
    private lateinit var categoryScroll: ScrollView
    private lateinit var detailScroll: ScrollView
    private lateinit var backButton: TextView
    private lateinit var titleView: TextView
    private var twoPane = false
    /** The open category; null shows the category list on a phone. */
    private var selected: SettingsCategory? = null

    private var config: JSONObject? = null
    private var status: JSONObject? = null
    private var nodeId = ""
    /** Where writes go: core when it exports them, otherwise the loopback session. */
    private var writer: ConfigWriter? = null

    /** Set when neither core nor a loopback session can write, so the screen is read-only. */
    private var readOnly = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        texts = Texts(this)
        clock = ClusterClock(app.core)
        selected = SettingsCategory.byId(savedInstanceState?.getString(STATE_CATEGORY))
        writer = ConfigWriters.choose(app.core, pendingSession)
        readOnly = writer == null
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

    override fun onStop() {
        // Leaving settings closes the native admin window; returning asks for the password again.
        if (isFinishing) app.core.adminLock()
        super.onStop()
    }

    override fun onDestroy() {
        writer = null
        super.onDestroy()
    }

    /**
     * Core closed the native admin window (timeout or app backgrounding). Ask for the password
     * again, then repeat the write that was refused.
     */
    private fun reauthenticateThen(retry: () -> Unit) {
        AdminGate.unlock(this, app.boot.httpPort, texts) { session ->
            if (session != null) writer = ConfigWriters.choose(app.core, session)
            retry()
        }
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

    private fun resolvePalette(): Palette {
        val appearance = CoreDisplays.parse(status?.optJSONObject("display")).appearance
        if (appearance != null)
            return Appearance.palette(CoreDisplays.isDark(appearance, systemDarkMode(this)))
        return Appearance.resolve(config, nodeId, systemDarkMode(this), clock.now().minuteOfDay())
    }

    // ---------- layout: drill-down on phones, two panes on tablets ----------

    private fun buildShell(): View {
        val configuration = resources.configuration
        twoPane = SettingsModel.twoPane(
            configuration.smallestScreenWidthDp,
            configuration.screenWidthDp,
            configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE,
        )
        if (twoPane && selected == null) selected = SettingsCategory.DEVICE
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(ShellUi.opaque(palette.ground))
        }
        // Toolbar: a back arrow while a phone shows one category, then the screen title.
        val toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ShellUi.dp(this@SettingsActivity, 56)
            val pad = ShellUi.dp(this@SettingsActivity, 8)
            setPadding(pad, 0, ShellUi.dp(this@SettingsActivity, 16), 0)
        }
        backButton = ShellUi.text(this, "\u2039", 30f, palette.ink, bold = true).apply {
            gravity = Gravity.CENTER
            contentDescription = texts.t("settings.back", R.string.settings_back)
            isClickable = true
            isFocusable = true
            setOnClickListener { showCategoryList() }
        }
        toolbar.addView(backButton, LinearLayout.LayoutParams(
            ShellUi.dp(this, ShellUi.TOUCH_FLOOR_DP), ShellUi.dp(this, ShellUi.TOUCH_FLOOR_DP)))
        titleView = ShellUi.text(this, "", 22f, palette.ink, bold = true)
        toolbar.addView(titleView, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        root.addView(toolbar, ShellUi.matchWrap())

        categoryList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        listView = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        categoryScroll = paneScroll(categoryList)
        detailScroll = paneScroll(listView)
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            isBaselineAligned = false
        }
        if (twoPane) {
            // Fixed-width category list, a hairline, and the detail pane, as Android Settings
            // lays out a tablet. Plain views, so legacy19 gets the same layout on API 19.
            body.addView(categoryScroll, LinearLayout.LayoutParams(
                ShellUi.dp(this, CATEGORY_PANE_DP), ViewGroup.LayoutParams.MATCH_PARENT))
            body.addView(View(this).apply { setBackgroundColor(ShellUi.opaque(palette.line)) },
                         LinearLayout.LayoutParams(1, ViewGroup.LayoutParams.MATCH_PARENT))
            body.addView(detailScroll, LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        } else {
            body.addView(categoryScroll, LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
            body.addView(detailScroll, LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        }
        root.addView(body, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        return root
    }

    private fun paneScroll(content: LinearLayout): ScrollView = ScrollView(this).apply {
        isFillViewport = true
        val pad = ShellUi.dp(this@SettingsActivity, 16)
        setPadding(pad, 0, pad, pad)
        clipToPadding = false
        addView(content, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ))
    }

    private fun showCategoryList() {
        if (twoPane) return
        selected = null
        render()
    }

    override fun onBackPressed() {
        // Phones step back from a category to the list before leaving settings.
        if (!twoPane && selected != null) {
            showCategoryList()
            return
        }
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        selected?.let { outState.putString(STATE_CATEGORY, it.id) }
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        // Rotating a tablet can move between one and two panes; the open category survives.
        setContentView(buildShell())
        render()
    }

    private fun render() {
        renderCategoryList()
        val category = selected
        listView.removeAllViews()
        if (readOnly) listView.addView(
            ShellUi.pill(this, texts.t("settings.offline", R.string.settings_offline),
                         palette.noticeBg, palette.noticeInk, 13f),
            ShellUi.matchWrap(),
        )
        if (category != null) renderCategory(category)
        if (!twoPane) {
            categoryScroll.visibility = if (category == null) View.VISIBLE else View.GONE
            detailScroll.visibility = if (category == null) View.GONE else View.VISIBLE
        }
        backButton.visibility =
            if (!twoPane && category != null) View.VISIBLE else View.INVISIBLE
        titleView.text = if (!twoPane && category != null) label(category.titleKey)
            else texts.t("settings.title", R.string.settings_title)
    }

    private fun renderCategoryList() {
        categoryList.removeAllViews()
        for (category in SettingsCategory.values()) {
            val row = ShellUi.row(this, palette, label(category.titleKey), "") {
                selected = category
                render()
                detailScroll.scrollTo(0, 0)
            }
            if (twoPane && category == selected) {
                row.background = ShellUi.rounded(this, palette.surfaceAlt,
                                                 ShellUi.PILL_RADIUS_DP, palette.accent)
                row.isSelected = true
            }
            categoryList.addView(row, ShellUi.matchWrap().apply {
                topMargin = ShellUi.dp(this@SettingsActivity, 6)
            })
        }
        categoryList.addView(
            ShellUi.button(this, texts.t("admin.menu_close", R.string.admin_menu_close),
                           palette) { finish() },
            ShellUi.matchWrap().apply { topMargin = ShellUi.dp(this@SettingsActivity, 16) },
        )
    }

    private fun renderCategory(category: SettingsCategory) {
        when (category) {
            SettingsCategory.DEVICE -> {
                sectionThisDevice()
                specSection(category)
            }
            SettingsCategory.SOUND -> {
                sectionVolume()
                specSection(category)
            }
            SettingsCategory.DISPLAY -> {
                specSection(category)
                sectionAppearance()
            }
            SettingsCategory.CALLS -> {
                specSection(category)
                sectionQuickReplies()
                sectionPurposes()
            }
            SettingsCategory.DOORS -> sectionDoors()
            SettingsCategory.EMERGENCY -> specSection(category)
            SettingsCategory.NOTIFICATIONS -> sectionRules()
            SettingsCategory.TIME -> sectionTime()
            SettingsCategory.SIP -> {
                val card = specSection(category)
                card.row(webOnlyRow(
                    texts.t("settings.item_sip_password", R.string.settings_item_sip_password),
                    texts.t("settings.web_only_secrets", R.string.settings_web_only_secrets),
                ))
            }
            SettingsCategory.NETWORK -> sectionNetwork()
            SettingsCategory.CLUSTER -> {
                sectionCluster()
                sectionHistory()
            }
            SettingsCategory.ABOUT -> {
                sectionAbout()
                sectionWebAdmin()
            }
        }
    }

    /** Text for a catalogue key, through the generated Android resource of the same name. */
    private fun label(key: String, vararg args: Any): String {
        val id = resources.getIdentifier(key.replace('.', '_'), "string", packageName)
        return texts.t(key, id, *args)
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

        if (app.boot.kiosk) card.row(ShellUi.row(
            this, palette,
            texts.t("admin.menu_exit_kiosk", R.string.admin_menu_exit_kiosk),
        ) {
            app.runtime.kioskController.leaveForMaintenance(this)
            finish()
        })
    }

    /** Appearance, background, and the dashboard preview rate (Display category). */
    private fun sectionAppearance() {
        val card = section(texts.t("theme.appearance", R.string.theme_appearance))
        if (app.boot.role != "door_station") card.row(previewRateRow())
        // Appearance: light and dark on every UI, with the schedule core resolves shown in place.
        val published = CoreDisplays.parse(status?.optJSONObject("display")).appearance
        val schedule = app.core.dig(config, "display.appearance_schedule") as? JSONObject
        val darkFrom = published?.darkFrom
            ?: schedule?.optString("dark_from").orEmpty().ifEmpty { "19:00" }
        val lightFrom = published?.lightFrom
            ?: schedule?.optString("light_from").orEmpty().ifEmpty { "06:30" }
        card.row(choiceRow(
            texts.t("theme.appearance", R.string.theme_appearance),
            "devices.$nodeId.local.display.appearance",
            listOf("auto_system", "auto_schedule", "light", "dark"),
            { appearanceLabel(it) },
            published?.configured
                ?: currentString(
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
            (app.core.dig(config, "time.ntp.interval_s") as? Number)?.toInt() ?: 86400,
            3600, 604800,
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
                val previousSync = app.core.status()?.optJSONObject("time")?.optLong("last_sync_ms", 0L) ?: 0L
                val started = app.core.timeSyncNow()
                ui.post {
                    if (!started) toast(texts.t("time.sync_failed", R.string.time_sync_failed))
                    else toast(texts.t("time.sync_started", R.string.time_sync_started))
                }
                if (started) {
                    for (attempt in 0 until 60) {
                        Thread.sleep(100)
                        val time = app.core.status()?.optJSONObject("time") ?: continue
                        if (time.optBoolean("syncing", false)) continue
                        val succeeded = time.optLong("last_sync_ms", 0L) > previousSync
                        ui.post {
                            toast(texts.t(
                                if (succeeded) "time.sync_succeeded" else "time.sync_result_failed",
                                if (succeeded) R.string.time_sync_succeeded else R.string.time_sync_result_failed,
                            ))
                        }
                        break
                    }
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
            val notice = NoticeModel.resolve(status, config, door, nowMs)
            val value = notice?.text ?: texts.t("notice.none", R.string.notice_none)
            card.row(ShellUi.row(this, palette, doorLabel(door), value) {
                NoticeDialog.show(this, app, texts, palette, door, doors, ::doorLabel) {
                    refreshSnapshots()
                    render()
                }
            })
            // Three answers, not a toggle: an absent show_button means "only when an unlock
            // action exists", which is core's "default" source; true and false force it.
            val unlock = DoorUnlocks.read(status, door)
            card.row(unlockRow(door, unlock))
            val labels = app.core.dig(config, "doors.$door.label") as? JSONObject
            card.row(ShellUi.row(this, palette, label("settings.item_door_label"),
                                 localizedLabel(labels, door), enabled = !readOnly) {
                labelDialog(label("settings.item_door_label"), labels) { values ->
                    writeOps(SettingsModel.doorLabelOps(door, values))
                }
            })
            val commandKey = "doors.$door.unlock.command"
            card.row(textRow(label("unlock.command"), commandKey, TextKind.UNLOCK_COMMAND,
                             SettingsModel.currentString(config, commandKey, ""),
                             label("unlock.binding_hint")))
        }
        card.row(webOnlyRow(
            texts.t("settings.item_doors_add", R.string.settings_item_doors_add),
            texts.t("settings.web_only_text", R.string.settings_web_only_text),
        ))
    }

    private fun sectionPurposes() {
        val card = section(texts.t("settings.purposes", R.string.settings_purposes))
        // Every purpose is listed, disabled ones included: this is where the flag is turned
        // back on, so hiding them here would make that impossible.
        val ids = VisitPurposes.all(config)
        if (ids.isEmpty()) {
            card.row(ShellUi.text(this, texts.t("info.no_data", R.string.info_no_data), 14f,
                                  palette.muted))
        } else {
            for (id in ids) card.row(toggleRow(
                purposeLabel(id),
                VisitPurposes.enabledKey(id),
                VisitPurposes.isEnabled(config, id),
            ))
        }
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
        val quietFrom = quiet?.optString("from").orEmpty()
        val quietTo = quiet?.optString("to").orEmpty()
        val unset = texts.t("settings.value_unset", R.string.settings_value_unset)
        card.row(ShellUi.text(this, texts.t("settings.quiet_hours", R.string.settings_quiet_hours),
                              14f, palette.muted, bold = true))
        card.row(timeRow(label("settings.item_quiet_from"), "notify.quiet_hours",
                         quietFrom.ifEmpty { unset }) { picked ->
            SettingsModel.quietHoursJson(picked, quietTo.ifEmpty { picked })
                ?.let { listOf(ConfigOp.Set("notify.quiet_hours", it)) }
        })
        card.row(timeRow(label("settings.item_quiet_to"), "notify.quiet_hours",
                         quietTo.ifEmpty { unset }) { picked ->
            SettingsModel.quietHoursJson(quietFrom.ifEmpty { picked }, picked)
                ?.let { listOf(ConfigOp.Set("notify.quiet_hours", it)) }
        })
        if (quiet != null) card.row(ShellUi.row(this, palette, label("settings.item_quiet_clear"),
                                                enabled = !readOnly) {
            writeOps(listOf(ConfigOp.Delete("notify.quiet_hours")))
        })
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
        sectionPanelsLink(card)
        card.row(ShellUi.row(this, palette, label("settings.item_password_change"),
                             enabled = !readOnly) { changePassword() })
        card.row(ShellUi.row(
            this, palette, texts.t("pair.clear_title", R.string.pair_clear_title),
            note = texts.t("pair.clear_confirm", R.string.pair_clear_confirm),
        ) { confirmUnpair() })
    }

    /** Change the cluster administrator password (db_core_admin_password_set). */
    private fun changePassword() {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = ShellUi.dp(this@SettingsActivity, 16)
            setPadding(pad, ShellUi.dp(this@SettingsActivity, 8), pad, 0)
        }
        fun field(hintKey: String) = EditText(this).apply {
            setSingleLine(true)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            hint = label(hintKey)
            box.addView(this, ShellUi.matchWrap())
        }
        val current = field("settings.item_password_current")
        val next = field("settings.item_password_new")
        val confirm = field("settings.item_password_confirm")
        AlertDialog.Builder(this)
            .setTitle(label("settings.item_password_change"))
            .setView(box)
            .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                val nextValue = next.text.toString()
                when (SettingsModel.checkNewPassword(nextValue, confirm.text.toString())) {
                    PasswordCheck.TOO_SHORT, PasswordCheck.TOO_LONG ->
                        toast(label("settings.item_password_short"))
                    PasswordCheck.MISMATCH -> toast(label("settings.item_password_mismatch"))
                    PasswordCheck.OK -> {
                        val currentValue = current.text.toString()
                        Thread({
                            val result = app.core.adminPasswordSet(currentValue, nextValue)
                            ui.post {
                                if (isFinishing) return@post
                                toast(when (result) {
                                    0 -> label("settings.item_password_changed")
                                    -2 -> texts.t("admin.pin_wrong", R.string.admin_pin_wrong)
                                    -3 -> texts.t("admin.locked", R.string.admin_locked)
                                    else -> texts.t("admin.save_failed", R.string.admin_save_failed)
                                })
                            }
                        }, "doorbell-password").apply { isDaemon = true }.start()
                    }
                }
            }
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
            .show()
    }

    private fun sectionPanelsLink(card: LinearLayout) {
        card.row(webOnlyRow(
            texts.t("settings.item_panels", R.string.settings_item_panels),
            texts.t("settings.item_panels_note", R.string.settings_item_panels_note),
        ))
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

    // ---------- catalogue-driven rows (SettingsModel) ----------

    private fun specSection(category: SettingsCategory): LinearLayout {
        val card = section(label(category.titleKey))
        for (spec in SettingsModel.specs(category, app.boot.role)) card.row(specRow(spec))
        return card
    }

    private fun specRow(spec: SettingSpec): View {
        val key = SettingsModel.resolve(spec.key, nodeId)
        val title = label(spec.titleKey)
        val note = if (spec.noteKey.isEmpty()) "" else label(spec.noteKey)
        return when (spec) {
            is SettingSpec.Toggle ->
                toggleRow(title, key, SettingsModel.currentBool(config, key, spec.default), note)
            is SettingSpec.Choice -> choiceRow(
                title, key, spec.options, { optionLabel(spec.optionKeyPrefix, spec.noneKey, it) },
                SettingsModel.currentString(config, key, spec.default), note,
                asNumber = spec.numeric,
            )
            is SettingSpec.MultiChoice -> multiChoiceRow(spec, key, title)
            is SettingSpec.IntRange -> {
                val current = SettingsModel.currentInt(config, key, spec.default)
                if (spec.slider) sliderRow(spec, key, title, current, note)
                else numberRow(title, key, current, spec.min, spec.max)
            }
            is SettingSpec.Time -> timeRow(title, key,
                SettingsModel.currentString(config, key, spec.default)) { value ->
                SettingsModel.encodeTime(value)?.let { listOf(ConfigOp.Set(key, it)) }
            }
            is SettingSpec.Text -> textRow(title, key, spec.kind,
                SettingsModel.currentString(config, key, spec.default), note)
        }
    }

    private fun optionLabel(prefix: String, noneKey: String, option: String): String = when {
        option.isEmpty() -> label(noneKey)
        option.startsWith("asset:") -> label("settings.sound_custom")
        prefix == "lang." -> Texts.langDisplayName(option)
        prefix == "settings.rotation_" -> "$option°"
        else -> label(prefix + option).let { if (it == prefix + option) option else it }
    }

    private fun multiChoiceRow(spec: SettingSpec.MultiChoice, key: String, title: String): View {
        val current = SettingsModel.currentList(config, key, spec.default)
        val summary = current.joinToString(", ") {
            optionLabel(spec.optionKeyPrefix, "settings.sound_none", it)
        }
        return ShellUi.row(this, palette, title, summary, enabled = !readOnly) {
            val checked = BooleanArray(spec.options.size) { spec.options[it] in current }
            AlertDialog.Builder(this)
                .setTitle(title)
                .setMultiChoiceItems(
                    spec.options.map {
                        optionLabel(spec.optionKeyPrefix, "settings.sound_none", it) as CharSequence
                    }.toTypedArray(),
                    checked,
                ) { _, which, isChecked -> checked[which] = isChecked }
                .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                    val chosen = spec.options.filterIndexed { index, _ -> checked[index] }
                    val json = SettingsModel.encodeMulti(spec, chosen)
                    if (json == null) toast(label("settings.select_at_least_one"))
                    else write(key, json) { }
                }
                .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
                .show()
        }
    }

    /** A SeekBar that writes once, when the finger lifts. */
    private fun sliderRow(
        spec: SettingSpec.IntRange,
        key: String,
        title: String,
        current: Int,
        note: String,
    ): View {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = ShellUi.rounded(this@SettingsActivity, palette.surface,
                                         ShellUi.PILL_RADIUS_DP, palette.line)
            val pad = ShellUi.dp(this@SettingsActivity, ShellUi.PILL_PADDING_H_DP)
            setPadding(pad, ShellUi.dp(this@SettingsActivity, 8), pad,
                       ShellUi.dp(this@SettingsActivity, 8))
        }
        val heading = ShellUi.text(this, "$title  ${current.coerceIn(spec.min, spec.max)}", 15f,
                                   palette.ink)
        column.addView(heading)
        if (note.isNotEmpty()) column.addView(ShellUi.text(this, note, 12.5f, palette.muted))
        val bar = SeekBar(this).apply {
            max = spec.max - spec.min
            progress = current.coerceIn(spec.min, spec.max) - spec.min
            isEnabled = !readOnly
            minimumHeight = ShellUi.dp(this@SettingsActivity, ShellUi.TOUCH_FLOOR_DP)
        }
        bar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                heading.text = "$title  ${progress + spec.min}"
            }

            override fun onStartTrackingTouch(seekBar: SeekBar) = Unit

            override fun onStopTrackingTouch(seekBar: SeekBar) {
                val json = SettingsModel.encodeInt(spec, (seekBar.progress + spec.min).toString())
                    ?: return
                write(key, json) { ok -> if (!ok) seekBar.progress = current - spec.min }
            }
        })
        column.addView(bar, ShellUi.matchWrap())
        return column
    }

    /** A time picker; [ops] turns the picked "HH:MM" into the batch to write (null = invalid). */
    private fun timeRow(
        title: String,
        key: String,
        current: String,
        ops: (String) -> List<ConfigOp>?,
    ): View = ShellUi.row(this, palette, title, current, enabled = !readOnly) {
        val parsed = SettingsModel.normalizeTime(current) ?: "00:00"
        android.app.TimePickerDialog(this, { _, hour, minute ->
            val picked = "%02d:%02d".format(hour, minute)
            val batch = ops(picked)
            if (batch == null) toast(texts.t("admin.save_failed", R.string.admin_save_failed))
            else writeOps(batch)
        }, parsed.substring(0, 2).toInt(), parsed.substring(3, 5).toInt(), true).apply {
            setTitle(title)
        }.show()
    }

    /** Free text with per-kind validation; a blank value deletes the key so it inherits. */
    private fun textRow(title: String, key: String, kind: TextKind, current: String,
                        note: String): View =
        ShellUi.row(this, palette, title,
                    current.ifEmpty { texts.t("settings.value_unset", R.string.settings_value_unset) },
                    note, enabled = !readOnly) {
            val field = EditText(this).apply {
                setSingleLine(true)
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
                setText(current)
            }
            AlertDialog.Builder(this)
                .setTitle(title)
                .setView(field)
                .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                    val raw = field.text.toString().trim()
                    val json = SettingsModel.encodeText(kind, raw)
                    when {
                        json == null -> toast(label("settings.invalid_value"))
                        raw.isEmpty() -> deleteKey(key)
                        else -> write(key, json) { }
                    }
                }
                .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
                .show()
        }

    /** Three label fields (ja/en/zh) in one dialog. */
    private fun labelDialog(
        title: String,
        current: JSONObject?,
        extra: View? = null,
        onDelete: (() -> Unit)? = null,
        onSave: (Map<String, String>) -> Unit,
    ) {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = ShellUi.dp(this@SettingsActivity, 16)
            setPadding(pad, ShellUi.dp(this@SettingsActivity, 8), pad, 0)
        }
        val fields = SettingsModel.LANGUAGES.associateWith { lang ->
            EditText(this).apply {
                setSingleLine(true)
                hint = label("admin.label_$lang")
                setText(current?.optString(lang).orEmpty())
                box.addView(this, ShellUi.matchWrap())
            }
        }
        if (extra != null) box.addView(extra, ShellUi.matchWrap())
        val builder = AlertDialog.Builder(this)
            .setTitle(title)
            .setView(box)
            .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                onSave(fields.mapValues { it.value.text.toString() })
            }
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
        if (onDelete != null) builder.setNeutralButton(label("admin.delete")) { _, _ -> onDelete() }
        builder.show()
    }

    private fun localizedLabel(labels: JSONObject?, fallback: String): String =
        labels?.optString(texts.lang).orEmpty().ifEmpty { labels?.optString("ja").orEmpty() }
            .ifEmpty { fallback }

    // ---------- structured sections ----------

    private fun sectionQuickReplies() {
        val card = section(texts.t("admin.quick_replies", R.string.admin_quick_replies))
        val replies = app.core.dig(config, "quick_replies") as? JSONObject
        if (replies != null) for (id in sortedByOrder(replies)) {
            val reply = replies.optJSONObject(id) ?: continue
            val labels = reply.optJSONObject("label")
            val speak = reply.optBoolean("speak", true)
            card.row(ShellUi.row(
                this, palette, localizedLabel(labels, id),
                if (speak) label("admin.qr_speak") else "", enabled = !readOnly,
            ) { editQuickReply(id, reply) })
        }
        card.row(ShellUi.row(this, palette, label("admin.add_reply"), enabled = !readOnly) {
            editQuickReply(null, null)
        })
        card.row(webOnlyRow(
            texts.t("settings.item_reply_audio", R.string.settings_item_reply_audio),
            texts.t("settings.web_only_upload", R.string.settings_web_only_upload),
        ))
    }

    private fun editQuickReply(id: String?, reply: JSONObject?) {
        val speak = android.widget.CheckBox(this).apply {
            text = label("admin.qr_speak")
            isChecked = reply?.optBoolean("speak", true) ?: true
        }
        val replies = app.core.dig(config, "quick_replies") as? JSONObject
        labelDialog(
            label(if (id == null) "admin.add_reply" else "admin.edit"),
            reply?.optJSONObject("label"),
            extra = speak,
            onDelete = id?.let { existing -> { writeOps(listOf(ConfigOp.Delete("quick_replies.$existing"))) } },
        ) { labels ->
            val order = reply?.optInt("order") ?: SettingsModel.nextQuickReplyOrder(replies)
            val json = SettingsModel.quickReplyJson(labels, speak.isChecked, order)
            if (json == null) {
                toast(label("settings.invalid_value"))
                return@labelDialog
            }
            val target = id ?: SettingsModel.nextQuickReplyId(
                replies?.keys()?.asSequence()?.toList().orEmpty(), System.nanoTime())
            // Replace the whole entry so a removed language does not linger as a stale leaf.
            writeOps(listOf(ConfigOp.Set("quick_replies.$target", json)))
        }
    }

    private fun sectionNetwork() {
        val card = section(label("settings.cat_network"))
        val node = status?.optJSONObject("node")
        val boot = try { JSONObject(app.boot.rawJson) } catch (e: Exception) {
            ShellLog.ignored("SettingsActivity", e)
            JSONObject()
        }
        val addresses = node?.optJSONArray("local_addrs")
        val hosts = PeerAddresses.preferredHosts(addresses)
        card.row(ShellUi.row(this, palette, label("info.node"),
                             nodeId.ifEmpty { "-" }))
        card.row(ShellUi.row(this, palette, label("admin.addresses"),
                             hosts.joinToString(", ").ifEmpty { "-" }))
        card.row(ShellUi.row(this, palette, label("settings.item_http_port"),
                             app.boot.httpPort.toString(), label("settings.item_http_port_note")))
        card.row(ShellUi.row(this, palette, label("settings.item_https_port"),
                             (node?.optInt("https_port", 47443) ?: 47443).toString()))
        card.row(ShellUi.row(this, palette, label("settings.item_mesh_port"),
                             boot.optInt("listen_port", 47172).toString(),
                             label("settings.item_ports_note")))
    }

    /** Batch write with the same admin-window handling as a single key. */
    private fun writeOps(ops: List<ConfigOp>) {
        val active = writer ?: run {
            toast(texts.t("settings.offline", R.string.settings_offline))
            return
        }
        Thread({
            val result = active.applyOps(ops)
            ui.post {
                if (isFinishing) return@post
                if (result.adminRequired) {
                    reauthenticateThen { writeOps(ops) }
                    return@post
                }
                toast(
                    if (result.ok) texts.t("admin.saved", R.string.admin_saved)
                    else texts.t("admin.save_failed", R.string.admin_save_failed),
                )
                refreshSnapshots()
                texts.setConfig(config)
                render()
            }
        }, "doorbell-config-batch").apply { isDaemon = true }.start()
    }

    // ---------- row builders ----------

    private fun webOnlyRow(title: String, reason: String): View =
        ShellUi.row(this, palette, title, note = reason) { openAdminPage() }

    /** 開錠ボタン: 自動 (follow the configured action) / 常に表示 / 表示しない. */
    private fun unlockRow(door: String, unlock: DoorUnlock): View {
        val key = "doors.$door.unlock.show_button"
        val choices = listOf(
            UnlockVisibility.AUTO to texts.t("unlock.auto", R.string.unlock_auto),
            UnlockVisibility.SHOW to texts.t("unlock.show", R.string.unlock_show),
            UnlockVisibility.HIDE to texts.t("unlock.hide", R.string.unlock_hide),
        )
        val current = DoorUnlocks.visibilityOf(unlock)
        val note = if (unlock.configured) ""
            else texts.t("unlock.not_configured", R.string.unlock_not_configured)
        return ShellUi.row(
            this, palette, texts.t("unlock.title", R.string.unlock_title),
            choices.first { it.first == current }.second, note, enabled = !readOnly,
        ) {
            AlertDialog.Builder(this)
                .setTitle(texts.t("unlock.title", R.string.unlock_title))
                .setItems(choices.map { it.second as CharSequence }.toTypedArray()) { _, which ->
                    // "自動" is the absence of the key, so it is a delete rather than a write.
                    when (choices[which].first) {
                        UnlockVisibility.AUTO -> deleteKey(key)
                        UnlockVisibility.SHOW -> write(key, "true") { }
                        UnlockVisibility.HIDE -> write(key, "false") { }
                    }
                }
                .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
                .show()
        }
    }

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

    /** The dashboard still rate is this panel's own preference, so it bypasses core writes. */
    private fun previewRateRow(): View {
        val title = texts.t("dashboard.preview_rate_title", R.string.dashboard_preview_rate_title)
        fun label(rate: Double) = texts.t("dashboard.preview_rate_format",
            R.string.dashboard_preview_rate_format, PreviewRate.valueText(rate))
        return ShellUi.row(this, palette, title, label(PreviewRate.saved(this))) {
            AlertDialog.Builder(this)
                .setTitle(title)
                .setItems(PreviewRate.RATES.map { label(it) as CharSequence }.toTypedArray()) { _, which ->
                    PreviewRate.save(this, PreviewRate.RATES[which])
                    render()
                }
                .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
                .show()
        }
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
        return texts.t("theme.low_contrast", R.string.theme_low_contrast,
                       UiContrast.ratioText(ratio))
    }

    // ---------- writes ----------

    private fun write(key: String, valueJson: String, done: (Boolean) -> Unit) {
        val active = writer
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
                    // A colour below the WCAG ratio is still saved; core returns the measured
                    // advisory alongside the success and it is shown rather than swallowed.
                    val advisory = WriteWarnings.message(result.warning) { key, ratio ->
                        if (key == WriteWarnings.LOW_CONTRAST)
                            texts.t(key, R.string.theme_low_contrast, ratio)
                        else texts.t(key, R.string.admin_saved)
                    }
                    toast(advisory.ifEmpty { texts.t("admin.saved", R.string.admin_saved) })
                    refreshSnapshots()
                    texts.setConfig(config)
                    render()
                } else if (result.adminRequired) {
                    reauthenticateThen { write(key, valueJson, done) }
                    return@post
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
        val active = writer ?: run {
            toast(texts.t("settings.offline", R.string.settings_offline))
            return
        }
        Thread({
            val result = active.deleteKey(key)
            ui.post {
                if (isFinishing) return@post
                if (result.adminRequired) {
                    reauthenticateThen { deleteKey(key) }
                    return@post
                }
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
            ui.postDelayed({ try { tone.release() } catch (e: Exception) { ShellLog.ignored("SettingsActivity", e) } }, 400)
        } catch (e: Exception) { ShellLog.ignored("SettingsActivity", e) }
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

    private fun purposeLabel(purpose: String): String =
        VisitPurposes.label(config, purpose, texts.lang)

    private fun roleLabel(role: String): String = when (role) {
        "door_station" -> texts.t("pair.role_door_station", R.string.pair_role_door_station)
        "indoor_panel" -> texts.t("pair.role_indoor_panel", R.string.pair_role_indoor_panel)
        else -> role
    }

    private fun appearanceLabel(value: String): String = when (value) {
        "auto_schedule" ->
            texts.t("theme.appearance_auto_schedule", R.string.theme_appearance_auto_schedule)
        "light" -> texts.t("theme.appearance_light", R.string.theme_appearance_light)
        "dark" -> texts.t("theme.appearance_dark", R.string.theme_appearance_dark)
        else -> texts.t("theme.appearance_auto_system", R.string.theme_appearance_auto_system)
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
        private const val STATE_CATEGORY = "settings_category"
        private const val CATEGORY_PANE_DP = 300

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
    }
}
