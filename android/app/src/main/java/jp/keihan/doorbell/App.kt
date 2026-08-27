// 起動: filesDir/boot.json を読み core を生成・起動する (WPF 版 App.xaml.cs 相当)。
// core の UI イベントはまず App が受け、前面の Activity (activityListener) へ転送する。
// chime は Activity の生死に関わらずここで拾い、来客モニタ画面 (IncomingActivity) を
// 前台へ被せる (TV: 視聴中の画面の上に出す — SYSTEM_ALERT_WINDOW 付与が前提, provision.md)。
package jp.keihan.doorbell

import android.app.Application
import android.content.Intent
import android.os.Build
import java.io.File
import org.json.JSONObject

class App : Application(), DoorbellCore.Listener {

    lateinit var boot: BootConfig
        private set
    val core = DoorbellCore()
    var coreOk = false
        private set

    /** 前面 Activity のリスナ (MainActivity)。core イベントの転送先。 */
    @Volatile
    var activityListener: DoorbellCore.Listener? = null

    override fun onCreate() {
        super.onCreate()
        boot = BootConfig.load(File(filesDir, "boot.json"))
        core.listener = this
        // 失敗しても UI は起動する (オフライン表示)。ログは logcat doorbell-core タグ。
        coreOk = core.start(filesDir.absolutePath, boot.rawJson)
        startResidentService()
    }

    /** 常駐前台サービス (通知 1 本)。BOOT_COMPLETED 経由でも呼ばれる。 */
    fun startResidentService() {
        try {
            val i = Intent(this, DoorbellService::class.java)
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
        } catch (_: Exception) { /* FGS 起動制限時は次の前面化で再試行される */ }
    }

    // ---------- core イベント (core 内部スレッド) ----------

    override fun onUiEvent(ev: JSONObject) {
        activityListener?.onUiEvent(ev)
        // 来客 (chime) → モニタ画面。門口機自身 (door_station) は MainActivity が門口 UI
        // なので出さない — 室内機/TV (indoor_panel) のみ。
        if (ev.optString("t") == "chime" && boot.role != "door_station") {
            IncomingActivity.launch(this, ev.optString("door"))
        }
    }

    override fun onTts(text: String, lang: String) {
        activityListener?.onTts(text, lang)
    }

    override fun onTerminate() {
        core.destroy()
        super.onTerminate()
    }
}
