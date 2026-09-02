// Responsive door-station visitor layout (spec §4.2, §5.1).
//
// Portrait stacks clock → announcement → language row (in the middle) → call button → hint →
// footer. Landscape splits into two columns and, when an announcement exists, the language row
// sits directly above the call button on the right while the announcement occupies the left.
// The arrangement is computed from the window size at runtime, never fixed to one orientation.
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
        minPx: Int,
        maxPx: Int,
    ): Int {
        if (viewportPx <= 0) return maxPx
        val available = viewportPx - headingPx - otherRowsPx - gapPx
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

    /** Whether the dashboard's announcement button and SOS slider stack rather than share a row. */
    fun actionsStacked(widthDp: Int): Boolean = widthDp < FOOTER_SPLIT_MIN_DP

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
        callSection: View,
        hasNotice: Boolean,
        widthDp: Int,
        heightDp: Int,
    ) {
        val arrangement = arrangementFor(widthDp, heightDp)
        detach(header)
        detach(noticeCard)
        detach(langBar)
        detach(callSection)
        columnA.removeAllViews()
        columnB.removeAllViews()

        if (arrangement == Arrangement.STACKED) {
            split.orientation = LinearLayout.VERTICAL
            columnB.visibility = View.GONE
            columnA.visibility = View.VISIBLE
            weight(columnA, 1f, vertical = true)
            columnA.addView(header, wrap())
            columnA.addView(noticeCard, wrap())
            columnA.addView(langBar, wrapCentered())
            columnA.addView(callSection, wrap())
            return
        }

        split.orientation = LinearLayout.HORIZONTAL
        columnA.visibility = View.VISIBLE
        columnB.visibility = View.VISIBLE
        weight(columnA, 1f, vertical = false)
        weight(columnB, 1f, vertical = false)
        columnA.addView(header, wrap())
        if (hasNotice) columnA.addView(noticeCard, wrap())
        // The language buttons sit directly above the call button so a visitor changes language
        // and calls without moving across the screen.
        columnB.addView(langBar, wrapCentered())
        columnB.addView(callSection, wrap())
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
            params.height = 0
        } else {
            params.width = 0
            params.height = ViewGroup.LayoutParams.MATCH_PARENT
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
