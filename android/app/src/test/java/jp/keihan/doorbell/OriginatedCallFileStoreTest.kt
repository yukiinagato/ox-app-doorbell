package jp.keihan.doorbell

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OriginatedCallFileStoreTest {
    @Test
    fun roundTripsAndRejectsCorruptState() {
        val directory = temporaryDirectory()
        try {
            val file = File(directory, "call.bin")
            val store = OriginatedCallFileStore(file)
            val expected = OriginatedCall(
                callId = "call-7",
                door = "front",
                stageRevision = 3,
                expiresAtMs = 123_456,
                purpose = "delivery",
                phase = CallUiPhase.RINGING,
            )

            assertTrue(store.save(expected))
            assertEquals(expected, store.load())

            file.writeBytes(byteArrayOf(1, 2, 3))
            assertNull(store.load())

            store.clear()
            assertNull(store.load())
        } finally {
            directory.deleteRecursively()
        }
    }

    private fun temporaryDirectory(): File {
        val marker = File.createTempFile("doorbell-call-store-", ".tmp")
        assertTrue(marker.delete())
        assertTrue(marker.mkdir())
        return marker
    }
}
