// The dashboard's recent calls (docs/en/ui-guidelines.md, "Dashboard" and "History"): the last
// rows of the call log on a scrim card, each with its outcome icon, and the full history one tap
// away. Split out of DashboardView.
package jp.ox.doorbell

import android.app.Activity
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.util.Locale

internal class RecentCallsPanel(
    private val activity: Activity,
    private val texts: Texts,
    private val clock: ClusterClock,
    private val doorLabel: (String) -> String,
    private val purposeLabel: (String) -> String,
) {
    val root: LinearLayout = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }

    /** Sits on the frame, so the dashboard paints its ink with the other frame regions. */
    val heading: TextView
    private val seeAll: Button
    private val list = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private val scroll: ScrollView
    private var rendered: Any? = null

    init {
        val header = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isBaselineAligned = false
        }
        heading = ShellUi.text(
            activity, texts.t("dash.recent_calls", R.string.dash_recent_calls),
            UiTokens.sp(UiTokens.CAPTION), Palette.DARK.muted, bold = true,
        ).apply {
            setPadding(
                ShellUi.dp(activity, UiTokens.SPACE_XS), ShellUi.dp(activity, UiTokens.SPACE_L),
                ShellUi.dp(activity, UiTokens.SPACE_XS), ShellUi.dp(activity, UiTokens.SPACE_S),
            )
        }
        header.addView(heading, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        seeAll = Button(activity).apply {
            text = texts.t("dash.see_all", R.string.dash_see_all)
            textSize = UiTokens.sp(UiTokens.CAPTION)
            setOnClickListener { HistoryActivity.launch(activity) }
        }
        header.addView(seeAll)
        root.addView(header, ShellUi.matchWrap())
        // The rows sit on a translucent card rather than straight on the theme picture, so each
        // one has a known surface and keeps its role colour instead of being measured against
        // whatever part of the wallpaper it lands on.
        scroll = ScrollView(activity).apply {
            isFillViewport = true
            val padH = ShellUi.dp(activity, UiTokens.SPACE_M)
            val padV = ShellUi.dp(activity, UiTokens.SPACE_S)
            setPadding(padH, padV, padH, padV)
            clipToPadding = false
            addView(list, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ))
        }
        root.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)
            .apply { topMargin = ShellUi.dp(activity, UiTokens.SPACE_S) })
    }

    /** Colours and labels; a language or palette change reaches the controls built once. */
    fun applyPalette(palette: Palette, roles: UiRoles) {
        heading.text = texts.t("dash.recent_calls", R.string.dash_recent_calls)
        seeAll.text = texts.t("dash.see_all", R.string.dash_see_all)
        UiKit.styleAction(seeAll, roles, ActionRole.SECONDARY)
        seeAll.textSize = UiTokens.sp(UiTokens.CAPTION)
        scroll.background = ShellUi.scrim(activity, palette.surface)
        rendered = null
    }

    /**
     * Rebuild the call rows, a view per row. Refreshes arrive once a second and the log changes
     * far more rarely, so an unchanged list in unchanged colours and language is left on screen.
     */
    fun render(rows: List<CallRow>, palette: Palette, roles: UiRoles) {
        val key = listOf(rows, palette, roles, texts.lang)
        if (rendered == key && list.childCount > 0) return
        rendered = key
        list.removeAllViews()
        if (rows.isEmpty()) {
            list.addView(
                ShellUi.text(activity, texts.t("history.empty", R.string.history_empty),
                             UiTokens.sp(UiTokens.BODY), palette.muted),
                ShellUi.matchWrap(),
            )
            return
        }
        for (row in rows.take(CallHistoryModel.DASHBOARD_ROWS)) list.addView(rowView(row, palette, roles), ShellUi.matchWrap())
    }

    private fun rowView(row: CallRow, palette: Palette, roles: UiRoles): View {
        val outcome = CallOutcome.of(row.outcome)
        val line = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isBaselineAligned = false
            minimumHeight = ShellUi.dp(activity, UiTokens.TOUCH_MIN_DP)
            setPadding(0, ShellUi.dp(activity, UiTokens.SPACE_XS), 0, ShellUi.dp(activity, UiTokens.SPACE_XS))
            isClickable = true
            isFocusable = true
            setOnClickListener { HistoryActivity.launch(activity, row.door) }
        }
        line.addView(ImageView(activity).apply {
            setImageResource(UiKit.outcomeIcon(outcome))
            setColorFilter(ShellUi.opaque(roles.tint(outcome.role)))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(ShellUi.dp(activity, 20), ShellUi.dp(activity, 20)).apply {
            rightMargin = ShellUi.dp(activity, UiTokens.SPACE_S)
        })
        val time = clock.format(row.tsMs)
        line.addView(
            ShellUi.text(activity, String.format(Locale.US, "%02d:%02d", time.hour, time.minute),
                         UiTokens.sp(UiTokens.CAPTION), palette.muted),
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                .apply { rightMargin = ShellUi.dp(activity, UiTokens.SPACE_S) },
        )
        val label = StringBuilder(doorLabel(row.door))
        if (row.purpose.isNotEmpty()) label.append(" · ").append(purposeLabel(row.purpose))
        val unread = row.missed && !row.seen
        line.addView(
            ShellUi.text(activity, label.toString(), UiTokens.sp(UiTokens.BODY),
                         if (row.missed) palette.dangerInk else palette.ink).apply {
                if (unread) setTypeface(typeface, Typeface.BOLD)
                maxLines = 2
            },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        val outcomeLabel = UiKit.outcomeLabel(texts, outcome)
        line.addView(ShellUi.text(activity, outcomeLabel, UiTokens.sp(UiTokens.CAPTION), palette.muted))
        line.contentDescription = "${time.hour}:${String.format(Locale.US, "%02d", time.minute)} $label $outcomeLabel"
        return line
    }
}
