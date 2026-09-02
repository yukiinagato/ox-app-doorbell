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
}
