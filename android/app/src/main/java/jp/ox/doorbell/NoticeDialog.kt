// The announcement dialog reached from all three entry points (spec §4.3, §5.1, §5.2):
// the dashboard's 「お知らせ（全体）」 button, a door tile's status chip, and the monitor screen's
// 「この門口機にお知らせ」 button. Text, target, expiry, admin-editable presets, 表示する/取り消す.
package jp.ox.doorbell

import android.app.Activity
import android.app.Dialog
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.view.Window
import android.view.WindowManager
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputFilter
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.util.Calendar
import org.json.JSONObject

internal object NoticeDialog {

    /**
     * Show the dialog.
     *
     * [preselectDoor] is empty for the dashboard's global entry point and set for a tile or the
     * monitor screen. [doors] is every configured door, which is what 全体 writes.
     */
    fun show(
        activity: Activity,
        app: App,
        texts: Texts,
        palette: Palette,
        preselectDoor: String,
        doors: List<String>,
        doorLabel: (String) -> String,
        onChanged: () -> Unit,
    ) {
        val config = app.core.config()
        val coreStatus = app.core.status()
        val nowMs = app.core.localTime()?.optLong("wall_ms", 0L)
            ?.takeIf { it > 0L } ?: System.currentTimeMillis()
        var target = if (preselectDoor.isEmpty()) NoticeTarget.GLOBAL else NoticeTarget.DOOR
        var expiry = ExpiryChoice.UNTIL_CLEARED
        val existing = NoticeModel.resolve(coreStatus, config, preselectDoor, nowMs)

        val roles = UiRoles.from(palette)
        val window = UiKit.window(activity)
        val pad = ShellUi.dp(activity, UiTokens.SPACE_L)
        val root = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, ShellUi.dp(activity, 8), pad, 0)
        }

        val field = EditText(activity).apply {
            setText(existing?.text.orEmpty())
            setSingleLine(false)
            maxLines = 4
            minLines = 2
            gravity = Gravity.TOP or Gravity.START
            filters = arrayOf<InputFilter>(InputFilter.LengthFilter(NoticeModel.MAX_TEXT))
            isFocusable = true
            isFocusableInTouchMode = true
            textSize = UiTokens.sp(UiTokens.BODY)
            setTextColor(ShellUi.opaque(palette.ink))
            background = ShellUi.rounded(activity, palette.surfaceAlt, UiTokens.RADIUS_CARD, palette.line)
            val inset = ShellUi.dp(activity, UiTokens.SPACE_M)
            setPadding(inset, inset, inset, inset)
            minHeight = ShellUi.dp(activity, UiTokens.TOUCH_MIN_DP * 2)
        }
        root.addView(field, ShellUi.matchWrap())

        val counter = ShellUi.text(
            activity,
            texts.t("notice.char_count", R.string.notice_char_count,
                    field.text.length.toString()),
            12f, palette.muted,
        )
        root.addView(counter, ShellUi.matchWrap())
        field.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) {
                counter.text = texts.t(
                    "notice.char_count", R.string.notice_char_count, (s?.length ?: 0).toString(),
                )
            }
        })

        // Admin-editable presets. Text only: a preset is a message, never an explainer.
        val presets = NoticeModel.presets(
            config,
            listOf(
                texts.t("notice.preset_absent", R.string.notice_preset_absent),
                texts.t("notice.preset_delivery", R.string.notice_preset_delivery),
                texts.t("notice.preset_construction", R.string.notice_preset_construction),
            ),
        )
        if (presets.isNotEmpty()) {
            root.addView(ShellUi.sectionHeading(
                activity, palette, texts.t("notice.presets", R.string.notice_presets),
            ))
            val strip = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
            for (preset in presets) {
                strip.addView(
                    ShellUi.button(activity, preset.text, palette) {
                        field.setText(preset.text)
                        field.setSelection(field.text.length)
                    },
                    ShellUi.matchWrap().apply { topMargin = ShellUi.dp(activity, 4) },
                )
            }
            root.addView(strip, ShellUi.matchWrap())
        }

        // Target selector: 全体 / この門口機（玄関）.
        val targetRow = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
        val globalButton = ShellUi.button(
            activity, texts.t("notice.target_global", R.string.notice_target_global), palette,
        ) { }
        val doorButton = ShellUi.button(
            activity,
            texts.t("notice.target_door", R.string.notice_target_door,
                    doorLabel(preselectDoor)),
            palette,
        ) { }
        fun paintTargets() {
            UiKit.styleAction(globalButton, roles,
                if (target == NoticeTarget.GLOBAL) ActionRole.PRIMARY else ActionRole.SECONDARY)
            UiKit.styleAction(doorButton, roles,
                if (target == NoticeTarget.DOOR) ActionRole.PRIMARY else ActionRole.SECONDARY)
        }
        globalButton.setOnClickListener { target = NoticeTarget.GLOBAL; paintTargets() }
        doorButton.setOnClickListener { target = NoticeTarget.DOOR; paintTargets() }
        if (preselectDoor.isNotEmpty()) {
            root.addView(ShellUi.sectionHeading(
                activity, palette, texts.t("notice.target", R.string.notice_target),
            ))
            val half = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            targetRow.addView(globalButton, LinearLayout.LayoutParams(half))
            targetRow.addView(doorButton, LinearLayout.LayoutParams(half).apply {
                leftMargin = ShellUi.dp(activity, 6)
            })
            root.addView(targetRow, ShellUi.matchWrap())
            paintTargets()
        }

        // Expiry presets.
        root.addView(ShellUi.sectionHeading(
            activity, palette, texts.t("notice.expiry", R.string.notice_expiry),
        ))
        val expiryButtons = LinkedHashMap<ExpiryChoice, Button>()
        val expiryLabels = linkedMapOf(
            ExpiryChoice.ONE_HOUR to texts.t("notice.expiry_1h", R.string.notice_expiry_1h),
            ExpiryChoice.TODAY to texts.t("notice.expiry_today", R.string.notice_expiry_today),
            ExpiryChoice.UNTIL_CLEARED to
                texts.t("notice.expiry_until_cleared", R.string.notice_expiry_until_cleared),
        )
        val expiryRow = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
        fun paintExpiry() {
            for ((choice, button) in expiryButtons) UiKit.styleAction(
                button, roles, if (choice == expiry) ActionRole.PRIMARY else ActionRole.SECONDARY,
            )
        }
        // Three presets share a row, except at large text on a compact window where each takes
        // its own full-width row so no label is cut.
        val stackExpiry = window.sizeClass == SizeClass.COMPACT && window.largeText
        if (stackExpiry) expiryRow.orientation = LinearLayout.VERTICAL
        for ((choice, label) in expiryLabels) {
            val button = ShellUi.button(activity, label, palette) {
                expiry = choice
                paintExpiry()
            }
            expiryButtons[choice] = button
            expiryRow.addView(
                button,
                if (stackExpiry) ShellUi.matchWrap().apply {
                    topMargin = if (expiryButtons.size == 1) 0 else ShellUi.dp(activity, UiTokens.SPACE_S)
                } else LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    leftMargin = if (expiryButtons.size == 1) 0 else ShellUi.dp(activity, UiTokens.SPACE_S)
                },
            )
        }
        root.addView(expiryRow, ShellUi.matchWrap())
        paintExpiry()

        val status = ShellUi.text(activity, "", 13f, palette.danger).apply {
            visibility = View.GONE
            setPadding(0, ShellUi.dp(activity, 8), 0, 0)
        }
        root.addView(status, ShellUi.matchWrap())

        // A sheet (guidelines: radius 20, fixed action zone): bottom sheet on compact windows,
        // a centred panel otherwise. Built from plain views so API 19 looks the same.
        val scroll = ScrollView(activity).apply { addView(root) }
        val sheet = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            background = ShellUi.rounded(activity, palette.surface, UiTokens.RADIUS_SHEET)
            setPadding(0, pad, 0, pad)
        }
        sheet.addView(UiKit.text(activity, texts.t("notice.title", R.string.notice_title),
                                 UiTokens.TITLE, palette.ink, bold = true).apply {
            setPadding(pad, 0, pad, ShellUi.dp(activity, UiTokens.SPACE_S))
        }, ShellUi.matchWrap())
        sheet.addView(scroll, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f,
        ))
        val publishButton = UiKit.actionButton(
            activity, texts.t("notice.publish", R.string.notice_publish), roles, ActionRole.PRIMARY,
        ) { }
        val clearButton = UiKit.actionButton(
            activity, texts.t("notice.clear", R.string.notice_clear), roles, ActionRole.NEGATIVE,
        ) { }
        val dialog = Dialog(activity)
        val cancelButton = UiKit.actionButton(
            activity, texts.t("admin.cancel", R.string.admin_cancel), roles, ActionRole.SECONDARY,
        ) { dialog.dismiss() }
        // Destructive on the start edge, the primary action last where the thumb ends.
        val actions = UiKit.row(activity, listOf(clearButton to 1f, cancelButton to 1f, publishButton to 1.4f))
        actions.setPadding(pad, ShellUi.dp(activity, UiTokens.SPACE_M), pad, 0)
        sheet.addView(actions, ShellUi.matchWrap())
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
        dialog.setContentView(sheet)
        dialog.window?.let { w ->
            w.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            val compact = window.sizeClass == SizeClass.COMPACT
            w.setGravity(if (compact) Gravity.BOTTOM else Gravity.CENTER)
            w.setLayout(
                if (compact) WindowManager.LayoutParams.MATCH_PARENT
                else ShellUi.dp(activity, 560),
                WindowManager.LayoutParams.WRAP_CONTENT,
            )
        }

        val ui = Handler(Looper.getMainLooper())
        fun report(view: TextView, message: String, isError: Boolean) {
            view.text = message
            view.setTextColor(ShellUi.opaque(if (isError) palette.danger else palette.okInk))
            view.visibility = View.VISIBLE
        }

        fun apply(clear: Boolean) {
            val text = field.text.toString().trim()
            if (!clear) {
                when (NoticeModel.validate(text)) {
                    "empty" -> {
                        report(status, texts.t("notice.empty", R.string.notice_empty), true)
                        return
                    }
                    "too_long" -> {
                        report(status, texts.t("notice.too_long", R.string.notice_too_long,
                                               text.length.toString()), true)
                        return
                    }
                }
            }
            val targets = NoticeModel.writeTargets(target, preselectDoor, doors)
            if (targets.isEmpty()) {
                report(status, texts.t("notice.failed", R.string.notice_failed), true)
                return
            }
            val expiresMs = NoticeModel.expiryFor(expiry, nowMs, endOfDay(app, nowMs), 1)
            Thread({
                var ok = true
                for (door in targets) {
                    ok = if (clear) app.core.clearDoorNotice(door) && ok
                    else app.core.setDoorNotice(door, text, expiresMs) && ok
                }
                ui.post {
                    if (activity.isFinishing) return@post
                    if (!ok) {
                        report(status, texts.t("notice.failed", R.string.notice_failed), true)
                        return@post
                    }
                    dialog.dismiss()
                    onChanged()
                }
            }, "doorbell-notice").apply { isDaemon = true }.start()
        }

        publishButton.setOnClickListener { apply(false) }
        clearButton.setOnClickListener { apply(true) }
        dialog.show()
    }

    /** End of the current cluster-local day, so 「今日いっぱい」 follows the cluster time zone. */
    private fun endOfDay(app: App, nowMs: Long): Long {
        val local = app.core.localTime(nowMs)
        val hour = local?.optInt("hh", -1) ?: -1
        if (hour < 0) {
            val calendar = Calendar.getInstance()
            calendar.timeInMillis = nowMs
            calendar.set(Calendar.HOUR_OF_DAY, 23)
            calendar.set(Calendar.MINUTE, 59)
            calendar.set(Calendar.SECOND, 59)
            return calendar.timeInMillis
        }
        val minute = local?.optInt("mm", 0) ?: 0
        val second = local?.optInt("ss", 0) ?: 0
        val elapsed = ((hour * 60L + minute) * 60L + second) * 1000L
        return nowMs - elapsed + 24L * 3_600_000L - 1_000L
    }

    /** Read the announcement rendered on a screen right now, honouring the door override. */
    fun current(status: JSONObject?, config: JSONObject?, door: String, nowMs: Long): Notice? =
        NoticeModel.resolve(status, config, door, nowMs)
}
