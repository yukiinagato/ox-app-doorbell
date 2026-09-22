package jp.ox.doorbell

internal object ClusterDateText {
    private val weekdayKeys = arrayOf(
        "day.sun", "day.mon", "day.tue", "day.wed", "day.thu", "day.fri", "day.sat",
    )

    // Core has already chosen the calendar date and weekday in the configured cluster zone.
    fun format(date: String, weekday: Int, text: (String, Array<String>) -> String): String {
        val parts = date.split("-")
        if (parts.size != 3 || weekday !in weekdayKeys.indices) return date
        if (parts.any { it.isEmpty() || it.any { ch -> ch !in '0'..'9' } }) return date
        val weekdayText = text(weekdayKeys[weekday], emptyArray())
        return text("date.full", arrayOf(parts[0], parts[1], parts[2], weekdayText))
    }
}
