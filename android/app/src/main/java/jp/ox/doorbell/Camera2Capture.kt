// Headless Camera2 capture for API 21+ door stations, delivering NV21 like the Camera1 path.
//
// Camera2 is used only where the device implements it natively: a LEGACY hardware level is a
// shim over Camera1 and gains nothing, so those devices, legacy19 builds, and any device where
// Camera2 once failed to produce a frame stay on Camera1. The QR scanner's on-screen preview
// also stays on Camera1. Frames arrive on a dedicated display-priority thread.
package jp.ox.doorbell

import android.annotation.TargetApi
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.util.Log
import android.util.Range
import android.util.Size
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs

@TargetApi(21)
internal class Camera2Capture(
    private val context: Context,
    private val onFrame: (ByteArray, Int, Int, Long) -> Unit,
    private val onLost: () -> Unit,
) {
    data class Mount(val facingFront: Boolean, val orientation: Int)

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var nv21: ByteArray? = null
    @Volatile private var stopping = false

    var width = 0
        private set
    var height = 0
        private set
    var mount: Mount? = null
        private set

    /**
     * Open the front camera (rear fallback) near the target size and wait for the first frame.
     * Blocking, bounded by [FIRST_FRAME_TIMEOUT_MS]; false means the caller should use Camera1.
     */
    fun start(targetW: Int, targetH: Int, targetFps: Int): Boolean {
        stop()
        stopping = false
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            ?: return false
        val id = pickCamera(manager) ?: return false
        val characteristics = manager.getCameraCharacteristics(id)
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: return false
        val sizes = map.getOutputSizes(ImageFormat.YUV_420_888)
        if (sizes.isNullOrEmpty()) return false
        val size = pickSize(sizes, targetW, targetH)
        val fpsRange = pickFpsRange(
            characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES),
            targetFps,
        )
        mount = Mount(
            characteristics.get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_FRONT,
            characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0,
        )

        val worker = HandlerThread("doorbell-camera2", Process.THREAD_PRIORITY_DISPLAY)
        worker.start()
        thread = worker
        val h = Handler(worker.looper)
        handler = h
        width = size.width
        height = size.height
        nv21 = ByteArray(width * height * 3 / 2)
        val imageReader = ImageReader.newInstance(width, height, ImageFormat.YUV_420_888, 3)
        reader = imageReader
        val firstFrame = CountDownLatch(1)
        imageReader.setOnImageAvailableListener({ r ->
            val image = try { r.acquireLatestImage() } catch (e: Exception) {
                Log.w(TAG, "acquireLatestImage failed: $e")
                null
            } ?: return@setOnImageAvailableListener
            // stop() runs on another thread and closes the reader, which closes every Image it
            // handed out and unmaps their planes. Reading a plane after that throws, or faults in
            // native code, so the copy and the close exclude each other.
            synchronized(frameLock) {
                try {
                    val buffer = nv21
                    if (!stopping && buffer != null && toNv21(image, buffer)) {
                        onFrame(buffer, width, height, System.currentTimeMillis())
                        firstFrame.countDown()
                    }
                } catch (e: IllegalStateException) {
                    Log.w(TAG, "frame dropped: $e")
                } finally {
                    try { image.close() } catch (e: Exception) { Log.d(TAG, "image close: $e") }
                }
            }
        }, h)

        try {
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    if (stopping) {
                        camera.close()
                        return
                    }
                    device = camera
                    createSession(camera, imageReader, fpsRange, h)
                }

                override fun onDisconnected(camera: CameraDevice) {
                    Log.w(TAG, "camera disconnected")
                    camera.close()
                    if (device === camera) device = null
                    if (!stopping) onLost()
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    Log.w(TAG, "camera error $error")
                    camera.close()
                    if (device === camera) device = null
                    if (!stopping) onLost()
                }
            }, h)
        } catch (e: SecurityException) {
            Log.w(TAG, "camera permission missing: $e")
            stop()
            return false
        } catch (e: Exception) {
            Log.w(TAG, "camera open failed: $e")
            stop()
            return false
        }

        val delivered = try {
            firstFrame.await(FIRST_FRAME_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!delivered) {
            Log.w(TAG, "no Camera2 frame within ${FIRST_FRAME_TIMEOUT_MS}ms")
            stop()
            return false
        }
        Log.i(TAG, "Camera2 capture ${width}x$height fps=$fpsRange")
        return true
    }

    /** Held while a frame is copied and while the reader is closed; see the frame callback. */
    private val frameLock = Any()

    fun stop() {
        stopping = true
        try { session?.close() } catch (e: Exception) { Log.d(TAG, "session close: $e") }
        session = null
        try { device?.close() } catch (e: Exception) { Log.d(TAG, "device close: $e") }
        device = null
        synchronized(frameLock) {
            try { reader?.close() } catch (e: Exception) { Log.d(TAG, "reader close: $e") }
            reader = null
            nv21 = null
        }
        thread?.quitSafely()
        thread = null
        handler = null
        nv21 = null
        width = 0
        height = 0
    }

    @Suppress("DEPRECATION") // createCaptureSession(List, ...) is the API 21-27 entry point.
    private fun createSession(
        camera: CameraDevice,
        imageReader: ImageReader,
        fpsRange: Range<Int>?,
        h: Handler,
    ) {
        try {
            camera.createCaptureSession(listOf(imageReader.surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(captureSession: CameraCaptureSession) {
                        if (stopping) {
                            captureSession.close()
                            return
                        }
                        session = captureSession
                        try {
                            val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                            request.addTarget(imageReader.surface)
                            if (fpsRange != null)
                                request.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange)
                            captureSession.setRepeatingRequest(request.build(), null, h)
                        } catch (e: Exception) {
                            Log.w(TAG, "repeating request failed: $e")
                            if (!stopping) onLost()
                        }
                    }

                    override fun onConfigureFailed(captureSession: CameraCaptureSession) {
                        Log.w(TAG, "capture session configuration failed")
                        if (!stopping) onLost()
                    }
                }, h)
        } catch (e: Exception) {
            Log.w(TAG, "capture session creation failed: $e")
            if (!stopping) onLost()
        }
    }

    private fun pickCamera(manager: CameraManager): String? {
        var fallback: String? = null
        for (id in manager.cameraIdList) {
            val c = manager.getCameraCharacteristics(id)
            when (c.get(CameraCharacteristics.LENS_FACING)) {
                CameraCharacteristics.LENS_FACING_FRONT -> return id
                else -> if (fallback == null) fallback = id
            }
        }
        return fallback
    }

    private fun pickSize(sizes: Array<Size>, tw: Int, th: Int): Size {
        val target = tw * th
        return sizes.minByOrNull { abs(it.width * it.height - target) } ?: sizes[0]
    }

    private fun pickFpsRange(ranges: Array<Range<Int>>?, target: Int): Range<Int>? {
        if (ranges.isNullOrEmpty() || target <= 0) return null
        return ranges.minByOrNull { range ->
            val outside = when {
                target < range.lower -> range.lower - target
                target > range.upper -> target - range.upper
                else -> 0
            }
            outside * 100 + (range.upper - range.lower) + abs(range.upper - target)
        }
    }

    companion object {
        private const val TAG = "doorbell-camera2"
        private const val FIRST_FRAME_TIMEOUT_MS = 3_000L

        /** Whether Camera2 is worth using on this device: native (non-LEGACY) hardware level. */
        fun supported(context: Context): Boolean = try {
            val manager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            val ids = manager?.cameraIdList.orEmpty()
            ids.isNotEmpty() && ids.all { id ->
                manager!!.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL) !=
                    CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY
            }
        } catch (e: Exception) {
            Log.w(TAG, "Camera2 capability probe failed: $e")
            false
        }

        /**
         * Copy a YUV_420_888 image into tightly packed NV21 (Y plane, then interleaved V/U),
         * honouring each plane's row and pixel stride. False when the image does not fit.
         */
        fun toNv21(image: Image, out: ByteArray): Boolean {
            val w = image.width
            val h = image.height
            if (out.size < w * h * 3 / 2 || image.planes.size < 3) return false
            val y = image.planes[0]
            val u = image.planes[1]
            val v = image.planes[2]
            val yBuf = y.buffer
            var pos = 0
            for (row in 0 until h) {
                yBuf.position(row * y.rowStride)
                yBuf.get(out, pos, w)
                pos += w
            }
            val uBuf = u.buffer
            val vBuf = v.buffer
            val chromaH = h / 2
            val chromaW = w / 2
            for (row in 0 until chromaH) {
                for (col in 0 until chromaW) {
                    val vIndex = row * v.rowStride + col * v.pixelStride
                    val uIndex = row * u.rowStride + col * u.pixelStride
                    out[pos++] = vBuf.get(vIndex)
                    out[pos++] = uBuf.get(uIndex)
                }
            }
            return true
        }
    }
}
