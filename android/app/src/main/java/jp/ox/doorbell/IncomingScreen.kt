// Arrangement of the incoming-call / live-view screen (docs/en/ui-guidelines.md section 4).
//
// IncomingActivity owns call behaviour; this component only places its views. Portrait windows
// stack video, details, and the fixed action zone; landscape medium/expanded windows put the video
// on the left (at least 60 %) and details plus actions in a right column. Opened without a call it
// is the live view: details and actions float over the video and hide after four seconds, and a
// door switcher lets the resident move between cameras.
package jp.ox.doorbell

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

internal class IncomingScreen(private val activity: Activity) {
    private val ui = Handler(Looper.getMainLooper())
    private val frame: FrameLayout = activity.findViewById(R.id.incoming_frame)
    private val root: LinearLayout = activity.findViewById(R.id.incoming_root)
    private val videoBox: FrameLayout = activity.findViewById(R.id.video_box)
    private val details: LinearLayout = activity.findViewById(R.id.details_box)
    private val actions: LinearLayout = activity.findViewById(R.id.action_zone)
    private val primaryRow: LinearLayout = activity.findViewById(R.id.control_row)
    private val secondaryRow: LinearLayout = activity.findViewById(R.id.secondary_row)
    private val footer: LinearLayout = activity.findViewById(R.id.footer_box)
    private val answer: Button = activity.findViewById(R.id.answer_button)
    private val reply: Button = activity.findViewById(R.id.reply_button)
    private val ignore: Button = activity.findViewById(R.id.close_button)
    private val monitor: Button = activity.findViewById(R.id.monitor_button)
    private val unlock: Button = activity.findViewById(R.id.unlock_button)
    private val mic: Button = activity.findViewById(R.id.mic_button)

    private val replyRow = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        isBaselineAligned = false
    }
    private val sideColumn = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private val detailsScroll = ScrollView(activity).apply { isFillViewport = false }
    private val overlayTop = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private val overlayBottom = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private val switcher = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
    private val switcherScroll = HorizontalScrollView(activity).apply {
        isHorizontalScrollBarEnabled = false
    }
    private val sideList = ScrollView(activity)
    private var doors: List<Pair<String, String>> = emptyList()
    private var currentDoor = ""
    private var onPickDoor: (String) -> Unit = {}
    private var liveView = false
    private var overlaysShown = true
    private val hideOverlays = Runnable { setOverlaysShown(false) }
    private var roles = UiRoles.from(Palette.DARK)
    private var window = UiKit.window(activity)

    /** Place the views for [liveView] (no call) or a call, on the current window. */
    fun arrange(roles: UiRoles, liveView: Boolean) {
        this.roles = roles
        this.liveView = liveView
        window = UiKit.window(activity)
        for (view in listOf(videoBox, details, actions, footer, sideColumn, detailsScroll,
                            overlayTop, overlayBottom, switcherScroll, sideList)) UiKit.detach(view)
        UiKit.detach(switcher)
        sideColumn.removeAllViews()
        detailsScroll.removeAllViews()
        overlayTop.removeAllViews()
        overlayBottom.removeAllViews()
        root.removeAllViews()
        root.setBackgroundColor(ShellUi.opaque(roles.ground))
        videoBox.setBackgroundColor(android.graphics.Color.BLACK)
        layoutRows(ScreenLayouts.incomingSideBySide(window))
        if (liveView) arrangeLiveView() else arrangeCall()
        setOverlaysShown(true)
    }

    private fun arrangeCall() {
        val side = ScreenLayouts.incomingSideBySide(window)
        if (!side) {
            root.orientation = LinearLayout.VERTICAL
            root.addView(videoBox, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
            root.addView(details, ShellUi.matchWrap())
            root.addView(actions, ShellUi.matchWrap())
            root.addView(footer, ShellUi.matchWrap())
            return
        }
        root.orientation = LinearLayout.HORIZONTAL
        val fraction = ScreenLayouts.incomingVideoFraction(window)
        root.addView(videoBox, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.MATCH_PARENT, fraction))
        // Details scroll inside the column; the action zone below them never moves.
        detailsScroll.addView(details, ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        sideColumn.addView(detailsScroll, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        sideColumn.addView(actions, ShellUi.matchWrap())
        sideColumn.addView(footer, ShellUi.matchWrap())
        sideColumn.setBackgroundColor(ShellUi.opaque(roles.surface))
        root.addView(sideColumn, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.MATCH_PARENT, 1f - fraction))
    }

    /**
     * Live view: the video fills the screen; details (with the door switcher) float at the top
     * and the action zone at the bottom, on a translucent surface, hidden after four seconds.
     */
    private fun arrangeLiveView() {
        // Door switcher: a side list on expanded windows, a horizontal strip otherwise.
        val asList = ScreenLayouts.monitorSideList(window) && doors.size >= 2
        buildSwitcher(vertical = asList)
        if (asList) {
            root.orientation = LinearLayout.HORIZONTAL
            sideList.removeAllViews()
            sideList.setBackgroundColor(ShellUi.opaque(roles.surface))
            val pad = ShellUi.dp(activity, UiTokens.SPACE_M)
            sideList.setPadding(pad, pad, pad, pad)
            sideList.addView(switcher, ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            root.addView(sideList, LinearLayout.LayoutParams(
                ShellUi.dp(activity, SIDE_LIST_DP), ViewGroup.LayoutParams.MATCH_PARENT))
            root.addView(videoBox, LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        } else {
            root.orientation = LinearLayout.VERTICAL
            root.addView(videoBox, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        val scrim = ShellUi.scrim(activity, roles.surface, 0)
        overlayTop.background = scrim
        overlayTop.addView(details, ShellUi.matchWrap())
        if (!asList && switcher.childCount > 0) {
            switcherScroll.removeAllViews()
            switcherScroll.addView(switcher)
            overlayTop.addView(switcherScroll, ShellUi.matchWrap().apply {
                bottomMargin = ShellUi.dp(activity, UiTokens.SPACE_S)
            })
        }
        overlayBottom.background = ShellUi.scrim(activity, roles.surface, 0)
        overlayBottom.addView(actions, ShellUi.matchWrap())
        overlayBottom.addView(footer, ShellUi.matchWrap())
        videoBox.addView(overlayTop, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP))
        videoBox.addView(overlayBottom, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM))
    }

    /**
     * Primary actions Answer/End (largest) · Reply · Ignore; secondary row Monitor · Unlock · Mic.
     * Where one row would squeeze the labels, Answer takes its own row above Reply and Ignore;
     * at large text in a narrow zone all three stack.
     */
    private fun layoutRows(side: Boolean) {
        val stack = window.largeText && (side || window.sizeClass == SizeClass.COMPACT)
        val oneRow = !stack && ScreenLayouts.incomingPrimaryInOneRow(window)
        val gap = ShellUi.dp(activity, UiTokens.SPACE_S)
        primaryRow.removeAllViews()
        replyRow.removeAllViews()
        primaryRow.orientation = if (oneRow) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
        fun inRow(index: Int, weight: Float) = LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, weight).apply { if (index > 0) leftMargin = gap }
        fun stacked(index: Int) = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { if (index > 0) topMargin = gap }
        when {
            oneRow -> {
                primaryRow.addView(answer, inRow(0, 2f))
                primaryRow.addView(reply, inRow(1, 1f))
                primaryRow.addView(ignore, inRow(2, 1f))
            }
            stack -> for ((index, view) in listOf(answer, reply, ignore).withIndex())
                primaryRow.addView(view, stacked(index))
            else -> {
                primaryRow.addView(answer, stacked(0))
                replyRow.addView(reply, inRow(0, 1f))
                replyRow.addView(ignore, inRow(1, 1f))
                primaryRow.addView(replyRow, stacked(1))
            }
        }
        secondaryRow.removeAllViews()
        for ((index, view) in listOf(monitor, unlock, mic).withIndex()) {
            secondaryRow.addView(view, LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { if (index > 0) leftMargin = gap })
        }
    }

    /**
     * Answer filled in the positive role (End in the negative role once in call), Reply tonal,
     * Ignore outlined, and the secondary row tonal; each with its Tabler icon beside the label.
     */
    fun styleActions(inCall: Boolean) {
        val primaryHeight = ScreenLayouts.touchTargetDp(window, 56)
        val secondaryHeight = ScreenLayouts.touchTargetDp(window)
        UiKit.styleAction(answer, roles, if (inCall) ActionRole.NEGATIVE else ActionRole.POSITIVE,
                          primaryHeight, emphasis = true)
        UiKit.styleAction(reply, roles, ActionRole.SECONDARY, primaryHeight)
        UiKit.styleAction(ignore, roles, ActionRole.SECONDARY, primaryHeight,
                          kind = ButtonKind.OUTLINED)
        for (button in listOf(monitor, unlock, mic))
            UiKit.styleAction(button, roles, ActionRole.SECONDARY, secondaryHeight)
        PlatformUi.setButtonIcon(answer, if (inCall) R.drawable.ic_tabler_phone_off
                                         else R.drawable.ic_tabler_phone)
        PlatformUi.setButtonIcon(reply, R.drawable.ic_tabler_message_reply)
        PlatformUi.setButtonIcon(ignore, R.drawable.ic_tabler_bell_off)
        PlatformUi.setButtonIcon(unlock, R.drawable.ic_tabler_lock_open)
    }

    /** Door chips for the live view; tapping one opens that door's live view. */
    fun setDoorSwitcher(doors: List<Pair<String, String>>, current: String, onPick: (String) -> Unit) {
        this.doors = doors
        currentDoor = current
        onPickDoor = onPick
        if (liveView) arrange(roles, true)
    }

    /** Door chips (strip) or full-width rows (side list); tapping one opens that door. */
    private fun buildSwitcher(vertical: Boolean) {
        switcher.removeAllViews()
        switcher.orientation = if (vertical) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
        if (doors.size < 2) return
        val pad = if (vertical) 0 else ShellUi.dp(activity, UiTokens.SPACE_L)
        switcher.setPadding(pad, 0, pad, 0)
        for ((id, label) in doors) {
            val active = id == currentDoor
            val chip = PlatformUi.chip(activity, label, ChipKind.FILTER).apply {
                PlatformUi.setChipChecked(this, active)
                isSelected = active
                setOnClickListener {
                    // The chip marks the door on screen; a tap must not toggle that mark off.
                    PlatformUi.setChipChecked(this, active)
                    if (!active) onPickDoor(id)
                }
            }
            switcher.addView(chip, if (vertical) ShellUi.matchWrap().apply {
                bottomMargin = ShellUi.dp(activity, UiTokens.SPACE_S)
            } else LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                rightMargin = ShellUi.dp(activity, UiTokens.SPACE_S)
            })
        }
    }

    /** Call on any touch; in the live view it shows the controls and restarts the timer. */
    fun onUserTouch(event: MotionEvent) {
        if (!liveView || event.actionMasked != MotionEvent.ACTION_DOWN) return
        setOverlaysShown(true)
    }

    private fun setOverlaysShown(shown: Boolean) {
        ui.removeCallbacks(hideOverlays)
        overlaysShown = shown
        if (!liveView) {
            overlayTop.visibility = View.VISIBLE
            overlayBottom.visibility = View.VISIBLE
            return
        }
        val target = if (shown) View.VISIBLE else View.GONE
        overlayTop.visibility = target
        overlayBottom.visibility = target
        if (shown) ui.postDelayed(hideOverlays, UiTokens.OVERLAY_HIDE_MS)
    }

    fun release() {
        ui.removeCallbacks(hideOverlays)
    }

    /** Quick replies in a modal bottom sheet (compact) or side sheet; one tap sends. */
    fun replySheet(list: LinearLayout, onDismiss: () -> Unit = {}): SheetHandle {
        val scroll = ScrollView(activity)
        val sheet = PlatformUi.sheet(activity, ScreenLayouts.replySheetAtSide(window)) {
            // The list goes back under the screen so the next sheet can take it, unless a newer
            // sheet already has: a dismissal is delivered after the replacement is built.
            if (list.parent === scroll) {
                scroll.removeView(list)
                list.visibility = View.GONE
                frame.addView(list)
            }
            onDismiss()
        }
        UiKit.detach(list)
        list.visibility = View.VISIBLE
        scroll.addView(list)
        sheet.content.addView(ShellUi.label(activity, reply.text, TextRole.TITLE).apply {
            setPadding(0, 0, 0, ShellUi.dp(activity, UiTokens.SPACE_M))
        }, ShellUi.matchWrap())
        sheet.content.addView(scroll, ShellUi.matchWrap())
        return sheet
    }

    companion object {
        /** Reply buttons inside the sheet use the secondary role and the touch floor. */
        fun styleReply(button: TextView, roles: UiRoles, window: WindowSpec) {
            UiKit.styleAction(button, roles, ActionRole.SECONDARY,
                              ScreenLayouts.touchTargetDp(window, 56))
        }

        /** Width of the expanded live view's door list. */
        const val SIDE_LIST_DP = 240
    }
}
