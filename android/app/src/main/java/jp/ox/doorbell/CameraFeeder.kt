// Camera1 sends NV21 preview frames to Core.
// Legacy devices have inconsistent Camera2 implementations, so Camera1 is intentional.
// Three reusable callback buffers reduce garbage-collection pressure on API19 hardware.
package jp.ox.doorbell

import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.Camera
import android.util.Log
import android.view.SurfaceHolder
import kotlin.math.abs

@Suppress("DEPRECATION")
internal class CameraFeeder(private val core: DoorbellCore) {

    private data class CameraMount(val id: Int, val facing: Int, val orientation: Int)

    private var camera: Camera? = null
    private var headlessTexture: SurfaceTexture? = null
    private var width = 0
    private var height = 0

    val frameWidth: Int get() = width
    val frameHeight: Int get() = height

    /** Optional H.264 encoder sink, enabled only while Core requests an encoded stream. */
    @Volatile
    var encoder: VideoEncoder? = null

    // Camera1 delivers NV21 in the sensor's native orientation.  The remote display
    // therefore needs the camera mount angle combined with the device orientation;
    // forwarding only the latter leaves most phone cameras off by 90 degrees.
    private val selectedCamera: CameraMount? by lazy {
        val info = Camera.CameraInfo()
        var fallback: CameraMount? = null
        for (i in 0 until Camera.getNumberOfCameras()) {
            Camera.getCameraInfo(i, info)
            val mount = CameraMount(i, info.facing, info.orientation)
            if (info.facing == Camera.CameraInfo.CAMERA_FACING_FRONT) return@lazy mount
            if (fallback == null) fallback = mount
        }
        fallback
    }

    /** Clockwise correction needed to show a native camera frame upright remotely. */
    fun frameRotationForDeviceRotation(deviceRotation: Int): Int {
        val degrees = ((deviceRotation % 360) + 360) % 360
        val mount = selectedCamera ?: return degrees
        return if (mount.facing == Camera.CameraInfo.CAMERA_FACING_FRONT) {
            (mount.orientation + degrees) % 360
        } else {
            (mount.orientation - degrees + 360) % 360
        }
    }

    /**
     * Open the front camera, or the rear fallback, near the requested dimensions. Core scales
     * oversized MJPEG frames, while the H.264 path uses the requested codec dimensions directly.
     */
    fun start(holder: SurfaceHolder, targetW: Int = 640, targetH: Int = 480,
              targetFps: Int = 0, preferBack: Boolean = false): Boolean =
        startInternal(holder, targetW, targetH, targetFps, preferBack)

    /** Service-owned capture path; no Activity surface is required. */
    fun startHeadless(targetW: Int = 640, targetH: Int = 480,
                      targetFps: Int = 0): Boolean =
        startInternal(null, targetW, targetH, targetFps, preferBack = false)

    private fun startInternal(holder: SurfaceHolder?, targetW: Int, targetH: Int,
                              targetFps: Int, preferBack: Boolean): Boolean {
        stop()
        val id = pickCameraId(preferBack)
        if (id < 0) return false
        return try {
            val cam = Camera.open(id)
            val params = cam.parameters
            val size = pickPreviewSize(params, targetW, targetH)
            params.setPreviewSize(size.width, size.height)
            params.previewFormat = ImageFormat.NV21
            if (targetFps > 0) {
                val range = pickPreviewFpsRange(params, targetFps * 1000)
                params.setPreviewFpsRange(range[0], range[1])
                // Prefer continuous capture to avoid still-image ISP stalls on legacy devices.
                params.setRecordingHint(true)
                Log.i(TAG, "preview ${size.width}x${size.height} fps=${range[0]}..${range[1]}")
            }
            cam.parameters = params
            width = size.width
            height = size.height

            val bufSize = width * height * ImageFormat.getBitsPerPixel(ImageFormat.NV21) / 8
            repeat(3) { cam.addCallbackBuffer(ByteArray(bufSize)) }
            cam.setPreviewCallbackWithBuffer { data, c ->
                if (data != null) {
                    val now = System.currentTimeMillis()
                    // Queue H.264 first so MJPEG frame-bus work does not delay the codec path.
                    encoder?.feed(data, width, height, now)
                    // Camera1 supplies tightly packed NV21 with a Y stride equal to width.
                    core.onCameraFrame(data, 0, width, height, width, now)
                    c.addCallbackBuffer(data)
                }
            }
            if (holder != null) {
                cam.setPreviewDisplay(holder)
            } else {
                headlessTexture = SurfaceTexture(0)
                cam.setPreviewTexture(headlessTexture)
            }
            cam.startPreview()
            camera = cam
            true
        } catch (e: Exception) {
            Log.w(TAG, "camera start failed: $e")
            stop()
            false
        }
    }

    fun stop() {
        try {
            camera?.setPreviewCallbackWithBuffer(null)
            camera?.stopPreview()
            camera?.release()
        } catch (_: Exception) { }
        camera = null
        try { headlessTexture?.release() } catch (_: Exception) { }
        headlessTexture = null
        width = 0
        height = 0
    }

    /**
     * The visitor camera faces the visitor, so it is the front one. A QR scanner points away
     * from the operator, so it prefers a back-facing lens and falls back to whatever exists.
     */
    private fun pickCameraId(preferBack: Boolean): Int {
        if (!preferBack) return selectedCamera?.id ?: -1
        val info = Camera.CameraInfo()
        for (i in 0 until Camera.getNumberOfCameras()) {
            Camera.getCameraInfo(i, info)
            if (info.facing == Camera.CameraInfo.CAMERA_FACING_BACK) return i
        }
        return selectedCamera?.id ?: -1
    }

    /** Choose the preview size nearest the target to bound legacy CPU and bandwidth use. */
    private fun pickPreviewSize(params: Camera.Parameters, tw: Int, th: Int): Camera.Size {
        val target = tw * th
        return params.supportedPreviewSizes.minByOrNull { abs(it.width * it.height - target) }
            ?: params.previewSize
    }

    /** Prefer an exact fixed rate, then the narrowest range containing the target. */
    private fun pickPreviewFpsRange(params: Camera.Parameters, target: Int): IntArray {
        val ranges = params.supportedPreviewFpsRange
        if (ranges.isNullOrEmpty()) return intArrayOf(target, target)
        return ranges.minByOrNull { range ->
            val outside = when {
                target < range[0] -> range[0] - target
                target > range[1] -> target - range[1]
                else -> 0
            }
            outside * 100 + (range[1] - range[0]) + abs(range[1] - target)
        } ?: ranges[0]
    }

    companion object {
        private const val TAG = "doorbell-camera"

        /** Whether this hardware has any camera at all; TV boxes and some panels have none. */
        fun deviceHasCamera(): Boolean = try {
            Camera.getNumberOfCameras() > 0
        } catch (_: Exception) {
            false
        }
    }
}
