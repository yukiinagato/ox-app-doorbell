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

    fun status(): JSONObject? = parse(if (handle != 0L) nativeStatusJson(handle) else null)

    fun config(): JSONObject? = parse(if (handle != 0L) nativeConfigJson(handle) else null)

    /** カメラフレーム push。format: 0=NV21 (Camera1 の既定), 1=NV12, 2=YUY2, 3=BGRA */
    fun onCameraFrame(data: ByteArray, format: Int, width: Int, height: Int, stride: Int,
                      tsMs: Long) {
        if (handle != 0L) nativeOnCameraFrame(handle, data, format, width, height, stride, tsMs)
    }

    fun version(): String = nativeVersion()

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
    private external fun nativeStatusJson(handle: Long): String?
    private external fun nativeConfigJson(handle: Long): String?
    private external fun nativeOnCameraFrame(handle: Long, data: ByteArray, format: Int,
                                             width: Int, height: Int, stride: Int, tsMs: Long)
    private external fun nativeVersion(): String

    companion object {
        init {
            System.loadLibrary("doorbell")
        }
    }
}
