// 文言解決の前段 (strings.xml の手前): config i18n_overrides.<lang>.<key> があればそれを使い、
// 無ければ言語別 Resources (createConfigurationContext) の組込文言へ回落する。
// 訪客言語 (門口機の言語バー) の現在値もここが持つ — Activity を作り直さずに切替できる。
// 上書き文言のプレースホルダは i18n/strings.yaml と同じ名前付き ({unit} 等) で、出現順に
// 引数で埋める (tools/gen_i18n.py が %1$s へ変換するのと同じ順序規約)。
package jp.keihan.doorbell

import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import java.util.Locale
import org.json.JSONObject

class Texts(private val base: Context) {

    /** 現在の表示言語 (門口機は訪客言語、室内機は boot.ui_lang)。 */
    var lang: String = "ja"
        private set

    private var config: JSONObject? = null
    private var overrides: JSONObject? = null
    private var res: Resources = base.resources

    /** 設定ツリーの差し替え (起動時 / config_changed)。 */
    fun setConfig(cfg: JSONObject?) {
        config = cfg
        reload()
    }

    /** 表示言語の切替 (組込文言の Resources もここで差し替える)。 */
    fun setLang(l: String) {
        lang = if (l.isEmpty()) "ja" else l
        reload()
    }

    private fun reload() {
        overrides = config?.optJSONObject("i18n_overrides")?.optJSONObject(lang)
        res = localizedResources(lang)
    }

    private fun localizedResources(l: String): Resources = try {
        val c = Configuration(base.resources.configuration)
        c.setLocale(Locale(l))
        base.createConfigurationContext(c).resources
    } catch (_: Exception) {
        base.resources
    }

    /**
     * key = i18n/strings.yaml のドットキー (上書きの照合用)、resId = 組込文言。
     * 引数は上書き文言では出現順の名前付きプレースホルダ、組込文言では %1$s… に入る。
     */
    fun t(key: String, resId: Int, vararg args: Any): String {
        val ov = overrides?.optString(key).orEmpty()
        if (ov.isNotEmpty()) return fillNamed(ov, args)
        return try {
            if (args.isEmpty()) res.getString(resId) else res.getString(resId, *args)
        } catch (_: Exception) {
            key
        }
    }

    private fun fillNamed(s: String, args: Array<out Any>): String {
        if (args.isEmpty()) return s
        var i = 0
        return PLACEHOLDER.replace(s) { m -> if (i < args.size) args[i++].toString() else m.value }
    }

    companion object {
        private val PLACEHOLDER = Regex("\\{[A-Za-z_][A-Za-z0-9_]*\\}")

        /** 言語の自言語表記 (訪客が自分の言語を見つけられるように)。 */
        fun langDisplayName(lang: String): String = when (lang) {
            "ja" -> "日本語"
            "en" -> "English"
            "zh" -> "中文"
            else -> lang
        }
    }
}
