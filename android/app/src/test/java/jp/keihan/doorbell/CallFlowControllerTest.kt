package jp.keihan.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CallFlowControllerTest {
    @Test
    fun purposeFirstDoesNotPressUntilPurposeIsConfirmed() {
        val fixture = Fixture()

        val pending = fixture.controller.begin("front")

        assertEquals(CallUiPhase.PURPOSE_PENDING, pending.phase)
        assertNull(pending.call)
        assertTrue(fixture.gateway.presses.isEmpty())

        val ringing = fixture.controller.selectPurpose("delivery")

        assertEquals(CallUiPhase.RINGING, ringing.phase)
        assertEquals(listOf("front" to "delivery"), fixture.gateway.presses)
        assertEquals("call-1", ringing.call?.callId)
    }

    @Test
    fun purposeFirstSkipIsAnExplicitNoPurposePress() {
        val fixture = Fixture()
        fixture.controller.begin("front")

        val ringing = fixture.controller.skipPurpose()

        assertTrue(ringing.accepted)
        assertEquals(CallUiPhase.RINGING, ringing.phase)
        assertEquals(listOf("front" to ""), fixture.gateway.presses)
    }

    @Test
    fun ringThenPurposePressesFirstAndCancelsOnlyOnce() {
        val fixture = Fixture(CallFlowMode.RING_THEN_PURPOSE)

        val pending = fixture.controller.begin("front")

        assertEquals(CallUiPhase.PURPOSE_PENDING, pending.phase)
        assertEquals("call-1", pending.call?.callId)
        assertEquals(listOf("front" to ""), fixture.gateway.presses)

        val ringing = fixture.controller.skipPurpose()
        assertEquals(CallUiPhase.RINGING, ringing.phase)
        assertTrue(fixture.gateway.selections.isEmpty())

        fixture.controller.cancel("visitor")
        fixture.controller.cancel("visitor")
        assertEquals(listOf(Cancel("front", "call-1", "visitor")), fixture.gateway.cancellations)
    }

    @Test
    fun ringThenPurposeSelectsAgainstTheExactCall() {
        val fixture = Fixture(CallFlowMode.RING_THEN_PURPOSE)
        fixture.controller.begin("front")

        val ringing = fixture.controller.selectPurpose("courier")

        assertEquals(CallUiPhase.RINGING, ringing.phase)
        assertEquals(1, ringing.call?.stageRevision)
        assertEquals(listOf(Selection("front", "call-1", "courier")),
            fixture.gateway.selections)
    }

    @Test
    fun ttlUsesTheConfiguredDeadlineAndEmitsOneGlobalCancel() {
        val fixture = Fixture(CallFlowMode.RING_THEN_PURPOSE)
        fixture.controller.begin("front")

        assertEquals(CallUiPhase.PURPOSE_PENDING, fixture.controller.timeout(10_999).phase)
        assertTrue(fixture.gateway.cancellations.isEmpty())

        assertEquals(CallUiPhase.IDLE, fixture.controller.timeout(11_000).phase)
        fixture.controller.timeout(12_000)
        assertEquals(listOf(Cancel("front", "call-1", "timeout")),
            fixture.gateway.cancellations)
    }

    @Test
    fun establishedEndOnlyHangsUp() {
        val fixture = Fixture(CallFlowMode.RING_THEN_PURPOSE)
        fixture.controller.begin("front")
        fixture.controller.markEstablished()

        val ended = fixture.controller.endEstablished()

        assertEquals(CallUiPhase.IDLE, ended.phase)
        assertEquals(1, fixture.gateway.hangups)
        assertTrue(fixture.gateway.cancellations.isEmpty())
        assertNull(fixture.persistence.value)
    }

    @Test
    fun rejectedCancelKeepsStateAndDoesNotRetryTheGlobalMutation() {
        val fixture = Fixture(CallFlowMode.RING_THEN_PURPOSE)
        fixture.gateway.cancelAccepted = false
        fixture.controller.begin("front")

        val first = fixture.controller.cancel("visitor")
        val second = fixture.controller.cancel("visitor")

        assertFalse(first.accepted)
        assertEquals(CallUiPhase.PURPOSE_PENDING, first.phase)
        assertFalse(second.accepted)
        assertEquals("call-1", fixture.controller.current()?.callId)
        assertEquals(1, fixture.gateway.cancellations.size)
    }

    @Test
    fun lifecycleEventsRejectWrongCallsAndStaleStages() {
        val fixture = Fixture(CallFlowMode.RING_THEN_PURPOSE)
        fixture.controller.begin("front")
        fixture.controller.selectPurpose("delivery")

        assertFalse(fixture.controller.observeCancellation("other", 2))
        assertFalse(fixture.controller.observeCancellation("call-1", 0))
        assertEquals("call-1", fixture.controller.current()?.callId)
        assertTrue(fixture.controller.observeCancellation("call-1", 1))
        assertNull(fixture.controller.current())
    }

    @Test
    fun answeredAndEndedEventsUseCallAndStageFiltering() {
        val fixture = Fixture(CallFlowMode.RING_THEN_PURPOSE)
        fixture.controller.begin("front")

        assertFalse(fixture.controller.observeAnswered("other", 0, 20_000))
        assertTrue(fixture.controller.observeAnswered("call-1", 0, 20_000))
        assertEquals(CallUiPhase.ESTABLISHED, fixture.controller.current()?.phase)
        assertFalse(fixture.controller.observeEnded("call-1", -1))
        assertTrue(fixture.controller.observeEnded("call-1", 0))
        assertNull(fixture.controller.current())
    }

    @Test
    fun newerPurposeReturnsAnAnsweredRevisionToRinging() {
        val fixture = Fixture(CallFlowMode.RING_THEN_PURPOSE)
        fixture.controller.begin("front")
        assertTrue(fixture.controller.observeAnswered("call-1", 0, 20_000))
        assertEquals(CallUiPhase.ESTABLISHED, fixture.controller.current()?.phase)

        assertTrue(fixture.controller.observePurpose(
            "front", "call-1", 1, 20_000, "delivery"))
        assertEquals(CallUiPhase.RINGING, fixture.controller.current()?.phase)
        assertEquals(1, fixture.controller.current()?.stageRevision)
    }

    @Test
    fun recoveryRequiresThePersistedOriginCallAndUnexpiredTtl() {
        val persisted = OriginatedCall(
            callId = "persisted",
            door = "front",
            stageRevision = 2,
            expiresAtMs = 20_000,
            purpose = "delivery",
            phase = CallUiPhase.RINGING,
        )
        val persistence = MemoryPersistence(persisted)
        val gateway = FakeGateway()
        val controller = CallFlowController(gateway, persistence) { 10_000 }

        assertNull(controller.recoveryCandidate("wrong", "front"))
        assertNull(controller.recoveryCandidate("persisted", "side"))
        assertEquals(persisted, controller.recoveryCandidate("persisted", "front"))

        controller.reportRecovery("persisted", true)
        assertEquals(listOf("persisted" to true), gateway.recoveryReports)
        assertEquals(persisted, controller.current())

        assertNull(controller.recoveryCandidate("persisted", "front", 20_000))
        assertNull(persistence.value)
    }

    private class Fixture(mode: CallFlowMode = CallFlowMode.PURPOSE_FIRST) {
        var nowMs = 1_000L
        val gateway = FakeGateway()
        val persistence = MemoryPersistence()
        val controller = CallFlowController(gateway, persistence) { nowMs }.also {
            it.configure(
                if (mode == CallFlowMode.RING_THEN_PURPOSE)
                    "ring_then_purpose" else "purpose_first",
                10,
            )
        }
    }

    private data class Selection(val door: String, val callId: String, val purpose: String)
    private data class Cancel(val door: String, val callId: String, val reason: String)

    private class FakeGateway : CallFlowGateway {
        val presses = ArrayList<Pair<String, String>>()
        val selections = ArrayList<Selection>()
        val cancellations = ArrayList<Cancel>()
        val recoveryReports = ArrayList<Pair<String, Boolean>>()
        var hangups = 0
        var cancelAccepted = true

        override fun press(door: String, purpose: String): String {
            presses.add(door to purpose)
            return "call-${presses.size}"
        }

        override fun selectPurpose(door: String, callId: String, purpose: String): Boolean {
            selections.add(Selection(door, callId, purpose))
            return true
        }

        override fun cancel(door: String, callId: String, reason: String): Boolean {
            cancellations.add(Cancel(door, callId, reason))
            return cancelAccepted
        }

        override fun reportRecovery(callId: String, restored: Boolean) {
            recoveryReports.add(callId to restored)
        }

        override fun hangup() {
            hangups++
        }
    }

    private class MemoryPersistence(initial: OriginatedCall? = null) : OriginatedCallPersistence {
        var value = initial

        override fun load(): OriginatedCall? = value

        override fun save(call: OriginatedCall): Boolean {
            value = call
            return true
        }

        override fun clear() {
            value = null
        }
    }
}
