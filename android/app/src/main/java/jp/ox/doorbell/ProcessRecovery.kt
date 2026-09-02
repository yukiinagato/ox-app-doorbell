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

    private fun scheduleServiceRestart(delayMs: Long) {
        try {
            val intent = Intent(app, DoorbellService::class.java)
            val pending = if (Build.VERSION.SDK_INT >= 26)
                RecoveryPendingIntentApi26.create(app, intent)
            else PendingIntent.getService(app, REQUEST_CODE, intent,
                if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
            val alarm = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarm.set(AlarmManager.ELAPSED_REALTIME_WAKEUP,
                      SystemClock.elapsedRealtime() + delayMs, pending)
        } catch (_: Exception) { }
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
        } catch (_: Exception) { }
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
    }
}
