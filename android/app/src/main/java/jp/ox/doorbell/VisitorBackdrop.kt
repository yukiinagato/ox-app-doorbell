// The visitor screen's background: configured colour or replicated image, the night tint, and the
// per-region automatic ink drawn over it (spec §5). Extracted from MainActivity; the rules are
// unchanged.
package jp.ox.doorbell

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Handler
import android.util.Log
import android.view.View
import android.view.ViewTreeObserver
import android.widget.ImageView
import android.widget.TextView
import java.net.HttpURLConnection
import org.json.JSONObject

/** A text region whose ink follows the background under it. */
internal data class InkRegion(val view: TextView, val region: String, val muted: Boolean)

internal class VisitorBackdrop(
    private val activity: Activity,
    private val app: App,
    private val rootView: View,
    private val themeBg: ImageView,
    private val nightTint: View,
    private val ui: Handler,
    private val config: () -> JSONObject?,
    private val nodeId: () -> String,
    private val palette: () -> Palette,
    private val coreDisplay: () -> CoreDisplay,
    private val inkRegions: () -> List<InkRegion>,
) {
    private var themeColor: String? = null
    var themeHash: String? = null
        private set

    /** The last ink applied per region, so a layout pass that changes nothing does no work. */
    private val inkApplied = HashMap<String, Int>()

    private val onLayout = ViewTreeObserver.OnGlobalLayoutListener {
        if (!activity.isFinishing) applyRegionInk()
    }

    fun themeValue(leaf: String): String? {
        val node = nodeId()
        val cfg = config()
        val v = (if (node.isNotEmpty()) app.core.dig(cfg, "devices.$node.local.theme.$leaf")
                 else null)
            ?: app.core.dig(cfg, "display.theme.$leaf")
        val s = v?.toString().orEmpty()
        return if (s.isEmpty() || s == "null") null else s
    }

    /** The flat colour behind the visitor screen, with no background image taken into account. */
    fun flatBackgroundRgb(): Int =
        UiContrast.parseRgb(themeValue("bg_color")) ?: palette().ground

    /** The colour actually behind the visitor screen, averaged by core when it is an image. */
    fun effectiveBackgroundRgb(): Int =
        coreDisplay().theme?.backgroundRgb
            ?: UiContrast.parseRgb(themeValue("bg_color"))
            ?: palette().ground

    fun applyTheme() {
        if (app.safeMode) {
            themeHash = null
            themeColor = null
            themeBg.setImageDrawable(null)
            themeBg.visibility = View.GONE
            @Suppress("DEPRECATION")
            rootView.setBackgroundColor(activity.resources.getColor(R.color.bg))
            return
        }
        val color = themeValue("bg_color")
        if (color != themeColor) {
            themeColor = color
            try {
                @Suppress("DEPRECATION")
                rootView.setBackgroundColor(
                    if (color != null) Color.parseColor(color)
                    else activity.resources.getColor(R.color.bg))
            } catch (e: Exception) {
                Log.w(TAG, "Ignoring invalid theme background color: $color ($e)")
            }
        }
        val hash = themeValue("bg_image")
        if (hash.isNullOrEmpty()) {
            themeHash = null
            themeBg.setImageDrawable(null)
            themeBg.visibility = View.GONE
            return
        }
        if (hash == themeHash && themeBg.drawable != null) return
        themeHash = hash
        loadThemeImage(hash)
    }

    /** Load a bounded background image from this node's own asset endpoint. */
    fun loadThemeImage(hash: String) {
        if (app.safeMode) return
        val url = "http://127.0.0.1:${app.boot.httpPort}/asset/$hash"
        val metrics = activity.resources.displayMetrics
        Thread({
            var bmp: Bitmap? = null
            var conn: HttpURLConnection? = null
            try {
                conn = LocalMedia.open(url)
                conn.connectTimeout = 4000
                conn.readTimeout = 8000
                val bytes = BoundedBitmapDecoder.readLimited(conn.inputStream, 4 * 1024 * 1024)
                val width = themeBg.width.takeIf { it > 0 } ?: metrics.widthPixels
                val height = themeBg.height.takeIf { it > 0 } ?: metrics.heightPixels
                bmp = bytes?.let { BoundedBitmapDecoder.decodeAspectFill(it, width, height) }
            } catch (e: Exception) {
                // asset_ready triggers another attempt after mesh prefetch completes.
                Log.w(TAG, "Theme background is not available yet: $e")
            } finally {
                try { conn?.disconnect() } catch (e: Exception) { ShellLog.ignored("VisitorBackdrop", e) }
            }
            val b = bmp ?: return@Thread
            ui.post {
                if (themeHash != hash || app.safeMode) return@post
                themeBg.setImageBitmap(b)
                themeBg.visibility = View.VISIBLE
                // The background under every region just changed; nothing decided against the
                // previous one may be kept.
                inkApplied.clear()
                scheduleRegionInk()
            }
        }, "theme-bg").apply { isDaemon = true }.start()
    }

    /** Apply a night tint above potentially bright theme imagery. */
    fun applyNightTint(night: Boolean, redTint: Boolean) {
        nightTint.visibility = if (night && redTint) View.VISIBLE else View.GONE
    }

    /**
     * Automatic ink per text region. Core averages the whole background image because it has no
     * layout geometry, so each region is sampled locally and refines core's answer; an
     * administrator override still wins, and a flat background colour leaves core's value
     * standing. A region that misses 4.5:1 gets the 40 % opposite-ink shadow behind it.
     */
    fun applyRegionInk() {
        for (region in inkRegions()) paint(region)
    }

    fun clearInk() = inkApplied.clear()

    fun scheduleRegionInk() {
        rootView.post { if (!activity.isFinishing) applyRegionInk() }
    }

    fun startWatch() {
        rootView.viewTreeObserver.addOnGlobalLayoutListener(onLayout)
    }

    fun stopWatch() {
        @Suppress("DEPRECATION")
        rootView.viewTreeObserver.removeGlobalOnLayoutListener(onLayout)
    }

    private fun paint(target: InkRegion) {
        val view = target.view
        // The flat colour a visitor would see with no picture on screen; never core's average of
        // the picture, which is only meaningful while the picture is actually painted.
        val ground = flatBackgroundRgb()
        val drawn = themeBg.visibility == View.VISIBLE && themeBg.drawable != null
        val sample = if (drawn) RegionInk.sample(themeBg, view, ground) else null
        val result = CoreDisplays.inkFor(
            coreDisplay().theme, target.region, ground, sample?.averageRgb, drawn, sample = sample,
        )
        val ink = if (target.muted) ShellUi.mute(result.inkRgb, palette().dark) else result.inkRgb
        val signature = (if (result.needsShadow) 1 shl 25 else 0) or (ink and 0xffffff)
        if (inkApplied[target.region] == signature) return
        inkApplied[target.region] = signature
        view.setTextColor(ShellUi.opaque(ink))
        if (result.needsShadow) {
            val shadow = ShellUi.opaque(result.shadowRgb) and 0x00ffffff or
                (RegionInkPolicy.SHADOW_ALPHA shl 24)
            view.setShadowLayer(1f * activity.resources.displayMetrics.density, 0f, 0f, shadow)
        } else {
            view.setShadowLayer(0f, 0f, 0f, 0)
        }
    }

    private companion object {
        const val TAG = "doorbell-backdrop"
    }
}
