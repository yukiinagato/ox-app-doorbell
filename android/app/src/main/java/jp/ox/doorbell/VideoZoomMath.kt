// The fit and zoom of a live picture (docs/en/ui-guidelines.md, "Live view / monitor"). The stage
// is everything the screen leaves for video; the picture is aspect-fitted and centred in it at 1x.
// Zoom runs from 1x to 4x and is clipped by the stage, not by the fitted picture, so a zoomed
// picture grows into the letterbox bars. Pan is clamped per axis: where the zoomed picture is
// larger than the stage its edges stay outside the stage edges, otherwise it stays centred.
// Pure, so the rules are host-tested; VideoZoom applies the result to the view layer.
package jp.ox.doorbell

internal data class ZoomState(val scale: Float = 1f, val dx: Float = 0f, val dy: Float = 0f) {
    val zoomed: Boolean get() = scale > VideoZoomMath.MIN_SCALE
}

/** A width and height in pixels: the stage, or the picture as fitted in it at 1x. */
internal data class VideoBox(val width: Float, val height: Float)

internal object VideoZoomMath {
    const val MIN_SCALE = 1f
    const val MAX_SCALE = 4f
    const val DOUBLE_TAP_SCALE = 2f

    /**
     * The picture at 1x: a [sourceWidth] x [sourceHeight] frame, turned by [rotation] degrees,
     * fills the stage's width or height, whichever is reached first. An unknown source size
     * yields the stage itself, so a picture that has not reported its size zooms as before.
     */
    fun fit(stage: VideoBox, sourceWidth: Int, sourceHeight: Int, rotation: Int = 0): VideoBox {
        val turned = quarterTurned(rotation)
        val width = (if (turned) sourceHeight else sourceWidth).toFloat()
        val height = (if (turned) sourceWidth else sourceHeight).toFloat()
        if (width <= 0f || height <= 0f || stage.width <= 0f || stage.height <= 0f) return stage
        val ratio = minOf(stage.width / width, stage.height / height)
        return VideoBox(width * ratio, height * ratio)
    }

    /**
     * Scale factors for a view that is as large as the stage, stretches its frame over itself,
     * and is then rotated by [rotation] about its centre (a TextureView): with them the frame
     * appears as [fit] describes instead of stretched.
     */
    fun stretchedViewScale(stage: VideoBox, sourceWidth: Int, sourceHeight: Int,
                           rotation: Int = 0): Pair<Float, Float> {
        if (sourceWidth <= 0 || sourceHeight <= 0 || stage.width <= 0f || stage.height <= 0f)
            return 1f to 1f
        val fitted = fit(stage, sourceWidth, sourceHeight, rotation)
        // The view's own x axis carries the frame's width, whichever way it ends up on screen.
        return if (quarterTurned(rotation)) fitted.height / stage.width to fitted.width / stage.height
               else fitted.width / stage.width to fitted.height / stage.height
    }

    /**
     * Keep [state] legal: the scale stays in range, and on each axis the translation stops where
     * the zoomed picture's edge meets the stage's edge, or is zero while the picture is not
     * larger than the stage on that axis.
     */
    fun clamp(state: ZoomState, stage: VideoBox, picture: VideoBox): ZoomState {
        val scale = if (state.scale.isNaN()) MIN_SCALE else state.scale.coerceIn(MIN_SCALE, MAX_SCALE)
        val maxX = maxOf(0f, (picture.width * scale - stage.width) / 2f)
        val maxY = maxOf(0f, (picture.height * scale - stage.height) / 2f)
        return ZoomState(scale, finite(state.dx).coerceIn(-maxX, maxX),
                         finite(state.dy).coerceIn(-maxY, maxY))
    }

    /**
     * Pinch by [factor] about the focal point ([focusX], [focusY]) in stage coordinates, so the
     * part of the picture under the fingers stays under them where the clamp allows it.
     */
    fun pinch(state: ZoomState, factor: Float, focusX: Float, focusY: Float,
              stage: VideoBox, picture: VideoBox): ZoomState {
        if (factor.isNaN() || factor <= 0f) return clamp(state, stage, picture)
        val scale = (state.scale * factor).coerceIn(MIN_SCALE, MAX_SCALE)
        val ratio = scale / state.scale
        // Offsets are measured from the stage centre, which is the layer's pivot.
        val fx = focusX - stage.width / 2f
        val fy = focusY - stage.height / 2f
        return clamp(ZoomState(scale, fx - (fx - state.dx) * ratio, fy - (fy - state.dy) * ratio),
                     stage, picture)
    }

    /** Drag by a finger movement; a picture at 1x does not move. */
    fun pan(state: ZoomState, moveX: Float, moveY: Float,
            stage: VideoBox, picture: VideoBox): ZoomState =
        if (!state.zoomed) clamp(state, stage, picture)
        else clamp(state.copy(dx = state.dx + moveX, dy = state.dy + moveY), stage, picture)

    /** Double-tap: fit when zoomed, otherwise 2x centred on the tapped point. */
    fun doubleTap(state: ZoomState, tapX: Float, tapY: Float,
                  stage: VideoBox, picture: VideoBox): ZoomState =
        if (state.zoomed) ZoomState()
        else pinch(ZoomState(), DOUBLE_TAP_SCALE, tapX, tapY, stage, picture)

    /** The part of the stage the picture covers in [state]: it grows until it is the stage. */
    fun visible(state: ZoomState, stage: VideoBox, picture: VideoBox): VideoBox =
        VideoBox(minOf(stage.width, picture.width * state.scale),
                 minOf(stage.height, picture.height * state.scale))

    private fun quarterTurned(rotation: Int): Boolean = ((rotation % 180) + 180) % 180 == 90

    private fun finite(value: Float): Float = if (value.isNaN() || value.isInfinite()) 0f else value
}
