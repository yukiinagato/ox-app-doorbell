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
    private val maxColumns: Int = Int.MAX_VALUE,
) {
    private val optionButtons = ArrayList<Pair<Button, FlowOptionView>>()
    private val imageCache = object : LinkedHashMap<String, Bitmap>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Bitmap>?): Boolean =
            size > MAX_CACHED_IMAGES
    }
    private var renderToken = 0
    private var pendingId: String? = null
    private var pendingDescription = ""
    private var busyButton: Button? = null
    private var backButton: Button? = null
    private var statusView: TextView? = null
    private var status: CharSequence = ""
    private var statusBold = false
    private var lastTitleAnnounced: String? = null

    val visible: Boolean get() = content.visibility == View.VISIBLE

    fun hide() {
        renderToken++
        content.visibility = View.GONE
        dock.visibility = View.GONE
        content.removeAllViews()
        dock.removeAllViews()
        optionButtons.clear()
        busyButton = null
        backButton = null
        statusView = null
        pendingId = null
        status = ""
    }

    /** Disables every control while Core cannot be reached or a call is being placed. */
    fun setEnabled(enabled: Boolean) {
        if (pendingId != null) {
            applyPending()
            return
        }
        for (index in 0 until dock.childCount) setTreeEnabled(dock.getChildAt(index), enabled)
        for ((button, _) in optionButtons) button.isEnabled = enabled
    }

    /**
     * Marks one option as waiting for Core: it keeps its label and its enabled look and shows the
     * platform's indeterminate indicator in its icon slot; every other option and Back are
     * disabled in place. Null restores the page. A re-render keeps the state.
     */
    fun setPending(optionId: String?, description: String = "") {
        pendingId = optionId
        pendingDescription = description
        applyPending()
        if (optionId != null && description.isNotEmpty()) content.announceForAccessibility(description)
    }

    /** The one-line status under the options; its slot is reserved, so showing it moves nothing. */
    fun setStatus(text: CharSequence, emphasis: Boolean = false) {
        status = text
        statusBold = emphasis
        applyStatus()
    }

    private fun applyStatus() {
        val view = statusView ?: return
        view.text = status
        view.setTypeface(null, if (statusBold) Typeface.BOLD else Typeface.NORMAL)
        view.visibility = if (status.isEmpty()) View.INVISIBLE else View.VISIBLE
    }

    private fun applyPending() {
        val id = pendingId
        for ((button, option) in optionButtons) {
            val busy = id != null && option.id == id
            button.isEnabled = id == null || busy
            button.contentDescription =
                if (busy && pendingDescription.isNotEmpty()) option.label + ", " + pendingDescription
                else option.label
            val icon = FlowIcons.glyph(option.purpose, option.icon).drawable
            if (busy && busyButton !== button) {
                busyButton = button
                PlatformUi.setButtonBusy(button, true, icon, OPTION_ICON_DP)
            } else if (!busy && busyButton === button) {
                busyButton = null
                PlatformUi.setButtonBusy(button, false, icon, OPTION_ICON_DP)
            }
        }
        backButton?.isEnabled = id == null
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
        callRoles: UiRoles,
        styleConfig: JSONObject?,
        nodeId: String,
        httpPort: Int,
        safeMode: Boolean,
    ) {
        val token = ++renderToken
        content.removeAllViews()
        dock.removeAllViews()
        optionButtons.clear()
        busyButton = null
        backButton = null
        statusView = null
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
        // A short page is one centred block: the title and its cards together. A long one keeps
        // the cards in the fixed dock so they never scroll away.
        val inline = snapshot.images.isEmpty() && window.heightDp >= INLINE_MIN_DP &&
            (snapshot.body?.length ?: 0) <= INLINE_BODY_MAX &&
            snapshot.options.size <= INLINE_MAX_OPTIONS
        if (snapshot.mode == FlowWalker.MODE_END) {
            (if (inline) content else dock).addView(UiKit.actionButton(
                activity, texts.t("flow.done", R.string.flow_done), roles, ActionRole.PRIMARY,
                height, kind = ButtonKind.FILLED,
            ) { onDone() }.apply {
                maxLines = 3
                @Suppress("DEPRECATION")
                setTextAppearance(activity, R.style.TextAppearance_Doorbell_Title)
                // The text appearance carries a colour of its own; the role's ink goes back on.
                UiKit.styleAction(this, roles, ActionRole.PRIMARY, height, kind = ButtonKind.FILLED)
            }, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { if (inline) topMargin = gap * 2 })
            dock.visibility = if (dock.childCount == 0) View.GONE else View.VISIBLE
            return
        }

        val columns = minOf(maxColumns, columnsFor(window, snapshot.options.size))
        val grid = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        val cell = ShellUi.dp(activity, UiTokens.SPACE_S)
        snapshot.options.chunked(columns).forEachIndexed { rowIndex, row ->
            val line = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                isBaselineAligned = false
            }
            for ((index, option) in row.withIndex()) {
                val button = optionButton(option, roles, callRoles, height)
                optionButtons.add(button to option)
                line.addView(button, LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
                ).apply { if (index > 0) leftMargin = cell })
            }
            // A short last row keeps its cards the size of the others and sits in the middle.
            val missing = columns - row.size
            if (missing > 0) {
                line.addView(View(activity), 0, LinearLayout.LayoutParams(0, 1, missing / 2f))
                line.addView(View(activity), LinearLayout.LayoutParams(0, 1, missing / 2f))
            }
            grid.addView(line, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { if (rowIndex > 0) topMargin = cell })
        }
        if (inline) {
            content.addView(grid, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = gap * 2 })
        } else {
            addDockedOptions(grid)
        }
        val statusLine = TextView(activity).apply {
            setLines(1)
            textSize = 16f
            gravity = Gravity.CENTER_HORIZONTAL
            setTextColor(ShellUi.opaque(roles.onSurface))
            visibility = View.INVISIBLE
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        statusView = statusLine
        (if (inline) content else dock).addView(statusLine, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = cell })
        if (snapshot.back) {
            val back = UiKit.actionButton(
                activity, texts.t("flow.back", R.string.flow_back), roles, ActionRole.SECONDARY,
                ScreenLayouts.touchTargetDp(window, 56),
            ) { onBack() }
            backButton = back
            dock.addView(back, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { if (!inline) topMargin = cell })
        }
        dock.visibility = if (dock.childCount == 0) View.GONE else View.VISIBLE
        applySemantic(styleConfig, nodeId)
        applyPending()
        applyStatus()
    }

    private fun addDockedOptions(grid: LinearLayout) {
        val scroller = CappedScrollView(activity) { (viewportHeightPx() * OPTION_VIEWPORT_SHARE).toInt() }
        // The fade marks that more options wait; a scroll bar would sit on the buttons.
        scroller.isVerticalScrollBarEnabled = false
        scroller.isVerticalFadingEdgeEnabled = true
        scroller.setFadingEdgeLength(ShellUi.dp(activity, UiTokens.SPACE_XL))
        scroller.overScrollMode = View.OVER_SCROLL_NEVER
        scroller.addView(grid)
        dock.addView(scroller, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
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

    private fun optionButton(
        option: FlowOptionView,
        roles: UiRoles,
        callRoles: UiRoles,
        heightDp: Int,
    ): Button {
        // Core's call-button colour belongs to a primary option that actually rings.
        val colours = if (option.primary && option.call) callRoles else roles
        return PlatformUi.button(activity, if (option.primary) ButtonKind.FILLED else ButtonKind.TONAL).apply {
            text = option.label
            @Suppress("DEPRECATION")
            setTextAppearance(activity, R.style.TextAppearance_Doorbell_Title)
            setSingleLine(false)
            maxLines = 4
            isFocusable = true
            contentDescription = option.label
            UiKit.styleAction(
                this, colours, if (option.primary) ActionRole.PRIMARY else ActionRole.SECONDARY,
                heightDp, emphasis = true,
            )
            PlatformUi.setButtonIcon(
                this, FlowIcons.glyph(option.purpose, option.icon).drawable, OPTION_ICON_DP,
            )
            setOnClickListener { onOption(option.id) }
        }
    }

    /** Two columns on a compact window, three on an expanded one; two or four cards pair up. */
    private fun columnsFor(window: WindowSpec, count: Int): Int = when {
        count <= 1 || window.widthDp < NARROW_MAX_DP -> 1
        window.widthDp < PHONE_MAX_DP -> if (count == 2) 1 else 2
        else -> if (count == 2 || count == 4) 2 else 3
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
        const val NARROW_MAX_DP = 360
        const val INLINE_MIN_DP = 600
        const val INLINE_BODY_MAX = 240
        const val INLINE_MAX_OPTIONS = 6
        const val OPTION_ICON_DP = 32
        const val MAX_IMAGE_BYTES = 2 * 1024 * 1024
        const val MAX_CACHED_IMAGES = 6
    }
}
