package jp.ox.doorbell

import android.os.Build
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.Socket
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import org.json.JSONObject

/** Synchronous HTTPS transport used only from a core worker thread. */
internal object AndroidHttpsClient {
    fun request(method: String, url: String, headersJson: String, body: ByteArray): ByteArray? {
        if (body.size > MAX_REQUEST_BYTES || headersJson.length > MAX_HEADERS_CHARS) return null
        val verb = method.uppercase()
        if (verb !in ALLOWED_METHODS) return null
        var connection: HttpsURLConnection? = null
        return try {
            val target = URL(url)
            if (!target.protocol.equals("https", ignoreCase = true)) return null
            connection = target.openConnection() as? HttpsURLConnection ?: return null
            connection.instanceFollowRedirects = false
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.requestMethod = verb
            connection.useCaches = false
            connection.setRequestProperty("Accept-Encoding", "identity")
            if (Build.VERSION.SDK_INT <= 19) {
                // TLS 1.2 exists on API 16-19 but is not consistently enabled by OEM defaults.
                connection.sslSocketFactory = Tls12SocketFactory.create()
            }
            val headers = try { JSONObject(headersJson.ifBlank { "{}" }) }
                catch (_: Exception) { return null }
            val names = headers.keys()
            while (names.hasNext()) {
                val name = names.next()
                if (name.equals("Host", true) || name.equals("Content-Length", true) ||
                    name.equals("Connection", true)) continue
                val value = headers.opt(name)
                if (value is String && value.length <= MAX_HEADER_VALUE_CHARS)
                    connection.setRequestProperty(name, value)
            }
            if (body.isNotEmpty()) {
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            val stream = if (status >= HttpURLConnection.HTTP_BAD_REQUEST)
                connection.errorStream else connection.inputStream
            val response = if (stream == null) ByteArray(0) else stream.use(::readBounded)
                ?: return null
            ByteBuffer.allocate(4 + response.size).order(ByteOrder.BIG_ENDIAN)
                .putInt(status).put(response).array()
        } catch (_: Exception) {
            null
        } finally {
            try { connection?.disconnect() } catch (_: Exception) { }
        }
    }

    private fun readBounded(input: java.io.InputStream): ByteArray? {
        val output = ByteArrayOutputStream()
        val chunk = ByteArray(8 * 1024)
        while (true) {
            val count = input.read(chunk)
            if (count < 0) break
            if (count == 0) continue
            if (output.size() + count > MAX_RESPONSE_BYTES) return null
            output.write(chunk, 0, count)
        }
        return output.toByteArray()
    }

    /** Wrap the platform trust manager and hostname verifier; change only enabled protocols. */
    private class Tls12SocketFactory private constructor(
        private val delegate: SSLSocketFactory,
    ) : SSLSocketFactory() {
        override fun getDefaultCipherSuites(): Array<String> = delegate.defaultCipherSuites
        override fun getSupportedCipherSuites(): Array<String> = delegate.supportedCipherSuites

        override fun createSocket(socket: Socket, host: String, port: Int, autoClose: Boolean): Socket =
            enable(delegate.createSocket(socket, host, port, autoClose))

        override fun createSocket(host: String, port: Int): Socket =
            enable(delegate.createSocket(host, port))

        override fun createSocket(host: String, port: Int, local: InetAddress, localPort: Int): Socket =
            enable(delegate.createSocket(host, port, local, localPort))

        override fun createSocket(host: InetAddress, port: Int): Socket =
            enable(delegate.createSocket(host, port))

        override fun createSocket(
            address: InetAddress,
            port: Int,
            local: InetAddress,
            localPort: Int,
        ): Socket = enable(delegate.createSocket(address, port, local, localPort))

        private fun enable(socket: Socket): Socket {
            if (socket is SSLSocket && "TLSv1.2" in socket.supportedProtocols)
                socket.enabledProtocols = arrayOf("TLSv1.2")
            return socket
        }

        companion object {
            fun create(): SSLSocketFactory {
                val context = SSLContext.getInstance("TLSv1.2")
                context.init(null, null, null)
                return Tls12SocketFactory(context.socketFactory)
            }
        }
    }

    private val ALLOWED_METHODS = setOf("GET", "POST", "PUT", "DELETE", "HEAD")
    private const val CONNECT_TIMEOUT_MS = 10_000
    private const val READ_TIMEOUT_MS = 45_000
    private const val MAX_REQUEST_BYTES = 16 * 1024 * 1024
    private const val MAX_RESPONSE_BYTES = 8 * 1024 * 1024
    private const val MAX_HEADERS_CHARS = 64 * 1024
    private const val MAX_HEADER_VALUE_CHARS = 16 * 1024
}
