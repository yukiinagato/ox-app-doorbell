package jp.ox.doorbell

import android.graphics.Bitmap
import android.os.Handler
import android.view.TextureView
import android.view.View
import android.widget.ImageView
import android.widget.TextView
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject

/** Keeps MJPEG visible until H.264 produces a frame, then retries H.264 while MJPEG is active. */
internal class AdaptiveVideoPlayer(
    private val app: App,
    private val ui: Handler,
    private val texture: TextureView,
    private val image: ImageView,
    private val noVideo: TextView,
) {
    private var h264: H264LivePlayer? = null
    private var mjpeg: MjpegStreamer? = null
    private var h264Url = ""
    private var mjpegUrl = ""
    private var stopped = true
    private var h264Visible = false
    private var currentBitmap: Bitmap? = null
    private var videoWidth = 0
    private var videoHeight = 0
    private var rotation = 0
    private var activeCodec = ""
    private var generation = 0
    private var h264Attempt = 0
    private val firstFrameDeadline = Runnable { failH264(h264Attempt, "H.264 first-frame timeout") }
    private val h264Retry = Runnable { startH264() }

    fun start(h264Url: String, mjpegUrl: String) {
        stop()
        stopped = false
        h264Visible = false
        activeCodec = ""
        generation++
        this.h264Url = h264Url
        this.mjpegUrl = mjpegUrl
        noVideo.visibility = View.VISIBLE
        texture.visibility = View.VISIBLE
        texture.alpha = 0f
        image.visibility = View.VISIBLE
        startMjpeg()
        if (app.safeMode) {
            app.runtime.reportDecoderStatus("disabled_safe_mode", fallback = "mjpeg")
            return
        }
        if (h264Url.isNotEmpty()) {
            startH264()
        } else {
            app.runtime.reportDecoderStatus("degraded", error = "H.264 URL unavailable",
                                            fallback = if (mjpegUrl.isEmpty()) "none" else "mjpeg")
        }
    }

    fun stop() {
        stopped = true
        ui.removeCallbacks(firstFrameDeadline)
        ui.removeCallbacks(h264Retry)
        h264?.stop()
        h264 = null
        mjpeg?.stop()
        mjpeg = null
        texture.visibility = View.GONE
        texture.alpha = 1f
        image.setImageDrawable(null)
        currentBitmap?.recycle()
        currentBitmap = null
    }

    fun onMemoryPressure() {
        if (!h264Visible) {
            image.setImageDrawable(null)
            currentBitmap?.recycle()
            currentBitmap = null
        }
    }

    fun onSafeModeChanged(active: Boolean) {
        if (active) failH264(h264Attempt, "safe mode disables H.264 decoding")
    }

    private fun startH264() {
        if (stopped || app.safeMode || h264Url.isEmpty()) return
        val attempt = ++h264Attempt
        ui.removeCallbacks(firstFrameDeadline)
        h264?.stop()
        h264Visible = false
        texture.visibility = View.VISIBLE
        texture.alpha = 0f
        image.visibility = View.VISIBLE
        app.runtime.reportDecoderStatus("connecting")
        h264 = H264LivePlayer(h264Url, texture, object : H264LivePlayer.Listener {
            override fun onConfigured(codec: String, width: Int, height: Int) {
                ui.post {
                    if (stopped || attempt != h264Attempt) return@post
                    videoWidth = width
                    videoHeight = height
                    activeCodec = codec
                    applyTextureTransform()
                    app.runtime.reportDecoderStatus("probing", codec)
                }
            }

            override fun onFirstFrame() {
                ui.post {
                    if (stopped || attempt != h264Attempt) return@post
                    ui.removeCallbacks(firstFrameDeadline)
                    h264Visible = true
                    texture.alpha = 1f
                    image.visibility = View.GONE
                    noVideo.visibility = View.GONE
                    app.runtime.reportDecoderStatus("active", activeCodec)
                }
            }

            override fun onFailure(reason: String) {
                ui.post { failH264(attempt, reason) }
            }
        }).also { it.start() }
        ui.postDelayed(firstFrameDeadline, H264_FIRST_FRAME_MS)
        fetchRotation(h264Url, generation)
    }

    private fun failH264(attempt: Int, reason: String) {
        if (stopped || attempt != h264Attempt) return
        ui.removeCallbacks(firstFrameDeadline)
        h264?.stop()
        h264 = null
        h264Visible = false
        texture.alpha = 0f
        image.visibility = View.VISIBLE
        app.runtime.reportDecoderStatus("degraded", error = reason,
                                        fallback = if (mjpegUrl.isEmpty()) "none" else "mjpeg")
        if (!mjpegUrl.isEmpty()) startMjpeg()
        ui.removeCallbacks(h264Retry)
        ui.postDelayed(h264Retry, H264_RETRY_MS)
    }

    private fun startMjpeg() {
        if (mjpeg != null || mjpegUrl.isEmpty()) return
        mjpeg = MjpegStreamer(mjpegUrl) { bitmap, frameRotation ->
            ui.post {
                if (stopped) {
                    bitmap.recycle()
                    return@post
                }
                currentBitmap = bitmap
                image.setImageBitmap(bitmap)
                if (!h264Visible) noVideo.visibility = View.GONE
                applyImageRotation(bitmap, frameRotation)
            }
        }.also { it.start() }
    }

    private fun fetchRotation(streamUrl: String, expectedGeneration: Int) {
        Thread({
            var connection: HttpURLConnection? = null
            try {
                val source = URL(streamUrl)
                val port = if (source.port >= 0) ":${source.port}" else ""
                val query = source.query?.let { "?$it" }.orEmpty()
                val meta = URL("${source.protocol}://${source.host}$port/video-meta$query")
                connection = meta.openConnection() as HttpURLConnection
                connection.connectTimeout = 1_500
                connection.readTimeout = 1_500
                if (connection.responseCode != HttpURLConnection.HTTP_OK) return@Thread
                val bytes = BoundedBitmapDecoder.readLimited(connection.inputStream, 4096)
                    ?: return@Thread
                val degrees = JSONObject(String(bytes, Charsets.UTF_8)).optInt("rotation", 0)
                ui.post {
                    if (!stopped && generation == expectedGeneration) {
                        rotation = ((degrees % 360) + 360) % 360
                        applyTextureTransform()
                    }
                }
            } catch (_: Exception) { }
            finally { try { connection?.disconnect() } catch (_: Exception) { } }
        }, "doorbell-video-meta").apply { isDaemon = true }.start()
    }

    private fun applyTextureTransform() {
        texture.rotation = rotation.toFloat()
        if ((rotation == 90 || rotation == 270) && texture.width > 0 && texture.height > 0 &&
            videoWidth > 0 && videoHeight > 0) {
            val base = kotlin.math.min(texture.width.toFloat() / videoWidth,
                                       texture.height.toFloat() / videoHeight)
            val rotated = kotlin.math.min(texture.width.toFloat() / videoHeight,
                                          texture.height.toFloat() / videoWidth)
            val ratio = if (base > 0f) rotated / base else 1f
            texture.scaleX = ratio
            texture.scaleY = ratio
        } else {
            texture.scaleX = 1f
            texture.scaleY = 1f
        }
    }

    private fun applyImageRotation(bitmap: Bitmap, degrees: Int) {
        val normalized = ((degrees % 360) + 360) % 360
        image.rotation = normalized.toFloat()
        if ((normalized == 90 || normalized == 270) && image.width > 0 && image.height > 0) {
            val base = kotlin.math.min(image.width.toFloat() / bitmap.width,
                                       image.height.toFloat() / bitmap.height)
            val rotated = kotlin.math.min(image.width.toFloat() / bitmap.height,
                                          image.height.toFloat() / bitmap.width)
            val ratio = if (base > 0f) rotated / base else 1f
            image.scaleX = ratio
            image.scaleY = ratio
        } else {
            image.scaleX = 1f
            image.scaleY = 1f
        }
    }

    companion object {
        private const val H264_FIRST_FRAME_MS = 2_500L
        private const val H264_RETRY_MS = 5_000L
    }
}
