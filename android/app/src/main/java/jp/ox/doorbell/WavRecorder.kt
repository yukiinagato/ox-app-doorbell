// Microphone recording for custom sounds (quick-reply audio, chimes, the SOS alarm). The asset
// ledger accepts only audio/mpeg and audio/wav, and MediaRecorder on API 19 can write neither, so
// this records 16 kHz mono PCM with AudioRecord and wraps it as WAV (WavFormat). Capped at 60 s,
// well inside the 3 MiB ledger limit.
package jp.ox.doorbell

import android.app.Activity
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import java.io.ByteArrayOutputStream

internal class WavRecorder {

    @Volatile var recording = false
        private set
    private var thread: Thread? = null
    private var pcm = ByteArrayOutputStream()

    /** Starts capturing; [onSecond] reports elapsed whole seconds. False when the mic is busy. */
    fun start(onSecond: (Int) -> Unit): Boolean {
        if (recording) return true
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO,
                                               AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return false
        val record = try {
            AudioRecord(MediaRecorder.AudioSource.MIC, RATE, AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT, maxOf(min, RATE))
        } catch (e: SecurityException) {
            ShellLog.ignored("WavRecorder", e)
            return false
        } catch (e: Exception) {
            ShellLog.ignored("WavRecorder", e)
            return false
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return false
        }
        pcm = ByteArrayOutputStream()
        val limit = minOf(MAX_SECONDS, WavFormat.maxSeconds(RATE)) * RATE * 2
        try {
            record.startRecording()
        } catch (e: Exception) {
            ShellLog.ignored("WavRecorder", e)
            record.release()
            return false
        }
        recording = true
        thread = Thread({
            val buffer = ByteArray(min)
            var lastSecond = -1
            try {
                while (recording && pcm.size() < limit) {
                    val n = record.read(buffer, 0, buffer.size)
                    if (n > 0) pcm.write(buffer, 0, minOf(n, limit - pcm.size()))
                    val second = pcm.size() / (RATE * 2)
                    if (second != lastSecond) { lastSecond = second; onSecond(second) }
                }
            } catch (e: Exception) {
                ShellLog.ignored("WavRecorder", e)
            } finally {
                try { record.stop() } catch (e: Exception) { ShellLog.ignored("WavRecorder", e) }
                record.release()
                recording = false
            }
        }, "doorbell-recorder").apply { isDaemon = true; start() }
        return true
    }

    fun stop() {
        recording = false
        try { thread?.join(1500) } catch (_: InterruptedException) { }
        thread = null
    }

    fun seconds(): Int = pcm.size() / (RATE * 2)

    /** The recording as a WAV file, or null when nothing (or under half a second) was captured. */
    fun wav(): ByteArray? {
        val data = pcm.toByteArray()
        return if (data.size < RATE) null else WavFormat.wrap(data, RATE)
    }

    companion object {
        const val RATE = 16_000
        const val MAX_SECONDS = 60
        private const val REQUEST = 7301

        fun permitted(activity: Activity): Boolean =
            Build.VERSION.SDK_INT < 23 ||
                activity.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED

        fun requestPermission(activity: Activity) {
            if (Build.VERSION.SDK_INT >= 23)
                activity.requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), REQUEST)
        }
    }
}
