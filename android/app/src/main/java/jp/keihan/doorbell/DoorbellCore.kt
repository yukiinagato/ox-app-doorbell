// doorbell-core (libdoorbell.so) の Kotlin ラッパ。
// コールバック (onUiEventFromNative / onTtsFromNative) は core 内部スレッドから届く —
// listener 側 (MainActivity) が Handler(mainLooper) で UI スレッドへ marshal する。
package jp.keihan.doorbell

import org.json.JSONObject

class DoorbellCore {

    interface Listener {
        /** core → 殻 UI イベント (JSON、doorbell.h 参照)。core 内部スレッドから呼ばれる。 */
        fun onUiEvent(ev: JSONObject)
        /** クイック返信の TTS 朗読要求。core 内部スレッドから呼ばれる。 */
        fun onTts(text: String, lang: String)
    }

    @Volatile
    var listener: Listener? = null

    private var handle: Long = 0

    val isCreated: Boolean get() = handle != 0L

    /** core 生成 + 起動。失敗時 false (ログは logcat の doorbell-core タグ)。 */
    fun start(dataDir: String, bootJson: String): Boolean {
        if (handle != 0L) return true
        handle = nativeCreate(dataDir, bootJson)
        if (handle == 0L) return false
        nativeSetUiCallback(handle, true)
        if (nativeStart(handle) != 0) {
            destroy()
            return false
        }
        return true
    }

    fun destroy() {
        if (handle == 0L) return
        nativeSetUiCallback(handle, false)
        nativeStop(handle)
        nativeDestroy(handle)
        handle = 0
    }

    fun press(doorId: String) {
        if (handle != 0L) nativePress(handle, doorId)
    }

    /** 用件ボタンからの按鈴 (config visit_purposes の id — press payload に載る)。 */
    fun pressPurpose(doorId: String, purpose: String) {
        if (handle != 0L) nativePressPurpose(handle, doorId, purpose)
    }

    /** 訪客言語の切替 ("ja" で即時復帰)。全ノードへ複製され visitor_lang イベントが返る。 */
    fun setVisitorLang(door: String, lang: String) {
        if (handle != 0L) nativeSetVisitorLang(handle, door, lang)
    }

    fun status(): JSONObject? = parse(if (handle != 0L) nativeStatusJson(handle) else null)

    fun config(): JSONObject? = parse(if (handle != 0L) nativeConfigJson(handle) else null)

    /** カメラフレーム push。format: 0=NV21 (Camera1 の既定), 1=NV12, 2=YUY2, 3=BGRA */
    fun onCameraFrame(data: ByteArray, format: Int, width: Int, height: Int, stride: Int,
                      tsMs: Long) {
        if (handle != 0L) nativeOnCameraFrame(handle, data, format, width, height, stride, tsMs)
    }

    /** 符号化済み H.264 (AnnexB) push — VideoEncoder から。core が fMP4 化して /stream.mp4 へ。 */
    fun onEncodedFrame(annexb: ByteArray, isKeyframe: Boolean, tsMs: Long) {
        if (handle != 0L) nativeOnEncodedFrame(handle, annexb, isKeyframe, tsMs)
    }

    /** エンコーダを回すべきか (codec=h264/auto かつ /stream.mp4 購読者あり)。5 秒毎に確認する。 */
    fun videoEncoderWanted(): Boolean =
        handle != 0L && nativeVideoEncoderWanted(handle)

    /**
     * SIP 発呼。target: 内線番号 or "sip:host:port" 完全 URI (Asterisk 非経由の直接呼)。
     * mode: "" = 通常 (双方向) / "monitor" = 一方向監聴 (門口マイクを聞くだけ)。
     * PJSIP 無効ビルド (プリビルド無し) では no-op。
     */
    fun sipCall(target: String, mode: String = "") {
        if (handle != 0L) nativeSipCall(handle, target, mode)
    }

    fun sipHangup() {
        if (handle != 0L) nativeSipHangup(handle)
    }

    /** クイック返信の配送 (門口機の面板表示 + TTS)。door 空 = 最新 press の door。 */
    fun quickReply(replyId: String, door: String) {
        if (handle != 0L) nativeQuickReply(handle, replyId, door)
    }

    fun version(): String = nativeVersion()

    // ---------- 配対 (発見/招待) ----------

    /** 配対 UI 用: {paired, self, pair_qr, pending:{devices,pairing_mode}}。 */
    fun pairingInfo(): JSONObject? = parse(if (handle != 0L) nativePairingJson(handle) else null)

    /** 未配対機側: PIN + seed で能動参加。結果は onUiEvent の t:"join_result"/t:"paired"。 */
    fun joinCluster(host: String, pin: String) {
        if (handle != 0L) nativeJoinCluster(handle, host, pin)
    }

    /** 配対済み機側: 配対モードを seconds 秒 ON (期間中の未配対機を自動招待)。 */
    fun setPairingMode(seconds: Int) {
        if (handle != 0L) nativePairingMode(handle, seconds)
    }

    /** 配対済み機側: pending の 1 台 (node_id) を承認・招待。 */
    fun inviteDevice(nodeId: String) {
        if (handle != 0L) nativeInviteDevice(handle, nodeId)
    }

    /** QR エンコード (core 共通)。戻り値 [0]=一辺のモジュール数, [1..]=行優先 0/1。失敗 null。 */
    fun qrEncode(text: String): IntArray? = if (text.isEmpty()) null else nativeQrEncode(text)

    private fun parse(s: String?): JSONObject? =
        try { if (s == null) null else JSONObject(s) } catch (_: Exception) { null }

    /** 設定ツリーをドットパスで辿る ("doors.d_front.label.ja" 等)。無ければ null。 */
    fun dig(root: JSONObject?, dotpath: String): Any? {
        var cur: Any? = root ?: return null
        for (part in dotpath.split(".")) {
            val o = cur as? JSONObject ?: return null
            cur = o.opt(part) ?: return null
        }
        return cur
    }

    // ---------- JNI から呼ばれる (core 内部スレッド) ----------

    @Suppress("unused")  // jni_bridge.cpp から GetMethodID で参照
    private fun onUiEventFromNative(json: String) {
        val ev = try { JSONObject(json) } catch (_: Exception) { return }
        listener?.onUiEvent(ev)
    }

    @Suppress("unused")  // jni_bridge.cpp から GetMethodID で参照
    private fun onTtsFromNative(text: String, lang: String) {
        listener?.onTts(text, lang)
    }

    // ---------- native ----------

    private external fun nativeCreate(dataDir: String, bootJson: String): Long
    private external fun nativeStart(handle: Long): Int
    private external fun nativeStop(handle: Long)
    private external fun nativeDestroy(handle: Long)
    private external fun nativeSetUiCallback(handle: Long, enabled: Boolean)
    private external fun nativePress(handle: Long, doorId: String)
    private external fun nativePressPurpose(handle: Long, doorId: String, purpose: String)
    private external fun nativeSetVisitorLang(handle: Long, door: String, lang: String)
    private external fun nativeStatusJson(handle: Long): String?
    private external fun nativeConfigJson(handle: Long): String?
    private external fun nativeOnCameraFrame(handle: Long, data: ByteArray, format: Int,
                                             width: Int, height: Int, stride: Int, tsMs: Long)
    private external fun nativeOnEncodedFrame(handle: Long, annexb: ByteArray,
                                              isKeyframe: Boolean, tsMs: Long)
    private external fun nativeVideoEncoderWanted(handle: Long): Boolean
    private external fun nativeSipCall(handle: Long, target: String, mode: String)
    private external fun nativeSipHangup(handle: Long)
    private external fun nativeQuickReply(handle: Long, replyId: String, door: String)
    private external fun nativeVersion(): String
    private external fun nativePairingJson(handle: Long): String?
    private external fun nativeJoinCluster(handle: Long, host: String, pin: String)
    private external fun nativePairingMode(handle: Long, seconds: Int)
    private external fun nativeInviteDevice(handle: Long, nodeId: String)
    private external fun nativeQrEncode(text: String): IntArray?

    companion object {
        init {
            System.loadLibrary("doorbell")
        }
    }
}
