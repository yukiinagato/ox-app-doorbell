// The full-screen call history reached from the dashboard's 「すべて見る」 (spec §5.1).
//
// Fifty rows per page with 「さらに読み込む」, grouped by cluster-local day, filtered by
// all / missed / one door, and marked seen on open so the dashboard's 不在着信 badge clears.
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

    private fun resolvePalette(): Palette = Appearance.resolve(
        config,
        app.core.status()?.optJSONObject("node")?.optString("id").orEmpty(),
        systemDarkMode(this),
        clock.now().minuteOfDay(),
    )

    private fun buildUi(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(ShellUi.opaque(palette.ground))
            val pad = ShellUi.dp(this@HistoryActivity, 16)
            setPadding(pad, pad, pad, pad)
        }
        root.addView(
            ShellUi.text(this, texts.t("history.title", R.string.history_title), 22f,
                         palette.ink, bold = true),
            ShellUi.matchWrap(),
        )

        filterRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, ShellUi.dp(this@HistoryActivity, 10), 0,
                       ShellUi.dp(this@HistoryActivity, 6))
        }
        root.addView(filterRow, ShellUi.matchWrap())

        listView = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            addView(listView, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ))
        }
        root.addView(scroll, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f,
        ))

        moreButton = ShellUi.button(
            this, texts.t("history.load_more", R.string.history_load_more), palette,
        ) { loadMore() }
        root.addView(moreButton, ShellUi.matchWrap().apply {
            topMargin = ShellUi.dp(this@HistoryActivity, 8)
        })

        root.addView(
            ShellUi.button(this, texts.t("admin.menu_close", R.string.admin_menu_close),
                           palette) { finish() },
            ShellUi.matchWrap().apply { topMargin = ShellUi.dp(this@HistoryActivity, 6) },
        )
        buildFilters()
        return root
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
            val button = ShellUi.button(this, label, palette, primary = on) {
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
        if (visible.isEmpty()) {
            listView.addView(
                ShellUi.text(this, texts.t("history.empty", R.string.history_empty), 15f,
                             palette.muted),
                ShellUi.matchWrap(),
            )
            return
        }
        val today = clock.now().date
        for (group in CallHistoryModel.group(visible) { clock.dayKey(it) }) {
            listView.addView(
                ShellUi.sectionHeading(this, palette, dayHeading(group.dayKey, today)),
                ShellUi.matchWrap(),
            )
            val card = ShellUi.card(this, palette)
            for (row in group.rows) card.addView(rowView(row), ShellUi.matchWrap())
            listView.addView(card, ShellUi.matchWrap())
        }
    }

    private fun rowView(row: CallRow): View {
        val line = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ShellUi.dp(this@HistoryActivity, ShellUi.TOUCH_FLOOR_DP)
            setPadding(0, ShellUi.dp(this@HistoryActivity, 6), 0,
                       ShellUi.dp(this@HistoryActivity, 6))
        }
        val time = clock.format(row.tsMs)
        line.addView(
            ShellUi.text(this, String.format(Locale.US, "%02d:%02d", time.hour, time.minute),
                         13f, palette.muted),
            LinearLayout.LayoutParams(
                ShellUi.dp(this, 48), ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        val middle = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val title = StringBuilder(doorLabel(row.door))
        if (row.purpose.isNotEmpty()) title.append(" · ").append(purposeLabel(row.purpose))
        middle.addView(ShellUi.text(this, title.toString(), 14.5f, palette.ink))
        val detail = ArrayList<String>(2)
        if (row.answeredBy.isNotEmpty())
            detail.add(texts.t("history.answered_by", R.string.history_answered_by,
                               row.answeredBy))
        val duration = CallHistoryModel.durationText(row.durationMs)
        if (duration.isNotEmpty())
            detail.add(texts.t("history.duration", R.string.history_duration, duration))
        if (detail.isNotEmpty())
            middle.addView(ShellUi.text(this, detail.joinToString(" · "), 12.5f, palette.muted))
        line.addView(middle, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
        ))
        line.addView(outcomePill(row))
        return line
    }

    private fun outcomePill(row: CallRow): View {
        val (label, background, ink) = when (row.outcome) {
            "missed" -> Triple(
                texts.t("history.outcome_missed", R.string.history_outcome_missed),
                palette.dangerSoft, palette.dangerInk,
            )
            "answered" -> Triple(
                texts.t("history.outcome_answered", R.string.history_outcome_answered),
                palette.okSoft, palette.okInk,
            )
            "replied" -> Triple(
                texts.t("history.outcome_replied", R.string.history_outcome_replied),
                palette.surfaceAlt, palette.muted,
            )
            else -> Triple(
                texts.t("history.outcome_cancelled", R.string.history_outcome_cancelled),
                palette.surfaceAlt, palette.muted,
            )
        }
        return ShellUi.pill(this, label, background, ink)
    }

    private fun dayHeading(dayKey: String, today: String): String {
        if (dayKey == today) return texts.t("history.today", R.string.history_today)
        val yesterday = clock.format(clock.now().wallMs - 86_400_000L).date
        if (dayKey == yesterday) return texts.t("history.yesterday", R.string.history_yesterday)
        return dayKey
    }

    private fun doorLabel(door: String): String {
        if (door.isEmpty()) return ""
        val value = app.core.dig(config, "doors.$door.label.${texts.lang}")
            ?: app.core.dig(config, "doors.$door.label.ja")
        return value?.toString() ?: door
    }

    private fun purposeLabel(purpose: String): String {
        val entry = app.core.dig(config, "visit_purposes.$purpose") as? JSONObject
            ?: return purpose
        val labels = entry.optJSONObject("label") ?: return purpose
        val value = labels.optString(texts.lang)
        if (value.isNotEmpty()) return value
        return labels.optString("ja").ifEmpty { purpose }
    }

    companion object {
        private const val EXTRA_DOOR = "door"

        fun launch(context: Context, door: String = "") {
            try {
                context.startActivity(
                    Intent(context, HistoryActivity::class.java).putExtra(EXTRA_DOOR, door),
                )
            } catch (_: Exception) { }
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
