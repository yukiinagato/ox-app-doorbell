// The indoor dashboard (spec §4.1, review page A).
//
// Clock and date from the cluster clock, membership pill, missed badge, 管理 entry, door tiles with
// a five-second still and an announcement chip, a scrolling list of the last twenty calls with
// 「すべて見る」, a footer carrying the admin QR + URL and `name · core vX · app vY · battery`, the
// SOS slider and the 「お知らせ（全体）」 button. Portrait stacks the tiles above the call list;
// landscape puts them side by side. Framework views only.
package jp.ox.doorbell

import android.app.Activity
import android.graphics.Bitmap
import android.os.Handler
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import org.json.JSONObject

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
    private var palette: Palette = Palette.DARK
    private var config: JSONObject? = null
    private var status: JSONObject? = null
    private var nodeId = ""
    private var coreDisplay: CoreDisplay = CoreDisplay(null, null)

    private val clockText = ShellUi.text(activity, "", 40f, palette.ink)
    private val dateText = ShellUi.text(activity, "", 14f, palette.muted)
    /** One icon-and-number counter in the header. */
    private class Counter(val root: LinearLayout, val icon: ImageView, val value: TextView)

    private val countersRow = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }
    private val deviceCount = counter(R.drawable.ic_count_cluster)
    private val doorCount = counter(R.drawable.ic_count_door_station)
    private val panelCount = counter(R.drawable.ic_count_indoor_panel)
    private val missedBadge = ShellUi.pill(activity, "", palette.dangerSoft, palette.dangerInk)
    private lateinit var adminButton: Button
    private lateinit var noticeButton: Button
    private lateinit var actionRow: LinearLayout
    private lateinit var header: LinearLayout
    private lateinit var clockBox: LinearLayout
    private lateinit var headerActions: LinearLayout
    private lateinit var recentCallsHeading: TextView

    /** The 門口 heading, rebuilt whenever the door set changes, so it is not a lateinit. */
    private var doorsHeading: TextView? = null
    private lateinit var seeAllButton: Button
    private val tileColumn = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
    }
    private val callColumn = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
    }
    private val bodySplit = LinearLayout(activity).apply { isBaselineAligned = false }
    private lateinit var tileScroll: ScrollView
    private var tilesScrolled = false
    private val callList = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
    }
    private val footer = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        isBaselineAligned = false
    }
    private val versionText = ShellUi.text(activity, "", 11.5f, palette.muted)
    private val sosSlider = SosSlideView(activity, ui)

    private val stills = HashMap<String, ImageView>()

    /** One tile view per door, built once and then only updated. */
    private val tiles = LinkedHashMap<String, DoorTile>()

    /** The backdrop currently on screen, as picture-hash@width x height. */
    private var backdropKey = ""

    /** A backdrop request already in flight, so a burst of refreshes decodes once. */
    private var backdropLoading = ""

    /** What the footer currently shows, so an unchanged poll does no work. */
    private var footerUrl = ""
    private var versionLine = ""

    /** A door tile's mutable parts, so a status poll updates rather than rebuilds. */
    private class DoorTile(
        val root: LinearLayout,
        val still: ImageView,
        val chips: LinearLayout,
        val label: TextView,
        val noticeText: TextView,
    ) {
        var lastNotice: String = "\u0000"
        var lastService: DoorService? = null
    }
    private var lastRows: List<CallRow> = emptyList()
    private var unreadMissed = 0

    private val stillTick = object : Runnable {
        override fun run() {
            refreshStills()
            ui.postDelayed(this, STILL_INTERVAL_MS)
        }
    }

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

    /** Redraw everything that depends on core state. Cheap enough for every relevant event. */
    fun refresh() {
        config = if (app.coreOk) app.core.config() else null
        status = if (app.coreOk) app.core.status() else null
        nodeId = status?.optJSONObject("node")?.optString("id").orEmpty()
        texts.setConfig(config)
        coreDisplay = CoreDisplays.parse(status?.optJSONObject("display"))
        clock.refreshIfStale()
        val now = clock.cached()
        // Core resolves the appearance in the cluster time zone; auto_system still consults the
        // platform, and an older core falls back to the local computation.
        val appearance = coreDisplay.appearance
        palette = if (appearance != null)
            Appearance.palette(CoreDisplays.isDark(appearance, systemDarkMode(activity)))
        else Appearance.resolve(config, nodeId, systemDarkMode(activity), now.minuteOfDay())
        applyPalette()
        applyThemeBackdrop()
        updateClock(now)
        updateHeader()
        buildTiles()
        updateFooter()
        configureSos()
        loadCalls()
        applyArrangement()
    }

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

    // ---------- construction ----------

    private fun build() {
        val pad = ShellUi.dp(activity, 14)
        root.addView(themeBg, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
        ))
        root.addView(column, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
        ))
        // The padding belongs to the column: the backdrop covers the whole frame, edge to edge.
        column.setPadding(pad, pad, pad, pad)

        header = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isBaselineAligned = false
        }
        // The clock and the date each keep to one line. Sharing a row with the header buttons left
        // the clock about one character wide on a portrait phone, and it wrapped to one glyph per
        // line down the edge; applyHeaderLayout gives portrait its own row, and this makes the
        // failure unreachable even if a future arrangement gets the widths wrong again.
        clockText.maxLines = 1
        dateText.maxLines = 1
        clockBox = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(clockText)
            addView(dateText)
        }
        header.addView(clockBox, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
        ))
        headerActions = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        for (counter in listOf(deviceCount, doorCount, panelCount))
            countersRow.addView(counter.root, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { leftMargin = if (counter === deviceCount) 0 else ShellUi.dp(activity, 10) })
        headerActions.addView(countersRow, chipParams())
        headerActions.addView(missedBadge, chipParams())
        missedBadge.isFocusable = true
        missedBadge.isClickable = true
        missedBadge.setOnClickListener { HistoryActivity.launch(activity) }
        adminButton = ShellUi.button(
            activity, texts.t("admin.title", R.string.admin_title), palette,
        ) { SettingsActivity.open(activity, app, texts) }
        headerActions.addView(adminButton, chipParams())
        header.addView(headerActions)
        column.addView(header, ShellUi.matchWrap())

        tileScroll = ScrollView(activity).apply {
            // Deliberately not fillViewport: that re-measures the column to exactly the viewport
            // height, and a column taller than the viewport then crushes the tile captions to a
            // few pixels instead of scrolling.
            isFillViewport = false
            addView(tileColumn, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ))
        }
        bodySplit.addView(tileScroll, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ))
        bodySplit.addView(callColumn, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ))
        column.addView(bodySplit, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f,
        ))

        // Recent calls: twenty rows that scroll, with the full history one tap away.
        val callHeader = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isBaselineAligned = false
        }
        recentCallsHeading = ShellUi.text(
            activity, texts.t("dash.recent_calls", R.string.dash_recent_calls), 13f,
            palette.muted, bold = true,
        )
        callHeader.addView(
            recentCallsHeading,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        seeAllButton = ShellUi.button(
            activity, texts.t("dash.see_all", R.string.dash_see_all), palette,
        ) { HistoryActivity.launch(activity) }
        callHeader.addView(seeAllButton)
        callColumn.addView(callHeader, ShellUi.matchWrap())
        callColumn.addView(
            ScrollView(activity).apply {
                isFillViewport = true
                addView(callList, LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                ))
            },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f),
        )

        // Footer: the admin QR and address are always visible; opening the page still asks for
        // the 管理パスワード.
        column.addView(footer, ShellUi.matchWrap())
        column.addView(versionText, ShellUi.matchWrap())

        actionRow = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isBaselineAligned = false
        }
        val actions = actionRow
        noticeButton = ShellUi.button(
            activity, texts.t("notice.global_button", R.string.notice_global_button), palette,
        ) { openNoticeDialog("") }
        actions.addView(noticeButton, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
        ))
        actions.addView(sosSlider, LinearLayout.LayoutParams(
            0, ShellUi.dp(activity, 56), 1f,
        ).apply { leftMargin = ShellUi.dp(activity, 8) })
        column.addView(actions, ShellUi.matchWrap().apply {
            topMargin = ShellUi.dp(activity, 8)
        })

        sosSlider.enabledProvider = { app.coreOk }
        sosSlider.onTrigger = { app.commitEmergency(true) }
    }

    /**
     * A counter: a small vector icon and a number. Drawn rather than written out, so the header
     * stays readable at a glance and in any language; the spoken label carries the words.
     */
    private fun counter(iconRes: Int): Counter {
        val icon = ImageView(activity).apply {
            setImageResource(iconRes)
            scaleType = ImageView.ScaleType.FIT_CENTER
        }
        val value = ShellUi.text(activity, "", 13f, palette.muted, bold = true)
        val root = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(icon, LinearLayout.LayoutParams(
                ShellUi.dp(activity, 16), ShellUi.dp(activity, 16),
            ))
            addView(value, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { leftMargin = ShellUi.dp(activity, 4) })
        }
        return Counter(root, icon, value)
    }

    private fun chipParams(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
    ).apply { leftMargin = ShellUi.dp(activity, 8) }

    // ---------- painting ----------

    private fun applyPalette() {
        // The flat ground, which is what shows when the cluster has no theme picture and what
        // shows through anywhere a picture does not cover.
        root.setBackgroundColor(ShellUi.opaque(palette.ground))
        // A new palette means every region's decision was taken against a colour that has gone.
        regionInkApplied.clear()
        for (counter in listOf(deviceCount, doorCount, panelCount)) {
            counter.value.setTextColor(ShellUi.opaque(palette.muted))
            counter.icon.setColorFilter(ShellUi.opaque(palette.muted))
        }
        missedBadge.background = ShellUi.rounded(activity, palette.dangerSoft, 999)
        missedBadge.setTextColor(ShellUi.opaque(palette.dangerInk))
        adminButton.background = ShellUi.rounded(activity, palette.surfaceAlt, 10)
        adminButton.setTextColor(ShellUi.opaque(palette.ink))
        noticeButton.background = ShellUi.rounded(activity, palette.surfaceAlt, 10)
        noticeButton.setTextColor(ShellUi.opaque(palette.ink))
        seeAllButton.background = ShellUi.rounded(activity, palette.surfaceAlt, 10)
        seeAllButton.setTextColor(ShellUi.opaque(palette.ink))
        sosSlider.applyPalette(palette)
        // Labels are reapplied here too, so a language change reaches the controls built once.
        adminButton.text = texts.t("admin.title", R.string.admin_title)
        noticeButton.text = texts.t("notice.global_button", R.string.notice_global_button)
        recentCallsHeading.text = texts.t("dash.recent_calls", R.string.dash_recent_calls)
        seeAllButton.text = texts.t("dash.see_all", R.string.dash_see_all)
        // The regions sit on the frame, so their ink depends on whether a picture is behind them
        // and where each one lands on it. Once now, and again after the next layout.
        applyRegionInk()
        scheduleRegionInk()
    }

    // ---------- the theme backdrop ----------

    /**
     * Put the cluster's theme picture behind the dashboard, darkened (spec §5.1).
     *
     * The dashboard used to paint a flat ground while the rest of the fleet carried the theme.
     * The picture is prepared once per (picture, view size) and cached, so a status poll every
     * second and a clock tick every second cost a map lookup and nothing else; only a new picture
     * or a real size change decodes, and that happens on a worker thread.
     */
    private fun applyThemeBackdrop() {
        val hash = if (app.safeMode) "" else coreDisplay.theme?.backgroundImage.orEmpty()
        if (hash.isEmpty()) {
            // No picture configured, or safe mode: the palette's flat ground is the background.
            if (backdropKey.isNotEmpty()) {
                backdropKey = ""
                themeBg.setImageDrawable(null)
                themeBg.visibility = View.GONE
                regionInkApplied.clear()
                scheduleRegionInk()
            }
            return
        }
        val width = root.width
        val height = root.height
        // Before the first layout there is no size to prepare for; the layout listener returns.
        if (width <= 0 || height <= 0) return
        val key = ThemeBackdrop.cacheKey(hash, width, height)
        if (key == backdropKey) return
        ThemeBackdrop.cached(hash, width, height)?.let { showBackdrop(key, it); return }
        if (key == backdropLoading) return
        backdropLoading = key
        loadThemeBackdrop(hash, width, height, key)
    }

    /**
     * Fetch the picture from this node's own asset endpoint and prepare it off the main thread.
     * The endpoint is loopback, so it is available before any peer is.
     */
    private fun loadThemeBackdrop(hash: String, width: Int, height: Int, key: String) {
        val url = "http://127.0.0.1:${app.boot.httpPort}/asset/$hash"
        Thread({
            var bytes: ByteArray? = null
            var connection: HttpURLConnection? = null
            try {
                connection = URL(url).openConnection() as HttpURLConnection
                connection.connectTimeout = 4000
                connection.readTimeout = 8000
                bytes = BoundedBitmapDecoder.readLimited(connection.inputStream, 4 * 1024 * 1024)
            } catch (error: Exception) {
                // The mesh prefetch may not have finished; the next refresh tries again.
                android.util.Log.w(TAG, "Theme backdrop is not available yet: $error")
            } finally {
                try { connection?.disconnect() } catch (_: Exception) { }
            }
            val prepared = ThemeBackdrop.build(bytes, hash, width, height)
            ui.post {
                backdropLoading = ""
                if (prepared == null) return@post
                // The theme or the size may have moved on while this was decoding.
                if (ThemeBackdrop.cacheKey(hash, root.width, root.height) != key) return@post
                showBackdrop(key, prepared)
            }
        }, "doorbell-theme-bg").apply { isDaemon = true }.start()
    }

    private fun showBackdrop(key: String, bitmap: Bitmap) {
        backdropKey = key
        themeBg.setImageBitmap(bitmap)
        themeBg.visibility = View.VISIBLE
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
        paintRegion(versionText, "footer", palette.ground, muted = true)
        paintRegion(recentCallsHeading, "status_line", palette.ground, muted = true)
        doorsHeading?.let { paintRegion(it, "status_line", palette.ground, muted = true,
                                        cacheKey = "doors_heading") }
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
        if (now.date.isEmpty()) return ""
        val parts = now.date.split("-")
        if (parts.size != 3) return now.date
        val weekday = WEEKDAYS.getOrElse(now.weekdayNum) { "" }
        return String.format(
            Locale.US, "%s-%s-%s%s", parts[0], parts[1], parts[2],
            if (weekday.isEmpty()) "" else " ($weekday)",
        )
    }

    private fun updateHeader() {
        val counts = FleetCounting.of(status, config, app.boot.role, nodeId)
        deviceCount.value.text = counts.devices.toString()
        deviceCount.root.contentDescription = texts.t(
            "dash.count_devices", R.string.dash_count_devices, counts.devices.toString(),
        )
        doorCount.value.text = "${counts.doorStations.online}/${counts.doorStations.total}"
        doorCount.root.contentDescription = texts.t(
            "dash.count_door_stations", R.string.dash_count_door_stations,
            counts.doorStations.online.toString(), counts.doorStations.total.toString(),
        )
        panelCount.value.text = "${counts.panels.online}/${counts.panels.total}"
        panelCount.root.contentDescription = texts.t(
            "dash.count_indoor_panels", R.string.dash_count_indoor_panels,
            counts.panels.online.toString(), counts.panels.total.toString(),
        )
        missedBadge.text = texts.t("history.missed_badge", R.string.history_missed_badge,
                                   unreadMissed.toString())
        missedBadge.visibility = if (unreadMissed > 0) View.VISIBLE else View.GONE
    }

    private fun updateFooter() {
        // The QR only changes when this node's own address does, so the footer is rebuilt on that
        // rather than on every status poll.
        val link = AdminLinks.resolve(status, app.boot.httpPort)
        if (link.url != footerUrl || footer.childCount == 0) {
            footerUrl = link.url
            footer.removeAllViews()
            footer.addView(
                AdminLinks.view(
                    activity, palette, app.core, link,
                    texts.t("web_admin.scan_hint", R.string.web_admin_scan_hint), 56,
                ),
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
            )
        }
        val power = status?.optJSONObject("self")?.optJSONObject("power")
        val line = ShellUi.versionLine(
            app.boot.name,
            status?.optJSONObject("node")?.optString("version").orEmpty()
                .ifEmpty { app.core.version() },
            appVersion(),
            power?.optInt("battery_pct", -1) ?: -1,
            power?.optBoolean("charging", false) ?: false,
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
        ) { seconds -> texts.t("sos.countdown", R.string.sos_countdown, seconds.toString()) }
        sosSlider.visibility = if (sosVisible()) View.VISIBLE else View.GONE
    }

    /**
     * emergency.button_on_roles decides whether this panel offers the slider at all. An absent
     * key is core's default of ["indoor_panel"]; an empty list is a deliberate "nowhere".
     */
    private fun sosVisible(): Boolean = SosSlideState.visibleForRole(config, app.boot.role)

    // ---------- door tiles ----------

    /**
     * Tiles are created once per door and then updated in place. Rebuilding them on every status
     * poll -- which is what this used to do -- inflated a card, an image view and two labels per
     * door several times a second, and that was the hitch on the home page.
     */
    private fun buildTiles() {
        val doors = tileDoorIds()
        if (tiles.keys.toList() != doors) {
            tileColumn.removeAllViews()
            tiles.clear()
            stills.clear()
            tileColumn.addView(
                ShellUi.sectionHeading(activity, palette,
                                       texts.t("settings.doors", R.string.settings_doors))
                    .also { doorsHeading = it },
                ShellUi.matchWrap(),
            )
            if (doors.isEmpty()) {
                tileColumn.addView(
                    ShellUi.text(activity, texts.t("dash.no_doors", R.string.dash_no_doors), 14f,
                                 palette.muted),
                    ShellUi.matchWrap(),
                )
                return
            }
            for (door in doors) {
                val tile = createTile(door)
                tiles[door] = tile
                stills[door] = tile.still
                tileColumn.addView(
                    tile.root,
                    ShellUi.matchWrap().apply { topMargin = ShellUi.dp(activity, 8) },
                )
            }
        }
        val nowMs = clock.cached().wallMs
        for ((door, tile) in tiles) updateTile(door, tile, NoticeModel.resolve(
            status, config, door, nowMs,
        ))
        // A focusable tile pulls the scroll view to itself on first layout, which hid the 門口
        // heading and clipped the first tile. Start at the top; the operator scrolls from there.
        if (!tilesScrolled) {
            tilesScrolled = true
            tileScroll.post { tileScroll.scrollTo(0, 0) }
        }
        fitTilesToViewport()
    }

    /** The parts that never change for a door. Called once. */
    /** The parts that never change for a door. Called once. */
    private fun createTile(door: String): DoorTile {
        val card = ShellUi.card(activity, palette)
        card.isFocusable = true
        card.isClickable = true
        card.setOnClickListener { IncomingActivity.launch(activity, door) }

        val still = ImageView(activity).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = ShellUi.rounded(activity, palette.surfaceAlt, 8)
            contentDescription = doorLabel(door)
        }
        // The still is the only part that may shrink; the label and chips keep their height.
        card.addView(
            still,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ShellUi.dp(activity, 120),
            ),
        )
        still.minimumHeight = ShellUi.dp(activity, 64)

        val chips = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, ShellUi.dp(activity, 6), 0, 0)
        }
        card.addView(chips, ShellUi.matchWrap())

        val caption = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isBaselineAligned = false
            setPadding(0, ShellUi.dp(activity, 6), 0, 0)
        }
        val label = ShellUi.text(activity, doorLabel(door), 16f, palette.ink, bold = true)
        // A tile label sits on the card surface, a different background from the ground.
        paintRegion(label, "tile_label", palette.surface, muted = false, cacheKey = null)
        caption.addView(
            label,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        caption.addView(ShellUi.text(
            activity, texts.t("dash.tile_open", R.string.dash_tile_open), 13f, palette.accent,
        ))
        card.addView(caption, ShellUi.matchWrap())

        val noticeText = ShellUi.text(activity, "", 13f, palette.muted).apply {
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
            visibility = View.GONE
            paintRegion(this, "notice", palette.surface, muted = true, cacheKey = null)
        }
        card.addView(noticeText, ShellUi.matchWrap())
        return DoorTile(card, still, chips, label, noticeText)
    }

    /** Everything a status poll can change, applied only when it actually changed. */
    private fun updateTile(door: String, tile: DoorTile, notice: Notice?) {
        val service = DoorStations.serviceOf(status, config, door)
        val noticeKey = notice?.text ?: ""
        if (tile.lastNotice == noticeKey && tile.lastService == service) return
        tile.lastNotice = noticeKey
        tile.lastService = service

        tile.label.text = doorLabel(door)
        tile.chips.removeAllViews()
        if (notice != null) {
            // A compact chip with a dot while an announcement is showing (§5.2).
            val chip = ShellUi.pill(
                activity, "● " + texts.t("notice.active", R.string.notice_active),
                palette.noticeBg, palette.noticeInk,
            )
            chip.isFocusable = true
            chip.isClickable = true
            chip.setOnClickListener { openNoticeDialog(door) }
            tile.chips.addView(chip)
        }
        // "The station is down" and "no station serves this door" are different problems with
        // different fixes, and core's served_by is what separates them.
        val serviceLabel = when (service) {
            DoorService.SERVED -> ""
            DoorService.STATION_OFFLINE ->
                texts.t("dash.tile_offline", R.string.dash_tile_offline)
            DoorService.NO_STATION ->
                texts.t("dash.tile_no_station", R.string.dash_tile_no_station)
        }
        if (serviceLabel.isNotEmpty()) tile.chips.addView(
            ShellUi.pill(activity, serviceLabel, palette.surfaceAlt, palette.muted),
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { leftMargin = if (tile.chips.childCount == 0) 0 else ShellUi.dp(activity, 6) },
        )
        tile.chips.visibility = if (tile.chips.childCount == 0) View.GONE else View.VISIBLE
        tile.noticeText.text = noticeKey
        tile.noticeText.visibility = if (notice != null) View.VISIBLE else View.GONE
    }

    /** Live stills refresh every five seconds; a failure simply leaves the previous frame. */
    /**
     * Refresh every tile's picture.
     *
     * The peer is resolved per door on each pass rather than captured with the tile, so a station
     * that joins after its tile was built starts showing a picture on the next tick instead of
     * staying blank until the door set changes. Each door is attempted independently: one station
     * that is down must not stop the loop before it reaches the others, which is why the body is
     * wrapped rather than relying on fetchStill alone to swallow everything.
     */
    private fun refreshStills() {
        if (stills.isEmpty()) return
        val targets = stills.keys.toList()
        val snapshot = status
        val settings = config
        Thread({
            for (door in targets) {
                try {
                    // Any station bound to this door, not only one the mesh calls alive: core
                    // omits the stream URL for a peer it has lost, so an unreachable station
                    // costs nothing here, while a station that is serving pictures over HTTP
                    // before the mesh has caught up still fills its tile.
                    val peer = DoorStations.peerFor(snapshot, settings, door)
                    if (peer == null) {
                        // Say which peers were considered and how each resolved: "no station" on
                        // its own cannot tell a door-id mismatch from a station that is down.
                        logStill(door, "no station; " + DoorStations.why(snapshot, settings, door))
                        continue
                    }
                    val url = DoorStations.stillUrl(peer)
                    if (url.isEmpty()) {
                        logStill(
                            door,
                            "station ${peer.optString("id")} (status " +
                                "${peer.optString("status")}) advertises no snapshot or stream",
                        )
                        continue
                    }
                    val bitmap = fetchStill(door, url) ?: continue
                    ui.post { stills[door]?.setImageBitmap(bitmap) }
                } catch (error: Exception) {
                    logStill(door, "failed: ${error.javaClass.simpleName}: ${error.message}")
                }
            }
        }, "doorbell-tiles").apply { isDaemon = true }.start()
    }

    /**
     * One still. Every outcome is logged with the URL, the HTTP status, the byte count and
     * whether the decode produced a bitmap.
     *
     * This used to swallow the exception silently, which is how a blocked request looked exactly
     * like a station with no camera: an empty tile and nothing at all in logcat.
     */
    private fun fetchStill(door: String, url: String): Bitmap? {
        var connection: HttpURLConnection? = null
        return try {
            connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = 2000
            connection.readTimeout = 3000
            connection.useCaches = false
            val code = connection.responseCode
            if (code != HttpURLConnection.HTTP_OK) {
                logStill(door, "$url -> HTTP $code")
                return null
            }
            val bytes = BoundedBitmapDecoder.readLimited(connection.inputStream, 2 * 1024 * 1024)
            if (bytes == null) {
                logStill(door, "$url -> HTTP $code, body empty or over the 2 MB cap")
                return null
            }
            val bitmap = BoundedBitmapDecoder.decode(bytes, 640, 480)
            logStill(
                door,
                "$url -> HTTP $code, ${bytes.size} bytes, " +
                    if (bitmap == null) "decode failed"
                    else "decoded ${bitmap.width}x${bitmap.height}",
            )
            bitmap
        } catch (error: Exception) {
            // A cleartext-policy refusal arrives here as an IOException naming the peer address.
            logStill(door, "$url -> ${error.javaClass.simpleName}: ${error.message}")
            null
        } finally {
            try { connection?.disconnect() } catch (_: Exception) { }
        }
    }

    private fun logStill(door: String, message: String) {
        android.util.Log.i("doorbell-still", "[$door] $message")
    }

    // ---------- recent calls ----------

    private fun loadCalls() {
        if (!app.coreOk) return
        Thread({
            val document = app.core.callLog(0L, 0L, CallHistoryModel.DASHBOARD_ROWS)
            val rows = CallHistoryModel.parse(document)
            val missed = CallHistoryModel.unreadMissed(document)
            ui.post {
                lastRows = rows
                unreadMissed = missed
                updateHeader()
                renderCalls()
            }
        }, "doorbell-dashboard-calls").apply { isDaemon = true }.start()
    }

    private fun renderCalls() {
        callList.removeAllViews()
        if (lastRows.isEmpty()) {
            callList.addView(
                ShellUi.text(activity, texts.t("history.empty", R.string.history_empty), 14f,
                             palette.muted),
                ShellUi.matchWrap(),
            )
            return
        }
        for (row in lastRows.take(CallHistoryModel.DASHBOARD_ROWS)) {
            val line = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                isBaselineAligned = false
                minimumHeight = ShellUi.dp(activity, ShellUi.TOUCH_FLOOR_DP)
                setPadding(0, ShellUi.dp(activity, 4), 0, ShellUi.dp(activity, 4))
            }
            val time = clock.format(row.tsMs)
            line.addView(
                ShellUi.text(activity,
                             String.format(Locale.US, "%02d:%02d", time.hour, time.minute),
                             12.5f, palette.muted),
                LinearLayout.LayoutParams(
                    ShellUi.dp(activity, 44), ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
            val label = StringBuilder(doorLabel(row.door))
            if (row.purpose.isNotEmpty()) label.append(" · ").append(purposeLabel(row.purpose))
            line.addView(
                ShellUi.text(activity, label.toString(), 13.5f,
                             if (row.missed) palette.dangerInk else palette.ink),
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
            )
            line.addView(ShellUi.text(activity, outcomeText(row), 12.5f, palette.muted))
            callList.addView(line, ShellUi.matchWrap())
        }
    }

    private fun outcomeText(row: CallRow): String = when (row.outcome) {
        "missed" -> texts.t("history.outcome_missed", R.string.history_outcome_missed)
        "answered" -> texts.t("history.outcome_answered", R.string.history_outcome_answered)
        "replied" -> texts.t("history.outcome_replied", R.string.history_outcome_replied)
        else -> texts.t("history.outcome_cancelled", R.string.history_outcome_cancelled)
    }

    // ---------- layout ----------

    /** Portrait stacks tiles above the call list; landscape puts them side by side. */
    private fun applyArrangement() {
        val metrics = activity.resources.displayMetrics
        val widthDp = (metrics.widthPixels / metrics.density).toInt()
        val heightDp = (metrics.heightPixels / metrics.density).toInt()
        val side = widthDp > heightDp && widthDp >= 600
        bodySplit.orientation = if (side) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
        val tileParams = tileScroll.layoutParams as LinearLayout.LayoutParams
        val callParams = callColumn.layoutParams as LinearLayout.LayoutParams
        if (side) {
            tileParams.width = 0
            tileParams.height = ViewGroup.LayoutParams.MATCH_PARENT
            tileParams.weight = 1.1f
            callParams.width = 0
            callParams.height = ViewGroup.LayoutParams.MATCH_PARENT
            callParams.weight = 1f
            callParams.leftMargin = ShellUi.dp(activity, 12)
        } else {
            tileParams.width = ViewGroup.LayoutParams.MATCH_PARENT
            tileParams.height = ViewGroup.LayoutParams.WRAP_CONTENT
            tileParams.weight = 0f
            callParams.width = ViewGroup.LayoutParams.MATCH_PARENT
            callParams.height = 0
            callParams.weight = 1f
            callParams.leftMargin = 0
        }
        tileScroll.layoutParams = tileParams
        callColumn.layoutParams = callParams
        applyHeaderLayout(widthDp, heightDp)
        applyActionLayout(widthDp)
        fitTilesToViewport()
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
        val countersParams = countersRow.layoutParams as LinearLayout.LayoutParams
        if (stacked) {
            clockParams.width = ViewGroup.LayoutParams.MATCH_PARENT
            clockParams.weight = 0f
            actionParams.width = ViewGroup.LayoutParams.MATCH_PARENT
            actionParams.topMargin = ShellUi.dp(activity, 8)
            // The counters absorb the row's slack; they never need to shrink.
            countersParams.width = ViewGroup.LayoutParams.WRAP_CONTENT
            countersParams.weight = 1f
            countersParams.leftMargin = 0
        } else {
            clockParams.width = 0
            clockParams.weight = 1f
            actionParams.width = ViewGroup.LayoutParams.WRAP_CONTENT
            actionParams.topMargin = 0
            countersParams.width = ViewGroup.LayoutParams.WRAP_CONTENT
            countersParams.weight = 0f
            countersParams.leftMargin = ShellUi.dp(activity, 8)
        }
        clockBox.layoutParams = clockParams
        headerActions.layoutParams = actionParams
        countersRow.layoutParams = countersParams
    }

    private fun applyStillHeight(heightPx: Int) {
        for (tile in tiles.values) {
            val params = tile.still.layoutParams ?: continue
            if (params.height == heightPx) continue
            params.height = heightPx
            tile.still.layoutParams = params
        }
    }

    /**
     * Size the preview so a whole tile fits in the space above the QR footer.
     *
     * The tile column is already constrained to end above the footer, but a tile taller than that
     * area left its bottom row -- the door name and 見る -- cut off at the scroll boundary, which
     * reads as the label disappearing under the footer. The still is the only part that may give
     * up height, so it is measured against the real viewport instead of guessed per orientation.
     * More doors than fit still scroll, but every row is whole.
     */
    private fun fitTilesToViewport() {
        val tile = tiles.values.firstOrNull() ?: return
        tileScroll.post {
            val viewport = tileScroll.height
            if (viewport <= 0 || tile.still.layoutParams == null) return@post
            val card = tile.root
            var others = card.paddingTop + card.paddingBottom
            for (index in 0 until card.childCount) {
                val child = card.getChildAt(index)
                if (child === tile.still || child.visibility == View.GONE) continue
                others += child.height +
                    ((child.layoutParams as? LinearLayout.LayoutParams)?.topMargin ?: 0)
            }
            // The section heading shares the column, and each tile carries a top margin.
            val heading = if (tileColumn.childCount > 0) tileColumn.getChildAt(0).height else 0
            applyStillHeight(VisitorLayout.tileStillHeightPx(
                viewportPx = viewport,
                headingPx = heading,
                otherRowsPx = others,
                gapPx = ShellUi.dp(activity, 16),
                minPx = ShellUi.dp(activity, 56),
                maxPx = ShellUi.dp(activity, 160),
            ))
        }
    }

    /**
     * On a narrow panel the announcement button and the SOS slider stack instead of halving each
     * other's width, so neither the two-part slider label nor the button text is clipped.
     */
    private fun applyActionLayout(widthDp: Int) {
        val stacked = VisitorLayout.actionsStacked(widthDp)
        actionRow.orientation = if (stacked) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
        val noticeParams = noticeButton.layoutParams as LinearLayout.LayoutParams
        val sosParams = sosSlider.layoutParams as LinearLayout.LayoutParams
        if (stacked) {
            noticeParams.width = ViewGroup.LayoutParams.MATCH_PARENT
            noticeParams.weight = 0f
            sosParams.width = ViewGroup.LayoutParams.MATCH_PARENT
            sosParams.weight = 0f
            sosParams.leftMargin = 0
            sosParams.topMargin = ShellUi.dp(activity, 8)
        } else {
            noticeParams.width = 0
            noticeParams.weight = 1f
            sosParams.width = 0
            sosParams.weight = 1f
            sosParams.leftMargin = ShellUi.dp(activity, 8)
            sosParams.topMargin = 0
        }
        noticeButton.layoutParams = noticeParams
        sosSlider.layoutParams = sosParams
    }

    // ---------- helpers ----------

    private fun openNoticeDialog(door: String) {
        NoticeDialog.show(activity, app, texts, palette, door, doorIds(), ::doorLabel) {
            refresh()
        }
    }

    /** Every configured door. The announcement dialog and the monitor list use all of them. */
    private fun doorIds(): List<String> {
        val doors = app.core.dig(config, "doors") as? JSONObject ?: return emptyList()
        return doors.keys().asSequence().sorted().toList()
    }

    /**
     * The doors that get a tile. A tile is a picture and a the label action, so a station that reports
     * caps.camera false is left out of the column -- there is nothing to show and nothing to
     * watch. The door itself stays reachable everywhere it matters: the monitor list, the
     * announcement dialog, and unlock all still address it.
     */
    private fun tileDoorIds(): List<String> =
        doorIds().filter { DoorStations.tileVisible(status, config, it) }

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
        const val STILL_INTERVAL_MS = 5_000L
        val WEEKDAYS = arrayOf("日", "月", "火", "水", "木", "金", "土")
    }
}
