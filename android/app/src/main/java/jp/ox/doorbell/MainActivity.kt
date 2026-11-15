// Door-station UI state machine driven by versioned Core events. Device Owner installations use
// lock-task mode; themes, visitor languages, and purposes are resolved from fleet configuration.
package jp.ox.doorbell

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.WindowManager
import android.view.animation.AlphaAnimation
import android.view.animation.Animation
import android.widget.Button
import android.widget.GridLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import java.io.File
import java.net.HttpURLConnection
import java.util.Calendar
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : ShellActivity(), DoorbellCore.Listener {

    private val ui = Handler(Looper.getMainLooper())
    private lateinit var app: App
    private lateinit var texts: Texts

    private lateinit var rootView: View
    private lateinit var themeBg: ImageView
    private lateinit var nightTint: View
    private lateinit var idleView: View
    private lateinit var visitorShell: View
    private lateinit var idleHeader: View
    private lateinit var callSection: View
    private lateinit var clockText: TextView
    private lateinit var dateText: TextView
    private lateinit var callButton: Button
    private lateinit var touchHint: TextView
    private lateinit var visitorStatus: TextView
    private lateinit var nodeInfo: TextView
    private lateinit var pairingBanner: TextView
    private lateinit var purposeSection: View
    private lateinit var purposeHint: TextView
    private lateinit var purposeAutoHint: TextView
    private lateinit var purposeGrid: GridLayout
    private lateinit var purposeSkipButton: Button
    private lateinit var purposeCancelButton: Button
    private lateinit var langBar: LinearLayout
    private lateinit var callingView: View
    private lateinit var callingText: TextView
    private lateinit var cancelButton: Button
    private lateinit var pulse: View
    private lateinit var replyBanner: View
    private lateinit var replyText: TextView
    private lateinit var replyScroll: View
    private lateinit var replyHint: TextView
    private lateinit var replyCount: TextView
    private lateinit var offlineView: View
    private lateinit var offlineTitle: TextView
    private lateinit var offlineBody: TextView
    private lateinit var dashboardHost: android.widget.FrameLayout
    private lateinit var visitorSplit: LinearLayout
    private lateinit var visitorColumnA: LinearLayout
    private lateinit var visitorColumnB: LinearLayout
    private lateinit var noticeCard: TextView
    private lateinit var visitorFooter: LinearLayout
    private lateinit var sosSlot: android.widget.FrameLayout
    private lateinit var sosSlider: SosTriggerView
    private lateinit var clusterClock: ClusterClock
    private lateinit var airIndicator: AirQualityIndicator
    private var airReading = AirQualityReading.HIDDEN
    private var airLoading = false
    private var airPermissionsAsked = false
    // Core hints on every change; the minute tick only keeps a stale/fresh boundary honest.
    private val airTick = object : Runnable {
        override fun run() {
            refreshAirQuality()
            ui.postDelayed(this, AIR_REFRESH_MS)
        }
    }

    /** Present only on an indoor panel; the door station never builds a dashboard. */
    private var dashboard: DashboardView? = null

    /** Resolved appearance for this screen; recomputed on every config or time change. */
    private var palette: Palette = Palette.DARK

    private var lastClockText = ""
    private var lastClockDate = ""
    private var membershipRenderKey = ""

    /** Appearance and automatic theme as core published them; null on an older core. */
    private var coreDisplay: CoreDisplay = CoreDisplay(null, null)

    /** The latest status snapshot, which carries the resolved notice, unlock, and display. */
    private var statusSnapshot: JSONObject? = null

    /** Home-screen refresh coalescing; see [HomeRefreshPolicy]. */
    private var homeRefreshRunMs = 0L
    private var homeRefreshQueued = false
    private var homeRefreshWantsConfig = false
    private var homeRefreshWantsFullRender = false
    private var homeRefreshWantsCalls = false
    private val homeRefreshTick = Runnable { runHomeRefresh() }

    /** Where the coalesced refresh reads core, so the main thread never waits on the run loop. */
    private var homeThread: HandlerThread? = null
    private var homeHandler: Handler? = null

    private lateinit var speech: ShellSpeech
    private lateinit var purposePanel: VisitorPurposePanel
    private lateinit var flowPanel: VisitorFlowPanel
    private lateinit var flowContent: LinearLayout
    private lateinit var flowDock: LinearLayout
    private lateinit var languageBar: VisitorLanguageBar

    private var secretTaps = 0
    private var secretFirstMs = 0L
    private var adminUnlocked = false

    // Theme, visitor language, purpose, and custom-audio state.
    private var cfg: JSONObject? = null
    private var nodeId = ""
    private var visitorLang = "ja"
    private var choosingPurpose = false
    private lateinit var backdrop: VisitorBackdrop
    private var resumed = false
    private val audio by lazy(LazyThreadSafetyMode.NONE) { ShellAudio(this) }
    private var callTitleOverride: String? = null

    /** The walker over Core's resolved visitor flow; null shows the classic purpose screen. */
    private var flowWalker: FlowWalker? = null

    /** Set once Core has answered whether a flow exists; until then the home shows no controls. */
    private var flowResolved = false
    private var flowGaveUp = false
    private var layoutCompact = false
    private val flowGate = ReloadGate()
    private var flowEndReason = "ended"
    private var flowBusy = false
    private var flowPendingToken = 0
    private val flowStatusTick = Runnable { flowPendingStatus() }
    private val flowTimeoutTick = Runnable { flowPendingFailed() }
    private val flowIdleTick = Runnable { flowIdleElapsed() }
    private var callFlowMode = CallFlowMode.PURPOSE_FIRST
    private var callUiPhase = CallUiPhase.IDLE
    private var uiCallId = ""
    private var uiCallStageRevision = 0
    private var uiCallExpiresAtMs = 0L

    // UI timers.
    private val clockTick = object : Runnable {
        override fun run() { updateClock(); ui.postDelayed(this, 1000) }
    }
    private val callTimeout = object : Runnable {
        override fun run() {
            val transition = app.callFlow.timeout()
            if (transition.phase == CallUiPhase.IDLE) {
                clearCallProjection()
                flowEndReason = "timeout"
                showIdle(if (flowWalker != null) null
                         else texts.t("calling.no_answer", R.string.calling_no_answer))
            } else {
                applyCallProjection(transition)
                scheduleCallTimeout()
            }
        }
    }
    /** When the visitor's purpose choice times out, on the elapsed-realtime clock. */
    private var purposeDeadlineElapsedMs = 0L
    private val purposeTimeout = Runnable {
        if (!choosingPurpose) return@Runnable
        if (uiCallId.isNotEmpty()) continueWithoutPurpose(false)
        else {
            app.callFlow.finishLocal()
            clearCallProjection()
            showIdle()
        }
    }
    private var replyGuard: ReplyDismissGuard? = null
    private var replyShownAt = 0L
    private var replyTtlMs = 30_000L
    private val replyTick = object : Runnable {
        override fun run() {
            val guard = replyGuard
            if (replyBanner.visibility != View.VISIBLE || guard == null) return
            val now = SystemClock.elapsedRealtime()
            val left = replyTtlMs - (now - replyShownAt)
            if (left <= 0) { dismissReply(); return }
            replyCount.text = ((left + 999) / 1000).toString()
            when (guard.hint(now)) {
                ReplyDismissGuard.Hint.NONE -> replyHint.text = ""
                ReplyDismissGuard.Hint.EXIT -> {
                    replyHint.text = texts.t("reply.exit_hint", R.string.reply_exit_hint)
                    replyHint.setTypeface(null, Typeface.NORMAL)
                    replyHint.background = null
                }
                ReplyDismissGuard.Hint.CONFIRM -> {
                    replyHint.text = texts.t("reply.exit_confirm", R.string.reply_exit_confirm)
                    replyHint.setTypeface(null, Typeface.BOLD)
                    replyHint.background = ShellUi.rounded(this@MainActivity, palette.surface, 14, palette.accent)
                }
            }
            ui.postDelayed(this, 250)
        }
    }

    private fun replyTap() {
        val guard = replyGuard ?: return
        if (guard.tap(SystemClock.elapsedRealtime()) == ReplyDismissGuard.Tap.CLOSE) dismissReply()
        else { ui.removeCallbacks(replyTick); replyTick.run() }
    }

    private fun dismissReply() {
        ui.removeCallbacks(replyTick)
        replyGuard = null
        replyBanner.visibility = View.GONE
        flowWalker?.apply(FlowEvent.Reply(false))
    }

    private fun fitReply() {
        val box = replyScroll
        val text = replyText.text
        val width = box.width
        val height = box.height
        if (width <= 0 || height <= 0 || text.isEmpty()) return
        val paint = TextPaint(replyText.paint)
        val floor = (28 * resources.displayMetrics.density).toInt()
        val spacing = 1.15f
        val result = ReplyFit.fit(width, height, floor, maxOf(floor, height)) { size ->
            paint.textSize = size.toFloat()
            @Suppress("DEPRECATION")
            val layout = StaticLayout(text, paint, width, Layout.Alignment.ALIGN_CENTER, spacing, 0f, false)
            var widest = 0f
            for (i in 0 until layout.lineCount) widest = maxOf(widest, layout.getLineWidth(i))
            ReplyFit.Extent(Math.ceil(widest.toDouble()).toInt(), layout.height)
        }
        replyText.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, result.sizePx.toFloat())
    }
    private var setupLaunchRequested = false
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        if (app.bootSetupRequired) {
            setupLaunchRequested = true
            startActivity(android.content.Intent(this, BootSetupActivity::class.java))
        }
        texts = Texts(this)
        clusterClock = ClusterClock(app.core)
        visitorLang = app.boot.uiLang
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        buildContent()

        val worker = HandlerThread("doorbell-home", Process.THREAD_PRIORITY_BACKGROUND)
        worker.start()
        homeThread = worker
        homeHandler = Handler(worker.looper)

        refreshConfigCache()
        texts.setLang(visitorLang)
        applyStrings()

        speech = ShellSpeech(this)

        requestPermissionsIfNeeded()

        // The foreground registration itself happens in onResume so a screen opened above this
        // one (pairing, maintenance) can never leave the main UI without Core events.
        if (!app.coreOk) showOffline() else restoreCurrentCallUi()
        refreshNodeInfo()
        restoreRequestedCall(intent)
        fetchFlow()
        ui.postDelayed({ playLaunchSound() }, 350)
    }

    /**
     * Inflate the screen and wire its controls. Runs again when the appearance changes, because
     * a view keeps the theme it was built with.
     */
    private fun buildContent() {
        setContentView(R.layout.activity_main)
        bindViews()
        airIndicator = AirQualityIndicator(this, TextView(this).apply { textSize = 15f })
        (idleHeader as LinearLayout).addView(airIndicator.root, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dp(4) })
        backdrop = VisitorBackdrop(this, app, rootView, themeBg, nightTint, ui,
            config = { cfg }, nodeId = { nodeId }, palette = { palette },
            coreDisplay = { coreDisplay },
            inkRegions = {
                listOf(
                    InkRegion(clockText, "clock", false), InkRegion(dateText, "date", true),
                    InkRegion(touchHint, "hint", true), InkRegion(nodeInfo, "footer", true),
                    InkRegion(airIndicator.label, "air", airReading.dimmed),
                )
            })
        purposePanel = VisitorPurposePanel(this, purposeGrid) { id, label -> onPurposeClick(id, label) }
        languageBar = VisitorLanguageBar(this, langBar) { lang -> onLangClick(lang) }
        flowPanel = VisitorFlowPanel(
            this, flowContent, flowDock, ui,
            viewportHeightPx = { rootView.height.takeIf { it > 0 } ?: resources.displayMetrics.heightPixels },
            onOption = { id -> onFlowOption(id) },
            onBack = { onFlowBack() },
            onDone = { onFlowDone() },
        )
        dashboard = null
        installRoleHome()
        renderAirQuality()
        membershipRenderKey = ""
        lastClockText = ""
        lastClockDate = ""
        (pulse as android.view.ViewGroup).addView(PlatformUi.progress(this))

        callButton.setOnClickListener { onCallClick() }
        purposeSkipButton.setOnClickListener { continueWithoutPurpose(true) }
        bindCallAction(purposeCancelButton)
        bindCallAction(cancelButton)
        sosSlider.enabledProvider = { app.coreOk }
        sosSlider.onTrigger = { app.commitEmergency(true) }
        // Hidden maintenance entry: seven taps in the top-right corner within five seconds.
        // This is the door station's only route to settings; nothing about it is visible.
        findViewById<View>(R.id.secret_corner).setOnClickListener { playButtonSound(); onSecretCorner() }
        pairingBanner.setOnClickListener {
            app.resumePairingSetup()
            PairingActivity.launch(this)
        }
    }

    /**
     * Core's appearance flipped while the home screen is up. The home screen is rebuilt in place
     * rather than recreated: a visitor call in progress, the chime and the audio all carry on.
     */
    override fun onAppearanceChanged() {
        if (!::app.isInitialized || isFinishing) return
        dashboard?.onPause()
        stopRegionInkWatch()
        sosSlider.cancelCountdown()
        pulse.clearAnimation()
        buildContent()
        if (!app.coreOk) showOffline() else restoreCurrentCallUi()
        refreshNodeInfo()
        if (resumed) {
            dashboard?.onResume()
            applyVisitorLayout()
            startRegionInkWatch()
        }
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        restoreRequestedCall(intent)
    }

    override fun onResume() {
        super.onResume()
        if (app.bootSetupRequired) {
            if (!setupLaunchRequested) {
                setupLaunchRequested = true
                startActivity(android.content.Intent(this, BootSetupActivity::class.java))
            }
            return
        }
        setupLaunchRequested = false
        resumed = true
        // Re-register on every resume: a pairing or maintenance screen closing above this one
        // must hand the event stream back, or chimes and display events are lost until restart.
        app.bindForeground(this)
        // Keep unenrolled devices in the pairing flow. The pairing document is read off the main
        // thread: core may be holding its run loop (SQLite, sync) and the visitor screen must not
        // freeze while it answers.
        checkPairingAsync {
            // Core may have come up while onboarding covered this screen; the offline pane shown
            // at creation must not outlive it.
            if (app.coreOk && offlineView.visibility == View.VISIBLE) restoreCurrentCallUi()
        }
        enterImmersive()
        ui.post(clockTick)
        ui.removeCallbacks(airTick)
        ui.post(airTick)
        requestAirSensorPermissions()
        if (choosingPurpose) {
            // Resume the remaining choice time; a pause must not restart the full window.
            val remaining = purposeDeadlineElapsedMs - SystemClock.elapsedRealtime()
            if (remaining <= 0L) ui.post(purposeTimeout)
            else ui.postDelayed(purposeTimeout, remaining)
        }
        enterKioskIfConfigured()
        maybeStartCamera()
        dashboard?.onResume()
        applyVisitorLayout()
        startRegionInkWatch()
        fetchFlow()
        if (flowWalker != null && flowPanel.visible) scheduleFlowTimer()
    }

    /**
     * Opens onboarding until Core reports "ready" and the shell holds its own durable secure
     * reference. Once the operator chose "set up later" the main UI stays visible and only the
     * banner remains, so there is no relaunch loop.
     */
    private fun checkPairingAsync(onReady: () -> Unit = {}) {
        val worker = homeHandler
        if (!app.coreOk || worker == null) {
            onReady()
            return
        }
        val generation = app.runtime.coreGeneration
        worker.post {
            val pairing = app.core.pairingInfo()
            val ready = app.pairingReadyFrom(pairing)
            ui.post {
                if (isFinishing || !app.runtime.isCurrentGeneration(generation)) return@post
                if (pairing != null && !ready && !app.pairingDeferred) {
                    PairingActivity.launch(this)
                    return@post
                }
                renderMembership(pairing, ready)
                onReady()
            }
        }
    }

    /**
     * Membership status replaces the raw node identifier, and opens the Add-device panel.
     *
     * Reads core here, so it belongs to the one-shot paths: resume, and core reporting ready. The
     * event stream goes through [scheduleHomeRefresh], which reads pairing off the main thread and
     * renders through [renderMembership].
     */
    private fun refreshMembership() {
        val worker = homeHandler
        if (!app.coreOk || worker == null) {
            renderMembership(null, false)
            return
        }
        worker.post {
            val pairing = app.core.pairingInfo()
            val ready = app.pairingReadyFrom(pairing)
            ui.post { if (!isFinishing) renderMembership(pairing, ready) }
        }
    }

    /** "0.2.0+<40 hex>" as "0.2.0+<7 hex>": the caption is one quiet line. */
    private fun shortRevision(version: String): String {
        val plus = version.indexOf('+')
        return if (plus < 0 || version.length - plus - 1 <= 7) version else version.substring(0, plus + 8)
    }

    /** Render the membership pill and the pairing banner from an already-read pairing document. */
    private fun renderMembership(pairing: JSONObject?, ready: Boolean) {
        val membershipText = if (!ready) {
            texts.t("pair.not_set_up_banner", R.string.pair_not_set_up_banner)
        } else if (dashboard != null) {
            listOf(
                texts.t("pair.membership", R.string.pair_membership,
                        PairingModel.memberCount(pairing).toString()),
                texts.t("pair.membership_connected", R.string.pair_membership_connected,
                        PairingModel.connectedCount(pairing).toString()),
            ).joinToString(" · ")
        } else {
            val status = statusSnapshot
            val power = status?.optJSONObject("self")?.optJSONObject("power")
            ShellUi.versionLine(
                doorLabel(app.boot.door).ifEmpty { app.boot.name },
                shortRevision(status?.optJSONObject("node")?.optString("version").orEmpty()
                    .ifEmpty { app.core.version() }),
                appVersionName(),
                power?.optInt("battery_pct", -1) ?: -1,
                power?.optBoolean("charging", false) ?: false,
                texts.t("power.charging", R.string.power_charging),
            ) { texts.t("power.percent", R.string.power_percent, it.toString()) }
        }
        val renderKey = "${if (ready) 1 else 0}:$membershipText"
        if (renderKey == membershipRenderKey) return
        membershipRenderKey = renderKey
        pairingBanner.visibility = if (ready) View.GONE else View.VISIBLE
        if (!ready) {
            pairingBanner.text = membershipText
            nodeInfo.text = membershipText
            return
        }
        nodeInfo.text = membershipText
    }

    private fun appVersionName(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName.orEmpty()
    } catch (_: Exception) {
        ""
    }

    /**
     * Everything behind the admin password: settings (which holds the Change role form, so a door
     * station can become an indoor panel), information, adding devices, kiosk exit.
     */
    private fun showMaintenanceMenu() {
        val labels = arrayOf<CharSequence>(
            texts.t("settings.title", R.string.settings_title),
            texts.t("admin.menu_info", R.string.admin_menu_info),
            texts.t("admin.menu_add_device", R.string.admin_menu_add_device),
            texts.t("admin.menu_exit_kiosk", R.string.admin_menu_exit_kiosk),
        )
        ShellDialogBuilder(this)
            .setTitle(texts.t("admin.menu_title", R.string.admin_menu_title))
            .setItems(labels) { _, which ->
                when (which) {
                    0 -> SettingsActivity.open(this, app, texts)
                    1 -> DeviceInfoActivity.launch(this)
                    2 -> openAddDevice()
                    3 -> exitKiosk()
                }
            }
            .setNegativeButton(texts.t("admin.menu_close", R.string.admin_menu_close), null)
            .show()
    }

    private fun openAddDevice() {
        if (app.pairingReady()) AddDeviceActivity.launch(this)
        else {
            app.resumePairingSetup()
            PairingActivity.launch(this)
        }
    }

    private fun exitKiosk() {
        adminUnlocked = true
        app.runtime.kioskController.leaveForMaintenance(this)
        finish()
    }

    override fun onPause() {
        // Leaving with setup still required must re-open setup on the next resume;
        // otherwise backing out of first-run setup strands the operator on an empty screen.
        setupLaunchRequested = false
        resumed = false
        dismissReply()
        ui.removeCallbacks(clockTick)
        ui.removeCallbacks(airTick)
        ui.removeCallbacks(purposeTimeout)
        ui.removeCallbacks(flowIdleTick)
        ui.removeCallbacks(homeRefreshTick)
        homeRefreshQueued = false
        homeRefreshWantsFullRender = false
        homeRefreshWantsCalls = false
        dashboard?.onPause()
        stopRegionInkWatch()
        if (::sosSlider.isInitialized) sosSlider.cancelCountdown()
        app.unbindForeground(this)
        super.onPause()
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        applyVisitorLayout()
        buildPurposeButtons()
        if (flowWalker != null && flowPanel.visible) showIdle()
        dashboard?.onConfigurationChanged()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersive()
    }

    override fun onDestroy() {
        ui.removeCallbacks(homeRefreshTick)
        ui.removeCallbacks(airTick)
        homeThread?.quit()
        homeThread = null
        homeHandler = null
        app.unbindForeground(this)
        if (::speech.isInitialized) speech.shutdown()
        stopRinging()
        audio.releaseAll()
        super.onDestroy()
    }

    @Deprecated("kiosk 中は戻れない")
    override fun onBackPressed() {
        val walker = flowWalker
        if (walker != null && flowPanel.visible && walker.snapshot().back) {
            onFlowBack()
            return
        }
        if (choosingPurpose) {
            if (uiCallId.isNotEmpty()) cancelActiveCall("visitor")
            else {
                app.callFlow.finishLocal()
                clearCallProjection()
                showIdle()
            }
            return
        }
        if (!app.boot.kiosk || adminUnlocked) super.onBackPressed()
    }

    private fun bindViews() {
        rootView = findViewById(R.id.root_view)
        themeBg = findViewById(R.id.theme_bg)
        nightTint = findViewById(R.id.night_tint)
        idleView = findViewById(R.id.idle_view)
        visitorShell = findViewById(R.id.visitor_shell)
        idleHeader = findViewById(R.id.idle_header)
        callSection = findViewById(R.id.call_section)
        clockText = findViewById(R.id.clock_text)
        dateText = findViewById(R.id.date_text)
        callButton = findViewById(R.id.call_button)
        touchHint = findViewById(R.id.touch_hint)
        visitorStatus = findViewById(R.id.visitor_status)
        nodeInfo = findViewById(R.id.node_info)
        pairingBanner = findViewById(R.id.pairing_banner)
        purposeSection = findViewById(R.id.purpose_section)
        purposeHint = findViewById(R.id.purpose_hint)
        purposeAutoHint = findViewById(R.id.purpose_auto_hint)
        purposeGrid = findViewById(R.id.purpose_grid)
        flowContent = findViewById(R.id.flow_content)
        flowDock = findViewById(R.id.flow_dock)
        purposeSkipButton = findViewById(R.id.purpose_skip_button)
        purposeCancelButton = findViewById(R.id.purpose_cancel_button)
        langBar = findViewById(R.id.lang_bar)
        callingView = findViewById(R.id.calling_view)
        callingText = findViewById(R.id.calling_text)
        cancelButton = findViewById(R.id.cancel_button)
        pulse = findViewById(R.id.pulse)
        replyBanner = findViewById(R.id.reply_banner)
        replyText = findViewById(R.id.reply_text)
        replyScroll = findViewById(R.id.reply_scroll)
        replyHint = findViewById(R.id.reply_hint)
        replyCount = findViewById(R.id.reply_count)
        val replyPad = ((if (resources.configuration.smallestScreenWidthDp >= 600) 24 else 16) *
            resources.displayMetrics.density).toInt()
        replyBanner.setPadding(replyPad, replyPad, replyPad, replyPad)
        replyBanner.setOnClickListener { replyTap() }
        replyScroll.addOnLayoutChangeListener { v, l, t, r, b, ol, ot, or2, ob ->
            if (r - l != or2 - ol || b - t != ob - ot) fitReply()
        }
        offlineView = findViewById(R.id.offline_view)
        offlineTitle = findViewById(R.id.offline_title)
        offlineBody = findViewById(R.id.offline_body)
        dashboardHost = findViewById(R.id.dashboard_host)
        visitorSplit = findViewById(R.id.visitor_split)
        visitorColumnA = findViewById(R.id.visitor_col_a)
        visitorColumnB = findViewById(R.id.visitor_col_b)
        noticeCard = findViewById(R.id.notice_card)
        visitorFooter = findViewById(R.id.visitor_footer)
        sosSlot = findViewById(R.id.sos_slot)
        sosSlider = SosTriggerView(this, ui)
        sosSlot.addView(
            sosSlider,
            android.widget.FrameLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
    }

    // Full-screen kiosk behavior.

    @Suppress("DEPRECATION")
    private fun enterImmersive() {
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
            View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
    }

    private fun enterKioskIfConfigured() {
        if (!adminUnlocked) app.runtime.kioskController.enter(this)
    }

    // Clock.

    /**
     * Every clock comes from core's cluster time, so the configured time zone and core's own NTP
     * correction apply without ever touching the operating-system clock.
     */
    private fun updateClock() {
        dashboard?.let {
            it.tickClock()
            return
        }
        clusterClock.refreshIfStale()
        val now = clusterClock.cached()
        // Once a second, so only touch the views when the rendered value actually changed.
        val clockValue = now.clockText()
        if (clockValue != lastClockText) {
            lastClockText = clockValue
            clockText.text = clockValue
        }
        val dateValue = texts.dateLine(now)
        if (dateValue == lastClockDate) return
        lastClockDate = dateValue
        dateText.text = dateValue
    }

    /** Read the PM2.5 document off the main thread; at most one read in flight. */
    private fun refreshAirQuality() {
        val worker = homeHandler
        if (!app.coreOk || worker == null || airLoading) return
        airLoading = true
        val generation = app.runtime.coreGeneration
        worker.post {
            val reading = AirQualityModel.parse(app.core.airQuality())
            ui.post {
                airLoading = false
                if (isFinishing || !app.runtime.isCurrentGeneration(generation)) return@post
                airReading = reading
                renderAirQuality()
            }
        }
    }

    private fun renderAirQuality() {
        dashboard?.let {
            it.setAirQuality(airReading)
            return
        }
        if (airIndicator.render(airReading, texts, palette.line)) scheduleRegionInk()
    }

    /** An indoor panel replaces the visitor screen with the dashboard; a door station keeps it. */
    private fun installRoleHome() {
        if (app.boot.role != "indoor_panel") return
        val view = DashboardView(this, app, texts, ui)
        dashboard = view
        dashboardHost.addView(
            view.root,
            android.widget.FrameLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        dashboardHost.visibility = View.VISIBLE
        visitorShell.visibility = View.GONE
        idleView.visibility = View.GONE
        // The hidden 7-tap corner is the door station's only way into settings. An indoor panel
        // has a visible 管理 button, and the invisible 200 dp target sat on top of the dashboard's
        // header, swallowing taps meant for 管理 and すべて見る.
        findViewById<View>(R.id.secret_corner).visibility = View.GONE
    }

    /**
     * Lay the visitor screen out for the current window and paint the parts that follow the
     * appearance and the effective announcement.
     */
    private fun applyVisitorLayout() {
        if (dashboard != null) return
        val metrics = resources.displayMetrics
        val widthDp = (metrics.widthPixels / metrics.density).toInt()
        val heightDp = (metrics.heightPixels / metrics.density).toInt()
        val notice = NoticeModel.resolve(
            statusSnapshot, cfg, app.boot.door, clusterClock.now().wallMs,
        )
        noticeCard.text = notice?.text.orEmpty()
        noticeCard.visibility = if (notice != null) View.VISIBLE else View.GONE
        noticeCard.background = ShellUi.rounded(this, palette.noticeBg, 12, palette.noticeLine)
        noticeCard.setTextColor(ShellUi.opaque(palette.noticeInk))
        val compact = flowHome()
        layoutCompact = compact
        clockText.textSize = if (compact) VisitorLayout.COMPACT_CLOCK_SP
            else VisitorLayout.clockTextSizeSp(widthDp, heightDp)
        dateText.textSize = if (compact) VisitorLayout.COMPACT_DATE_SP else 15f
        touchHint.textSize = VisitorLayout.hintTextSizeSp(widthDp)
        styleVisitorActions()
        VisitorLayout.apply(
            visitorSplit, visitorColumnA, visitorColumnB,
            idleHeader, noticeCard, langBar,
            notice != null, widthDp, heightDp, compact,
        )
        applyFooterLayout(widthDp, heightDp)
        scheduleGroupSpacing()
        scheduleRegionInk()
    }

    /**
     * The fixed action zone (guidelines "Visitor"): one full-width primary Call button in Core's
     * region accent, Cancel/End in the negative role, "call without choosing" secondary. All are
     * at least the 72 dp visitor target and grow with large text so a 200 % label never clips.
     */
    private fun styleVisitorActions() {
        val window = UiKit.window(this)
        val height = ScreenLayouts.visitorActionHeightDp(window)
        val roles = visitorRoles()
        callButton.minHeight = dp(height)
        callButton.minimumHeight = dp(height)
        UiKit.styleAction(cancelButton, roles, ActionRole.NEGATIVE, height, emphasis = true)
        UiKit.styleAction(purposeCancelButton, roles, ActionRole.NEGATIVE, height, emphasis = true)
        UiKit.styleAction(purposeSkipButton, roles, ActionRole.SECONDARY,
                          ScreenLayouts.touchTargetDp(window, 56))
        pairingBanner.background = ShellUi.rounded(this, roles.warning, UiTokens.RADIUS_CARD)
        pairingBanner.setTextColor(ShellUi.opaque(roles.onWarning))
        applyCallButtonAccent()
        // Core's semantic overrides go on top of the freshly styled roles.
        applySemanticUi()
    }

    /**
     * Breathing room between the visitor screen's groups, measured rather than assumed: the gap
     * comes out of whatever vertical slack is actually left once the groups have been laid out, so
     * a short screen keeps the tight layout it needs.
     */
    private fun scheduleGroupSpacing() {
        if (dashboard != null) return
        visitorSplit.post {
            if (isFinishing || dashboard != null) return@post
            for (column in arrayOf(visitorColumnA, visitorColumnB)) {
                if (column.visibility != View.VISIBLE || column.childCount < 2) continue
                var content = 0
                for (index in 0 until column.childCount) {
                    val child = column.getChildAt(index)
                    if (child.visibility == View.GONE) continue
                    content += child.height
                }
                val density = resources.displayMetrics.density
                val gap = VisitorLayout.groupGapDp(
                    (column.height / density).toInt(),
                    (content / density).toInt(),
                    column.childCount,
                )
                var changed = false
                for (index in 1 until column.childCount) {
                    val child = column.getChildAt(index)
                    val params = child.layoutParams as? LinearLayout.LayoutParams ?: continue
                    val margin = dp(gap)
                    if (params.topMargin == margin) continue
                    params.topMargin = margin
                    child.layoutParams = params
                    changed = true
                }
                if (changed) column.requestLayout()
            }
        }
    }

    /**
     * The version line and the SOS slider must never overlap or clip each other. A narrow window
     * stacks them, so the full `door · core vX · app vY · battery` line is always readable; a wide
     * one puts the slider to its right. The version line is never ellipsized.
     */
    private fun applyFooterLayout(widthDp: Int, heightDp: Int) {
        val stacked = VisitorLayout.footerStacked(widthDp, heightDp)
        visitorFooter.orientation =
            if (stacked) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
        val infoParams = nodeInfo.layoutParams as LinearLayout.LayoutParams
        val sosParams = sosSlot.layoutParams as LinearLayout.LayoutParams
        if (stacked) {
            infoParams.width = android.view.ViewGroup.LayoutParams.MATCH_PARENT
            infoParams.weight = 0f
            sosParams.width = android.view.ViewGroup.LayoutParams.MATCH_PARENT
            sosParams.bottomMargin = dp(6)
        } else {
            infoParams.width = 0
            infoParams.weight = 1f
            sosParams.width = android.view.ViewGroup.LayoutParams.WRAP_CONTENT
            sosParams.bottomMargin = 0
        }
        // The caption is the bottom edge: the slider sits above it, or beside it when wide.
        visitorFooter.removeAllViews()
        if (stacked) {
            visitorFooter.addView(sosSlot, sosParams)
            visitorFooter.addView(nodeInfo, infoParams)
        } else {
            visitorFooter.addView(nodeInfo, infoParams)
            visitorFooter.addView(sosSlot, sosParams)
        }
        // Two lines rather than a cut-off one: the versions and the battery all have to be read.
        nodeInfo.setSingleLine(false)
        nodeInfo.maxLines = 2
        nodeInfo.ellipsize = null
    }

    /** Light and dark tokens for the door station's own screen (§5.1). */
    private fun applyAppearance() {
        // Core resolves the schedule in the cluster time zone; the shell only adds the platform's
        // own light/dark setting for auto_system, and computes everything locally on an older core.
        palette = ShellAppearance.resolve(
            this, statusSnapshot, cfg, clusterClock.now().minuteOfDay(),
        )
        if (dashboard != null) return
        replyBanner.setBackgroundColor(ShellUi.opaque(palette.surface))
        replyText.setTextColor(ShellUi.opaque(palette.ink))
        replyHint.setTextColor(ShellUi.opaque(palette.ink))
        replyCount.setTextColor(ShellUi.opaque(palette.ink))
        // A configured background colour or image wins; the palette ground is the fallback.
        if (themeValue("bg_color") == null && themeValue("bg_image").isNullOrEmpty())
            rootView.setBackgroundColor(ShellUi.opaque(palette.ground))
        airIndicator.render(airReading, texts, palette.line)
        backdrop.clearInk()
        applyRegionInk()
        sosSlider.applyPalette(palette)
        applyCallButtonAccent()
    }

    private fun applyRegionInk() = backdrop.applyRegionInk()

    private fun scheduleRegionInk() {
        if (dashboard != null) return
        backdrop.scheduleRegionInk()
    }

    private fun startRegionInkWatch() {
        if (dashboard != null) return
        backdrop.startWatch()
    }

    private fun stopRegionInkWatch() {
        if (dashboard != null) return
        backdrop.stopWatch()
    }

    private fun effectiveBackgroundRgb(): Int = backdrop.effectiveBackgroundRgb()

    /**
     * The call button's background comes from core, which has already folded in the administrator
     * override; its text colour always comes from call_button_ink, because on a mid-luminance
     * background core returns the best compromise rather than an unreadable button (§5.2).
     */
    private fun applyCallButtonAccent() {
        val (background, ink) = CoreDisplays.callButton(
            coreDisplay.theme, effectiveBackgroundRgb(),
        )
        SemanticUi.release(callButton)
        PlatformUi.styleButton(callButton, ButtonKind.FILLED, background, ink)
    }

    /**
     * Ask for a home-screen refresh. Several events a second fold into one refresh; see
     * [HomeRefreshPolicy]. [withConfig] also re-reads configuration and rebuilds what depends on
     * it, which peer liveness never changes.
     */
    private fun scheduleHomeRefresh(
        withConfig: Boolean = false,
        fullRender: Boolean = true,
        withCalls: Boolean = false,
    ) {
        if (withConfig) homeRefreshWantsConfig = true
        if (withConfig || fullRender) homeRefreshWantsFullRender = true
        if (withCalls) homeRefreshWantsCalls = true
        if (homeRefreshQueued) return
        homeRefreshQueued = true
        ui.postDelayed(
            homeRefreshTick,
            HomeRefreshPolicy.delayMs(homeRefreshRunMs, SystemClock.elapsedRealtime()),
        )
    }

    /** Read core for one coalesced refresh, off the main thread, and render what comes back. */
    private fun runHomeRefresh() {
        homeRefreshQueued = false
        val worker = homeHandler
        // Leave the pending flags alone when there is nothing to read: the configuration rebuild
        // this refresh was carrying must still happen once core is back.
        if (!app.coreOk || worker == null) return
        homeRefreshRunMs = SystemClock.elapsedRealtime()
        val withConfig = homeRefreshWantsConfig
        val fullRender = homeRefreshWantsFullRender
        val withCalls = homeRefreshWantsCalls
        val generation = app.runtime.coreGeneration
        homeRefreshWantsConfig = false
        homeRefreshWantsFullRender = false
        homeRefreshWantsCalls = false
        worker.post {
            // One status document per refresh, shared by every surface that renders from it.
            val status = app.core.status()
            val config = if (withConfig) app.core.config() else null
            val pairing = app.core.pairingInfo()
            val ready = app.pairingReadyFrom(pairing)
            ui.post {
                applyHomeRefresh(status, config, pairing, ready, withConfig, fullRender,
                    withCalls, generation)
            }
        }
    }

    private fun applyHomeRefresh(
        status: JSONObject?,
        config: JSONObject?,
        pairing: JSONObject?,
        pairingReady: Boolean,
        withConfig: Boolean,
        fullRender: Boolean,
        withCalls: Boolean,
        generation: Long,
    ) {
        if (isFinishing || !app.runtime.isCurrentGeneration(generation)) return
        statusSnapshot = status
        coreDisplay = CoreDisplays.parse(status?.optJSONObject("display"))
        status?.optJSONObject("node")?.optString("id")?.let { if (it.isNotEmpty()) nodeId = it }
        if (!fullRender) {
            renderMembership(pairing, pairingReady)
            dashboard?.refreshRuntime(status, withCalls)
            return
        }
        if (withConfig) {
            applyConfigCache(config)
            fetchFlow()
            applyTheme()
            buildPurposeButtons()
            buildLangBar()
            applyStrings()
            applySemanticUi()
            configureSos()
        }
        renderMembership(pairing, pairingReady)
        status?.optJSONObject("display")?.let {
            applyNightTint(it.optBoolean("night"), it.optBoolean("red_tint"))
        }
        applyAppearance()
        applyVisitorLayout()
        dashboard?.refresh(status, cfg)
    }

    private fun refreshNodeInfo() {
        refreshConfigCache()
        val st = app.core.status()
        statusSnapshot = st
        coreDisplay = CoreDisplays.parse(st?.optJSONObject("display"))
        val node = st?.optJSONObject("node")
        if (node != null) nodeId = node.optString("id")
        refreshMembership()
        // Recover replicated visitor language from status after restart.
        if (st != null && app.boot.role == "door_station" && app.boot.door.isNotEmpty()) {
            val vl = app.core.dig(st, "visitor_lang.${app.boot.door}")
            setVisitorLang(vl?.toString() ?: "ja")
        }
        // Status catches a display event that may have preceded subscription.
        st?.optJSONObject("display")?.let { applyNightTint(it.optBoolean("night"),
                                                          it.optBoolean("red_tint")) }
        applyTheme()
        applyAppearance()
        buildPurposeButtons()
        buildLangBar()
        applyStrings()
        applySemanticUi()
        configureSos()
        applyVisitorLayout()
        homeRefreshRunMs = SystemClock.elapsedRealtime()
        dashboard?.refresh(st, cfg)
    }

    /**
     * The SOS control is a slide, and the countdown length is the configured
     * emergency.trigger.countdown_s rather than a hardcoded hold.
     */
    private fun configureSos() {
        val countdown = SosSlideState.countdownFromConfig(cfg)
        sosSlider.configure(
            texts.t("sos.slide_label", R.string.sos_slide_label),
            texts.t("sos.slide_sub", R.string.sos_slide_sub, countdown.toString()),
            texts.t("sos.countdown_cancel", R.string.sos_countdown_cancel),
            countdown,
            texts.t("sos.confirm_title", R.string.sos_confirm_title),
            texts.t("sos.hint", R.string.sos_hint),
            texts.t("sos.send", R.string.sos_send),
        ) { seconds -> texts.t("sos.countdown", R.string.sos_countdown, seconds.toString()) }
        sosSlot.visibility = if (sosVisibleForRole()) View.VISIBLE else View.GONE
    }

    /**
     * emergency.button_on_roles decides whether this device offers the slider at all. An absent
     * key is core's default of ["indoor_panel"], so this visitor screen shows no bar unless the
     * cluster deliberately names door_station.
     */
    private fun sosVisibleForRole(): Boolean =
        SosSlideState.visibleForRole(cfg, app.boot.role)

    private fun applySemanticUi() {
        val styleConfig = if (app.safeMode) null else cfg
        SemanticUi.apply(callButton, "call.primary", styleConfig, nodeId)
        SemanticUi.apply(purposeSkipButton, "call.primary", styleConfig, nodeId)
        SemanticUi.apply(purposeCancelButton, "cancel.call", styleConfig, nodeId)
        SemanticUi.apply(cancelButton, if (callUiPhase == CallUiPhase.ESTABLISHED)
            "call.end" else "cancel.call", styleConfig, nodeId)
        for (index in 0 until purposeGrid.childCount)
            SemanticUi.apply(purposeGrid.getChildAt(index), "purpose.button", styleConfig, nodeId)
        if (::flowPanel.isInitialized) flowPanel.applySemantic(styleConfig, nodeId)
        sosSlider.applySemantic(styleConfig, nodeId)
        SemanticUi.apply(offlineTitle, "status.offline", styleConfig, nodeId)
        SemanticUi.apply(offlineBody, "status.offline", styleConfig, nodeId)
    }

    // Localized text: configuration overrides precede generated resources.

    /** Reapply all labels after a visitor-language change. */
    private fun applyStrings() {
        // Just the verb. A visitor has no use for the device or door identifier, and it made the
        // button read "DOORBELL-ANDROID 呼出" on the Moto; the door name lives in the footer.
        callButton.text = if (showsHomePurposes()) texts.t("door.call_direct", R.string.door_call_direct)
            else texts.t("door.call_action", R.string.door_call_action)
        touchHint.text = homeCallHint()
        purposeHint.text = texts.t("idle.choose_purpose", R.string.idle_choose_purpose)
        purposeAutoHint.text = texts.t("calling.title", R.string.calling_title)
        purposeSkipButton.text = texts.t("purpose.skip", R.string.purpose_skip)
        purposeCancelButton.text = texts.t("purpose.cancel_call", R.string.purpose_cancel_call)
        updateCallingTitle()
        updateCallActionLabel()
        replyBanner.contentDescription = texts.t("ui.close", R.string.ui_close)
        offlineTitle.text = if (uiCallId.isNotEmpty())
            texts.t("visitor.restoring", R.string.visitor_restoring)
        else texts.t("offline.title", R.string.offline_title)
        offlineBody.text = texts.t("offline.body", R.string.offline_body)
        renderAirQuality()
    }

    /** Resolve a door label by current language, Japanese fallback, then identifier. */
    private fun doorLabel(door: String): String {
        if (door.isEmpty()) return ""
        val l = app.core.dig(cfg, "doors.$door.label.${texts.lang}")
            ?: app.core.dig(cfg, "doors.$door.label.ja")
        return l?.toString() ?: door
    }

    // Theme, purpose, and visitor-language configuration.

    private fun refreshConfigCache() = applyConfigCache(app.core.config())

    private fun applyConfigCache(config: JSONObject?) {
        cfg = config
        texts.setConfig(cfg)
        callFlowMode = CallFlowMode.parse(app.core.dig(cfg, "ui.call_flow")?.toString().orEmpty())
        configureCallFlow()
    }

    /** A visitor flow places its call through the purpose-first path whatever ui.call_flow says. */
    private fun configureCallFlow() {
        val ttlSeconds = (app.core.dig(cfg, "ui.call_ttl_s") as? Number)?.toLong() ?: 60L
        app.callFlow.configure(
            if (callFlowMode == CallFlowMode.RING_THEN_PURPOSE && flowWalker == null)
                "ring_then_purpose" else "purpose_first",
            ttlSeconds,
        )
    }

    private fun updateCallActionLabel() {
        cancelButton.text = if (callUiPhase == CallUiPhase.ESTABLISHED)
            texts.t("incall.end", R.string.incall_end)
        else texts.t("calling.cancel", R.string.calling_cancel)
        SemanticUi.apply(cancelButton, if (callUiPhase == CallUiPhase.ESTABLISHED)
            "call.end" else "cancel.call", if (app.safeMode) null else cfg, nodeId)
    }

    private fun updateCallingTitle() {
        callingText.text = if (callUiPhase == CallUiPhase.ESTABLISHED)
            texts.t("incall.title", R.string.incall_title)
        else texts.t("calling.title", R.string.calling_title) +
            (callTitleOverride?.let { "\n$it" } ?: "")
    }

    /** Resolve device-local theme values before fleet defaults. */
    private fun themeValue(leaf: String): String? = backdrop.themeValue(leaf)

    private fun applyTheme() = backdrop.applyTheme()

    private fun loadThemeImage(hash: String) = backdrop.loadThemeImage(hash)

    private fun applyNightTint(night: Boolean, redTint: Boolean) =
        backdrop.applyNightTint(night, redTint)

    /**
     * Build visit-purpose controls for the door-station idle screen. A purpose an administrator
     * disabled is never offered; when every purpose is off the chooser behaves exactly as it does
     * with none configured, so the visitor goes straight on with the call.
     */
    private fun buildPurposeButtons() {
        if (app.boot.role != "door_station") {
            purposeGrid.removeAllViews()
            purposeSection.visibility = View.GONE
            return
        }
        purposePanel.build(cfg, texts.lang, visitorRoles())
        updatePurposeVisibility()
    }

    /** Colour roles for the visitor screen; the call button keeps Core's region accent. */
    private fun visitorRoles(): UiRoles =
        UiRoles.from(palette, CoreDisplays.callButton(coreDisplay.theme, effectiveBackgroundRgb()))

    private fun showsHomePurposes(): Boolean = app.boot.role == "door_station" &&
        flowWalker == null && callFlowMode == CallFlowMode.PURPOSE_FIRST && VisitPurposes.enabled(cfg).isNotEmpty()

    private fun homeCallHint(): String = if (showsHomePurposes())
        texts.t("door.hint_purpose_first", R.string.door_hint_purpose_first)
        else texts.t("door.hint_call", R.string.door_hint_call)

    private fun updatePurposeVisibility() {
        purposeSection.visibility = if (choosingPurpose || showsHomePurposes()) View.VISIBLE else View.GONE
        purposeHint.visibility = if (choosingPurpose) View.VISIBLE else View.GONE
        purposeAutoHint.visibility = if (choosingPurpose && uiCallId.isNotEmpty()) View.VISIBLE else View.GONE
        (purposeSkipButton.parent as View).visibility = if (choosingPurpose) View.VISIBLE else View.GONE
    }

    private fun onPurposeClick(id: String, label: String) {
        if (!VisitPurposes.enabled(cfg).contains(id)) return
        if (!choosingPurpose) {
            if (!showsHomePurposes() || app.callFlow.current() != null) return
            if (!app.coreOk) { showOffline(); return }
            val pending = app.callFlow.begin(app.boot.door)
            if (!pending.accepted || pending.call != null) return
            playCallFeedback()
        }
        playButtonSound()
        val transition = app.callFlow.selectPurpose(id)
        if (!transition.accepted || transition.call == null) {
            showIdle(texts.t("offline.body", R.string.offline_body))
            return
        }
        applyCallProjection(transition)
        showCalling(texts.t("purpose.sent", R.string.purpose_sent, label))
    }

    /** Build the configured visitor-language controls. */
    private fun buildLangBar() {
        val shown = languageBar.build(cfg, visitorRoles(), app.boot.role == "door_station")
        // The visitor keeps the language row on the idle screen, not only while choosing.
        langBar.visibility = if (shown) View.VISIBLE else View.GONE
        if (shown) updateLangBarSelection()
    }

    private fun updateLangBarSelection() {
        languageBar.select(visitorLang)
    }

    private fun onLangClick(lang: String) {
        playButtonSound()
        app.core.setVisitorLang(app.boot.door, lang)
        setVisitorLang(lang)
    }

    /** Switch visitor language through the common local, remote, and timeout path. */
    private fun setVisitorLang(lang: String) {
        val l = if (lang.isEmpty()) "ja" else lang
        if (visitorLang == l) return
        visitorLang = l
        texts.setLang(l)
        lastClockDate = ""
        updateClock()
        applyStrings()
        buildPurposeButtons()
        updateLangBarSelection()
        configureSos()
        flowWalker?.apply(FlowEvent.Language(l))
        if (flowWalker != null && idleShowing()) showIdle()
    }

    // ---------- Visitor flow (docs/en/visitor-flow-contract.md) ----------

    /** Any touch counts as input for the flow's idle return. */
    override fun onUserInteraction() {
        super.onUserInteraction()
        if (flowWalker != null && ::flowPanel.isInitialized && flowPanel.visible) scheduleFlowTimer()
    }

    /** Whether the home is still waiting for Core to say if a visitor flow exists. */
    private fun awaitingFlow(): Boolean =
        app.boot.role == "door_station" && !flowResolved && !flowGaveUp && flowWalker == null

    /** The flow start page is the home, or about to be: the compact top row applies. */
    private fun flowHome(): Boolean = flowWalker != null || awaitingFlow()

    private var flowGiveUpArmed = false

    /** A Core that never answers must not leave the home blank: the classic screen takes over. */
    private fun armFlowGiveUp() {
        if (flowResolved || flowGaveUp || flowGiveUpArmed) return
        flowGiveUpArmed = true
        ui.postDelayed(flowGiveUp, FLOW_WAIT_MS)
    }

    private val flowGiveUp = Runnable {
        flowGaveUp = true
        if (!isFinishing && idleShowing()) showIdle()
    }

    private fun idleShowing(): Boolean = !showsDashboard && idleView.visibility == View.VISIBLE &&
        callingView.visibility != View.VISIBLE && offlineView.visibility != View.VISIBLE &&
        !choosingPurpose

    /** Reads the resolved document off the main thread; bursts coalesce into one more read. */
    private fun fetchFlow() {
        if (app.boot.role != "door_station" || !app.coreOk || homeHandler == null) return
        if (flowGate.request()) startFlowFetch()
    }

    private fun startFlowFetch() {
        armFlowGiveUp()
        val worker = homeHandler
        if (worker == null) {
            flowGate.complete()
            return
        }
        val generation = app.runtime.coreGeneration
        worker.post {
            val document = try { app.core.visitorFlow("") } catch (e: Exception) {
                ShellLog.ignored("MainActivity", e)
                null
            }
            ui.post {
                val again = flowGate.complete()
                if (!isFinishing && app.runtime.isCurrentGeneration(generation)) applyFlowDocument(document)
                if (again) startFlowFetch()
            }
        }
    }

    private fun applyFlowDocument(document: JSONObject?) {
        // An unreadable answer changes nothing; a readable one that is disabled means classic.
        if (document == null || app.boot.role != "door_station") return
        val usable = FlowDocuments.usable(document)
        val current = flowWalker
        val waiting = awaitingFlow()
        flowResolved = true
        if (usable == null) {
            if (current == null) {
                if (waiting && idleShowing()) showIdle()
                return
            }
            flowWalker = null
            configureCallFlow()
            if (idleShowing()) showIdle()
            return
        }
        if (current == null) {
            flowWalker = FlowWalker(usable, visitorLang)
        } else if (current.revision != usable.optString("revision")) {
            current.apply(FlowEvent.FlowChanged(usable))
        } else {
            return
        }
        configureCallFlow()
        if (idleShowing()) showIdle()
    }

    private fun flowNoticeText(code: String): String = when (code) {
        FlowWalker.NO_ANSWER_NOTICE -> texts.t("calling.no_answer", R.string.calling_no_answer)
        FlowWalker.PRESS_FAILED_NOTICE -> texts.t("flow.call_failed", R.string.flow_call_failed)
        else -> ""
    }

    /** Draws the walker's current page in place of the classic call button and purpose grid. */
    private fun showFlowPage(hint: String?) {
        val walker = flowWalker ?: return
        val snapshot = walker.snapshot()
        if (snapshot.mode != FlowWalker.MODE_PAGE && snapshot.mode != FlowWalker.MODE_END) {
            flowPanel.hide()
            return
        }
        try {
            callSection.visibility = View.GONE
            touchHint.visibility = View.GONE
            purposeSection.visibility = View.GONE
            // The clock gives its room to the page once the visitor is below the start page.
            idleHeader.visibility = if (snapshot.back && UiKit.window(this).heightDp < 700)
                View.GONE else View.VISIBLE
            val shown = snapshot.notice?.let { flowNoticeText(it) }?.takeIf { it.isNotEmpty() } ?: hint
            visitorStatus.text = shown.orEmpty()
            visitorStatus.visibility = if (shown.isNullOrEmpty()) View.GONE else View.VISIBLE
            if (!layoutCompact) applyVisitorLayout()
            applyFlowColumn(true)
            flowPanel.render(snapshot, texts, UiRoles.from(palette), visitorRoles(),
                             if (app.safeMode) null else cfg,
                             nodeId, app.boot.httpPort, app.safeMode)
            flowPanel.setEnabled(app.coreOk)
            flowPanel.announce(snapshot.title)
            scheduleFlowTimer()
        } catch (e: Exception) {
            // Any failure while drawing a page degrades to a direct call: a visitor is never stranded.
            ShellLog.ignored("MainActivity", e)
            flowWalker = null
            configureCallFlow()
            showIdle()
            ui.post { onCallClick() }
        }
    }

    private fun scheduleFlowTimer() {
        ui.removeCallbacks(flowIdleTick)
        if (flowBusy) return
        val walker = flowWalker ?: return
        val snapshot = walker.snapshot()
        val seconds = when {
            snapshot.mode == FlowWalker.MODE_END -> walker.returnSeconds
            snapshot.mode == FlowWalker.MODE_PAGE && (snapshot.back || snapshot.notice != null) ->
                walker.idleSeconds
            else -> return
        }
        ui.postDelayed(flowIdleTick, seconds * 1000L)
    }

    private fun flowIdleElapsed() {
        val walker = flowWalker ?: return
        if (!idleShowing()) return
        walker.apply(if (walker.mode == FlowWalker.MODE_END) FlowEvent.Done else FlowEvent.IdleTimeout)
        showIdle()
    }

    private fun onFlowBack() {
        val walker = flowWalker ?: return
        if (flowBusy) return
        playButtonSound()
        walker.apply(FlowEvent.Back)
        flowPanel.forgetAnnouncement()
        showIdle()
    }

    private fun onFlowDone() {
        val walker = flowWalker ?: return
        playButtonSound()
        walker.apply(FlowEvent.Done)
        flowPanel.forgetAnnouncement()
        showIdle()
    }

    private fun onFlowOption(optionId: String) {
        val walker = flowWalker ?: return
        if (flowBusy || app.callFlow.current() != null) return
        if (!app.coreOk) { showOffline(); return }
        val label = walker.snapshot().options.firstOrNull { it.id == optionId }?.label.orEmpty()
        try {
            when (val target = walker.targetOf(optionId)) {
                FlowTarget.Nothing -> Unit
                FlowTarget.Page, FlowTarget.End -> {
                    playButtonSound()
                    walker.apply(FlowEvent.Tap(optionId))
                    flowPanel.forgetAnnouncement()
                    showIdle()
                }
                is FlowTarget.Call -> flowDirectCall(optionId, target.purpose, label)
                FlowTarget.Direct -> flowDirectCall(optionId, "", "")
                is FlowTarget.Notify -> flowNotify(optionId, target, label)
            }
        } catch (e: Exception) {
            ShellLog.ignored("MainActivity", e)
            flowWalker = null
            configureCallFlow()
            showIdle()
            onCallClick()
        }
    }

    private fun flowDirectCall(optionId: String, purpose: String, label: String) {
        val walker = flowWalker ?: return
        val placed = flowRing(purpose, if (purpose.isEmpty()) "" else label)
        walker.apply(FlowEvent.Tap(optionId, pressFailed = !placed))
        if (placed) showCalling(callTitleOverride) else showIdle()
    }

    /** The existing purpose-first press: begin, then the purpose (or none). False when it failed. */
    private fun flowRing(purpose: String, label: String): Boolean {
        val pending = app.callFlow.begin(app.boot.door)
        if (!pending.accepted || pending.call != null) return false
        playCallFeedback()
        playButtonSound()
        val transition = if (purpose.isEmpty()) app.callFlow.skipPurpose()
            else app.callFlow.selectPurpose(purpose)
        if (!transition.accepted || transition.call == null) {
            stopCallFeedback()
            app.callFlow.finishLocal()
            clearCallProjection()
            return false
        }
        applyCallProjection(transition)
        if (label.isNotEmpty()) callTitleOverride = texts.t("purpose.sent", R.string.purpose_sent, label)
        return true
    }

    /**
     * The household is notified by Core, which takes seconds: the tapped option shows a spinner at
     * once, a status line follows after [FLOW_STATUS_DELAY_MS], and the page is restored with a retry
     * hint when Core fails or [FLOW_PENDING_TIMEOUT_MS] pass. The idle return is suspended meanwhile.
     */
    private fun flowNotify(optionId: String, target: FlowTarget.Notify, label: String) {
        val worker = homeHandler ?: return
        playButtonSound()
        val token = ++flowPendingToken
        flowBusy = true
        ui.removeCallbacks(flowIdleTick)
        val busy = texts.t("flow.pending_notify", R.string.flow_pending_notify)
        flowPanel.setStatus("")
        flowPanel.setPending(optionId, busy)
        ui.postDelayed(flowStatusTick, FLOW_STATUS_DELAY_MS)
        ui.postDelayed(flowTimeoutTick, FLOW_PENDING_TIMEOUT_MS)
        val generation = app.runtime.coreGeneration
        worker.post {
            val result = try { app.core.visitorNotify(app.boot.door, target.step) } catch (e: Exception) {
                ShellLog.ignored("MainActivity", e)
                null
            }
            ui.post {
                if (token != flowPendingToken) return@post
                val walker = flowWalker
                if (isFinishing || walker == null || !app.runtime.isCurrentGeneration(generation)) {
                    endFlowPending()
                    return@post
                }
                // A throttled result is ok: the visitor sees the same page and never learns of the limit.
                if (!FlowDocuments.notifyOk(result)) {
                    flowPendingFailed()
                    return@post
                }
                endFlowPending()
                walker.apply(FlowEvent.Tap(optionId, notifyOk = true))
                flowPanel.forgetAnnouncement()
                showIdle()
            }
        }
    }

    private fun flowPendingStatus() {
        if (!flowBusy) return
        val text = texts.t("flow.pending_notify", R.string.flow_pending_notify)
        flowPanel.setStatus(text)
    }

    private fun flowPendingFailed() {
        if (!flowBusy) return
        endFlowPending()
        flowPanel.setPending(null)
        flowPanel.setEnabled(app.coreOk)
        val text = texts.t("flow.pending_failed", R.string.flow_pending_failed)
        flowPanel.setStatus(text, emphasis = true)
        scheduleFlowTimer()
    }

    /** Leaves the pending state; a result that arrives later is ignored by its stale token. */
    private fun endFlowPending() {
        flowPendingToken++
        flowBusy = false
        ui.removeCallbacks(flowStatusTick)
        ui.removeCallbacks(flowTimeoutTick)
    }

    // ---------- Call state transitions ----------

    /**
     * True on an indoor panel, where the home screen is the dashboard and the door-station call
     * flow has no screen of its own. Without this the dashboard is built and then immediately
     * covered by the visitor idle view, which is what put a door station's call button on an
     * indoor panel.
     */
    private val showsDashboard: Boolean get() = dashboard != null

    /** Put the dashboard back in front after any call-flow transition. */
    private fun restoreRoleHome() {
        visitorShell.visibility = View.GONE
        idleView.visibility = View.GONE
        callingView.visibility = View.GONE
        dashboardHost.visibility = View.VISIBLE
    }

    private fun showIdle(hint: String? = null) {
        stopCallFeedback()
        choosingPurpose = false
        ui.removeCallbacks(purposeTimeout)
        callTitleOverride = null
        ui.removeCallbacks(callTimeout)
        pulse.clearAnimation()
        offlineView.visibility = View.GONE
        flowWalker?.let {
            if (it.mode == FlowWalker.MODE_CALLING) it.apply(FlowEvent.CallEnded(flowEndReason))
        }
        flowEndReason = "ended"
        flowBusy = false
        if (showsDashboard) {
            restoreRoleHome()
            updateCallActionLabel()
            return
        }
        callingView.visibility = View.GONE
        cancelButton.visibility = View.GONE
        idleView.visibility = View.VISIBLE
        idleHeader.visibility = View.VISIBLE
        callSection.visibility = View.VISIBLE
        callButton.isEnabled = app.coreOk
        cancelButton.isEnabled = app.coreOk
        purposeCancelButton.isEnabled = app.coreOk
        updatePurposeVisibility()
        langBar.visibility = if (langBar.childCount > 0) View.VISIBLE else View.GONE
        purposeCancelButton.visibility = View.GONE
        touchHint.visibility = View.VISIBLE
        touchHint.text = homeCallHint()
        visitorStatus.text = hint.orEmpty()
        visitorStatus.visibility = if (hint.isNullOrEmpty()) View.GONE else View.VISIBLE
        idleView.scrollTo(0, 0)
        if (flowWalker != null) {
            showFlowPage(hint)
        } else {
            flowPanel.hide()
            applyFlowColumn(false)
            if (layoutCompact != flowHome()) applyVisitorLayout()
            if (awaitingFlow()) {
                armFlowGiveUp()
                // Neither the classic call button nor a purpose grid until Core has said which.
                callSection.visibility = View.GONE
                purposeSection.visibility = View.GONE
                touchHint.visibility = View.GONE
            }
        }
        updateCallActionLabel()
    }

    /** On a wide window the flow page stays one centred column rather than spanning the screen. */
    private fun applyFlowColumn(flow: Boolean) {
        val widthPx = resources.displayMetrics.widthPixels
        val base = dp(16)
        val side = if (flow) maxOf(base, (widthPx - dp(FLOW_COLUMN_MAX_DP)) / 2) else base
        val dock = findViewById<View>(R.id.visitor_action_dock)
        dock.setPadding(side, dock.paddingTop, side, dock.paddingBottom)
        val content = if (flow) maxOf(dp(12), side - dp(12)) else dp(12)
        flowContent.setPadding(content, flowContent.paddingTop, content, flowContent.paddingBottom)
    }

    private fun showPurposeChooser() {
        dismissReply()
        if (showsDashboard) return
        flowPanel.hide()
        choosingPurpose = true
        visitorStatus.visibility = View.GONE
        touchHint.visibility = View.GONE
        idleView.visibility = View.VISIBLE
        callingView.visibility = View.GONE
        cancelButton.visibility = View.GONE
        offlineView.visibility = View.GONE
        idleHeader.visibility = View.GONE
        callSection.visibility = View.GONE
        purposeSection.visibility = View.VISIBLE
        purposeHint.visibility = View.VISIBLE
        (purposeSkipButton.parent as View).visibility = View.VISIBLE
        purposeAutoHint.visibility =
            if (uiCallId.isNotEmpty()) View.VISIBLE else View.GONE
        purposeCancelButton.visibility =
            if (uiCallId.isNotEmpty()) View.VISIBLE else View.GONE
        purposeCancelButton.isEnabled = app.coreOk
        langBar.visibility = if (langBar.childCount > 0) View.VISIBLE else View.GONE
        ui.removeCallbacks(purposeTimeout)
        purposeDeadlineElapsedMs = SystemClock.elapsedRealtime() + PURPOSE_TIMEOUT_MS
        ui.postDelayed(purposeTimeout, PURPOSE_TIMEOUT_MS)
        scheduleCallTimeout()
    }

    /** Show ringing while preserving an explicit purpose confirmation title. */
    private fun showCalling(title: String? = null) {
        dismissReply()
        if (showsDashboard) return
        flowPanel.hide()
        ui.removeCallbacks(flowIdleTick)
        choosingPurpose = false
        visitorStatus.visibility = View.GONE
        ui.removeCallbacks(purposeTimeout)
        if (title != null) callTitleOverride = title
        updateCallingTitle()
        updateCallActionLabel()
        idleView.visibility = View.GONE
        callSection.visibility = View.GONE
        purposeCancelButton.visibility = View.GONE
        cancelButton.visibility = View.VISIBLE
        cancelButton.isEnabled = app.coreOk
        offlineView.visibility = View.GONE
        callingView.visibility = View.VISIBLE
        callingView.scrollTo(0, 0)
        scheduleCallTimeout()
        if (app.safeMode) pulse.clearAnimation()
        else pulse.startAnimation(AlphaAnimation(0.25f, 1.0f).apply {
                duration = 900
                repeatMode = Animation.REVERSE
                repeatCount = Animation.INFINITE
            })
    }

    private fun showEstablished() {
        dismissReply()
        if (showsDashboard) return
        flowPanel.hide()
        ui.removeCallbacks(flowIdleTick)
        choosingPurpose = false
        visitorStatus.visibility = View.GONE
        ui.removeCallbacks(purposeTimeout)
        ui.removeCallbacks(callTimeout)
        stopCallFeedback()
        pulse.clearAnimation()
        callingText.text = texts.t("incall.title", R.string.incall_title)
        idleView.visibility = View.GONE
        callSection.visibility = View.GONE
        purposeCancelButton.visibility = View.GONE
        cancelButton.visibility = View.VISIBLE
        cancelButton.isEnabled = app.coreOk
        offlineView.visibility = View.GONE
        callingView.visibility = View.VISIBLE
        callingView.scrollTo(0, 0)
        updateCallActionLabel()
    }

    private fun applyCallProjection(transition: CallTransition) {
        callUiPhase = transition.phase
        transition.call?.let {
            uiCallId = it.callId
            uiCallStageRevision = it.stageRevision
            uiCallExpiresAtMs = it.expiresAtMs
        }
        updateCallActionLabel()
    }

    private fun applyCallProjection(call: OriginatedCall) {
        applyCallProjection(CallTransition(call.phase, call))
    }

    private fun clearCallProjection() {
        callUiPhase = CallUiPhase.IDLE
        uiCallId = ""
        uiCallStageRevision = 0
        uiCallExpiresAtMs = 0L
        callTitleOverride = null
        updateCallActionLabel()
    }

    private fun scheduleCallTimeout() {
        ui.removeCallbacks(callTimeout)
        if (uiCallId.isEmpty() || callUiPhase == CallUiPhase.ESTABLISHED) return
        val remaining = (uiCallExpiresAtMs - System.currentTimeMillis()).coerceAtLeast(0L)
        ui.postDelayed(callTimeout, if (remaining == 0L) CANCEL_RECONCILE_MS else remaining)
    }

    private fun restoreCurrentCallUi() {
        val active = app.callFlow.current()
        if (active == null) {
            clearCallProjection()
            showIdle()
            return
        }
        applyCallProjection(active)
        when (active.phase) {
            CallUiPhase.PURPOSE_PENDING -> showPurposeChooser()
            CallUiPhase.RINGING -> showCalling()
            CallUiPhase.ESTABLISHED -> showEstablished()
            CallUiPhase.IDLE -> showIdle()
        }
    }

    private fun restoreRequestedCall(request: Intent?) {
        if (request?.action != App.ACTION_RESTORE_CALL || !app.coreOk) return
        val callId = request.getStringExtra(App.EXTRA_RECOVERY_CALL_ID).orEmpty()
        request.action = null
        val active = app.callFlow.recoveryCandidate(callId, app.boot.door)
        val sipActive = app.core.status()?.optJSONObject("sip")?.optString("call") == "in_call"
        val restoredCall = active?.takeIf {
            it.phase != CallUiPhase.ESTABLISHED || sipActive
        }
        val restored = restoredCall != null
        if (restoredCall != null) {
            applyCallProjection(restoredCall)
            when (restoredCall.phase) {
                CallUiPhase.PURPOSE_PENDING -> showPurposeChooser()
                CallUiPhase.RINGING -> showCalling()
                CallUiPhase.ESTABLISHED -> showEstablished()
                CallUiPhase.IDLE -> showIdle()
            }
        }
        if (app.completeCallRecovery(callId, restored) && !restored) {
            clearCallProjection()
            showIdle(texts.t("calling.no_answer", R.string.calling_no_answer))
        }
    }

    private fun showOffline() {
        dismissReply()
        flowPanel.hide()
        ui.removeCallbacks(flowIdleTick)
        visitorStatus.visibility = View.GONE
        if (showsDashboard) {
            visitorShell.visibility = View.VISIBLE
            findViewById<View>(R.id.visitor_action_dock).visibility = View.GONE
        }
        offlineTitle.text = if (uiCallId.isNotEmpty())
            texts.t("visitor.restoring", R.string.visitor_restoring)
        else texts.t("offline.title", R.string.offline_title)
        callButton.isEnabled = false
        cancelButton.isEnabled = false
        purposeCancelButton.isEnabled = false
        offlineView.visibility = View.VISIBLE
    }

    // Marshal Core-thread callbacks to the UI thread.

    override fun onUiEvent(ev: JSONObject) {
        val generation = ev.optLong("_runtime_generation", -1L)
        ui.post {
            if (generation == -1L || app.runtime.isCurrentGeneration(generation))
                handleUiEvent(ev)
        }
    }

    override fun onTts(text: String, lang: String) {
        ui.post { speakNow(text, lang) }
    }

    private fun speakNow(text: String, lang: String) {
        if (::speech.isInitialized) speech.speak(text, lang)
    }

    private fun handleUiEvent(ev: JSONObject) {
        when (ev.optString("t")) {
            "conversation" -> if (app.boot.role == "door_station" && ev.optString("door") == app.boot.door &&
                ev.optString("call_id") == uiCallId) {
                val phase = ev.optString("phase")
                if (phase == "connected" || phase == "held") showEstablished()
                val members = ev.optJSONArray("participants")
                val lines = mutableListOf<String>()
                if (members != null) for (i in 0 until members.length()) {
                    val member = members.optJSONObject(i) ?: continue
                    val id = member.optString("device")
                    val device = app.core.dig(app.core.config(), "devices.$id") as? JSONObject
                    val name = device?.optJSONObject("label")?.optString(app.boot.uiLang)?.ifEmpty { id } ?: id
                    val key = if (member.optString("state") == "waiting") "queued" else member.optString("state")
                    val resource = resources.getIdentifier("conversation_$key", "string", packageName)
                    if (resource != 0) lines.add(texts.t("conversation.$key", resource, name))
                }
                callingText.text = lines.joinToString("\n").ifEmpty { texts.t("conversation.waiting", R.string.conversation_waiting) }
            }
            "runtime" -> {
                if (ev.optString("state") == "ready") {
                    // Core only publishes pairing state once its runtime is up, so the
                    // membership check is repeated here rather than only in onResume.
                    refreshAirQuality()
                    checkPairingAsync {
                        refreshNodeInfo()
                        restoreCurrentCallUi()
                        restoreRequestedCall(intent)
                        maybeStartCamera()
                        fetchFlow()
                    }
                } else showOffline()
            }
            "memory_pressure" -> {
                if (ev.optInt("level") >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) {
                    themeBg.setImageDrawable(null)
                    audio.releaseOptional()
                }
            }
            // peers_changed lands in the coalesced refresh below, which renders membership too.
            // It used to be caught here as well, and because a `when` takes only its first
            // matching branch that swallowed the event: the header counters were then never
            // recomputed after startup, and stood at whatever the cluster looked like when the
            // last unrelated event arrived.
            "visitor_flow_changed" -> fetchFlow()
            "pairing_state", "pairing_revoked" -> refreshMembership()
            "safe_mode" -> {
                if (ev.optBoolean("active")) {
                    pulse.clearAnimation()
                    themeBg.setImageDrawable(null)
                    themeBg.visibility = View.GONE
                }
                applyTheme()
                applySemanticUi()
            }
            "state" -> {
                val callState = ev.optString("state")
                when (callState) {
                    "calling" -> if (!choosingPurpose && app.callFlow.current() != null)
                        showCalling()
                    "idle" -> if (app.callFlow.current() == null) {
                        clearCallProjection()
                        showIdle()
                    }
                    "in_call" -> {
                        val active = app.callFlow.current()
                        if (active?.phase == CallUiPhase.ESTABLISHED) {
                            applyCallProjection(active)
                            showEstablished()
                        }
                    }
                }
            }
            // The chime sound is played by App.incomingAlerts, which rings whatever is in front.
            "reply" -> {
                // Core already spoke replies without custom audio, so avoid duplicate TTS.
                val path = ev.optString("audio_path")
                if (path.isNotEmpty()) {
                    val spoken = ev.optString("text")
                    val spokenLang = ev.optString("lang")
                    audio.playFile(path) { speakNow(spoken, spokenLang) }
                }
                val replyDoor = ev.optString("door")
                if (replyDoor.isEmpty() || replyDoor == app.boot.door) {
                    clearCallProjection()
                    showIdle()
                }
                if (app.emergencyAlerts.current() == null) {
                    var ttl = ev.optDouble("ttl_s", 30.0)
                    if (ttl <= 0) ttl = 30.0
                    replyTtlMs = (ttl * 1000).toLong()
                    replyShownAt = SystemClock.elapsedRealtime()
                    replyGuard = ReplyDismissGuard(replyShownAt)
                    replyText.text = ev.optString("text")
                    replyBanner.visibility = View.VISIBLE
                    flowWalker?.apply(FlowEvent.Reply(true))
                    replyScroll.post { fitReply() }
                    ui.removeCallbacks(replyTick)
                    replyTick.run()
                }
            }
            // Replicated visitor-language update.
            "visitor_lang" -> {
                val door = ev.optString("door")
                if (app.boot.role == "door_station" &&
                    (door.isEmpty() || door == app.boot.door))
                    setVisitorLang(ev.optString("lang"))
            }
            // Retry a pending background after asset prefetch completes.
            "asset_ready" -> {
                val h = backdrop.themeHash
                if (!app.safeMode && h != null && ev.optString("hash") == h &&
                    themeBg.drawable == null)
                    loadThemeImage(h)
            }
            "display" -> {
                coreDisplay = CoreDisplays.parse(ev)
                applyNightTint(ev.optBoolean("night"), ev.optBoolean("red_tint"))
                applyAppearance()
                applyVisitorLayout()
                scheduleHomeRefresh()
            }
            // Cluster time, battery, and announcements each redraw only what they affect.
            "time_changed" -> {
                // The correction moved, so the projected clock is wrong until it is re-anchored.
                clusterClock.invalidate()
                clusterClock.refreshIfStale()
                dashboard?.onTimeChanged()
                updateClock()
                applyAppearance()
                scheduleHomeRefresh()
            }
            "power_changed" -> scheduleHomeRefresh(fullRender = false)
            // A door of "*" means the cluster-wide announcement moved, which affects every
            // door that has none of its own.
            "notice_changed" -> scheduleHomeRefresh()
            "air_quality_changed" -> refreshAirQuality()
            AirSensorHost.PERMISSIONS_EVENT -> requestAirSensorPermissions()
            "call_log_changed" -> scheduleHomeRefresh(fullRender = false, withCalls = true)
            "peers_changed" -> scheduleHomeRefresh(fullRender = false)
            "config_changed" -> scheduleHomeRefresh(withConfig = true)
            "event" -> {
                val eventType = ev.optString("type")
                if (eventType == "motion" || eventType == "press")
                    dashboard?.prioritizeDoor(ev.optString("door"))
                handleCallLifecycleEvent(ev)
            }
        }
    }

    private fun handleCallLifecycleEvent(ev: JSONObject) {
        val type = ev.optString("type")
        val callId = ev.optString("call_id")
        val stage = ev.optInt("stage_revision", 0)
        val matchesProjection = callId.isNotEmpty() && callId == uiCallId &&
            stage >= uiCallStageRevision
        when (type) {
            "press", "purpose_selected" -> {
                val active = app.callFlow.current()
                if (active?.callId == callId && stage >= uiCallStageRevision) {
                    applyCallProjection(active)
                    if (!choosingPurpose && active.phase == CallUiPhase.RINGING) showCalling()
                }
            }
            "call_answered" -> if (matchesProjection) {
                val active = app.callFlow.current()
                if (active?.callId == callId) applyCallProjection(active)
                else {
                    callUiPhase = CallUiPhase.ESTABLISHED
                    uiCallStageRevision = stage
                }
                showEstablished()
            }
            "call_cancelled" -> {
                if (app.boot.role != "door_station") playUpdateSound()
                if (matchesProjection) {
                    stopRinging()
                    clearCallProjection()
                    showIdle()
                }
            }
            "call_ended" -> if (matchesProjection) {
                stopRinging()
                clearCallProjection()
                showIdle()
            }
            "reply" -> {
                val door = ev.optString("door")
                if (door.isEmpty() || door == app.boot.door) {
                    clearCallProjection()
                    showIdle()
                }
            }
        }
    }

    // Audio.

    /** Play immediate feedback after accepting the visitor's call action. */
    private fun playCallFeedback() {
        stopCallFeedback()
        val value = configuredSound("call_sound", "outdoor_call_alert")
        if (value.isEmpty()) return
        val loop = (app.core.dig(cfg, "ui.call_sound_loop") as? Boolean) ?: false
        if (!audio.playConfigured(ShellAudio.Channel.CALL_FEEDBACK, value, loop))
            audio.playTone(AudioManager.STREAM_MUSIC, 75, ToneGenerator.TONE_PROP_ACK, 140)
    }

    private fun configuredSound(key: String, fallback: String): String {
        val value = app.core.dig(cfg, "ui.$key")
        return if (value is String) value else fallback
    }

    private fun playButtonSound() {
        audio.playConfigured(ShellAudio.Channel.EFFECT,
                             configuredSound("button_sound", "button_click"), false)
    }

    private fun playUpdateSound() {
        audio.playConfigured(ShellAudio.Channel.EFFECT,
                             configuredSound("update_sound", "indoor_update"), false)
    }

    private fun playLaunchSound() {
        audio.playConfigured(ShellAudio.Channel.LAUNCH,
                             configuredSound("launch_sound", "title_display"), false)
    }

    private fun stopCallFeedback() {
        audio.stop(ShellAudio.Channel.CALL_FEEDBACK)
    }

    private fun stopRinging() {
        stopCallFeedback()
        audio.stop(ShellAudio.Channel.CUSTOM)
        audio.stopTone()
        app.incomingAlerts.stopChime()
    }

    // Visitor actions.

    private fun onCallClick() {
        if (choosingPurpose || app.callFlow.current() != null) return
        if (!app.coreOk) {
            showOffline()
            return
        }
        playCallFeedback()
        val transition = app.callFlow.begin(app.boot.door)
        if (!transition.accepted) {
            stopCallFeedback()
            showIdle(texts.t("offline.body", R.string.offline_body))
            return
        }
        applyCallProjection(transition)
        if (callFlowMode == CallFlowMode.PURPOSE_FIRST || VisitPurposes.enabled(cfg).isEmpty())
            continueWithoutPurpose(false)
        else showPurposeChooser()
    }

    private fun continueWithoutPurpose(playSound: Boolean) {
        if (playSound) playButtonSound()
        val transition = app.callFlow.skipPurpose()
        if (!transition.accepted || transition.call == null) {
            clearCallProjection()
            showIdle(texts.t("offline.body", R.string.offline_body))
            return
        }
        applyCallProjection(transition)
        showCalling()
    }

    private fun cancelActiveCall(reason: String) {
        playButtonSound()
        ui.removeCallbacks(callTimeout)
        renderCancellationResult(app.callFlow.cancel(reason))
    }

    private fun visitorCallAction(): VisitorCallAction? =
        uiCallId.takeIf { it.isNotEmpty() }?.let { VisitorCallAction(it, callUiPhase) }

    @android.annotation.SuppressLint("ClickableViewAccessibility")
    private fun bindCallAction(button: Button) {
        val latch = VisitorActionLatch()
        button.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> latch.begin(visitorCallAction())
                MotionEvent.ACTION_CANCEL -> latch.cancel()
            }
            false
        }
        button.setOnKeyListener { _, key, event ->
            if ((key == KeyEvent.KEYCODE_ENTER || key == KeyEvent.KEYCODE_DPAD_CENTER ||
                    key == KeyEvent.KEYCODE_SPACE) && event.action == KeyEvent.ACTION_DOWN &&
                    event.repeatCount == 0) latch.begin(visitorCallAction())
            false
        }
        button.setOnClickListener {
            latch.consume(visitorCallAction())?.let { endOrCancelCall(it) }
        }
    }

    private fun endOrCancelCall(action: VisitorCallAction) {
        val active = app.callFlow.current() ?: return
        if (active.callId != action.callId || active.phase != action.phase) return
        playButtonSound()
        ui.removeCallbacks(callTimeout)
        val transition = if (action.phase == CallUiPhase.ESTABLISHED)
            app.callFlow.endEstablished() else app.callFlow.cancel("visitor")
        renderCancellationResult(transition)
    }

    private fun renderCancellationResult(transition: CallTransition) {
        if (transition.phase == CallUiPhase.IDLE || transition.call == null) {
            clearCallProjection()
            showIdle()
            return
        }
        applyCallProjection(transition)
        when (transition.phase) {
            CallUiPhase.PURPOSE_PENDING -> showPurposeChooser()
            CallUiPhase.RINGING -> showCalling()
            CallUiPhase.ESTABLISHED -> showEstablished()
            CallUiPhase.IDLE -> showIdle()
        }
    }

    private fun onSecretCorner() {
        val now = System.currentTimeMillis()
        if (now - secretFirstMs > 5000) { secretFirstMs = now; secretTaps = 0 }
        if (++secretTaps < 7) return
        secretTaps = 0
        AdminGate.unlock(this, app.boot.httpPort, texts) { showMaintenanceMenu() }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    // Camera and permissions.

    private fun requestPermissionsIfNeeded() {
        if (Build.VERSION.SDK_INT < 23) return
        val requested = ArrayList<String>()
        requested.add(Manifest.permission.CAMERA)
        requested.add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33) requested.add(Manifest.permission.POST_NOTIFICATIONS)
        val want = requested
            .filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (want.isNotEmpty()) requestPermissions(want.toTypedArray(), 1)
    }

    /**
     * Bluetooth permissions are asked for only after Core names this device as a sensor host, and
     * once per screen instance; a request made while another dialog is up is retried afterwards.
     */
    private fun requestAirSensorPermissions() {
        if (airPermissionsAsked || !app.coreOk || Build.VERSION.SDK_INT < 23) return
        val missing = app.runtime.airSensors.missingPermissions()
        if (missing.isEmpty()) return
        airPermissionsAsked = true
        requestPermissions(missing.toTypedArray(), AIR_PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>,
                                            grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == AIR_PERMISSION_REQUEST) {
            // An empty result means the request was cancelled by another dialog, not denied.
            if (grantResults.isEmpty()) airPermissionsAsked = false
            app.runtime.airSensors.onPermissionsChanged()
            return
        }
        if (app.coreOk) app.runtime.airSensors.onPermissionsChanged()
        requestAirSensorPermissions()
        // Newly granted camera/microphone permissions become foreground-service types.
        app.refreshResidentForegroundTypes()
        maybeStartCamera()
    }

    private fun hasCameraPermission(): Boolean =
        Build.VERSION.SDK_INT < 23 ||
        checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun maybeStartCamera() {
        if (hasCameraPermission()) app.runtime.onPermissionsChanged()
    }

    companion object {
        private const val TAG = "doorbell-ui"

        private const val PURPOSE_TIMEOUT_MS = 15_000L
        private const val FLOW_WAIT_MS = 2_500L
        private const val FLOW_STATUS_DELAY_MS = 800L
        private const val FLOW_PENDING_TIMEOUT_MS = 15_000L
        private const val FLOW_COLUMN_MAX_DP = 640
        private const val AIR_REFRESH_MS = 60_000L
        private const val AIR_PERMISSION_REQUEST = 2
        private const val CANCEL_RECONCILE_MS = 500L
    }
}
