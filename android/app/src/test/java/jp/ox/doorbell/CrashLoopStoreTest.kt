package jp.ox.doorbell

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CrashLoopStoreTest {
    @Test
    fun threeCrashesWithinFiveMinutesPersistSafeMode() {
        val root = Files.createTempDirectory("doorbell-crash-").toFile()
        try {
            val file = File(root, "recovery.json")
            var store = CrashLoopStore(file)
            store.beginSession(1_000_000L)
            store.recordCrash("first", 1_010_000L)

            store = CrashLoopStore(file)
            store.beginSession(1_020_000L)
            store.recordCrash("second", 1_030_000L)

            store = CrashLoopStore(file)
            store.beginSession(1_040_000L)
            val state = store.recordCrash("third", 1_050_000L)
            assertTrue(state.safeMode)
            assertEquals(3, state.crashWallMs.size)
            assertEquals(10_000L, state.restartBackoffMs)

            val restored = CrashLoopStore(file).beginSession(1_060_000L)
            assertTrue(restored.safeMode)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun openSessionDetectsNativeOrLmkStyleExit() {
        val root = Files.createTempDirectory("doorbell-unclean-").toFile()
        try {
            val file = File(root, "recovery.json")
            val first = CrashLoopStore(file).beginSession(2_000_000L)
            val next = CrashLoopStore(file).beginSession(2_010_000L)
            assertEquals(1L, first.generation)
            assertEquals(2L, next.generation)
            assertEquals(1, next.crashWallMs.size)
            assertEquals("unexpected_process_exit", next.lastExitReason)
            assertEquals(2_000L, next.restartBackoffMs)
            assertEquals(2_000L, RecoveryPolicy.unexpectedExitStartupDelayMs(next))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun packageReplacementDoesNotCountAsCrash() {
        val root = Files.createTempDirectory("doorbell-upgrade-").toFile()
        try {
            val file = File(root, "recovery.json")
            CrashLoopStore(file).beginSession(2_000_000L, "app:1")
            val next = CrashLoopStore(file).beginSession(2_010_000L, "app:2")
            assertTrue(next.crashWallMs.isEmpty())
            assertFalse(next.safeMode)
            assertEquals("package_replaced", next.lastExitReason)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun stableFiveMinuteSessionClearsCrashLoop() {
        val root = Files.createTempDirectory("doorbell-healthy-").toFile()
        try {
            val file = File(root, "recovery.json")
            val store = CrashLoopStore(file)
            store.beginSession(3_000_000L)
            store.recordCrash("one", 3_010_000L)
            store.beginSession(3_020_000L)
            store.recordCrash("two", 3_030_000L)
            store.beginSession(3_040_000L)
            store.recordCrash("three", 3_050_000L)
            store.beginSession(3_060_000L)
            val healthy = store.markHealthy(3_060_000L + RecoveryPolicy.WINDOW_MS)
            assertFalse(healthy.safeMode)
            assertTrue(healthy.crashWallMs.isEmpty())
            assertEquals(0, healthy.restartAttempt)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun oneProcessCanContributeOnlyOneCrashRecord() {
        val root = Files.createTempDirectory("doorbell-one-crash-").toFile()
        try {
            val store = CrashLoopStore(File(root, "recovery.json"))
            store.beginSession(4_000_000L)
            val first = store.recordCrash("first fatal thread", 4_010_000L)
            val duplicate = store.recordCrash("second fatal thread", 4_010_001L)
            assertEquals("first_fatal_thread", first.lastExitReason)
            assertEquals(1, duplicate.crashWallMs.size)
            assertEquals(1, duplicate.restartAttempt)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun recoveryBackoffIsBoundedAndExact() {
        assertEquals(
            listOf(2_000L, 5_000L, 10_000L, 30_000L, 60_000L, 60_000L),
            (0..5).map(RecoveryPolicy::restartBackoffMs),
        )
        assertEquals(0L, ProcessRecoveryState().restartBackoffMs)
        assertEquals(0L, RecoveryPolicy.unexpectedExitStartupDelayMs(
            ProcessRecoveryState(restartAttempt = 3, lastExitReason = "OutOfMemoryError"),
        ))
    }

    @Test
    fun generationAndBoundedExitReasonSurviveReload() {
        val root = Files.createTempDirectory("doorbell-generation-").toFile()
        try {
            val file = File(root, "recovery.json")
            val store = CrashLoopStore(file)
            store.beginSession(5_000_000L)
            store.endSession("clean exit / private path " + "x".repeat(200))
            val next = CrashLoopStore(file).beginSession(5_010_000L)
            assertEquals(2L, next.generation)
            assertTrue(next.lastExitReason.length <= 128)
            assertTrue(next.lastExitReason.matches(Regex("^[A-Za-z0-9_.:-]+$")))
        } finally {
            root.deleteRecursively()
        }
    }
}
