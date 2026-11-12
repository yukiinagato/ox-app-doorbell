// The SOS control (docs/en/ui-guidelines.md, "SOS").
//
// What a screen shows is a compact outlined button in the negative role: it never competes with
// the screen's primary action. Tapping it only opens a confirmation surface (a modal bottom sheet
// on modern, a dialog on legacy19) that says what will happen. Arming needs a second, different
// gesture there: sliding the confirm control end to end, or, where nothing can be dragged (D-pad,
// keyboard, screen reader), the focusable "Send SOS" button, which is never the default focus.
// There is no press-and-hold anywhere. The surface closes by itself after ten seconds without
// input. After the slide the configured countdown runs with one large Cancel; the owner is told
// only when it reaches zero.
package jp.ox.doorbell

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import org.json.JSONObject

/**
 * A slide confirmation on the platform's modal surface. Used to send an SOS and, with a zero
 * countdown, to clear an active one.
 */
internal class SosConfirmSurface(
    context: Context,
    private val handler: Handler,
    title: String,
    message: String,
    slideLabel: String,
    slideSub: String,
    sendLabel: String,
    private val cancelLabel: String,
    countdownSeconds: Int,
    countdownText: (Int) -> String,
    palette: Palette,
    enabled: () -> Boolean,
    private val onConfirmed: () -> Unit,
    private val onClosed: () -> Unit,
) {
    private val idleClose = Runnable { dismiss() }
    private val sheet: SheetHandle = PlatformUi.confirmSurface(context) {
        handler.removeCallbacks(idleClose)
        slide.cancelCountdown()
        onClosed()
    }

    val slide = SosSlideView(context, handler)
    val sendButton: Button
    val cancelButton: Button
    val showing: Boolean get() = sheet.showing

    init {
        val roles = UiRoles.from(palette)
        val content = sheet.content
        content.addView(ShellUi.label(context, title, TextRole.TITLE), ShellUi.matchWrap())
        if (message.isNotEmpty()) content.addView(
            ShellUi.label(context, message, TextRole.BODY, palette.muted).apply {
                setPadding(0, ShellUi.dp(context, UiTokens.SPACE_S), 0, 0)
            }, ShellUi.matchWrap(),
        )
        slide.enabledProvider = enabled
        slide.applyPalette(palette)
        slide.configure(slideLabel, slideSub, cancelLabel, countdownSeconds,
                        countdownText = countdownText)
        slide.onTrigger = {
            // Guarded twice: a surface that was closed must not deliver a confirmation.
            if (sheet.showing) {
                onConfirmed()
                dismiss()
            }
        }
        content.addView(slide, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ShellUi.dp(context, SLIDE_HEIGHT_DP),
        ).apply { topMargin = ShellUi.dp(context, UiTokens.SPACE_XL) })

        sendButton = UiKit.actionButton(context, sendLabel, roles, ActionRole.NEGATIVE,
                                        kind = ButtonKind.OUTLINED) {
            if (sheet.showing && enabled()) slide.confirm()
        }
        cancelButton = UiKit.actionButton(context, cancelLabel, roles, ActionRole.SECONDARY) {
            dismiss()
        }
        // Cancel comes first in focus order and takes the initial focus; Send SOS is reachable
        // but never where a stray key press lands.
        val actions = UiKit.row(context, listOf(cancelButton to 1f, sendButton to 1f))
        content.addView(actions, ShellUi.matchWrap().apply {
            topMargin = ShellUi.dp(context, UiTokens.SPACE_L)
        })

        slide.onStateChanged = { snapshot ->
            // Any slide movement is input; a running countdown must not be closed under the user.
            restartIdleClose(snapshot.phase != SosPhase.COUNTDOWN)
            val counting = snapshot.phase == SosPhase.COUNTDOWN
            sendButton.visibility = if (counting) View.GONE else View.VISIBLE
            // During the countdown the one remaining action is a large Cancel.
            val height = ShellUi.dp(context, if (counting) UiTokens.VISITOR_TOUCH_MIN_DP
                                             else UiTokens.TOUCH_MIN_DP)
            cancelButton.minHeight = height
            cancelButton.minimumHeight = height
        }
    }

    fun show() {
        sheet.show()
        cancelButton.requestFocus()
        restartIdleClose(true)
    }

    fun dismiss() = sheet.dismiss()

    /** The Cancel shown during the countdown is the `sos.cancel` semantic element. */
    fun applySemantic(config: JSONObject?, nodeId: String) {
        SemanticUi.apply(cancelButton, "sos.cancel", config, nodeId)
    }

    private fun restartIdleClose(armed: Boolean) {
        handler.removeCallbacks(idleClose)
        if (armed && sheet.showing) handler.postDelayed(idleClose, IDLE_CLOSE_MS)
    }

    companion object {
        const val IDLE_CLOSE_MS = 10_000L
        private const val SLIDE_HEIGHT_DP = 64
    }
}

@SuppressLint("ViewConstructor")
internal class SosTriggerView(
    context: Context,
    private val handler: Handler = Handler(Looper.getMainLooper()),
) : FrameLayout(context) {

    /** Called once per confirmed slide when the countdown reaches zero. */
    var onTrigger: (() -> Unit)? = null

    /** Gate that keeps the control inert while core is not ready. */
    var enabledProvider: () -> Boolean = { true }

    private val button: Button = PlatformUi.button(context, ButtonKind.OUTLINED)
    private var palette: Palette = PlatformUi.tokens(context)
    private var slideLabel = context.getString(R.string.sos_slide_label)
    private var slideSub = ""
    private var cancelLabel = context.getString(R.string.sos_countdown_cancel)
    private var title = context.getString(R.string.sos_confirm_title)
    private var message = context.getString(R.string.sos_hint)
    private var sendLabel = context.getString(R.string.sos_send)
    private var countdownSeconds = SosSlideState.DEFAULT_COUNTDOWN_S
    private var countdownText: (Int) -> String = { it.toString() }
    private var semanticConfig: JSONObject? = null
    private var semanticNode = ""

    /** The open confirmation surface, or null. */
    internal var surface: SosConfirmSurface? = null
        private set

    init {
        button.text = context.getString(R.string.sos_title)
        button.setOnClickListener { open() }
        addView(button, LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER_VERTICAL or Gravity.START,
        ))
        restyle()
    }

    private fun restyle() {
        UiKit.styleAction(button, UiRoles.from(palette), ActionRole.NEGATIVE,
                          kind = ButtonKind.OUTLINED)
        PlatformUi.setButtonIcon(button, R.drawable.ic_tabler_alert_triangle)
    }

    /**
     * Labels and the countdown; call again after a language or config change. [primary] and
     * [secondary] label the slide on the confirmation surface.
     */
    fun configure(
        primary: String,
        secondary: String,
        cancelLabel: String,
        countdownSeconds: Int,
        title: String = context.getString(R.string.sos_confirm_title),
        message: String = context.getString(R.string.sos_hint),
        sendLabel: String = context.getString(R.string.sos_send),
        countdownText: (Int) -> String,
    ) {
        cancelCountdown()
        slideLabel = primary
        slideSub = secondary
        this.cancelLabel = cancelLabel
        this.countdownSeconds = countdownSeconds
        this.title = title
        this.message = message
        this.sendLabel = sendLabel
        this.countdownText = countdownText
    }

    fun applyPalette(value: Palette) {
        palette = value
        restyle()
    }

    /** Administrator overrides: `sos.trigger` on the button, `sos.cancel` on the surface. */
    fun applySemantic(config: JSONObject?, nodeId: String) {
        semanticConfig = config
        semanticNode = nodeId
        SemanticUi.apply(button, "sos.trigger", config, nodeId)
    }

    /** A tap: nothing is armed, the confirmation surface opens. */
    internal fun open() {
        if (!isEnabled || !enabledProvider() || !isShown || windowToken == null) return
        if (surface?.showing == true) return
        var opened: SosConfirmSurface? = null
        opened = SosConfirmSurface(
            context, handler, title, message, slideLabel, slideSub, sendLabel, cancelLabel,
            countdownSeconds, countdownText, palette, enabledProvider,
            onConfirmed = { if (surface === opened && enabledProvider()) onTrigger?.invoke() },
            onClosed = { if (surface === opened) surface = null },
        )
        surface = opened
        opened.applySemantic(semanticConfig, semanticNode)
        opened.show()
    }

    /** Close the surface and cancel any countdown, for example when the owning screen goes away. */
    fun cancelCountdown() {
        val open = surface
        surface = null
        open?.slide?.cancelCountdown()
        open?.dismiss()
    }

    fun isArmed(): Boolean = surface?.slide?.isArmed() == true

    override fun onDetachedFromWindow() {
        cancelCountdown()
        super.onDetachedFromWindow()
    }
}
