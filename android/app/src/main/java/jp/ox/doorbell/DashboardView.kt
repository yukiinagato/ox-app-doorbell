// The indoor dashboard (spec §4.1, review page A).
//
// Clock and date from the cluster clock, membership pill, missed badge, 管理 entry, door tiles with
// a five-second still and an announcement chip, a scrolling list of the last twenty calls with
// 「すべて見る」, a footer carrying the admin QR + URL and `name · core vX · app vY · battery`, the
// SOS slider and the 「お知らせ（全体）」 button. Portrait stacks the tiles above the call list;
// landscape puts them side by side. Framework views only.
package jp.ox.doorbell

import android.app.Activity
import android.graphics.Bitmap
import android.os.Handler
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import org.json.JSONObject

internal class DashboardView(
    private val activity: Activity,
    private val app: App,
    private val texts: Texts,
    private val ui: Handler,
) {

    val root: LinearLayout = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
    }

    private val clock = ClusterClock(app.core)
    private var palette: Palette = Palette.DARK
    private var config: JSONObject? = null
    private var status: JSONObject? = null
    private var nodeId = ""
    private var coreDisplay: CoreDisplay = CoreDisplay(null, null)

    private val clockText = ShellUi.text(activity, "", 40f, palette.ink)
    private val dateText = ShellUi.text(activity, "", 14f, palette.muted)
    private val membershipPill = ShellUi.pill(activity, "", palette.surfaceAlt, palette.muted)
    private val missedBadge = ShellUi.pill(activity, "", palette.dangerSoft, palette.dangerInk)
    private lateinit var adminButton: Button
    private lateinit var noticeButton: Button
    private lateinit var recentCallsHeading: TextView
    private lateinit var seeAllButton: Button
    private val tileColumn = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
    }
    private val callColumn = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
    }
    private val bodySplit = LinearLayout(activity).apply { isBaselineAligned = false }
    private val callList = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
    }
    private val footer = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        isBaselineAligned = false
    }
    private val versionText = ShellUi.text(activity, "", 11.5f, palette.muted)
    private val sosSlider = SosSlideView(activity, ui)

    private val stills = HashMap<String, ImageView>()
    private var lastRows: List<CallRow> = emptyList()
    private var unreadMissed = 0

    private val stillTick = object : Runnable {
        override fun run() {
            refreshStills()
            ui.postDelayed(this, STILL_INTERVAL_MS)
        }
    }

    init {
        build()
    }

    // ---------- lifecycle ----------

    fun onResume() {
        ui.removeCallbacks(stillTick)
        ui.post(stillTick)
        refresh()
    }

    fun onPause() {
        ui.removeCallbacks(stillTick)
        sosSlider.cancelCountdown()
    }

    fun onConfigurationChanged() {
        applyArrangement()
    }

    /** Redraw everything that depends on core state. Cheap enough for every relevant event. */
    fun refresh() {
        config = if (app.coreOk) app.core.config() else null
        status = if (app.coreOk) app.core.status() else null
        nodeId = status?.optJSONObject("node")?.optString("id").orEmpty()
        texts.setConfig(config)
        coreDisplay = CoreDisplays.parse(status?.optJSONObject("display"))
        val now = clock.now()
        // Core resolves the appearance in the cluster time zone; auto_system still consults the
        // platform, and an older core falls back to the local computation.
        val appearance = coreDisplay.appearance
        palette = if (appearance != null)
            Appearance.palette(CoreDisplays.isDark(appearance, systemDarkMode(activity)))
        else Appearance.resolve(config, nodeId, systemDarkMode(activity), now.minuteOfDay())
        applyPalette()
        updateClock(now)
        updateHeader()
        buildTiles()
        updateFooter()
        configureSos()
        loadCalls()
        applyArrangement()
    }

    /** Called once a second by the host so the clock keeps ticking without a full refresh. */
    fun tickClock() {
        updateClock(clock.now())
    }

    // ---------- construction ----------

    private fun build() {
        val pad = ShellUi.dp(activity, 14)
        root.setPadding(pad, pad, pad, pad)

        val header = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isBaselineAligned = false
        }
        val clockBox = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(clockText)
            addView(dateText)
        }
        header.addView(clockBox, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
        ))
        val headerActions = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        headerActions.addView(membershipPill, chipParams())
        headerActions.addView(missedBadge, chipParams())
        missedBadge.isFocusable = true
        missedBadge.isClickable = true
        missedBadge.setOnClickListener { HistoryActivity.launch(activity) }
        adminButton = ShellUi.button(
            activity, texts.t("admin.title", R.string.admin_title), palette,
        ) { SettingsActivity.open(activity, app, texts) }
        headerActions.addView(adminButton, chipParams())
        header.addView(headerActions)
        root.addView(header, ShellUi.matchWrap())

        bodySplit.addView(tileColumn, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ))
        bodySplit.addView(callColumn, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ))
        root.addView(bodySplit, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f,
        ))

        // Recent calls: twenty rows that scroll, with the full history one tap away.
        val callHeader = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isBaselineAligned = false
        }
        recentCallsHeading = ShellUi.text(
            activity, texts.t("dash.recent_calls", R.string.dash_recent_calls), 13f,
            palette.muted, bold = true,
        )
        callHeader.addView(
            recentCallsHeading,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        seeAllButton = ShellUi.button(
            activity, texts.t("dash.see_all", R.string.dash_see_all), palette,
        ) { HistoryActivity.launch(activity) }
        callHeader.addView(seeAllButton)
        callColumn.addView(callHeader, ShellUi.matchWrap())
        callColumn.addView(
            ScrollView(activity).apply {
                isFillViewport = true
                addView(callList, LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                ))
            },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f),
        )

        // Footer: the admin QR and address are always visible; opening the page still asks for
        // the 管理パスワード.
        root.addView(footer, ShellUi.matchWrap())
        root.addView(versionText, ShellUi.matchWrap())

        val actions = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isBaselineAligned = false
        }
        noticeButton = ShellUi.button(
            activity, texts.t("notice.global_button", R.string.notice_global_button), palette,
        ) { openNoticeDialog("") }
        actions.addView(noticeButton, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
        ))
        actions.addView(sosSlider, LinearLayout.LayoutParams(
            0, ShellUi.dp(activity, 56), 1f,
        ).apply { leftMargin = ShellUi.dp(activity, 8) })
        root.addView(actions, ShellUi.matchWrap().apply {
            topMargin = ShellUi.dp(activity, 8)
        })

        sosSlider.enabledProvider = { app.coreOk }
        sosSlider.onTrigger = { app.commitEmergency(true) }
    }

    private fun chipParams(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
    ).apply { leftMargin = ShellUi.dp(activity, 8) }

    // ---------- painting ----------

    private fun applyPalette() {
        root.setBackgroundColor(ShellUi.opaque(palette.ground))
        clockText.setTextColor(ShellUi.opaque(palette.ink))
        dateText.setTextColor(ShellUi.opaque(palette.muted))
        versionText.setTextColor(ShellUi.opaque(palette.muted))
        membershipPill.background = ShellUi.rounded(activity, palette.surfaceAlt, 999, palette.line)
        membershipPill.setTextColor(ShellUi.opaque(palette.muted))
        missedBadge.background = ShellUi.rounded(activity, palette.dangerSoft, 999)
        missedBadge.setTextColor(ShellUi.opaque(palette.dangerInk))
        adminButton.background = ShellUi.rounded(activity, palette.surfaceAlt, 10)
        adminButton.setTextColor(ShellUi.opaque(palette.ink))
        noticeButton.background = ShellUi.rounded(activity, palette.surfaceAlt, 10)
        noticeButton.setTextColor(ShellUi.opaque(palette.ink))
        recentCallsHeading.setTextColor(ShellUi.opaque(palette.muted))
        seeAllButton.background = ShellUi.rounded(activity, palette.surfaceAlt, 10)
        seeAllButton.setTextColor(ShellUi.opaque(palette.ink))
        sosSlider.applyPalette(palette)
        // Labels are reapplied here too, so a language change reaches the controls built once.
        adminButton.text = texts.t("admin.title", R.string.admin_title)
        noticeButton.text = texts.t("notice.global_button", R.string.notice_global_button)
        recentCallsHeading.text = texts.t("dash.recent_calls", R.string.dash_recent_calls)
        seeAllButton.text = texts.t("dash.see_all", R.string.dash_see_all)
    }

    private fun updateClock(now: ClusterTime) {
        clockText.text = now.clockText()
        dateText.text = dateLine(now)
    }

    private fun dateLine(now: ClusterTime): String {
        if (now.date.isEmpty()) return ""
        val parts = now.date.split("-")
        if (parts.size != 3) return now.date
        val weekday = WEEKDAYS.getOrElse(now.weekdayNum) { "" }
        return String.format(
            Locale.US, "%s-%s-%s%s", parts[0], parts[1], parts[2],
            if (weekday.isEmpty()) "" else " ($weekday)",
        )
    }

    private fun updateHeader() {
        val pairing = app.core.pairingInfo()
        membershipPill.text = listOf(
            texts.t("pair.membership", R.string.pair_membership,
                    PairingModel.memberCount(pairing).toString()),
            texts.t("pair.membership_connected", R.string.pair_membership_connected,
                    PairingModel.connectedCount(pairing).toString()),
        ).joinToString(" · ")
        missedBadge.text = texts.t("history.missed_badge", R.string.history_missed_badge,
                                   unreadMissed.toString())
        missedBadge.visibility = if (unreadMissed > 0) View.VISIBLE else View.GONE
    }

    private fun updateFooter() {
        footer.removeAllViews()
        footer.addView(
            AdminLinks.view(
                activity, palette, app.core, AdminLinks.resolve(status, app.boot.httpPort),
                texts.t("web_admin.scan_hint", R.string.web_admin_scan_hint), 56,
            ),
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        val power = status?.optJSONObject("self")?.optJSONObject("power")
        versionText.text = ShellUi.versionLine(
            app.boot.name,
            status?.optJSONObject("node")?.optString("version").orEmpty()
                .ifEmpty { app.core.version() },
            appVersion(),
            power?.optInt("battery_pct", -1) ?: -1,
            power?.optBoolean("charging", false) ?: false,
        ) { texts.t("power.percent", R.string.power_percent, it.toString()) }
    }

    private fun configureSos() {
        val countdown = SosSlideState.countdownFromConfig(config)
        sosSlider.configure(
            texts.t("sos.slide_label", R.string.sos_slide_label),
            texts.t("sos.slide_sub", R.string.sos_slide_sub, countdown.toString()),
            texts.t("sos.countdown_cancel", R.string.sos_countdown_cancel),
            countdown,
        ) { seconds -> texts.t("sos.countdown", R.string.sos_countdown, seconds.toString()) }
        sosSlider.visibility = if (sosVisible()) View.VISIBLE else View.GONE
    }

    /** emergency.button_on_roles decides whether this panel offers the slider at all. */
    private fun sosVisible(): Boolean {
        val roles = app.core.dig(config, "emergency.button_on_roles") as? org.json.JSONArray
            ?: return true
        for (index in 0 until roles.length())
            if (roles.optString(index) == app.boot.role) return true
        return roles.length() == 0
    }

    // ---------- door tiles ----------

    private fun buildTiles() {
        tileColumn.removeAllViews()
        stills.clear()
        tileColumn.addView(
            ShellUi.sectionHeading(activity, palette,
                                   texts.t("settings.doors", R.string.settings_doors)),
            ShellUi.matchWrap(),
        )
        val doors = doorIds()
        if (doors.isEmpty()) {
            tileColumn.addView(
                ShellUi.text(activity, texts.t("dash.no_doors", R.string.dash_no_doors), 14f,
                             palette.muted),
                ShellUi.matchWrap(),
            )
            return
        }
        val nowMs = clock.now().wallMs
        for (door in doors) tileColumn.addView(
            tileView(door, NoticeModel.resolve(status, config, door, nowMs)),
            ShellUi.matchWrap().apply { topMargin = ShellUi.dp(activity, 8) },
        )
    }

    private fun tileView(door: String, notice: Notice?): View {
        val peer = doorPeer(door)
        val online = peer != null && peer.optString("status") != "dead"
        val card = ShellUi.card(activity, palette)
        card.isFocusable = true
        card.isClickable = true
        card.setOnClickListener {
            IncomingActivity.launch(activity, door)
        }

        val still = ImageView(activity).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = ShellUi.rounded(activity, palette.surfaceAlt, 8)
            contentDescription = doorLabel(door)
        }
        stills[door] = still
        card.addView(still, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ShellUi.dp(activity, 120),
        ))

        val chips = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, ShellUi.dp(activity, 6), 0, 0)
        }
        if (notice != null) {
            // The status chip is compact, with a dot when an announcement is showing (§5.2).
            val chip = ShellUi.pill(
                activity, "● " + texts.t("notice.active", R.string.notice_active),
                palette.noticeBg, palette.noticeInk,
            )
            chip.isFocusable = true
            chip.isClickable = true
            chip.setOnClickListener { openNoticeDialog(door) }
            chips.addView(chip)
        }
        if (!online) chips.addView(
            ShellUi.pill(activity, texts.t("dash.tile_offline", R.string.dash_tile_offline),
                         palette.surfaceAlt, palette.muted),
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { leftMargin = ShellUi.dp(activity, 6) },
        )
        card.addView(chips, ShellUi.matchWrap())

        val caption = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isBaselineAligned = false
            setPadding(0, ShellUi.dp(activity, 6), 0, 0)
        }
        caption.addView(
            ShellUi.text(activity, doorLabel(door), 16f, palette.ink, bold = true),
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        caption.addView(ShellUi.text(
            activity, texts.t("dash.tile_open", R.string.dash_tile_open), 13f, palette.accent,
        ))
        card.addView(caption, ShellUi.matchWrap())
        if (notice != null) card.addView(
            ShellUi.text(activity, notice.text, 13f, palette.muted).apply {
                maxLines = 2
                ellipsize = android.text.TextUtils.TruncateAt.END
            },
            ShellUi.matchWrap(),
        )
        return card
    }

    /** Live stills refresh every five seconds; a failure simply leaves the previous frame. */
    private fun refreshStills() {
        if (stills.isEmpty()) return
        val targets = stills.keys.toList()
        Thread({
            for (door in targets) {
                val peer = doorPeer(door) ?: continue
                val snapshot = peer.optString("snapshot").ifEmpty {
                    val stream = peer.optString("stream")
                    if (stream.isEmpty()) "" else stream.substringBeforeLast('/') + "/snapshot.jpg"
                }
                if (snapshot.isEmpty()) continue
                val bitmap = fetchStill(snapshot) ?: continue
                ui.post { stills[door]?.setImageBitmap(bitmap) }
            }
        }, "doorbell-tiles").apply { isDaemon = true }.start()
    }

    private fun fetchStill(url: String): Bitmap? {
        var connection: HttpURLConnection? = null
        return try {
            connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = 2000
            connection.readTimeout = 3000
            val bytes = BoundedBitmapDecoder.readLimited(connection.inputStream, 2 * 1024 * 1024)
            bytes?.let { BoundedBitmapDecoder.decode(it, 640, 480) }
        } catch (_: Exception) {
            null
        } finally {
            try { connection?.disconnect() } catch (_: Exception) { }
        }
    }

    // ---------- recent calls ----------

    private fun loadCalls() {
        if (!app.coreOk) return
        Thread({
            val document = app.core.callLog(0L, CallHistoryModel.DASHBOARD_ROWS)
            val rows = CallHistoryModel.parse(document)
            val missed = CallHistoryModel.unreadMissed(document)
            ui.post {
                lastRows = rows
                unreadMissed = missed
                updateHeader()
                renderCalls()
            }
        }, "doorbell-dashboard-calls").apply { isDaemon = true }.start()
    }

    private fun renderCalls() {
        callList.removeAllViews()
        if (lastRows.isEmpty()) {
            callList.addView(
                ShellUi.text(activity, texts.t("history.empty", R.string.history_empty), 14f,
                             palette.muted),
                ShellUi.matchWrap(),
            )
            return
        }
        for (row in lastRows.take(CallHistoryModel.DASHBOARD_ROWS)) {
            val line = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                isBaselineAligned = false
                minimumHeight = ShellUi.dp(activity, ShellUi.TOUCH_FLOOR_DP)
                setPadding(0, ShellUi.dp(activity, 4), 0, ShellUi.dp(activity, 4))
            }
            val time = clock.format(row.tsMs)
            line.addView(
                ShellUi.text(activity,
                             String.format(Locale.US, "%02d:%02d", time.hour, time.minute),
                             12.5f, palette.muted),
                LinearLayout.LayoutParams(
                    ShellUi.dp(activity, 44), ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
            val label = StringBuilder(doorLabel(row.door))
            if (row.purpose.isNotEmpty()) label.append(" · ").append(purposeLabel(row.purpose))
            line.addView(
                ShellUi.text(activity, label.toString(), 13.5f,
                             if (row.missed) palette.dangerInk else palette.ink),
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
            )
            line.addView(ShellUi.text(activity, outcomeText(row), 12.5f, palette.muted))
            callList.addView(line, ShellUi.matchWrap())
        }
    }

    private fun outcomeText(row: CallRow): String = when (row.outcome) {
        "missed" -> texts.t("history.outcome_missed", R.string.history_outcome_missed)
        "answered" -> texts.t("history.outcome_answered", R.string.history_outcome_answered)
        "replied" -> texts.t("history.outcome_replied", R.string.history_outcome_replied)
        else -> texts.t("history.outcome_cancelled", R.string.history_outcome_cancelled)
    }

    // ---------- layout ----------

    /** Portrait stacks tiles above the call list; landscape puts them side by side. */
    private fun applyArrangement() {
        val metrics = activity.resources.displayMetrics
        val widthDp = (metrics.widthPixels / metrics.density).toInt()
        val heightDp = (metrics.heightPixels / metrics.density).toInt()
        val side = widthDp > heightDp && widthDp >= 600
        bodySplit.orientation = if (side) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
        val tileParams = tileColumn.layoutParams as LinearLayout.LayoutParams
        val callParams = callColumn.layoutParams as LinearLayout.LayoutParams
        if (side) {
            tileParams.width = 0
            tileParams.height = ViewGroup.LayoutParams.MATCH_PARENT
            tileParams.weight = 1.1f
            callParams.width = 0
            callParams.height = ViewGroup.LayoutParams.MATCH_PARENT
            callParams.weight = 1f
            callParams.leftMargin = ShellUi.dp(activity, 12)
        } else {
            tileParams.width = ViewGroup.LayoutParams.MATCH_PARENT
            tileParams.height = ViewGroup.LayoutParams.WRAP_CONTENT
            tileParams.weight = 0f
            callParams.width = ViewGroup.LayoutParams.MATCH_PARENT
            callParams.height = 0
            callParams.weight = 1f
            callParams.leftMargin = 0
        }
        tileColumn.layoutParams = tileParams
        callColumn.layoutParams = callParams
    }

    // ---------- helpers ----------

    private fun openNoticeDialog(door: String) {
        NoticeDialog.show(activity, app, texts, palette, door, doorIds(), ::doorLabel) {
            refresh()
        }
    }

    private fun doorIds(): List<String> {
        val doors = app.core.dig(config, "doors") as? JSONObject ?: return emptyList()
        return doors.keys().asSequence().sorted().toList()
    }

    private fun doorPeer(door: String): JSONObject? {
        val peers = status?.optJSONArray("peers") ?: return null
        for (index in 0 until peers.length()) {
            val peer = peers.optJSONObject(index) ?: continue
            if (peer.optString("role") != "door_station") continue
            if (peer.optString("door") != door) continue
            return peer
        }
        return null
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

    private fun appVersion(): String = try {
        activity.packageManager.getPackageInfo(activity.packageName, 0).versionName.orEmpty()
    } catch (_: Exception) {
        ""
    }

    private companion object {
        const val STILL_INTERVAL_MS = 5_000L
        val WEEKDAYS = arrayOf("日", "月", "火", "水", "木", "金", "土")
    }
}
