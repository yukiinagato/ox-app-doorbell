// Shared framework-view building blocks for the pairing screens. Framework widgets only:
// no androidx, no material, no third-party QR library.
package jp.keihan.doorbell

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.drawable.GradientDrawable
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

internal object PairingUi {

    val BG = Color.parseColor("#0E1621")
    val CARD = Color.parseColor("#16202D")
    val TEXT = Color.WHITE
    val DIM = Color.parseColor("#9FB0C0")
    val FAINT = Color.parseColor("#63758A")
    val ACCENT = Color.parseColor("#3FA9F5")
    val OK = Color.parseColor("#4CC38A")
    val ERR = Color.parseColor("#E05B4C")
    val WARN = Color.parseColor("#E0A23C")

    fun dp(context: Context, value: Int): Int =
        (value * context.resources.displayMetrics.density).toInt()

    fun matchWrap(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
    )

    fun title(context: Context, value: String): TextView = TextView(context).apply {
        text = value
        setTextColor(TEXT)
        textSize = 24f
        setTypeface(typeface, Typeface.BOLD)
    }

    fun heading(context: Context, value: String): TextView = TextView(context).apply {
        text = value
        setTextColor(TEXT)
        textSize = 17f
        setTypeface(typeface, Typeface.BOLD)
    }

    fun body(context: Context, value: String = ""): TextView = TextView(context).apply {
        text = value
        setTextColor(DIM)
        textSize = 15f
    }

    fun small(context: Context, value: String = ""): TextView = TextView(context).apply {
        text = value
        setTextColor(FAINT)
        textSize = 13f
    }

    fun mono(context: Context, value: String = "", size: Float = 34f): TextView =
        TextView(context).apply {
            text = value
            setTextColor(TEXT)
            textSize = size
            typeface = Typeface.MONOSPACE
            setTypeface(typeface, Typeface.BOLD)
        }

    /** A rounded panel used for every grouped block on the pairing screens. */
    fun card(context: Context): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = GradientDrawable().apply {
            setColor(CARD)
            cornerRadius = dp(context, 12).toFloat()
        }
        val pad = dp(context, 16)
        setPadding(pad, pad, pad, pad)
    }

    fun button(
        context: Context,
        value: String,
        primary: Boolean = false,
        onClick: () -> Unit,
    ): Button = Button(context).apply {
        text = value
        isAllCaps = false
        textSize = 17f
        minHeight = dp(context, 48)
        isFocusable = true
        setTextColor(if (primary) Color.WHITE else TEXT)
        background = GradientDrawable().apply {
            setColor(if (primary) ACCENT else Color.parseColor("#243244"))
            cornerRadius = dp(context, 10).toFloat()
        }
        setOnClickListener { onClick() }
    }

    /** Compact row action used by the nearby list. */
    fun chip(
        context: Context,
        value: String,
        primary: Boolean = true,
        onClick: () -> Unit,
    ): Button =
        Button(context).apply {
            text = value
            isAllCaps = false
            textSize = 15f
            minWidth = dp(context, 88)
            minHeight = dp(context, 48)
            isFocusable = true
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply {
                setColor(if (primary) ACCENT else Color.parseColor("#243244"))
                cornerRadius = dp(context, 8).toFloat()
            }
            setOnClickListener { onClick() }
        }

    fun spacer(context: Context, height: Int): View = View(context).apply {
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            dp(context, height),
        )
    }

    /**
     * A focusable 3x4 numeric keypad. Installations without an IME or a physical keyboard use
     * this instead of a soft keyboard, exactly as the admin password dialog does.
     */
    fun keypad(context: Context, onKey: (String) -> Unit): LinearLayout {
        val box = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        val rows = listOf(
            listOf("1", "2", "3"), listOf("4", "5", "6"),
            listOf("7", "8", "9"), listOf(KEY_BACK, "0", KEY_OK),
        )
        for (row in rows) {
            val line = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
            for (key in row) {
                val b = Button(context).apply {
                    text = when (key) {
                        KEY_BACK -> "⌫"
                        KEY_OK -> "OK"
                        else -> key
                    }
                    textSize = 22f
                    isAllCaps = false
                    isFocusable = true
                    setTextColor(TEXT)
                    background = GradientDrawable().apply {
                        setColor(Color.parseColor("#243244"))
                        cornerRadius = dp(context, 8).toFloat()
                    }
                    setOnClickListener { onKey(key) }
                }
                val lp = LinearLayout.LayoutParams(0, dp(context, 56), 1f)
                lp.setMargins(dp(context, 3), dp(context, 3), dp(context, 3), dp(context, 3))
                line.addView(b, lp)
            }
            box.addView(line, matchWrap())
        }
        return box
    }

    const val KEY_BACK = "back"
    const val KEY_OK = "ok"

    /** Render a QR matrix from Core into a bitmap; null when Core cannot encode the payload. */
    fun qrBitmap(core: DoorbellCore, text: String, targetPx: Int): Bitmap? {
        val enc = core.qrEncode(text) ?: return null
        val size = enc[0]
        if (size <= 0 || enc.size < 1 + size * size) return null
        val quiet = 3
        val total = size + quiet * 2
        val scale = maxOf(1, targetPx / total)
        val dim = total * scale
        val bmp = try {
            Bitmap.createBitmap(dim, dim, Bitmap.Config.ARGB_8888)
        } catch (_: OutOfMemoryError) {
            return null
        }
        val canvas = Canvas(bmp)
        canvas.drawColor(Color.WHITE)
        val paint = Paint().apply { color = Color.BLACK }
        for (y in 0 until size) for (x in 0 until size) {
            if (enc[1 + y * size + x] != 0) {
                val l = ((x + quiet) * scale).toFloat()
                val t = ((y + quiet) * scale).toFloat()
                canvas.drawRect(l, t, l + scale, t + scale, paint)
            }
        }
        return bmp
    }

    /** Placeholder shown until Core publishes pair_qr, so the QR box is never blank white. */
    fun qrPlaceholder(context: Context): TextView = TextView(context).apply {
        gravity = Gravity.CENTER
        setTextColor(FAINT)
        textSize = 14f
        background = GradientDrawable().apply {
            setColor(Color.parseColor("#1B2634"))
            cornerRadius = dp(context, 8).toFloat()
            setStroke(dp(context, 1), FAINT)
        }
    }
}
