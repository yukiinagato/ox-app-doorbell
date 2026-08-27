// boot.json — 端末ローカルの起動設定 (filesDir/boot.json、WPF 版 BootConfig と同形式)。
// fleet 設定は core が CRDT で持つ。無ければ既定を書き出す (管理者が adb 等で編集できるように)。
package jp.keihan.doorbell

import java.io.File
import org.json.JSONObject

class BootConfig private constructor(
    val rawJson: String,
    val name: String,
    val role: String,
    val door: String,
    val uiLang: String,
    val kiosk: Boolean,
) {
    companion object {
        private const val DEFAULT_JSON =
            "{ \"name\": \"doorbell-android\", \"role\": \"door_station\", \"door\": \"\", " +
            "\"listen_port\": 47172, \"http_port\": 47180, \"ui_lang\": \"ja\", \"kiosk\": false }"

        fun load(file: File): BootConfig {
            var raw = DEFAULT_JSON
            if (file.exists()) {
                raw = try { file.readText() } catch (_: Exception) { DEFAULT_JSON }
            } else {
                try { file.writeText(DEFAULT_JSON) } catch (_: Exception) { }
            }
            var name = "doorbell"; var role = "door_station"; var door = ""
            var lang = "ja"; var kiosk = true
            try {
                val d = JSONObject(raw)
                name = d.optString("name", name)
                role = d.optString("role", role)
                door = d.optString("door", door)
                lang = d.optString("ui_lang", lang)
                kiosk = d.optBoolean("kiosk", kiosk)
            } catch (_: Exception) { }
            return BootConfig(raw, name, role, door, lang, kiosk)
        }
    }
}
