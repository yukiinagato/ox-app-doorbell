// H.264 ハードウェアエンコード (MediaCodec, API 21+) — Phase 6a の流暢档。
// CameraFeeder の NV21 プレビューフレームを NV12 へ変換して食わせ、AnnexB 出力を
// core (nativeOnEncodedFrame → fMP4 → /stream.mp4) へ流す。
// 出力は専用スレッドで連続 drain し、次のカメラ callback まで待たせない。
// 稼働制御は MainActivity のポーリング (core.videoEncoderWanted() —
// /stream.mp4 の購読者がいる間だけ回す。購読者ゼロ = エンコードゼロで省電力)。
package jp.keihan.doorbell

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Log

class VideoEncoder(private val core: DoorbellCore) {

    @Volatile
    private var codec: MediaCodec? = null
    private var width = 0
    private var height = 0
    private var fps = 30
    private var bitrateKbps = 700
    private var lastFeedMs = 0L
    private var configData: ByteArray? = null   // CODEC_CONFIG (SPS/PPS) — キーフレームに前置
    private var nv12: ByteArray? = null         // NV21→NV12 変換の使い回しバッファ
    @Volatile
    private var drainRunning = false
    private var drainThread: Thread? = null
    @Volatile
    private var started = false                 // start()..stop() の間 true (稼働指示)
    private var failed = false                  // createCodec 失敗 (次の start まで再試行しない)

    /** 稼働指示中か (MediaCodec 自体の生成は最初のフレームまで遅延する)。 */
    val isRunning: Boolean get() = started

    /** config camera.h264_* を適用して開始。解像度はカメラのプレビューサイズに従う
     *  (feed で最初のフレームが来た時に configure する — ここではパラメータ記憶のみ)。 */
    @Synchronized
    fun start(fps: Int, bitrateKbps: Int) {
        this.fps = if (fps > 0) fps else 30
        this.bitrateKbps = if (bitrateKbps > 0) bitrateKbps else 700
        // 既に走っていてパラメータだけ変わった場合は作り直す (次の feed で再 configure)
        releaseCodec()
        width = 0
        height = 0
        lastFeedMs = 0L
        failed = false
        started = true
    }

    @Synchronized
    fun stop() {
        started = false
        releaseCodec()
    }

    private fun releaseCodec() {
        val c = codec
        codec = null
        drainRunning = false
        try {
            c?.stop()  // dequeueOutputBuffer を即時解除
        } catch (_: Exception) { }
        try {
            drainThread?.join(250)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        drainThread = null
        try {
            c?.release()
        } catch (_: Exception) { }
        configData = null
    }

    /**
     * カメラスレッドから NV21 フレームを投入。fps 間引き → NV12 変換 → 入力バッファ →
     * 出力は専用 thread が連続ドレーンする。入力が詰まった場合は古い映像を
     * 待たず現在フレームを捨てる (ライブ専用)。
     * MediaCodec が使えない端末 (硬編なし) では null のまま = 何も流れない
     * (codec=auto の想定回落: /stream.mp4 は 503 → クライアントが MJPEG へ)。
     */
    @Synchronized
    fun feed(data: ByteArray, w: Int, h: Int, tsMs: Long) {
        if (!started || failed) return
        // fps 間引き (プレビューは 15-30fps 来ることがある)
        if (lastFeedMs != 0L && tsMs - lastFeedMs < 1000L / fps) return
        lastFeedMs = tsMs

        var c = codec
        if (c == null || w != width || h != height) {
            releaseCodec()
            c = createCodec(w, h)
            if (c == null) {
                failed = true  // 硬編なし — 次の start() まで再試行しない (ログ 1 回)
                return
            }
            codec = c
            width = w
            height = h
            startOutputDrain(c)
        }
        try {
            val inIdx = c.dequeueInputBuffer(0)
            if (inIdx < 0) return  // 入力詰まり — このフレームは捨てる (ライブ専用)
            val buf = c.getInputBuffer(inIdx) ?: return
            buf.clear()
            buf.put(nv21ToNv12(data, w, h))
            c.queueInputBuffer(inIdx, 0, w * h * 3 / 2, tsMs * 1000, 0)
        } catch (e: Exception) {
            Log.w(TAG, "encode failed: $e")
            releaseCodec()  // 次のフレームで作り直す
        }
    }

    private fun createCodec(w: Int, h: Int): MediaCodec? {
        return try {
            val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h)
            fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar)  // NV12 系
            fmt.setInteger(MediaFormat.KEY_BIT_RATE, bitrateKbps * 1000)
            fmt.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            fmt.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, GOP_S)
            // iPad 1 / iOS 5 のハードウェアデコーダは High Profile を受けられない。
            // profile/level を省略すると一部の Android encoder が High を選ぶため、
            // 互換性のある Baseline Level 3.1 を明示する。文字列 key を使うのは
            // minSdk 21 で MediaFormat.KEY_LEVEL の API 差を踏まないため。
            fmt.setInteger("profile", MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            fmt.setInteger("level", MediaCodecInfo.CodecProfileLevel.AVCLevel31)
            val c = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            val encCaps = c.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                .encoderCapabilities
            if (encCaps.isBitrateModeSupported(
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)) {
                fmt.setInteger(MediaFormat.KEY_BITRATE_MODE,
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            }
            // Encoder latency hint (frames). Optional keys are ignored by codecs which
            // do not implement them; the active output format is logged for verification.
            if (android.os.Build.VERSION.SDK_INT >= 26) fmt.setInteger("latency", 0)
            c.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            c.start()
            Log.i(TAG, "h264 encoder start ${w}x$h @${fps}fps ${bitrateKbps}kbps")
            c
        } catch (e: Exception) {
            // 硬編なし/フォーマット不許容 — auto の回落先は MJPEG (core 側で 503)
            Log.w(TAG, "MediaCodec unavailable: $e")
            null
        }
    }

    /**
     * MediaCodec の出力を常時待ち受ける。旧実装の dequeue(timeout=0) は出力が
     * 数 ms 遅れただけで次の camera callback (33--60ms 後) まで放置していた。
     */
    private fun startOutputDrain(c: MediaCodec) {
        drainRunning = true
        drainThread = Thread({
            val info = MediaCodec.BufferInfo()
            while (drainRunning && codec === c) {
                try {
                    val outIdx = c.dequeueOutputBuffer(info, 5_000)
                    if (outIdx >= 0) {
                        handleOutput(c, outIdx, info)
                    } else if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        Log.i(TAG, "h264 output format ${c.outputFormat}")
                    }
                } catch (e: Exception) {
                    if (drainRunning && codec === c) Log.w(TAG, "output drain failed: $e")
                    break
                }
            }
        }, "doorbell-h264-output").also {
            it.priority = Thread.MAX_PRIORITY
            it.start()
        }
    }

    /** AnnexB output → core. MediaCodec の AVC 出力は start code 付き。 */
    private fun handleOutput(c: MediaCodec, outIdx: Int, info: MediaCodec.BufferInfo) {
        try {
            val buf = c.getOutputBuffer(outIdx)
            if (buf != null && info.size > 0) {
                val bytes = ByteArray(info.size)
                buf.position(info.offset)
                buf.get(bytes)
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    // SPS/PPS。保存してキーフレームへ前置する (端末によっては
                    // キーフレームに SPS/PPS が同梱されないため — core が抽出する)
                    configData = bytes
                } else {
                    val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                    val cfg = configData
                    val out = if (key && cfg != null) cfg + bytes else bytes
                    core.onEncodedFrame(out, key, info.presentationTimeUs / 1000)
                }
            }
        } finally {
            c.releaseOutputBuffer(outIdx, false)
        }
    }

    /** NV21 (VUVU) → NV12 (UVUV)。Y 面はそのまま、色度は使い回しバッファへ入替コピー。 */
    private fun nv21ToNv12(src: ByteArray, w: Int, h: Int): ByteArray {
        val size = w * h * 3 / 2
        var dst = nv12
        if (dst == null || dst.size != size) {
            dst = ByteArray(size)
            nv12 = dst
        }
        System.arraycopy(src, 0, dst, 0, w * h)
        var i = w * h
        while (i + 1 < size) {
            dst[i] = src[i + 1]      // U
            dst[i + 1] = src[i]      // V
            i += 2
        }
        return dst
    }

    companion object {
        private const val TAG = "doorbell-encoder"
        private const val GOP_S = 1  // 秒。HLS の初期 3 セグメント待ちと遅延を抑える
    }
}
