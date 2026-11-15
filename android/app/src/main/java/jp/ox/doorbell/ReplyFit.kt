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
