package jp.ox.doorbell

import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.SystemClock
import java.io.File
import org.json.JSONObject

/**
 * Client for the optional, separately provisioned root watchdog.
 * It deliberately has no shell/su path and accepts only this fixed command set.
 */
class RootKeepaliveClient {
    data class Status(
        val installed: Boolean,
        val enabled: Boolean = false,
        val running: Boolean = false,
        val version: String = "",
        val safeMode: Boolean = false,
        val error: String = "",
    )

    fun status(): Status = exchange("STATUS")
    fun setMode(mode: String): Status {
        val command = modeCommand(mode) ?: return Status(false, error = "invalid mode")
        return exchange(command)
    }
    fun enable(): Status = exchange("ENABLE")
    fun disable(): Status = exchange("DISABLE")
    fun kick(): Status = exchange(kickCommand(SystemClock.elapsedRealtime()))
    fun pauseLease(seconds: Int): Status =
        exchange(pauseLeaseCommand(seconds))

    private fun exchange(command: String): Status {
        if (!VALID_COMMAND.matches(command)) return Status(false, error = "invalid command")
        val socketPath = File("/dev/socket/$SOCKET_NAME")
        if (!socketPath.exists()) return Status(false, error = "helper socket absent")
        val socket = LocalSocket()
        return try {
            socket.soTimeout = TIMEOUT_MS
            socket.connect(LocalSocketAddress(SOCKET_NAME, LocalSocketAddress.Namespace.RESERVED))
            socket.outputStream.write((command + "\n").toByteArray(Charsets.US_ASCII))
            socket.outputStream.flush()
            val bytes = ByteArray(MAX_REPLY)
            var size = 0
            var terminated = false
            while (size < bytes.size) {
                val n = socket.inputStream.read(bytes, size, 1)
                if (n <= 0) break
                if (bytes[size] == '\n'.code.toByte()) {
                    terminated = true
                    break
                }
                size += n
            }
            if (!terminated) Status(true, error = "unterminated helper reply")
            else parseReply(String(bytes, 0, size, Charsets.UTF_8))
        } catch (e: Exception) {
            Status(true, error = e.javaClass.simpleName)
        } finally {
            try { socket.close() } catch (_: Exception) { }
        }
    }

    companion object {
        const val SOCKET_NAME = "doorbell_keeper"
        private const val TIMEOUT_MS = 500
        private const val MAX_REPLY = 512
        private val VALID_COMMAND =
            Regex("^(STATUS|MODE (off|auto|on)|ENABLE|DISABLE|KICK [1-9][0-9]*|PAUSE_LEASE ([1-9][0-9]{0,2}|[1-2][0-9]{3}|3[0-5][0-9]{2}|3600))$")
        private val REPLY_KEYS =
            setOf("enabled", "running", "version", "safe_mode", "error")

        internal fun modeCommand(mode: String): String? =
            if (mode == "off" || mode == "auto" || mode == "on") "MODE $mode" else null

        internal fun kickCommand(elapsedRealtimeMs: Long): String =
            "KICK ${elapsedRealtimeMs.coerceAtLeast(1L)}"

        internal fun pauseLeaseCommand(seconds: Int): String =
            "PAUSE_LEASE ${seconds.coerceIn(1, 3600)}"

        internal fun parseReply(reply: String): Status {
            if (reply.toByteArray(Charsets.UTF_8).size >= MAX_REPLY)
                return Status(true, error = "invalid helper reply")
            return try {
                val json = JSONObject(reply)
                val keys = LinkedHashSet<String>()
                val iterator = json.keys()
                while (iterator.hasNext()) keys.add(iterator.next())
                if (keys != REPLY_KEYS || json.opt("enabled") !is Boolean ||
                    json.opt("running") !is Boolean || json.opt("safe_mode") !is Boolean ||
                    json.opt("version") !is String || json.opt("error") !is String ||
                    json.optString("version") != "1.0") {
                    Status(true, error = "invalid helper reply")
                } else {
                    Status(
                        installed = true,
                        enabled = json.getBoolean("enabled"),
                        running = json.getBoolean("running"),
                        version = json.getString("version"),
                        safeMode = json.getBoolean("safe_mode"),
                        error = json.getString("error"),
                    )
                }
            } catch (_: Exception) {
                Status(true, error = "invalid helper reply")
            }
        }
    }
}
