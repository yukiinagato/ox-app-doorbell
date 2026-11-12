// Role-aware building blocks for the guideline layouts (docs/en/ui-guidelines.md).
//
// The widgets come from the flavor's PlatformUi. A control's role, not the screen, decides its
// colour, so the same action looks the same everywhere: primary takes the accent, positive and
// negative stay fixed, and everything else keeps the platform's own look.
package jp.ox.doorbell

import android.app.Activity
import android.content.Context
import android.graphics.Typeface
import android.view.View
import android.view.ViewGroup
import android.widget.Button
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
     * Give an existing button its role colours and touch floor. Any administrator override is
     * taken off first, so a Core semantic override is applied on top of the new role, never
     * under it. [kind] defaults to filled for a coloured role and tonal for a secondary one.
     */
    fun styleAction(
        view: TextView,
        roles: UiRoles,
        role: ActionRole,
        minHeightDp: Int = UiTokens.TOUCH_MIN_DP,
        @Suppress("UNUSED_PARAMETER") emphasis: Boolean = false,
        kind: ButtonKind? = null,
    ) {
        val context = view.context
        SemanticUi.release(view)
        val resolved = kind ?: if (role == ActionRole.SECONDARY) ButtonKind.TONAL else ButtonKind.FILLED
        when (role) {
            ActionRole.SECONDARY -> PlatformUi.styleButton(view, resolved, null, null)
            // The primary role is the accent the screen resolved, which on the home surfaces is
            // Core's call-button colour for the wallpaper actually behind it.
            else -> PlatformUi.styleButton(view, resolved, roles.fill(role), roles.ink(role))
        }
        view.minHeight = ShellUi.dp(context, minHeightDp)
        view.minimumHeight = ShellUi.dp(context, minHeightDp)
        view.minWidth = ShellUi.dp(context, UiTokens.TOUCH_MIN_DP)
        view.minimumWidth = ShellUi.dp(context, UiTokens.TOUCH_MIN_DP)
        if (view is Button) view.isAllCaps = false
    }

    fun actionButton(
        context: Context,
        label: String,
        roles: UiRoles,
        role: ActionRole,
        minHeightDp: Int = UiTokens.TOUCH_MIN_DP,
        kind: ButtonKind? = null,
        onClick: () -> Unit,
    ): Button {
        val resolved = kind ?: if (role == ActionRole.SECONDARY) ButtonKind.TONAL else ButtonKind.FILLED
        return PlatformUi.button(context, resolved).apply {
            text = label
            maxLines = 2
            isFocusable = true
            styleAction(this, roles, role, minHeightDp, kind = resolved)
            setOnClickListener { onClick() }
        }
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

    /** A section header for grouped lists (history days, settings groups). */
    fun groupHeader(context: Context, roles: UiRoles, value: String): TextView =
        ShellUi.label(context, value, TextRole.LABEL, roles.muted).apply {
            setTypeface(typeface, Typeface.BOLD)
            setPadding(ShellUi.dp(context, UiTokens.SPACE_L), ShellUi.dp(context, UiTokens.SPACE_L),
                       ShellUi.dp(context, UiTokens.SPACE_L), ShellUi.dp(context, UiTokens.SPACE_S))
        }

    /**
     * Navigation between home and the secondary destinations: the platform's navigation bar on
     * compact windows, its rail from medium up. [badges] puts a count on a destination.
     */
    fun navigation(
        context: Context,
        style: NavStyle,
        items: List<NavItem>,
        selected: String,
        badges: Map<String, Int> = emptyMap(),
        onSelect: (NavItem) -> Unit,
    ): View = PlatformUi.navigation(context, style, items, selected, badges, onSelect)

    /** The icon for a recorded call's outcome, shared by the dashboard and the history. */
    fun outcomeIcon(outcome: CallOutcome): Int = when (outcome) {
        CallOutcome.ANSWERED -> R.drawable.ic_tabler_phone
        CallOutcome.MISSED -> R.drawable.ic_tabler_phone_off
        CallOutcome.REPLIED -> R.drawable.ic_tabler_message_reply
        CallOutcome.CANCELLED -> R.drawable.ic_tabler_x
    }

    fun outcomeLabel(texts: Texts, outcome: CallOutcome): String = when (outcome) {
        CallOutcome.MISSED -> texts.t("history.outcome_missed", R.string.history_outcome_missed)
        CallOutcome.ANSWERED -> texts.t("history.outcome_answered", R.string.history_outcome_answered)
        CallOutcome.REPLIED -> texts.t("history.outcome_replied", R.string.history_outcome_replied)
        CallOutcome.CANCELLED -> texts.t("history.outcome_cancelled", R.string.history_outcome_cancelled)
    }
}

/** One navigation destination; [icon] is a drawable the build rasterises for API 19. */
internal data class NavItem(val id: String, val label: String, val icon: Int)
