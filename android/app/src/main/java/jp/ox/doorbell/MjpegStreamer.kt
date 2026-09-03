// Bounded multipart MJPEG reader. Core's server supplies Content-Length on each part, allowing
// exact frame extraction without a third-party parser. Callbacks run on the reader thread.
package jp.ox.doorbell

import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Log
import java.io.BufferedInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

class MjpegStreamer(private val url: String, private val onFrame: (Bitmap, Int) -> Unit) {

    private data class Frame(val jpeg: ByteArray, val rotation: Int)

    @Volatile
    private var running = false
    private var thread: Thread? = null
    private var startupMs = 0L
    private var tracedHeaders = false
    private var tracedPart = false
    private var tracedDecode = false

    fun start() {
        if (running) return
        running = true
        startupMs = SystemClock.elapsedRealtime()
        tracedHeaders = false
        tracedPart = false
        tracedDecode = false
        trace("request_start")
        thread = Thread({ loop() }, "mjpeg-$url").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        running = false
        thread?.interrupt()
        thread = null
    }

    private fun loop() {
        while (running) {
            var conn: HttpURLConnection? = null
            try {
                conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 4000
                conn.readTimeout = 10000
                val ins = BufferedInputStream(conn.inputStream, 64 * 1024)
                if (!tracedHeaders) {
                    tracedHeaders = true
                    trace("http_response_headers")
                }
                while (running) {
                    val frame = readPart(ins) ?: break
                    if (!tracedPart) {
                        tracedPart = true
                        trace("first_complete_multipart")
                    }
                    val bmp = BoundedBitmapDecoder.decode(frame.jpeg, MAX_WIDTH, MAX_HEIGHT) ?: continue
                    if (!tracedDecode) {
                        tracedDecode = true
                        trace("first_jpeg_decoded")
                    }
                    if (running) onFrame(bmp, frame.rotation)
                }
            } catch (e: Exception) {
                if (running) Log.w(TAG, "stream error: $e")
            } finally {
                try { conn?.disconnect() } catch (_: Exception) { }
            }
            if (!running) break
            try { Thread.sleep(2000) } catch (_: InterruptedException) { }
        }
    }

    private fun trace(stage: String) {
        Log.i(TAG, "startup $stage +${SystemClock.elapsedRealtime() - startupMs}ms")
    }

    /** Read one bounded part; return null at the stream boundary. */
    private fun readPart(ins: InputStream): Frame? {
        var contentLength = -1
        var rotation = 0
        // The blank line after the multipart headers begins the frame body.
        while (true) {
            val line = readLine(ins) ?: return null
            if (line.isEmpty()) {
                if (contentLength > 0) break
                continue
            }
            val p = line.split(':', limit = 2)
            if (p.size == 2 && p[0].trim().equals("Content-Length", ignoreCase = true)) {
                contentLength = p[1].trim().toIntOrNull() ?: -1
                if (contentLength <= 0 || contentLength > MAX_FRAME) return null
            } else if (p.size == 2 &&
                p[0].trim().equals("X-Doorbell-Video-Rotation", ignoreCase = true)) {
                rotation = p[1].trim().toIntOrNull() ?: 0
            }
        }
        val buf = ByteArray(contentLength)
        var off = 0
        while (off < contentLength) {
            val n = ins.read(buf, off, contentLength - off)
            if (n < 0) return null
            off += n
        }
        return Frame(buf, ((rotation % 360) + 360) % 360)
    }

    /** Read one bounded CRLF-terminated ASCII line. */
    private fun readLine(ins: InputStream): String? {
        val sb = StringBuilder(64)
        while (true) {
            val c = ins.read()
            if (c < 0) return null
            if (c == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(c.toChar())
            if (sb.length > 512) return null
        }
    }

    companion object {
        private const val TAG = "doorbell-mjpeg"
        private const val MAX_FRAME = 4 * 1024 * 1024
        private const val MAX_WIDTH = 1280
        private const val MAX_HEIGHT = 720
    }
}
