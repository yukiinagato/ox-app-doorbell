// 電源投入で自動起動。まず常駐前台サービス (BOOT_COMPLETED からの FGS 起動は免除対象) —
// これで App.onCreate → core 起動まで到達する。Activity の直接起動は Android 10+ で
// 制限されるため保険 (HOME 設定 / Device Owner が本筋 — provision.md 参照)。
package jp.keihan.doorbell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        (context.applicationContext as? App)?.startResidentService()
        val i = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try { context.startActivity(i) } catch (_: Exception) { }
    }
}
