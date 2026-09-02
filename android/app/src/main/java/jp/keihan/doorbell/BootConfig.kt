// boot.json contains local startup settings; fleet configuration remains in Core's CRDT.
package jp.keihan.doorbell

import java.io.File
import java.io.FileOutputStream
import java.nio.charset.Charset
import java.security.SecureRandom
import org.json.JSONObject

class BootConfig private constructor(
    val rawJson: String,
    val name: String,
    val role: String,
    val door: String,
    val uiLang: String,
    val kiosk: Boolean,
    val kioskMode: String,
    val bootLaunch: Boolean,
    val rootHelper: Boolean,
    val watchdog: Boolean,
    val httpPort: Int,
    /** True until an operator has confirmed a valid local role/profile. */
    val setupRequired: Boolean,
    /** A valid, unique-enough suggestion for a door-station assignment. */
    val suggestedDoor: String,
) {
    companion object {
        private const val DEFAULT_JSON =
            "{ \"name\": \"doorbell-android\", \"role\": \"door_station\", \"door\": \"\", " +
            "\"listen_port\": 47172, \"http_port\": 47180, \"ui_lang\": \"ja\", \"kiosk\": false, " +
            "\"setup_complete\": false }"

        private val random = SecureRandom()

        private fun suggestedDoorId(): String {
            val bytes = ByteArray(4)
            random.nextBytes(bytes)
            return "door-" + bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
        }

        fun validRole(value: String): Boolean =
            value == "door_station" || value == "indoor_panel"

        fun validDoor(value: String): Boolean =
            value.matches(Regex("[A-Za-z0-9][A-Za-z0-9_-]{0,63}"))

        fun load(file: File): BootConfig {
            val backup = File(file.parentFile, file.name + ".bak")
            val primary = readValidJson(file)
            val recovered = if (primary == null) readValidJson(backup) else null
            val raw = primary ?: recovered ?: JSONObject(DEFAULT_JSON).apply {
                put("door", suggestedDoorId())
            }.toString()
            if (primary == null) writeAtomic(file, raw, preserveCurrent = false)
            var name = "doorbell"; var role = "door_station"; var door = ""
            var lang = "ja"; var kiosk = false; var kioskMode = "auto"
            var bootLaunch = true; var rootHelper = false; var watchdog = true
            var httpPort = 47180
            // A readable legacy profile is not proof that an operator confirmed
            // its local identity.  Require the explicit marker so upgrades also
            // surface the setup UI once instead of silently accepting a blank or
            // accidentally inherited role.
            var setupComplete = false
            try {
                val d = JSONObject(raw)
                name = d.optString("name", name)
                role = d.optString("role", role)
                door = d.optString("door", door)
                lang = d.optString("ui_lang", lang)
                when (val value = d.opt("kiosk")) {
                    is JSONObject -> {
                        kiosk = value.optBoolean("enabled", true)
                        kioskMode = normalizeKioskMode(value.optString("mode", kioskMode))
                        bootLaunch = value.optBoolean("boot_launch", bootLaunch)
                        rootHelper = value.optBoolean("root_helper", rootHelper)
                        watchdog = value.optBoolean("watchdog", watchdog)
                    }
                    is Boolean -> kiosk = value
                }
                httpPort = d.optInt("http_port", httpPort)
                if (d.has("setup_complete")) setupComplete = d.optBoolean("setup_complete", false)
            } catch (_: Exception) { }
            val roleValid = validRole(role)
            val doorValid = validDoor(door)
            val suggestedDoor = if (doorValid) door else suggestedDoorId()
            val setupRequired = !setupComplete || !roleValid ||
                (role == "door_station" && !doorValid)
            return BootConfig(raw, name, role, door, lang, kiosk, kioskMode, bootLaunch,
                              rootHelper, watchdog, httpPort, setupRequired, suggestedDoor)
        }

        /**
         * Saves the locally-owned bootstrap identity without touching pairing secrets or seeds.
         * Door stations require a stable nonempty door ID; indoor panels deliberately do not.
         */
        fun persistSetup(file: File, name: String, role: String, door: String): BootConfig? {
            if (!validRole(role)) return null
            val normalizedName = name.trim().take(64).ifEmpty { "doorbell" }
            val normalizedDoor = door.trim()
            if (role == "door_station" && !validDoor(normalizedDoor)) return null
            val cur = readValidJson(file)
                ?: readValidJson(File(file.parentFile, file.name + ".bak"))
                ?: DEFAULT_JSON
            return try {
                val json = JSONObject(cur)
                json.put("name", normalizedName)
                json.put("role", role)
                json.put("door", if (role == "door_station") normalizedDoor else "")
                json.put("setup_complete", true)
                val text = json.toString()
                if (!writeAtomic(file, text, preserveCurrent = true)) null else load(file)
            } catch (_: Exception) { null }
        }

        /** Persist only the secure-store reference and seeds. Both boot generations are scrubbed. */
        fun persistPskReference(file: File, seeds: List<String>): String? {
            val cur = readValidJson(file)
                ?: readValidJson(File(file.parentFile, file.name + ".bak"))
                ?: DEFAULT_JSON
            return try {
                val d = JSONObject(cur)
                d.remove("psk_hex")
                d.put("psk_ref", "secret:mesh.psk")
                val merged = LinkedHashSet<String>()
                d.optJSONArray("seed_peers")?.let { arr ->
                    for (i in 0 until arr.length()) arr.optString(i).takeIf { it.isNotEmpty() }
                        ?.let { merged.add(it) }
                }
                for (s in seeds) if (s.isNotEmpty()) merged.add(s)
                if (merged.isNotEmpty()) d.put("seed_peers", org.json.JSONArray(merged.toList()))
                val js = d.toString()
                val backup = File(file.parentFile, file.name + ".bak")
                writeAndRename(backup, js)
                writeAndRename(file, js)
                js
            } catch (_: Exception) { null }
        }

        /**
         * Drop the cluster secret reference and seeds after core reported state "unpaired".
         * Returns the rewritten boot JSON, or null when nothing had to change or the write failed.
         */
        fun clearPskReference(file: File): String? {
            val cur = readValidJson(file)
                ?: readValidJson(File(file.parentFile, file.name + ".bak"))
                ?: return null
            return try {
                val d = JSONObject(cur)
                if (!d.has("psk_ref") && !d.has("psk_hex") && !d.has("seed_peers")) return null
                d.remove("psk_ref")
                d.remove("psk_hex")
                d.remove("seed_peers")
                val js = d.toString()
                writeAndRename(File(file.parentFile, file.name + ".bak"), js)
                writeAndRename(file, js)
                js
            } catch (_: Exception) { null }
        }

        fun hasSecureMeshReference(rawJson: String): Boolean = try {
            JSONObject(rawJson).optString("psk_ref") == "secret:mesh.psk"
        } catch (_: Exception) { false }

        private fun normalizeKioskMode(value: String): String = when (value) {
            "auto", "native", "root_helper", "home_only" -> value
            else -> "auto"
        }

        private fun readValidJson(file: File): String? {
            if (!file.isFile) return null
            return try {
                val text = file.readText(Charsets.UTF_8)
                JSONObject(text)
                text
            } catch (_: Exception) { null }
        }

        /** Write through a same-directory temporary and keep the last valid generation. */
        private fun writeAtomic(file: File, value: String, preserveCurrent: Boolean): Boolean {
            val parent = file.parentFile ?: return false
            if (!parent.exists() && !parent.mkdirs()) return false
            return try {
                if (preserveCurrent) {
                    readValidJson(file)?.let { current ->
                        writeAndRename(File(parent, file.name + ".bak"), current)
                    }
                }
                writeAndRename(file, value)
                true
            } catch (_: Exception) { false }
        }

        private fun writeAndRename(target: File, value: String) {
            val tmp = File(target.parentFile, target.name + ".tmp")
            FileOutputStream(tmp).use { out ->
                out.write(value.toByteArray(Charsets.UTF_8))
                out.flush()
                out.fd.sync()
            }
            if (!tmp.renameTo(target)) {
                tmp.delete()
                throw java.io.IOException("rename failed: ${target.name}")
            }
        }
    }
}
