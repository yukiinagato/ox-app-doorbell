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
import android.util.Log

class DoorbellService : Service() {

    private val app: App get() = application as App
    private val handler = Handler(Looper.getMainLooper())
    private val startRuntime = Runnable { app.runtime.start() }

    override fun onCreate() {
        super.onCreate()
        enterForeground()
        scheduleRuntimeStart()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A permission grant or a return to the foreground re-declares the service types, so
        // the camera and microphone stay usable once the screen goes off.
        if (intent?.action == ACTION_REFRESH_TYPES) enterForeground()
        scheduleRuntimeStart()
        return START_STICKY
    }

    /**
     * startForeground with the types this device can use right now. Android 11+ cuts camera and
     * microphone access from a backgrounded app unless the running service declares those types,
     * and Android 14 rejects a type whose runtime permission is missing, or a while-in-use type
     * started from the background (for example at boot). In that case the service falls back to
     * the special-use type alone and is upgraded on the next foreground transition.
     */
    @SuppressLint("ForegroundServiceType") // Types are passed explicitly from API 30.
    private fun enterForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT < 30) {
            startForeground(NOTIF_ID, notification)
            return
        }
        val wanted = ForegroundTypesApi30.wanted(this, app.boot.role)
        try {
            ForegroundTypesApi30.start(this, NOTIF_ID, notification, wanted)
        } catch (e: Exception) {
            Log.w(TAG, "foreground types $wanted refused ($e); using the resident type only")
            ForegroundTypesApi30.start(this, NOTIF_ID, notification,
                                       ForegroundTypesApi30.residentOnly())
        }
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
        private const val TAG = "doorbell-service"
        private const val CHANNEL_ID = "doorbell_resident"
        private const val NOTIF_ID = 1
        internal const val ACTION_REFRESH_TYPES = "jp.ox.doorbell.action.REFRESH_FGS_TYPES"
    }
}
