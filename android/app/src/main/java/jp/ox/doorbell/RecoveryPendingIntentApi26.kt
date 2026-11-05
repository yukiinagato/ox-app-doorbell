package jp.ox.doorbell

import android.annotation.TargetApi
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

@TargetApi(26)
internal object RecoveryPendingIntentApi26 {
    fun create(context: Context, intent: Intent): PendingIntent =
        PendingIntent.getForegroundService(context, 7019, intent, PendingIntent.FLAG_IMMUTABLE)
}

@TargetApi(23)
internal object RecoveryAlarmApi23 {
    fun scheduleWhileIdle(alarm: AlarmManager, atElapsedMs: Long, pending: PendingIntent) {
        alarm.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, atElapsedMs, pending)
    }
}

@TargetApi(31)
internal object RecoveryAlarmApi31 {
    fun canScheduleExact(alarm: AlarmManager): Boolean = alarm.canScheduleExactAlarms()

    fun scheduleExact(alarm: AlarmManager, atElapsedMs: Long, pending: PendingIntent) {
        alarm.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, atElapsedMs, pending)
    }
}

/**
 * Target of the exact recovery alarm. Delivery of an exact alarm grants a short exemption from
 * Android 12's background foreground-service restriction, and the service is started inside it.
 */
class RecoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val app = context.applicationContext as? App ?: return
        Log.i("doorbell-recovery", "exact recovery alarm delivered; starting the service")
        app.startResidentService()
    }

    companion object {
        private const val REQUEST_CODE = 7020

        fun pendingIntent(context: Context): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                Intent(context, RecoveryReceiver::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0,
            )
    }
}
