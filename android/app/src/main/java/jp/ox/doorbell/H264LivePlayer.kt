package jp.ox.doorbell

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import android.view.TextureView
import java.net.HttpURLConnection
import java.net.URL

/** API19-safe MediaCodec surface decoder for the repository's live fMP4 stream. */
internal class H264LivePlayer(
    private val url: String,
    private val view: TextureView,
    private val listener: Listener,
) : TextureView.SurfaceTextureListener, Fmp4StreamReader.Listener {
    interface Listener {
        fun onConfigured(codec: String, width: Int, height: Int)
        fun onFirstFrame()
        fun onFailure(reason: String)
    }

    @Volatile private var running = false
    @Volatile private var decoder: MediaCodec? = null
    @Volatile private var connection: HttpURLConnection? = null
    private var surface: Surface? = null
    private var buffers: CodecBufferAccess? = null
    private var networkThread: Thread? = null
    private var drainThread: Thread? = null
    private var drainRunning = false
    private var awaitingKeyframe = true
    private var firstFrame = false

    fun start() {
        if (running) return
        running = true
        view.surfaceTextureListener = this
        if (view.isAvailable) view.surfaceTexture?.let { startForSurface(it) }
    }

    @Synchronized
    fun stop() {
        running = false
        connection?.disconnect()
        connection = null
        drainRunning = false
        val active = decoder
        decoder = null
        try { active?.stop() } catch (_: Exception) { }
        joinUnlessCurrent(networkThread)
        joinUnlessCurrent(drainThread)
        networkThread = null
        drainThread = null
        try { active?.release() } catch (_: Exception) { }
        buffers = null
        try { surface?.release() } catch (_: Exception) { }
        surface = null
        if (view.surfaceTextureListener === this)
            view.surfaceTextureListener = null
    }

    override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) {
        startForSurface(texture)
    }

    override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) = Unit

    override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
        stop()
        return true
    }

    override fun onSurfaceTextureUpdated(texture: SurfaceTexture) = Unit

    @Synchronized
    private fun startForSurface(texture: SurfaceTexture) {
        if (!running || networkThread != null) return
        surface = Surface(texture)
        networkThread = Thread({ stream() }, "doorbell-fmp4").also {
            it.isDaemon = true
            it.start()
        }
    }

    private fun stream() {
        var local: HttpURLConnection? = null
        try {
            local = URL(url).openConnection() as HttpURLConnection
            connection = local
            local.connectTimeout = CONNECT_TIMEOUT_MS
            local.readTimeout = READ_TIMEOUT_MS
            local.setRequestProperty("Accept", "video/mp4")
            local.setRequestProperty("Connection", "close")
            val code = local.responseCode
            if (code != HttpURLConnection.HTTP_OK)
                throw Fmp4StreamReader.ParseException("HTTP $code")
            Fmp4StreamReader(local.inputStream, this).pump { running }
            if (running) fail("fMP4 stream ended")
        } catch (e: Exception) {
            if (running) fail("${e.javaClass.simpleName}: ${e.message.orEmpty()}")
        } finally {
            try { local?.disconnect() } catch (_: Exception) { }
            if (connection === local) connection = null
        }
    }

    @Synchronized
    override fun onConfig(config: Fmp4StreamReader.Config) {
        if (!running || decoder != null) return
        if (config.sps.size < 2 || (config.sps[1].toInt() and 0xff) != 66) {
            fail("downlink is not AVC Baseline")
            return
        }
        var active: MediaCodec? = null
        try {
            val target = surface ?: throw IllegalStateException("surface unavailable")
            val format = MediaFormat.createVideoFormat(AVC_MIME, config.width, config.height)
            format.setByteBuffer("csd-0", AvcByteStream.withStartCode(config.sps))
            format.setByteBuffer("csd-1", AvcByteStream.withStartCode(config.pps))
            active = MediaCodec.createDecoderByType(AVC_MIME)
            val name = active.name
            active.configure(format, target, null, 0)
            active.start()
            val access = CodecBufferAccessFactory.create()
            access.afterStart(active)
            decoder = active
            buffers = access
            awaitingKeyframe = true
            firstFrame = false
            startDrain(active)
            listener.onConfigured(name, config.width, config.height)
        } catch (e: Exception) {
            try { active?.stop() } catch (_: Exception) { }
            try { active?.release() } catch (_: Exception) { }
            fail("decoder configure failed: ${e.javaClass.simpleName}")
        }
    }

    @Synchronized
    override fun onSample(sample: Fmp4StreamReader.Sample) {
        if (!running) return
        val active = decoder ?: return
        if (awaitingKeyframe && !sample.keyframe) return
        try {
            val index = active.dequeueInputBuffer(INPUT_TIMEOUT_US)
            if (index < 0) {
                awaitingKeyframe = true
                return
            }
            val input = buffers?.input(active, index)
            if (input == null || input.capacity() < sample.annexB.size) {
                active.queueInputBuffer(index, 0, 0, sample.presentationTimeUs, 0)
                fail("decoder input buffer too small")
                return
            }
            input.clear()
            input.put(sample.annexB)
            active.queueInputBuffer(index, 0, sample.annexB.size,
                                    sample.presentationTimeUs, 0)
            if (sample.keyframe) awaitingKeyframe = false
        } catch (e: Exception) {
            fail("decoder input failed: ${e.javaClass.simpleName}")
        }
    }

    private fun startDrain(active: MediaCodec) {
        drainRunning = true
        drainThread = Thread({
            val info = MediaCodec.BufferInfo()
            while (running && drainRunning && decoder === active) {
                try {
                    val index = active.dequeueOutputBuffer(info, OUTPUT_TIMEOUT_US)
                    when {
                        index >= 0 -> {
                            val render = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                            active.releaseOutputBuffer(index, render)
                            if (render && !firstFrame) {
                                firstFrame = true
                                listener.onFirstFrame()
                            }
                        }
                        index == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED ->
                            buffers?.onOutputBuffersChanged(active)
                    }
                } catch (e: Exception) {
                    if (running && decoder === active)
                        fail("decoder output failed: ${e.javaClass.simpleName}")
                    break
                }
            }
        }, "doorbell-h264-decode").also {
            it.priority = Thread.MAX_PRIORITY
            it.start()
        }
    }

    @Synchronized
    private fun fail(reason: String) {
        if (!running) return
        Log.w(TAG, reason)
        running = false
        connection?.disconnect()
        drainRunning = false
        val active = decoder
        decoder = null
        try { active?.stop() } catch (_: Exception) { }
        try { active?.release() } catch (_: Exception) { }
        listener.onFailure(reason)
    }

    private fun joinUnlessCurrent(thread: Thread?) {
        if (thread == null || thread === Thread.currentThread()) return
        try { thread.join(250) } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    companion object {
        private const val TAG = "doorbell-h264-player"
        private const val AVC_MIME = "video/avc"
        private const val CONNECT_TIMEOUT_MS = 2_000
        private const val READ_TIMEOUT_MS = 10_000
        private const val INPUT_TIMEOUT_US = 5_000L
        private const val OUTPUT_TIMEOUT_US = 10_000L
    }
}
