package jp.ox.doorbell

import android.media.MediaCodec

/** Keeps one unconfigured AVC decoder allocated for the next incoming video surface. */
internal class H264DecoderPool {
    private var prepared: MediaCodec? = null
    private var warming = false
    private var generation = 0L

    @Synchronized
    fun warm() {
        if (prepared != null || warming) return
        warming = true
        val warmGeneration = generation
        Thread({
            val codec = try { MediaCodec.createDecoderByType(AVC_MIME) } catch (_: Exception) { null }
            synchronized(this) {
                if (generation == warmGeneration) warming = false
                if (generation == warmGeneration && prepared == null) prepared = codec
                else try { codec?.release() } catch (_: Exception) { }
            }
        }, "doorbell-h264-warmup").apply { isDaemon = true }.start()
    }

    @Synchronized
    fun take(): MediaCodec? {
        val codec = prepared
        prepared = null
        return codec
    }

    @Synchronized
    fun recycle(codec: MediaCodec) {
        if (prepared == null) prepared = codec
        else try { codec.release() } catch (_: Exception) { }
    }

    @Synchronized
    fun discard(codec: MediaCodec?) {
        try { codec?.release() } catch (_: Exception) { }
        warm()
    }

    @Synchronized
    fun release() {
        generation++
        warming = false
        val codec = prepared
        prepared = null
        try { codec?.release() } catch (_: Exception) { }
    }

    private companion object { const val AVC_MIME = "video/avc" }
}
