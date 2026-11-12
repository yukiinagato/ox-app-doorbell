// Pinch-to-zoom, pan, and double-tap for every live picture (docs/en/ui-guidelines.md, "Live
// view / monitor"). The incoming call, the established call and the monitor share one video box,
// and both renderers (the H.264 TextureView and the MJPEG/still ImageView) sit in one layer, so
// one transform covers them all on both flavors.
//
// The transform is applied to that layer only, so overlays on the video box (admin QR, debug
// line, sent-reply text) keep their size. The texture view's own rotation transform is left to
// the player. The call actions live outside the video box, so a gesture can neither press nor
// block them.
package jp.ox.doorbell

import android.annotation.SuppressLint
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View

internal class VideoZoom(private val layer: View, touchSurface: View) {
    private var state = ZoomState()

    private val scaleDetector = ScaleGestureDetector(layer.context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: ScaleGestureDetector): Boolean {
                apply(VideoZoomMath.pinch(state, detector.scaleFactor, detector.focusX,
                                          detector.focusY, layer.width, layer.height))
                return true
            }
        })

    private val gestureDetector = GestureDetector(layer.context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onScroll(e1: MotionEvent?, e2: MotionEvent, distanceX: Float,
                                  distanceY: Float): Boolean {
                if (!state.zoomed) return false
                apply(VideoZoomMath.pan(state, -distanceX, -distanceY, layer.width, layer.height))
                return true
            }

            override fun onDoubleTap(e: MotionEvent): Boolean {
                apply(VideoZoomMath.doubleTap(state, e.x, e.y, layer.width, layer.height))
                return true
            }
        })

    init {
        attach(touchSurface)
        // A rotation or a pane change resizes the box; the pan limits move with it.
        layer.addOnLayoutChangeListener { _, left, top, right, bottom, oldLeft, oldTop,
                                          oldRight, oldBottom ->
            if (right - left != oldRight - oldLeft || bottom - top != oldBottom - oldTop)
                apply(VideoZoomMath.clamp(state, layer.width, layer.height))
        }
    }

    @SuppressLint("ClickableViewAccessibility") // Gestures only; there is nothing to click.
    private fun attach(surface: View) {
        surface.setOnTouchListener { _, event ->
            scaleDetector.onTouchEvent(event)
            gestureDetector.onTouchEvent(event)
            // Claim the gesture while zoomed or pinching so a scrolling parent cannot take it.
            val claim = state.zoomed || event.pointerCount > 1
            if (claim) surface.parent?.requestDisallowInterceptTouchEvent(true)
            claim || event.actionMasked == MotionEvent.ACTION_DOWN
        }
    }

    /** Back to fit; called when the door or the call changes. */
    fun reset() = apply(ZoomState())

    private fun apply(next: ZoomState) {
        state = next
        layer.scaleX = next.scale
        layer.scaleY = next.scale
        layer.translationX = next.dx
        layer.translationY = next.dy
    }
}
