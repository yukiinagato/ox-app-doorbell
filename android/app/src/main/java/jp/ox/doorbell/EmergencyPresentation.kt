package jp.ox.doorbell

import java.io.File
import java.io.FileOutputStream
import org.json.JSONArray
import org.json.JSONObject

internal data class EmergencyPresentation(
    val active: Boolean,
    val eventHlc: String = "",
    val source: String = "",
    val title: String = "",
    val visual: Boolean = true,
    val sticky: Boolean = true,
    val ttlSeconds: Int = 0,
    val alarmSound: String = "",
    val audioPath: String = "",
    val alarmVolume: Int = 100,
    val channels: Set<String> = emptySet(),
    val foreground: String = "",
    val background: String = "",
    val accent: String = "",
    val receivedWallMs: Long = 0L,
    val presentationUntilWallMs: Long = 0L,
) {
    fun uses(channel: String): Boolean = channel in channels

    fun presentationCurrent(nowWallMs: Long): Boolean =
        active && (presentationUntilWallMs == 0L || nowWallMs < presentationUntilWallMs)

    fun toJson(): JSONObject = JSONObject()
        .put("schema_version", 1)
        .put("active", active)
        .put("event_hlc", eventHlc)
        .put("source", source)
        .put("title", title)
        .put("visual", visual)
        .put("sticky", sticky)
        .put("ttl_s", ttlSeconds)
        .put("alarm_sound", alarmSound)
        .put("audio_path", audioPath)
        .put("alarm_volume", alarmVolume)
        .put("channels", JSONArray(channels.toList().sorted()))
        .put("foreground", foreground)
        .put("background", background)
        .put("accent", accent)
        .put("received_wall_ms", receivedWallMs)
        .put("presentation_until_wall_ms", presentationUntilWallMs)

    companion object {
        fun fromJson(value: JSONObject): EmergencyPresentation? {
            if (value.optInt("schema_version", 0) != 1) return null
            val channels = LinkedHashSet<String>()
            value.optJSONArray("channels")?.let { array ->
                for (index in 0 until array.length()) {
                    array.optString(index).takeIf(EmergencyProjection::validChannel)
                        ?.let(channels::add)
                }
            }
            return EmergencyPresentation(
                active = value.optBoolean("active", false),
                eventHlc = value.optString("event_hlc"),
                source = value.optString("source"),
                title = value.optString("title"),
                visual = value.optBoolean("visual", true),
                sticky = value.optBoolean("sticky", true),
                ttlSeconds = value.optInt("ttl_s", 0).coerceIn(0, 86_400),
                alarmSound = value.optString("alarm_sound"),
                audioPath = value.optString("audio_path"),
                alarmVolume = value.optInt("alarm_volume", 100).coerceIn(0, 100),
                channels = channels,
                foreground = EmergencyProjection.color(value.optString("foreground")),
                background = EmergencyProjection.color(value.optString("background")),
                accent = EmergencyProjection.color(value.optString("accent")),
                receivedWallMs = value.optLong("received_wall_ms", 0L).coerceAtLeast(0L),
                presentationUntilWallMs =
                    value.optLong("presentation_until_wall_ms", 0L).coerceAtLeast(0L),
            )
        }
    }
}

internal object EmergencyProjection {
    private val validChannels = setOf("in_app", "system_notification", "web_push")
    private val colorPattern = Regex("^#[0-9A-Fa-f]{6}$")

    fun fromEvent(event: JSONObject, nowWallMs: Long): EmergencyPresentation? {
        if (event.optString("t") != "emergency") return null
        val channels = LinkedHashSet<String>()
        val array = event.optJSONArray("channels")
        if (array != null) {
            for (index in 0 until array.length()) {
                array.optString(index).takeIf(::validChannel)?.let(channels::add)
            }
        } else if (event.optInt("schema_version", 1) <= 1 &&
            !event.optBoolean("state_only", false)) {
            // Compatibility with schema-v1 Core, whose emergency event meant local presentation.
            channels.add("in_app")
        }
        val active = event.optBoolean("active", false)
        val ttl = event.optInt("ttl_s", if (active) 0 else 10).coerceIn(0, 86_400)
        val style = event.optJSONObject("style")
        val until = if (active && ttl > 0) nowWallMs + ttl * 1_000L else 0L
        return EmergencyPresentation(
            active = active,
            eventHlc = event.optString("event_hlc"),
            source = event.optString("source"),
            title = event.optString("title"),
            visual = event.optBoolean("visual", true),
            sticky = event.optBoolean("sticky", active),
            ttlSeconds = ttl,
            alarmSound = event.optString("alarm_sound"),
            audioPath = event.optString("audio_path"),
            alarmVolume = event.optInt("alarm_volume", 100).coerceIn(0, 100),
            channels = channels,
            foreground = color(style?.optString("foreground") ?: event.optString("foreground")),
            background = color(style?.optString("background") ?: event.optString("background")),
            accent = color(style?.optString("accent") ?: event.optString("accent")),
            receivedWallMs = nowWallMs,
            presentationUntilWallMs = until,
        )
    }

    fun silentState(active: Boolean, eventHlc: String, nowWallMs: Long): EmergencyPresentation =
        EmergencyPresentation(
            active = active,
            eventHlc = eventHlc,
            visual = false,
            sticky = active,
            channels = emptySet(),
            receivedWallMs = nowWallMs,
        )

    fun validChannel(value: String): Boolean = value in validChannels

    fun color(value: String): String = if (colorPattern.matches(value)) value.uppercase() else ""
}

internal class EmergencyStateStore(private val file: File) {
    private var state: EmergencyPresentation? = load(file) ?: load(backup())

    @Synchronized
    fun snapshot(): EmergencyPresentation? = state

    @Synchronized
    fun update(value: EmergencyPresentation): Boolean {
        state = value
        val parent = file.parentFile ?: return false
        if (!parent.exists() && !parent.mkdirs()) return false
        val tmp = File(parent, file.name + ".tmp")
        return try {
            if (file.isFile) file.copyTo(backup(), overwrite = true)
            FileOutputStream(tmp).use { out ->
                out.write(value.toJson().toString().toByteArray(Charsets.UTF_8))
                out.flush()
                out.fd.sync()
            }
            if (!tmp.renameTo(file)) throw java.io.IOException("rename failed")
            true
        } catch (_: Exception) {
            tmp.delete()
            false
        }
    }

    private fun backup(): File = File(file.parentFile, file.name + ".bak")

    private fun load(source: File): EmergencyPresentation? {
        if (!source.isFile || source.length() !in 1..MAX_BYTES) return null
        return try {
            EmergencyPresentation.fromJson(JSONObject(source.readText(Charsets.UTF_8)))
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        private const val MAX_BYTES = 16 * 1024L
    }
}
