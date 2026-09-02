package jp.ox.doorbell

internal data class ManualSipCallIdentity(
    val door: String,
    val callId: String,
    val stageRevision: Int,
)

internal enum class ManualSipCallReportKind { ANSWERED, ENDED }

internal enum class ManualSipClaimResult { NONE, OWNED, LOST_PENDING, LOST_ESTABLISHED }

internal enum class ManualSipPurposeResult { NONE, SUPERSEDED_PENDING, SUPERSEDED_ESTABLISHED }

internal data class ManualSipCallReport(
    val kind: ManualSipCallReportKind,
    val identity: ManualSipCallIdentity,
    val reason: String = "",
    internal val generation: Long = 0L,
)

/** Binds only a user-requested answer dialog; monitor dialogs never enter this state machine. */
internal class ManualSipCallLifecycle {
    private data class Binding(
        var identity: ManualSipCallIdentity,
        val localNodeId: String,
        val generation: Long,
        var established: Boolean = false,
        var endedPending: Boolean = false,
    )

    private var binding: Binding? = null
    private var nextGeneration = 1L

    @Synchronized
    fun bind(identity: ManualSipCallIdentity, localNodeId: String): Boolean {
        if (identity.door.isBlank() || identity.callId.isBlank() || identity.stageRevision < 0)
            return false
        if (localNodeId.isBlank()) return false
        val previous = binding
        if (previous?.established == true)
            return previous.identity == identity && previous.localNodeId == localNodeId
        binding = Binding(identity, localNodeId, nextGeneration++)
        return true
    }

    @Synchronized
    fun onSipState(
        state: String,
        current: ManualSipCallIdentity?,
    ): ManualSipCallReport? {
        val active = binding ?: return null
        if (current == null || current.door != active.identity.door ||
            current.callId != active.identity.callId ||
            current.stageRevision < active.identity.stageRevision) {
            binding = null
            return null
        }
        // A purpose update may advance the revision while this same SIP INVITE is connecting.
        active.identity = current
        return when (state) {
            "in_call" -> {
                if (active.established || active.endedPending) null else {
                    active.established = true
                    ManualSipCallReport(
                        ManualSipCallReportKind.ANSWERED,
                        active.identity,
                        generation = active.generation,
                    )
                }
            }
            "idle" -> {
                if (!active.established) {
                    binding = null
                    null
                } else if (active.endedPending) {
                    null
                } else {
                    active.endedPending = true
                    ManualSipCallReport(
                        ManualSipCallReportKind.ENDED,
                        active.identity,
                        "sip_ended",
                        active.generation,
                    )
                }
            }
            else -> null
        }
    }

    @Synchronized
    fun abandonPending(callId: String) {
        val active = binding ?: return
        if (!active.established && active.identity.callId == callId) binding = null
    }

    @Synchronized
    fun observeAnsweredClaim(callId: String, dialogOwner: String): ManualSipClaimResult {
        val active = binding ?: return ManualSipClaimResult.NONE
        if (callId.isBlank() || callId != active.identity.callId || dialogOwner.isBlank())
            return ManualSipClaimResult.NONE
        if (dialogOwner == active.localNodeId) return ManualSipClaimResult.OWNED
        binding = null
        return if (active.established) ManualSipClaimResult.LOST_ESTABLISHED
        else ManualSipClaimResult.LOST_PENDING
    }

    /** A winning newer purpose revision invalidates the old answer binding without an ended event. */
    @Synchronized
    fun observeWinningPurpose(callId: String, stageRevision: Int): ManualSipPurposeResult {
        val active = binding ?: return ManualSipPurposeResult.NONE
        if (callId.isBlank() || callId != active.identity.callId ||
            stageRevision <= active.identity.stageRevision) return ManualSipPurposeResult.NONE
        binding = null
        return if (active.established) ManualSipPurposeResult.SUPERSEDED_ESTABLISHED
        else ManualSipPurposeResult.SUPERSEDED_PENDING
    }

    @Synchronized
    fun isCurrent(report: ManualSipCallReport): Boolean {
        val active = binding ?: return false
        if (active.generation != report.generation ||
            active.identity.callId != report.identity.callId) return false
        return report.kind != ManualSipCallReportKind.ENDED || active.endedPending
    }

    @Synchronized
    fun complete(report: ManualSipCallReport) {
        if (report.kind == ManualSipCallReportKind.ENDED && isCurrent(report)) binding = null
    }

    @Synchronized
    fun clear(callId: String) {
        if (binding?.identity?.callId == callId) binding = null
    }
}
