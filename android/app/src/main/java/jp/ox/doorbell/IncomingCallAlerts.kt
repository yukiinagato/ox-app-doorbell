// Application-level presentation of a targeted visitor chime.
//
// The chime sound belongs to the application, not to whichever Activity happens to be in front:
// a panel showing settings, history, or nothing at all still rings. The incoming screen opens
// directly when the platform allows it; otherwise (Android 10+ with the app in the background
// and no overlay, kiosk, or device-owner exemption) a high-priority call notification with a
// full-screen intent brings it up, so a visitor is never silently missed.
package jp.ox.doorbell

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import org.json.JSONObject

/** One immutable view of the visitor call the indoor UI is presenting. */
internal data class VisitorCallSnapshot(
    val door: String = "",
    val purpose: String = "",
    val visitorLang: String = "",
    val callId: String = "",
    val stageRevision: Int = 0,
    val expiresAtMs: Long = 0L,
) {
    companion object {
        val EMPTY = VisitorCallSnapshot()
    }
}

internal class IncomingCallAlerts(private val app: App) {
    private val handler = Handler(Looper.getMainLooper())
    private val audio = ShellAudio(app)
    @Volatile private var notifiedCallId = ""

    /** Called on a Core thread for an accepted schema-v2 chime. */
    fun onChime(ev: JSONObject, call: VisitorCallSnapshot, openIncomingUi: Boolean) {
        val audioPath = ev.optString("audio_path")
        val sound = ev.optString("sound", "ding1")
        handler.post {
            audio.playFile(audioPath) {
                if (!audio.playConfigured(ShellAudio.Channel.CUSTOM, sound, false))
                    audio.playChimeTone(sound)
            }
            if (!openIncomingUi) return@post
            val launched = canStartActivityNow() && IncomingActivity.launch(app, call)
            if (!launched) postCallNotification(call)
        }
    }

    /** The incoming screen is visible; the notification that may have opened it is done. */
    fun onIncomingShown(callId: String) {
        handler.post { cancelNotification(callId) }
    }

    /** The call stopped ringing for any reason: answered, cancelled, ended, or replaced. */
    fun onCallFinished(callId: String) {
        handler.post {
            stopChime()
            cancelNotification(callId)
        }
    }

    /** Main thread. Stops a chime that is still sounding. */
    fun stopChime() {
        audio.stop(ShellAudio.Channel.CUSTOM)
        audio.stopTone()
    }

    /**
     * Whether startActivity from this process is expected to succeed now. Android 10 blocks
     * background activity starts unless an exemption applies.
     */
    private fun canStartActivityNow(): Boolean {
        if (Build.VERSION.SDK_INT < 29) return true
        if (app.hasStartedActivity) return true
        if (Settings.canDrawOverlays(app)) return true
        return DeviceOwnerPolicies.isDeviceOwner(app)
    }

    private fun postCallNotification(call: VisitorCallSnapshot) {
        val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val texts = Texts(app).apply { setLang(app.boot.uiLang) }
        if (Build.VERSION.SDK_INT >= 26) {
            IncomingCallNotificationApi26.ensureChannel(
                manager, CHANNEL_ID, texts.t("incoming.channel_name", R.string.incoming_channel_name))
        }
        if (Build.VERSION.SDK_INT >= 34 && !IncomingCallNotificationApi34.canUseFullScreen(manager))
            Log.w(TAG, "full-screen intent not granted; the call shows as a heads-up notification")
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
        val open = PendingIntent.getActivity(
            app, REQUEST_CODE, IncomingActivity.intent(app, call), flags)
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26)
            IncomingCallNotificationApi26.builder(app, CHANNEL_ID) else Notification.Builder(app)
        val door = call.door.ifEmpty { "-" }
        builder.setSmallIcon(R.drawable.ic_doorbell)
            .setContentTitle(texts.t("ring.incoming", R.string.ring_incoming, door))
            .setContentText(texts.t("incoming.notification_tap", R.string.incoming_notification_tap))
            .setContentIntent(open)
            .setFullScreenIntent(open, true)
            .setAutoCancel(true)
            .setOngoing(false)
        @Suppress("DEPRECATION")
        builder.setPriority(Notification.PRIORITY_MAX)
        if (Build.VERSION.SDK_INT >= 21) {
            builder.setCategory(Notification.CATEGORY_CALL)
            builder.setVisibility(Notification.VISIBILITY_PUBLIC)
        }
        if (call.expiresAtMs > 0L && Build.VERSION.SDK_INT >= 26) {
            val ttl = call.expiresAtMs - System.currentTimeMillis()
            if (ttl > 0L) builder.setTimeoutAfter(ttl)
        }
        try {
            manager.notify(NOTIFICATION_ID, builder.build())
            notifiedCallId = call.callId
        } catch (e: Exception) {
            Log.e(TAG, "could not post the incoming-call notification", e)
        }
    }

    private fun cancelNotification(callId: String) {
        val current = notifiedCallId
        if (current.isEmpty() || (callId.isNotEmpty() && callId != current)) return
        notifiedCallId = ""
        val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(NOTIFICATION_ID)
    }

    companion object {
        private const val TAG = "doorbell-incoming"
        private const val CHANNEL_ID = "doorbell_incoming_call_v1"
        private const val NOTIFICATION_ID = 2
        private const val REQUEST_CODE = 20
    }
}
