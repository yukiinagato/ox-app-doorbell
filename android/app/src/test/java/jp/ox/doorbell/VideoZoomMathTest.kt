package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoZoomMathTest {
    private val landscapeStage = VideoBox(832f, 744f)
    private val portraitStage = VideoBox(800f, 900f)
    private val wide = VideoZoomMath.fit(landscapeStage, 1280, 720)

    @Test
    fun thePictureFillsTheStageWidthOrHeightWhicheverComesFirst() {
        // 16:9 in a nearly square stage: full width, letterboxed above and below.
        assertEquals(832f, wide.width, 0.01f)
        assertEquals(468f, wide.height, 0.01f)
        // 4:3 in the same stage still meets the width first.
        val classic = VideoZoomMath.fit(landscapeStage, 640, 480)
        assertEquals(832f, classic.width, 0.01f)
        assertEquals(624f, classic.height, 0.01f)
        // 4:3 in a wide stage meets the height first.
        val pillar = VideoZoomMath.fit(VideoBox(1280f, 600f), 640, 480)
        assertEquals(800f, pillar.width, 0.01f)
        assertEquals(600f, pillar.height, 0.01f)
        // 16:9 in a portrait stage.
        val inPortrait = VideoZoomMath.fit(portraitStage, 1280, 720)
        assertEquals(800f, inPortrait.width, 0.01f)
        assertEquals(450f, inPortrait.height, 0.01f)
    }

    @Test
    fun rotationIsAppliedBeforeFitting() {
        // A 16:9 frame turned a quarter is a 9:16 picture: it meets the height first.
        for (rotation in listOf(90, 270, -90, 450)) {
            val turned = VideoZoomMath.fit(landscapeStage, 1280, 720, rotation)
            assertEquals(744f, turned.height, 0.01f)
            assertEquals(744f * 9f / 16f, turned.width, 0.01f)
        }
        assertEquals(wide, VideoZoomMath.fit(landscapeStage, 1280, 720, 180))
        // In a portrait stage the same picture meets the width first.
        val tall = VideoZoomMath.fit(portraitStage, 1280, 720, 90)
        assertEquals(900f * 9f / 16f, tall.width, 0.01f)
        assertEquals(900f, tall.height, 0.01f)
    }

    @Test
    fun anUnknownSourceUsesTheWholeStage() {
        assertEquals(landscapeStage, VideoZoomMath.fit(landscapeStage, 0, 0))
        assertEquals(landscapeStage, VideoZoomMath.fit(landscapeStage, 640, -1))
        assertEquals(1f to 1f, VideoZoomMath.stretchedViewScale(landscapeStage, 0, 720))
    }

    @Test
    fun aStretchedViewIsScaledBackToThePictureAspect() {
        val (x, y) = VideoZoomMath.stretchedViewScale(landscapeStage, 1280, 720)
        assertEquals(1f, x, 0.001f)
        assertEquals(468f / 744f, y, 0.001f)
        // Turned a quarter, the view's x axis is drawn vertically on screen.
        val (rx, ry) = VideoZoomMath.stretchedViewScale(landscapeStage, 1280, 720, 90)
        val turned = VideoZoomMath.fit(landscapeStage, 1280, 720, 90)
        assertEquals(turned.height, landscapeStage.width * rx, 0.01f)
        assertEquals(turned.width, landscapeStage.height * ry, 0.01f)
    }

    @Test
    fun scaleStaysBetweenOneAndFour() {
        assertEquals(1f, VideoZoomMath.pinch(ZoomState(), 0.2f, 400f, 225f, landscapeStage, wide).scale, 0f)
        assertEquals(4f, VideoZoomMath.pinch(ZoomState(), 9f, 400f, 225f, landscapeStage, wide).scale, 0f)
        assertEquals(4f, VideoZoomMath.clamp(ZoomState(scale = 12f), landscapeStage, wide).scale, 0f)
        assertEquals(1f, VideoZoomMath.clamp(ZoomState(scale = Float.NaN), landscapeStage, wide).scale, 0f)
        assertTrue(VideoZoomMath.MAX_SCALE >= 4f)
    }

    @Test
    fun aPictureAtFitNeverMoves() {
        val moved = VideoZoomMath.pan(ZoomState(), 120f, -80f, landscapeStage, wide)
        assertEquals(ZoomState(), moved)
        assertFalse(moved.zoomed)
    }

    @Test
    fun theZoomedPictureGrowsIntoTheLetterboxBars() {
        // At 1x the picture covers 832 x 468 of the 832 x 744 stage.
        assertEquals(wide, VideoZoomMath.visible(ZoomState(), landscapeStage, wide))
        // At 1.5x it is 1248 x 702: wider than the stage, and taller than the fitted picture.
        val partly = VideoZoomMath.visible(ZoomState(scale = 1.5f), landscapeStage, wide)
        assertEquals(832f, partly.width, 0.01f)
        assertEquals(702f, partly.height, 0.01f)
        assertTrue(partly.height > wide.height)
        // At 2x it covers the whole stage.
        assertEquals(landscapeStage, VideoZoomMath.visible(ZoomState(scale = 2f), landscapeStage, wide))
    }

    @Test
    fun anAxisSmallerThanTheStageStaysCentred() {
        // 1.5x: 1248 wide (larger than 832), 702 tall (smaller than 744).
        val dragged = VideoZoomMath.pan(ZoomState(scale = 1.5f), 10_000f, 10_000f, landscapeStage, wide)
        assertEquals((1248f - 832f) / 2f, dragged.dx, 0.01f)
        assertEquals(0f, dragged.dy, 0f)
        val back = VideoZoomMath.pan(ZoomState(scale = 1.5f), -10_000f, -10_000f, landscapeStage, wide)
        assertEquals(-(1248f - 832f) / 2f, back.dx, 0.01f)
        assertEquals(0f, back.dy, 0f)
    }

    @Test
    fun panNeverBringsAPictureEdgeInsideTheStage() {
        val stages = listOf(landscapeStage, portraitStage, VideoBox(1280f, 600f))
        val sources = listOf(Triple(1280, 720, 0), Triple(640, 480, 0), Triple(1280, 720, 90))
        for (stage in stages) for ((width, height, rotation) in sources) {
            val picture = VideoZoomMath.fit(stage, width, height, rotation)
            for (scale in listOf(1f, 1.3f, 2f, 3.1f, 4f)) for (push in listOf(-9_000f, 9_000f)) {
                val state = VideoZoomMath.pan(ZoomState(scale = scale), push, push, stage, picture)
                for ((size, limit, offset) in listOf(
                    Triple(picture.width * scale, stage.width, state.dx),
                    Triple(picture.height * scale, stage.height, state.dy))) {
                    if (size <= limit) assertEquals(0f, offset, 0f)
                    else {
                        // Edges of the zoomed picture, measured from the stage centre.
                        assertTrue(offset - size / 2f <= -limit / 2f + 0.01f)
                        assertTrue(offset + size / 2f >= limit / 2f - 0.01f)
                    }
                }
            }
        }
    }

    @Test
    fun pinchKeepsThePointUnderTheFingers() {
        // A picture point p (from the centre) is drawn at p * scale + offset.
        val focusX = 600f
        val focusY = 380f
        val before = ZoomState(scale = 2.5f, dx = 40f, dy = -10f)
        val pictureX = (focusX - landscapeStage.width / 2f - before.dx) / before.scale
        val pictureY = (focusY - landscapeStage.height / 2f - before.dy) / before.scale
        val after = VideoZoomMath.pinch(before, 1.2f, focusX, focusY, landscapeStage, wide)
        assertEquals(3f, after.scale, 0.001f)
        assertEquals(focusX - landscapeStage.width / 2f, pictureX * after.scale + after.dx, 0.01f)
        assertEquals(focusY - landscapeStage.height / 2f, pictureY * after.scale + after.dy, 0.01f)
    }

    @Test
    fun pinchingOutAtACornerNeverShowsPastTheEdge() {
        val after = VideoZoomMath.pinch(ZoomState(), 4f, 0f, 0f, landscapeStage, wide)
        assertEquals(4f, after.scale, 0f)
        assertEquals((wide.width * 4f - landscapeStage.width) / 2f, after.dx, 0.001f)
        assertEquals((wide.height * 4f - landscapeStage.height) / 2f, after.dy, 0.001f)
    }

    @Test
    fun pinchingBackInRecentresThePicture() {
        val zoomed = VideoZoomMath.pan(ZoomState(scale = 3f), 500f, 300f, landscapeStage, wide)
        val fit = VideoZoomMath.pinch(zoomed, 0.1f, 100f, 100f, landscapeStage, wide)
        assertEquals(ZoomState(), fit)
    }

    @Test
    fun doubleTapTogglesBetweenFitAndTwoTimes() {
        val centre = VideoZoomMath.doubleTap(ZoomState(), landscapeStage.width / 2f,
                                             landscapeStage.height / 2f, landscapeStage, wide)
        assertEquals(ZoomState(scale = 2f), centre)
        assertEquals(ZoomState(), VideoZoomMath.doubleTap(centre, 10f, 10f, landscapeStage, wide))
        val corner = VideoZoomMath.doubleTap(ZoomState(), 0f, 0f, landscapeStage, wide)
        assertEquals(2f, corner.scale, 0f)
        assertEquals((wide.width * 2f - landscapeStage.width) / 2f, corner.dx, 0.001f)
        assertEquals((wide.height * 2f - landscapeStage.height) / 2f, corner.dy, 0.001f)
    }

    @Test
    fun aSmallerStageTightensThePan() {
        val picture = VideoZoomMath.fit(portraitStage, 1280, 720)
        val before = VideoZoomMath.pan(ZoomState(scale = 3f), 10_000f, 10_000f, landscapeStage, wide)
        val after = VideoZoomMath.clamp(before, portraitStage, picture)
        assertEquals((picture.width * 3f - portraitStage.width) / 2f, after.dx, 0.001f)
        assertEquals((picture.height * 3f - portraitStage.height) / 2f, after.dy, 0.001f)
    }
}
