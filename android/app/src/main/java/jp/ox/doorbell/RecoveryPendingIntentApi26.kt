package jp.ox.doorbell

import android.annotation.TargetApi
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

@TargetApi(26)
internal object RecoveryPendingIntentApi26 {
    fun create(context: Context, intent: Intent): PendingIntent =
        PendingIntent.getForegroundService(context, 7019, intent, PendingIntent.FLAG_IMMUTABLE)
}
