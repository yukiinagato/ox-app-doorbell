// Readability warnings that ride along with a *successful* configuration write (spec §5.2).
//
// A colour below the WCAG 2.1 AA ratio is never rejected: core commits the value and reports
//   {"key":"…","property":"foreground","contrast":3.1,"message_key":"theme.low_contrast"}
// which the shell shows as the measured ratio next to the field. db_core_config_batch_json embeds
// the array in its result; a single-key write reads the same array from
// db_core_last_write_warnings_json immediately afterwards.
package jp.ox.doorbell

import org.json.JSONArray

internal data class WriteWarning(
    val key: String,
    val property: String,
    val contrast: Double,
    /** The catalogue key to render, so every shell shows the same sentence. */
    val messageKey: String,
) {
    /** The ratio as the advisory renders it, for example "3.1". */
    fun ratioText(): String = UiContrast.ratioText(contrast)
}

internal object WriteWarnings {

    const val LOW_CONTRAST = "theme.low_contrast"

    fun parse(array: JSONArray?): List<WriteWarning> {
        if (array == null || array.length() == 0) return emptyList()
        val out = ArrayList<WriteWarning>(array.length())
        for (index in 0 until array.length()) {
            val entry = array.optJSONObject(index) ?: continue
            val messageKey = entry.optString("message_key").ifEmpty { LOW_CONTRAST }
            out.add(
                WriteWarning(
                    key = entry.optString("key"),
                    property = entry.optString("property"),
                    contrast = entry.optDouble("contrast", 0.0),
                    messageKey = messageKey,
                ),
            )
        }
        return out
    }

    /** The first warning is what the row shows; the rest are the same sentence for other fields. */
    fun first(array: JSONArray?): WriteWarning? = parse(array).firstOrNull()

    /**
     * Render the advisory. [lookup] resolves the catalogue key with the ratio substituted, so an
     * unknown message_key from a newer core still shows something rather than nothing.
     */
    fun message(warning: WriteWarning?, lookup: (String, String) -> String): String {
        if (warning == null) return ""
        return lookup(warning.messageKey, warning.ratioText())
    }
}
