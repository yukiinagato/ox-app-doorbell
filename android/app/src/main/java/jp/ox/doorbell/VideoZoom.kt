// Pinch-to-zoom, pan, and double-tap reset for the incoming-call video (parity with iOS).
//
// The transform is applied to one layer that holds only the video views, so overlays on the
// video box (admin QR, debug line, sent-reply text) keep their size. The texture view's own
// rotation transform is left to the player.
package jp.ox.doorbell

import android.annotation.SuppressLint
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View

internal class VideoZoom(private val layer: View, touchSurface: View) {
    private var scale = 1f
    private var dx = 0f
    private var dy = 0f

    private val scaleDetector = ScaleGestureDetector(layer.context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: ScaleGestureDetector): Boolean {
                scale = (scale * detector.scaleFactor).coerceIn(MIN_SCALE, MAX_SCALE)
                apply()
                return true
            }
        })

    private val gestureDetector = GestureDetector(layer.context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onScroll(e1: MotionEvent?, e2: MotionEvent, distanceX: Float,
                                  distanceY: Float): Boolean {
                if (scale <= 1f) return false
                dx -= distanceX
                dy -= distanceY
                apply()
                return true
            }

            override fun onDoubleTap(e: MotionEvent): Boolean {
                reset()
                return true
            }
        })

    init {
        attach(touchSurface)
    }

    @SuppressLint("ClickableViewAccessibility") // Gestures only; double-tap mirrors reset().
    private fun attach(surface: View) {
        surface.setOnTouchListener { _, event ->
            scaleDetector.onTouchEvent(event)
            gestureDetector.onTouchEvent(event)
            scale > 1f || event.pointerCount > 1
        }
    }

    fun reset() {
        scale = 1f
        dx = 0f
        dy = 0f
        apply()
    }

    private fun apply() {
        // Keep the zoomed picture covering the box: panning stops at the edges.
        val maxX = layer.width * (scale - 1f) / 2f
        val maxY = layer.height * (scale - 1f) / 2f
        dx = dx.coerceIn(-maxX, maxX)
        dy = dy.coerceIn(-maxY, maxY)
        layer.scaleX = scale
        layer.scaleY = scale
        layer.translationX = dx
        layer.translationY = dy
    }

    private companion object {
        const val MIN_SCALE = 1f
        const val MAX_SCALE = 4f
    }
}
