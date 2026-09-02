package jp.keihan.doorbell

internal enum class CallRevisionUpdate {
    STALE,
    ADVANCED,
    ANSWER_SUPERSEDED,
}

/** Keeps a superseded answer leg from resolving the newer ringing revision on its final Idle. */
internal class CallRevisionLifecycle(initialStageRevision: Int) {
    var stageRevision: Int = initialStageRevision.coerceAtLeast(0)
        private set

    private var answerRevision: Int? = null
    private var suppressingLosingIdle = false

    fun beginAnswer() {
        answerRevision = stageRevision
    }

    fun observeWinningRevision(revision: Int): CallRevisionUpdate {
        if (revision <= stageRevision) return CallRevisionUpdate.STALE
        stageRevision = revision
        if (answerRevision == null) return CallRevisionUpdate.ADVANCED
        answerRevision = null
        suppressingLosingIdle = true
        return CallRevisionUpdate.ANSWER_SUPERSEDED
    }

    fun consumeSupersededIdle(): Boolean {
        if (!suppressingLosingIdle) return false
        suppressingLosingIdle = false
        return true
    }
}
