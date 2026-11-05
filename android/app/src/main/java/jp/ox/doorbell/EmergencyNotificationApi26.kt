package jp.ox.doorbell

import android.annotation.TargetApi
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer

@TargetApi(26)
internal object EmergencyNotificationApi26 {
    /**
     * The SOS channel vibrates and shows on the lock screen but has no sound of its own; the
     * alarm-stream player supplies the configured sound and volume instead.
     */
    fun ensureChannel(
        manager: NotificationManager,
        id: String,
        name: String,
        legacyIds: List<String>,
    ) {
        for (legacy in legacyIds) {
            if (manager.getNotificationChannel(legacy) != null)
                manager.deleteNotificationChannel(legacy)
        }
        val channel = NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH)
        channel.enableLights(true)
        channel.enableVibration(true)
        channel.setSound(null, null)
        channel.setBypassDnd(true)
        channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        manager.createNotificationChannel(channel)
    }

    fun builder(context: Context, id: String): Notification.Builder =
        Notification.Builder(context, id)
}

@TargetApi(21)
internal object AlarmAudioApi21 {
    fun apply(player: MediaPlayer) {
        player.setAudioAttributes(AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build())
    }
}
