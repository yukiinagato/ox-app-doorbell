// Renders one page of the visitor flow on the door station (docs/en/visitor-flow-contract.md,
// section 7). Two zones: the content zone (title, images, body) goes into the scrolling idle view,
// the option zone goes into the fixed action dock and never scrolls off screen. This class only
// draws and reports taps; MainActivity owns navigation and the Core calls.
package jp.ox.doorbell

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.net.HttpURLConnection
import org.json.JSONObject

/** A scroll view that grows with its content up to a share of the viewport, then scrolls. */
internal class CappedScrollView(
    activity: Activity,
    private val capPx: () -> Int,
) : ScrollView(activity) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val incoming = MeasureSpec.getSize(heightMeasureSpec)
        val cap = capPx().coerceAtLeast(1)
        val limit = if (MeasureSpec.getMode(heightMeasureSpec) == MeasureSpec.UNSPECIFIED) cap
            else minOf(cap, incoming)
        super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(limit, MeasureSpec.AT_MOST))
    }
}

internal class VisitorFlowPanel(
    private val activity: Activity,
    private val content: LinearLayout,
    private val dock: LinearLayout,
    private val ui: android.os.Handler,
    private val viewportHeightPx: () -> Int,
    private val onOption: (String) -> Unit,
    private val onBack: () -> Unit,
    private val onDone: () -> Unit,
) {
    private val optionButtons = ArrayList<Pair<Button, FlowOptionView>>()
    private val imageCache = object : LinkedHashMap<String, Bitmap>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Bitmap>?): Boolean =
            size > MAX_CACHED_IMAGES
    }
    private var renderToken = 0
    private var lastTitleAnnounced: String? = null

    val visible: Boolean get() = content.visibility == View.VISIBLE

    fun hide() {
        renderToken++
        content.visibility = View.GONE
        dock.visibility = View.GONE
        content.removeAllViews()
        dock.removeAllViews()
        optionButtons.clear()
    }

    /** Disables every control while Core cannot be reached or a call is being placed. */
    fun setEnabled(enabled: Boolean) {
        for (index in 0 until dock.childCount) setTreeEnabled(dock.getChildAt(index), enabled)
    }

    private fun setTreeEnabled(view: View, enabled: Boolean) {
        view.isEnabled = enabled
        if (view is ViewGroup) for (i in 0 until view.childCount) setTreeEnabled(view.getChildAt(i), enabled)
    }

    fun applySemantic(config: JSONObject?, nodeId: String) {
        for ((button, option) in optionButtons)
            SemanticUi.apply(button, option.semanticId.ifEmpty { "purpose.button" }, config, nodeId)
    }

    fun render(
        snapshot: FlowSnapshot,
        texts: Texts,
        roles: UiRoles,
        styleConfig: JSONObject?,
        nodeId: String,
        httpPort: Int,
        safeMode: Boolean,
    ) {
        val token = ++renderToken
        content.removeAllViews()
        dock.removeAllViews()
        optionButtons.clear()
        val window = UiKit.window(activity)
        val metrics = activity.resources.displayMetrics
        val gap = ShellUi.dp(activity, UiTokens.SPACE_M)
        content.visibility = View.VISIBLE
        dock.visibility = View.VISIBLE

        snapshot.title?.takeIf { it.isNotEmpty() }?.let { title ->
            content.addView(TextView(activity).apply {
                text = title
                @Suppress("DEPRECATION")
                setTextAppearance(activity, R.style.TextAppearance_Doorbell_Headline)
                setTextColor(ShellUi.opaque(roles.onSurface))
                gravity = Gravity.CENTER_HORIZONTAL
                setTypeface(typeface, Typeface.BOLD)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            }, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = gap; bottomMargin = gap })
        }
        val maxImageHeight = (viewportHeightPx() * IMAGE_VIEWPORT_SHARE).toInt()
        for (image in snapshot.images.filter { it.above })
            addImage(image, token, maxImageHeight, httpPort, safeMode, roles)
        snapshot.body?.takeIf { it.isNotEmpty() }?.let { body ->
            val paragraphs = body.replace("\r\n", "\n").split("\n\n").filter { it.isNotEmpty() }
            for ((index, paragraph) in paragraphs.withIndex()) content.addView(TextView(activity).apply {
                text = paragraph
                textSize = if (window.widthDp >= VisitorLayout.TABLET_MIN_DP) 22f else 18f
                setTextColor(ShellUi.opaque(roles.onSurface))
                gravity = Gravity.CENTER_HORIZONTAL
                setLineSpacing(0f, 1.15f)
                // Plain text: nothing in the body is ever made tappable.
                autoLinkMask = 0
                linksClickable = false
            }, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { bottomMargin = if (index == paragraphs.lastIndex) 0 else gap })
        }
        for (image in snapshot.images.filter { !it.above })
            addImage(image, token, maxImageHeight, httpPort, safeMode, roles)

        val height = maxOf(UiTokens.VISITOR_TOUCH_MIN_DP, ScreenLayouts.visitorActionHeightDp(window))
        if (snapshot.mode == FlowWalker.MODE_END) {
            dock.addView(UiKit.actionButton(
                activity, texts.t("flow.done", R.string.flow_done), roles, ActionRole.PRIMARY,
                height, kind = ButtonKind.FILLED,
            ) { onDone() }.apply {
                maxLines = 3
                @Suppress("DEPRECATION")
                setTextAppearance(activity, R.style.TextAppearance_Doorbell_Title)
                // The text appearance carries a colour of its own; the role's ink goes back on.
                UiKit.styleAction(this, roles, ActionRole.PRIMARY, height, kind = ButtonKind.FILLED)
            }, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            return
        }

        val columns = columnsFor(window, snapshot.options.size)
        val grid = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        val cell = ShellUi.dp(activity, UiTokens.SPACE_S)
        snapshot.options.chunked(columns).forEachIndexed { rowIndex, row ->
            val line = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                isBaselineAligned = false
            }
            for ((index, option) in row.withIndex()) {
                val button = optionButton(option, roles, height)
                optionButtons.add(button to option)
                line.addView(button, LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
                ).apply { if (index > 0) leftMargin = cell })
            }
            grid.addView(line, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { if (rowIndex > 0) topMargin = cell })
        }
        val scroller = CappedScrollView(activity) { (viewportHeightPx() * OPTION_VIEWPORT_SHARE).toInt() }
        // The fade marks that more options wait; a scroll bar would sit on the buttons.
        scroller.isVerticalScrollBarEnabled = false
        scroller.isVerticalFadingEdgeEnabled = true
        scroller.setFadingEdgeLength(ShellUi.dp(activity, UiTokens.SPACE_XL))
        scroller.overScrollMode = View.OVER_SCROLL_NEVER
        scroller.addView(grid)
        dock.addView(scroller, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        if (snapshot.back) dock.addView(UiKit.actionButton(
            activity, texts.t("flow.back", R.string.flow_back), roles, ActionRole.SECONDARY,
            ScreenLayouts.touchTargetDp(window, 56),
        ) { onBack() }, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = cell })
        applySemantic(styleConfig, nodeId)
    }

    /** Announces the page title to a screen reader once per page change. */
    fun announce(title: String?) {
        if (title.isNullOrEmpty() || title == lastTitleAnnounced) return
        lastTitleAnnounced = title
        content.announceForAccessibility(title)
    }

    fun forgetAnnouncement() {
        lastTitleAnnounced = null
    }

    private fun optionButton(option: FlowOptionView, roles: UiRoles, heightDp: Int): Button {
        val label = if (option.icon.isEmpty()) option.label else "${option.icon}  ${option.label}"
        return PlatformUi.button(activity, if (option.primary) ButtonKind.FILLED else ButtonKind.TONAL).apply {
            text = label
            @Suppress("DEPRECATION")
            setTextAppearance(activity, R.style.TextAppearance_Doorbell_Title)
            setSingleLine(false)
            maxLines = 4
            isFocusable = true
            contentDescription = option.label
            UiKit.styleAction(
                this, roles, if (option.primary) ActionRole.PRIMARY else ActionRole.SECONDARY,
                heightDp, emphasis = true,
            )
            setOnClickListener { onOption(option.id) }
        }
    }

    private fun columnsFor(window: WindowSpec, count: Int): Int {
        if (count <= 1) return 1
        val portrait = window.heightDp > window.widthDp
        return if (window.widthDp < PHONE_MAX_DP || portrait) 1 else 2
    }

    private fun addImage(
        image: FlowImageView,
        token: Int,
        maxHeightPx: Int,
        httpPort: Int,
        safeMode: Boolean,
        roles: UiRoles,
    ) {
        val gap = ShellUi.dp(activity, UiTokens.SPACE_M)
        val params = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = gap / 2; bottomMargin = gap }
        // Until the file is cached the alt text stands in; Core re-publishes the document then.
        val alt = TextView(activity).apply {
            text = image.alt
            setTextColor(ShellUi.opaque(roles.muted))
            gravity = Gravity.CENTER_HORIZONTAL
            visibility = if (image.alt.isEmpty()) View.GONE else View.VISIBLE
        }
        val view = ImageView(activity).apply {
            adjustViewBounds = true
            scaleType = ImageView.ScaleType.FIT_CENTER
            maxHeight = maxHeightPx
            contentDescription = image.alt
            visibility = View.GONE
        }
        content.addView(view, params)
        content.addView(alt, params)
        if (image.path == null || safeMode || image.asset.isEmpty()) return
        imageCache[image.asset]?.let { show(view, alt, it); return }
        val widthPx = viewportWidthPx()
        Thread({
            val bitmap = fetch(image.asset, httpPort, widthPx, maxHeightPx)
            if (bitmap != null) ui.post {
                imageCache[image.asset] = bitmap
                if (token == renderToken) show(view, alt, bitmap)
            }
        }, "flow-image").apply { isDaemon = true }.start()
    }

    private fun show(view: ImageView, alt: TextView, bitmap: Bitmap) {
        view.setImageBitmap(bitmap)
        view.visibility = View.VISIBLE
        alt.visibility = View.GONE
    }

    private fun viewportWidthPx(): Int = activity.resources.displayMetrics.widthPixels

    /** Off the UI thread: the node's own asset route, bounded in bytes and in pixels. */
    private fun fetch(hash: String, httpPort: Int, widthPx: Int, heightPx: Int): Bitmap? {
        var connection: HttpURLConnection? = null
        return try {
            connection = LocalMedia.open("http://127.0.0.1:$httpPort/asset/$hash")
            connection.connectTimeout = 4000
            connection.readTimeout = 8000
            val bytes = BoundedBitmapDecoder.readLimited(connection.inputStream, MAX_IMAGE_BYTES)
            bytes?.let { BoundedBitmapDecoder.decode(it, widthPx, heightPx.coerceAtLeast(1)) }
        } catch (e: Exception) {
            ShellLog.ignored("VisitorFlowPanel", e)
            null
        } finally {
            try { connection?.disconnect() } catch (e: Exception) { ShellLog.ignored("VisitorFlowPanel", e) }
        }
    }

    companion object {
        const val IMAGE_VIEWPORT_SHARE = 0.4f
        const val OPTION_VIEWPORT_SHARE = 0.5f
        const val PHONE_MAX_DP = 600
        const val MAX_IMAGE_BYTES = 2 * 1024 * 1024
        const val MAX_CACHED_IMAGES = 6
    }
}
