package jp.ox.doorbell

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.InputStream

internal object BoundedBitmapDecoder {
    fun readLimited(input: InputStream, maxBytes: Int): ByteArray? {
        if (maxBytes <= 0) return null
        val storage = ByteArray(maxBytes + 1)
        var size = 0
        while (size < storage.size) {
            val n = input.read(storage, size, storage.size - size)
            if (n < 0) break
            if (n == 0) continue
            size += n
        }
        return if (size == 0 || size > maxBytes) null else storage.copyOf(size)
    }

    fun decode(bytes: ByteArray, maxWidth: Int, maxHeight: Int): Bitmap? {
        if (bytes.isEmpty() || maxWidth <= 0 || maxHeight <= 0) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / sample > maxWidth || bounds.outHeight / sample > maxHeight ||
            (bounds.outWidth.toLong() / sample) * (bounds.outHeight.toLong() / sample) > MAX_PIXELS) {
            if (sample >= 16) return null
            sample *= 2
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.RGB_565
            inDither = true
        }
        return try { BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) }
            catch (_: OutOfMemoryError) { null }
    }

    private const val MAX_PIXELS = 2_073_600L
}
