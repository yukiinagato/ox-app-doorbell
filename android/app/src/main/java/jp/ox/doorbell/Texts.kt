// Resolve configuration overrides before localized Android resources. Named placeholders use
// the same encounter order as the generated positional placeholders from i18n/strings.yaml.
package jp.ox.doorbell

import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import java.util.Locale
import org.json.JSONObject

class Texts(private val base: Context) {

    /** Current display language: visitor language at a door, boot.ui_lang indoors. */
    var lang: String = "ja"
        private set

    private var config: JSONObject? = null
    private var overrides: JSONObject? = null
    private var res: Resources = base.resources

    /** Replace the configuration tree at startup or after config_changed. */
    fun setConfig(cfg: JSONObject?) {
        config = cfg
        reload()
    }

    /** Switch display language and its built-in resource context. */
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
     * key identifies an i18n/strings.yaml entry for override lookup; resId selects the built-in
     * translation. Arguments fill named overrides by encounter order and positional resources.
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

        /** Native language names let visitors identify their language. */
        fun langDisplayName(lang: String): String = when (lang) {
            "ja" -> "日本語"
            "en" -> "English"
            "zh" -> "中文"
            else -> lang
        }
    }
}
