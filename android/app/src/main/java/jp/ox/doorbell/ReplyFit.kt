package jp.ox.doorbell

/** Largest font size at which a quick reply fits the visitor content area. */
object ReplyFit {
    class Extent(val width: Int, val height: Int)

    class Result(val sizePx: Int, val fits: Boolean)

    /**
     * Binary search over whole pixels between [floorPx] and [ceilingPx]. [measure] returns the
     * wrapped extent of the text at a size. When even the floor overflows, the floor is kept and
     * [Result.fits] is false so the caller lets the text scroll instead of truncating it.
     */
    fun fit(
        widthPx: Int,
        heightPx: Int,
        floorPx: Int,
        ceilingPx: Int,
        measure: (Int) -> Extent,
    ): Result {
        fun fits(size: Int): Boolean {
            val e = measure(size)
            return e.width <= widthPx && e.height <= heightPx
        }
        var lo = floorPx
        var hi = maxOf(floorPx, ceilingPx)
        if (!fits(lo)) return Result(lo, false)
        while (lo < hi) {
            val mid = (lo + hi + 1) / 2
            if (fits(mid)) lo = mid else hi = mid - 1
        }
        return Result(lo, true)
    }
}

/**
 * Guarded dismissal of the quick-reply overlay: taps are ignored for [GUARD_MS]; a first tap
 * after that arms the guard for [CONFIRM_MS]; a second tap at least [MIN_GAP_MS] later closes.
 */
class ReplyDismissGuard(private val shownAtMs: Long) {
    enum class Tap { IGNORE, ARM, CLOSE }
    enum class Hint { NONE, EXIT, CONFIRM }

    private var armedAtMs: Long? = null

    private fun armed(now: Long): Boolean {
        val at = armedAtMs ?: return false
        return now - at <= CONFIRM_MS
    }

    fun tap(now: Long): Tap {
        if (now - shownAtMs < GUARD_MS) return Tap.IGNORE
        if (armed(now)) return if (now - armedAtMs!! < MIN_GAP_MS) Tap.IGNORE else Tap.CLOSE
        armedAtMs = now
        return Tap.ARM
    }

    fun hint(now: Long): Hint = when {
        now - shownAtMs < GUARD_MS -> Hint.NONE
        armed(now) -> Hint.CONFIRM
        else -> Hint.EXIT
    }

    companion object {
        const val GUARD_MS = 3000L
        const val CONFIRM_MS = 3000L
        const val MIN_GAP_MS = 300L
    }
}
