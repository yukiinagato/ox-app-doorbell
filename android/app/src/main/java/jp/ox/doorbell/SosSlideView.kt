// Slide-to-trigger SOS control (spec §4.4). Framework views only: a custom View that draws its
// own track, thumb, and two-part label, plus a D-pad path so the control is reachable on a TV.
//
// The control never calls core itself; it reports the countdown reaching zero to its owner.
package jp.ox.doorbell

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo

@SuppressLint("ViewConstructor")
internal class SosSlideView(
    context: Context,
    private val handler: Handler = Handler(Looper.getMainLooper()),
) : View(context) {

    /** Called once per armed slide when the countdown reaches zero. */
    var onTrigger: (() -> Unit)? = null

    /** Called on every visible change so the owner can update an overlay or announce state. */
    var onStateChanged: ((SosSnapshot) -> Unit)? = null

    /** Gate that keeps the control inert while core is not ready. */
    var enabledProvider: () -> Boolean = { true }

    /**
     * The thumb's two icons, from the fleet's Tabler set rather than a typed glyph: a font's
     * guillemet and multiplication sign are whatever the platform's font happens to draw, and on
     * the older panels that is not the same shape twice.
     */
    private val slideIcon: Drawable? by lazy { icon(R.drawable.ic_tabler_chevron_right) }
    private val cancelIcon: Drawable? by lazy { icon(R.drawable.ic_tabler_x) }

    @Suppress("DEPRECATION")
    private fun icon(resource: Int): Drawable? =
        try { resources.getDrawable(resource)?.mutate() } catch (_: Exception) { null }

    private val state = SosSlideState(SosSlideState.DEFAULT_COUNTDOWN_S)
    private var palette: Palette = Palette.DARK
    private var label = TwoPartLabel("", "")
    private var countdownFormatter: (Int) -> String = { it.toString() }
    private var cancelText = context.getString(R.string.sos_countdown_cancel)
    private var accessibleStart = context.getString(R.string.sos_accessibility_start)
    private var accessibleHint = context.getString(R.string.sos_accessibility_hint)
    private var accessibleConfirm = context.getString(R.string.sos_accessibility_confirm)
    private var confirmation: AlertDialog? = null
    private var confirmationRevision = 0L

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val density = context.resources.displayMetrics.density

    private val tick = object : Runnable {
        override fun run() {
            val snapshot = state.tick()
            publish(snapshot)
            if (snapshot.phase == SosPhase.COUNTDOWN) handler.postDelayed(this, 1000L)
        }
    }

    init {
        isFocusable = true
        isFocusableInTouchMode = false
        isClickable = true
        minimumHeight = dp(56)
        contentDescription = ""
    }

    /** Configure the labels and the countdown; call again after a language or config change. */
    fun configure(
        primary: String,
        secondary: String,
        cancelLabel: String,
        countdownSeconds: Int,
        startLabel: String = context.getString(R.string.sos_accessibility_start),
        hintLabel: String = context.getString(R.string.sos_accessibility_hint),
        confirmLabel: String = context.getString(R.string.sos_accessibility_confirm),
        countdownText: (Int) -> String,
    ) {
        dismissConfirmation()
        label = TwoPartLabels.of(primary, secondary)
        cancelText = cancelLabel
        accessibleStart = startLabel
        accessibleHint = hintLabel
        accessibleConfirm = confirmLabel
        countdownFormatter = countdownText
        state.configure(countdownSeconds)
        updateDescription(state.snapshot())
        requestLayout()
        invalidate()
    }

    fun applyPalette(value: Palette) {
        palette = value
        invalidate()
    }

    /** Cancel an armed countdown, for example when the owning screen goes away. */
    fun cancelCountdown() {
        dismissConfirmation()
        handler.removeCallbacks(tick)
        publish(state.cancel())
    }

    private fun dismissConfirmation() {
        confirmationRevision += 1
        val dialog = confirmation
        confirmation = null
        dialog?.dismiss()
    }

    fun isArmed(): Boolean = state.armed

    override fun onDetachedFromWindow() {
        cancelCountdown()
        super.onDetachedFromWindow()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = resolveSize(dp(240), widthMeasureSpec)
        val height = resolveSize(maxOf(dp(56), (40 * resources.displayMetrics.scaledDensity).toInt()), heightMeasureSpec)
        setMeasuredDimension(width, height)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled || !enabledProvider()) return false
        // A tap anywhere during the countdown cancels it, which is the documented escape hatch.
        if (state.armed) {
            if (event.actionMasked == MotionEvent.ACTION_UP) {
                cancelCountdown()
                super.performClick()
            }
            return true
        }
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                publish(state.begin())
                publish(state.drag(progressFor(event.x)))
            }
            MotionEvent.ACTION_MOVE -> publish(state.drag(progressFor(event.x)))
            MotionEvent.ACTION_UP -> {
                publish(state.drag(progressFor(event.x)))
                finishSlide()
                super.performClick()
            }
            MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_OUTSIDE ->
                publish(state.cancel())
            else -> return false
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        if (!isEnabled || !enabledProvider() || !isShown || windowToken == null) return false
        if (state.armed) {
            cancelCountdown()
            return true
        }
        if (confirmation != null) return true
        confirmationRevision += 1
        val revision = confirmationRevision
        val dialog = AlertDialog.Builder(context)
            .setTitle(accessibleStart)
            .setMessage(accessibleConfirm)
            .setNegativeButton(cancelText, null)
            .setPositiveButton(accessibleStart) { selected, _ ->
                // Android queues button callbacks; dismissal must revoke an already queued action.
                if (confirmation !== selected || confirmationRevision != revision ||
                    !isEnabled || !enabledProvider() || !isShown || windowToken == null) return@setPositiveButton
                dismissConfirmation()
                val snapshot = state.confirm()
                publish(snapshot)
                if (snapshot.phase == SosPhase.COUNTDOWN) handler.postDelayed(tick, 1000L)
            }
            .create()
        dialog.setOnDismissListener {
            if (confirmation === dialog) {
                confirmation = null
                confirmationRevision += 1
            }
        }
        confirmation = dialog
        dialog.show()
        return true
    }

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = android.widget.Button::class.java.name
        info.isClickable = isEnabled && enabledProvider()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (!isEnabled || !isTriggerKey(keyCode)) return super.onKeyDown(keyCode, event)
        return true
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (!isEnabled || !isTriggerKey(keyCode)) return super.onKeyUp(keyCode, event)
        if (!event.isCanceled) performClick()
        return true
    }

    private fun isTriggerKey(keyCode: Int): Boolean =
        keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER ||
            keyCode == KeyEvent.KEYCODE_SPACE

    private fun finishSlide() {
        val snapshot = state.release()
        publish(snapshot)
        if (snapshot.phase == SosPhase.COUNTDOWN) handler.postDelayed(tick, 1000L)
    }

    private fun publish(snapshot: SosSnapshot) {
        updateDescription(snapshot)
        invalidate()
        onStateChanged?.invoke(snapshot)
        if (!snapshot.fireNow) return
        handler.removeCallbacks(tick)
        if (enabledProvider()) onTrigger?.invoke()
        publish(state.reset())
    }

    private fun updateDescription(snapshot: SosSnapshot) {
        contentDescription = if (snapshot.phase == SosPhase.COUNTDOWN)
            TwoPartLabels.flatten(TwoPartLabel(countdownFormatter(snapshot.secondsLeft), cancelText))
        else TwoPartLabels.flatten(TwoPartLabel(accessibleStart, accessibleHint))
    }

    private fun progressFor(x: Float): Float {
        val travel = (width - dp(8) - thumbSize()).coerceAtLeast(1)
        return ((x - dp(4) - thumbSize() / 2f) / travel).coerceIn(0f, 1f)
    }

    private fun thumbSize(): Int = (height - dp(8)).coerceAtLeast(dp(32))

    override fun onDraw(canvas: Canvas) {
        val snapshot = state.snapshot()
        val radius = height / 2f
        fill.color = opaque(palette.dangerSoft)
        canvas.drawRoundRect(RectF(0f, 0f, width.toFloat(), height.toFloat()),
                             radius, radius, fill)

        // Label: primary line at full size, deliberate secondary line at 0.8x and muted.
        val labelInk = opaque(palette.dangerInk)
        val primaryText = if (snapshot.phase == SosPhase.COUNTDOWN)
            countdownFormatter(snapshot.secondsLeft) else label.primary
        val secondaryText = if (snapshot.phase == SosPhase.COUNTDOWN)
            cancelText else label.secondary
        text.color = labelInk
        text.typeface = Typeface.DEFAULT
        val primarySize = dp(17).toFloat()
        text.textSize = primarySize
        val centerX = width / 2f
        if (secondaryText.isEmpty()) {
            canvas.drawText(primaryText, centerX, baselineFor(primarySize, 0f), text)
        } else {
            val secondarySize = dp(13).toFloat()
            canvas.drawText(primaryText, centerX,
                            baselineFor(primarySize, -secondarySize * 0.65f), text)
            text.typeface = Typeface.DEFAULT
            text.textSize = secondarySize
            text.alpha = 220
            canvas.drawText(secondaryText, centerX,
                            baselineFor(primarySize, primarySize * 0.85f), text)
            text.alpha = 255
        }

        // Thumb.
        val size = thumbSize()
        val travel = (width - dp(8) - size).coerceAtLeast(0)
        val left = dp(4) + travel * snapshot.progress
        fill.color = opaque(palette.danger)
        canvas.drawRoundRect(
            RectF(left, dp(4).toFloat(), left + size, (dp(4) + size).toFloat()),
            size / 2f, size / 2f, fill,
        )
        val thumbInk = if (UiContrast.inkFor(palette.danger) == Ink.DARK)
            opaque(Palette.DARK_INK) else opaque(Palette.LIGHT_INK)
        val icon = if (snapshot.phase == SosPhase.COUNTDOWN) cancelIcon else slideIcon
        if (icon != null) {
            // The same square the glyph occupied, centred in the thumb.
            val box = size * 0.5f
            val centreX = left + size / 2f
            val centreY = dp(4) + size / 2f
            icon.setBounds(
                Math.round(centreX - box / 2f), Math.round(centreY - box / 2f),
                Math.round(centreX + box / 2f), Math.round(centreY + box / 2f),
            )
            icon.setColorFilter(thumbInk, android.graphics.PorterDuff.Mode.SRC_IN)
            icon.draw(canvas)
        }

        if (isFocused) {
            fill.color = opaque(palette.accent)
            val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = dp(2).toFloat()
                color = opaque(palette.accent)
            }
            canvas.drawRoundRect(
                RectF(dp(1).toFloat(), dp(1).toFloat(),
                      width - dp(1).toFloat(), height - dp(1).toFloat()),
                radius, radius, stroke,
            )
        }
    }

    private fun baselineFor(primarySize: Float, offset: Float): Float =
        height / 2f + primarySize * 0.36f + offset

    private fun opaque(rgb: Int): Int = Color.rgb(
        rgb ushr 16 and 0xff, rgb ushr 8 and 0xff, rgb and 0xff,
    )

    private fun dp(value: Int): Int = (value * density).toInt()

}
