// 起動: filesDir/boot.json を読み core を生成・起動する (WPF 版 App.xaml.cs 相当)。
// core の UI イベントはまず App が受け、前面の Activity (activityListener) へ転送する。
// chime は Activity の生死に関わらずここで拾い、来客モニタ画面 (IncomingActivity) を
// 前台へ被せる (TV: 視聴中の画面の上に出す — SYSTEM_ALERT_WINDOW 付与が前提, provision.md)。
package jp.keihan.doorbell

import android.app.Application
import android.app.admin.DevicePolicyManager
import android.app.admin.SystemUpdatePolicy
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log
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

    // 直近 press の付帯情報 (来鈴画面のバッジ/返信ラベル言語に使う)
    @Volatile
    var lastPressDoor = ""
        private set
    @Volatile
    var lastPurpose = ""
        private set
    @Volatile
    var lastVisitorLang = ""
        private set

    override fun onCreate() {
        super.onCreate()
        boot = BootConfig.load(File(filesDir, "boot.json"))
        core.listener = this
        // 失敗しても UI は起動する (オフライン表示)。ログは logcat doorbell-core タグ。
        coreOk = core.start(filesDir.absolutePath, boot.rawJson)
        applyDeviceOwnerPolicies()
        startResidentService()
    }

    /**
     * Device Owner 時の kiosk 強化 (adb: dpm set-device-owner jp.keihan.doorbell/.AdminReceiver):
     *  - 系統ロック画面を完全無効化 (来鈴画面が锁屏に遮られない)
     *  - 給電中は常時点灯 (AC|USB|WIRELESS = 7)
     *  - システム更新の弾窗防止 (インストール延期ポリシー) + 通知シェード封鎖
     * DO でない端末はスキップ — 設定 > 画面ロック = なし を手動設定 (provision.md)。
     */
    private fun applyDeviceOwnerPolicies() {
        try {
            val dpm = getSystemService(DEVICE_POLICY_SERVICE) as DevicePolicyManager
            if (!dpm.isDeviceOwnerApp(packageName)) {
                Log.i(TAG, "Device Owner ではない — ロック画面無効化はスキップ (provision.md 参照)")
                return
            }
            val admin = ComponentName(this, AdminReceiver::class.java)
            dpm.setGlobalSetting(admin, Settings.Global.STAY_ON_WHILE_PLUGGED_IN, "7")
            if (Build.VERSION.SDK_INT >= 23) {
                dpm.setKeyguardDisabled(admin, true)
                dpm.setStatusBarDisabled(admin, true)
                dpm.setSystemUpdatePolicy(admin, SystemUpdatePolicy.createPostponeInstallPolicy())
            }
            Log.i(TAG, "Device Owner: keyguard 無効化 + 常時点灯 + 更新延期 + 状態バー封鎖を適用")
        } catch (e: Exception) {
            Log.w(TAG, "Device Owner 策略の適用失敗 (容認): $e")
        }
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
        // press イベント (chime より先に届く — node.cpp は event 通知 → ルール評価の順) から
        // 用件/訪客言語を控えておき、続く chime で来鈴画面へ渡す (バッジ + 返信ラベル言語)。
        if (ev.optString("t") == "event" && ev.optString("type") == "press") {
            lastPressDoor = ev.optString("door")
            lastPurpose = ev.optString("purpose")
            lastVisitorLang = ev.optString("visitor_lang")
        }
        // 配対成功 (INVITE 受理 / PIN 参加) → boot.json に PSK/seeds を永続化。
        // 現行プロセスは取得済み PSK で seed 直結・gossip 済み (再起動不要)、次回起動で beacon も再鍵。
        if (ev.optString("t") == "paired") onPaired(ev)
        // 来客 (chime) → モニタ画面。門口機自身 (door_station) は MainActivity が門口 UI
        // なので出さない — 室内機/TV (indoor_panel) のみ。
        if (ev.optString("t") == "chime" && boot.role != "door_station") {
            val door = ev.optString("door")
            val same = door.isEmpty() || lastPressDoor.isEmpty() || door == lastPressDoor
            IncomingActivity.launch(this, door,
                                    if (same) lastPurpose else "",
                                    if (same) lastVisitorLang else "")
        }
    }

    private fun onPaired(ev: JSONObject) {
        val pskHex = ev.optString("psk_hex")
        val seeds = ArrayList<String>()
        ev.optJSONArray("seeds")?.let { arr ->
            for (i in 0 until arr.length()) arr.optString(i).takeIf { it.isNotEmpty() }
                ?.let { seeds.add(it) }
        }
        val js = BootConfig.persistPsk(File(filesDir, "boot.json"), pskHex, seeds)
        if (js != null) {
            boot = BootConfig.load(File(filesDir, "boot.json"))  // メモリ側も更新
            Log.i(TAG, "paired: boot.json に PSK/seeds を保存しました")
        }
        android.os.Handler(mainLooper).post {
            android.widget.Toast.makeText(this, "配対しました", android.widget.Toast.LENGTH_LONG).show()
        }
    }

    override fun onTts(text: String, lang: String) {
        activityListener?.onTts(text, lang)
    }

    override fun onTerminate() {
        core.destroy()
        super.onTerminate()
    }

    companion object {
        private const val TAG = "doorbell-app"
    }
}
