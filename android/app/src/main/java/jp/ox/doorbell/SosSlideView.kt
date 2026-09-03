// Slide-to-trigger SOS control (spec §4.4). Framework views only: a custom View that draws its
// own track, thumb, and two-part label, plus a D-pad path so the control is reachable on a TV.
//
// The control never calls core itself; it reports the countdown reaching zero to its owner.
package jp.ox.doorbell

import android.annotation.SuppressLint
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
    private var cancelText = ""

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
        countdownText: (Int) -> String,
    ) {
        label = TwoPartLabels.of(primary, secondary)
        cancelText = cancelLabel
        countdownFormatter = countdownText
        state.configure(countdownSeconds)
        contentDescription = TwoPartLabels.flatten(label)
        invalidate()
    }

    fun applyPalette(value: Palette) {
        palette = value
        invalidate()
    }

    /** Cancel an armed countdown, for example when the owning screen goes away. */
    fun cancelCountdown() {
        handler.removeCallbacks(tick)
        publish(state.cancel())
    }

    fun isArmed(): Boolean = state.armed

    override fun onDetachedFromWindow() {
        handler.removeCallbacks(tick)
        super.onDetachedFromWindow()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = resolveSize(dp(240), widthMeasureSpec)
        val height = resolveSize(dp(56), heightMeasureSpec)
        setMeasuredDimension(width, height)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled) return false
        // A tap anywhere during the countdown cancels it, which is the documented escape hatch.
        if (state.armed) {
            if (event.actionMasked == MotionEvent.ACTION_UP) {
                cancelCountdown()
                performClick()
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
                performClick()
            }
            MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_OUTSIDE ->
                publish(state.cancel())
            else -> return false
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    /**
     * D-pad path: holding the centre key sweeps the thumb so a remote can reach the same armed
     * state, and pressing it during a countdown cancels, matching the touch behaviour.
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (!isEnabled || !isTriggerKey(keyCode)) return super.onKeyDown(keyCode, event)
        if (state.armed) {
            cancelCountdown()
            return true
        }
        if (event.repeatCount == 0) publish(state.begin())
        val steps = (event.repeatCount + 1).coerceAtMost(DPAD_STEPS)
        publish(state.drag(steps.toFloat() / DPAD_STEPS))
        return true
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (!isEnabled || !isTriggerKey(keyCode)) return super.onKeyUp(keyCode, event)
        finishSlide()
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
        invalidate()
        onStateChanged?.invoke(snapshot)
        if (!snapshot.fireNow) return
        handler.removeCallbacks(tick)
        if (enabledProvider()) onTrigger?.invoke()
        publish(state.reset())
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
        text.typeface = Typeface.DEFAULT_BOLD
        val primarySize = dp(14).toFloat()
        text.textSize = primarySize
        val centerX = width / 2f
        if (secondaryText.isEmpty()) {
            canvas.drawText(primaryText, centerX, baselineFor(primarySize, 0f), text)
        } else {
            val secondarySize = primarySize * TwoPartLabels.SECONDARY_SCALE
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

    private companion object {
        const val DPAD_STEPS = 6
    }
}
