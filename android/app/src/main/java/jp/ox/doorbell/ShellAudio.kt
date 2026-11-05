// Shell-side sound playback shared by the visitor UI and the application-level chime.
//
// Every method runs on the main thread. Players are grouped into channels so a new sound on one
// channel replaces only that channel's previous sound, and memory pressure can release the
// optional channels without touching an alert that is still sounding.
package jp.ox.doorbell

import android.content.Context
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File
import java.util.EnumMap

internal class ShellAudio(private val context: Context) {

    enum class Channel { CUSTOM, EFFECT, CALL_FEEDBACK, LAUNCH }

    private val handler = Handler(Looper.getMainLooper())
    private val players = EnumMap<Channel, MediaPlayer>(Channel::class.java)
    private var tone: ToneGenerator? = null

    /**
     * Play a local file on [Channel.CUSTOM]. [fallback] runs when the path is empty, missing, or
     * fails to open or play, so the caller can substitute a bundled sound or TTS.
     */
    fun playFile(path: String, fallback: () -> Unit) {
        if (path.isEmpty() || !File(path).exists()) {
            fallback()
            return
        }
        stop(Channel.CUSTOM)
        val mp = MediaPlayer()
        players[Channel.CUSTOM] = mp
        try {
            mp.setOnErrorListener { _, what, extra ->
                Log.w(TAG, "custom audio playback failed ($what/$extra); using fallback")
                releaseIfCurrent(Channel.CUSTOM, mp)
                handler.post { fallback() }
                true
            }
            mp.setOnCompletionListener { releaseIfCurrent(Channel.CUSTOM, mp) }
            mp.setDataSource(path)
            mp.prepare()
            mp.start()
        } catch (e: Exception) {
            Log.w(TAG, "cannot open custom audio; using fallback: $e")
            releaseIfCurrent(Channel.CUSTOM, mp)
            fallback()
        }
    }

    /**
     * Play a configured sound value: an "asset:<sha256>" reference to a replicated asset or a
     * bundled sound name. Returns false when the value names nothing playable.
     */
    fun playConfigured(channel: Channel, value: String, loop: Boolean): Boolean {
        val mp = makeConfiguredPlayer(value, loop) ?: return false
        stop(channel)
        players[channel] = mp
        mp.setOnCompletionListener {
            if (!it.isLooping) releaseIfCurrent(channel, it)
        }
        return try {
            mp.start()
            true
        } catch (e: Exception) {
            Log.w(TAG, "configured audio failed to start: $value ($e)")
            releaseIfCurrent(channel, mp)
            false
        }
    }

    /** The built-in chime used when no configured or custom chime is playable. */
    fun playChimeTone(sound: String) {
        val kind = when (sound) {
            "ding2" -> ToneGenerator.TONE_PROP_BEEP
            "classic" -> ToneGenerator.TONE_SUP_RINGTONE
            else -> ToneGenerator.TONE_PROP_BEEP2
        }
        val duration = if (sound == "classic") 1400 else if (sound == "ding2") 700 else 450
        playTone(AudioManager.STREAM_NOTIFICATION, 90, kind, duration)
    }

    /** One short generated tone. A new tone replaces one still sounding. */
    fun playTone(stream: Int, volume: Int, kind: Int, durationMs: Int) {
        stopTone()
        try {
            val generator = ToneGenerator(stream, volume.coerceIn(0, 100))
            tone = generator
            generator.startTone(kind, durationMs)
            handler.postDelayed({
                if (tone === generator) stopTone()
            }, (durationMs + 100).toLong())
        } catch (e: Exception) {
            Log.w(TAG, "tone generator unavailable: $e")
            tone = null
        }
    }

    fun stop(channel: Channel) {
        val player = players.remove(channel) ?: return
        release(player)
    }

    fun stopTone() {
        val generator = tone ?: return
        tone = null
        try { generator.stopTone() } catch (e: Exception) { Log.d(TAG, "stopTone: $e") }
        try { generator.release() } catch (e: Exception) { Log.d(TAG, "tone release: $e") }
    }

    /** Release the optional sounds under memory pressure; an alert in progress keeps playing. */
    fun releaseOptional() {
        stop(Channel.EFFECT)
        stop(Channel.CALL_FEEDBACK)
        stop(Channel.LAUNCH)
    }

    fun releaseAll() {
        for (channel in Channel.values()) stop(channel)
        stopTone()
    }

    private fun releaseIfCurrent(channel: Channel, player: MediaPlayer) {
        if (players[channel] === player) players.remove(channel)
        release(player)
    }

    private fun release(player: MediaPlayer) {
        try { player.stop() } catch (e: Exception) { Log.d(TAG, "player stop: $e") }
        try { player.release() } catch (e: Exception) { Log.d(TAG, "player release: $e") }
    }

    private fun makeConfiguredPlayer(value: String, loop: Boolean): MediaPlayer? {
        if (value.isEmpty()) return null
        val mp = MediaPlayer()
        return try {
            if (value.startsWith("asset:") && value.length == 70) {
                val file = File(File(context.filesDir, "assets"), value.substring(6))
                if (!file.exists()) {
                    mp.release()
                    return null
                }
                mp.setDataSource(file.absolutePath)
            } else {
                val name = bundledSoundFile(value) ?: run {
                    mp.release()
                    return null
                }
                context.assets.openFd("audio/$name").use { fd ->
                    mp.setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
                }
            }
            mp.isLooping = loop
            mp.prepare()
            mp
        } catch (e: Exception) {
            Log.w(TAG, "cannot open bundled or configured audio: $value ($e)")
            try { mp.release() } catch (e: Exception) { ShellLog.ignored("ShellAudio", e) }
            null
        }
    }

    companion object {
        private const val TAG = "doorbell-audio"

        fun bundledSoundFile(value: String): String? = when (value) {
            "outdoor_call_alert" -> "outdoor_call_alert.mp3"
            "button_click" -> "button_click.mp3"
            "school_chime" -> "学校のチャイム.mp3"
            "indoor_update" -> "indoor_update.mp3"
            "title_display" -> "title_display.mp3"
            else -> null
        }
    }
}
