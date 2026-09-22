package jp.ox.doorbell

internal data class VisitorCallAction(val callId: String, val phase: CallUiPhase)

/** A touch or key gesture cannot acquire a different action while its button is relabelled. */
internal class VisitorActionLatch {
    private var held: VisitorCallAction? = null
    private var tracking = false

    fun begin(action: VisitorCallAction?) {
        held = action
        tracking = true
    }

    fun cancel() {
        held = null
        tracking = false
    }

    fun consume(current: VisitorCallAction?): VisitorCallAction? {
        val requested = if (tracking) held else current
        cancel()
        return requested?.takeIf { it == current }
    }
}
