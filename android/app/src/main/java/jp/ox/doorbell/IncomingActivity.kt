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
        texts = Texts(this)
        texts.setConfig(cfg)
        texts.setLang(app.boot.uiLang)

        // Resolve the resident-facing door label.
        val label = app.core.dig(cfg, "doors.$door.label.${app.boot.uiLang}")
            ?: app.core.dig(cfg, "doors.$door.label.ja") ?: door
        findViewById<TextView>(R.id.door_label).text = label.toString()
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

        val sos = findViewById<Button>(R.id.sos_button)
        sos.contentDescription = getString(
            R.string.emergency_hold_hint,
            SosHoldTrigger.HOLD_SECONDS.toString(),
        )
        SosHoldTrigger.bind(sos, ui, { app.coreOk }) { app.commitEmergency(true) }

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
        val entry = app.core.dig(cfg, "doors.$door.label.${app.boot.uiLang}")
            ?: app.core.dig(cfg, "doors.$door.label.ja") ?: door
        findViewById<TextView>(R.id.door_label).text = entry.toString()
        findViewById<TextView>(R.id.status_text).text =
            texts.t("reply.choose", R.string.reply_choose)
        findViewById<TextView>(R.id.audio_hint).visibility = View.GONE
        updateBadges(cfg)
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
        if (purpose.isEmpty()) {
            purposeBadge.visibility = View.GONE
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
    }

    // Direct monitor audio.

    private fun startAudio() {
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

    private fun buildReplyButtons(cfg: JSONObject?) {
        val list = findViewById<LinearLayout>(R.id.reply_list)
        val close = findViewById<Button>(R.id.close_button)
        val answer = findViewById<Button>(R.id.answer_button)
        // Rebuild dynamic replies while preserving the answer and close controls.
        var i = list.childCount - 1
        while (i >= 0) {
            val v = list.getChildAt(i)
            if (v !== close && v !== answer) list.removeViewAt(i)
            i--
        }
        if (inCall || answerRequested) return
        val replies = (app.core.dig(cfg, "quick_replies") as? JSONObject) ?: return
        // Replies use the visitor language with a Japanese fallback.
        val lang = if (visitorLang.isEmpty()) "ja" else visitorLang
        val ids = replies.keys().asSequence().toMutableList()
        ids.sortWith(compareBy({ replies.optJSONObject(it)?.optInt("order", 999) ?: 999 }, { it }))
        var first: Button? = null
        val replyTextSize = if (ids.size >= 5) 16f else 19f
        for ((idx, id) in ids.withIndex()) {
            val q = replies.optJSONObject(id) ?: continue
            val b = Button(this)
            b.text = labelOf(q, lang, id)
            b.textSize = replyTextSize
            b.maxLines = 2
            @Suppress("DEPRECATION")
            b.setTextColor(resources.getColor(R.color.fg))
            @Suppress("DEPRECATION")
            b.background = resources.getDrawable(R.drawable.bg_tv_button)
            b.isFocusable = true
            b.isAllCaps = false
            val lp = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
            lp.topMargin = dp(4)
            lp.bottomMargin = dp(4)
            b.layoutParams = lp
            b.setOnClickListener { sendReply(id, b.text.toString()) }
            list.addView(b, list.childCount - 1)
            if (first == null) first = b
        }
        // Initial focus enables immediate D-pad use.
        (first ?: close).requestFocus()
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
        SemanticUi.apply(findViewById(R.id.sos_button), "sos.trigger", styleConfig, nodeId)
        val list = findViewById<LinearLayout>(R.id.reply_list)
        for (index in 0 until list.childCount) {
            val child = list.getChildAt(index)
            if (child.id != R.id.answer_button && child.id != R.id.close_button)
                SemanticUi.apply(child, "reply.button", styleConfig, nodeId)
        }
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

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
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
