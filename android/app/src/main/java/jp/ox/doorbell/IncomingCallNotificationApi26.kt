package jp.ox.doorbell

import android.annotation.TargetApi
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context

@TargetApi(26)
internal object IncomingCallNotificationApi26 {
    /** High importance so the full-screen intent fires; the chime itself is played by the app. */
    fun ensureChannel(manager: NotificationManager, id: String, name: String) {
        val channel = NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH)
        channel.setSound(null, null)
        channel.enableVibration(true)
        channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        manager.createNotificationChannel(channel)
    }

    fun builder(context: Context, id: String): Notification.Builder =
        Notification.Builder(context, id)
}

@TargetApi(34)
internal object IncomingCallNotificationApi34 {
    /** Android 14 lets the user revoke USE_FULL_SCREEN_INTENT; the notification still posts. */
    fun canUseFullScreen(manager: NotificationManager): Boolean = manager.canUseFullScreenIntent()
}
