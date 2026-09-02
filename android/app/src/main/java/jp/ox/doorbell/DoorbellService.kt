// Foreground owner for core/camera/codec runtime. START_STICKY handles ordinary
// process eviction; native abort, force-stop and hangs need the optional root helper.
package jp.ox.doorbell

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

class DoorbellService : Service() {

    private val app: App get() = application as App
    private val handler = Handler(Looper.getMainLooper())
    private val startRuntime = Runnable { app.runtime.start() }

    @SuppressLint("ForegroundServiceType") // The modern overlay declares it; API 19 has no type.
    override fun onCreate() {
        super.onCreate()
        startForeground(NOTIF_ID, buildNotification())
        scheduleRuntimeStart()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        scheduleRuntimeStart()
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        app.onTaskRemoved()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        handler.removeCallbacks(startRuntime)
        app.runtime.stop("service_destroyed")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun scheduleRuntimeStart() {
        if (app.bootSetupRequired) return
        handler.removeCallbacks(startRuntime)
        val delay = app.recoveryStartupDelayMs()
        if (delay == 0L) startRuntime.run() else handler.postDelayed(startRuntime, delay)
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26)
            ResidentNotificationApi26.ensureChannel(nm, CHANNEL_ID, getString(R.string.app_name))
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26)
            ResidentNotificationApi26.builder(this, CHANNEL_ID) else Notification.Builder(this)
        return b.setContentTitle(getString(R.string.app_name))
            .setSmallIcon(R.drawable.ic_doorbell)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "doorbell_resident"
        private const val NOTIF_ID = 1
    }
}
