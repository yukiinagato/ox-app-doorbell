// Indoor/TV visitor monitor with adaptive video, direct SIP monitor/answer modes, and localized
// quick replies. It supports touch and D-pad input and can appear above the lock screen.
package jp.ox.doorbell

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.TextureView
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject

class IncomingActivity : Activity() {

    private val ui = Handler(Looper.getMainLooper())
    private lateinit var app: App
    private lateinit var texts: Texts
    private var door = ""
    private var purpose = ""
    private var visitorLang = ""
    private var callId = ""
    private var stageRevision = 0
    private var revisionLifecycle = CallRevisionLifecycle(0)
    private var expiresAtMs = 0L
    private var videoPlayer: AdaptiveVideoPlayer? = null
    private var sipCalling = false
    private var inCall = false
    private var answerRequested = false  // The answer INVITE is active or waiting to start.
    private var answerDelayPending = false // Do not close on Idle while replacing monitor mode.
    private var peerHost: String? = null
    private var directPort = DIRECT_PORT
    private lateinit var clusterClock: ClusterClock
    private lateinit var sosSlider: SosSlideView
    private var palette: Palette = Palette.DARK
    private var cachedConfig: JSONObject? = null
    private var cachedStatus: JSONObject? = null

    /** モニター ON/OFF: whether the door's audio is being played on this panel. */
    private var monitorOn = true

    /** マイク: only meaningful once the answer leg is up. */
    private var micMuted = false

    /** The debug line is remembered per device, so it stays hidden once it is dismissed. */
    private var debugVisible = true
    private val debugTick = object : Runnable {
        override fun run() {
            updateDebugLine()
            ui.postDelayed(this, DEBUG_INTERVAL_MS)
        }
    }
    private lateinit var audioManager: AudioManager
    private var oldAudioMode = AudioManager.MODE_NORMAL
    private var oldSpeakerphone = false
    private val autoClose = Runnable { finish() }
    private val answerReplaceTimeout = Runnable {
        if (answerDelayPending) {
            answerDelayPending = false
            answerRequested = false
            finish()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        oldAudioMode = audioManager.mode
        oldSpeakerphone = audioManager.isSpeakerphoneOn
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        @Suppress("DEPRECATION")
        audioManager.isSpeakerphoneOn = true
        app.incomingActivity = this
        door = intent?.getStringExtra(EXTRA_DOOR) ?: ""
        purpose = intent?.getStringExtra(EXTRA_PURPOSE) ?: ""
        visitorLang = intent?.getStringExtra(EXTRA_LANG) ?: ""
        callId = intent?.getStringExtra(EXTRA_CALL_ID) ?: ""
        stageRevision = intent?.getIntExtra(EXTRA_STAGE_REVISION, 0) ?: 0
        revisionLifecycle = CallRevisionLifecycle(stageRevision)
        expiresAtMs = intent?.getLongExtra(EXTRA_EXPIRES_AT_MS, 0L) ?: 0L
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Alert on the lock screen when Device Owner policy has not disabled keyguard.
        if (Build.VERSION.SDK_INT >= 27) {
            IncomingWindowApi27.apply(this)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD)
        }
        setContentView(R.layout.activity_incoming)

        val cfg = app.core.config()
        val st = app.core.status()
        cachedConfig = cfg
        cachedStatus = st
        texts = Texts(this)
        texts.setConfig(cfg)
        texts.setLang(app.boot.uiLang)
        clusterClock = ClusterClock(app.core)
        debugVisible = getSharedPreferences(PREFS, MODE_PRIVATE)
            .getBoolean(PREF_DEBUG_VISIBLE, true)
        val appearance = CoreDisplays.parse(st?.optJSONObject("display")).appearance
        palette = if (appearance != null)
            Appearance.palette(CoreDisplays.isDark(appearance, systemDarkMode(this)))
        else Appearance.resolve(
            cfg,
            st?.optJSONObject("node")?.optString("id").orEmpty(),
            systemDarkMode(this),
            clusterClock.now().minuteOfDay(),
        )

        findViewById<TextView>(R.id.door_label).text = doorLabel()
        findViewById<TextView>(R.id.status_text).text =
            texts.t("reply.choose", R.string.reply_choose)
        findViewById<TextView>(R.id.audio_hint).text =
            texts.t("ring.monitoring", R.string.ring_monitoring)
        findViewById<TextView>(R.id.no_video_text).text =
            texts.t("ring.no_video", R.string.ring_no_video)
        updateBadges(cfg)

        val close = findViewById<Button>(R.id.close_button)
        close.text = texts.t("ring.ignore", R.string.ring_ignore)
        close.setOnClickListener { finish() }

        sosSlider = SosSlideView(this, ui)
        sosSlider.enabledProvider = { app.coreOk }
        sosSlider.onTrigger = { app.commitEmergency(true) }
        findViewById<android.widget.FrameLayout>(R.id.sos_slot).addView(
            sosSlider,
            android.widget.FrameLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT, dp(56),
            ),
        )
        applyAppearance()
        buildControlRow(cfg)
        buildNoticeChip()
        buildAdminQr(st)
        buildReplyButtons(cfg)

        // Resolve the confirmed door peer for video and direct SIP.
        val peer = findDoorPeer(st)
        peerHost = resolvePeerHost(peer)
        directPort = (app.core.dig(cfg, "sip.direct_port") as? Number)?.toInt() ?: DIRECT_PORT
        startVideo(peer)
        startAudio()

        // Disable answering until a confirmed peer address is available.
        val answer = findViewById<Button>(R.id.answer_button)
        answer.text = texts.t("ring.answer", R.string.ring_answer)
        answer.isEnabled = peerHost != null
        answer.setOnClickListener { onAnswerClick(answer) }
        applySemanticUi(cfg, st)
        ui.post(debugTick)

        // Bound unanswered video and monitor-audio resource use.
        scheduleAutoClose()
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Refresh metadata and timeout for a newer chime, but never replace an established call.
        val requestedDoor = intent?.getStringExtra(EXTRA_DOOR).orEmpty()
        val newDoor = requestedDoor.ifEmpty { door }
        val p = intent?.getStringExtra(EXTRA_PURPOSE)
        val l = intent?.getStringExtra(EXTRA_LANG)
        val newCallId = intent?.getStringExtra(EXTRA_CALL_ID).orEmpty()
        val newStage = intent?.getIntExtra(EXTRA_STAGE_REVISION, 0) ?: 0
        val newExpiry = intent?.getLongExtra(EXTRA_EXPIRES_AT_MS, 0L) ?: 0L
        if (callId.isNotEmpty() && newCallId.isNotEmpty() && newCallId != callId) {
            if (inCall || answerRequested) return
            switchIncomingDoor(newDoor, p.orEmpty(), l.orEmpty(), newCallId, newStage, newExpiry)
            return
        }
        if (newCallId == callId && newStage < stageRevision) return
        if (newDoor != door) {
            // A new door can replace ringing or monitoring, but never an established call.
            if (inCall || answerRequested) return
            switchIncomingDoor(newDoor, p.orEmpty(), l.orEmpty(), newCallId, newStage, newExpiry)
            return
        }
        if (newCallId.isNotEmpty()) callId = newCallId
        if (newStage > stageRevision) {
            val update = revisionLifecycle.observeWinningRevision(newStage)
            if (update == CallRevisionUpdate.ANSWER_SUPERSEDED) demoteSupersededAnswer()
            stageRevision = revisionLifecycle.stageRevision
        }
        if (newExpiry > 0L) expiresAtMs = newExpiry
        if (p != null || l != null) {
            purpose = p ?: ""
            visitorLang = l ?: ""
            val cfg = app.core.config()
            updateBadges(cfg)
            buildReplyButtons(cfg)
            applySemanticUi(cfg, app.core.status())
        }
        if (!inCall && !answerRequested) scheduleAutoClose()
    }

    private fun switchIncomingDoor(
        newDoor: String,
        newPurpose: String,
        newLang: String,
        newCallId: String,
        newStage: Int,
        newExpiry: Long,
    ) {
        ui.removeCallbacksAndMessages(null)  // Also cancels a delayed answer for the old door.
        videoPlayer?.stop()
        videoPlayer = null
        if (sipCalling) app.core.sipHangup()
        sipCalling = false
        inCall = false
        answerRequested = false
        answerDelayPending = false
        door = newDoor
        purpose = newPurpose
        visitorLang = newLang
        callId = newCallId
        stageRevision = newStage
        revisionLifecycle = CallRevisionLifecycle(newStage)
        expiresAtMs = newExpiry

        val cfg = app.core.config()
        val st = app.core.status()
        texts.setConfig(cfg)
        cachedConfig = cfg
        cachedStatus = st
        findViewById<TextView>(R.id.door_label).text = doorLabel()
        findViewById<TextView>(R.id.status_text).text =
            texts.t("reply.choose", R.string.reply_choose)
        findViewById<TextView>(R.id.audio_hint).visibility = View.GONE
        monitorOn = true
        micMuted = false
        updateBadges(cfg)
        buildControlRow(cfg)
        buildNoticeChip()
        buildAdminQr(st)
        buildReplyButtons(cfg)

        val peer = findDoorPeer(st)
        peerHost = resolvePeerHost(peer)
        directPort = (app.core.dig(cfg, "sip.direct_port") as? Number)?.toInt() ?: DIRECT_PORT
        startVideo(peer)
        startAudio()
        findViewById<Button>(R.id.answer_button).apply {
            text = texts.t("ring.answer", R.string.ring_answer)
            isEnabled = peerHost != null
        }
        applySemanticUi(cfg, st)
        scheduleAutoClose()
    }

    override fun onDestroy() {
        if (app.incomingActivity === this) app.incomingActivity = null
        ui.removeCallbacks(debugTick)
        if (::sosSlider.isInitialized) sosSlider.cancelCountdown()
        ui.removeCallbacksAndMessages(null)
        answerRequested = false
        answerDelayPending = false
        videoPlayer?.stop()
        videoPlayer = null
        if (sipCalling) app.core.sipHangup()
        app.abandonPendingManualSipAnswer(callId)
        @Suppress("DEPRECATION")
        audioManager.isSpeakerphoneOn = oldSpeakerphone
        audioManager.mode = oldAudioMode
        super.onDestroy()
    }

    /** Show cancellation briefly before closing the visitor monitor. */
    fun onCallCancelled(cancelledDoor: String, cancelledCallId: String, cancelledStage: Int) {
        runOnUiThread {
            if (!matchesCall(cancelledDoor, cancelledCallId, cancelledStage)) return@runOnUiThread
            if (isFinishing || inCall || answerRequested) return@runOnUiThread
            findViewById<TextView>(R.id.status_text).text =
                texts.t("ring.cancelled", R.string.ring_cancelled)
            ui.removeCallbacks(autoClose)
            ui.postDelayed(autoClose, CANCELLED_CLOSE_MS)
        }
    }

    fun onPurposeSelected(
        selectedDoor: String,
        selectedCallId: String,
        selectedStage: Int,
        selectedExpiry: Long,
        selectedPurpose: String,
        selectedLang: String,
    ) {
        runOnUiThread {
            if (!matchesCall(selectedDoor, selectedCallId, selectedStage)) return@runOnUiThread
            if (isFinishing) return@runOnUiThread
            val update = revisionLifecycle.observeWinningRevision(selectedStage)
            if (update == CallRevisionUpdate.STALE) return@runOnUiThread
            if (update == CallRevisionUpdate.ANSWER_SUPERSEDED) demoteSupersededAnswer()
            stageRevision = revisionLifecycle.stageRevision
            if (selectedExpiry > 0L) expiresAtMs = selectedExpiry
            purpose = selectedPurpose
            if (selectedLang.isNotEmpty()) visitorLang = selectedLang
            val config = app.core.config()
            updateBadges(config)
            buildReplyButtons(config)
            if (!inCall && !answerRequested) scheduleAutoClose()
        }
    }

    private fun demoteSupersededAnswer() {
        ui.removeCallbacks(answerReplaceTimeout)
        answerDelayPending = false
        answerRequested = false
        inCall = false
        sipCalling = false
        findViewById<Button>(R.id.answer_button).apply {
            text = texts.t("ring.answer", R.string.ring_answer)
            isEnabled = false
        }
        findViewById<TextView>(R.id.status_text).text =
            texts.t("reply.choose", R.string.reply_choose)
        findViewById<TextView>(R.id.audio_hint).visibility = View.GONE
        updateControlLabels()
        applySemanticUi(app.core.config(), app.core.status())
        scheduleAutoClose()
    }

    fun onCallAnswered(answeredDoor: String, answeredCallId: String, answeredStage: Int) {
        runOnUiThread {
            if (!matchesCall(answeredDoor, answeredCallId, answeredStage)) return@runOnUiThread
            if (isFinishing) return@runOnUiThread
            stageRevision = maxOf(stageRevision, answeredStage)
            if (!answerRequested && !inCall) finish()
        }
    }

    /** A different dialog owner won Core arbitration, so this SIP leg must end silently. */
    fun onManualSipClaimLost(lostCallId: String) {
        runOnUiThread {
            if (lostCallId.isEmpty() || lostCallId != callId || isFinishing)
                return@runOnUiThread
            ui.removeCallbacks(answerReplaceTimeout)
            answerDelayPending = false
            answerRequested = false
            inCall = false
            sipCalling = false
            finish()
        }
    }

    fun onCallEnded(endedDoor: String, endedCallId: String, endedStage: Int) {
        runOnUiThread {
            if (matchesCall(endedDoor, endedCallId, endedStage) && !isFinishing) finish()
        }
    }

    private fun matchesCall(eventDoor: String, eventCallId: String, eventStage: Int): Boolean =
        eventCallId.isNotEmpty() && callId.isNotEmpty() && eventCallId == callId &&
            eventStage >= stageRevision &&
            (eventDoor.isEmpty() || door.isEmpty() || eventDoor == door)

    private fun scheduleAutoClose() {
        ui.removeCallbacks(autoClose)
        val byExpiry = if (expiresAtMs > 0L) expiresAtMs - System.currentTimeMillis()
            else AUTO_CLOSE_MS
        ui.postDelayed(autoClose, byExpiry.coerceIn(0L, AUTO_CLOSE_MS))
    }

    fun onMemoryPressure() {
        runOnUiThread { videoPlayer?.onMemoryPressure() }
    }

    fun onSafeModeChanged(active: Boolean) {
        runOnUiThread {
            videoPlayer?.onSafeModeChanged(active)
            applySemanticUi(app.core.config(), app.core.status())
        }
    }

    /** Receives SIP state directly from App while MainActivity is behind this screen. */
    fun onSipState(state: String) {
        runOnUiThread {
            if (isFinishing) return@runOnUiThread
            when (state) {
                "in_call" -> if (answerRequested && !answerDelayPending) {
                    inCall = true
                    findViewById<Button>(R.id.answer_button).apply {
                        text = texts.t("incall.end", R.string.incall_end)
                        isEnabled = true
                    }
                    applySemanticUi(app.core.config(), app.core.status())
                    findViewById<TextView>(R.id.status_text).text =
                        texts.t("incall.title", R.string.incall_title)
                    findViewById<TextView>(R.id.audio_hint).visibility = View.GONE
                    updateControlLabels()
                    buildReplyButtons(app.core.config())
                }
                "idle" -> {
                    if (revisionLifecycle.consumeSupersededIdle()) {
                        sipCalling = false
                        findViewById<Button>(R.id.answer_button).apply {
                            text = texts.t("ring.answer", R.string.ring_answer)
                            isEnabled = peerHost != null
                        }
                        findViewById<TextView>(R.id.audio_hint).visibility = View.GONE
                        scheduleAutoClose()
                        return@runOnUiThread
                    }
                    if (answerDelayPending) {
                        answerDelayPending = false
                        ui.removeCallbacks(answerReplaceTimeout)
                        peerHost?.let(::startAnswerLeg) ?: run {
                            answerRequested = false
                            finish()
                        }
                        return@runOnUiThread
                    }
                    sipCalling = false
                    if (answerRequested || inCall) finish()
                    else findViewById<TextView>(R.id.audio_hint).visibility = View.GONE
                }
            }
        }
    }

    /** Closes an unanswered screen only when the reply belongs to this door. */
    fun onReply(replyDoor: String) {
        runOnUiThread {
            if (replyDoor.isNotEmpty() && door.isNotEmpty() && replyDoor != door)
                return@runOnUiThread
            if (!isFinishing && !inCall && !answerRequested) finish()
        }
    }

    // Purpose and visitor-language badges.

    private fun updateBadges(cfg: JSONObject?) {
        val purposeBadge = findViewById<TextView>(R.id.purpose_badge)
        val langBadge = findViewById<TextView>(R.id.lang_badge)

        val e = if (purpose.isEmpty()) null
                else app.core.dig(cfg, "visit_purposes.$purpose") as? JSONObject
        // The slot keeps its height so the layout never jumps when the purpose arrives later.
        if (purpose.isEmpty()) {
            purposeBadge.visibility = View.INVISIBLE
        } else {
            val label = labelOf(e, app.boot.uiLang, purpose)
            val icon = e?.optString("icon").orEmpty()
            purposeBadge.text = if (icon.isEmpty()) label else "$icon $label"
            purposeBadge.contentDescription =
                texts.t("ring.purpose_badge", R.string.ring_purpose_badge, label)
            purposeBadge.visibility = View.VISIBLE
        }

        if (visitorLang.isEmpty() || visitorLang == "ja") {
            langBadge.visibility = View.GONE
        } else {
            langBadge.text = "🌐 " + visitorLang.uppercase()
            langBadge.contentDescription = texts.t("ring.lang_badge", R.string.ring_lang_badge,
                                                   Texts.langDisplayName(visitorLang))
            langBadge.visibility = View.VISIBLE
        }
    }

    /** Resolve a label by requested language, Japanese, then fallback. */
    private fun labelOf(e: JSONObject?, lang: String, fallback: String): String {
        val l = e?.optJSONObject("label") ?: return fallback
        val s = l.optString(lang)
        if (s.isNotEmpty()) return s
        val ja = l.optString("ja")
        return if (ja.isNotEmpty()) ja else fallback
    }

    // Confirmed door peer.

    /** Find a live, confirmed door-station peer assigned to this door. */
    private fun findDoorPeer(st: JSONObject?): JSONObject? {
        val peers = st?.optJSONArray("peers") ?: return null
        for (i in 0 until peers.length()) {
            val p = peers.optJSONObject(i) ?: continue
            if (p.optBoolean("self")) continue
            if (p.optString("role") != "door_station") continue
            if (door.isNotEmpty() && p.optString("door") != door) continue
            if (p.optString("status") == "dead") continue
            return p
        }
        return null
    }

    // Live video.

    private fun startVideo(peer: JSONObject?) {
        val mjpegUrl = peer?.optString("stream").orEmpty()
        val h264Url = peer?.optString("stream_mp4").orEmpty()
        val texture = findViewById<TextureView>(R.id.live_texture)
        val live = findViewById<ImageView>(R.id.live_view)
        val noVideo = findViewById<TextView>(R.id.no_video_text)
        videoPlayer?.stop()
        videoPlayer = AdaptiveVideoPlayer(app, ui, texture, live, noVideo).also {
            it.start(h264Url, mjpegUrl)
        }
        // fitCenter letterboxes inside the video box, so a portrait door camera stays portrait
        // and is never cropped or stretched to the panel's own shape.
        live.scaleType = ImageView.ScaleType.FIT_CENTER
    }

    // Direct monitor audio.

    private fun startAudio() {
        if (!monitorOn) return
        val host = peerHost ?: return
        app.core.sipCall("sip:$host:$directPort", "monitor")
        sipCalling = true
        findViewById<TextView>(R.id.audio_hint).visibility = View.VISIBLE
    }

    // Bidirectional answer takeover.

    /** Replace the monitor leg with one answer leg; pressing again ends an established call. */
    private fun onAnswerClick(btn: Button) {
        val host = peerHost ?: return
        if (inCall) {
            app.core.sipHangup()
            sipCalling = false
            finish()
            return
        }
        if (answerRequested) return
        answerRequested = true
        revisionLifecycle.beginAnswer()
        ui.removeCallbacks(autoClose)
        btn.isEnabled = false
        findViewById<TextView>(R.id.status_text).text =
            texts.t("incall.title", R.string.incall_title)
        findViewById<TextView>(R.id.audio_hint).visibility = View.GONE
        if (sipCalling) {
            // Bind only after the monitor leg's actual idle callback, never on a fixed delay.
            answerDelayPending = true
            app.core.sipHangup()
            sipCalling = false
            ui.postDelayed(answerReplaceTimeout, ANSWER_REPLACE_TIMEOUT_MS)
        } else {
            startAnswerLeg(host)
        }
    }

    private fun startAnswerLeg(host: String) {
        if (callId.isNotEmpty() &&
            !app.bindManualSipAnswer(door, callId, stageRevision)) {
            answerRequested = false
            answerDelayPending = false
            sipCalling = false
            finish()
            return
        }
        app.core.sipCall("sip:$host:$directPort", "answer")
        sipCalling = true
    }

    /** Extract the host from the peer's first mesh address for direct SIP. */
    private fun resolvePeerHost(peer: JSONObject?): String? {
        val addrs = peer?.optJSONArray("addrs") ?: return null
        if (addrs.length() == 0) return null
        val a = addrs.optString(0)
        val i = a.lastIndexOf(':')
        val host = if (i > 0) a.substring(0, i) else a
        return host.ifEmpty { null }
    }

    // Quick replies.

    /**
     * Quick replies live in their own expandable strip below the single control row, so the row
     * itself stays one line of five actions on every screen size.
     */
    private fun buildReplyButtons(cfg: JSONObject?) {
        val list = findViewById<LinearLayout>(R.id.reply_list)
        list.removeAllViews()
        val replyButton = findViewById<Button>(R.id.reply_button)
        val replies = (app.core.dig(cfg, "quick_replies") as? JSONObject)
        val available = replies != null && replies.length() > 0 && !inCall && !answerRequested
        replyButton.visibility = if (available) View.VISIBLE else View.GONE
        if (!available) {
            list.visibility = View.GONE
            return
        }
        // Replies use the visitor language with a Japanese fallback.
        val lang = if (visitorLang.isEmpty()) "ja" else visitorLang
        val ids = replies!!.keys().asSequence().toMutableList()
        ids.sortWith(compareBy({ replies.optJSONObject(it)?.optInt("order", 999) ?: 999 }, { it }))
        for (id in ids) {
            val q = replies.optJSONObject(id) ?: continue
            val label = labelOf(q, lang, id)
            val b = Button(this)
            b.text = label
            b.textSize = 17f
            b.maxLines = 2
            b.isAllCaps = false
            @Suppress("DEPRECATION")
            b.setTextColor(resources.getColor(R.color.fg))
            @Suppress("DEPRECATION")
            b.background = resources.getDrawable(R.drawable.bg_tv_button)
            b.isFocusable = true
            b.minHeight = dp(52)
            val lp = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
            lp.topMargin = dp(4)
            b.layoutParams = lp
            b.setOnClickListener { sendReply(id, label) }
            list.addView(b)
        }
        if (list.visibility == View.VISIBLE && list.childCount > 0)
            list.getChildAt(0).requestFocus()
    }

    private fun applySemanticUi(cfg: JSONObject?, status: JSONObject?) {
        val nodeId = status?.optJSONObject("node")?.optString("id").orEmpty()
        val styleConfig = if (app.safeMode) null else cfg
        SemanticUi.apply(findViewById(R.id.door_label), "ring.title", styleConfig, nodeId)
        SemanticUi.apply(findViewById(R.id.status_text), "ring.title", styleConfig, nodeId)
        SemanticUi.apply(
            findViewById(R.id.answer_button),
            if (inCall) "call.end" else "ring.action",
            styleConfig,
            nodeId,
        )
        val close = findViewById<Button>(R.id.close_button)
        SemanticUi.apply(close, "monitor.close", styleConfig, nodeId)
        val list = findViewById<LinearLayout>(R.id.reply_list)
        for (index in 0 until list.childCount)
            SemanticUi.apply(list.getChildAt(index), "reply.button", styleConfig, nodeId)
    }

    private fun sendReply(replyId: String, label: String) {
        if (inCall || answerRequested) return
        val accepted = app.core.quickReplyV2(replyId, door, callId, stageRevision)
        val sent = findViewById<TextView>(R.id.sent_text)
        sent.text = if (accepted)
            texts.t("reply.sent", R.string.reply_sent, label)
        else
            texts.t("reply.failed", R.string.reply_failed)
        sent.visibility = View.VISIBLE
        if (accepted) {
            ui.removeCallbacks(autoClose)
            if (!inCall) ui.postDelayed(autoClose, 3000)
        }
    }


    // ---------- batch 2: one control row, notice chip, debug line, admin QR ----------

    private fun applyAppearance() {
        findViewById<View>(R.id.incoming_root).setBackgroundColor(ShellUi.opaque(palette.ground))
        findViewById<TextView>(R.id.door_label).setTextColor(ShellUi.opaque(palette.ink))
        findViewById<TextView>(R.id.status_text).setTextColor(ShellUi.opaque(palette.accent))
        findViewById<TextView>(R.id.audio_hint).setTextColor(ShellUi.opaque(palette.muted))
        findViewById<TextView>(R.id.no_video_text).setTextColor(ShellUi.opaque(palette.muted))
        val debug = findViewById<TextView>(R.id.debug_line)
        debug.setTextColor(ShellUi.opaque(palette.muted))
        debug.background = ShellUi.rounded(this, palette.surfaceAlt, 8)
        sosSlider.applyPalette(palette)
    }

    /**
     * モニター ON/OFF · 応答/通話終了 · マイク · 開錠 · クイック返信 — one row, each control showing
     * its own state rather than an explanatory label next to it.
     */
    private fun buildControlRow(cfg: JSONObject?) {
        val monitor = findViewById<Button>(R.id.monitor_button)
        monitor.setOnClickListener { toggleMonitor() }
        val mic = findViewById<Button>(R.id.mic_button)
        mic.setOnClickListener { toggleMic() }
        val reply = findViewById<Button>(R.id.reply_button)
        reply.setOnClickListener {
            val list = findViewById<LinearLayout>(R.id.reply_list)
            list.visibility = if (list.visibility == View.VISIBLE) View.GONE else View.VISIBLE
            if (list.visibility == View.VISIBLE && list.childCount > 0)
                list.getChildAt(0).requestFocus()
        }
        reply.text = texts.t("ring.quick_reply", R.string.ring_quick_reply)
        val unlock = findViewById<Button>(R.id.unlock_button)
        unlock.text = texts.t("ring.unlock", R.string.ring_unlock)
        // Core decides whether the control appears at all, so it is hidden before it is ever
        // pressed when an administrator turned it off or nothing is configured.
        unlock.visibility = if (DoorUnlocks.read(cachedStatus, door).showButton) View.VISIBLE
            else View.GONE
        unlock.setOnClickListener { onUnlockClick() }
        updateControlLabels()
    }

    private fun updateControlLabels() {
        findViewById<Button>(R.id.monitor_button).apply {
            text = if (monitorOn) texts.t("ring.monitor_on", R.string.ring_monitor_on)
            else texts.t("ring.monitor_off", R.string.ring_monitor_off)
            isSelected = monitorOn
        }
        findViewById<Button>(R.id.mic_button).apply {
            text = if (micMuted) texts.t("ring.mic_off", R.string.ring_mic_off)
            else texts.t("ring.mic_on", R.string.ring_mic_on)
            isSelected = !micMuted
            isEnabled = inCall
        }
        findViewById<TextView>(R.id.audio_hint).visibility =
            if (sipCalling && monitorOn && !inCall) View.VISIBLE else View.GONE
    }

    /** Stops or restarts the door audio leg without touching the call lifecycle. */
    private fun toggleMonitor() {
        monitorOn = !monitorOn
        if (inCall || answerRequested) {
            // While talking, the toggle only mutes local playback of the far end.
            setPlaybackMuted(!monitorOn)
        } else if (monitorOn) {
            startAudio()
        } else if (sipCalling) {
            app.core.sipHangup()
            sipCalling = false
        }
        updateControlLabels()
    }

    private fun toggleMic() {
        if (!inCall) return
        micMuted = !micMuted
        try { audioManager.isMicrophoneMute = micMuted } catch (_: Exception) { }
        updateControlLabels()
    }

    private fun setPlaybackMuted(muted: Boolean) {
        try {
            @Suppress("DEPRECATION")
            audioManager.setStreamMute(AudioManager.STREAM_VOICE_CALL, muted)
        } catch (_: Exception) { }
    }

    /**
     * 開錠 stays on this screen and triggers core's configured feature-code action. When an
     * administrator shows the button but nothing is configured, core answers -3 and that is said
     * out loud rather than reported as a silent success.
     */
    private fun onUnlockClick() {
        Thread({
            val result = app.core.openDoor(door)
            ui.post {
                if (isFinishing) return@post
                toast(
                    when {
                        DoorUnlocks.queued(result) ->
                            texts.t("ring.unlock_sent", R.string.ring_unlock_sent)
                        DoorUnlocks.unconfigured(result) -> texts.t(
                            "ring.unlock_unconfigured", R.string.ring_unlock_unconfigured,
                        )
                        else -> texts.t("admin.save_failed", R.string.admin_save_failed)
                    },
                )
            }
        }, "doorbell-open-door").apply { isDaemon = true }.start()
    }

    /** A compact chip with a dot while an announcement is showing; tap opens the popover. */
    private fun buildNoticeChip() {
        val chip = findViewById<TextView>(R.id.notice_chip)
        val notice = NoticeModel.resolve(
            cachedStatus, cachedConfig, door, clusterClock.now().wallMs,
        )
        val active = notice != null
        chip.text = (if (active) "● " else "") +
            texts.t("notice.title", R.string.notice_title)
        chip.background = ShellUi.rounded(
            this, if (active) palette.noticeBg else palette.surfaceAlt, 999,
            if (active) palette.noticeLine else palette.line,
        )
        chip.setTextColor(ShellUi.opaque(if (active) palette.noticeInk else palette.muted))
        chip.setOnClickListener { showNoticePopover(notice) }
    }

    private fun showNoticePopover(notice: Notice?) {
        val builder = android.app.AlertDialog.Builder(this)
            .setTitle(texts.t("notice.title", R.string.notice_title))
            .setMessage(notice?.text ?: texts.t("notice.none", R.string.notice_none))
            .setPositiveButton(
                if (notice == null) texts.t("notice.door_button", R.string.notice_door_button)
                else texts.t("notice.edit", R.string.notice_edit),
            ) { _, _ -> openNoticeDialog() }
            .setNegativeButton(texts.t("admin.menu_close", R.string.admin_menu_close), null)
        if (notice != null) builder.setNeutralButton(
            texts.t("notice.clear", R.string.notice_clear),
        ) { _, _ ->
            Thread({
                app.core.clearDoorNotice(door)
                ui.post { if (!isFinishing) refreshNotice() }
            }, "doorbell-notice-clear").apply { isDaemon = true }.start()
        }
        builder.show()
    }

    private fun openNoticeDialog() {
        NoticeDialog.show(this, app, texts, palette, door, doorIds(), { doorLabel(it) }) {
            refreshNotice()
        }
    }

    private fun refreshNotice() {
        cachedConfig = app.core.config()
        cachedStatus = app.core.status()
        texts.setConfig(cachedConfig)
        buildNoticeChip()
    }

    /** The door station's admin page stays reachable from a corner of this screen. */
    private fun buildAdminQr(status: JSONObject?) {
        val slot = findViewById<LinearLayout>(R.id.admin_qr_slot)
        slot.removeAllViews()
        slot.addView(
            AdminLinks.view(
                this, palette, app.core, AdminLinks.resolve(status, app.boot.httpPort),
                texts.t("web_admin.scan_hint", R.string.web_admin_scan_hint), 44,
            ),
        )
    }

    /** codec/strategy · latency · jitter · fps · dropped, tap to hide, remembered per device. */
    private fun updateDebugLine() {
        val line = findViewById<TextView>(R.id.debug_line)
        if (!debugVisible) {
            line.text = "·"
            line.contentDescription = texts.t("info.title", R.string.info_title)
            line.setOnClickListener { setDebugVisible(true) }
            return
        }
        val stats = videoPlayer?.stats()
        line.text = texts.t(
            "ring.debug_stats", R.string.ring_debug_stats,
            stats?.codec.orEmpty().ifEmpty { "-" },
            (stats?.latencyMs ?: 0).toString(),
            (stats?.jitterMs ?: 0).toString(),
            (stats?.fps ?: 0).toString(),
            (stats?.dropped ?: 0).toString(),
        )
        line.setOnClickListener { setDebugVisible(false) }
    }

    private fun setDebugVisible(value: Boolean) {
        debugVisible = value
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putBoolean(PREF_DEBUG_VISIBLE, value).apply()
        updateDebugLine()
    }

    private fun doorIds(): List<String> {
        val doors = app.core.dig(cachedConfig, "doors") as? JSONObject ?: return emptyList()
        return doors.keys().asSequence().sorted().toList()
    }

    private fun doorLabel(value: String = door): String {
        if (value.isEmpty()) return ""
        val label = app.core.dig(cachedConfig, "doors.$value.label.${texts.lang}")
            ?: app.core.dig(cachedConfig, "doors.$value.label.ja")
        return label?.toString() ?: value
    }

    private fun toast(message: String) {
        android.widget.Toast.makeText(this, message, android.widget.Toast.LENGTH_SHORT).show()
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val PREFS = "doorbell-incoming"
        private const val PREF_DEBUG_VISIBLE = "debug_line_visible"
        private const val DEBUG_INTERVAL_MS = 1_000L
        private const val EXTRA_DOOR = "door"
        private const val EXTRA_PURPOSE = "purpose"
        private const val EXTRA_LANG = "visitor_lang"
        private const val EXTRA_CALL_ID = "call_id"
        private const val EXTRA_STAGE_REVISION = "stage_revision"
        private const val EXTRA_EXPIRES_AT_MS = "expires_at_ms"
        private const val AUTO_CLOSE_MS = 90_000L
        private const val CANCELLED_CLOSE_MS = 15_000L
        private const val ANSWER_REPLACE_TIMEOUT_MS = 2_000L
        private const val DIRECT_PORT = 47190

        /** Launch from an application-level Core callback using a new task. */
        fun launch(
            ctx: Context,
            door: String,
            purpose: String = "",
            visitorLang: String = "",
            callId: String = "",
            stageRevision: Int = 0,
            expiresAtMs: Long = 0L,
        ) {
            try {
                ctx.startActivity(
                    Intent(ctx, IncomingActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        .putExtra(EXTRA_DOOR, door)
                        .putExtra(EXTRA_PURPOSE, purpose)
                        .putExtra(EXTRA_LANG, visitorLang)
                        .putExtra(EXTRA_CALL_ID, callId)
                        .putExtra(EXTRA_STAGE_REVISION, stageRevision)
                        .putExtra(EXTRA_EXPIRES_AT_MS, expiresAtMs))
            } catch (_: Exception) {
                // Background launch may be denied when overlay authorization is unavailable.
            }
        }
    }
}
