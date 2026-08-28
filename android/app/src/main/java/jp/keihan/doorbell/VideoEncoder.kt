// H.264 ハードウェアエンコード (MediaCodec, API 21+) — Phase 6a の流暢档。
// CameraFeeder の NV21 プレビューフレームを NV12 へ変換して食わせ、AnnexB 出力を
// core (nativeOnEncodedFrame → fMP4 → /stream.mp4) へ流す。
// 稼働制御は MainActivity の 5 秒毎ポーリング (core.videoEncoderWanted() —
// /stream.mp4 の購読者がいる間だけ回す。購読者ゼロ = エンコードゼロで省電力)。
package jp.keihan.doorbell

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Log

class VideoEncoder(private val core: DoorbellCore) {

    private var codec: MediaCodec? = null
    private var width = 0
    private var height = 0
    private var fps = 25
    private var bitrateKbps = 1500
    private var lastFeedMs = 0L
    private var configData: ByteArray? = null   // CODEC_CONFIG (SPS/PPS) — キーフレームに前置
    private var nv12: ByteArray? = null         // NV21→NV12 変換の使い回しバッファ
    @Volatile
    private var started = false                 // start()..stop() の間 true (稼働指示)
    private var failed = false                  // createCodec 失敗 (次の start まで再試行しない)

    /** 稼働指示中か (MediaCodec 自体の生成は最初のフレームまで遅延する)。 */
    val isRunning: Boolean get() = started

    /** config camera.h264_* を適用して開始。解像度はカメラのプレビューサイズに従う
     *  (feed で最初のフレームが来た時に configure する — ここではパラメータ記憶のみ)。 */
    @Synchronized
    fun start(fps: Int, bitrateKbps: Int) {
        this.fps = if (fps > 0) fps else 25
        this.bitrateKbps = if (bitrateKbps > 0) bitrateKbps else 1500
        // 既に走っていてパラメータだけ変わった場合は作り直す (次の feed で再 configure)
        releaseCodec()
        width = 0
        height = 0
        failed = false
        started = true
    }

    @Synchronized
    fun stop() {
        started = false
        releaseCodec()
    }

    private fun releaseCodec() {
        try {
            codec?.stop()
            codec?.release()
        } catch (_: Exception) { }
        codec = null
        configData = null
    }

    /**
     * カメラスレッドから NV21 フレームを投入。fps 間引き → NV12 変換 → 入力バッファ →
     * 出力ドレーン (同期モード — Camera1 のコールバック頻度なら十分軽い)。
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
        }
        try {
            val inIdx = c.dequeueInputBuffer(0)
            if (inIdx < 0) return  // 入力詰まり — このフレームは捨てる (ライブ専用)
            val buf = c.getInputBuffer(inIdx) ?: return
            buf.clear()
            buf.put(nv21ToNv12(data, w, h))
            c.queueInputBuffer(inIdx, 0, w * h * 3 / 2, tsMs * 1000, 0)
            drain(c)
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
            val c = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
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

    /** 出力バッファを全部吸い出して core へ (AnnexB — MediaCodec の AVC 出力は start code 付き)。 */
    private fun drain(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val outIdx = c.dequeueOutputBuffer(info, 0)
            if (outIdx < 0) break
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
        private const val GOP_S = 2  // キーフレーム間隔 (秒) — MSE 参加者の初描画待ちに直結
    }
}
