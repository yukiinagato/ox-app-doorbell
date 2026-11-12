// Shared building blocks for the pairing, add-device, scanner and device-information screens.
// Controls come from the flavor's PlatformUi; colours are the platform's own, read when a screen
// binds. No third-party QR library: Core encodes and decodes.
package jp.ox.doorbell

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

    private var tokens: Palette = Palette.DARK

    /** Take the colours of the screen being built; call before building any view. */
    fun bind(context: Context) {
        tokens = PlatformUi.tokens(context)
    }

    val BG: Int get() = ShellUi.opaque(tokens.ground)
    val TEXT: Int get() = ShellUi.opaque(tokens.ink)
    val DIM: Int get() = ShellUi.opaque(tokens.muted)
    val FAINT: Int get() = ShellUi.opaque(tokens.muted)
    val ACCENT: Int get() = ShellUi.opaque(ShellUi.accentInk(tokens))
    val OK: Int get() = ShellUi.opaque(tokens.positive)
    val ERR: Int get() = ShellUi.opaque(tokens.danger)
    val WARN: Int get() = ShellUi.opaque(tokens.warning)

    fun dp(context: Context, value: Int): Int =
        (value * context.resources.displayMetrics.density).toInt()

    fun matchWrap(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
    )

    fun title(context: Context, value: String): TextView =
        ShellUi.label(context, value, TextRole.HEADLINE)

    fun heading(context: Context, value: String): TextView =
        ShellUi.label(context, value, TextRole.SUBTITLE).apply {
            setTypeface(typeface, Typeface.BOLD)
        }

    fun body(context: Context, value: String = ""): TextView =
        ShellUi.label(context, value, TextRole.BODY, tokens.muted)

    fun small(context: Context, value: String = ""): TextView =
        ShellUi.label(context, value, TextRole.SUPPORTING)

    fun mono(context: Context, value: String = "", size: Float = 34f): TextView =
        TextView(context).apply {
            text = value
            setTextColor(TEXT)
            textSize = size
            typeface = Typeface.MONOSPACE
            setTypeface(typeface, Typeface.BOLD)
        }

    /** A grouped block on the platform's card container. */
    fun card(context: Context): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = PlatformUi.cardBackground(context)
        val pad = dp(context, 16)
        setPadding(pad, pad, pad, pad)
    }

    fun button(
        context: Context,
        value: String,
        primary: Boolean = false,
        onClick: () -> Unit,
    ): Button = PlatformUi.button(context, if (primary) ButtonKind.FILLED else ButtonKind.TONAL).apply {
        text = value
        minHeight = dp(context, 48)
        minimumHeight = dp(context, 48)
        isFocusable = true
        setOnClickListener { onClick() }
    }

    /** Compact row action used by the nearby list. */
    fun chip(
        context: Context,
        value: String,
        primary: Boolean = true,
        onClick: () -> Unit,
    ): Button = button(context, value, primary, onClick).apply {
        minWidth = dp(context, 88)
        minimumWidth = dp(context, 88)
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
                val b = PlatformUi.button(context, ButtonKind.TONAL).apply {
                    when (key) {
                        // The fleet's Tabler backspace rather than a font glyph.
                        KEY_BACK -> {
                            PlatformUi.setButtonIcon(this, R.drawable.ic_tabler_backspace)
                            contentDescription = context.getString(R.string.pair_key_delete)
                        }
                        KEY_OK -> text = context.getString(android.R.string.ok)
                        else -> text = key
                    }
                    textSize = 22f
                    isFocusable = true
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
    fun qrPlaceholder(context: Context): TextView = small(context).apply {
        gravity = Gravity.CENTER
        background = GradientDrawable().apply {
            setColor(ShellUi.opaque(tokens.surfaceAlt))
            cornerRadius = dp(context, 8).toFloat()
            setStroke(dp(context, 1), ShellUi.opaque(tokens.line))
        }
    }
}
