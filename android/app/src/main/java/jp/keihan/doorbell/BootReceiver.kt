// 電源投入で自動起動。HOME に設定済みなら OS が起動するが、HOME 未設定の設置ミス時の保険。
// Android 10+ はバックグラウンドからの Activity 起動が制限される — Device Owner / HOME 設定が
// 本筋で、この receiver は API 21〜28 の旧端末向け (provision.md 参照)。
package jp.keihan.doorbell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val i = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try { context.startActivity(i) } catch (_: Exception) { }
    }
}
