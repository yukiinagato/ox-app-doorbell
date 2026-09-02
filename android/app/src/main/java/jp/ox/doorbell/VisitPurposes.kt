// Visit purposes and the cross-platform visit_purposes.<id>.enabled flag.
//
// A disabled purpose is never offered to a visitor, but its label must still resolve: a call that
// is already in flight, and every row already in the call history, keeps showing the purpose the
// visitor actually chose even after an administrator turns it off. So the chooser filters and the
// label lookup does not. The settings list shows every purpose, enabled or not, because that is
// where the flag is turned back on.
//
// Pure, so the precedence and the default are host-tested.
package jp.ox.doorbell

import org.json.JSONObject

internal object VisitPurposes {

    /** Absent means enabled: an installation that predates the flag keeps every purpose. */
    fun isEnabled(entry: JSONObject?): Boolean = entry?.optBoolean("enabled", true) ?: true

    fun isEnabled(config: JSONObject?, id: String): Boolean =
        isEnabled(entryOf(config, id))

    /** Every configured purpose, ordered, including disabled ones. For the settings list. */
    fun all(config: JSONObject?): List<String> = ordered(rootOf(config))

    /** Only the purposes a visitor may choose. For the door station's chooser. */
    fun enabled(config: JSONObject?): List<String> {
        val root = rootOf(config) ?: return emptyList()
        return ordered(root).filter { isEnabled(root.optJSONObject(it)) }
    }

    /**
     * The label for one purpose in the requested language, falling back to Japanese and then to
     * the identifier. Resolves for a disabled purpose too, so an in-flight call and the history
     * never lose the visitor's own words.
     */
    fun label(config: JSONObject?, id: String, lang: String): String {
        if (id.isEmpty()) return ""
        val labels = entryOf(config, id)?.optJSONObject("label") ?: return id
        val value = labels.optString(lang)
        if (value.isNotEmpty()) return value
        return labels.optString("ja").ifEmpty { id }
    }

    fun icon(config: JSONObject?, id: String): String =
        entryOf(config, id)?.optString("icon").orEmpty()

    /** The label with its icon in front, as the chooser and the badges render it. */
    fun decoratedLabel(config: JSONObject?, id: String, lang: String): String {
        val label = label(config, id, lang)
        val icon = icon(config, id)
        return if (icon.isEmpty()) label else "$icon  $label"
    }

    /** The configuration key the settings toggle writes. */
    fun enabledKey(id: String): String = "visit_purposes.$id.enabled"

    internal fun rootOf(config: JSONObject?): JSONObject? =
        config?.optJSONObject("visit_purposes")

    private fun entryOf(config: JSONObject?, id: String): JSONObject? =
        rootOf(config)?.optJSONObject(id)

    /** Sorted by the configured order, then by identifier so the result is deterministic. */
    private fun ordered(root: JSONObject?): List<String> {
        if (root == null) return emptyList()
        val ids = root.keys().asSequence().toMutableList()
        ids.sortWith(compareBy({ root.optJSONObject(it)?.optInt("order", 999) ?: 999 }, { it }))
        return ids
    }
}
