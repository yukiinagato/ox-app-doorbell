// Every HTTP request this shell makes to its own Core (security v3 section 8).
//
// Core publishes peer media as loopback proxy URLs, so the shell never fetches another node
// directly. Loopback media routes require X-Doorbell-Local with the token Core returns from
// db_core_local_token(); the token is attached only to loopback URLs and never leaves the device.
package jp.ox.doorbell

import java.net.HttpURLConnection
import java.net.URL

internal object LocalMedia {
    const val HEADER = "X-Doorbell-Local"

    /** Supplies the current Core's token; empty while Core is not running. Set by [App]. */
    @Volatile
    var tokenProvider: () -> String = { "" }

    fun isLoopback(url: URL): Boolean = isLoopbackHost(url.host)

    fun isLoopbackHost(host: String?): Boolean = when (host?.lowercase()) {
        "127.0.0.1", "localhost", "::1", "[::1]" -> true
        else -> false
    }

    /** Open [url], adding the loopback token when the URL addresses this device. */
    fun open(url: String): HttpURLConnection = open(URL(url))

    fun open(url: URL): HttpURLConnection {
        val connection = url.openConnection() as HttpURLConnection
        if (isLoopback(url)) {
            val token = tokenProvider()
            if (token.isNotEmpty()) connection.setRequestProperty(HEADER, token)
        }
        return connection
    }
}
