// Door-station UI state machine driven by versioned Core events. Device Owner installations use
// lock-task mode; themes, visitor languages, and purposes are resolved from fleet configuration.
package jp.ox.doorbell

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.ToneGenerator
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.util.Log
import android.view.View
import android.view.Surface
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
import java.net.URL
import java.util.Calendar
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : Activity(), DoorbellCore.Listener, SensorEventListener {

    private val ui = Handler(Looper.getMainLooper())
    private lateinit var app: App
    private lateinit var texts: Texts

    private lateinit var rootView: View
    private lateinit var themeBg: ImageView
    private lateinit var nightTint: View
    private lateinit var idleView: View
    private lateinit var idleHeader: View
    private lateinit var callSection: View
    private lateinit var clockText: TextView
    private lateinit var dateText: TextView
    private lateinit var callButton: Button
    private lateinit var touchHint: TextView
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
    private lateinit var replyCaption: TextView
    private lateinit var replyText: TextView
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
    private lateinit var sosSlider: SosSlideView
    private lateinit var clusterClock: ClusterClock

    /** Present only on an indoor panel; the door station never builds a dashboard. */
    private var dashboard: DashboardView? = null

    /** Resolved appearance for this screen; recomputed on every config or time change. */
    private var palette: Palette = Palette.DARK

    private var lastClockText = ""
    private var lastClockDate = ""

    /** Appearance and automatic theme as core published them; null on an older core. */
    private var coreDisplay: CoreDisplay = CoreDisplay(null, null)

    /** The latest status snapshot, which carries the resolved notice, unlock, and display. */
    private var statusSnapshot: JSONObject? = null

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val sensorManager by lazy { getSystemService(SENSOR_SERVICE) as SensorManager }
    private var lastVideoRotation = -1

    private var secretTaps = 0
    private var secretFirstMs = 0L
    private var adminUnlocked = false

    // Theme, visitor language, purpose, and custom-audio state.
    private var cfg: JSONObject? = null
    private var nodeId = ""
    private var visitorLang = "ja"
    private var choosingPurpose = false
    private var themeColor: String? = null
    private var themeHash: String? = null
    private var audio: MediaPlayer? = null
    private var effectAudio: MediaPlayer? = null
    private var callFeedbackAudio: MediaPlayer? = null
    private var launchAudio: MediaPlayer? = null
    private var chimeTone: ToneGenerator? = null
    private var callTitleOverride: String? = null
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
                showIdle(texts.t("calling.no_answer", R.string.calling_no_answer))
            } else {
                applyCallProjection(transition)
                scheduleCallTimeout()
            }
        }
    }
    private val purposeTimeout = Runnable {
        if (!choosingPurpose) return@Runnable
        if (uiCallId.isNotEmpty()) continueWithoutPurpose(false)
        else {
            app.callFlow.finishLocal()
            clearCallProjection()
            showIdle()
        }
    }
    private val replyTimeout = Runnable { replyBanner.visibility = View.GONE }
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
        setContentView(R.layout.activity_main)
        bindViews()
        installRoleHome()

        refreshConfigCache()
        texts.setLang(visitorLang)
        applyStrings()

        callButton.setOnClickListener { onCallClick() }
        purposeSkipButton.setOnClickListener { continueWithoutPurpose(true) }
        purposeCancelButton.setOnClickListener { cancelActiveCall("visitor") }
        cancelButton.setOnClickListener { endOrCancelCall() }
        sosSlider.enabledProvider = { app.coreOk }
        sosSlider.onTrigger = { app.commitEmergency(true) }
        // Hidden maintenance entry: seven taps in the top-right corner within five seconds.
        // This is the door station's only route to settings; nothing about it is visible.
        findViewById<View>(R.id.secret_corner).setOnClickListener { playButtonSound(); onSecretCorner() }
        pairingBanner.setOnClickListener {
            app.resumePairingSetup()
            PairingActivity.launch(this)
        }

        tts = TextToSpeech(this) { status -> ttsReady = status == TextToSpeech.SUCCESS }

        requestPermissionsIfNeeded()

        // The foreground registration itself happens in onResume so a screen opened above this
        // one (pairing, maintenance) can never leave the main UI without Core events.
        if (!app.coreOk) showOffline() else restoreCurrentCallUi()
        refreshNodeInfo()
        restoreRequestedCall(intent)
        ui.postDelayed({ playLaunchSound() }, 350)
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
        // Re-register on every resume: a pairing or maintenance screen closing above this one
        // must hand the event stream back, or chimes and display events are lost until restart.
        app.bindForeground(this)
        // Keep unenrolled devices in the pairing flow.
        if (maybeShowPairing()) return
        refreshMembership()
        enterImmersive()
        ui.post(clockTick)
        if (choosingPurpose) ui.postDelayed(purposeTimeout, PURPOSE_TIMEOUT_MS)
        enterKioskIfConfigured()
        maybeStartCamera()
        dashboard?.onResume()
        applyVisitorLayout()
        startRegionInkWatch()
        if (app.boot.role == "door_station") {
            publishDisplayRotationFallback()
            sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
                sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
            }
        }
    }

    /**
     * Opens onboarding until Core reports "ready" and the shell holds its own durable secure
     * reference. Once the operator chose "set up later" the main UI stays visible and only the
     * banner remains, so there is no relaunch loop.
     */
    private fun maybeShowPairing(): Boolean {
        if (!app.coreOk) return false
        if (app.core.pairingInfo() == null) return false
        if (app.pairingReady()) return false
        if (app.pairingDeferred) return false
        PairingActivity.launch(this)
        return true
    }

    /** Membership status replaces the raw node identifier, and opens the Add-device panel. */
    private fun refreshMembership() {
        val ready = app.pairingReady()
        pairingBanner.visibility = if (ready) View.GONE else View.VISIBLE
        if (!ready) {
            pairingBanner.text = texts.t(
                "pair.not_set_up_banner", R.string.pair_not_set_up_banner,
            )
            nodeInfo.text = texts.t("pair.not_set_up_banner", R.string.pair_not_set_up_banner)
            return
        }
        if (dashboard != null) {
            val pairing = app.core.pairingInfo()
            nodeInfo.text = listOf(
                texts.t("pair.membership", R.string.pair_membership,
                        PairingModel.memberCount(pairing).toString()),
                texts.t("pair.membership_connected", R.string.pair_membership_connected,
                        PairingModel.connectedCount(pairing).toString()),
            ).joinToString(" · ")
            return
        }
        // A visitor sees the door, the core and app versions, and the battery — nothing else.
        val status = statusSnapshot ?: app.core.status()
        val power = status?.optJSONObject("self")?.optJSONObject("power")
        nodeInfo.text = ShellUi.versionLine(
            doorLabel(app.boot.door).ifEmpty { app.boot.name },
            status?.optJSONObject("node")?.optString("version").orEmpty()
                .ifEmpty { app.core.version() },
            appVersionName(),
            power?.optInt("battery_pct", -1) ?: -1,
            power?.optBoolean("charging", false) ?: false,
        ) { texts.t("power.percent", R.string.power_percent, it.toString()) }
    }

    private fun appVersionName(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName.orEmpty()
    } catch (_: Exception) {
        ""
    }

    /** Everything behind the admin password: information, adding devices, setup, kiosk exit. */
    private fun showMaintenanceMenu() {
        val labels = arrayOf<CharSequence>(
            texts.t("settings.title", R.string.settings_title),
            texts.t("admin.menu_info", R.string.admin_menu_info),
            texts.t("admin.menu_add_device", R.string.admin_menu_add_device),
            texts.t("admin.menu_boot_setup", R.string.admin_menu_boot_setup),
            texts.t("admin.menu_exit_kiosk", R.string.admin_menu_exit_kiosk),
        )
        android.app.AlertDialog.Builder(this)
            .setTitle(texts.t("admin.menu_title", R.string.admin_menu_title))
            .setItems(labels) { _, which ->
                when (which) {
                    0 -> SettingsActivity.open(this, app, texts)
                    1 -> DeviceInfoActivity.launch(this)
                    2 -> openAddDevice()
                    3 -> startActivity(BootSetupActivity.reentryIntent(this))
                    4 -> exitKiosk()
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
        sensorManager.unregisterListener(this)
        ui.removeCallbacks(clockTick)
        ui.removeCallbacks(purposeTimeout)
        dashboard?.onPause()
        stopRegionInkWatch()
        if (::sosSlider.isInitialized) sosSlider.cancelCountdown()
        app.unbindForeground(this)
        super.onPause()
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    /** Applies camera mount correction before the first sensor event or without a sensor. */
    @Suppress("DEPRECATION")
    private fun publishDisplayRotationFallback() {
        val deviceRotation = when (windowManager.defaultDisplay.rotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
        val rotation = app.runtime.frameRotationForDeviceRotation(deviceRotation)
        if (rotation != lastVideoRotation) {
            lastVideoRotation = rotation
            app.core.setVideoSensorRotation(rotation)
        }
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_ACCELEROMETER || event.values.size < 2) return
        val x = event.values[0]
        val y = event.values[1]
        // Keep the last angle when the device lies flat and the in-plane gravity is unstable.
        if (kotlin.math.max(kotlin.math.abs(x), kotlin.math.abs(y)) < 4f) return
        val deviceRotation = if (kotlin.math.abs(x) > kotlin.math.abs(y)) {
            if (x > 0) 90 else 270
        } else {
            if (y > 0) 0 else 180
        }
        val rotation = app.runtime.frameRotationForDeviceRotation(deviceRotation)
        if (rotation == lastVideoRotation) return
        lastVideoRotation = rotation
        app.core.setVideoSensorRotation(rotation)
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        applyVisitorLayout()
        buildPurposeButtons()
        dashboard?.onConfigurationChanged()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersive()
    }

    override fun onDestroy() {
        app.unbindForeground(this)
        tts?.shutdown()
        try { audio?.release() } catch (_: Exception) { }
        audio = null
        releasePlayer(effectAudio); effectAudio = null
        releasePlayer(callFeedbackAudio); callFeedbackAudio = null
        releasePlayer(launchAudio); launchAudio = null
        stopRinging()
        super.onDestroy()
    }

    @Deprecated("kiosk 中は戻れない")
    override fun onBackPressed() {
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
        idleHeader = findViewById(R.id.idle_header)
        callSection = findViewById(R.id.call_section)
        clockText = findViewById(R.id.clock_text)
        dateText = findViewById(R.id.date_text)
        callButton = findViewById(R.id.call_button)
        touchHint = findViewById(R.id.touch_hint)
        nodeInfo = findViewById(R.id.node_info)
        pairingBanner = findViewById(R.id.pairing_banner)
        purposeSection = findViewById(R.id.purpose_section)
        purposeHint = findViewById(R.id.purpose_hint)
        purposeAutoHint = findViewById(R.id.purpose_auto_hint)
        purposeGrid = findViewById(R.id.purpose_grid)
        purposeSkipButton = findViewById(R.id.purpose_skip_button)
        purposeCancelButton = findViewById(R.id.purpose_cancel_button)
        langBar = findViewById(R.id.lang_bar)
        callingView = findViewById(R.id.calling_view)
        callingText = findViewById(R.id.calling_text)
        cancelButton = findViewById(R.id.cancel_button)
        pulse = findViewById(R.id.pulse)
        replyBanner = findViewById(R.id.reply_banner)
        replyCaption = findViewById(R.id.reply_caption)
        replyText = findViewById(R.id.reply_text)
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
        sosSlider = SosSlideView(this, ui)
        sosSlot.addView(
            sosSlider,
            android.widget.FrameLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                dp(56),
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
        val now = clusterClock.now()
        // Once a second, so only touch the views when the rendered value actually changed.
        val clockValue = now.clockText()
        if (clockValue != lastClockText) {
            lastClockText = clockValue
            clockText.text = clockValue
        }
        if (now.date == lastClockDate) return
        lastClockDate = now.date
        val parts = now.date.split("-")
        dateText.text = if (parts.size != 3) now.date else String.format(
            Locale.US, "%s年%s月%s日 (%s)",
            parts[0], parts[1].trimStart('0'), parts[2].trimStart('0'),
            YOBI.getOrElse(now.weekdayNum) { "" },
        )
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
        clockText.textSize = VisitorLayout.clockTextSizeSp(widthDp, heightDp)
        touchHint.textSize = VisitorLayout.hintTextSizeSp(widthDp)
        callButton.minHeight = dp(VisitorLayout.callButtonHeightDp(widthDp))
        VisitorLayout.apply(
            visitorSplit, visitorColumnA, visitorColumnB,
            idleHeader, noticeCard, langBar, callSection,
            notice != null, widthDp, heightDp,
        )
        applyFooterLayout(widthDp, heightDp)
        scheduleGroupSpacing()
        scheduleRegionInk()
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
            sosParams.topMargin = dp(6)
        } else {
            infoParams.width = 0
            infoParams.weight = 1f
            sosParams.width = android.view.ViewGroup.LayoutParams.WRAP_CONTENT
            sosParams.topMargin = 0
        }
        nodeInfo.layoutParams = infoParams
        sosSlot.layoutParams = sosParams
        // Two lines rather than a cut-off one: the versions and the battery all have to be read.
        nodeInfo.setSingleLine(false)
        nodeInfo.maxLines = 2
        nodeInfo.ellipsize = null
    }

    /** Light and dark tokens for the door station's own screen (§5.1). */
    private fun applyAppearance() {
        // Core resolves the schedule in the cluster time zone; the shell only adds the platform's
        // own light/dark setting for auto_system, and computes everything locally on an older core.
        val appearance = coreDisplay.appearance
        palette = if (appearance != null)
            Appearance.palette(CoreDisplays.isDark(appearance, systemDarkMode(this)))
        else Appearance.resolve(
            cfg, nodeId, systemDarkMode(this), clusterClock.now().minuteOfDay(),
        )
        if (dashboard != null) return
        // A configured background colour or image wins; the palette ground is the fallback.
        if (themeValue("bg_color") == null && themeValue("bg_image").isNullOrEmpty())
            rootView.setBackgroundColor(ShellUi.opaque(palette.ground))
        regionInkApplied.clear()
        applyRegionInk()
        sosSlider.applyPalette(palette)
        applyCallButtonAccent()
    }

    /**
     * Automatic ink per text region (§5). Core averages the whole background image because it has
     * no layout geometry, so each region is sampled locally and the result refines core's answer;
     * an administrator override still wins, and a flat background colour leaves core's value
     * standing. A region that misses 4.5:1 gets the 40 % opposite-ink shadow behind it.
     */
    private fun applyRegionInk() {
        paintRegion(clockText, "clock", muted = false)
        paintRegion(dateText, "date", muted = true)
        paintRegion(touchHint, "hint", muted = true)
        paintRegion(nodeInfo, "footer", muted = true)
    }

    /** The last ink applied per region, so a layout pass that changes nothing does no work. */
    private val regionInkApplied = HashMap<String, Int>()

    private fun paintRegion(view: TextView, region: String, muted: Boolean) {
        // The flat colour a visitor would see with no picture on screen; never core's average of
        // the picture, which is only meaningful while the picture is actually painted.
        val ground = flatBackgroundRgb()
        val drawn = themeBg.visibility == View.VISIBLE && themeBg.drawable != null
        val sample = if (drawn) RegionInk.sample(themeBg, view, ground) else null
        val result = CoreDisplays.inkFor(
            coreDisplay.theme, region, ground, sample?.averageRgb, drawn, sample = sample,
        )
        val ink = if (muted) ShellUi.mute(result.inkRgb, palette.dark) else result.inkRgb
        val signature = (if (result.needsShadow) 1 shl 25 else 0) or (ink and 0xffffff)
        if (regionInkApplied[region] == signature) return
        regionInkApplied[region] = signature
        view.setTextColor(ShellUi.opaque(ink))
        if (result.needsShadow) {
            val shadow = ShellUi.opaque(result.shadowRgb) and 0x00ffffff or
                (RegionInkPolicy.SHADOW_ALPHA shl 24)
            view.setShadowLayer(1f * resources.displayMetrics.density, 0f, 0f, shadow)
        } else {
            view.setShadowLayer(0f, 0f, 0f, 0)
        }
    }

    /**
     * The regions move under the picture on every layout, and the picture itself arrives long
     * after the first one. Both have to re-run the decision, or the screen keeps the ink it chose
     * against a background nobody is looking at any more -- which is how a light illustration ended
     * up carrying light text.
     */
    private fun scheduleRegionInk() {
        if (dashboard != null) return
        rootView.post { if (!isFinishing) applyRegionInk() }
    }

    private val regionInkOnLayout = android.view.ViewTreeObserver.OnGlobalLayoutListener {
        if (!isFinishing) applyRegionInk()
    }

    private fun startRegionInkWatch() {
        if (dashboard != null) return
        rootView.viewTreeObserver.addOnGlobalLayoutListener(regionInkOnLayout)
    }

    private fun stopRegionInkWatch() {
        if (dashboard != null) return
        @Suppress("DEPRECATION")
        rootView.viewTreeObserver.removeGlobalOnLayoutListener(regionInkOnLayout)
    }

    /** The flat colour behind the visitor screen, with no background image taken into account. */
    private fun flatBackgroundRgb(): Int =
        UiContrast.parseRgb(themeValue("bg_color")) ?: palette.ground

    /** The colour actually behind the visitor screen, averaged by core when it is an image. */
    private fun effectiveBackgroundRgb(): Int =
        coreDisplay.theme?.backgroundRgb
            ?: UiContrast.parseRgb(themeValue("bg_color"))
            ?: palette.ground

    /**
     * The call button's background comes from core, which has already folded in the administrator
     * override; its text colour always comes from call_button_ink, because on a mid-luminance
     * background core returns the best compromise rather than an unreadable button (§5.2).
     */
    private fun applyCallButtonAccent() {
        val (background, ink) = CoreDisplays.callButton(
            coreDisplay.theme, effectiveBackgroundRgb(),
        )
        callButton.background = ShellUi.rounded(this, background, 14)
        callButton.setTextColor(ShellUi.opaque(ink))
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
        dashboard?.refresh()
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
        ) { seconds -> texts.t("sos.countdown", R.string.sos_countdown, seconds.toString()) }
        sosSlot.visibility = if (sosVisibleForRole()) View.VISIBLE else View.GONE
    }

    /** emergency.button_on_roles decides whether this device offers the slider at all. */
    private fun sosVisibleForRole(): Boolean {
        val roles = app.core.dig(cfg, "emergency.button_on_roles") as? JSONArray ?: return true
        if (roles.length() == 0) return true
        for (index in 0 until roles.length())
            if (roles.optString(index) == app.boot.role) return true
        return false
    }

    private fun applySemanticUi() {
        val styleConfig = if (app.safeMode) null else cfg
        SemanticUi.apply(callButton, "call.primary", styleConfig, nodeId)
        SemanticUi.apply(purposeSkipButton, "call.primary", styleConfig, nodeId)
        SemanticUi.apply(purposeCancelButton, "cancel.call", styleConfig, nodeId)
        SemanticUi.apply(cancelButton, "cancel.call", styleConfig, nodeId)
        for (index in 0 until purposeGrid.childCount)
            SemanticUi.apply(purposeGrid.getChildAt(index), "purpose.button", styleConfig, nodeId)
        SemanticUi.apply(offlineTitle, "status.offline", styleConfig, nodeId)
        SemanticUi.apply(offlineBody, "status.offline", styleConfig, nodeId)
    }

    // Localized text: configuration overrides precede generated resources.

    /** Reapply all labels after a visitor-language change. */
    private fun applyStrings() {
        // Just the verb. A visitor has no use for the device or door identifier, and it made the
        // button read "DOORBELL-ANDROID 呼出" on the Moto; the door name lives in the footer.
        callButton.text = texts.t("door.call_action", R.string.door_call_action)
        touchHint.text = texts.t("door.hint_call", R.string.door_hint_call)
        purposeHint.text = texts.t("idle.choose_purpose", R.string.idle_choose_purpose)
        purposeAutoHint.text = texts.t("calling.title", R.string.calling_title)
        purposeSkipButton.text = texts.t("purpose.skip", R.string.purpose_skip)
        purposeCancelButton.text = texts.t("purpose.cancel_call", R.string.purpose_cancel_call)
        callingText.text = texts.t("calling.title", R.string.calling_title)
        updateCallActionLabel()
        replyCaption.text = texts.t("reply.banner", R.string.reply_banner)
        offlineTitle.text = texts.t("offline.title", R.string.offline_title)
        offlineBody.text = texts.t("offline.body", R.string.offline_body)
    }

    /** Resolve a door label by current language, Japanese fallback, then identifier. */
    private fun doorLabel(door: String): String {
        if (door.isEmpty()) return ""
        val l = app.core.dig(cfg, "doors.$door.label.${texts.lang}")
            ?: app.core.dig(cfg, "doors.$door.label.ja")
        return l?.toString() ?: door
    }

    // Theme, purpose, and visitor-language configuration.

    private fun refreshConfigCache() {
        cfg = app.core.config()
        texts.setConfig(cfg)
        callFlowMode = CallFlowMode.parse(app.core.dig(cfg, "ui.call_flow")?.toString().orEmpty())
        val ttlSeconds = (app.core.dig(cfg, "ui.call_ttl_s") as? Number)?.toLong() ?: 60L
        app.callFlow.configure(
            if (callFlowMode == CallFlowMode.RING_THEN_PURPOSE)
                "ring_then_purpose" else "purpose_first",
            ttlSeconds,
        )
    }

    private fun updateCallActionLabel() {
        cancelButton.text = if (callUiPhase == CallUiPhase.ESTABLISHED)
            texts.t("incall.end", R.string.incall_end)
        else texts.t("calling.cancel", R.string.calling_cancel)
    }

    /** Resolve device-local theme values before fleet defaults. */
    private fun themeValue(leaf: String): String? {
        val v = (if (nodeId.isNotEmpty()) app.core.dig(cfg, "devices.$nodeId.local.theme.$leaf")
                 else null)
            ?: app.core.dig(cfg, "display.theme.$leaf")
        val s = v?.toString().orEmpty()
        return if (s.isEmpty() || s == "null") null else s
    }

    private fun applyTheme() {
        if (app.safeMode) {
            themeHash = null
            themeColor = null
            themeBg.setImageDrawable(null)
            themeBg.visibility = View.GONE
            @Suppress("DEPRECATION")
            rootView.setBackgroundColor(resources.getColor(R.color.bg))
            return
        }
        val color = themeValue("bg_color")
        if (color != themeColor) {
            themeColor = color
            try {
                @Suppress("DEPRECATION")
                rootView.setBackgroundColor(
                    if (color != null) Color.parseColor(color) else resources.getColor(R.color.bg))
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

    /** Load a bounded background image from the LAN-public local asset endpoint. */
    private fun loadThemeImage(hash: String) {
        if (app.safeMode) return
        val url = "http://127.0.0.1:${app.boot.httpPort}/asset/$hash"
        Thread({
            var bmp: Bitmap? = null
            var conn: HttpURLConnection? = null
            try {
                conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 4000
                conn.readTimeout = 8000
                val bytes = BoundedBitmapDecoder.readLimited(conn.inputStream, 4 * 1024 * 1024)
                bmp = bytes?.let { BoundedBitmapDecoder.decode(it, 1920, 1080) }
            } catch (e: Exception) {
                // asset_ready triggers another attempt after mesh prefetch completes.
                Log.w(TAG, "Theme background is not available yet: $e")
            } finally {
                try { conn?.disconnect() } catch (_: Exception) { }
            }
            val b = bmp ?: return@Thread
            ui.post {
                if (themeHash != hash || app.safeMode) return@post
                themeBg.setImageBitmap(b)
                themeBg.visibility = View.VISIBLE
                // The background under every region just changed, so nothing decided against the
                // previous one may be kept.
                regionInkApplied.clear()
                scheduleRegionInk()
            }
        }, "theme-bg").apply { isDaemon = true }.start()
    }

    /** Apply a night tint above potentially bright theme imagery. */
    private fun applyNightTint(night: Boolean, redTint: Boolean) {
        nightTint.visibility = if (night && redTint) View.VISIBLE else View.GONE
    }

    /**
     * Build visit-purpose controls for the door-station idle screen. A purpose an administrator
     * disabled is never offered; when every purpose is off the chooser behaves exactly as it does
     * with none configured, so the visitor goes straight on with the call.
     */
    private fun buildPurposeButtons() {
        purposeGrid.removeAllViews()
        if (app.boot.role != "door_station") {
            purposeSection.visibility = View.GONE
            return
        }
        val ids = VisitPurposes.enabled(cfg)
        if (ids.isEmpty()) {
            purposeGrid.columnCount = 1
            purposeSection.visibility = if (choosingPurpose) View.VISIBLE else View.GONE
            return
        }
        val widthDp = resources.displayMetrics.widthPixels / resources.displayMetrics.density
        val columns = when {
            ids.size <= 1 -> 1
            widthDp < 520f -> 2
            else -> minOf(3, ids.size)
        }
        purposeGrid.columnCount = columns
        val rows = (ids.size + columns - 1) / columns
        val buttonHeight = when {
            rows >= 3 -> 48
            rows == 2 -> 50
            else -> 64
        }
        val textSize = if (rows >= 2 || columns == 2) 14f else 16f
        for ((index, id) in ids.withIndex()) {
            val label = VisitPurposes.label(cfg, id, texts.lang)
            val b = Button(this)
            b.text = VisitPurposes.decoratedLabel(cfg, id, texts.lang)
            b.textSize = textSize
            b.isAllCaps = false
            b.setSingleLine(false)
            b.maxLines = 2
            b.gravity = android.view.Gravity.CENTER
            b.setPadding(dp(8), 0, dp(8), 0)
            @Suppress("DEPRECATION")
            b.setTextColor(resources.getColor(R.color.fg))
            @Suppress("DEPRECATION")
            b.background = resources.getDrawable(R.drawable.bg_tv_button)
            b.isFocusable = true
            b.setOnClickListener { onPurposeClick(id, label) }
            val lp = GridLayout.LayoutParams()
            lp.rowSpec = GridLayout.spec(index / columns)
            lp.columnSpec = GridLayout.spec(index % columns)
            lp.width = (resources.displayMetrics.widthPixels - dp(32)) / columns - dp(8)
            lp.height = dp(buttonHeight)
            lp.setMargins(dp(4), dp(3), dp(4), dp(3))
            purposeGrid.addView(b, lp)
        }
        purposeSection.visibility = if (choosingPurpose) View.VISIBLE else View.GONE
    }

    private fun onPurposeClick(id: String, label: String) {
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
        langBar.removeAllViews()
        val arr = app.core.dig(cfg, "ui.languages") as? JSONArray
        val list = ArrayList<String>()
        if (arr != null) {
            for (i in 0 until arr.length()) {
                val s = arr.optString(i)
                if (s.isNotEmpty()) list.add(s)
            }
        }
        if (app.boot.role != "door_station" || list.size < 2) {
            langBar.visibility = View.GONE
            return
        }
        for (l in list) {
            val b = Button(this)
            b.text = Texts.langDisplayName(l)
            b.textSize = 15f
            b.isAllCaps = false
            b.isFocusable = true
            b.gravity = android.view.Gravity.CENTER
            b.includeFontPadding = false
            b.minWidth = 0
            b.minHeight = 0
            b.minimumWidth = 0
            b.minimumHeight = 0
            b.setPadding(0, 0, 0, 0)
            b.tag = l
            @Suppress("DEPRECATION")
            b.background = resources.getDrawable(R.drawable.bg_tv_button)
            b.setOnClickListener { onLangClick(l) }
            val lp = LinearLayout.LayoutParams(dp(104), dp(42))
            lp.leftMargin = dp(4)
            lp.rightMargin = dp(4)
            langBar.addView(b, lp)
        }
        // The visitor keeps the language row on the idle screen, not only while choosing.
        langBar.visibility = View.VISIBLE
        updateLangBarSelection()
    }

    private fun updateLangBarSelection() {
        for (i in 0 until langBar.childCount) {
            val b = langBar.getChildAt(i) as? Button ?: continue
            @Suppress("DEPRECATION")
            b.setTextColor(resources.getColor(
                if (b.tag == visitorLang) R.color.accent else R.color.dim))
        }
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
        applyStrings()
        buildPurposeButtons()
        updateLangBarSelection()
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
        if (showsDashboard) {
            restoreRoleHome()
            updateCallActionLabel()
            return
        }
        callingView.visibility = View.GONE
        idleView.visibility = View.VISIBLE
        idleHeader.visibility = View.VISIBLE
        callSection.visibility = View.VISIBLE
        purposeSection.visibility = View.GONE
        langBar.visibility = if (langBar.childCount > 0) View.VISIBLE else View.GONE
        purposeCancelButton.visibility = View.GONE
        touchHint.text = hint ?: texts.t("door.hint_call", R.string.door_hint_call)
        updateCallActionLabel()
    }

    private fun showPurposeChooser() {
        if (showsDashboard) return
        choosingPurpose = true
        idleView.visibility = View.VISIBLE
        callingView.visibility = View.GONE
        offlineView.visibility = View.GONE
        idleHeader.visibility = View.GONE
        callSection.visibility = View.GONE
        purposeSection.visibility = View.VISIBLE
        purposeAutoHint.visibility =
            if (uiCallId.isNotEmpty()) View.VISIBLE else View.GONE
        purposeCancelButton.visibility =
            if (uiCallId.isNotEmpty()) View.VISIBLE else View.GONE
        langBar.visibility = if (langBar.childCount > 0) View.VISIBLE else View.GONE
        ui.removeCallbacks(purposeTimeout)
        ui.postDelayed(purposeTimeout, PURPOSE_TIMEOUT_MS)
        scheduleCallTimeout()
    }

    /** Show ringing while preserving an explicit purpose confirmation title. */
    private fun showCalling(title: String? = null) {
        if (showsDashboard) return
        choosingPurpose = false
        ui.removeCallbacks(purposeTimeout)
        if (title != null) callTitleOverride = title
        callingText.text = callTitleOverride ?: texts.t("calling.title", R.string.calling_title)
        updateCallActionLabel()
        idleView.visibility = View.GONE
        callingView.visibility = View.VISIBLE
        scheduleCallTimeout()
        if (app.safeMode) pulse.clearAnimation()
        else pulse.startAnimation(AlphaAnimation(0.25f, 1.0f).apply {
                duration = 900
                repeatMode = Animation.REVERSE
                repeatCount = Animation.INFINITE
            })
    }

    private fun showEstablished() {
        if (showsDashboard) return
        choosingPurpose = false
        ui.removeCallbacks(purposeTimeout)
        ui.removeCallbacks(callTimeout)
        stopCallFeedback()
        pulse.clearAnimation()
        callingText.text = texts.t("incall.title", R.string.incall_title)
        idleView.visibility = View.GONE
        offlineView.visibility = View.GONE
        callingView.visibility = View.VISIBLE
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
        offlineView.visibility = View.VISIBLE
    }

    // Marshal Core-thread callbacks to the UI thread.

    override fun onUiEvent(ev: JSONObject) {
        ui.post { handleUiEvent(ev) }
    }

    override fun onTts(text: String, lang: String) {
        ui.post { speakNow(text, lang) }
    }

    private fun speakNow(text: String, lang: String) {
        if (!ttsReady || text.isEmpty()) return
        try {
            tts?.language = Locale(if (lang.isEmpty()) "ja" else lang)
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT >= 21)
                tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "reply")
            else
                tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null)
        } catch (_: Exception) { }
    }

    private fun handleUiEvent(ev: JSONObject) {
        when (ev.optString("t")) {
            "runtime" -> {
                if (ev.optString("state") == "ready") {
                    // Core only publishes pairing state once its runtime is up, so the
                    // membership check is repeated here rather than only in onResume.
                    if (maybeShowPairing()) return
                    refreshNodeInfo()
                    restoreCurrentCallUi()
                    restoreRequestedCall(intent)
                    maybeStartCamera()
                } else showOffline()
            }
            "memory_pressure" -> {
                if (ev.optInt("level") >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) {
                    themeBg.setImageDrawable(null)
                    releasePlayer(effectAudio); effectAudio = null
                    releasePlayer(callFeedbackAudio); callFeedbackAudio = null
                    releasePlayer(launchAudio); launchAudio = null
                }
            }
            "pairing_state", "pairing_revoked", "peers_changed" -> refreshMembership()
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
            // Prefer the configured asset and fall back to a built-in tone.
            "chime" -> playAudio(ev.optString("audio_path")) {
                val sound = ev.optString("sound", "ding1")
                if (!playConfiguredInto(sound, false) { audio = it }) playChimeTone(sound)
            }
            "reply" -> {
                // Core already spoke replies without custom audio, so avoid duplicate TTS.
                val path = ev.optString("audio_path")
                if (path.isNotEmpty()) {
                    val spoken = ev.optString("text")
                    val spokenLang = ev.optString("lang")
                    playAudio(path) { speakNow(spoken, spokenLang) }
                }
                replyText.text = ev.optString("text")
                replyBanner.visibility = View.VISIBLE
                var ttl = ev.optDouble("ttl_s", 30.0)
                if (ttl <= 0) ttl = 30.0
                ui.removeCallbacks(replyTimeout)
                ui.postDelayed(replyTimeout, (ttl * 1000).toLong())
                val replyDoor = ev.optString("door")
                if (replyDoor.isEmpty() || replyDoor == app.boot.door) {
                    clearCallProjection()
                    showIdle()
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
                val h = themeHash
                if (!app.safeMode && h != null && ev.optString("hash") == h &&
                    themeBg.drawable == null)
                    loadThemeImage(h)
            }
            "display" -> {
                coreDisplay = CoreDisplays.parse(ev)
                applyNightTint(ev.optBoolean("night"), ev.optBoolean("red_tint"))
                applyAppearance()
                applyVisitorLayout()
                dashboard?.refresh()
            }
            // Cluster time, battery, and announcements each redraw only what they affect.
            "time_changed" -> {
                updateClock()
                applyAppearance()
                dashboard?.refresh()
            }
            "power_changed" -> {
                refreshMembership()
                dashboard?.refresh()
            }
            // A door of "*" means the cluster-wide announcement moved, which affects every
            // door that has none of its own.
            "notice_changed" -> {
                statusSnapshot = app.core.status()
                applyVisitorLayout()
                dashboard?.refresh()
            }
            "call_log_changed" -> dashboard?.refresh()
            "peers_changed", "config_changed" -> refreshNodeInfo()
            "event" -> {
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

    /** Play a local asset, falling back to TTS or a built-in sound. */
    private fun playAudio(path: String, fallback: () -> Unit) {
        if (path.isEmpty() || !File(path).exists()) {
            fallback()
            return
        }
        try {
            try { audio?.release() } catch (_: Exception) { }
            audio = null
            val mp = MediaPlayer()
            audio = mp
            mp.setOnErrorListener { _, what, extra ->
                Log.w(TAG, "Custom audio playback failed ($what/$extra); using fallback")
                try { mp.release() } catch (_: Exception) { }
                if (audio === mp) audio = null
                ui.post { fallback() }
                true
            }
            mp.setOnCompletionListener {
                try { it.release() } catch (_: Exception) { }
                if (audio === mp) audio = null
            }
            mp.setDataSource(path)
            mp.prepare()
            mp.start()
        } catch (e: Exception) {
            Log.w(TAG, "Cannot open custom audio; using fallback: $e")
            fallback()
        }
    }

    private fun playChimeTone(sound: String) {
        try {
            try { chimeTone?.release() } catch (_: Exception) { }
            val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 90)
            chimeTone = tone
            val kind = when (sound) {
                "ding2" -> ToneGenerator.TONE_PROP_BEEP
                "classic" -> ToneGenerator.TONE_SUP_RINGTONE
                else -> ToneGenerator.TONE_PROP_BEEP2
            }
            val duration = if (sound == "classic") 1400 else if (sound == "ding2") 700 else 450
            tone.startTone(kind, duration)
            ui.postDelayed({
                if (chimeTone === tone) {
                    try { tone.release() } catch (_: Exception) { }
                    chimeTone = null
                }
            }, (duration + 100).toLong())
        } catch (_: Exception) { }
    }

    /** Play immediate feedback after accepting the visitor's call action. */
    private fun playCallFeedback() {
        stopCallFeedback()
        val value = configuredSound("call_sound", "outdoor_call_alert")
        if (value.isEmpty()) return
        val loop = (app.core.dig(cfg, "ui.call_sound_loop") as? Boolean) ?: false
        if (!playConfiguredInto(value, loop) { callFeedbackAudio = it }) {
            try {
                val tone = ToneGenerator(AudioManager.STREAM_MUSIC, 75)
                tone.startTone(ToneGenerator.TONE_PROP_ACK, 140)
                ui.postDelayed({ try { tone.release() } catch (_: Exception) { } }, 220)
            } catch (_: Exception) { }
        }
    }

    private fun configuredSound(key: String, fallback: String): String {
        val value = app.core.dig(cfg, "ui.$key")
        return if (value is String) value else fallback
    }

    private fun bundledSoundFile(value: String): String? = when (value) {
        "outdoor_call_alert" -> "outdoor_call_alert.mp3"
        "button_click" -> "button_click.mp3"
        "school_chime" -> "学校のチャイム.mp3"
        "indoor_update" -> "indoor_update.mp3"
        "title_display" -> "title_display.mp3"
        else -> null
    }

    private fun makeConfiguredPlayer(value: String, loop: Boolean): MediaPlayer? {
        if (value.isEmpty()) return null
        return try {
            val mp = MediaPlayer()
            if (value.startsWith("asset:") && value.length == 70) {
                val file = File(File(filesDir, "assets"), value.substring(6))
                if (!file.exists()) { mp.release(); return null }
                mp.setDataSource(file.absolutePath)
            } else {
                val name = bundledSoundFile(value) ?: run { mp.release(); return null }
                assets.openFd("audio/$name").use { fd ->
                    mp.setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
                }
            }
            mp.isLooping = loop
            mp.prepare()
            mp
        } catch (e: Exception) {
            Log.w(TAG, "Cannot open bundled or configured audio: $value ($e)")
            null
        }
    }

    private fun playConfiguredInto(value: String, loop: Boolean,
                                   assign: (MediaPlayer?) -> Unit): Boolean {
        val mp = makeConfiguredPlayer(value, loop) ?: return false
        assign(mp)
        mp.setOnCompletionListener {
            if (!it.isLooping) {
                try { it.release() } catch (_: Exception) { }
                assign(null)
            }
        }
        mp.start()
        return true
    }

    private fun releasePlayer(player: MediaPlayer?) {
        try { player?.stop() } catch (_: Exception) { }
        try { player?.release() } catch (_: Exception) { }
    }

    private fun playButtonSound() {
        releasePlayer(effectAudio)
        effectAudio = null
        playConfiguredInto(configuredSound("button_sound", "button_click"), false) {
            effectAudio = it
        }
    }

    private fun playUpdateSound() {
        releasePlayer(effectAudio)
        effectAudio = null
        playConfiguredInto(configuredSound("update_sound", "indoor_update"), false) {
            effectAudio = it
        }
    }

    private fun playLaunchSound() {
        releasePlayer(launchAudio)
        launchAudio = null
        playConfiguredInto(configuredSound("launch_sound", "title_display"), false) {
            launchAudio = it
        }
    }

    private fun stopCallFeedback() {
        releasePlayer(callFeedbackAudio)
        callFeedbackAudio = null
    }

    private fun stopRinging() {
        stopCallFeedback()
        try { audio?.stop() } catch (_: Exception) { }
        try { audio?.release() } catch (_: Exception) { }
        audio = null
        try { chimeTone?.stopTone() } catch (_: Exception) { }
        try { chimeTone?.release() } catch (_: Exception) { }
        chimeTone = null
    }

    // Visitor actions.

    private fun onCallClick() {
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
        showPurposeChooser()
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

    private fun endOrCancelCall() {
        playButtonSound()
        ui.removeCallbacks(callTimeout)
        val active = app.callFlow.current()
        val transition = if (active?.phase == CallUiPhase.ESTABLISHED)
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

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>,
                                            grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
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
        private val YOBI = arrayOf("日", "月", "火", "水", "木", "金", "土")

        private const val PURPOSE_TIMEOUT_MS = 15_000L
        private const val CANCEL_RECONCILE_MS = 500L
    }
}
