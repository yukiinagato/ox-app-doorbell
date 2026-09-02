package jp.keihan.doorbell

import android.annotation.SuppressLint
import android.os.Handler
import android.view.KeyEvent
import android.view.MotionEvent
import android.widget.Button

/** Binds the safety-critical SOS action to an uninterrupted two-second hold. */
internal object SosHoldTrigger {
    @SuppressLint("ClickableViewAccessibility")
    fun bind(
        button: Button,
        handler: Handler,
        enabled: () -> Boolean,
        trigger: () -> Unit,
    ) {
        var holding = false
        val fire = Runnable {
            if (holding && enabled()) {
                holding = false
                button.isSelected = false
                trigger()
            }
        }
        fun begin() {
            if (holding) return
            holding = true
            button.isSelected = true
            handler.postDelayed(fire, HOLD_MS)
        }
        fun cancel() {
            holding = false
            button.isSelected = false
            handler.removeCallbacks(fire)
        }
        button.setOnClickListener {
            button.announceForAccessibility(button.contentDescription)
        }
        button.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> begin()
                MotionEvent.ACTION_UP -> {
                    val wasHolding = holding
                    cancel()
                    if (wasHolding) button.performClick()
                }
                MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_OUTSIDE -> cancel()
            }
            true
        }
        button.setOnKeyListener { _, keyCode, event ->
            if (keyCode != KeyEvent.KEYCODE_DPAD_CENTER && keyCode != KeyEvent.KEYCODE_ENTER &&
                keyCode != KeyEvent.KEYCODE_SPACE) return@setOnKeyListener false
            when (event.action) {
                KeyEvent.ACTION_DOWN -> if (event.repeatCount == 0) begin()
                KeyEvent.ACTION_UP -> cancel()
            }
            true
        }
    }

    const val HOLD_SECONDS = 2
    private const val HOLD_MS = HOLD_SECONDS * 1_000L
}
