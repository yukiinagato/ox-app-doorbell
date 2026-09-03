package jp.ox.doorbell

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import java.io.InputStream

internal object BoundedBitmapDecoder {
    internal data class AspectFillPlan(
        val cropLeft: Int,
        val cropTop: Int,
        val cropRight: Int,
        val cropBottom: Int,
        val sampleSize: Int,
    ) {
        val cropWidth: Int get() = cropRight - cropLeft
        val cropHeight: Int get() = cropBottom - cropTop
    }

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

    /**
     * Decode the centred source region that an aspect-filled view actually displays.
     *
     * Sampling the whole image to fit both target dimensions destroys a portrait wallpaper before
     * it is cropped into a landscape screen: a 2200x2609 upload became 550 pixels wide and was then
     * enlarged across a 2400-pixel display. Region decoding keeps the visible crop at display
     * resolution without retaining the unused top and bottom of the photograph.
     */
    fun decodeAspectFill(bytes: ByteArray, width: Int, height: Int): Bitmap? {
        if (bytes.isEmpty() || width <= 0 || height <= 0) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val plan = aspectFillPlan(bounds.outWidth, bounds.outHeight, width, height) ?: return null
        var decoder: BitmapRegionDecoder? = null
        var source: Bitmap? = null
        var output: Bitmap? = null
        try {
            @Suppress("DEPRECATION")
            val opened = BitmapRegionDecoder.newInstance(bytes, 0, bytes.size, false)
                ?: return null
            decoder = opened
            val options = BitmapFactory.Options().apply {
                inSampleSize = plan.sampleSize
                inPreferredConfig = Bitmap.Config.RGB_565
                inDither = true
            }
            source = opened.decodeRegion(
                Rect(plan.cropLeft, plan.cropTop, plan.cropRight, plan.cropBottom), options,
            ) ?: return null
            output = Bitmap.createBitmap(width, height, Bitmap.Config.RGB_565)
            Canvas(output).drawBitmap(
                source,
                Rect(0, 0, source.width, source.height),
                Rect(0, 0, width, height),
                Paint(Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG),
            )
            return output
        } catch (_: Exception) {
            output?.recycle()
            return null
        } catch (_: OutOfMemoryError) {
            output?.recycle()
            return null
        } finally {
            source?.recycle()
            @Suppress("DEPRECATION")
            decoder?.recycle()
        }
    }

    internal fun aspectFillPlan(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
    ): AspectFillPlan? {
        if (sourceWidth <= 0 || sourceHeight <= 0 || targetWidth <= 0 || targetHeight <= 0)
            return null
        var cropWidth = sourceWidth
        var cropHeight = sourceHeight
        if (sourceWidth.toLong() * targetHeight > targetWidth.toLong() * sourceHeight) {
            cropWidth = ((sourceHeight.toLong() * targetWidth) / targetHeight)
                .coerceIn(1, sourceWidth.toLong()).toInt()
        } else {
            cropHeight = ((sourceWidth.toLong() * targetHeight) / targetWidth)
                .coerceIn(1, sourceHeight.toLong()).toInt()
        }
        val left = (sourceWidth - cropWidth) / 2
        val top = (sourceHeight - cropHeight) / 2
        var sample = 1
        while (cropWidth / (sample * 2) >= targetWidth &&
            cropHeight / (sample * 2) >= targetHeight) {
            sample *= 2
        }
        return AspectFillPlan(left, top, left + cropWidth, top + cropHeight, sample)
    }

    private const val MAX_PIXELS = 2_073_600L
}
