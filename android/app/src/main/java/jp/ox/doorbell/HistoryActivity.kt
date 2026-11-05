// The full-screen call history reached from the dashboard's 「すべて見る」 (spec §5.1).
//
// Fifty rows per page with 「さらに読み込む」, grouped by cluster-local day, filtered by
// all / missed / one door, and marked seen on open so the dashboard's 不在着信 badge clears.
// Each row carries its outcome icon and an unread mark; from 600 dp the detail sits beside the
// list, below that it opens in a bottom sheet (docs/en/ui-guidelines.md, "History").
package jp.ox.doorbell

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import java.util.Locale
import org.json.JSONObject

class HistoryActivity : Activity(), DoorbellCore.Listener {

    private val ui = Handler(Looper.getMainLooper())
    private lateinit var app: App
    private lateinit var texts: Texts
    private lateinit var clock: ClusterClock
    private lateinit var palette: Palette
    private lateinit var listView: LinearLayout
    private lateinit var filterRow: LinearLayout
    private lateinit var moreButton: Button

    private var config: JSONObject? = null
    private var filter = HistoryFilter.ALL
    private var doorFilter = ""
    private var pages = 1
    private var rows: List<CallRow> = emptyList()
    private var hasMore = false
    private var twoPane = false
    private var roles: UiRoles = UiRoles.from(Palette.DARK)
    private lateinit var frame: FrameLayout
    private var detailPane: LinearLayout? = null
    private var sheet: UiKit.Sheet? = null

    /** The call shown in the detail pane or sheet; kept across reloads while it is listed. */
    private var selectedId = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        texts = Texts(this)
        clock = ClusterClock(app.core)
        config = if (app.coreOk) app.core.config() else null
        texts.setConfig(config)
        texts.setLang(app.boot.uiLang)
        doorFilter = intent?.getStringExtra(EXTRA_DOOR).orEmpty()
        if (doorFilter.isNotEmpty()) filter = HistoryFilter.DOOR
        palette = resolvePalette()
        setContentView(buildUi())
        reload(markSeen = true)
    }

    override fun onResume() {
        super.onResume()
        app.bindForeground(this)
    }

    override fun onPause() {
        app.unbindForeground(this)
        super.onPause()
    }

    override fun onUiEvent(ev: JSONObject) {
        val type = ev.optString("t")
        if (type != "call_log_changed" && type != "config_changed" && type != "time_changed")
            return
        ui.post {
            if (isFinishing) return@post
            if (type == "config_changed") {
                config = app.core.config()
                texts.setConfig(config)
            }
            reload(markSeen = false)
        }
    }

    override fun onTts(text: String, lang: String) {}

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        val open = sheet
        if (open != null && open.showing) open.dismiss() else super.onBackPressed()
    }

    private fun resolvePalette(): Palette = Appearance.resolve(
        config,
        app.core.status()?.optJSONObject("node")?.optString("id").orEmpty(),
        systemDarkMode(this),
        clock.now().minuteOfDay(),
    )

    private fun buildUi(): View {
        val window = UiKit.window(this)
        twoPane = ScreenLayouts.historyTwoPane(window)
        roles = UiRoles.from(palette)
        frame = FrameLayout(this).apply { setBackgroundColor(ShellUi.opaque(palette.ground)) }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_L)
            setPadding(pad, pad, pad, pad)
        }
        frame.addView(root, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
        ))
        // Title bar: the back action sits where the eye starts, then the title.
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        bar.addView(UiKit.actionButton(
            this, texts.t("admin.menu_close", R.string.admin_menu_close), roles, ActionRole.SECONDARY,
        ) { finish() })
        bar.addView(
            UiKit.text(this, texts.t("history.title", R.string.history_title), UiTokens.HEADLINE,
                       palette.ink, bold = true).apply { maxLines = 2 },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                leftMargin = ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_M)
            },
        )
        root.addView(bar, ShellUi.matchWrap())

        filterRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_M), 0,
                       ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_S))
        }
        root.addView(filterRow, ShellUi.matchWrap())

        val listColumn = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        listView = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            addView(listView, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ))
        }
        listColumn.addView(scroll, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f,
        ))
        moreButton = UiKit.actionButton(
            this, texts.t("history.load_more", R.string.history_load_more), roles,
            ActionRole.SECONDARY,
        ) { loadMore() }
        listColumn.addView(moreButton, ShellUi.matchWrap().apply {
            topMargin = ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_S)
        })

        if (twoPane) {
            // Expanded: list left, detail right (guidelines "History").
            val split = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                isBaselineAligned = false
            }
            split.addView(listColumn, LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.MATCH_PARENT, 0.45f,
            ))
            detailPane = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
            split.addView(ScrollView(this).apply {
                addView(detailPane, LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                ))
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 0.55f).apply {
                leftMargin = ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_L)
            })
            root.addView(split, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f,
            ))
        } else {
            detailPane = null
            root.addView(listColumn, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f,
            ))
        }
        buildFilters()
        return frame
    }

    private fun buildFilters() {
        filterRow.removeAllViews()
        val entries = ArrayList<Pair<HistoryFilter, String>>(3)
        entries.add(HistoryFilter.ALL to
            texts.t("history.filter_all", R.string.history_filter_all))
        entries.add(HistoryFilter.MISSED to
            texts.t("history.filter_missed", R.string.history_filter_missed))
        if (doorFilter.isNotEmpty())
            entries.add(HistoryFilter.DOOR to texts.t(
                "history.filter_door", R.string.history_filter_door, doorLabel(doorFilter),
            ))
        for ((value, label) in entries) {
            val on = value == filter
            val button = UiKit.actionButton(
                this, label, roles, if (on) ActionRole.PRIMARY else ActionRole.SECONDARY,
            ) {
                filter = value
                pages = 1
                buildFilters()
                render()
            }
            filterRow.addView(button, LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
            ).apply { rightMargin = ShellUi.dp(this@HistoryActivity, 6) })
        }
    }

    /** Core snapshots take the run loop, so history is fetched off the main thread. */
    private fun reload(markSeen: Boolean) {
        if (!app.coreOk) {
            render()
            return
        }
        // With before_ms paging the first page is just the newest fifty rows; without it the v1
        // call has no upper bound, so the whole prefix is fetched and sliced.
        val paged = app.core.exports.callLogV2
        val limit = if (paged) CallHistoryModel.PAGE_SIZE
            else CallHistoryModel.requestLimit(pages)
        Thread({
            val document = app.core.callLog(0L, 0L, limit)
            val parsed = CallHistoryModel.parse(document)
            if (markSeen) app.core.callLogMarkSeen(CallHistoryModel.newestHlc(parsed))
            ui.post {
                if (isFinishing) return@post
                if (paged) {
                    hasMore = CallHistoryModel.hasMoreAfterPage(parsed.size, limit)
                    rows = parsed
                } else {
                    hasMore = CallHistoryModel.hasMore(parsed.size, pages)
                    rows = CallHistoryModel.page(parsed, pages)
                }
                render()
            }
        }, "doorbell-history").apply { isDaemon = true }.start()
    }

    /** 「さらに読み込む」: one more page, continuing from the oldest row already shown. */
    private fun loadMore() {
        if (!app.coreOk || !hasMore) return
        if (!app.core.exports.callLogV2) {
            pages += 1
            reload(markSeen = false)
            return
        }
        val before = CallHistoryModel.beforeMs(rows)
        if (before <= 0L) return
        moreButton.isEnabled = false
        val limit = CallHistoryModel.PAGE_SIZE
        Thread({
            val document = app.core.callLog(0L, before, limit)
            val page = CallHistoryModel.parse(document)
            ui.post {
                if (isFinishing) return@post
                moreButton.isEnabled = true
                hasMore = CallHistoryModel.hasMoreAfterPage(page.size, limit)
                rows = CallHistoryModel.append(rows, page)
                render()
            }
        }, "doorbell-history-page").apply { isDaemon = true }.start()
    }

    private fun render() {
        listView.removeAllViews()
        val visible = CallHistoryModel.filter(rows, filter, doorFilter)
        moreButton.visibility = if (hasMore) View.VISIBLE else View.GONE
        val shown = HistoryModel.selection(visible, selectedId, twoPane)
        selectedId = shown?.id.orEmpty()
        if (visible.isEmpty()) {
            listView.addView(
                UiKit.text(this, texts.t("history.empty", R.string.history_empty), UiTokens.BODY,
                           palette.muted),
                ShellUi.matchWrap(),
            )
            renderDetail(null)
            return
        }
        val today = clock.now().date
        for (group in CallHistoryModel.group(visible) { clock.dayKey(it) }) {
            listView.addView(UiKit.groupHeader(this, roles, dayHeading(group.dayKey, today)),
                             ShellUi.matchWrap())
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                background = ShellUi.rounded(this@HistoryActivity, palette.surface,
                                             UiTokens.RADIUS_CARD, palette.line)
                val pad = ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_S)
                setPadding(pad, pad / 2, pad, pad / 2)
            }
            for (row in group.rows) card.addView(rowView(row, row.id == selectedId && twoPane),
                                                 ShellUi.matchWrap())
            listView.addView(card, ShellUi.matchWrap())
        }
        renderDetail(shown)
    }

    private fun rowView(row: CallRow, selected: Boolean): View {
        val outcome = CallOutcome.of(row.outcome)
        val line = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isBaselineAligned = false
            minimumHeight = ShellUi.dp(this@HistoryActivity, UiTokens.TOUCH_MIN_DP + UiTokens.SPACE_S)
            val pad = ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_S)
            setPadding(pad, pad, pad, pad)
            isClickable = true
            isFocusable = true
            if (selected) background = ShellUi.rounded(this@HistoryActivity, palette.surfaceAlt,
                                                       UiTokens.RADIUS_CARD, roles.accent)
            setOnClickListener { select(row) }
        }
        line.addView(ImageView(this).apply {
            setImageResource(UiKit.outcomeIcon(outcome))
            setColorFilter(ShellUi.opaque(roles.tint(outcome.role)))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(ShellUi.dp(this, 24), ShellUi.dp(this, 24)).apply {
            rightMargin = ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_M)
        })
        val time = clock.format(row.tsMs)
        val clockText = String.format(Locale.US, "%02d:%02d", time.hour, time.minute)
        line.addView(
            UiKit.text(this, clockText, UiTokens.CAPTION, palette.muted),
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT,
                                      ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                rightMargin = ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_M)
            },
        )
        val middle = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val title = titleOf(row)
        val unread = HistoryModel.unread(row)
        middle.addView(UiKit.text(this, title, UiTokens.BODY,
                                  if (row.missed) palette.dangerInk else palette.ink,
                                  bold = unread).apply { maxLines = 2 })
        val outcomeLabel = UiKit.outcomeLabel(texts, outcome)
        middle.addView(UiKit.text(this, outcomeLabel, UiTokens.CAPTION, palette.muted))
        line.addView(middle, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
        ))
        if (unread) line.addView(ShellUi.pill(
            this, texts.t("history.unread", R.string.history_unread), roles.negative,
            roles.onNegative, UiTokens.sp(UiTokens.CAPTION),
        ))
        line.contentDescription = listOf(clockText, title, outcomeLabel,
            if (unread) texts.t("history.unread", R.string.history_unread) else "")
            .filter { it.isNotEmpty() }.joinToString(", ")
        return line
    }

    private fun titleOf(row: CallRow): String {
        val title = StringBuilder(doorLabel(row.door))
        if (row.purpose.isNotEmpty()) title.append(" · ").append(purposeLabel(row.purpose))
        return title.toString()
    }

    /** Two panes: show it on the right. One pane: show it in a sheet over the list. */
    private fun select(row: CallRow) {
        selectedId = row.id
        if (twoPane) {
            render()
            return
        }
        sheet?.dismiss()
        val next = UiKit.Sheet(frame, roles, atSide = false) { sheet = null }
        fillDetail(next.panel, row)
        sheet = next
        next.show()
    }

    private fun renderDetail(row: CallRow?) {
        val pane = detailPane ?: return
        pane.removeAllViews()
        if (row == null) {
            pane.addView(UiKit.text(this, texts.t("history.select_call", R.string.history_select_call),
                                    UiTokens.BODY, palette.muted).apply {
                gravity = Gravity.CENTER
                setPadding(0, ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_XXXL), 0, 0)
            }, ShellUi.matchWrap())
            return
        }
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = ShellUi.rounded(this@HistoryActivity, palette.surface,
                                         UiTokens.RADIUS_CARD, palette.line)
            val pad = ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_L)
            setPadding(pad, pad, pad, pad)
        }
        fillDetail(card, row)
        pane.addView(card, ShellUi.matchWrap())
    }

    /** One call's detail: what happened, when, who answered, and a way to look at the door now. */
    private fun fillDetail(target: LinearLayout, row: CallRow) {
        val outcome = CallOutcome.of(row.outcome)
        val time = clock.format(row.tsMs)
        val head = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        head.addView(ImageView(this).apply {
            setImageResource(UiKit.outcomeIcon(outcome))
            setColorFilter(ShellUi.opaque(roles.tint(outcome.role)))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(ShellUi.dp(this, 32), ShellUi.dp(this, 32)).apply {
            rightMargin = ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_M)
        })
        head.addView(UiKit.text(this, titleOf(row), UiTokens.TITLE, palette.ink, bold = true)
                         .apply { maxLines = 3 },
                     LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        target.addView(head, ShellUi.matchWrap())
        val facts = ArrayList<String>(4)
        facts.add(String.format(Locale.US, "%s %02d:%02d", time.date, time.hour, time.minute))
        facts.add(UiKit.outcomeLabel(texts, outcome))
        if (row.answeredBy.isNotEmpty())
            facts.add(texts.t("history.answered_by", R.string.history_answered_by,
                              deviceName(row.answeredBy)))
        val duration = CallHistoryModel.durationText(row.durationMs)
        if (duration.isNotEmpty())
            facts.add(texts.t("history.duration", R.string.history_duration, duration))
        for (fact in facts) target.addView(
            UiKit.text(this, fact, UiTokens.BODY, palette.muted).apply {
                setPadding(0, ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_S), 0, 0)
            }, ShellUi.matchWrap(),
        )
        if (row.door.isNotEmpty()) target.addView(
            UiKit.actionButton(this, texts.t("nav.monitor", R.string.nav_monitor), roles,
                               ActionRole.PRIMARY) { IncomingActivity.launch(this, row.door) },
            ShellUi.matchWrap().apply { topMargin = ShellUi.dp(this@HistoryActivity, UiTokens.SPACE_L) },
        )
    }

    private fun dayHeading(dayKey: String, today: String): String {
        if (dayKey == today) return texts.t("history.today", R.string.history_today)
        val yesterday = clock.format(clock.now().wallMs - 86_400_000L).date
        if (dayKey == yesterday) return texts.t("history.yesterday", R.string.history_yesterday)
        return dayKey
    }

    /** answered_by is a node id; a resident needs the device's name, not its hash. */
    private fun deviceName(nodeId: String): String {
        if (nodeId.isEmpty()) return ""
        val name = app.core.dig(config, "devices.$nodeId.name")?.toString().orEmpty()
        if (name.isNotEmpty()) return name
        // Nothing configured for it: a short prefix beats a full 32-character hash.
        return if (nodeId.length > 8) nodeId.substring(0, 8) else nodeId
    }

    private fun doorLabel(door: String): String {
        if (door.isEmpty()) return ""
        val value = app.core.dig(config, "doors.$door.label.${texts.lang}")
            ?: app.core.dig(config, "doors.$door.label.ja")
        return value?.toString() ?: door
    }

    /** A recorded call keeps the purpose the visitor chose, even once it has been disabled. */
    private fun purposeLabel(purpose: String): String =
        VisitPurposes.label(config, purpose, texts.lang)

    companion object {
        private const val EXTRA_DOOR = "door"

        fun launch(context: Context, door: String = "") {
            try {
                context.startActivity(
                    Intent(context, HistoryActivity::class.java).putExtra(EXTRA_DOOR, door),
                )
            } catch (e: Exception) { ShellLog.ignored("HistoryActivity", e) }
        }

        /**
         * Android's own dark mode, or null below API 29 where the platform has none and the
         * appearance falls back to the cluster schedule.
         */
        fun systemDarkMode(context: Context): Boolean? {
            if (android.os.Build.VERSION.SDK_INT < 29) return null
            val mode = context.resources.configuration.uiMode and
                android.content.res.Configuration.UI_MODE_NIGHT_MASK
            return when (mode) {
                android.content.res.Configuration.UI_MODE_NIGHT_YES -> true
                android.content.res.Configuration.UI_MODE_NIGHT_NO -> false
                else -> null
            }
        }
    }
}

/** Shared shorthand so every screen resolves the system appearance the same way. */
internal fun systemDarkMode(context: Context): Boolean? =
    HistoryActivity.systemDarkMode(context)
