// Framework-view building blocks for the guideline layouts (docs/en/ui-guidelines.md).
//
// Plain android.view/android.widget only, so API 19 (legacy19) renders the same metrics as the
// modern tier. Colours always come from [UiRoles]; a control's role, not the screen, decides its
// colour, so the same action looks the same everywhere.
package jp.ox.doorbell

import android.app.Activity
import android.content.Context
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

internal object UiKit {

    fun window(activity: Activity): WindowSpec {
        val configuration = activity.resources.configuration
        return WindowSpec(
            configuration.screenWidthDp,
            configuration.screenHeightDp,
            configuration.fontScale,
        )
    }

    /**
     * Give an existing button its role colours and touch floor. SemanticUi's captured baseline is
     * dropped so a Core semantic override is applied on top of the new role, never under it.
     */
    fun styleAction(
        view: TextView,
        roles: UiRoles,
        role: ActionRole,
        minHeightDp: Int = UiTokens.TOUCH_MIN_DP,
        emphasis: Boolean = false,
    ) {
        val context = view.context
        val fill = roles.fill(role)
        val border = if (role == ActionRole.SECONDARY) roles.line else null
        view.background = ShellUi.rounded(context, fill, UiTokens.RADIUS_CARD, border)
        view.setTextColor(ShellUi.opaque(roles.ink(role)))
        view.minHeight = ShellUi.dp(context, minHeightDp)
        view.minimumHeight = ShellUi.dp(context, minHeightDp)
        view.minWidth = ShellUi.dp(context, UiTokens.TOUCH_MIN_DP)
        view.minimumWidth = ShellUi.dp(context, UiTokens.TOUCH_MIN_DP)
        view.gravity = Gravity.CENTER
        if (view is Button) view.isAllCaps = false
        view.setTypeface(Typeface.create(view.typeface, if (emphasis) Typeface.BOLD else Typeface.NORMAL))
        val padH = ShellUi.dp(context, UiTokens.SPACE_L)
        val padV = ShellUi.dp(context, UiTokens.SPACE_S)
        view.setPadding(padH, padV, padH, padV)
        SemanticUi.invalidate(view)
    }

    fun actionButton(
        context: Context,
        label: String,
        roles: UiRoles,
        role: ActionRole,
        minHeightDp: Int = UiTokens.TOUCH_MIN_DP,
        onClick: () -> Unit,
    ): Button = Button(context).apply {
        text = label
        textSize = UiTokens.sp(UiTokens.BODY)
        maxLines = 2
        isFocusable = true
        styleAction(this, roles, role, minHeightDp, emphasis = role != ActionRole.SECONDARY)
        setOnClickListener { onClick() }
    }

    /** Lay buttons out in one row with the given weights and an 8 dp gap. */
    fun row(context: Context, views: List<Pair<View, Float>>): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            isBaselineAligned = false
            var first = true
            for ((view, weight) in views) {
                detach(view)
                addView(view, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT,
                                                        weight).apply {
                    if (!first) leftMargin = ShellUi.dp(context, UiTokens.SPACE_S)
                })
                first = false
            }
        }

    /** Remove a view from its current parent so it can be placed in a new arrangement. */
    fun detach(view: View) {
        (view.parent as? ViewGroup)?.removeView(view)
    }

    fun text(context: Context, value: CharSequence, scale: Float, ink: Int,
             bold: Boolean = false): TextView =
        ShellUi.text(context, value, UiTokens.sp(scale), ink, bold)

    /**
     * A section header for grouped lists (history days, settings groups): caption scale, muted,
     * with the 4-point spacing above and below.
     */
    fun groupHeader(context: Context, roles: UiRoles, value: String): TextView =
        text(context, value, UiTokens.CAPTION, roles.muted, bold = true).apply {
            setPadding(ShellUi.dp(context, UiTokens.SPACE_XS), ShellUi.dp(context, UiTokens.SPACE_L),
                       ShellUi.dp(context, UiTokens.SPACE_XS), ShellUi.dp(context, UiTokens.SPACE_S))
        }

    /**
     * Navigation between home and the secondary destinations: a bottom tab bar on compact
     * windows, a vertical rail from medium up. [selected] is highlighted with the accent role.
     */
    fun navigation(
        context: Context,
        roles: UiRoles,
        style: NavStyle,
        items: List<NavItem>,
        selected: String,
        onSelect: (NavItem) -> Unit,
    ): LinearLayout = LinearLayout(context).apply {
        orientation = if (style == NavStyle.RAIL) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
        setBackgroundColor(ShellUi.opaque(roles.surface))
        val pad = ShellUi.dp(context, UiTokens.SPACE_S)
        setPadding(pad, pad, pad, pad)
        for (item in items) {
            val active = item.id == selected
            val cell = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                minimumHeight = ShellUi.dp(context, UiTokens.TOUCH_MIN_DP + UiTokens.SPACE_S)
                minimumWidth = ShellUi.dp(context, if (style == NavStyle.RAIL) 80 else UiTokens.TOUCH_MIN_DP)
                isClickable = true
                isFocusable = true
                contentDescription = item.label
                if (active) background = ShellUi.rounded(context, roles.accent, UiTokens.RADIUS_CARD)
                setOnClickListener { onSelect(item) }
                val ink = if (active) roles.onAccent else roles.onSurface
                addView(text(context, item.glyph, UiTokens.TITLE, ink).apply {
                    gravity = Gravity.CENTER
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                })
                addView(text(context, item.label, UiTokens.CAPTION, ink, bold = active).apply {
                    gravity = Gravity.CENTER
                    maxLines = 2
                })
            }
            if (style == NavStyle.RAIL) {
                addView(cell, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                                                        ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    bottomMargin = ShellUi.dp(context, UiTokens.SPACE_S)
                })
            } else {
                addView(cell, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            }
        }
    }

    /**
     * A modal sheet over [host]: a scrim plus a panel at the bottom (compact) or the end edge
     * (otherwise) with the sheet radius. Tapping the scrim dismisses it; the screen underneath
     * keeps running.
     */
    class Sheet(
        private val host: FrameLayout,
        roles: UiRoles,
        atSide: Boolean,
        private val onDismiss: () -> Unit = {},
    ) {
        private val context = host.context
        private val scrim = View(context).apply {
            setBackgroundColor(0x99000000.toInt())
            isClickable = true
            setOnClickListener { dismiss() }
        }
        val panel: LinearLayout = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            background = ShellUi.rounded(context, roles.surface, UiTokens.RADIUS_SHEET)
            val pad = ShellUi.dp(context, UiTokens.SPACE_L)
            setPadding(pad, pad, pad, pad)
            isClickable = true
        }
        private val panelParams = if (atSide) FrameLayout.LayoutParams(
            ShellUi.dp(context, 360), ViewGroup.LayoutParams.MATCH_PARENT, Gravity.END,
        ) else FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM,
        )
        val showing: Boolean get() = panel.parent != null

        fun show() {
            if (showing) return
            host.addView(scrim, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                                                         ViewGroup.LayoutParams.MATCH_PARENT))
            host.addView(panel, panelParams)
        }

        fun dismiss() {
            if (!showing) return
            host.removeView(scrim)
            host.removeView(panel)
            onDismiss()
        }
    }
}

/** One navigation destination; [glyph] is a short text icon so API 19 needs no vector assets. */
internal data class NavItem(val id: String, val label: String, val glyph: String)
