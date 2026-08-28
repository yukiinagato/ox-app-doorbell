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
    val httpPort: Int,   // 自機 httpd (資産取得 /asset/<hash> に使う)
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
            var lang = "ja"; var kiosk = true; var httpPort = 47180
            try {
                val d = JSONObject(raw)
                name = d.optString("name", name)
                role = d.optString("role", role)
                door = d.optString("door", door)
                lang = d.optString("ui_lang", lang)
                kiosk = d.optBoolean("kiosk", kiosk)
                httpPort = d.optInt("http_port", httpPort)
            } catch (_: Exception) { }
            return BootConfig(raw, name, role, door, lang, kiosk, httpPort)
        }

        /**
         * 配対成功時: boot.json に psk_hex + seed_peers を書き込む (既存 seeds と和集合)。
         * 返り値 = 更新後の rawJson (次回起動でこの PSK を使う)。失敗時 null。
         */
        fun persistPsk(file: File, pskHex: String, seeds: List<String>): String? {
            if (pskHex.length != 64) return null
            val cur = if (file.exists()) {
                try { file.readText() } catch (_: Exception) { DEFAULT_JSON }
            } else DEFAULT_JSON
            return try {
                val d = JSONObject(cur)
                d.put("psk_hex", pskHex)
                val merged = LinkedHashSet<String>()
                d.optJSONArray("seed_peers")?.let { arr ->
                    for (i in 0 until arr.length()) arr.optString(i).takeIf { it.isNotEmpty() }
                        ?.let { merged.add(it) }
                }
                for (s in seeds) if (s.isNotEmpty()) merged.add(s)
                if (merged.isNotEmpty()) d.put("seed_peers", org.json.JSONArray(merged.toList()))
                val js = d.toString()
                file.writeText(js)
                js
            } catch (_: Exception) { null }
        }
    }
}
