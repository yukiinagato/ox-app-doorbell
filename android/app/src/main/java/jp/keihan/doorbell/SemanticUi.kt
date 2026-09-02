package jp.keihan.doorbell

import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.drawable.Drawable
import android.graphics.drawable.StateListDrawable
import android.util.StateSet
import android.util.TypedValue
import android.view.View
import android.widget.TextView
import java.util.WeakHashMap
import kotlin.math.ceil
import kotlin.math.min
import org.json.JSONObject

/** Applies only manifest-advertised properties and fails closed to a persisted safe style. */
internal object SemanticUi {
    private data class Baseline(
        val scaleX: Float,
        val scaleY: Float,
        val textSizePx: Float?,
        val textColors: ColorStateList?,
        val background: Drawable?,
        val padding: IntArray,
        val minimumWidth: Int,
        val minimumHeight: Int,
        val foregroundArgb: Int?,
        val backgroundRgb: Int?,
    )

    /** A bounded wrapper is used instead of mutating an arbitrary platform or OEM drawable. */
    private class StyledBackgroundDrawable(
        private val content: Drawable?,
        private val fallbackFillArgb: Int,
        private val borderArgb: Int?,
        private val radiusPx: Float,
        private val strokeWidthPx: Float,
    ) : Drawable() {
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
        private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
        private val path = Path()
        private var drawableAlpha = 255
        private var drawableColorFilter: ColorFilter? = null

        override fun draw(canvas: Canvas) {
            if (bounds.isEmpty) return
            val area = RectF(bounds)
            path.reset()
            path.addRoundRect(area, radiusPx, radiusPx, Path.Direction.CW)
            val save = canvas.save()
            canvas.clipPath(path)
            if (content != null) {
                content.bounds = bounds
                content.draw(canvas)
            } else {
                fill.color = fallbackFillArgb
                fill.alpha = drawableAlpha
                fill.colorFilter = drawableColorFilter
                canvas.drawRect(area, fill)
            }
            canvas.restoreToCount(save)
            borderArgb?.let {
                stroke.color = it
                stroke.alpha = drawableAlpha
                stroke.colorFilter = drawableColorFilter
                stroke.strokeWidth = strokeWidthPx
                val inset = strokeWidthPx / 2f
                val outline = RectF(area).apply { inset(inset, inset) }
                val outlineRadius = maxOf(0f, radiusPx - inset)
                canvas.drawRoundRect(outline, outlineRadius, outlineRadius, stroke)
            }
        }

        override fun onStateChange(state: IntArray): Boolean {
            val changed = content?.setState(state) == true
            if (changed) invalidateSelf()
            return changed
        }

        override fun isStateful(): Boolean = content?.isStateful == true

        override fun setAlpha(alpha: Int) {
            drawableAlpha = alpha.coerceIn(0, 255)
            content?.alpha = drawableAlpha
            invalidateSelf()
        }

        override fun setColorFilter(colorFilter: ColorFilter?) {
            drawableColorFilter = colorFilter
            content?.colorFilter = colorFilter
            invalidateSelf()
        }

        @Deprecated("Deprecated in the Android Drawable API")
        override fun getOpacity(): Int = PixelFormat.TRANSLUCENT

        override fun getIntrinsicWidth(): Int = content?.intrinsicWidth ?: -1
        override fun getIntrinsicHeight(): Int = content?.intrinsicHeight ?: -1
    }

    private val baselines = WeakHashMap<View, Baseline>()
    private val safetyCritical = setOf("cancel.call", "call.end", "sos.trigger", "sos.cancel")

    fun apply(view: View, semanticId: String, config: JSONObject?, nodeId: String) {
        val baseline = baselines.getOrPut(view) { captureBaseline(view) }
        restore(view, baseline)
        enforceTouchFloor(view, baseline)
        val proposed = value(config, nodeId, semanticId)
        val app = view.context.applicationContext as? App
        val saved = if (proposed != null && app != null && nodeId.isNotEmpty())
            app.uiStyleLkg.get(nodeId, semanticId) else null
        val resolution = UiStylePolicy.resolve(
            proposed,
            saved,
            validationBaseline(semanticId, baseline),
            semanticId in safetyCritical,
            AndroidRuntimeContracts.uiProperties(semanticId),
        )
        resolution.style?.let { applyValidated(view, baseline, semanticId, it) }

        var result = when (resolution.source) {
            "proposed" -> "applied"
            "last_known_good" -> "last_known_good"
            else -> if (proposed == null) "platform_default" else "rejected_platform_default"
        }
        val validationError = resolution.rejectionReason
        var persistenceError = ""
        if (resolution.source == "proposed" && proposed != null && app != null &&
            nodeId.isNotEmpty() && !app.uiStyleLkg.save(nodeId, semanticId, proposed)) {
            result = "applied_not_persisted"
            persistenceError = "last_known_good_persist_failed"
        }
        if (app != null && nodeId.isNotEmpty()) app.reportUiStyleApplication(
            UiStyleApplyReport(
                nodeId,
                semanticId,
                result,
                validationError,
                persistenceError,
            ),
        )
    }

    fun invalidate(view: View) {
        baselines.remove(view)
    }

    private fun captureBaseline(view: View): Baseline {
        val text = view as? TextView
        val backgroundRgb = effectiveBackgroundRgb(view)
        val foreground = text?.textColors?.getColorForState(
            view.drawableState,
            text.currentTextColor,
        )
        return Baseline(
            view.scaleX,
            view.scaleY,
            text?.textSize,
            text?.textColors,
            view.background,
            intArrayOf(view.paddingLeft, view.paddingTop, view.paddingRight, view.paddingBottom),
            view.minimumWidth,
            view.minimumHeight,
            foreground,
            backgroundRgb,
        )
    }

    private fun applyValidated(
        view: View,
        baseline: Baseline,
        semanticId: String,
        style: ValidatedUiStyle,
    ) {
        view.scaleX = baseline.scaleX * style.scale
        view.scaleY = baseline.scaleY * style.scale
        val effectiveScale = min(kotlin.math.abs(view.scaleX), kotlin.math.abs(view.scaleY))
        if (effectiveScale > 0f && effectiveScale < 1f) {
            val minimumTouch = MINIMUM_TOUCH_DP * view.resources.displayMetrics.density
            val layoutFloor = ceil(minimumTouch / effectiveScale).toInt()
            view.minimumWidth = maxOf(view.minimumWidth, layoutFloor)
            view.minimumHeight = maxOf(view.minimumHeight, layoutFloor)
        }
        if (view is TextView) {
            baseline.textSizePx?.let {
                view.setTextSize(TypedValue.COMPLEX_UNIT_PX, it * style.fontScale)
            }
            style.foregroundRgb?.let { view.setTextColor(opaque(it)) }
        }
        styledBackground(view, baseline, semanticId, style)?.let {
            @Suppress("DEPRECATION")
            view.setBackgroundDrawable(it)
            view.setPadding(
                baseline.padding[0],
                baseline.padding[1],
                baseline.padding[2],
                baseline.padding[3],
            )
        }
    }

    private fun styledBackground(
        view: View,
        baseline: Baseline,
        semanticId: String,
        style: ValidatedUiStyle,
    ): Drawable? {
        if (style.backgroundRgb == null && style.accentRgb == null &&
            style.borderRgb == null && style.radiusDp == null) return null
        val defaults = AndroidRuntimeContracts.uiDefaults(semanticId)
        val density = view.resources.displayMetrics.density
        val radius = (style.radiusDp ?: defaults.radius.toFloat()) * density
        val background = opaque(style.backgroundRgb ?: baseline.backgroundRgb
            ?: UiStylePolicy.parseRgb(defaults.background)!!)
        val defaultAccent = UiStylePolicy.parseRgb(defaults.accent)?.let(::opaque)
        val defaultBorder = UiStylePolicy.parseRgb(defaults.border)?.let(::opaque)
        val accent = style.accentRgb?.let(::opaque) ?: if (style.backgroundRgb != null)
            defaultAccent else null
        val border = style.borderRgb?.let(::opaque) ?: when {
            style.accentRgb != null -> accent
            style.backgroundRgb != null -> defaultBorder
            else -> null
        }
        val replaceContent = style.backgroundRgb != null
        fun layer(outline: Int?, widthDp: Float): Drawable = StyledBackgroundDrawable(
            if (replaceContent) null else cloneDrawable(baseline.background, view),
            background,
            outline,
            radius,
            widthDp * density,
        )
        if (accent == null || accent == border) return layer(border, BORDER_DP)
        return StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_pressed), layer(accent, ACCENT_BORDER_DP))
            addState(intArrayOf(android.R.attr.state_focused), layer(accent, ACCENT_BORDER_DP))
            addState(intArrayOf(android.R.attr.state_selected), layer(accent, ACCENT_BORDER_DP))
            addState(intArrayOf(android.R.attr.state_activated), layer(accent, ACCENT_BORDER_DP))
            addState(StateSet.WILD_CARD, layer(border, BORDER_DP))
        }
    }

    private fun cloneDrawable(drawable: Drawable?, view: View): Drawable? = try {
        drawable?.constantState?.newDrawable(view.resources)?.mutate()
    } catch (_: Exception) {
        null
    }

    private fun validationBaseline(semanticId: String, baseline: Baseline): UiStyleBaseline {
        val defaults = AndroidRuntimeContracts.uiDefaults(semanticId)
        return UiStyleBaseline(
            baseline.foregroundArgb,
            baseline.backgroundRgb,
            UiStylePolicy.parseRgb(defaults.accent),
            UiStylePolicy.parseRgb(defaults.border),
            defaults.radius.toFloat(),
        )
    }

    private fun restore(view: View, value: Baseline) {
        view.scaleX = value.scaleX
        view.scaleY = value.scaleY
        if (view is TextView) {
            value.textSizePx?.let { view.setTextSize(TypedValue.COMPLEX_UNIT_PX, it) }
            value.textColors?.let(view::setTextColor)
        }
        @Suppress("DEPRECATION")
        view.setBackgroundDrawable(value.background)
        view.setPadding(value.padding[0], value.padding[1], value.padding[2], value.padding[3])
        view.minimumWidth = value.minimumWidth
        view.minimumHeight = value.minimumHeight
    }

    private fun enforceTouchFloor(view: View, baseline: Baseline) {
        val minimumTouch = (MINIMUM_TOUCH_DP * view.resources.displayMetrics.density + 0.5f).toInt()
        view.minimumWidth = maxOf(baseline.minimumWidth, minimumTouch)
        view.minimumHeight = maxOf(baseline.minimumHeight, minimumTouch)
    }

    private fun value(config: JSONObject?, nodeId: String, semanticId: String): JSONObject? {
        if (config == null || nodeId.isEmpty()) return null
        var current = config.optJSONObject("devices")?.optJSONObject(nodeId)
            ?.optJSONObject("local")?.optJSONObject("ui")?.optJSONObject("elements")
            ?: return null
        current.optJSONObject(semanticId)?.let { return it }
        val parts = semanticId.split('.')
        for (index in parts.indices) {
            val next = current.optJSONObject(parts[index]) ?: return null
            if (index == parts.lastIndex) return next
            current = next
        }
        return null
    }

    private fun effectiveBackgroundRgb(view: View): Int? {
        val layers = ArrayList<Int>()
        var current: View? = view
        while (current != null) {
            sample(current.background, current)?.let(layers::add)
            current = current.parent as? View
        }
        var composed = themeBackground(view)
        for (index in layers.indices.reversed()) composed = composite(layers[index], composed)
        return if (Color.alpha(composed) == 255) composed and RGB_MASK else null
    }

    private fun sample(drawable: Drawable?, view: View): Int? {
        if (drawable == null) return null
        val copy = try {
            drawable.constantState?.newDrawable(view.resources)?.mutate() ?: drawable
        } catch (_: Exception) {
            drawable
        }
        val originalBounds = if (copy === drawable) Rect(drawable.bounds) else null
        val originalState = if (copy === drawable) drawable.state.clone() else null
        var bitmap: Bitmap? = null
        return try {
            bitmap = Bitmap.createBitmap(SAMPLE_SIZE, SAMPLE_SIZE, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            copy.state = view.drawableState
            copy.setBounds(0, 0, SAMPLE_SIZE, SAMPLE_SIZE)
            copy.draw(canvas)
            bitmap.getPixel(SAMPLE_SIZE / 2, SAMPLE_SIZE / 2)
        } catch (_: Exception) {
            null
        } finally {
            if (originalBounds != null) copy.bounds = originalBounds
            if (originalState != null) copy.state = originalState
            bitmap?.recycle()
        }
    }

    @Suppress("DEPRECATION")
    private fun themeBackground(view: View): Int {
        val value = TypedValue()
        if (!view.context.theme.resolveAttribute(android.R.attr.colorBackground, value, true))
            return Color.TRANSPARENT
        return try {
            if (value.resourceId != 0) view.resources.getColor(value.resourceId) else value.data
        } catch (_: Exception) {
            Color.TRANSPARENT
        }
    }

    private fun composite(foreground: Int, background: Int): Int {
        val foregroundAlpha = Color.alpha(foreground)
        val backgroundAlpha = Color.alpha(background)
        val outputAlpha = foregroundAlpha + backgroundAlpha * (255 - foregroundAlpha) / 255
        if (outputAlpha == 0) return Color.TRANSPARENT
        fun channel(foregroundChannel: Int, backgroundChannel: Int): Int =
            (foregroundChannel * foregroundAlpha * 255 +
                backgroundChannel * backgroundAlpha * (255 - foregroundAlpha)) /
                (outputAlpha * 255)
        return Color.argb(
            outputAlpha,
            channel(Color.red(foreground), Color.red(background)),
            channel(Color.green(foreground), Color.green(background)),
            channel(Color.blue(foreground), Color.blue(background)),
        )
    }

    private fun opaque(rgb: Int): Int = 0xff000000.toInt() or rgb

    private const val MINIMUM_TOUCH_DP = 48
    private const val BORDER_DP = 2f
    private const val ACCENT_BORDER_DP = 3f
    private const val SAMPLE_SIZE = 3
    private const val RGB_MASK = 0x00ffffff
}
