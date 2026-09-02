package jp.ox.doorbell

import java.io.File
import java.io.FileOutputStream
import org.json.JSONArray
import org.json.JSONObject

internal data class ProcessRecoveryState(
    val generation: Long = 0L,
    val crashWallMs: List<Long> = emptyList(),
    val safeMode: Boolean = false,
    val restartAttempt: Int = 0,
    val lastExitReason: String = "",
    val sessionOpen: Boolean = false,
    val sessionStartedWallMs: Long = 0L,
    val artifactBuild: String = "",
) {
    val restartBackoffMs: Long get() = if (restartAttempt <= 0) 0L
        else RecoveryPolicy.restartBackoffMs(restartAttempt - 1)
}

internal object RecoveryPolicy {
    const val WINDOW_MS = 5 * 60_000L
    const val SAFE_MODE_THRESHOLD = 3
    private val backoff = longArrayOf(2_000L, 5_000L, 10_000L, 30_000L, 60_000L)

    fun restartBackoffMs(attemptIndex: Int): Long = backoff[attemptIndex.coerceIn(0, 4)]

    fun unexpectedExitStartupDelayMs(state: ProcessRecoveryState): Long =
        if (state.lastExitReason == "unexpected_process_exit") state.restartBackoffMs else 0L

    fun recent(crashes: List<Long>, nowWallMs: Long): List<Long> = crashes.filter {
        it in (nowWallMs - WINDOW_MS)..(nowWallMs + MAX_CLOCK_SKEW_MS)
    }.takeLast(MAX_CRASH_RECORDS)

    private const val MAX_CLOCK_SKEW_MS = 60_000L
    private const val MAX_CRASH_RECORDS = 16
}

/** Atomic crash window and session marker used to detect Java, native, LMK, and OOM exits. */
internal class CrashLoopStore(private val file: File) {
    private var state = load()

    @Synchronized
    fun beginSession(nowWallMs: Long, artifactBuild: String = ""): ProcessRecoveryState {
        val buildChanged = artifactBuild.isNotEmpty() && state.artifactBuild.isNotEmpty() &&
            artifactBuild != state.artifactBuild
        var crashes = if (buildChanged) emptyList()
            else RecoveryPolicy.recent(state.crashWallMs, nowWallMs)
        var reason = if (buildChanged) "package_replaced" else state.lastExitReason
        var attempt = if (buildChanged) 0 else state.restartAttempt
        if (state.sessionOpen && !buildChanged) {
            crashes = (crashes + nowWallMs).takeLast(16)
            reason = "unexpected_process_exit"
            attempt++
        }
        if (reason.isEmpty()) reason = "first_launch"
        state = ProcessRecoveryState(
            generation = nextGeneration(state.generation),
            crashWallMs = crashes,
            safeMode = !buildChanged &&
                (state.safeMode || crashes.size >= RecoveryPolicy.SAFE_MODE_THRESHOLD),
            restartAttempt = attempt,
            lastExitReason = runtimeToken(reason),
            sessionOpen = true,
            sessionStartedWallMs = nowWallMs,
            artifactBuild = artifactBuild,
        )
        persist()
        return state
    }

    @Synchronized
    fun recordCrash(reason: String, nowWallMs: Long): ProcessRecoveryState {
        if (!state.sessionOpen) return state
        val crashes = (RecoveryPolicy.recent(state.crashWallMs, nowWallMs) + nowWallMs).takeLast(16)
        state = state.copy(
            crashWallMs = crashes,
            safeMode = state.safeMode || crashes.size >= RecoveryPolicy.SAFE_MODE_THRESHOLD,
            restartAttempt = state.restartAttempt + 1,
            lastExitReason = runtimeToken(reason),
            sessionOpen = false,
        )
        persist()
        return state
    }

    @Synchronized
    fun markHealthy(nowWallMs: Long): ProcessRecoveryState {
        if (!state.sessionOpen || nowWallMs - state.sessionStartedWallMs < RecoveryPolicy.WINDOW_MS)
            return state
        state = state.copy(
            crashWallMs = emptyList(),
            safeMode = false,
            restartAttempt = 0,
            lastExitReason = "healthy",
        )
        persist()
        return state
    }

    @Synchronized
    fun endSession(reason: String): ProcessRecoveryState {
        state = state.copy(sessionOpen = false, lastExitReason = runtimeToken(reason))
        persist()
        return state
    }

    @Synchronized
    fun snapshot(): ProcessRecoveryState = state.copy(crashWallMs = state.crashWallMs.toList())

    private fun persist() {
        val parent = file.parentFile ?: return
        if (!parent.exists() && !parent.mkdirs()) return
        val root = JSONObject()
            .put("schema_version", 1)
            .put("generation", state.generation)
            .put("crash_wall_ms", JSONArray(state.crashWallMs))
            .put("safe_mode", state.safeMode)
            .put("restart_attempt", state.restartAttempt)
            .put("last_exit_reason", state.lastExitReason)
            .put("session_open", state.sessionOpen)
            .put("session_started_wall_ms", state.sessionStartedWallMs)
            .put("artifact_build", state.artifactBuild)
        val tmp = File(parent, file.name + ".tmp")
        try {
            FileOutputStream(tmp).use { out ->
                out.write(root.toString().toByteArray(Charsets.UTF_8))
                out.flush()
                out.fd.sync()
            }
            if (!tmp.renameTo(file)) tmp.delete()
        } catch (_: Exception) {
            tmp.delete()
        }
    }

    private fun load(): ProcessRecoveryState {
        if (!file.isFile || file.length() !in 1..MAX_BYTES) return ProcessRecoveryState()
        return try {
            val root = JSONObject(file.readText(Charsets.UTF_8))
            if (root.optInt("schema_version") != 1) return ProcessRecoveryState()
            val crashes = ArrayList<Long>()
            root.optJSONArray("crash_wall_ms")?.let { array ->
                for (index in 0 until array.length()) {
                    array.optLong(index).takeIf { it > 0L }?.let(crashes::add)
                }
            }
            ProcessRecoveryState(
                generation = root.optLong("generation").coerceIn(0L, MAX_GENERATION),
                crashWallMs = crashes.takeLast(16),
                safeMode = root.optBoolean("safe_mode"),
                restartAttempt = root.optInt("restart_attempt").coerceIn(0, 1_000),
                lastExitReason = runtimeToken(root.optString("last_exit_reason")),
                sessionOpen = root.optBoolean("session_open"),
                sessionStartedWallMs = root.optLong("session_started_wall_ms").coerceAtLeast(0L),
                artifactBuild = root.optString("artifact_build").take(256),
            )
        } catch (_: Exception) {
            ProcessRecoveryState()
        }
    }

    companion object {
        private const val MAX_BYTES = 32 * 1024L
        private const val MAX_GENERATION = 9_000_000_000_000_000L

        private fun nextGeneration(previous: Long): Long =
            if (previous in 0 until MAX_GENERATION) previous + 1L else 1L

        internal fun runtimeToken(value: String): String {
            if (value.isEmpty()) return "unknown"
            val bounded = StringBuilder()
            for (character in value) {
                if (bounded.length >= 128) break
                val valid = character.code < 128 && (character.isLetterOrDigit() ||
                    character == '_' || character == '-' || character == '.' || character == ':')
                bounded.append(if (valid) character else '_')
            }
            return bounded.toString().ifEmpty { "unknown" }
        }
    }
}
