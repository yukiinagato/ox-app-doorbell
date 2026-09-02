package jp.keihan.doorbell

import android.annotation.TargetApi
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context

@TargetApi(26)
internal object EmergencyNotificationApi26 {
    fun ensureChannel(manager: NotificationManager, id: String, name: String, audible: Boolean) {
        val channel = NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH)
        channel.enableLights(true)
        channel.enableVibration(audible)
        if (!audible) channel.setSound(null, null)
        channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        manager.createNotificationChannel(channel)
    }

    fun builder(context: Context, id: String): Notification.Builder =
        Notification.Builder(context, id)
}
