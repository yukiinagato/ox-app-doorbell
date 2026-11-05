package jp.ox.doorbell

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.File
import org.json.JSONObject

/** Application-owned SOS projection. Core owns durable fleet state; this owns local presentation. */
internal class EmergencyAlertController(private val app: App) {
    private val handler = Handler(Looper.getMainLooper())
    private val store = EmergencyStateStore(File(app.filesDir, "emergency-state-v1.json"))
    private val alarm = EmergencyAlarmPlayer(app, handler)
    private var expiryHlc = ""
    private var lastResultHlc = ""
    private var lastChannelResults: List<DeviceAlertChannelResult> = emptyList()
    @Volatile private var statePersisted = true
    private val expiry = Runnable { expirePresentation(expiryHlc) }

    fun restore() {
        handler.post {
            val state = store.snapshot() ?: return@post
            applyPresentation(state, restored = true)
        }
    }

    fun onCoreEvent(event: JSONObject) {
        handler.post {
            var next = EmergencyProjection.fromEvent(event, System.currentTimeMillis())
                ?: return@post
            val current = store.snapshot()
            if (current != null && current.eventHlc.isNotEmpty() &&
                current.eventHlc == next.eventHlc && current.channels.isNotEmpty() &&
                current.presentationUntilWallMs != 0L) {
                next = next.copy(
                    receivedWallMs = current.receivedWallMs,
                    presentationUntilWallMs = current.presentationUntilWallMs,
                )
            }
            statePersisted = store.update(next)
            applyPresentation(next, restored = event.optBoolean("restored", false))
        }
    }

    /** Reconciles replicated state even when rules intentionally select no local channel. */
    fun reconcileCoreState(active: Boolean, eventHlc: String) {
        val snapshot = store.snapshot()
        if (statePersisted && snapshot != null && snapshot.active == active &&
            snapshot.eventHlc == eventHlc) return
        handler.post {
            val current = store.snapshot()
            if (current != null && current.active == active && current.eventHlc == eventHlc) {
                if (!statePersisted) statePersisted = store.update(current)
                return@post
            }
            val next = EmergencyProjection.silentState(active, eventHlc, System.currentTimeMillis())
            statePersisted = store.update(next)
            applyPresentation(next, restored = true)
        }
    }

    fun current(): EmergencyPresentation? = store.snapshot()

    fun notificationPermissionNeeded(): Boolean =
        Build.VERSION.SDK_INT >= 33 &&
            app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED

    fun notificationPermissionStatus(): String = when {
        Build.VERSION.SDK_INT < 33 -> AndroidDeviceAlertChannels.PERMISSION_NOT_REQUIRED
        notificationPermissionNeeded() -> AndroidDeviceAlertChannels.PERMISSION_REQUIRED
        else -> AndroidDeviceAlertChannels.PERMISSION_GRANTED
    }

    private fun applyPresentation(value: EmergencyPresentation, restored: Boolean) {
        handler.removeCallbacks(expiry)
        if (!value.active) {
            alarm.stop()
            cancelNotification()
            app.emergencyActivity?.finishForStateClear()
            report(value, "cleared", restored, cleanupChannelResults(value, "cleared"))
            return
        }
        if (!value.presentationCurrent(System.currentTimeMillis())) {
            expirePresentation(value.eventHlc)
            return
        }

        val inApp = value.uses(CHANNEL_IN_APP)
        val systemNotification = value.uses(CHANNEL_SYSTEM_NOTIFICATION)
        val soundRequested = value.alarmVolume > 0 &&
            (value.alarmSound.isNotEmpty() || value.audioPath.isNotEmpty())
        var inAppPresented = inApp
        var inAppVisualApplied = false
        var inAppSoundApplied = false
        var notificationSoundApplied = false
        if (inApp) {
            inAppSoundApplied = alarm.start(value)
            if (value.visual) {
                val existing = app.emergencyActivity
                if (existing != null) {
                    existing.renderPresentation(value)
                    inAppVisualApplied = true
                } else {
                    inAppPresented = EmergencyActivity.launch(app)
                    inAppVisualApplied = inAppPresented
                }
            } else {
                app.emergencyActivity?.finishForStateClear()
            }
        } else {
            app.emergencyActivity?.finishForStateClear()
            // Without the in-app channel the notification owns the sound. The app still plays it
            // on the alarm stream with the configured file and volume: a notification channel's
            // sound is fixed at creation, ignores per-alert volume, and is muted by Do Not Disturb.
            if (systemNotification && soundRequested) {
                notificationSoundApplied = alarm.start(value)
            } else {
                alarm.stop()
            }
        }
        val notification = if (systemNotification)
            postNotification(value, inApp, notificationSoundApplied) else {
            cancelNotification()
            NotificationPostResult.notRequested(notificationPermissionStatus())
        }
        val notificationPosted = notification.posted
        if (value.presentationUntilWallMs > 0L) {
            expiryHlc = value.eventHlc
            val delay = (value.presentationUntilWallMs - System.currentTimeMillis()).coerceAtLeast(0L)
            handler.postDelayed(expiry, delay)
        }
        val result = when {
            inApp && !inAppPresented -> "in_app_launch_failed"
            inApp && systemNotification && notificationPosted -> "in_app_and_system_notification"
            inApp && systemNotification -> "in_app_notification_permission_denied"
            inApp -> "in_app"
            systemNotification && notificationPosted -> "system_notification"
            systemNotification -> "notification_permission_denied"
            else -> "silent_state_only"
        }
        report(value, result, restored, activeChannelResults(
            value,
            inAppVisualApplied,
            inAppSoundApplied,
            soundRequested,
            notification,
        ))
    }

    private fun expirePresentation(expectedHlc: String) {
        val current = store.snapshot() ?: return
        if (expectedHlc.isNotEmpty() && current.eventHlc != expectedHlc) return
        alarm.stop()
        cancelNotification()
        app.emergencyActivity?.finishForStateClear()
        val previous = if (lastResultHlc == current.eventHlc) lastChannelResults
            else cleanupChannelResults(current, "ttl_expired")
        report(
            current,
            "presentation_ttl_expired",
            restored = false,
            channelResults = AndroidDeviceAlertChannels.expired(previous),
        )
    }

    private fun postNotification(
        value: EmergencyPresentation,
        inAppRequested: Boolean,
        soundApplied: Boolean,
    ): NotificationPostResult {
        val permission = notificationPermissionStatus()
        if (notificationPermissionNeeded()) return NotificationPostResult(
            posted = false,
            permission = permission,
            failure = "notification_permission_required",
        )
        val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // The sound is never the channel's: see applyPresentation. The channel only vibrates.
        val audible = !inAppRequested && soundApplied
        val channelId = NOTIFICATION_CHANNEL
        if (Build.VERSION.SDK_INT >= 26) {
            EmergencyNotificationApi26.ensureChannel(
                manager,
                channelId,
                app.getString(R.string.emergency_title),
                LEGACY_NOTIFICATION_CHANNELS,
            )
        }
        val open = PendingIntent.getActivity(
            app,
            NOTIFICATION_REQUEST,
            Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0,
        )
        // Over the lock screen the alert opens full screen, as the in-app channel would.
        val fullScreen = if (value.visual) PendingIntent.getActivity(
            app,
            FULL_SCREEN_REQUEST,
            Intent(app, EmergencyActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            ),
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0,
        ) else null
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26)
            EmergencyNotificationApi26.builder(app, channelId)
        else Notification.Builder(app)
        if (fullScreen != null) builder.setFullScreenIntent(fullScreen, true)
        if (Build.VERSION.SDK_INT >= 21) {
            builder.setCategory(Notification.CATEGORY_ALARM)
            builder.setVisibility(Notification.VISIBILITY_PUBLIC)
        }
        val title = value.title.ifEmpty { app.getString(R.string.emergency_title) }
        val body = if (value.source.isEmpty()) app.getString(R.string.emergency_notified)
            else value.source
        val notification = builder
            .setSmallIcon(R.drawable.ic_doorbell)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(open)
            .setPriority(Notification.PRIORITY_MAX)
            .setOngoing(value.sticky)
            .setAutoCancel(!value.sticky)
            .setDefaults(if (Build.VERSION.SDK_INT < 26)
                Notification.DEFAULT_VIBRATE or Notification.DEFAULT_LIGHTS else 0)
            .build()
        return try {
            manager.notify(NOTIFICATION_ID, notification)
            NotificationPostResult(
                posted = true,
                permission = permission,
                audible = audible,
            )
        } catch (e: SecurityException) {
            android.util.Log.w(TAG, "SOS notification refused: $e")
            NotificationPostResult(
                posted = false,
                permission = AndroidDeviceAlertChannels.PERMISSION_DENIED,
                failure = "notification_permission_denied",
            )
        } catch (e: Exception) {
            android.util.Log.w(TAG, "SOS notification failed: $e")
            NotificationPostResult(
                posted = false,
                permission = permission,
                failure = "notification_post_failed",
            )
        }
    }

    private fun cancelNotification() {
        val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(NOTIFICATION_ID)
    }

    private fun activeChannelResults(
        value: EmergencyPresentation,
        inAppVisualApplied: Boolean,
        inAppSoundApplied: Boolean,
        soundRequested: Boolean,
        notification: NotificationPostResult,
    ): List<DeviceAlertChannelResult> {
        val results = ArrayList<DeviceAlertChannelResult>(3)
        if (!value.uses(CHANNEL_IN_APP)) {
            results.add(AndroidDeviceAlertChannels.notRequested(
                CHANNEL_IN_APP,
                AndroidDeviceAlertChannels.PERMISSION_NOT_REQUIRED,
            ))
        } else {
            val visualRejected = value.visual && !inAppVisualApplied
            val soundRejected = soundRequested && !inAppSoundApplied
            val rejected = visualRejected || soundRejected
            val applied = (!value.visual && !soundRequested) ||
                inAppVisualApplied || inAppSoundApplied
            val limitations = ArrayList<String>(2)
            if (visualRejected) limitations.add("in_app_launch_failed")
            if (soundRejected) limitations.add("in_app_sound_failed")
            results.add(DeviceAlertChannelResult(
                channel = CHANNEL_IN_APP,
                requested = true,
                applied = applied,
                rejected = rejected,
                unsupported = false,
                permission = AndroidDeviceAlertChannels.PERMISSION_NOT_REQUIRED,
                result = when {
                    applied && rejected -> "partially_applied"
                    !value.visual && !soundRequested -> "suppressed_by_presentation"
                    applied -> "presented"
                    else -> "rejected"
                },
                visualApplied = inAppVisualApplied,
                soundApplied = inAppSoundApplied,
                stickyApplied = value.sticky && (inAppVisualApplied || inAppSoundApplied),
                ttlSeconds = value.ttlSeconds,
                limitation = limitations.joinToString(";"),
            ))
        }
        if (!value.uses(CHANNEL_SYSTEM_NOTIFICATION)) {
            results.add(AndroidDeviceAlertChannels.notRequested(
                CHANNEL_SYSTEM_NOTIFICATION,
                notification.permission,
            ))
        } else {
            val limitations = ArrayList<String>(4)
            if (soundRequested && value.uses(CHANNEL_IN_APP))
                limitations.add("sound_owned_by_in_app_channel")
            if (soundRequested && !value.uses(CHANNEL_IN_APP) && !notification.audible)
                limitations.add("alarm_sound_failed")
            if (!value.visual && notification.posted)
                limitations.add("system_notification_visual_is_mandatory")
            if (notification.failure.isNotEmpty()) limitations.add(notification.failure)
            results.add(DeviceAlertChannelResult(
                channel = CHANNEL_SYSTEM_NOTIFICATION,
                requested = true,
                applied = notification.posted,
                rejected = !notification.posted,
                unsupported = false,
                permission = notification.permission,
                result = if (notification.posted) "presented" else "rejected",
                visualApplied = notification.posted,
                soundApplied = notification.posted && notification.audible,
                stickyApplied = notification.posted && value.sticky,
                ttlSeconds = value.ttlSeconds,
                limitation = limitations.joinToString(";"),
            ))
        }
        results.add(if (value.uses(AndroidDeviceAlertChannels.WEB_PUSH))
            AndroidDeviceAlertChannels.unsupportedWebPush(requested = true)
        else AndroidDeviceAlertChannels.notRequested(
            AndroidDeviceAlertChannels.WEB_PUSH,
            AndroidDeviceAlertChannels.PERMISSION_NOT_APPLICABLE,
        ))
        return results
    }

    private fun cleanupChannelResults(
        value: EmergencyPresentation,
        result: String,
    ): List<DeviceAlertChannelResult> = listOf(
        cleanupResult(
            AndroidDeviceAlertChannels.IN_APP,
            value.uses(AndroidDeviceAlertChannels.IN_APP),
            AndroidDeviceAlertChannels.PERMISSION_NOT_REQUIRED,
            result,
        ),
        cleanupResult(
            AndroidDeviceAlertChannels.SYSTEM_NOTIFICATION,
            value.uses(AndroidDeviceAlertChannels.SYSTEM_NOTIFICATION),
            notificationPermissionStatus(),
            result,
        ),
        if (value.uses(AndroidDeviceAlertChannels.WEB_PUSH))
            AndroidDeviceAlertChannels.unsupportedWebPush(requested = true)
        else AndroidDeviceAlertChannels.notRequested(
            AndroidDeviceAlertChannels.WEB_PUSH,
            AndroidDeviceAlertChannels.PERMISSION_NOT_APPLICABLE,
        ),
    )

    private fun cleanupResult(
        channel: String,
        requested: Boolean,
        permission: String,
        result: String,
    ): DeviceAlertChannelResult = if (!requested) {
        AndroidDeviceAlertChannels.notRequested(channel, permission)
    } else {
        DeviceAlertChannelResult(
            channel = channel,
            requested = true,
            applied = true,
            rejected = false,
            unsupported = false,
            permission = permission,
            result = result,
        )
    }

    private fun report(
        value: EmergencyPresentation,
        result: String,
        restored: Boolean,
        channelResults: List<DeviceAlertChannelResult>,
    ) {
        lastResultHlc = value.eventHlc
        lastChannelResults = channelResults
        app.reportEmergencyPresentation(AndroidDeviceAlertChannels.report(
            value,
            result,
            restored,
            statePersisted,
            channelResults,
            System.currentTimeMillis(),
        ))
    }

    companion object {
        private const val CHANNEL_IN_APP = AndroidDeviceAlertChannels.IN_APP
        private const val CHANNEL_SYSTEM_NOTIFICATION =
            AndroidDeviceAlertChannels.SYSTEM_NOTIFICATION
        private const val TAG = "doorbell-sos"
        // Versioned: the old channels carried the channel's own sound, which the user could not
        // retune from the cluster. They are deleted when the current channel is created.
        private const val NOTIFICATION_CHANNEL = "doorbell_emergency_v2"
        private val LEGACY_NOTIFICATION_CHANNELS =
            listOf("doorbell_emergency_alarm", "doorbell_emergency_silent")
        private const val NOTIFICATION_ID = 911
        private const val NOTIFICATION_REQUEST = 912
        private const val FULL_SCREEN_REQUEST = 913
    }
}

private data class NotificationPostResult(
    val posted: Boolean,
    val permission: String,
    val audible: Boolean = false,
    val failure: String = "",
) {
    companion object {
        fun notRequested(permission: String) = NotificationPostResult(
            posted = false,
            permission = permission,
        )
    }
}

private class EmergencyAlarmPlayer(
    private val context: Context,
    private val handler: Handler,
) {
    private var media: MediaPlayer? = null
    private var tone: ToneGenerator? = null
    private var repeat = false
    private val repeatTone = object : Runnable {
        override fun run() {
            tone?.startTone(ToneGenerator.TONE_CDMA_EMERGENCY_RINGBACK, TONE_DURATION_MS)
            if (repeat) handler.postDelayed(this, TONE_REPEAT_MS)
        }
    }

    @Suppress("DEPRECATION") // setAudioStreamType is the API 19-20 path only.
    fun start(value: EmergencyPresentation): Boolean {
        stop()
        if (value.alarmVolume <= 0 ||
            (value.alarmSound.isEmpty() && value.audioPath.isEmpty())) return false
        val custom = safeAudioFile(value.audioPath)
        if (custom != null) {
            try {
                val volume = value.alarmVolume / 100f
                media = MediaPlayer().apply {
                    if (Build.VERSION.SDK_INT >= 21) AlarmAudioApi21.apply(this)
                    else setAudioStreamType(AudioManager.STREAM_ALARM)
                    setDataSource(custom.absolutePath)
                    isLooping = value.sticky
                    setVolume(volume, volume)
                    prepare()
                    start()
                }
                return true
            } catch (e: Exception) {
                android.util.Log.w("doorbell-sos", "SOS audio file failed; using the alarm tone: $e")
                try { media?.release() } catch (e: Exception) { ShellLog.ignored("EmergencyAlertController", e) }
                media = null
            }
        }
        try {
            tone = ToneGenerator(AudioManager.STREAM_ALARM, value.alarmVolume.coerceIn(0, 100))
            repeat = value.sticky
            handler.post(repeatTone)
            return true
        } catch (e: Exception) {
            android.util.Log.w("doorbell-sos", "SOS alarm tone unavailable: $e")
            return false
        }
    }

    fun stop() {
        handler.removeCallbacks(repeatTone)
        try { media?.stop() } catch (e: Exception) { ShellLog.ignored("EmergencyAlertController", e) }
        try { media?.release() } catch (e: Exception) { ShellLog.ignored("EmergencyAlertController", e) }
        media = null
        try { tone?.stopTone() } catch (e: Exception) { ShellLog.ignored("EmergencyAlertController", e) }
        try { tone?.release() } catch (e: Exception) { ShellLog.ignored("EmergencyAlertController", e) }
        tone = null
        repeat = false
    }

    private fun safeAudioFile(path: String): File? {
        if (path.isEmpty()) return null
        return try {
            val candidate = File(path).canonicalFile
            val root = context.filesDir.canonicalFile
            if (candidate.isFile && candidate.path.startsWith(root.path + File.separator)) candidate
            else null
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        private const val TONE_DURATION_MS = 900
        private const val TONE_REPEAT_MS = 1_200L
    }
}
