// Native settings (spec §3): every device-level and cluster setting, always behind the
// 管理パスワード. Every write goes through the same configuration keys and the same server-side
// validation the web admin uses. Nothing here hands off to the web admin any more: the editors
// that replaced those rows live in NativeSettingsSections.
package jp.ox.doorbell

import android.app.Activity
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
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.util.Locale
import java.util.TimeZone
import org.json.JSONArray
import org.json.JSONObject

class SettingsActivity : ShellActivity(), DoorbellCore.Listener {

    internal val ui = Handler(Looper.getMainLooper())
    internal lateinit var app: App
    internal lateinit var texts: Texts
    private lateinit var clock: ClusterClock
    internal lateinit var palette: Palette
    /** The detail pane that every section renders into. */
    private lateinit var listView: LinearLayout
    private lateinit var categoryList: LinearLayout
    private lateinit var categoryScroll: ScrollView

    /** Search field above the category list, then the list; one pane on phones. */
    private lateinit var categoryPane: LinearLayout
    private var query = ""
    private var roles: UiRoles = UiRoles.from(Palette.DARK)
    private lateinit var detailScroll: ScrollView
    private lateinit var appBar: AppBarHandle
    private var twoPane = false
    /** The open category; null shows the category list on a phone. */
    private var selected: SettingsCategory? = null

    internal var config: JSONObject? = null
    internal var status: JSONObject? = null
    internal var nodeId = ""
    private var pairing: JSONObject? = null
    /** Where writes go: core when it exports them, otherwise the loopback session. */
    private var writer: ConfigWriter? = null

    /** Set when neither core nor a loopback session can write, so the screen is read-only. */
    internal var readOnly = false

    /**
     * The loopback administrator session from the password gate. Core's session-bound entry
     * points (config import, panel identities) and the Telegram test need its cookie and CSRF.
     */
    internal var adminSession: AdminSession? = null

    private val native by lazy { NativeSettingsSections(this) }

    /** Pending file pickers / document creators, by request code. */
    private val resultHandlers = HashMap<Int, (Intent?) -> Unit>()
    private var nextRequestCode = 7100

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        texts = Texts(this)
        clock = ClusterClock(app.core)
        selected = SettingsCategory.byId(savedInstanceState?.getString(STATE_CATEGORY))
        writer = ConfigWriters.choose(app.core, pendingSession)
        readOnly = writer == null
        adminSession = pendingSession
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
    internal fun reauthenticateThen(retry: () -> Unit) {
        AdminGate.unlock(this, app.boot.httpPort, texts) { session ->
            if (session != null) {
                writer = ConfigWriters.choose(app.core, session)
                adminSession = session
            }
            retry()
        }
    }

    /** Start a picker; [onResult] gets the result data, or null when cancelled. */
    internal fun launchForResult(intent: Intent, onResult: (Intent?) -> Unit) {
        val code = nextRequestCode++
        resultHandlers[code] = onResult
        try {
            startActivityForResult(intent, code)
        } catch (e: android.content.ActivityNotFoundException) {
            resultHandlers.remove(code)
            toast(label("nset.no_picker"))
        }
    }

    @Deprecated("Activity result API is unavailable on API 19 without AndroidX")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val handler = resultHandlers.remove(requestCode)
        if (handler == null) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        handler(if (resultCode == RESULT_OK) data else null)
    }

    /**
     * Run an admin-gated Core call off the main thread. A refusal because the native admin window
     * closed asks for the password again and repeats the call.
     */
    internal fun coreCall(work: () -> JSONObject?, done: (JSONObject?) -> Unit) {
        Thread({
            val result = try { work() } catch (e: Exception) {
                ShellLog.ignored("SettingsActivity", e)
                null
            }
            ui.post {
                if (isFinishing) return@post
                val error = result?.optString("err").orEmpty()
                    .ifEmpty { result?.optString("error_code").orEmpty() }
                if (error == ConfigWriters.ERR_ADMIN_REQUIRED) {
                    reauthenticateThen { coreCall(work, done) }
                    return@post
                }
                done(result)
            }
        }, "doorbell-settings-core").apply { isDaemon = true }.start()
    }

    override fun onUiEvent(ev: JSONObject) {
        when (ev.optString("t")) {
            "config_changed", "peers_changed", "notice_changed", "time_changed",
            "power_changed", "cluster_key_changed", "peer_rejected", "pairing_state", "display",
            -> ui.post {
                if (isFinishing) return@post
                refreshSnapshots()
                texts.setConfig(config)
                render()
            }
        }
    }

    override fun onTts(text: String, lang: String) {}

    internal fun refreshSnapshots() {
        config = if (app.coreOk) app.core.config() else null
        status = if (app.coreOk) app.core.status() else null
        pairing = if (app.coreOk) app.core.pairingInfo() else null
        nodeId = status?.optJSONObject("node")?.optString("id").orEmpty()
    }

    private fun resolvePalette(): Palette =
        ShellAppearance.resolve(this, status, config, clock.now().minuteOfDay())

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
        // Top app bar: back steps from a category to the list on a phone, and out of settings
        // otherwise.
        appBar = PlatformUi.appBar(this, texts.t("settings.title", R.string.settings_title))
        root.addView(appBar.view, ShellUi.matchWrap())

        categoryList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        listView = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        categoryScroll = paneScroll(categoryList)
        roles = UiRoles.from(palette)
        categoryPane = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val searchEntry = PlatformUi.field(
            this, texts.t("settings.search_hint", R.string.settings_search_hint), query,
            icon = R.drawable.ic_tabler_search,
        )
        val search = searchEntry.view
        searchEntry.input.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(value: Editable?) {
                val next = value?.toString().orEmpty()
                if (next == query) return
                query = next
                applySearch()
            }
        })
        categoryPane.addView(search, ShellUi.matchWrap().apply {
            val m = ShellUi.dp(this@SettingsActivity, UiTokens.SPACE_L)
            setMargins(m, ShellUi.dp(this@SettingsActivity, UiTokens.SPACE_S), m, 0)
        })
        categoryPane.addView(categoryScroll, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        detailScroll = paneScroll(listView)
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            isBaselineAligned = false
        }
        if (twoPane) {
            // Fixed-width category list, a hairline, and the detail pane, as Android Settings
            // lays out a tablet. Plain views, so legacy19 gets the same layout on API 19.
            body.addView(categoryPane, LinearLayout.LayoutParams(
                ShellUi.dp(this, CATEGORY_PANE_DP), ViewGroup.LayoutParams.MATCH_PARENT))
            body.addView(View(this).apply { setBackgroundColor(ShellUi.opaque(palette.line)) },
                         LinearLayout.LayoutParams(ShellUi.dp(this, 1),
                                                   ViewGroup.LayoutParams.MATCH_PARENT))
            body.addView(detailScroll, LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        } else {
            body.addView(categoryPane, LinearLayout.LayoutParams(
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
        setPadding(0, 0, 0, pad)
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

    /**
     * Rebuilt in place rather than recreated: the administrator session handed over by the
     * password gate lives in this instance and must not be lost to an appearance flip.
     */
    override fun onAppearanceChanged() {
        palette = PlatformUi.tokens(this)
        setContentView(buildShell())
        render()
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        palette = PlatformUi.tokens(this)
        // Rotating a tablet can move between one and two panes; the open category survives.
        setContentView(buildShell())
        render()
    }

    internal fun render() {
        // Every render follows a fresh snapshot; an appearance changed on this very screen is
        // reported here so it shows at once.
        resolvePalette()
        renderCategoryList()
        val category = selected
        listView.removeAllViews()
        if (readOnly) listView.addView(
            ShellUi.pill(this, texts.t("settings.offline", R.string.settings_offline),
                         palette.noticeBg, palette.noticeInk),
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT,
                                      ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                leftMargin = ShellUi.dp(this@SettingsActivity, 16)
            },
        )
        if (category != null) renderCategory(category)
        if (!twoPane) {
            categoryPane.visibility = if (category == null) View.VISIBLE else View.GONE
            detailScroll.visibility = if (category == null) View.GONE else View.VISIBLE
        }
        val drilled = !twoPane && category != null
        appBar.setTitle(if (drilled) label(category!!.titleKey)
                        else texts.t("settings.title", R.string.settings_title))
        appBar.setBack(
            if (drilled) texts.t("settings.back", R.string.settings_back)
            else texts.t("admin.menu_close", R.string.admin_menu_close),
        ) { if (drilled) showCategoryList() else finish() }
    }

    /** Categories the search matches: by their own title or any setting title inside them. */
    private fun visibleCategories(): List<SettingsCategory> {
        val role = app.boot.role
        return SettingsSearch.filter(query) { category ->
            listOf(label(category.titleKey)) +
                SettingsModel.specs(category, role).map { label(it.titleKey) } +
                native.searchLabels(category)
        }
    }

    /** A new query: list the matches, and in two panes open the first if the open one is gone. */
    private fun applySearch() {
        val matches = visibleCategories()
        if (twoPane && matches.isNotEmpty() && selected !in matches) {
            selected = matches.first()
            render()
        } else {
            renderCategoryList()
        }
    }

    private fun renderCategoryList() {
        categoryList.removeAllViews()
        val matches = visibleCategories()
        if (matches.isEmpty()) categoryList.addView(
            ShellUi.label(this, texts.t("settings.search_empty", R.string.settings_search_empty),
                          TextRole.BODY, palette.muted).apply {
                val pad = ShellUi.dp(this@SettingsActivity, UiTokens.SPACE_L)
                setPadding(pad, pad, pad, 0)
            },
            ShellUi.matchWrap(),
        )
        for (category in matches) {
            val active = twoPane && category == selected
            categoryList.addView(categoryRow(category, active), ShellUi.matchWrap())
        }
    }

    /** Icon and title, as Android Settings lists its categories; the open one is highlighted. */
    private fun categoryRow(category: SettingsCategory, active: Boolean): View =
        ShellUi.row(this, palette, label(category.titleKey), icon = categoryIcon(category)) {
            selected = category
            render()
            detailScroll.scrollTo(0, 0)
        }.apply {
            isSelected = active
            contentDescription = label(category.titleKey)
            if (active) {
                // The open category keeps a tonal plate, as a selected list item does.
                setBackgroundColor(ShellUi.opaque(palette.surfaceAlt))
                (getChildAt(0) as? android.widget.ImageView)
                    ?.setColorFilter(ShellUi.opaque(ShellUi.accentInk(palette)))
            }
        }

    private fun categoryIcon(category: SettingsCategory): Int = when (category) {
        SettingsCategory.DEVICE -> R.drawable.ic_tabler_device_tablet
        SettingsCategory.SOUND -> R.drawable.ic_tabler_volume
        SettingsCategory.DISPLAY -> R.drawable.ic_tabler_palette
        SettingsCategory.CALLS -> R.drawable.ic_tabler_phone
        SettingsCategory.DOORS -> R.drawable.ic_tabler_door
        SettingsCategory.EMERGENCY -> R.drawable.ic_tabler_bell
        SettingsCategory.NOTIFICATIONS -> R.drawable.ic_tabler_mail
        SettingsCategory.TIME -> R.drawable.ic_tabler_clock
        SettingsCategory.SIP -> R.drawable.ic_tabler_link
        SettingsCategory.NETWORK -> R.drawable.ic_tabler_world
        SettingsCategory.CLUSTER -> R.drawable.ic_tabler_topology_star_3
        SettingsCategory.ABOUT -> R.drawable.ic_tabler_info_circle
    }

    /**
     * A destructive or security action (guidelines "Settings"): a list row in the negative
     * colour with its consequence written under it; the caller confirms before acting.
     */
    internal fun destructiveRow(title: String, note: String, onClick: () -> Unit): View =
        ShellUi.row(this, palette, title, note = note, enabled = !readOnly) { onClick() }.apply {
            ((getChildAt(0) as? LinearLayout)?.getChildAt(0) as? TextView)
                ?.setTextColor(ShellUi.opaque(if (readOnly) palette.muted else palette.danger))
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
                native.soundLibrary()
            }
            SettingsCategory.DISPLAY -> {
                specSection(category)
                sectionAppearance()
                native.wording()
            }
            SettingsCategory.CALLS -> {
                specSection(category)
                sectionQuickReplies()
                native.purposes()
            }
            SettingsCategory.DOORS -> {
                sectionDoors()
                native.buildings()
                native.noticePresets()
                native.mediaSources()
            }
            SettingsCategory.EMERGENCY -> specSection(category)
            SettingsCategory.NOTIFICATIONS -> {
                native.rules()
                native.quietHours()
                native.households()
                native.telegram()
                native.webPush()
                native.mqtt()
            }
            SettingsCategory.TIME -> sectionTime()
            SettingsCategory.SIP -> {
                native.sipExtras(specSection(category))
                native.dtmf()
                native.webrtc()
            }
            SettingsCategory.NETWORK -> sectionNetwork()
            SettingsCategory.CLUSTER -> {
                sectionCluster()
                native.devices()
                native.panels()
                native.transfer()
                sectionHistory()
            }
            SettingsCategory.ABOUT -> {
                sectionAbout()
                sectionWebAdmin()
            }
        }
    }

    /** Text for a catalogue key, through the generated Android resource of the same name. */
    internal fun label(key: String, vararg args: Any): String {
        val id = resources.getIdentifier(key.replace('.', '_'), "string", packageName)
        return texts.t(key, id, *args)
    }

    // ---------- sections ----------

    /** A titled group of rows on a card; returns the card's content column. */
    internal fun section(title: String): LinearLayout {
        listView.addView(ShellUi.sectionHeading(this, palette, title), ShellUi.matchWrap())
        val card = ShellUi.card(this, palette)
        listView.addView(card.root, ShellUi.matchWrap().apply {
            val margin = ShellUi.dp(this@SettingsActivity, 16)
            leftMargin = margin
            rightMargin = margin
        })
        return card.content
    }

    internal fun LinearLayout.row(view: View) {
        addView(view, ShellUi.matchWrap())
    }

    private fun sectionThisDevice() {
        val card = section(texts.t("settings.this_device", R.string.settings_this_device))
        card.row(ShellUi.row(
            this, palette,
            texts.t("settings.device_name", R.string.settings_device_name),
            app.boot.name,
            texts.t("settings.restart_required", R.string.settings_restart_required),
        ) { renameThisDevice() })
        val door = if (app.boot.role == RoleChangeModel.DOOR_STATION)
            " · " + doorLabel(app.boot.door) else ""
        card.row(ShellUi.row(
            this, palette,
            label("settings.change_role"),
            roleLabel(app.boot.role) + door,
            label("settings.role_restart"),
            trailing = ShellUi.label(this, label("settings.change_role_action"), TextRole.LABEL,
                                     ShellUi.accentInk(palette)),
        ) { changeRole(nodeId, app.boot.role, app.boot.door, self = true) })

        if (app.boot.kiosk) card.row(ShellUi.row(
            this, palette,
            texts.t("admin.menu_exit_kiosk", R.string.admin_menu_exit_kiosk),
        ) {
            app.runtime.kioskController.leaveForMaintenance(this)
            finish()
        })
    }

    private fun roleChangeBlocked(): Boolean = RoleChangeModel.blocked(
        status, app.callFlow.current() != null, app.incomingActivity != null,
    )

    /** The device name is part of the local identity, so saving it restarts Core as a role does. */
    private fun renameThisDevice() {
        if (roleChangeBlocked()) {
            toast(label("settings.role_busy"))
            return
        }
        val field = PlatformUi.field(
            this, texts.t("settings.device_name", R.string.settings_device_name), app.boot.name,
        )
        ShellDialogBuilder(this)
            .setTitle(texts.t("settings.device_name", R.string.settings_device_name))
            .setView(dialogField(field))
            .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                val name = field.text.trim()
                when {
                    name.isEmpty() || name.length > 64 -> toast(label("settings.invalid_value"))
                    name == app.boot.name -> toast(label("settings.role_unchanged"))
                    !app.completeBootSetup(name, app.boot.role, app.boot.door) ->
                        toast(texts.t("admin.save_failed", R.string.admin_save_failed))
                    else -> finish()
                }
            }
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
            .show()
    }

    /**
     * The "Change role" form. Nothing is written until the confirmation: this device persists
     * boot.json and restarts through the identity path; another device gets its role and door in
     * one batch and applies them itself.
     */
    internal fun changeRole(deviceId: String, currentRole: String, currentDoor: String,
                            self: Boolean, deviceName: String = "") {
        if (readOnly && !self) {
            toast(texts.t("settings.offline", R.string.settings_offline))
            return
        }
        if (self && roleChangeBlocked()) {
            toast(label("settings.role_busy"))
            return
        }
        var role = if (currentRole == RoleChangeModel.INDOOR_PANEL) RoleChangeModel.INDOOR_PANEL
                   else RoleChangeModel.DOOR_STATION
        val existing = if (currentDoor == "null") "" else currentDoor
        val pad = ShellUi.dp(this, 24)
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, ShellUi.dp(this@SettingsActivity, 8), pad, 0)
        }
        // Doors nobody else serves come first; the device's own door stays selectable.
        val doors = (RoleChangeModel.freeDoors(config, deviceId) + listOf(existing))
            .filter { it.isNotEmpty() }.distinct()
        val doorBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        doorBox.addView(ShellUi.label(this, texts.t("settings.door", R.string.settings_door),
                                      TextRole.LABEL).apply {
            setPadding(0, ShellUi.dp(this@SettingsActivity, 16), 0, 0)
        })
        val group = android.widget.RadioGroup(this)
        val ids = ArrayList<Int>()
        for (door in doors) group.addView(PlatformUi.radio(this).apply {
            id = View.generateViewId()
            ids.add(id)
            text = doorLabel(door).let { if (it == door) door else "$it ($door)" }
            minHeight = ShellUi.dp(this@SettingsActivity, UiTokens.TOUCH_MIN_DP)
        })
        val newDoor = PlatformUi.radio(this).apply {
            id = View.generateViewId()
            text = label("settings.role_new_door")
            minHeight = ShellUi.dp(this@SettingsActivity, UiTokens.TOUCH_MIN_DP)
        }
        group.addView(newDoor)
        val suggestion = if (self && BootConfig.validDoor(app.boot.suggestedDoor) &&
            app.boot.suggestedDoor !in doors) app.boot.suggestedDoor
            else "door-" + java.lang.Long.toHexString(System.nanoTime()).takeLast(8)
        val newId = PlatformUi.field(this, label("settings.role_new_door_id"), suggestion)
        val selected = doors.indexOf(existing)
        group.check(if (selected >= 0) ids[selected] else if (doors.isNotEmpty() && existing.isEmpty())
            ids[0] else newDoor.id)
        newId.view.visibility = if (group.checkedRadioButtonId == newDoor.id) View.VISIBLE else View.GONE
        group.setOnCheckedChangeListener { _, checked ->
            newId.view.visibility = if (checked == newDoor.id) View.VISIBLE else View.GONE
        }
        doorBox.addView(group, ShellUi.matchWrap())
        doorBox.addView(newId.view, ShellUi.matchWrap())
        doorBox.addView(ShellUi.label(this, label("setup.door_hint"), TextRole.LABEL))
        val indoorNote = ShellUi.label(
            this, label("settings.role_indoor_note") + "\n" + label("settings.role_door_kept_note"),
            TextRole.SUPPORTING,
        ).apply { setPadding(0, ShellUi.dp(this@SettingsActivity, 16), 0, 0) }
        fun showRole() {
            doorBox.visibility = if (role == RoleChangeModel.DOOR_STATION) View.VISIBLE else View.GONE
            indoorNote.visibility = if (role == RoleChangeModel.INDOOR_PANEL) View.VISIBLE else View.GONE
        }
        val roles = PlatformUi.segmented(this, listOf(
            RoleChangeModel.DOOR_STATION to roleLabel(RoleChangeModel.DOOR_STATION),
            RoleChangeModel.INDOOR_PANEL to roleLabel(RoleChangeModel.INDOOR_PANEL),
        ), onPick = { picked ->
            role = picked
            showRole()
        })
        roles.select(role)
        box.addView(roles.view, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        box.addView(doorBox, ShellUi.matchWrap())
        box.addView(indoorNote, ShellUi.matchWrap())
        showRole()

        val dialog = ShellDialogBuilder(this)
            .setTitle(label("settings.change_role"))
            .setView(ScrollView(this).apply { addView(box) })
            .setPositiveButton(label("settings.change_role"), null)
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(android.content.DialogInterface.BUTTON_POSITIVE).setOnClickListener {
                val checked = group.checkedRadioButtonId
                val door = if (checked == newDoor.id) newId.text.trim()
                           else doors.getOrNull(ids.indexOf(checked)).orEmpty()
                when (RoleChangeModel.validate(role, door)) {
                    RoleChangeModel.Problem.DOOR -> {
                        newId.setError(label("setup.invalid_door"))
                        group.check(newDoor.id)
                        return@setOnClickListener
                    }
                    RoleChangeModel.Problem.ROLE -> {
                        toast(label("settings.invalid_value"))
                        return@setOnClickListener
                    }
                    RoleChangeModel.Problem.NONE -> Unit
                }
                if (RoleChangeModel.unchanged(currentRole, existing, role, door)) {
                    toast(label("settings.role_unchanged"))
                    dialog.dismiss()
                    return@setOnClickListener
                }
                dialog.dismiss()
                confirmRoleChange(deviceId, role, door, self, deviceName)
            }
        }
        dialog.show()
    }

    /** States the consequence, then applies: boot.json first for this device, a batch otherwise. */
    private fun confirmRoleChange(deviceId: String, role: String, door: String, self: Boolean,
                                  deviceName: String) {
        val owner = if (role == RoleChangeModel.DOOR_STATION)
            RoleChangeModel.otherOwner(config, deviceId, door) else ""
        val message = buildString {
            append(if (self) label("settings.role_restart_confirm")
                   else label("editor.role_restart_confirm", deviceName))
            if (owner.isNotEmpty()) append("\n\n").append(label("settings.role_door_in_use", owner))
        }
        ShellDialogBuilder(this)
            .setTitle(label("settings.change_role"))
            .setMessage(message)
            .setPositiveButton(label("settings.change_role")) { _, _ ->
                if (!self) {
                    writeOps(RoleChangeModel.ops(deviceId, role, door))
                    return@setPositiveButton
                }
                if (roleChangeBlocked()) {
                    toast(label("settings.role_busy"))
                    return@setPositiveButton
                }
                // completeBootSetup persists boot.json, restarts Core with the new identity and
                // relaunches the home screen for the new role.
                if (app.completeBootSetup(app.boot.name, role, RoleChangeModel.doorFor(role, door)))
                    finish()
                else toast(texts.t("admin.save_failed", R.string.admin_save_failed))
            }
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
            .show()
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
        native.backgroundImageRow(card)
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
        card.row(rowNote(texts.t("volume.hint", R.string.volume_hint)))
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
        card.row(rowAction(texts.t("time.sync_now", R.string.time_sync_now)) {
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
            card.row(rowNote(texts.t("dash.no_doors", R.string.dash_no_doors)))
            native.addDoorRow(card)
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
            native.doorExtras(card, door)
        }
        native.addDoorRow(card)
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
                    texts.t("power.charging", R.string.power_charging),
                ) { texts.t("power.percent", R.string.power_percent, it.toString()) }
                card.row(ShellUi.row(this, palette, name, detail))
            }
        }
        sectionClusterSecurity(card)
        card.row(ShellUi.row(this, palette, label("settings.item_password_change"),
                             enabled = !readOnly) { changePassword() })
        // Destructive and security actions sit at the bottom of their section.
        card.row(destructiveRow(label("settings.item_rotate_key"),
                                label("settings.item_rotate_key_note")) { confirmRotateKey() })
        card.row(destructiveRow(texts.t("pair.clear_title", R.string.pair_clear_title),
                                texts.t("pair.clear_confirm", R.string.pair_clear_confirm)) {
            confirmUnpair()
        })
    }

    /** Security v3 key state, the re-pair notice after an upgrade, and key rotation. */
    private fun sectionClusterSecurity(card: LinearLayout) {
        PairingModel.upgradeRejoinReason(pairing)?.let { reason ->
            card.row(rowNote(texts.t("pair.upgrade_rejoin", R.string.pair_upgrade_rejoin) +
                " · " + texts.t("pair.err_detail", R.string.pair_err_detail, reason)).apply {
                setTextColor(ShellUi.opaque(palette.danger))
            })
        }
        val security = PairingModel.security(pairing)
        if (security != null) {
            val notes = ArrayList<String>(3)
            if (security.rekeyRequired) notes.add(label("settings.item_rekey_required"))
            if (security.legacyPeers > 0)
                notes.add(label("settings.item_legacy_peers", security.legacyPeers.toString()))
            if (security.prevPskId.isNotEmpty() && security.prevPskUntilMs > 0L)
                notes.add(label("settings.item_prev_key", security.prevPskId,
                                clock.format(security.prevPskUntilMs).clockText()))
            card.row(ShellUi.row(this, palette, label("settings.item_cluster_key"),
                                 security.pskId.ifEmpty { "-" }, notes.joinToString(" · ")))
        }
    }

    /** The confirmation names the consequence and repeats the action on its button. */
    private fun confirmRotateKey() {
        ShellDialogBuilder(this)
            .setTitle(label("settings.item_rotate_key"))
            .setMessage(label("settings.item_rotate_key_confirm"))
            .setPositiveButton(label("settings.item_rotate_key")) { _, _ ->
                Thread({
                    val result = app.core.rotateClusterKey()
                    ui.post {
                        if (isFinishing) return@post
                        if (result == DoorbellCore.RESULT_ADMIN_REQUIRED) {
                            reauthenticateThen { app.core.rotateClusterKey() }
                            return@post
                        }
                        toast(if (result == 0) label("settings.item_rotate_key_started")
                              else texts.t("admin.save_failed", R.string.admin_save_failed))
                    }
                }, "doorbell-rotate-key").apply { isDaemon = true }.start()
            }
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
            .show()
    }

    /** Change the cluster administrator password (db_core_admin_password_set). */
    private fun changePassword() {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = ShellUi.dp(this@SettingsActivity, 24)
            setPadding(pad, ShellUi.dp(this@SettingsActivity, 8), pad, 0)
        }
        fun field(hintKey: String) = PlatformUi.field(
            this, label(hintKey),
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
        ).also {
            box.addView(it.view, ShellUi.matchWrap().apply {
                topMargin = ShellUi.dp(this@SettingsActivity, 8)
            })
        }
        val current = field("settings.item_password_current")
        val next = field("settings.item_password_new")
        val confirm = field("settings.item_password_confirm")
        ShellDialogBuilder(this)
            .setTitle(label("settings.item_password_change"))
            .setView(box)
            .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                val nextValue = next.text
                when (SettingsModel.checkNewPassword(nextValue, confirm.text)) {
                    PasswordCheck.TOO_SHORT, PasswordCheck.TOO_LONG ->
                        toast(label("settings.item_password_short"))
                    PasswordCheck.MISMATCH -> toast(label("settings.item_password_mismatch"))
                    PasswordCheck.OK -> {
                        val currentValue = current.text
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

    private fun sectionHistory() {
        val card = section(texts.t("history.title", R.string.history_title))
        card.row(ShellUi.row(
            this, palette, texts.t("dash.see_all", R.string.dash_see_all),
        ) { HistoryActivity.launch(this, app.boot.door) })
    }

    private fun sectionWebAdmin() {
        val card = section(texts.t("web_admin.open", R.string.web_admin_open))
        val pad = ShellUi.dp(this, 16)
        card.addView(
            AdminLinks.view(
                this, palette, app.core, AdminLinks.resolve(status, app.boot.httpPort),
                texts.t("web_admin.scan_hint", R.string.web_admin_scan_hint), 96,
            ).apply { setPadding(pad, pad, pad, pad) },
            ShellUi.matchWrap(),
        )
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
                texts.t("power.charging", R.string.power_charging),
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
        prefix == "settings.rotation_" ->
            if (option == "auto") label("admin.rotation_auto") else "$option°"
        else -> label(prefix + option).let { if (it == prefix + option) option else it }
    }

    private fun multiChoiceRow(spec: SettingSpec.MultiChoice, key: String, title: String): View {
        val current = SettingsModel.currentList(config, key, spec.default)
        val summary = current.joinToString(", ") {
            optionLabel(spec.optionKeyPrefix, "settings.sound_none", it)
        }
        return ShellUi.row(this, palette, title, summary, enabled = !readOnly) {
            val checked = BooleanArray(spec.options.size) { spec.options[it] in current }
            ShellDialogBuilder(this)
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

    /** A slider that writes once, when the finger lifts. */
    private fun sliderRow(
        spec: SettingSpec.IntRange,
        key: String,
        title: String,
        current: Int,
        note: String,
    ): View {
        val readout = ShellUi.label(this, current.coerceIn(spec.min, spec.max).toString(),
                                    TextRole.BODY, palette.muted)
        var slider: SliderHandle? = null
        slider = PlatformUi.slider(
            this, spec.min, spec.max, current, !readOnly,
            onChange = { readout.text = it.toString() },
            onCommit = { value ->
                val json = SettingsModel.encodeInt(spec, value.toString())
                if (json != null) write(key, json) { ok -> if (!ok) slider?.value = current }
            },
        )
        return sliderBlock(title, note, readout, slider.view)
    }

    /** Title with a live readout, an optional note, then the slider across the row. */
    private fun sliderBlock(title: String, note: String, readout: View, slider: View,
                            below: View? = null): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val padH = ShellUi.dp(this@SettingsActivity, 16)
            setPadding(padH, ShellUi.dp(this@SettingsActivity, 12), padH,
                       ShellUi.dp(this@SettingsActivity, 4))
            val header = LinearLayout(this@SettingsActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            header.addView(ShellUi.label(this@SettingsActivity, title, TextRole.BODY),
                           LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            header.addView(readout)
            addView(header, ShellUi.matchWrap())
            if (note.isNotEmpty())
                addView(ShellUi.label(this@SettingsActivity, note, TextRole.LABEL), ShellUi.matchWrap())
            addView(slider, ShellUi.matchWrap())
            if (below != null) addView(below, ShellUi.matchWrap())
        }

    /** Explanatory text inside a section, aligned with the rows around it. */
    internal fun rowNote(text: String): TextView =
        ShellUi.label(this, text, TextRole.SUPPORTING).apply {
            val padH = ShellUi.dp(this@SettingsActivity, 16)
            setPadding(padH, ShellUi.dp(this@SettingsActivity, 8), padH,
                       ShellUi.dp(this@SettingsActivity, 8))
        }

    /** A secondary action inside a section: a tonal button at the row inset. */
    internal fun rowAction(title: String, onClick: () -> Unit): View =
        LinearLayout(this).apply {
            val padH = ShellUi.dp(this@SettingsActivity, 16)
            setPadding(padH, ShellUi.dp(this@SettingsActivity, 4), padH,
                       ShellUi.dp(this@SettingsActivity, 12))
            addView(ShellUi.button(this@SettingsActivity, title, palette) { onClick() })
        }

    /** A dialog's single text field, inset to the dialog's content margin. */
    private fun dialogField(entry: FieldHandle, extra: View? = null): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = ShellUi.dp(this@SettingsActivity, 24)
            setPadding(pad, ShellUi.dp(this@SettingsActivity, 8), pad, 0)
            addView(entry.view, ShellUi.matchWrap())
            if (extra != null) addView(extra, ShellUi.matchWrap())
        }

    /** A time picker; [ops] turns the picked "HH:MM" into the batch to write (null = invalid). */
    internal fun timeRow(
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
    internal fun textRow(title: String, key: String, kind: TextKind, current: String,
                        note: String): View =
        ShellUi.row(this, palette, title,
                    current.ifEmpty { texts.t("settings.value_unset", R.string.settings_value_unset) },
                    note, enabled = !readOnly) {
            val field = PlatformUi.field(
                this, value = current,
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI,
            )
            ShellDialogBuilder(this)
                .setTitle(title)
                .setView(dialogField(field))
                .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                    val raw = field.text.trim()
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
    internal fun labelDialog(
        title: String,
        current: JSONObject?,
        extra: View? = null,
        onDelete: (() -> Unit)? = null,
        onSave: (Map<String, String>) -> Unit,
    ) {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = ShellUi.dp(this@SettingsActivity, 24)
            setPadding(pad, ShellUi.dp(this@SettingsActivity, 8), pad, 0)
        }
        val fields = SettingsModel.LANGUAGES.associateWith { lang ->
            PlatformUi.field(this, label("admin.label_$lang"),
                             current?.optString(lang).orEmpty()).also {
                box.addView(it.view, ShellUi.matchWrap().apply {
                    topMargin = ShellUi.dp(this@SettingsActivity, 8)
                })
            }
        }
        if (extra != null) box.addView(extra, ShellUi.matchWrap())
        val builder = ShellDialogBuilder(this)
            .setTitle(title)
            .setView(box)
            .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                onSave(fields.mapValues { it.value.text })
            }
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
        if (onDelete != null) builder.setNeutralButton(label("admin.delete")) { _, _ -> onDelete() }
        builder.show()
    }

    internal fun localizedLabel(labels: JSONObject?, fallback: String): String =
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
            val audio = reply.optJSONObject("audio")?.length() ?: 0
            val detail = listOfNotNull(
                if (speak) label("admin.qr_speak") else null,
                if (audio > 0) label("settings.item_reply_audio") else null,
            ).joinToString(" · ")
            card.row(ShellUi.row(
                this, palette, localizedLabel(labels, id), detail, enabled = !readOnly,
            ) { native.quickReplyMenu(id, reply) { editQuickReply(id, reply) } })
        }
        card.row(ShellUi.row(this, palette, label("admin.add_reply"), enabled = !readOnly) {
            editQuickReply(null, null)
        })
    }

    internal fun editQuickReply(id: String?, reply: JSONObject?) {
        val speak = PlatformUi.checkbox(this).apply {
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
            // Replace the whole entry so a removed language does not linger as a stale leaf, but
            // keep the per-language audio chosen in the reply's audio menu.
            val entry = JSONObject(json)
            reply?.optJSONObject("audio")?.let { entry.put("audio", it) }
            writeOps(listOf(ConfigOp.Set("quick_replies.$target", entry.toString())))
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
    internal fun writeOps(ops: List<ConfigOp>) {
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
            ShellDialogBuilder(this)
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

    internal fun toggleRow(
        title: String,
        key: String,
        value: Boolean,
        note: String = "",
    ): View {
        val toggle = PlatformUi.toggle(this).apply {
            isChecked = value
            isFocusable = true
            isEnabled = !readOnly
        }
        toggle.setOnCheckedChangeListener { _, checked ->
            write(key, if (checked) "true" else "false") { ok ->
                if (!ok) toggle.isChecked = !checked
            }
        }
        // The whole row toggles, as a settings switch row does.
        return ShellUi.row(this, palette, title, note = note, enabled = !readOnly,
                           trailing = toggle) { toggle.toggle() }
    }

    /** The dashboard still rate is this panel's own preference, so it bypasses core writes. */
    private fun previewRateRow(): View {
        val title = texts.t("dashboard.preview_rate_title", R.string.dashboard_preview_rate_title)
        fun label(rate: Double) = texts.t("dashboard.preview_rate_format",
            R.string.dashboard_preview_rate_format, PreviewRate.valueText(rate))
        return ShellUi.row(this, palette, title, label(PreviewRate.saved(this))) {
            ShellDialogBuilder(this)
                .setTitle(title)
                .setItems(PreviewRate.RATES.map { label(it) as CharSequence }.toTypedArray()) { _, which ->
                    PreviewRate.save(this, PreviewRate.RATES[which])
                    render()
                }
                .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
                .show()
        }
    }

    internal fun choiceRow(
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
        ShellDialogBuilder(this)
            .setTitle(title)
            .setItems(options.map { label(it) as CharSequence }.toTypedArray()) { _, which ->
                val chosen = options[which]
                // A numeric choice may still carry a word ("auto"), which is stored as a string.
                write(key, if (asNumber && chosen.toIntOrNull() != null) chosen
                           else JSONObject.quote(chosen)) { }
            }
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
            .show()
    }

    internal fun numberRow(title: String, key: String, current: Int, min: Int, max: Int): View =
        ShellUi.row(this, palette, title, current.toString(), enabled = !readOnly) {
            val field = PlatformUi.field(this, "$min – $max", current.toString(),
                                         InputType.TYPE_CLASS_NUMBER)
            ShellDialogBuilder(this)
                .setTitle(title)
                .setView(dialogField(field))
                .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                    val value = field.text.toIntOrNull()
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
            val field = PlatformUi.field(this, value = values.joinToString("\n"), lines = 2)
            ShellDialogBuilder(this)
                .setTitle(title)
                .setView(dialogField(field))
                .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                    val entries = field.text.split("\n")
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
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, ShellUi.dp(this@SettingsActivity, 8), 0, 0)
        }
        val searchEntry = PlatformUi.field(this, texts.t("time.zone", R.string.time_zone))
        val search = searchEntry.input
        val results = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        container.addView(searchEntry.view, ShellUi.matchWrap().apply {
            val margin = ShellUi.dp(this@SettingsActivity, 24)
            leftMargin = margin
            rightMargin = margin
        })
        container.addView(
            ScrollView(this).apply { addView(results) },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ShellUi.dp(this@SettingsActivity, 280),
            ),
        )
        val dialog = ShellDialogBuilder(this)
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
                ShellUi.matchWrap(),
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
        val readout = ShellUi.label(this, value.toString(), TextRole.BODY, palette.muted)
        val bar = PlatformUi.slider(
            this, 0, 100, value, !readOnly,
            onChange = { readout.text = it.toString() },
            onCommit = { write(deviceKey, it.toString()) { } },
        )
        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val inheritToggle = PlatformUi.toggle(this).apply {
            isChecked = inherited
            isFocusable = true
            isEnabled = !readOnly
        }
        inheritToggle.setOnCheckedChangeListener { _, checked ->
            if (checked) deleteKey(deviceKey) else write(deviceKey, bar.value.toString()) { }
        }
        actions.addView(inheritToggle)
        actions.addView(
            ShellUi.label(this, texts.t("volume.inherit", R.string.volume_inherit),
                          TextRole.SUPPORTING).apply {
                setPadding(ShellUi.dp(this@SettingsActivity, 12), 0, 0, 0)
                setOnClickListener { if (!readOnly) inheritToggle.toggle() }
            },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        actions.addView(ShellUi.button(
            this, texts.t("volume.preview", R.string.volume_preview), palette,
        ) { previewVolume(level, bar.value) })
        return sliderBlock(title, "", readout, bar.view, actions)
    }

    /**
     * A colour field never rejects the operator's value; it saves and shows the advisory WCAG
     * warning next to it when the contrast falls short (§5.2).
     */
    private fun colourRow(title: String, key: String, current: String): View {
        val warning = contrastWarning(current)
        return ShellUi.row(this, palette, title, current, warning, enabled = !readOnly) {
            val field = PlatformUi.field(this, "#RRGGBB", current)
            val advice = ShellUi.label(this, warning, TextRole.SUPPORTING, palette.warning).apply {
                setPadding(0, ShellUi.dp(this@SettingsActivity, 8), 0, 0)
            }
            val container = dialogField(field, advice)
            field.input.addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    advice.text = contrastWarning(s?.toString().orEmpty())
                }
            })
            ShellDialogBuilder(this)
                .setTitle(title)
                .setView(container)
                .setPositiveButton(texts.t("admin.save", R.string.admin_save)) { _, _ ->
                    val value = field.text.trim()
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

    internal fun write(key: String, valueJson: String, done: (Boolean) -> Unit) {
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

    internal fun deleteKey(key: String) {
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
        ShellDialogBuilder(this)
            .setTitle(texts.t("pair.clear_title", R.string.pair_clear_title))
            .setMessage(texts.t("pair.clear_confirm", R.string.pair_clear_confirm))
            .setPositiveButton(texts.t("pair.clear_title", R.string.pair_clear_title)) { _, _ ->
                // Leaving the cluster from the device itself is the same factory reset a
                // revocation performs: key, seeds, and the local identity all go.
                app.factoryResetClusterIdentity("admin_leave")
                finish()
            }
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
            .show()
    }

    internal fun currentString(key: String, fallback: String): String =
        app.core.dig(config, key)?.toString()?.takeIf { it.isNotEmpty() && it != "null" }
            ?: fallback

    private fun defaultVolume(level: String): Int = when (level) {
        "sos" -> 100
        "idle" -> 60
        else -> 80
    }

    internal fun doorIds(): List<String> {
        val doors = app.core.dig(config, "doors") as? JSONObject ?: return emptyList()
        return doors.keys().asSequence().sorted().toList()
    }

    internal fun doorLabel(door: String): String {
        if (door.isEmpty()) return ""
        val value = app.core.dig(config, "doors.$door.label.${texts.lang}")
            ?: app.core.dig(config, "doors.$door.label.ja")
        return value?.toString() ?: door
    }

    internal fun purposeLabel(purpose: String): String =
        VisitPurposes.label(config, purpose, texts.lang)

    internal fun roleLabel(role: String): String = when (role) {
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

    internal fun toast(message: String) {
        PlatformUi.toast(this, message)
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
