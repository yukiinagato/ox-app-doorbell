// Native settings write through exactly the same configuration keys and the same validation the
// web admin uses (spec §3).
//
// Core publishes no configuration-write entry point on its C ABI, so the shell talks to this
// node's own administration API over loopback: POST /api/login with the 管理パスワード establishes
// the session, and POST /api/config and /api/config/batch then apply the same keys the web admin
// writes, through the same configWriteValidEffective checks. Nothing here ever leaves the device.
package jp.ox.doorbell

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject

internal data class ConfigWriteResult(
    val ok: Boolean,
    /** Server-supplied reason, already a documented key or an empty string. */
    val error: String = "",
    val status: Int = 0,
    /**
     * Advisory notices that accompany a successful write, such as the WCAG contrast warning a
     * colour below the ratio earns. The value is still saved; these are shown next to the field.
     */
    val warnings: org.json.JSONArray? = null,
) {
    /** The advisory to show, or null when the write raised none. */
    val warning: WriteWarning? get() = WriteWarnings.first(warnings)

    val unauthorized: Boolean get() = status == 401 || status == 403
    val unsupported: Boolean get() = error == ConfigWriters.ERR_UNSUPPORTED
}

/**
 * One authenticated administration session against this node. Instances are created after the
 * password prompt succeeds and are held only for as long as the settings screen is open.
 */
internal class AdminSession private constructor(
    private val port: Int,
    private val cookie: String,
) : ConfigWriter {

    /** Write one configuration key. [valueJson] is a JSON document, not a bare display string. */
    override fun setKey(key: String, valueJson: String): ConfigWriteResult {
        val body = JSONObject().put("key", key).put("value", valueJson)
        return post("/api/config", body.toString())
    }

    /** Apply several keys atomically, exactly as the web admin's save buttons do. */
    override fun setBatch(values: List<Pair<String, String>>): ConfigWriteResult {
        if (values.isEmpty()) return ConfigWriteResult(true)
        return post("/api/config/batch", ConfigOps.build(values))
    }

    override fun deleteKey(key: String): ConfigWriteResult =
        post("/api/config/delete", JSONObject().put("key", key).toString())

    private fun post(path: String, body: String): ConfigWriteResult {
        var connection: HttpURLConnection? = null
        return try {
            connection = connect(port, path)
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Cookie", cookie)
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            val payload = readBody(
                if (status in 200..299) connection.inputStream else connection.errorStream,
            )
            val document = try { JSONObject(payload) } catch (_: Exception) { null }
            val ok = status in 200..299 && document?.optBoolean("ok", false) != false
            ConfigWriteResult(ok, document?.optString("err").orEmpty(), status,
                              document?.optJSONArray("warnings"))
        } catch (e: Exception) {
            ConfigWriteResult(false, e.javaClass.simpleName, 0)
        } finally {
            try { connection?.disconnect() } catch (_: Exception) { }
        }
    }

    companion object {
        /** Failure kinds a caller distinguishes; anything else is reported as a save failure. */
        const val ERR_PASSWORD = "password"
        const val ERR_UNREACHABLE = "unreachable"

        /**
         * Authenticate with the 管理パスワード. Runs blocking I/O and must be called off the main
         * thread. Returns null with [ERR_PASSWORD] for a wrong password.
         */
        fun open(port: Int, password: String): Pair<AdminSession?, String> {
            var connection: HttpURLConnection? = null
            return try {
                connection = connect(port, "/api/login")
                connection.requestMethod = "POST"
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                val body = JSONObject().put("password", password).toString()
                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                val status = connection.responseCode
                if (status == 401 || status == 403) return null to ERR_PASSWORD
                if (status !in 200..299) return null to ERR_UNREACHABLE
                val cookie = sessionCookie(connection) ?: return null to ERR_UNREACHABLE
                AdminSession(port, cookie) to ""
            } catch (_: Exception) {
                null to ERR_UNREACHABLE
            } finally {
                try { connection?.disconnect() } catch (_: Exception) { }
            }
        }

        /** Extract the dbsess cookie without carrying its attributes into later requests. */
        internal fun sessionCookie(connection: HttpURLConnection): String? {
            var index = 0
            while (true) {
                val key = connection.getHeaderFieldKey(index)
                val value = connection.getHeaderField(index) ?: break
                if (key != null && key.equals("Set-Cookie", ignoreCase = true)) {
                    val pair = value.substringBefore(';').trim()
                    if (pair.startsWith("dbsess=") && pair.length > 7) return pair
                }
                index++
                if (index > 64) break
            }
            return null
        }

        private fun connect(port: Int, path: String): HttpURLConnection {
            val connection = URL("http://127.0.0.1:$port$path").openConnection()
                as HttpURLConnection
            connection.connectTimeout = 4000
            connection.readTimeout = 8000
            connection.useCaches = false
            connection.instanceFollowRedirects = false
            return connection
        }

        private fun readBody(stream: InputStream?): String {
            if (stream == null) return ""
            return try {
                val out = ByteArrayOutputStream()
                val buffer = ByteArray(8 * 1024)
                var total = 0
                while (total < MAX_BODY) {
                    val size = stream.read(buffer)
                    if (size < 0) break
                    out.write(buffer, 0, size)
                    total += size
                }
                out.toString("UTF-8")
            } catch (_: Exception) {
                ""
            } finally {
                try { stream.close() } catch (_: Exception) { }
            }
        }

        private const val MAX_BODY = 256 * 1024
    }
}
