// Camera1 (android.hardware.Camera) 前面カメラ → NV21 プレビューフレームを core へ push。
// minSdk 21 の旧端末では Camera2 の実装品質が低い機種が多いため、あえて Camera1 を使う。
// setPreviewCallbackWithBuffer + 使い回しバッファ 3 枚で GC 圧を避ける。
package jp.keihan.doorbell

import android.graphics.ImageFormat
import android.hardware.Camera
import android.util.Log
import android.view.SurfaceHolder
import kotlin.math.abs

@Suppress("DEPRECATION")
class CameraFeeder(private val core: DoorbellCore) {

    private var camera: Camera? = null
    private var width = 0
    private var height = 0

    /** 前面カメラ (無ければ背面) を開いてプレビュー開始。失敗時 false。 */
    fun start(holder: SurfaceHolder): Boolean {
        stop()
        val id = pickCameraId()
        if (id < 0) return false
        return try {
            val cam = Camera.open(id)
            val params = cam.parameters
            val size = pickPreviewSize(params)
            params.setPreviewSize(size.width, size.height)
            params.previewFormat = ImageFormat.NV21
            // 门口機は静止画質より安定性 — fps 固定はせず端末既定に任せる
            cam.parameters = params
            width = size.width
            height = size.height

            val bufSize = width * height * ImageFormat.getBitsPerPixel(ImageFormat.NV21) / 8
            repeat(3) { cam.addCallbackBuffer(ByteArray(bufSize)) }
            cam.setPreviewCallbackWithBuffer { data, c ->
                if (data != null) {
                    // NV21: y ストライド = width (Camera1 のバッファは詰めて格納される)
                    core.onCameraFrame(data, 0, width, height, width, System.currentTimeMillis())
                    c.addCallbackBuffer(data)  // バッファ返却 (使い回し)
                }
            }
            cam.setPreviewDisplay(holder)
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
    }

    private fun pickCameraId(): Int {
        val info = Camera.CameraInfo()
        var fallback = -1
        for (i in 0 until Camera.getNumberOfCameras()) {
            Camera.getCameraInfo(i, info)
            if (info.facing == Camera.CameraInfo.CAMERA_FACING_FRONT) return i
            if (fallback < 0) fallback = i
        }
        return fallback
    }

    /** 640x480 に最も近いプレビューサイズを選ぶ (旧端末の帯域・CPU を考慮)。 */
    private fun pickPreviewSize(params: Camera.Parameters): Camera.Size {
        val target = 640 * 480
        return params.supportedPreviewSizes.minByOrNull { abs(it.width * it.height - target) }
            ?: params.previewSize
    }

    companion object {
        private const val TAG = "doorbell-camera"
    }
}
