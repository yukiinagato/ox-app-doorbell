// The icon an option of the visitor flow shows. Purpose data carries emoji (or nothing); the door
// station never renders them and instead maps the purpose id or the known emoji to one of the
// vendored Material Symbols, so every option has the same size, tint and style.
package jp.ox.doorbell

private fun cp(point: Int): String = String(Character.toChars(point))

internal object FlowIcons {

    internal enum class Glyph(val drawable: Int, val emoji: String, val labelKey: String) {
        VISIT(R.drawable.ic_ms_home, cp(0x1F3E0), "flow_editor.icon_kind_visit"),
        DELIVERY(R.drawable.ic_ms_package_2, cp(0x1F4E6), "flow_editor.icon_kind_delivery"),
        MAIL(R.drawable.ic_ms_mail, cp(0x2709), "flow_editor.icon_kind_mail"),
        SALES(R.drawable.ic_ms_work, cp(0x1F4BC), "flow_editor.icon_kind_sales"),
        WORK(R.drawable.ic_ms_build, cp(0x1F527), "flow_editor.icon_kind_work"),
        OTHER(R.drawable.ic_ms_more_horiz, cp(0x22EF), "flow_editor.icon_kind_other"),
        PERSON(R.drawable.ic_ms_person, cp(0x1F464), "flow_editor.icon_kind_person"),
    }

    private val EMOJI: Map<String, Glyph> = HashMap<String, Glyph>().apply {
        fun add(glyph: Glyph, vararg points: Int) { for (point in points) put(cp(point), glyph) }
        add(Glyph.VISIT, 0x1F3E0, 0x1F3E1, 0x1F6AA, 0x1F44B)
        add(Glyph.DELIVERY, 0x1F4E6, 0x1F69A, 0x1F4EE, 0x1F4EF)
        add(Glyph.MAIL, 0x2709, 0x1F4E7, 0x1F4E8, 0x1F4EC, 0x1F4E9, 0x1F4EA)
        add(Glyph.SALES, 0x1F4BC, 0x1F6CD, 0x1F4B0, 0x1F4B4, 0x1F9FE)
        add(Glyph.WORK, 0x1F527, 0x1F528, 0x1F6E0, 0x26A1, 0x1F4A1)
        add(Glyph.OTHER, 0x22EF, 0x2026, 0x2753, 0x1F4AC)
        add(Glyph.PERSON, 0x1F464, 0x1F64B)
    }

    private val ID_WORDS: List<Pair<Glyph, List<String>>> = listOf(
        Glyph.DELIVERY to listOf("deliver", "parcel", "package", "courier", "takuhai", "express"),
        Glyph.MAIL to listOf("mail", "post", "letter"),
        Glyph.SALES to listOf("sales", "sale", "solicit", "collect", "shop", "bag", "business"),
        Glyph.WORK to listOf("utility", "repair", "work", "maint", "tool", "meter", "inspect",
                             "contractor", "service"),
        Glyph.VISIT to listOf("visit", "guest", "friend", "family", "house", "home"),
        Glyph.OTHER to listOf("other", "misc", "etc"),
    )

    /** The icon without presentation selectors, joiners and trailing skin-tone or modifier marks. */
    private fun normalised(icon: String): String {
        val trimmed = icon.trim().filter { it != '️' && it != '︎' && it != '‍' }
        if (trimmed.isEmpty()) return trimmed
        return cp(trimmed.codePointAt(0))
    }

    /**
     * The glyph for an option: a known emoji first, then the purpose id, otherwise the generic
     * person. Anything else the data carries is ignored rather than drawn as text.
     */
    fun glyph(purpose: String, icon: String): Glyph {
        EMOJI[normalised(icon)]?.let { return it }
        val id = purpose.lowercase()
        if (id.isNotEmpty()) for ((glyph, words) in ID_WORDS)
            if (words.any { it in id }) return glyph
        return Glyph.PERSON
    }
}
