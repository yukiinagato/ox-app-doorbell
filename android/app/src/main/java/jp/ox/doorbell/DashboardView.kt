// The indoor dashboard (spec §4.1, docs/en/ui-guidelines.md "Dashboard").
//
// A top app bar carries the device name and the announcement, add-device and device-information
// actions. Under it: the cluster clock with the fleet and status chips (SOS, offline devices,
// missed calls), then the door tile grid (DoorTilesPanel), which has the whole body: the home
// surface shows no call history. While missed calls are unread one notice above the tiles opens
// History, and the History destination carries the count as a badge. History, Monitor and
// Settings are the platform's navigation bar on compact windows and its rail from 600 dp up.
// Footer: admin QR +
// URL and `name · core vX · app vY · battery`. The SOS trigger is a compact outlined button in
// the header row. The wallpaper stays behind
// it all; everything on it sits on a card or chip except the clock and headings, which take
// Core's region ink.
package jp.ox.doorbell

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.drawable.Drawable
import android.os.Handler
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.net.HttpURLConnection
import java.util.Locale
import org.json.JSONObject

private class FrostedBackdropDrawable(
    private val owner: View,
    private val canvasRoot: View,
    private val radius: Float,
) : Drawable() {

    private var backdrop: Bitmap? = null
    private var tintRgb = 0
    private var borderRgb = 0
    private val imagePaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val shapePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val clip = Path()
    private val ownerLocation = IntArray(2)
    private val rootLocation = IntArray(2)

    fun update(bitmap: Bitmap?, tint: Int, border: Int) {
        backdrop = bitmap
        tintRgb = tint
        borderRgb = border
        invalidateSelf()
    }

    override fun draw(canvas: Canvas) {
        val box = RectF(bounds)
        clip.reset()
        clip.addRoundRect(box, radius, radius, Path.Direction.CW)
        val saved = canvas.save()
        canvas.clipPath(clip)
        val image = backdrop
        if (image != null && !image.isRecycled && canvasRoot.width > 0 && canvasRoot.height > 0) {
            owner.getLocationInWindow(ownerLocation)
            canvasRoot.getLocationInWindow(rootLocation)
            val left = ownerLocation[0] - rootLocation[0]
            val top = ownerLocation[1] - rootLocation[1]
            val sx = image.width.toFloat() / canvasRoot.width
            val sy = image.height.toFloat() / canvasRoot.height
            val source = Rect(
                (left * sx).toInt().coerceIn(0, image.width),
                (top * sy).toInt().coerceIn(0, image.height),
                ((left + owner.width) * sx).toInt().coerceIn(0, image.width),
                ((top + owner.height) * sy).toInt().coerceIn(0, image.height),
            )
            if (source.width() > 0 && source.height() > 0)
                canvas.drawBitmap(image, source, bounds, imagePaint)
        }
        canvas.drawColor((166 shl 24) or (tintRgb and 0xffffff))
        canvas.restoreToCount(saved)
        shapePaint.style = Paint.Style.STROKE
        shapePaint.strokeWidth = 1f
        shapePaint.color = (46 shl 24) or (borderRgb and 0xffffff)
        canvas.drawRoundRect(box, radius, radius, shapePaint)
    }

    override fun setAlpha(alpha: Int) = Unit
    override fun setColorFilter(colorFilter: ColorFilter?) = Unit

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}

internal class DashboardView(
    private val activity: Activity,
    private val app: App,
    private val texts: Texts,
    private val ui: Handler,
) {

    /** What the host mounts: the theme backdrop, with the dashboard column above it. */
    val root: FrameLayout = FrameLayout(activity)

    /**
     * The cluster's theme picture, already scaled and darkened, behind everything. GONE when the
     * cluster has no picture, which leaves the flat ground colour the palette paints on [root].
     */
    private val themeBg = ImageView(activity).apply {
        // The backdrop is prepared at exactly this view's size, so there is nothing left to fit.
        scaleType = ImageView.ScaleType.FIT_XY
        visibility = View.GONE
    }

    /** The dashboard itself, drawn over the backdrop. */
    private val column = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
    }

    private val clock = ClusterClock(app.core)
    private var palette: Palette = PlatformUi.tokens(activity)
    private var config: JSONObject? = null
    private var status: JSONObject? = null
    private var nodeId = ""
    private var coreDisplay: CoreDisplay = CoreDisplay(null, null)

    private val clockText = ShellUi.label(activity, "", TextRole.DISPLAY)
    private val dateText = ShellUi.label(activity, "", TextRole.SUBTITLE)
    private val appBar = PlatformUi.appBar(activity, app.boot.name)

    private val countersRow = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }
    private val deviceCount = counter(R.drawable.ic_tabler_topology_star_3)
    private val doorCount = counter(R.drawable.ic_tabler_door)
    private val panelCount = counter(R.drawable.ic_tabler_device_tablet)
    /** The one notice for unread missed calls; tapping it opens History. */
    private val missedNotice = PlatformUi.card(activity)
    private var missedText: TextView? = null
    private val sosChip = PlatformUi.chip(activity, "", ChipKind.STATUS, R.drawable.ic_tabler_alert_triangle,
                                          palette.danger, palette.onNegative)
    private val offlineChip = PlatformUi.chip(activity, "", ChipKind.ACTION, R.drawable.ic_tabler_video_off,
                                              palette.warning, palette.onWarning)
    private lateinit var header: LinearLayout
    private lateinit var clockBox: LinearLayout
    private lateinit var headerActions: android.widget.HorizontalScrollView


    /** Navigation and the dashboard column side by side (rail) or stacked (tabs). */
    private val shell = LinearLayout(activity)
    private var nav: View? = null
    private var navKey: Any? = null
    private var roles: UiRoles = UiRoles.from(palette)

    private val footer = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        isBaselineAligned = false
    }
    private val footerQr = ImageView(activity).apply {
        scaleType = ImageView.ScaleType.FIT_CENTER
        background = ShellUi.rounded(activity, 0xFFFFFF, 4)
        val inset = ShellUi.dp(activity, 2)
        setPadding(inset, inset, inset, inset)
    }
    private val footerAddress = ShellUi.text(activity, "", 11.5f, palette.ink).apply {
        maxLines = 1
        isSingleLine = true
    }
    private val versionText = ShellUi.text(activity, "", 11.5f, palette.muted)
    private val sosSlider = SosTriggerView(activity, ui)

    /** The backdrop currently on screen, as picture-hash@width x height. */
    private var backdropKey = ""

    /** A backdrop request already in flight, so a burst of refreshes decodes once. */
    private var backdropLoading = ""
    private var softenedBackdrop: Bitmap? = null
    private val footerGlass = FrostedBackdropDrawable(
        footer, root, ShellUi.dp(activity, ShellUi.CARD_RADIUS_DP).toFloat(),
    )

    /** What the footer currently shows, so an unchanged poll does no work. */
    private var footerUrl = ""
    private var versionLine = ""

    private var lastRows: List<CallRow> = emptyList()

    /** At most one call-log read in flight: refreshes can arrive faster than the query returns. */
    private var callsLoading = false

    private var unreadMissed = 0

    private val stillTick = object : Runnable {
        override fun run() {
            tilesPanel.refreshStills()
            // Re-read every tick so a change in settings applies without rebuilding the view.
            ui.postDelayed(this, PreviewRate.intervalMs(PreviewRate.saved(activity)))
        }
    }

    private val tilesPanel = DoorTilesPanel(activity, app, texts, ui, object : DoorTilesPanel.Host {
        override val palette: Palette get() = this@DashboardView.palette
        override val roles: UiRoles get() = this@DashboardView.roles
        override val status: JSONObject? get() = this@DashboardView.status
        override val config: JSONObject? get() = this@DashboardView.config
        override val clock: ClusterClock get() = this@DashboardView.clock
        override fun doorLabel(door: String): String = this@DashboardView.doorLabel(door)
        override fun openNotice(door: String) = openNoticeDialog(door)
        override fun showOfflineDoors() = this@DashboardView.showOfflineDoors()
        override fun lastActivity(door: String): String = lastActivityText(door)
        override fun paintRegion(view: TextView, region: String, backgroundRgb: Int, muted: Boolean) =
            this@DashboardView.paintRegion(view, region, backgroundRgb, muted, cacheKey = null)
    })


    init {
        build()
        // The frame has no size until the first layout, and it changes size on rotation. Both
        // decide which backdrop to prepare, and both move the regions around on top of it.
        root.addOnLayoutChangeListener { _, left, top, right, bottom, oldLeft, oldTop,
                                         oldRight, oldBottom ->
            val resized = (right - left) != (oldRight - oldLeft) ||
                (bottom - top) != (oldBottom - oldTop)
            if (resized) {
                applyThemeBackdrop()
                scheduleRegionInk()
            }
        }
    }

    // ---------- lifecycle ----------

    fun onResume() {
        ui.removeCallbacks(stillTick)
        ui.post(stillTick)
        refresh()
    }

    fun onPause() {
        ui.removeCallbacks(stillTick)
        sosSlider.cancelCountdown()
    }

    fun onConfigurationChanged() {
        applyArrangement()
    }

    /**
     * Redraw everything that depends on core state, from documents the host has already read.
     *
     * The host takes one status document per refresh and hands the same one to every surface, so
     * a refresh costs one read of core rather than one per surface that wants to look at it.
     */
    fun refresh(status: JSONObject?, config: JSONObject?) {
        this.config = config
        this.status = status
        nodeId = status?.optJSONObject("node")?.optString("id").orEmpty()
        texts.setConfig(config)
        coreDisplay = CoreDisplays.parse(status?.optJSONObject("display"))
        clock.refreshIfStale()
        val now = clock.cached()
        palette = ShellAppearance.resolve(activity, status, config, now.minuteOfDay())
        roles = UiRoles.from(palette, CoreDisplays.callButton(coreDisplay.theme, palette.ground))
        applyPalette()
        applyThemeBackdrop()
        updateClock(now)
        updateHeader()
        tilesPanel.update()
        updateFooter()
        configureSos()
        loadCalls()
        applyArrangement()
    }

    /** Update only runtime-backed widgets; theme and layout are configuration dependencies. */
    fun refreshRuntime(status: JSONObject?, withCalls: Boolean) {
        this.status = status
        nodeId = status?.optJSONObject("node")?.optString("id").orEmpty()
        updateHeader()
        tilesPanel.update()
        updateFooter()
        if (withCalls) loadCalls()
    }

    /** Refresh by reading core here, for the paths the host's coalescer does not drive. */
    fun refresh() = refresh(
        if (app.coreOk) app.core.status() else null,
        if (app.coreOk) app.core.config() else null,
    )

    /**
     * Called once a second by the host. Formats from the cached anchor and never touches core, so
     * a busy run loop cannot hold the second hand back; the anchor itself is renewed on a worker.
     */
    fun tickClock() {
        clock.refreshIfStale()
        updateClock(clock.cached())
    }

    /** Core says the time moved, so the next tick re-reads it rather than projecting. */
    fun onTimeChanged() {
        clock.invalidate()
        clock.refreshIfStale()
    }

    /**
     * A press or motion event promotes that camera without allocating a second carousel. All
     * doors remain in the scroll view, while only the cameras actually on screen are refreshed.
     */
    fun prioritizeDoor(door: String) = tilesPanel.prioritizeDoor(door)

    // ---------- construction ----------

    private fun build() {
        val pad = ShellUi.dp(activity, UiTokens.SPACE_L)
        root.addView(themeBg, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
        ))
        root.addView(shell, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
        ))
        shell.addView(column, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT, 1f,
        ))
        // The backdrop covers the whole frame, edge to edge; the body carries its own margins.

        column.addView(appBar.view, ShellUi.matchWrap())
        header = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isBaselineAligned = false
            val padH = ShellUi.dp(activity, UiTokens.SPACE_L)
            setPadding(padH, 0, padH, ShellUi.dp(activity, UiTokens.SPACE_S))
        }
        // The clock and the date each keep to one line; applyHeaderLayout gives a portrait
        // window its own clock row so the chips can never squeeze it.
        clockText.maxLines = 1
        clockText.includeFontPadding = false
        dateText.maxLines = 1
        clockBox = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(clockText)
            addView(dateText)
        }
        header.addView(clockBox, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
        ))
        // The SOS trigger is a compact outlined control at the leading edge of the header row;
        // it opens the confirmation surface and nothing else.
        countersRow.addView(sosSlider, chipParams())
        for (counter in listOf(deviceCount, doorCount, panelCount))
            countersRow.addView(counter, chipParams())
        // Status chips (guidelines: offline devices, SOS state, missed calls with badge).
        sosChip.visibility = View.GONE
        offlineChip.visibility = View.GONE
        offlineChip.setOnClickListener { showOfflineDoors() }
        for (chip in listOf(sosChip, offlineChip)) countersRow.addView(chip, chipParams())
        headerActions = android.widget.HorizontalScrollView(activity).apply {
            isHorizontalScrollBarEnabled = false
            addView(countersRow)
        }
        header.addView(headerActions)
        column.addView(header, ShellUi.matchWrap())

        val missedRow = ShellUi.row(activity, palette, "", icon = R.drawable.ic_tabler_phone_off) {
            HistoryActivity.launch(activity)
        }
        (missedRow.getChildAt(0) as? ImageView)?.setColorFilter(ShellUi.opaque(ShellUi.roleInk(palette.danger, palette)))
        missedText = (missedRow.getChildAt(1) as? LinearLayout)?.getChildAt(0) as? TextView
        missedRow.addView(ImageView(activity).apply {
            setImageResource(R.drawable.ic_tabler_chevron_right)
            setColorFilter(ShellUi.opaque(palette.muted))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(ShellUi.dp(activity, 24), ShellUi.dp(activity, 24)))
        missedNotice.content.addView(missedRow, ShellUi.matchWrap())
        missedNotice.root.visibility = View.GONE
        column.addView(missedNotice.root, ShellUi.matchWrap().apply {
            leftMargin = pad
            rightMargin = pad
            bottomMargin = ShellUi.dp(activity, UiTokens.SPACE_S)
        })
        column.addView(tilesPanel.scroll, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f,
        ).apply { leftMargin = pad; rightMargin = pad })

        val footerText = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            addView(footerAddress, ShellUi.matchWrap())
            addView(versionText, ShellUi.matchWrap())
        }
        val footerInset = ShellUi.dp(activity, 8)
        footer.setPadding(footerInset, footerInset, footerInset, footerInset)
        footer.addView(footerQr, LinearLayout.LayoutParams(
            ShellUi.dp(activity, 72), ShellUi.dp(activity, 72),
        ))
        footer.addView(footerText, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
        ).apply { leftMargin = ShellUi.dp(activity, 10) })
        // At least the QR's height, and taller when large text wraps the version line.
        footer.minimumHeight = ShellUi.dp(activity, 88)
        column.addView(footer, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { leftMargin = pad; rightMargin = pad; topMargin = ShellUi.dp(activity, 8) })

        sosSlider.enabledProvider = { app.coreOk }
        sosSlider.onTrigger = { app.commitEmergency(true) }
    }

    /**
     * A counter: an icon and a number on a chip, so the header stays readable at a glance and in
     * any language; the spoken label carries the words.
     */
    private fun counter(iconRes: Int): TextView =
        PlatformUi.chip(activity, "", ChipKind.STATUS, iconRes)

    private fun chipParams(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
    ).apply { rightMargin = ShellUi.dp(activity, 8) }

    /** The app bar's trailing actions; rebuilt with the language. */
    private fun buildActions() {
        appBar.clearActions()
        appBar.addAction(R.drawable.ic_tabler_note,
                         texts.t("notice.global_button", R.string.notice_global_button)) {
            openNoticeDialog("")
        }
        appBar.addAction(R.drawable.ic_tabler_plus,
                         texts.t("admin.menu_add_device", R.string.admin_menu_add_device)) {
            AdminGate.unlock(activity, app.boot.httpPort, texts) {
                if (app.pairingReady()) AddDeviceActivity.launch(activity)
                else {
                    app.resumePairingSetup()
                    PairingActivity.launch(activity)
                }
            }
        }
        appBar.addAction(R.drawable.ic_tabler_info_circle,
                         texts.t("admin.menu_info", R.string.admin_menu_info)) {
            AdminGate.unlock(activity, app.boot.httpPort, texts) {
                DeviceInfoActivity.launch(activity)
            }
        }
    }

    // ---------- painting ----------

    private fun applyPalette() {
        // The flat ground, which is what shows when the cluster has no theme picture and what
        // shows through anywhere a picture does not cover.
        root.setBackgroundColor(ShellUi.opaque(palette.ground))
        // A new palette means every region's decision was taken against a colour that has gone.
        regionInkApplied.clear()
        tilesPanel.invalidate()
        applyNavigation()
        footerAddress.setTextColor(ShellUi.opaque(palette.ink))
        versionText.setTextColor(ShellUi.opaque(palette.muted))
        footerAddress.setShadowLayer(0f, 0f, 0f, 0)
        versionText.setShadowLayer(0f, 0f, 0f, 0)
        footerGlass.update(softenedBackdrop, palette.surface, palette.line)
        footer.background = footerGlass
        sosSlider.applyPalette(palette)
        // Labels are reapplied here too, so a language change reaches the controls built once.
        if (actionsLang != texts.lang) {
            actionsLang = texts.lang
            buildActions()
        }
        // The regions sit on the frame, so their ink depends on whether a picture is behind them
        // and where each one lands on it. Once now, and again after the next layout.
        applyRegionInk()
        scheduleRegionInk()
    }

    private var actionsLang = ""

    // ---------- the theme backdrop ----------

    /**
     * Put the cluster's theme picture behind the dashboard, under the configured overlay
     * (spec §5.1).
     *
     * The dashboard used to paint a flat ground while the rest of the fleet carried the theme.
     * The picture is prepared once per (picture, view size, overlay) and cached, so a status poll
     * every second and a clock tick every second cost a map lookup and nothing else; only a new
     * picture, a real size change, or an administrator moving the overlay decodes, and that
     * happens on a worker thread. The overlay is composited into the cached bitmap, which is also
     * what RegionInk samples, so the ink is chosen against the pixels actually on screen.
     */
    private fun applyThemeBackdrop() {
        val hash = if (app.safeMode) "" else coreDisplay.theme?.backgroundImage.orEmpty()
        // An older core publishes no backdrop; that cluster keeps the overlay it always had.
        val overlay = coreDisplay.theme?.backdrop ?: BackdropOverlay.LEGACY
        if (hash.isEmpty()) {
            // No picture configured, or safe mode: the palette's flat ground is the background.
            if (backdropKey.isNotEmpty()) {
                backdropKey = ""
                themeBg.setImageDrawable(null)
                themeBg.visibility = View.GONE
                softenedBackdrop?.recycle()
                softenedBackdrop = null
                footerGlass.update(null, palette.surface, palette.line)
                regionInkApplied.clear()
                scheduleRegionInk()
            }
            return
        }
        val width = root.width
        val height = root.height
        // Before the first layout there is no size to prepare for; the layout listener returns.
        if (width <= 0 || height <= 0) return
        val blurRadius = coreDisplay.theme?.glassBlurRadius ?: 32
        val key = ThemeBackdrop.cacheKey(hash, width, height, overlay) + "/glass@$blurRadius"
        if (key == backdropKey) return
        if (key == backdropLoading) return
        backdropLoading = key
        loadThemeBackdrop(hash, width, height, overlay, blurRadius, key)
    }

    /**
     * Fetch the picture from this node's own asset endpoint and prepare it off the main thread.
     * The endpoint is loopback, so it is available before any peer is.
     */
    private fun loadThemeBackdrop(
        hash: String,
        width: Int,
        height: Int,
        overlay: BackdropOverlay,
        blurRadius: Int,
        key: String,
    ) {
        val url = "http://127.0.0.1:${app.boot.httpPort}/asset/$hash"
        Thread({
            var prepared = ThemeBackdrop.cached(hash, width, height, overlay)
            if (prepared == null) {
                var bytes: ByteArray? = null
                var connection: HttpURLConnection? = null
                try {
                    connection = LocalMedia.open(url)
                    connection.connectTimeout = 4000
                    connection.readTimeout = 8000
                    bytes = BoundedBitmapDecoder.readLimited(connection.inputStream, 4 * 1024 * 1024)
                } catch (error: Exception) {
                    // The mesh prefetch may not have finished; the next refresh tries again.
                    android.util.Log.w(TAG, "Theme backdrop is not available yet: $error")
                } finally {
                    try { connection?.disconnect() } catch (e: Exception) { ShellLog.ignored("DashboardView", e) }
                }
                prepared = ThemeBackdrop.build(bytes, hash, width, height, overlay)
            }
            val ready = prepared
            val softened = ready?.let {
                FrostedBlur.build(it, ShellUi.dp(activity, blurRadius))
            }
            ui.post {
                backdropLoading = ""
                if (ready == null) return@post
                // The theme, the size or the overlay may have moved on while this was decoding.
                val current = ThemeBackdrop.cacheKey(hash, root.width, root.height, overlay) +
                    "/glass@${coreDisplay.theme?.glassBlurRadius ?: 32}"
                if (current != key) {
                    softened?.recycle()
                    return@post
                }
                showBackdrop(key, ready, softened)
            }
        }, "doorbell-theme-bg").apply { isDaemon = true }.start()
    }

    private fun showBackdrop(key: String, bitmap: Bitmap, softened: Bitmap?) {
        backdropKey = key
        themeBg.setImageBitmap(bitmap)
        themeBg.visibility = View.VISIBLE
        softenedBackdrop?.recycle()
        softenedBackdrop = softened
        footerGlass.update(softenedBackdrop, palette.surface, palette.line)
        // Everything decided against the previous background is now wrong.
        regionInkApplied.clear()
        scheduleRegionInk()
    }

    /** The last ink applied per region, so a layout that changes nothing does no work. */
    private val regionInkApplied = HashMap<String, Int>()

    /**
     * The regions move under the picture on every layout, and the picture arrives after the first
     * one, so the decision has to re-run or the dashboard keeps ink chosen against a background
     * nobody is looking at any more.
     */
    private fun scheduleRegionInk() {
        root.post { applyRegionInk() }
    }

    /**
     * Every text that sits on the frame rather than on one of the dashboard's own opaque cards.
     *
     * A card carries its own known surface, so its label is decided against that. These have the
     * theme picture behind them whenever one is up, and a busy photograph is what §5's per-region
     * rule and its shadow exist for. The two section headings are included for the same reason
     * the clock is: they sit on the frame, not on a card.
     */
    private fun applyRegionInk() {
        paintRegion(clockText, "clock", palette.ground, muted = false)
        paintRegion(dateText, "date", palette.ground, muted = true)
        tilesPanel.heading?.let { paintRegion(it, "status_line", palette.ground, muted = true,
                                        cacheKey = "doors_heading") }
        // The app bar has no plate of its own either: its title and action icons take the ink
        // measured for the strip of wallpaper it lies on.
        val drawn = themeBg.visibility == View.VISIBLE && themeBg.drawable != null
        if (!drawn) {
            if (regionInkApplied.put("app_bar", -1) != -1) appBar.setInk(null)
            return
        }
        val sample = RegionInk.sample(themeBg, appBar.view, palette.ground)
        val ink = CoreDisplays.inkFor(
            coreDisplay.theme, "status_line", palette.ground, sample?.averageRgb,
            imageDrawnLocally = true, sample = sample,
        ).inkRgb
        if (regionInkApplied.put("app_bar", ink) != ink) appBar.setInk(ink)
    }

    /**
     * One text region's ink, by the same §5 rule the visitor screen uses: an administrator
     * override wins, then core's per-region decision, then the local measurement of whatever the
     * region actually sits on. A region that misses 4.5:1 gets the 40 % opposite-ink shadow.
     */
    private fun paintRegion(
        view: TextView,
        region: String,
        backgroundRgb: Int,
        muted: Boolean,
        /** Null for a region that repeats across many views, which must never share one entry. */
        cacheKey: String? = region,
    ) {
        // Two different backgrounds, and they take different rules. A card, a chip or a pill is a
        // surface the dashboard painted itself, so its colour is known exactly and core's average
        // of the theme picture says nothing about it. A region sitting straight on the frame,
        // though, has the darkened theme picture behind it whenever one is up, and then the local
        // sample of the pixels actually behind that region decides -- core averages the whole
        // picture and may not have averaged it at all.
        val drawn = themeBg.visibility == View.VISIBLE && themeBg.drawable != null
        val overBackdrop = drawn && backgroundRgb == palette.ground
        val sample = if (overBackdrop) RegionInk.sample(themeBg, view, backgroundRgb) else null
        val result = CoreDisplays.inkFor(
            coreDisplay.theme,
            region,
            backgroundRgb,
            if (overBackdrop) sample?.averageRgb else backgroundRgb,
            imageDrawnLocally = overBackdrop,
            knownSurface = !overBackdrop,
            sample = sample,
        )
        val ink = if (muted) ShellUi.mute(result.inkRgb, palette.dark) else result.inkRgb
        if (cacheKey != null) {
            val signature = (if (result.needsShadow) 1 shl 25 else 0) or (ink and 0xffffff)
            if (regionInkApplied[cacheKey] == signature) return
            regionInkApplied[cacheKey] = signature
        }
        view.setTextColor(ShellUi.opaque(ink))
        if (result.needsShadow) {
            val shadow = ShellUi.opaque(result.shadowRgb) and 0x00ffffff or
                (RegionInkPolicy.SHADOW_ALPHA shl 24)
            view.setShadowLayer(activity.resources.displayMetrics.density, 0f, 0f, shadow)
        } else {
            view.setShadowLayer(0f, 0f, 0f, 0)
        }
    }

    private var lastClock = ""
    private var lastDate = ""

    /** When the clock label last actually changed, for the tick-interval measurement. */
    private var lastClockAtMs = 0L

    /** Called once a second: only touches a TextView when the rendered value actually changed. */
    private fun updateClock(now: ClusterTime) {
        val clockValue = now.clockText()
        if (clockValue != lastClock) {
            // How long the displayed second actually lasted. A 1 Hz tick should read ~1000 ms;
            // anything much larger means the tick was blocked before it got here.
            val at = android.os.SystemClock.elapsedRealtime()
            if (lastClockAtMs != 0L)
                android.util.Log.i(CLOCK_TAG, "label $lastClock -> $clockValue after " +
                    "${at - lastClockAtMs} ms")
            lastClockAtMs = at
            lastClock = clockValue
            clockText.text = clockValue
        }
        val dateValue = dateLine(now)
        if (dateValue != lastDate) {
            lastDate = dateValue
            dateText.text = dateValue
        }
    }

    private fun dateLine(now: ClusterTime): String {
        return texts.dateLine(now)
    }

    private fun updateHeader() {
        val counts = FleetCounting.of(status, config, app.boot.role, nodeId)
        setTextIfChanged(deviceCount, counts.devices.toString())
        setDescriptionIfChanged(deviceCount, texts.t(
            "dash.count_devices", R.string.dash_count_devices, counts.devices.toString(),
        ))
        setTextIfChanged(
            doorCount, "${counts.doorStations.online}/${counts.doorStations.total}",
        )
        setDescriptionIfChanged(doorCount, texts.t(
            "dash.count_door_stations", R.string.dash_count_door_stations,
            counts.doorStations.online.toString(), counts.doorStations.total.toString(),
        ))
        setTextIfChanged(panelCount, "${counts.panels.online}/${counts.panels.total}")
        setDescriptionIfChanged(panelCount, texts.t(
            "dash.count_indoor_panels", R.string.dash_count_indoor_panels,
            counts.panels.online.toString(), counts.panels.total.toString(),
        ))
        missedText?.let {
            setTextIfChanged(it, texts.t("history.missed_badge", R.string.history_missed_badge,
                                         unreadMissed.toString()))
        }
        val offline = DashboardModel.offlineDevices(counts)
        val chips = DashboardModel.headerChips(DashboardModel.sosActive(status), offline, unreadMissed)
        setTextIfChanged(sosChip, texts.t("dash.chip_sos", R.string.dash_chip_sos))
        setTextIfChanged(offlineChip, texts.t("dash.chip_offline", R.string.dash_chip_offline, offline.toString()))
        setVisible(sosChip, HeaderChip.SOS in chips)
        setVisible(offlineChip, HeaderChip.OFFLINE_DEVICES in chips)
        setVisible(missedNotice.root, HeaderChip.MISSED in chips)
        applyNavigation()
    }

    private fun setVisible(view: View, visible: Boolean) {
        val value = if (visible) View.VISIBLE else View.GONE
        if (view.visibility != value) view.visibility = value
    }

    private fun setTextIfChanged(view: TextView, value: String) {
        if (view.text.toString() != value) view.text = value
    }

    private fun setDescriptionIfChanged(view: View, value: String) {
        if (view.contentDescription?.toString() != value) view.contentDescription = value
    }

    private fun updateFooter() {
        // The QR only changes when this node's own address does, so the footer is rebuilt on that
        // rather than on every status poll.
        val link = AdminLinks.resolve(status, app.boot.httpPort)
        if (link.url != footerUrl) {
            footerUrl = link.url
            footerAddress.text = link.url
            footerQr.contentDescription = texts.t(
                "web_admin.scan_hint", R.string.web_admin_scan_hint,
            )
            footerQr.setImageBitmap(AdminQrCache.get(
                app.core, link.url, ShellUi.dp(activity, 72),
            ))
        }
        val power = status?.optJSONObject("self")?.optJSONObject("power")
        val line = ShellUi.versionLine(
            app.boot.name,
            status?.optJSONObject("node")?.optString("version").orEmpty()
                .ifEmpty { app.core.version() },
            appVersion(),
            power?.optInt("battery_pct", -1) ?: -1,
            power?.optBoolean("charging", false) ?: false,
            texts.t("power.charging", R.string.power_charging),
        ) { texts.t("power.percent", R.string.power_percent, it.toString()) }
        if (line != versionLine) {
            versionLine = line
            versionText.text = line
        }
    }

    private fun configureSos() {
        val countdown = SosSlideState.countdownFromConfig(config)
        sosSlider.configure(
            texts.t("sos.slide_label", R.string.sos_slide_label),
            texts.t("sos.slide_sub", R.string.sos_slide_sub, countdown.toString()),
            texts.t("sos.countdown_cancel", R.string.sos_countdown_cancel),
            countdown,
            texts.t("sos.confirm_title", R.string.sos_confirm_title),
            texts.t("sos.hint", R.string.sos_hint),
            texts.t("sos.send", R.string.sos_send),
        ) { seconds -> texts.t("sos.countdown", R.string.sos_countdown, seconds.toString()) }
        sosSlider.visibility = if (sosVisible()) View.VISIBLE else View.GONE
        sosSlider.applySemantic(if (app.safeMode) null else config, nodeId)
    }

    /**
     * emergency.button_on_roles decides whether this panel offers the slider at all. An absent
     * key is core's default of ["indoor_panel"]; an empty list is a deliberate "nowhere".
     */
    private fun sosVisible(): Boolean = SosSlideState.visibleForRole(config, app.boot.role)

    // ---------- recent calls ----------

    private fun loadCalls() {
        if (!app.coreOk || callsLoading) return
        callsLoading = true
        Thread({
            val document = app.core.callLog(0L, 0L, CallHistoryModel.DASHBOARD_ROWS)
            val rows = CallHistoryModel.parse(document)
            val missed = CallHistoryModel.unreadMissed(document)
            ui.post {
                callsLoading = false
                lastRows = rows
                unreadMissed = missed
                updateHeader()
                tilesPanel.update()
            }
        }, "doorbell-dashboard-calls").apply { isDaemon = true }.start()
    }

    /** "14:02 · Answered" today, "11-03 14:02 · Missed" on an earlier day; empty if none. */
    private fun lastActivityText(door: String): String {
        val row = DashboardModel.lastCall(lastRows, door) ?: return ""
        val time = clock.format(row.tsMs)
        val today = clock.cached().date
        val clockPart = String.format(Locale.US, "%02d:%02d", time.hour, time.minute)
        val stamp = if (time.date == today || time.date.length < 10) clockPart
                    else time.date.substring(5) + " " + clockPart
        return stamp + " · " + UiKit.outcomeLabel(texts, CallOutcome.of(row.outcome))
    }

    // ---------- layout ----------

    /**
     * The guideline arrangement for the current window: tabs below on compact, a rail on the
     * start edge from medium up; the tile grid's columns follow the width the tiles get.
     */
    private fun applyArrangement() {
        val window = UiKit.window(activity)
        applyNavigation()
        tilesPanel.setColumns(DashboardModel.tileColumns(window, maxOf(1, tilesPanel.count)))
        applyHeaderLayout(window.widthDp, window.heightDp)
        tilesPanel.fitTilesToViewport()
    }

    /** Rebuild the tab bar or rail for the current window, palette and language. */
    private fun applyNavigation() {
        val window = UiKit.window(activity)
        val style = ScreenLayouts.navStyle(window)
        // Refreshes arrive often; rebuild only when something the bar shows actually changed.
        val key = listOf(style, roles, texts.lang, unreadMissed)
        if (nav != null && key == navKey) return
        navKey = key
        nav?.let { shell.removeView(it) }
        val items = listOf(
            NavItem(Destination.HOME.id, texts.t("nav.home", R.string.nav_home), R.drawable.ic_tabler_home),
            NavItem(Destination.HISTORY.id, texts.t("nav.history", R.string.nav_history), R.drawable.ic_tabler_history),
            NavItem(Destination.MONITOR.id, texts.t("nav.monitor", R.string.nav_monitor), R.drawable.ic_tabler_eye),
            NavItem(Destination.SETTINGS.id, texts.t("nav.settings", R.string.nav_settings), R.drawable.ic_tabler_settings),
        )
        val badges = if (unreadMissed > 0) mapOf(Destination.HISTORY.id to unreadMissed) else emptyMap()
        val view = UiKit.navigation(activity, style, items, Destination.HOME.id, badges) { item ->
            when (item.id) {
                Destination.HISTORY.id -> HistoryActivity.launch(activity)
                Destination.MONITOR.id -> tilesPanel.firstDoor.takeIf { it.isNotEmpty() }
                    ?.let { IncomingActivity.launch(activity, it) }
                Destination.SETTINGS.id -> SettingsActivity.open(activity, app, texts)
            }
        }
        if (style == NavStyle.RAIL) {
            shell.orientation = LinearLayout.HORIZONTAL
            shell.addView(view, 0, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT,
            ))
            (column.layoutParams as LinearLayout.LayoutParams).apply {
                width = 0; height = ViewGroup.LayoutParams.MATCH_PARENT; weight = 1f
            }
        } else {
            shell.orientation = LinearLayout.VERTICAL
            shell.addView(view, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ))
            (column.layoutParams as LinearLayout.LayoutParams).apply {
                width = ViewGroup.LayoutParams.MATCH_PARENT; height = 0; weight = 1f
            }
        }
        column.requestLayout()
        nav = view
    }

    /**
     * Portrait gives the clock its own full-width row above the pill and the buttons; landscape
     * keeps the single row, with the clock taking the width the buttons leave.
     */
    private fun applyHeaderLayout(widthDp: Int, heightDp: Int) {
        val stacked = VisitorLayout.dashboardHeaderStacked(widthDp, heightDp)
        header.orientation = if (stacked) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
        header.gravity = if (stacked) Gravity.START else Gravity.CENTER_VERTICAL
        val clockParams = clockBox.layoutParams as LinearLayout.LayoutParams
        val actionParams = headerActions.layoutParams as LinearLayout.LayoutParams
        if (stacked) {
            clockParams.width = ViewGroup.LayoutParams.MATCH_PARENT
            clockParams.weight = 0f
            actionParams.width = ViewGroup.LayoutParams.MATCH_PARENT
            actionParams.topMargin = ShellUi.dp(activity, 8)
        } else {
            clockParams.width = 0
            clockParams.weight = 1f
            actionParams.width = ViewGroup.LayoutParams.WRAP_CONTENT
            actionParams.topMargin = 0
        }
        clockBox.layoutParams = clockParams
        headerActions.layoutParams = actionParams
    }

    // ---------- helpers ----------

    private fun openNoticeDialog(door: String) {
        NoticeDialog.show(activity, app, texts, palette, door, doorIds(), ::doorLabel) {
            refresh()
        }
    }

    /** Every configured door. The announcement dialog and the monitor list use all of them. */
    private fun doorIds(): List<String> = DoorStations.allDoorIds(status, config)

    private fun showOfflineDoors() {
        val offline = DoorStations.offlineDoors(status, config)
        val title = texts.t("dashboard.offline_doors_title", R.string.dashboard_offline_doors_title)
        val builder = ShellDialogBuilder(activity).setTitle(title)
        if (offline.isEmpty()) {
            builder.setMessage(
                texts.t("dashboard.offline_doors_empty", R.string.dashboard_offline_doors_empty))
        } else {
            val statusText = texts.t("dashboard.device_status_offline",
                                     R.string.dashboard_device_status_offline)
            builder.setItems(offline.map { door ->
                val peer = DoorStations.peerFor(status, config, door)
                val name = peer?.optString("name").orEmpty()
                listOf(name, doorLabel(door), statusText).filter { it.isNotEmpty() }
                    .distinct().joinToString(" · ") as CharSequence
            }.toTypedArray(), null)
        }
        builder.setPositiveButton(texts.t("settings.close", R.string.settings_close), null).show()
    }

    private fun doorLabel(door: String): String {
        if (door.isEmpty()) return ""
        val value = app.core.dig(config, "doors.$door.label.${texts.lang}")
            ?: app.core.dig(config, "doors.$door.label.ja")
        return value?.toString() ?: door
    }

    /** A recorded call keeps the purpose the visitor chose, even once it has been disabled. */
    private fun purposeLabel(purpose: String): String =
        VisitPurposes.label(config, purpose, texts.lang)

    private fun appVersion(): String = try {
        activity.packageManager.getPackageInfo(activity.packageName, 0).versionName.orEmpty()
    } catch (_: Exception) {
        ""
    }

    private companion object {
        const val TAG = "doorbell-dash"
        const val CLOCK_TAG = "doorbell-clock"
    }
}
