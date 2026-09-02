// Boot starts the resident service first. Device Owner or HOME mode remains the reliable
// foreground-launch mechanism on Android versions that restrict background activity starts.
package jp.keihan.doorbell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val app = context.applicationContext as? App ?: return
        app.startResidentService()
        if (!app.boot.bootLaunch) return
        val i = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try { context.startActivity(i) } catch (_: Exception) { }
    }
}
