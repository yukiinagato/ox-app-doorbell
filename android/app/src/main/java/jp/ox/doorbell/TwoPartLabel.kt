// Deliberate line breaks for labels that may not fit (spec §5.1).
//
// A label is authored as a primary line and an optional secondary line, never auto-wrapped in the
// middle of a phrase. Catalog entries carry the two parts as separate keys; a configuration
// override may instead carry one string with an embedded newline, so both shapes are accepted
// here and rendered the same way: primary at full size, secondary at 0.8x and muted.
package jp.ox.doorbell

internal data class TwoPartLabel(val primary: String, val secondary: String) {
    val hasSecondary: Boolean get() = secondary.isNotEmpty()
}

internal object TwoPartLabels {

    /** Split one authored string on its first newline. Trailing blank parts are dropped. */
    fun split(value: String): TwoPartLabel {
        val normalized = value.replace("\r\n", "\n").replace('\r', '\n')
        val index = normalized.indexOf('\n')
        if (index < 0) return TwoPartLabel(normalized.trim(), "")
        val primary = normalized.substring(0, index).trim()
        val secondary = normalized.substring(index + 1).replace('\n', ' ').trim()
        return TwoPartLabel(primary, secondary)
    }

    /** Combine two catalog entries; an empty secondary yields a single-line label. */
    fun of(primary: String, secondary: String): TwoPartLabel {
        // A primary that already carries its own break wins, so an override stays authoritative.
        val split = split(primary)
        if (split.hasSecondary) return split
        return TwoPartLabel(split.primary, secondary.trim())
    }

    /** One-line rendering for a control too small for two lines, and for accessibility text. */
    fun flatten(label: TwoPartLabel): String =
        if (label.hasSecondary) "${label.primary} — ${label.secondary}" else label.primary

    const val SECONDARY_SCALE = 0.8f
}
