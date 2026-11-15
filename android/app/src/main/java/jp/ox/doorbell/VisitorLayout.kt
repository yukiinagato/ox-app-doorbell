// Responsive secondary content; the primary action stays in the Activity's separate dock.
package jp.ox.doorbell

import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout

internal object VisitorLayout {

    /** Tablets get a taller call button and a larger hint. */
    const val TABLET_MIN_DP = 768

    internal enum class Arrangement { STACKED, SPLIT }

    /** The arrangement for a window; landscape only splits when it is genuinely wide. */
    fun arrangementFor(widthDp: Int, heightDp: Int): Arrangement =
        if (widthDp > heightDp && widthDp >= SPLIT_MIN_DP) Arrangement.SPLIT
        else Arrangement.STACKED

    fun callButtonHeightDp(widthDp: Int): Int = if (widthDp >= TABLET_MIN_DP) 96 else 72

    /**
     * The gap between the visitor screen's groups (clock, announcement, language row, call
     * button). Breathing room is added only out of genuine slack: [contentDp] is what the groups
     * measured without any gaps, so a short screen keeps the tight layout rather than pushing the
     * call button off the bottom.
     */
    fun groupGapDp(availableDp: Int, contentDp: Int, groups: Int): Int {
        if (groups <= 1) return 0
        val slack = availableDp - contentDp
        if (slack <= 0) return 0
        // Spend at most two thirds of the slack, so the layout never ends up flush to the edges.
        val perGap = (slack * 2 / 3) / (groups - 1)
        for (step in SPACING_SCALE) if (perGap >= step) return step
        return 0
    }

    /** The 4 dp-based spacing scale, largest first. */
    val SPACING_SCALE = intArrayOf(32, 24, 16, 12, 8, 4)

    /**
     * How tall a door tile's preview may be so the whole tile fits above the QR footer.
     *
     * The tile column ends above the footer, but a tile taller than that area had its bottom row
     * -- the door name and the 見る action -- cut off at the scroll boundary, which reads as the
     * label vanishing under the footer. The preview is the only part that may give up height, so
     * it is derived from the measured viewport rather than guessed per orientation.
     *
     * All values are pixels. [otherRowsPx] is everything in the card except the preview.
     */
    fun tileStillHeightPx(
        viewportPx: Int,
        headingPx: Int,
        otherRowsPx: Int,
        gapPx: Int,
        tileCount: Int,
        minPx: Int,
        maxPx: Int,
    ): Int {
        if (viewportPx <= 0) return maxPx
        // One camera may use the whole viewport. Two or three share it without forcing the
        // resident to scroll just to compare them. A larger fleet deliberately sizes for three
        // compact cards: the scroll position then becomes the resident's camera selection.
        val fittingCount = tileCount.coerceIn(1, 3)
        val available = (viewportPx - headingPx - gapPx * fittingCount) / fittingCount -
            otherRowsPx
        // Clamped: below the floor the preview is useless, above the ceiling it wastes the column.
        return available.coerceIn(minPx, maxPx)
    }

    /**
     * Whether the footer stacks the version line above the SOS slider.
     *
     * They must never overlap or clip each other: the observed failure was the version line cut
     * off by the slider on a portrait phone. Anything portrait, and anything narrower than a
     * tablet, stacks; only a genuinely wide landscape window puts them side by side.
     */
    fun footerStacked(widthDp: Int, heightDp: Int): Boolean =
        widthDp < FOOTER_SPLIT_MIN_DP || widthDp <= heightDp

    /**
     * Whether the dashboard header puts the clock on its own row above the membership pill and
     * the buttons, rather than sharing one row with them.
     *
     * The one-row header is a landscape arrangement: the clock takes the leftover width after the
     * pill, the missed badge and 管理 have taken theirs. On a portrait phone those three want
     * nearly the whole width, so "leftover" was about one character and the clock rendered one
     * glyph per line down the left edge -- observed on the Moto. Portrait, and anything narrower
     * than a tablet, therefore gets its own full-width clock row.
     */
    fun dashboardHeaderStacked(widthDp: Int, heightDp: Int): Boolean =
        widthDp <= heightDp || widthDp < FOOTER_SPLIT_MIN_DP

    fun hintTextSizeSp(widthDp: Int): Float = if (widthDp >= TABLET_MIN_DP) 20f else 15f

    /** The clock beside the language switch on the flow home: secondary, never a headline. */
    const val COMPACT_CLOCK_SP = 18f
    const val COMPACT_DATE_SP = 12f

    /** Below this the language switch leaves no room for the clock beside it. */
    const val COMPACT_ROW_MIN_DP = 480

    fun clockTextSizeSp(widthDp: Int, heightDp: Int): Float = when {
        widthDp >= TABLET_MIN_DP -> 72f
        minOf(widthDp, heightDp) < 360 -> 40f
        else -> 52f
    }

    /**
     * Place the visitor sections into the two columns.
     *
     * [notice] is null when no announcement is showing, which is what decides whether the
     * language row joins the call column in landscape.
     */
    fun apply(
        split: LinearLayout,
        columnA: LinearLayout,
        columnB: LinearLayout,
        header: View,
        noticeCard: View,
        langBar: View,
        hasNotice: Boolean,
        widthDp: Int,
        heightDp: Int,
        compact: Boolean = false,
    ) {
        val arrangement = arrangementFor(widthDp, heightDp)
        detach(header)
        detach(noticeCard)
        detach(langBar)
        columnA.removeAllViews()
        columnB.removeAllViews()
        val narrow = compact && widthDp < COMPACT_ROW_MIN_DP
        (header as? LinearLayout)?.let { box ->
            box.orientation = if (narrow) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
            box.gravity = when {
                narrow -> android.view.Gravity.END or android.view.Gravity.CENTER_VERTICAL
                compact -> android.view.Gravity.END
                else -> android.view.Gravity.CENTER
            }
            // Clock and date share one line when the language switch takes the rest of the row.
            (box.getChildAt(1)?.layoutParams as? LinearLayout.LayoutParams)?.leftMargin =
                if (narrow) (12 * box.resources.displayMetrics.density).toInt() else 0
        }

        if (compact) {
            // The flow home: language switch at the start of one quiet top row, clock and date at
            // its end; the page below owns the rest of the screen.
            split.orientation = LinearLayout.VERTICAL
            columnB.visibility = View.GONE
            columnA.visibility = View.VISIBLE
            weight(columnA, 1f, vertical = true)
            if (narrow) {
                columnA.addView(header, wrap())
                columnA.addView(noticeCard, wrap())
                columnA.addView(langBar, wrapCentered())
                return
            }
            val row = LinearLayout(columnA.context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = android.view.Gravity.CENTER_VERTICAL
                isBaselineAligned = false
            }
            row.addView(langBar, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            row.addView(View(row.context), LinearLayout.LayoutParams(0, 1, 1f))
            row.addView(header, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            columnA.addView(row, wrap())
            columnA.addView(noticeCard, wrap())
            return
        }

        if (arrangement == Arrangement.STACKED) {
            split.orientation = LinearLayout.VERTICAL
            columnB.visibility = View.GONE
            columnA.visibility = View.VISIBLE
            weight(columnA, 1f, vertical = true)
            columnA.addView(header, wrap())
            columnA.addView(noticeCard, wrap())
            columnA.addView(langBar, wrapCentered())
            return
        }

        split.orientation = LinearLayout.HORIZONTAL
        columnA.visibility = View.VISIBLE
        columnB.visibility = View.VISIBLE
        weight(columnA, 1f, vertical = false)
        weight(columnB, 1f, vertical = false)
        columnA.addView(header, wrap())
        if (hasNotice) columnA.addView(noticeCard, wrap())
        columnB.addView(langBar, wrapCentered())
        if (!hasNotice) noticeCard.visibility = View.GONE
    }

    private fun detach(view: View) {
        (view.parent as? ViewGroup)?.removeView(view)
    }

    private fun weight(column: LinearLayout, value: Float, vertical: Boolean) {
        val params = column.layoutParams as? LinearLayout.LayoutParams
            ?: LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
            )
        if (vertical) {
            params.width = ViewGroup.LayoutParams.MATCH_PARENT
            params.height = ViewGroup.LayoutParams.WRAP_CONTENT
        } else {
            params.width = 0
            params.height = ViewGroup.LayoutParams.WRAP_CONTENT
        }
        params.weight = value
        column.layoutParams = params
    }

    private fun wrap(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
    )

    private fun wrapCentered(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
    ).apply { gravity = android.view.Gravity.CENTER_HORIZONTAL }

    private const val SPLIT_MIN_DP = 600

    /** Below this a row of two controls cannot hold both without clipping one of them. */
    const val FOOTER_SPLIT_MIN_DP = 600
}
