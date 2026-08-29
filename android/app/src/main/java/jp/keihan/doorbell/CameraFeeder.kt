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

    /** H.264 硬編への分岐先 (Phase 6a)。稼働中のみ feed される (null = 分岐なし)。
     *  MainActivity が wanted ポーリングで start/stop を切り替える。 */
    @Volatile
    var encoder: VideoEncoder? = null

    /**
     * 前面カメラ (無ければ背面) を開いてプレビュー開始。失敗時 false。
     * targetW/H: プレビュー解像度の目標。codec=h264/auto では h264_resolution を渡す
     * (MJPEG 側は core の frame_bus が max_width へ縮小するので大きくても無害)。
     */
    fun start(holder: SurfaceHolder, targetW: Int = 640, targetH: Int = 480,
              targetFps: Int = 0): Boolean {
        stop()
        val id = pickCameraId()
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
                // 録画用の連続取り込み経路を優先し、静止画向け ISP 停滞を避ける。
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
                    // H.264 を最優先で queue。MJPEG 用 frame bus の処理時間を
                    // ultra-low-latency 経路へ持ち込まない。
                    encoder?.feed(data, width, height, now)
                    // NV21: y ストライド = width (Camera1 のバッファは詰めて格納される)
                    core.onCameraFrame(data, 0, width, height, width, now)
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

    /** 目標 (既定 640x480) に最も近いプレビューサイズを選ぶ (旧端末の帯域・CPU を考慮)。 */
    private fun pickPreviewSize(params: Camera.Parameters, tw: Int, th: Int): Camera.Size {
        val target = tw * th
        return params.supportedPreviewSizes.minByOrNull { abs(it.width * it.height - target) }
            ?: params.previewSize
    }

    /** exact fixed fps を最優先。無ければ target を含む最も狭い範囲を選ぶ。 */
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
    }
}
