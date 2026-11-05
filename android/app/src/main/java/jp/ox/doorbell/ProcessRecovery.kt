package jp.ox.doorbell

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.io.File
import java.io.FileOutputStream

/** Process-level recovery. Native abort/LMK/force-stop still require the optional helper. */
internal class ProcessRecovery(private val app: App) {
    private val previous = Thread.getDefaultUncaughtExceptionHandler()
    private val marker = "java_fatal\n".toByteArray(Charsets.US_ASCII)
    private val store = CrashLoopStore(File(app.filesDir, "process-recovery-v1.json"))
    @Volatile private var state = ProcessRecoveryState()
    @Volatile private var startupNotBeforeElapsedMs = 0L

    fun install() {
        state = store.beginSession(System.currentTimeMillis(), artifactBuild())
        startupNotBeforeElapsedMs = SystemClock.elapsedRealtime() +
            RecoveryPolicy.unexpectedExitStartupDelayMs(state)
        Handler(Looper.getMainLooper()).postDelayed({
            state = store.markHealthy(System.currentTimeMillis())
            app.onProcessRecoveryChanged()
        }, RecoveryPolicy.WINDOW_MS)
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            writeMarker(marker)
            state = try {
                store.recordCrash(error.javaClass.simpleName, System.currentTimeMillis())
            } catch (_: Throwable) {
                state
            }
            scheduleServiceRestart(state.restartBackoffMs)
            if (previous != null) previous.uncaughtException(thread, error) else {
                Process.killProcess(Process.myPid())
                System.exit(10)
            }
        }
    }

    fun onTaskRemoved() {
        writeMarker("task_removed\n".toByteArray(Charsets.US_ASCII))
        scheduleServiceRestart(RecoveryPolicy.restartBackoffMs(0))
    }

    fun snapshot(): ProcessRecoveryState = state

    fun startupDelayMs(): Long =
        (startupNotBeforeElapsedMs - SystemClock.elapsedRealtime()).coerceAtLeast(0L)

    fun endSession(reason: String) {
        state = store.endSession(reason)
    }

    /**
     * Ask the system to bring the resident service back after this process dies.
     *
     * Android 12 refuses a foreground-service start from the background unless an exemption
     * applies, so a plain alarm aimed at getForegroundService is silently dropped there. The
     * restart therefore uses, in order:
     *  1. an exact allow-while-idle alarm delivered to [RecoveryReceiver]; receiving an exact
     *     alarm is an exemption, and the receiver starts the service inside it. Needs
     *     SCHEDULE_EXACT_ALARM, which the user or the device owner can grant;
     *  2. the direct foreground-service alarm when this app is the device owner, which is itself
     *     exempt;
     *  3. otherwise nothing reliable exists, and that is logged rather than pretended.
     * Native aborts, LMK kills and force-stops never reach this handler; the optional root helper
     * covers them.
     */
    private fun scheduleServiceRestart(delayMs: Long) {
        try {
            val alarm = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val at = SystemClock.elapsedRealtime() + delayMs
            if (Build.VERSION.SDK_INT >= 31) {
                if (RecoveryAlarmApi31.canScheduleExact(alarm)) {
                    RecoveryAlarmApi31.scheduleExact(alarm, at, RecoveryReceiver.pendingIntent(app))
                    return
                }
                if (!DeviceOwnerPolicies.isDeviceOwner(app)) {
                    android.util.Log.w(TAG, "no exempt restart path: grant exact alarms " +
                        "(SCHEDULE_EXACT_ALARM) or provision as device owner")
                }
            }
            val intent = Intent(app, DoorbellService::class.java)
            val pending = if (Build.VERSION.SDK_INT >= 26)
                RecoveryPendingIntentApi26.create(app, intent)
            else PendingIntent.getService(app, REQUEST_CODE, intent,
                if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
            if (Build.VERSION.SDK_INT >= 23) {
                RecoveryAlarmApi23.scheduleWhileIdle(alarm, at, pending)
            } else {
                alarm.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pending)
            }
        } catch (e: Exception) {
            android.util.Log.e(TAG, "could not schedule the service restart", e)
        }
    }

    private fun writeMarker(bytes: ByteArray) {
        val target = File(app.filesDir, "last-process-exit")
        val tmp = File(app.filesDir, "last-process-exit.tmp")
        try {
            FileOutputStream(tmp).use { out ->
                out.write(bytes)
                out.flush()
                out.fd.sync()
            }
            if (!tmp.renameTo(target)) tmp.delete()
        } catch (e: Exception) { ShellLog.ignored("ProcessRecovery", e) }
    }

    private fun artifactBuild(): String = try {
        @Suppress("DEPRECATION")
        val info = app.packageManager.getPackageInfo(app.packageName, 0)
        "${info.versionName.orEmpty()}:${info.versionCode}:${info.lastUpdateTime}:" +
            BuildConfig.DOORBELL_SOURCE_ID
    } catch (_: Exception) {
        "unknown"
    }

    companion object {
        private const val REQUEST_CODE = 7019
        private const val TAG = "doorbell-recovery"
    }
}
