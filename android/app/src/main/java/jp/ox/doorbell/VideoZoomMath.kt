// The zoom state of a live picture (docs/en/ui-guidelines.md, "Live view / monitor"): pinch from
// 1x to 4x, drag to pan while zoomed, double-tap between fit and 2x, and never past the picture's
// own edges. Pure, so the clamp is host-tested; VideoZoom applies the result to the view layer.
package jp.ox.doorbell

internal data class ZoomState(val scale: Float = 1f, val dx: Float = 0f, val dy: Float = 0f) {
    val zoomed: Boolean get() = scale > VideoZoomMath.MIN_SCALE
}

internal object VideoZoomMath {
    const val MIN_SCALE = 1f
    const val MAX_SCALE = 4f
    const val DOUBLE_TAP_SCALE = 2f

    /**
     * Keep [state] legal for a layer of [width] x [height] that scales about its centre: the
     * scale stays in range and the translation stops where the picture's edge meets the box.
     */
    fun clamp(state: ZoomState, width: Int, height: Int): ZoomState {
        val scale = if (state.scale.isNaN()) MIN_SCALE else state.scale.coerceIn(MIN_SCALE, MAX_SCALE)
        val maxX = maxOf(0f, width * (scale - 1f) / 2f)
        val maxY = maxOf(0f, height * (scale - 1f) / 2f)
        return ZoomState(scale, state.dx.coerceIn(-maxX, maxX), state.dy.coerceIn(-maxY, maxY))
    }

    /**
     * Pinch by [factor] about the focal point ([focusX], [focusY]) in box coordinates, so the
     * part of the picture under the fingers stays under them.
     */
    fun pinch(state: ZoomState, factor: Float, focusX: Float, focusY: Float,
              width: Int, height: Int): ZoomState {
        if (factor.isNaN() || factor <= 0f) return clamp(state, width, height)
        val scale = (state.scale * factor).coerceIn(MIN_SCALE, MAX_SCALE)
        val ratio = scale / state.scale
        // Offsets are measured from the box centre, which is the layer's pivot.
        val fx = focusX - width / 2f
        val fy = focusY - height / 2f
        return clamp(ZoomState(scale, fx - (fx - state.dx) * ratio, fy - (fy - state.dy) * ratio),
                     width, height)
    }

    /** Drag by a finger movement; a picture at 1x does not move. */
    fun pan(state: ZoomState, moveX: Float, moveY: Float, width: Int, height: Int): ZoomState =
        if (!state.zoomed) clamp(state, width, height)
        else clamp(state.copy(dx = state.dx + moveX, dy = state.dy + moveY), width, height)

    /** Double-tap: fit when zoomed, otherwise 2x centred on the tapped point. */
    fun doubleTap(state: ZoomState, tapX: Float, tapY: Float, width: Int, height: Int): ZoomState =
        if (state.zoomed) ZoomState()
        else pinch(ZoomState(), DOUBLE_TAP_SCALE, tapX, tapY, width, height)
}
