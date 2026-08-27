// MJPEG (multipart/x-mixed-replace) の自前デコーダ — 外部ライブラリ禁止の方針のため
// HttpURLConnection + 境界パース + BitmapFactory で組む。
// 子機 httpd の /stream.mjpeg はパート毎に Content-Length を必ず付ける (httpd.cpp) ので
// ヘッダの Content-Length を読んで本文をそのまま切り出す。
// 接続断は 2 秒後に自動再接続 (stop まで)。コールバックは読取スレッドから呼ばれる。
package jp.keihan.doorbell

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import java.io.BufferedInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

class MjpegStreamer(private val url: String, private val onFrame: (Bitmap) -> Unit) {

    @Volatile
    private var running = false
    private var thread: Thread? = null

    fun start() {
        if (running) return
        running = true
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
                while (running) {
                    val frame = readPart(ins) ?: break
                    val bmp = BitmapFactory.decodeByteArray(frame, 0, frame.size) ?: continue
                    if (running) onFrame(bmp)
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

    /** 1 パート読む: 境界/ヘッダ行 → Content-Length → JPEG 本文。ストリーム終端は null。 */
    private fun readPart(ins: InputStream): ByteArray? {
        var contentLength = -1
        // ヘッダ行 (--frame, Content-Type, Content-Length, 空行)。空行でヘッダ終了。
        while (true) {
            val line = readLine(ins) ?: return null
            if (line.isEmpty()) {
                if (contentLength > 0) break
                continue  // 本文前の余分な空行 (境界直後) は読み飛ばす
            }
            val p = line.split(':', limit = 2)
            if (p.size == 2 && p[0].trim().equals("Content-Length", ignoreCase = true)) {
                contentLength = p[1].trim().toIntOrNull() ?: -1
                if (contentLength <= 0 || contentLength > MAX_FRAME) return null
            }
        }
        val buf = ByteArray(contentLength)
        var off = 0
        while (off < contentLength) {
            val n = ins.read(buf, off, contentLength - off)
            if (n < 0) return null
            off += n
        }
        return buf
    }

    /** \r\n 終端の 1 行 (ASCII)。終端到達は null。 */
    private fun readLine(ins: InputStream): String? {
        val sb = StringBuilder(64)
        while (true) {
            val c = ins.read()
            if (c < 0) return null
            if (c == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(c.toChar())
            if (sb.length > 512) return null  // 異常なヘッダ行
        }
    }

    companion object {
        private const val TAG = "doorbell-mjpeg"
        private const val MAX_FRAME = 4 * 1024 * 1024  // JPEG 1 枚の上限 (安全弁)
    }
}
