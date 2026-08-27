// 常駐前台サービス。core 自体は App (Application) が持つ — 本サービスは通知 1 本で
// プロセスを前台扱いにして省電力 kill を避けるだけの殻。TV は kill が緩いが、
// タブレット流用時のため共通で立てる。BOOT_COMPLETED → BootReceiver からも起動される。
package jp.keihan.doorbell

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

class DoorbellService : Service() {

    override fun onCreate() {
        super.onCreate()
        startForeground(NOTIF_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_STICKY  // kill されたら OS に再起動してもらう

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, getString(R.string.svc_channel),
                                    NotificationManager.IMPORTANCE_MIN))
        }
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26)
            Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        return b.setContentTitle(getString(R.string.app_name))
            .setContentText(getString(R.string.svc_running))
            .setSmallIcon(android.R.drawable.sym_def_app_icon)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "doorbell_resident"
        private const val NOTIF_ID = 1
    }
}
