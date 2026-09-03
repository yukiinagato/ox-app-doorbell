package jp.ox.doorbell

import android.graphics.Bitmap

/** A bounded separable box blur for the static bitmap sampled by frosted dashboard plates. */
internal object FrostedBlur {

    fun build(source: Bitmap, radius: Int): Bitmap? {
        if (source.isRecycled || source.width <= 0 || source.height <= 0) return null
        val r = radius.coerceIn(0, 80)
        return try {
            if (r == 0) return source.copy(Bitmap.Config.ARGB_8888, false)
            val width = source.width
            val height = source.height
            val input = IntArray(width * height)
            val horizontal = IntArray(input.size)
            val output = IntArray(input.size)
            source.getPixels(input, 0, width, 0, 0, width, height)
            blurHorizontal(input, horizontal, width, height, r)
            blurVertical(horizontal, output, width, height, r)
            Bitmap.createBitmap(output, width, height, Bitmap.Config.ARGB_8888)
        } catch (_: OutOfMemoryError) {
            null
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun blurHorizontal(input: IntArray, output: IntArray, width: Int, height: Int, r: Int) {
        val span = r * 2 + 1
        for (y in 0 until height) {
            val row = y * width
            var a = 0L; var red = 0L; var green = 0L; var blue = 0L
            for (x in -r..r) {
                val pixel = input[row + x.coerceIn(0, width - 1)]
                a += pixel ushr 24
                red += pixel ushr 16 and 0xff
                green += pixel ushr 8 and 0xff
                blue += pixel and 0xff
            }
            for (x in 0 until width) {
                output[row + x] = ((a / span).toInt() shl 24) or
                    ((red / span).toInt() shl 16) or ((green / span).toInt() shl 8) or
                    (blue / span).toInt()
                val remove = input[row + (x - r).coerceIn(0, width - 1)]
                val add = input[row + (x + r + 1).coerceIn(0, width - 1)]
                a += (add ushr 24) - (remove ushr 24)
                red += (add ushr 16 and 0xff) - (remove ushr 16 and 0xff)
                green += (add ushr 8 and 0xff) - (remove ushr 8 and 0xff)
                blue += (add and 0xff) - (remove and 0xff)
            }
        }
    }

    private fun blurVertical(input: IntArray, output: IntArray, width: Int, height: Int, r: Int) {
        val span = r * 2 + 1
        for (x in 0 until width) {
            var a = 0L; var red = 0L; var green = 0L; var blue = 0L
            for (y in -r..r) {
                val pixel = input[y.coerceIn(0, height - 1) * width + x]
                a += pixel ushr 24
                red += pixel ushr 16 and 0xff
                green += pixel ushr 8 and 0xff
                blue += pixel and 0xff
            }
            for (y in 0 until height) {
                output[y * width + x] = ((a / span).toInt() shl 24) or
                    ((red / span).toInt() shl 16) or ((green / span).toInt() shl 8) or
                    (blue / span).toInt()
                val remove = input[(y - r).coerceIn(0, height - 1) * width + x]
                val add = input[(y + r + 1).coerceIn(0, height - 1) * width + x]
                a += (add ushr 24) - (remove ushr 24)
                red += (add ushr 16 and 0xff) - (remove ushr 16 and 0xff)
                green += (add ushr 8 and 0xff) - (remove ushr 8 and 0xff)
                blue += (add and 0xff) - (remove and 0xff)
            }
        }
    }
}
