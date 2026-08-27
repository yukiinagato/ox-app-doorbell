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

    companion object {
        private const val TAG = "doorbell-app"
    }
}
