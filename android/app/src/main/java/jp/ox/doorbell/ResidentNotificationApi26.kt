package jp.ox.doorbell

import android.annotation.TargetApi
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context

@TargetApi(26)
internal object ResidentNotificationApi26 {
    fun ensureChannel(manager: NotificationManager, id: String, name: String) {
        manager.createNotificationChannel(
            NotificationChannel(id, name, NotificationManager.IMPORTANCE_MIN))
    }

    fun builder(context: Context, id: String): Notification.Builder =
        Notification.Builder(context, id)
}
