package jp.keihan.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ManualSipCallLifecycleTest {
    private val call = ManualSipCallIdentity("front", "call-a", 1)

    @Test
    fun onlyABoundAnswerLegReportsActualEstablishedAndEndedTransitions() {
        val lifecycle = ManualSipCallLifecycle()
        assertNull(lifecycle.onSipState("in_call", call)) // A monitor leg has no binding.
        assertTrue(lifecycle.bind(call, "node-a"))
        assertNull(lifecycle.onSipState("calling", call))

        val answered = lifecycle.onSipState("in_call", call)
        assertEquals(ManualSipCallReportKind.ANSWERED, answered?.kind)
        assertEquals(call, answered?.identity)
        assertNull(lifecycle.onSipState("in_call", call))

        val ended = lifecycle.onSipState("idle", call)
        assertEquals(ManualSipCallReportKind.ENDED, ended?.kind)
        assertEquals("sip_ended", ended?.reason)
        assertTrue(lifecycle.isCurrent(ended!!))
        lifecycle.complete(ended)
        assertNull(lifecycle.onSipState("idle", call))
    }

    @Test
    fun staleCallCannotProduceLifecycleReports() {
        val lifecycle = ManualSipCallLifecycle()
        assertTrue(lifecycle.bind(call, "node-a"))
        assertNull(lifecycle.onSipState(
            "in_call",
            ManualSipCallIdentity("front", "call-b", 1),
        ))
        assertNull(lifecycle.onSipState("idle", call))

        assertTrue(lifecycle.bind(call, "node-a"))
        assertNull(lifecycle.onSipState(
            "in_call",
            ManualSipCallIdentity("front", "call-a", 0),
        ))
    }

    @Test
    fun currentStageAdvanceIsUsedAndFailedInviteDoesNotReportEnded() {
        val lifecycle = ManualSipCallLifecycle()
        assertTrue(lifecycle.bind(call, "node-a"))
        val revised = ManualSipCallIdentity("front", "call-a", 2)
        assertEquals(revised, lifecycle.onSipState("in_call", revised)?.identity)
        val ended = lifecycle.onSipState("idle", revised)
        assertEquals(revised, ended?.identity)
        lifecycle.complete(ended!!)

        assertTrue(lifecycle.bind(call, "node-a"))
        assertNull(lifecycle.onSipState("idle", call))
        assertNull(lifecycle.onSipState("in_call", call))
    }

    @Test
    fun abandoningAnActivityClearsOnlyAnUnestablishedBinding() {
        val lifecycle = ManualSipCallLifecycle()
        assertFalse(lifecycle.bind(ManualSipCallIdentity("", "call-a", 0), "node-a"))
        assertTrue(lifecycle.bind(call, "node-a"))
        lifecycle.abandonPending(call.callId)
        assertNull(lifecycle.onSipState("in_call", call))

        assertTrue(lifecycle.bind(call, "node-a"))
        assertEquals(ManualSipCallReportKind.ANSWERED,
            lifecycle.onSipState("in_call", call)?.kind)
        lifecycle.abandonPending(call.callId)
        val ended = lifecycle.onSipState("idle", call)
        assertEquals(ManualSipCallReportKind.ENDED, ended?.kind)
        lifecycle.complete(ended!!)
    }

    @Test
    fun anotherDialogOwnerClearsAnEstablishedLegWithoutReportingEnded() {
        val lifecycle = ManualSipCallLifecycle()
        assertTrue(lifecycle.bind(call, "node-a"))
        assertEquals(ManualSipCallReportKind.ANSWERED,
            lifecycle.onSipState("in_call", call)?.kind)

        assertEquals(ManualSipClaimResult.LOST_ESTABLISHED,
            lifecycle.observeAnsweredClaim(call.callId, "node-b"))
        assertNull(lifecycle.onSipState("idle", call))
    }

    @Test
    fun theLocalDialogOwnerPreservesTheBindingUntilActualIdle() {
        val lifecycle = ManualSipCallLifecycle()
        assertTrue(lifecycle.bind(call, "node-a"))
        assertEquals(ManualSipCallReportKind.ANSWERED,
            lifecycle.onSipState("in_call", call)?.kind)

        assertEquals(ManualSipClaimResult.OWNED,
            lifecycle.observeAnsweredClaim(call.callId, "node-a"))
        val ended = lifecycle.onSipState("idle", call)
        assertEquals(ManualSipCallReportKind.ENDED, ended?.kind)
        lifecycle.complete(ended!!)
    }

    @Test
    fun anotherOwnerCanWinBeforeTheAnswerInviteEstablishes() {
        val lifecycle = ManualSipCallLifecycle()
        assertTrue(lifecycle.bind(call, "node-a"))

        assertEquals(ManualSipClaimResult.NONE,
            lifecycle.observeAnsweredClaim("call-b", "node-b"))
        assertEquals(ManualSipClaimResult.LOST_PENDING,
            lifecycle.observeAnsweredClaim(call.callId, "node-b"))
        assertNull(lifecycle.onSipState("in_call", call))
    }

    @Test
    fun competingClaimInvalidatesAnEndedReportQueuedForCore() {
        val lifecycle = ManualSipCallLifecycle()
        assertTrue(lifecycle.bind(call, "node-a"))
        lifecycle.onSipState("in_call", call)
        val ended = lifecycle.onSipState("idle", call)!!
        assertTrue(lifecycle.isCurrent(ended))

        assertEquals(ManualSipClaimResult.LOST_ESTABLISHED,
            lifecycle.observeAnsweredClaim(call.callId, "node-b"))
        assertFalse(lifecycle.isCurrent(ended))
    }

    @Test
    fun newerPurposeClearsAnsweredBindingAndLosingIdleCannotEndTheNewRevision() {
        val lifecycle = ManualSipCallLifecycle()
        val revisionZero = ManualSipCallIdentity("front", "call-purpose", 0)
        assertTrue(lifecycle.bind(revisionZero, "node-a"))
        assertEquals(ManualSipCallReportKind.ANSWERED,
            lifecycle.onSipState("in_call", revisionZero)?.kind)

        assertEquals(ManualSipPurposeResult.SUPERSEDED_ESTABLISHED,
            lifecycle.observeWinningPurpose(revisionZero.callId, 1))
        assertNull(lifecycle.onSipState(
            "idle",
            ManualSipCallIdentity("front", revisionZero.callId, 1),
        ))
        assertEquals(ManualSipPurposeResult.NONE,
            lifecycle.observeWinningPurpose(revisionZero.callId, 1))
    }
}
