package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoZoomMathTest {
    private val w = 800
    private val h = 450

    @Test
    fun scaleStaysBetweenOneAndFour() {
        assertEquals(1f, VideoZoomMath.pinch(ZoomState(), 0.2f, 400f, 225f, w, h).scale, 0f)
        assertEquals(4f, VideoZoomMath.pinch(ZoomState(), 9f, 400f, 225f, w, h).scale, 0f)
        assertEquals(4f, VideoZoomMath.clamp(ZoomState(scale = 12f), w, h).scale, 0f)
        assertEquals(1f, VideoZoomMath.clamp(ZoomState(scale = Float.NaN), w, h).scale, 0f)
        assertTrue(VideoZoomMath.MAX_SCALE >= 4f)
    }

    @Test
    fun aPictureAtFitNeverMoves() {
        val moved = VideoZoomMath.pan(ZoomState(), 120f, -80f, w, h)
        assertEquals(ZoomState(), moved)
        assertFalse(moved.zoomed)
    }

    @Test
    fun panStopsAtThePictureEdges() {
        val zoomed = ZoomState(scale = 2f)
        val farRight = VideoZoomMath.pan(zoomed, 10_000f, 10_000f, w, h)
        assertEquals(w * (2f - 1f) / 2f, farRight.dx, 0.001f)
        assertEquals(h * (2f - 1f) / 2f, farRight.dy, 0.001f)
        val farLeft = VideoZoomMath.pan(zoomed, -10_000f, -10_000f, w, h)
        assertEquals(-w / 2f, farLeft.dx, 0.001f)
        assertEquals(-h / 2f, farLeft.dy, 0.001f)
        val inside = VideoZoomMath.pan(zoomed, 30f, -20f, w, h)
        assertEquals(30f, inside.dx, 0.001f)
        assertEquals(-20f, inside.dy, 0.001f)
    }

    @Test
    fun pinchKeepsThePointUnderTheFingers() {
        // A picture point p (from the centre) is drawn at p * scale + offset.
        val focusX = 600f
        val focusY = 100f
        val before = ZoomState(scale = 1.5f, dx = 40f, dy = -10f)
        val pictureX = (focusX - w / 2f - before.dx) / before.scale
        val pictureY = (focusY - h / 2f - before.dy) / before.scale
        val after = VideoZoomMath.pinch(before, 1.6f, focusX, focusY, w, h)
        assertEquals(2.4f, after.scale, 0.001f)
        assertEquals(focusX - w / 2f, pictureX * after.scale + after.dx, 0.01f)
        assertEquals(focusY - h / 2f, pictureY * after.scale + after.dy, 0.01f)
    }

    @Test
    fun pinchingOutAtACornerNeverShowsPastTheEdge() {
        val after = VideoZoomMath.pinch(ZoomState(), 4f, 0f, 0f, w, h)
        assertEquals(4f, after.scale, 0f)
        assertEquals(w * 3f / 2f, after.dx, 0.001f)
        assertEquals(h * 3f / 2f, after.dy, 0.001f)
    }

    @Test
    fun zoomingBackOutRecentresThePicture() {
        val corner = VideoZoomMath.pinch(ZoomState(), 4f, 0f, 0f, w, h)
        val fit = VideoZoomMath.pinch(corner, 0.1f, 700f, 400f, w, h)
        assertEquals(ZoomState(), fit)
    }

    @Test
    fun doubleTapTogglesBetweenFitAndTwoTimes() {
        val zoomed = VideoZoomMath.doubleTap(ZoomState(), 400f, 225f, w, h)
        assertEquals(ZoomState(scale = 2f), zoomed)
        assertEquals(ZoomState(), VideoZoomMath.doubleTap(zoomed, 10f, 10f, w, h))
        assertEquals(ZoomState(), VideoZoomMath.doubleTap(ZoomState(3.3f, 50f, 50f), 10f, 10f, w, h))
        val offCentre = VideoZoomMath.doubleTap(ZoomState(), 800f, 450f, w, h)
        assertEquals(2f, offCentre.scale, 0f)
        assertEquals(-w / 2f, offCentre.dx, 0.001f)
        assertEquals(-h / 2f, offCentre.dy, 0.001f)
    }

    @Test
    fun aResizeBringsThePanBackInsideTheNewBox() {
        val state = ZoomState(scale = 2f, dx = 400f, dy = 225f)
        val smaller = VideoZoomMath.clamp(state, 400, 200)
        assertEquals(200f, smaller.dx, 0.001f)
        assertEquals(100f, smaller.dy, 0.001f)
        assertEquals(ZoomState(scale = 2f), VideoZoomMath.clamp(ZoomState(scale = 2f, dx = 5f, dy = 5f), 0, 0))
    }
}
