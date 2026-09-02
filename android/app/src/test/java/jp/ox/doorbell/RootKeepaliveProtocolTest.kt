package jp.ox.doorbell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RootKeepaliveProtocolTest {
    @Test
    fun usesTheFixedAndroidProfileCommandsAndSocket() {
        assertEquals("doorbell_keeper", RootKeepaliveClient.SOCKET_NAME)
        assertEquals("MODE off", RootKeepaliveClient.modeCommand("off"))
        assertEquals("MODE auto", RootKeepaliveClient.modeCommand("auto"))
        assertEquals("MODE on", RootKeepaliveClient.modeCommand("on"))
        assertNull(RootKeepaliveClient.modeCommand("shell"))
        assertEquals("KICK 1", RootKeepaliveClient.kickCommand(0))
        assertEquals("KICK 42", RootKeepaliveClient.kickCommand(42))
        assertEquals("PAUSE_LEASE 1", RootKeepaliveClient.pauseLeaseCommand(0))
        assertEquals("PAUSE_LEASE 3600", RootKeepaliveClient.pauseLeaseCommand(10_000))
    }

    @Test
    fun parsesOnlyTheFrozenVersionOneReplyShape() {
        val status = RootKeepaliveClient.parseReply(
            """{"enabled":true,"running":true,"version":"1.0","safe_mode":true,"error":""}""",
        )

        assertTrue(status.installed)
        assertTrue(status.enabled)
        assertTrue(status.running)
        assertTrue(status.safeMode)
        assertEquals("1.0", status.version)
        assertEquals("", status.error)
    }

    @Test
    fun rejectsMissingExtraOrWrongTypedReplyFields() {
        val invalid = listOf(
            """{"enabled":true,"running":true,"version":"1.0","error":""}""",
            """{"enabled":true,"running":true,"version":"2.0","safe_mode":false,"error":""}""",
            """{"enabled":1,"running":true,"version":"1.0","safe_mode":false,"error":""}""",
            """{"enabled":true,"running":true,"version":"1.0","safe_mode":false,"error":"","extra":1}""",
        )

        for (reply in invalid) {
            val status = RootKeepaliveClient.parseReply(reply)
            assertTrue(status.installed)
            assertFalse(status.enabled)
            assertEquals("invalid helper reply", status.error)
        }
    }
}
