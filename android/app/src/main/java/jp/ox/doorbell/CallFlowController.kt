package jp.ox.doorbell

internal enum class CallFlowMode {
    PURPOSE_FIRST,
    RING_THEN_PURPOSE;

    companion object {
        fun parse(value: String): CallFlowMode =
            if (value == "ring_then_purpose") RING_THEN_PURPOSE else PURPOSE_FIRST
    }
}

internal enum class CallUiPhase {
    IDLE,
    PURPOSE_PENDING,
    RINGING,
    ESTABLISHED,
}

internal data class OriginatedCall(
    val callId: String,
    val door: String,
    val stageRevision: Int,
    val expiresAtMs: Long,
    val purpose: String,
    val phase: CallUiPhase,
)

internal data class CallTransition(
    val phase: CallUiPhase,
    val call: OriginatedCall? = null,
    val accepted: Boolean = true,
)

internal interface CallFlowGateway {
    fun press(door: String, purpose: String): String?
    fun selectPurpose(door: String, callId: String, purpose: String): Boolean
    fun cancel(door: String, callId: String, reason: String): Boolean
    fun reportRecovery(callId: String, restored: Boolean)
    fun hangup()
}

internal class CallFlowController(
    private val gateway: CallFlowGateway,
    private val persistence: OriginatedCallPersistence,
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    private val lock = Any()
    private var mode = CallFlowMode.PURPOSE_FIRST
    private var ttlMs = DEFAULT_TTL_MS
    private var currentCall: OriginatedCall? = persistence.load()
    private var pendingDoor: String? = null
    private var startingDoor: String? = null
    private var startingPhase = CallUiPhase.IDLE
    private var cancellationInFlight = ""
    private var cancellationAttempted = ""

    init {
        synchronized(lock) { discardExpiredLocked(nowMs()) }
    }

    fun configure(callFlow: String, callTtlSeconds: Long) {
        synchronized(lock) {
            mode = CallFlowMode.parse(callFlow)
            ttlMs = callTtlSeconds.coerceIn(MIN_TTL_SECONDS, MAX_TTL_SECONDS) * 1000L
        }
    }

    fun mode(): CallFlowMode = synchronized(lock) { mode }

    fun current(): OriginatedCall? = synchronized(lock) {
        discardExpiredLocked(nowMs())
        currentCall
    }

    fun begin(door: String): CallTransition {
        synchronized(lock) {
            discardExpiredLocked(nowMs())
            currentCall?.let { return transitionFor(it) }
            if (mode == CallFlowMode.PURPOSE_FIRST) {
                pendingDoor = door
                return CallTransition(CallUiPhase.PURPOSE_PENDING)
            }
        }
        return startCall(door, "", CallUiPhase.PURPOSE_PENDING)
    }

    fun selectPurpose(purpose: String): CallTransition {
        if (purpose.isEmpty()) return snapshot(accepted = false)
        val state = synchronized(lock) {
            discardExpiredLocked(nowMs())
            Pair(currentCall, pendingDoor)
        }
        val active = state.first
        if (active == null) {
            val door = state.second ?: return snapshot(accepted = false)
            return startCall(door, purpose, CallUiPhase.RINGING)
        }
        if (active.phase != CallUiPhase.PURPOSE_PENDING) return transitionFor(active)
        val accepted = gateway.selectPurpose(active.door, active.callId, purpose)
        if (!accepted) return snapshot(accepted = false)
        return synchronized(lock) {
            val latest = currentCall
            if (latest == null || latest.callId != active.callId) {
                CallTransition(CallUiPhase.IDLE, accepted = false)
            } else {
                val updated = latest.copy(
                    stageRevision = maxOf(latest.stageRevision, active.stageRevision + 1),
                    purpose = purpose,
                    phase = CallUiPhase.RINGING,
                )
                persistLocked(updated)
                transitionFor(updated)
            }
        }
    }

    fun skipPurpose(): CallTransition {
        val state = synchronized(lock) {
            discardExpiredLocked(nowMs())
            Pair(currentCall, pendingDoor)
        }
        val active = state.first
        if (active == null) {
            val door = state.second ?: return snapshot(accepted = false)
            return startCall(door, "", CallUiPhase.RINGING)
        }
        return synchronized(lock) {
            val latest = currentCall
            if (latest == null || latest.callId != active.callId) {
                CallTransition(CallUiPhase.IDLE, accepted = false)
            } else {
                val updated = latest.copy(phase = CallUiPhase.RINGING)
                persistLocked(updated)
                transitionFor(updated)
            }
        }
    }

    fun cancel(reason: String): CallTransition {
        val active = synchronized(lock) {
            pendingDoor = null
            val value = currentCall
            if (value == null) return CallTransition(CallUiPhase.IDLE)
            if (cancellationInFlight == value.callId || cancellationAttempted == value.callId)
                return transitionFor(value).copy(accepted = false)
            cancellationInFlight = value.callId
            value
        }
        val accepted = try {
            gateway.cancel(active.door, active.callId, reason)
        } catch (_: Exception) {
            false
        }
        return synchronized(lock) {
            if (cancellationInFlight == active.callId) cancellationInFlight = ""
            if (currentCall?.callId == active.callId) {
                cancellationAttempted = active.callId
                if (accepted) clearLocked()
            }
            currentCall?.let { transitionFor(it).copy(accepted = accepted) }
                ?: CallTransition(CallUiPhase.IDLE, accepted = accepted)
        }
    }

    fun timeout(atMs: Long = nowMs()): CallTransition {
        synchronized(lock) {
            val value = currentCall
            if (value == null) {
                pendingDoor = null
                return CallTransition(CallUiPhase.IDLE)
            }
            if (atMs < value.expiresAtMs) return transitionFor(value)
        }
        return cancel("timeout")
    }

    fun markEstablished(): CallTransition = synchronized(lock) {
        val active = currentCall ?: return CallTransition(CallUiPhase.IDLE, accepted = false)
        val updated = active.copy(phase = CallUiPhase.ESTABLISHED)
        persistLocked(updated)
        transitionFor(updated)
    }

    fun endEstablished(): CallTransition {
        val established = synchronized(lock) {
            currentCall?.takeIf { it.phase == CallUiPhase.ESTABLISHED }
        } ?: return snapshot(accepted = false)
        gateway.hangup()
        synchronized(lock) {
            if (currentCall?.callId == established.callId) clearLocked()
        }
        return CallTransition(CallUiPhase.IDLE)
    }

    fun finishLocal(): CallTransition {
        synchronized(lock) { clearLocked() }
        return CallTransition(CallUiPhase.IDLE)
    }

    fun observePress(
        door: String,
        callId: String,
        stageRevision: Int,
        expiresAtMs: Long,
        purpose: String,
    ): Boolean = synchronized(lock) {
        if (!validEvent(callId, stageRevision, expiresAtMs)) return false
        val active = currentCall
        val starting = startingDoor == door
        if (!starting && active?.callId != callId) return false
        val phase = if (active?.callId == callId) active.phase else startingPhase
        val updated = OriginatedCall(
            callId,
            door,
            stageRevision,
            expiresAtMs,
            purpose,
            phase.takeIf { it != CallUiPhase.IDLE } ?: CallUiPhase.RINGING,
        )
        persistLocked(updated)
        true
    }

    fun observePurpose(
        door: String,
        callId: String,
        stageRevision: Int,
        expiresAtMs: Long,
        purpose: String,
    ): Boolean = synchronized(lock) {
        val active = currentCall ?: return false
        if (active.callId != callId || active.door != door ||
            stageRevision < active.stageRevision || expiresAtMs <= nowMs()) return false
        persistLocked(active.copy(
            stageRevision = stageRevision,
            expiresAtMs = expiresAtMs,
            purpose = purpose,
            phase = CallUiPhase.RINGING,
        ))
        true
    }

    fun observeCancellation(callId: String, stageRevision: Int): Boolean = synchronized(lock) {
        val active = currentCall ?: return false
        if (callId.isEmpty() || callId != active.callId || stageRevision < active.stageRevision)
            return false
        clearLocked()
        true
    }

    fun observeAnswered(
        callId: String,
        stageRevision: Int,
        expiresAtMs: Long,
    ): Boolean = synchronized(lock) {
        val active = currentCall ?: return false
        if (callId.isEmpty() || callId != active.callId ||
            stageRevision < active.stageRevision || expiresAtMs <= nowMs()) return false
        persistLocked(active.copy(
            stageRevision = stageRevision,
            expiresAtMs = expiresAtMs,
            phase = CallUiPhase.ESTABLISHED,
        ))
        true
    }

    fun observeEnded(callId: String, stageRevision: Int): Boolean = synchronized(lock) {
        val active = currentCall ?: return false
        if (callId.isEmpty() || callId != active.callId || stageRevision < active.stageRevision)
            return false
        clearLocked()
        true
    }

    fun observeResolvedDoor(door: String): Boolean = synchronized(lock) {
        val active = currentCall ?: return false
        if (door.isNotEmpty() && active.door != door) return false
        clearLocked()
        true
    }

    fun recoveryCandidate(callId: String, door: String, atMs: Long = nowMs()): OriginatedCall? =
        synchronized(lock) {
            discardExpiredLocked(atMs)
            currentCall?.takeIf {
                it.callId == callId && (door.isEmpty() || it.door == door) && it.expiresAtMs > atMs
            }
        }

    fun reportRecovery(callId: String, restored: Boolean) {
        gateway.reportRecovery(callId, restored)
        if (!restored) synchronized(lock) {
            if (currentCall?.callId == callId) clearLocked()
        }
    }

    fun remainingMs(atMs: Long = nowMs()): Long = synchronized(lock) {
        (currentCall?.expiresAtMs?.minus(atMs) ?: 0L).coerceAtLeast(0L)
    }

    private fun startCall(door: String, purpose: String, phase: CallUiPhase): CallTransition {
        synchronized(lock) {
            if (startingDoor != null) return snapshotLocked(accepted = false)
            startingDoor = door
            startingPhase = phase
            pendingDoor = null
        }
        val callId = try {
            gateway.press(door, purpose).orEmpty()
        } catch (_: Exception) {
            ""
        }
        val transition = synchronized(lock) {
            startingDoor = null
            startingPhase = CallUiPhase.IDLE
            if (callId.isEmpty()) {
                if (currentCall == null) persistence.clear()
                return@synchronized snapshotLocked(accepted = false)
            }
            val observed = currentCall?.takeIf { it.callId == callId }
            val active = observed ?: OriginatedCall(
                callId = callId,
                door = door,
                stageRevision = 0,
                expiresAtMs = nowMs() + ttlMs,
                purpose = purpose,
                phase = phase,
            ).also(::persistLocked)
            transitionFor(active)
        }
        return transition
    }

    private fun snapshot(accepted: Boolean): CallTransition = synchronized(lock) {
        snapshotLocked(accepted)
    }

    private fun snapshotLocked(accepted: Boolean): CallTransition =
        currentCall?.let { transitionFor(it).copy(accepted = accepted) }
            ?: CallTransition(
                if (pendingDoor != null) CallUiPhase.PURPOSE_PENDING else CallUiPhase.IDLE,
                accepted = accepted,
            )

    private fun transitionFor(call: OriginatedCall): CallTransition =
        CallTransition(call.phase, call)

    private fun persistLocked(call: OriginatedCall) {
        if (currentCall?.callId != call.callId) {
            cancellationInFlight = ""
            cancellationAttempted = ""
        }
        currentCall = call
        persistence.save(call)
    }

    private fun clearLocked() {
        currentCall = null
        pendingDoor = null
        cancellationInFlight = ""
        cancellationAttempted = ""
        persistence.clear()
    }

    private fun discardExpiredLocked(atMs: Long) {
        val active = currentCall ?: return
        if (active.expiresAtMs <= atMs) clearLocked()
    }

    private fun validEvent(callId: String, stageRevision: Int, expiresAtMs: Long): Boolean =
        callId.isNotEmpty() && stageRevision >= 0 && expiresAtMs > nowMs()

    companion object {
        private const val DEFAULT_TTL_MS = 60_000L
        private const val MIN_TTL_SECONDS = 10L
        private const val MAX_TTL_SECONDS = 300L
    }
}
