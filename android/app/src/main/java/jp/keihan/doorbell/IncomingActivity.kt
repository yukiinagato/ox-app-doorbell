// 来客モニタ画面 (TV/室内機)。chime UI イベントで App から起動され、前台アプリの上に被さる。
//   - 門口ライブ映像: statusJson peers[].stream (MJPEG) を自前デコード (MjpegStreamer)
//   - 門口音声: core の SIP で門口機の待受 (udp 47190) へ Asterisk 非経由の直接監聴呼
//     (X-Doorbell-Mode: monitor) — 門口機側はマイクのみ一方向で流す。閉じる時に hangup。
//   - 応答: 監聴呼を切って X-Doorbell-Mode: answer の直呼 — 門口機は鳴っている電話腿を
//     取り消して双方向応答する (計画書 §12)。通話中は映像を表示し続け「終了」で切る。
//   - クイック返信: config quick_replies を order 順に縦並び。D-pad フォーカス/タッチ両対応。
//     ラベルは**訪客言語** (quick_replies.<id>.label.<visitor_lang> — 無ければ ja) で出す。
//   - 用件 / 訪客言語バッジ: press イベント payload 由来 (「📦 宅配便」「🌐 EN」)。住人が読む
//     ものなので用件名は室内側の言語 (boot.ui_lang) で表示する。
// TV リモコン: BACK で閉じる。返信送信後は「送信しました」→ 3 秒でクローズ。
// 锁屏対策: showWhenLocked/turnScreenOn (API27+ は manifest + setter、以前は window flags)。
package jp.keihan.doorbell

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
    private var purpose = ""             // press payload の用件 id (バッジ用)
    private var visitorLang = ""         // press payload の訪客言語 (返信ラベル/バッジ用)
    private var streamer: MjpegStreamer? = null
    private var sipCalling = false
    private var inCall = false           // 応答 (双方向) 確立後 = 「終了」ボタン
    private var peerHost: String? = null // 門口機の mesh 実アドレス host (直呼宛先)
    private var directPort = DIRECT_PORT
    private val autoClose = Runnable { finish() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        app.incomingActivity = this
        door = intent?.getStringExtra(EXTRA_DOOR) ?: ""
        purpose = intent?.getStringExtra(EXTRA_PURPOSE) ?: ""
        visitorLang = intent?.getStringExtra(EXTRA_LANG) ?: ""
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // 万一ロック中でも来鈴画面を表示する (DO 端末は App 側で keyguard 自体を無効化済み)
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
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
        texts.setLang(app.boot.uiLang)   // 室内側の言語 (住人が読む面)

        // 門口名 (doors.<door>.label.<lang> → ja → door id)
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

        buildReplyButtons(cfg)

        // 門口機 peer の解決 (映像 URL + 直接監聴呼/応答呼の宛先 host)
        val peer = findDoorPeer(st)
        peerHost = resolvePeerHost(peer)
        directPort = (app.core.dig(cfg, "sip.direct_port") as? Number)?.toInt() ?: DIRECT_PORT
        startVideo(peer)
        startAudio()

        // 応答 (双方向) — 宛先不明なら無効化
        val answer = findViewById<Button>(R.id.answer_button)
        answer.text = texts.t("ring.answer", R.string.ring_answer)
        answer.isEnabled = peerHost != null
        answer.setOnClickListener { onAnswerClick(answer) }

        // 応対されないまま放置された時の安全弁 (映像/監聴を持続させない)
        ui.postDelayed(autoClose, AUTO_CLOSE_MS)
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        // 同じ画面が出ている間の再チャイム → 用件/言語を更新しタイマを張り直す (通話中は張らない)
        val p = intent?.getStringExtra(EXTRA_PURPOSE)
        val l = intent?.getStringExtra(EXTRA_LANG)
        if (p != null || l != null) {
            purpose = p ?: ""
            visitorLang = l ?: ""
            val cfg = app.core.config()
            updateBadges(cfg)
            buildReplyButtons(cfg)
        }
        ui.removeCallbacks(autoClose)
        if (!inCall) ui.postDelayed(autoClose, AUTO_CLOSE_MS)
    }

    override fun onDestroy() {
        if (app.incomingActivity === this) app.incomingActivity = null
        ui.removeCallbacksAndMessages(null)
        streamer?.stop()
        if (sipCalling) app.core.sipHangup()
        super.onDestroy()
    }

    /** 室外機の取消後も映像画面は残し、短い猶予後にだけ閉じる。 */
    fun onCallCancelled(cancelledDoor: String) {
        if (cancelledDoor.isNotEmpty() && door.isNotEmpty() && cancelledDoor != door) return
        runOnUiThread {
            if (isFinishing || inCall) return@runOnUiThread
            findViewById<TextView>(R.id.status_text).text =
                texts.t("ring.cancelled", R.string.ring_cancelled)
            ui.removeCallbacks(autoClose)
            ui.postDelayed(autoClose, CANCELLED_CLOSE_MS)
        }
    }

    // ---------- 用件 / 訪客言語バッジ ----------

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

    /** ラベル多言語解決 (label.<lang> → label.ja → 既定)。 */
    private fun labelOf(e: JSONObject?, lang: String, fallback: String): String {
        val l = e?.optJSONObject("label") ?: return fallback
        val s = l.optString(lang)
        if (s.isNotEmpty()) return s
        val ja = l.optString("ja")
        return if (ja.isNotEmpty()) ja else fallback
    }

    // ---------- 門口機 peer ----------

    /** statusJson peers[] からこの door を担当する door_station (自分以外) を返す。 */
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

    // ---------- ライブ映像 ----------

    private fun startVideo(peer: JSONObject?) {
        val url = peer?.optString("stream").orEmpty()
        val live = findViewById<ImageView>(R.id.live_view)
        val noVideo = findViewById<TextView>(R.id.no_video_text)
        if (url.isEmpty()) return  // 「映像なし」表示のまま
        streamer = MjpegStreamer(url) { bmp ->
            ui.post {
                noVideo.visibility = View.GONE
                live.setImageBitmap(bmp)
            }
        }.also { it.start() }
    }

    // ---------- 門口音声 (直接監聴呼) ----------

    private fun startAudio() {
        val host = peerHost ?: return
        app.core.sipCall("sip:$host:$directPort", "monitor")
        sipCalling = true
        findViewById<TextView>(R.id.audio_hint).visibility = View.VISIBLE
    }

    // ---------- 応答 (双方向通話 — answer 接管) ----------

    /** 応答: 監聴呼を切ってから answer 直呼 (主呼は同時に 1 本)。通話中の再押下 = 終了。 */
    private fun onAnswerClick(btn: Button) {
        val host = peerHost ?: return
        if (inCall) {  // 「終了」
            app.core.sipHangup()
            sipCalling = false
            finish()
            return
        }
        inCall = true
        ui.removeCallbacks(autoClose)  // 通話中は自動クローズしない (映像は表示継続)
        btn.text = texts.t("incall.end", R.string.incall_end)
        findViewById<TextView>(R.id.status_text).text =
            texts.t("incall.title", R.string.incall_title)
        findViewById<TextView>(R.id.audio_hint).visibility = View.GONE
        if (sipCalling) {
            // 監聴呼が立っている → hangup してから少し待って answer (Idle 遷移待ち)
            app.core.sipHangup()
            ui.postDelayed({ app.core.sipCall("sip:$host:$directPort", "answer") }, 400)
        } else {
            app.core.sipCall("sip:$host:$directPort", "answer")
        }
        sipCalling = true
    }

    /** peer の addrs[0] "host:port" → host (Asterisk 非経由 — mesh の実アドレスを使う) */
    private fun resolvePeerHost(peer: JSONObject?): String? {
        val addrs = peer?.optJSONArray("addrs") ?: return null
        if (addrs.length() == 0) return null
        val a = addrs.optString(0)
        val i = a.lastIndexOf(':')
        val host = if (i > 0) a.substring(0, i) else a
        return host.ifEmpty { null }
    }

    // ---------- クイック返信 ----------

    private fun buildReplyButtons(cfg: JSONObject?) {
        val list = findViewById<LinearLayout>(R.id.reply_list)
        val close = findViewById<Button>(R.id.close_button)
        val answer = findViewById<Button>(R.id.answer_button)
        // 前回分を除去 (再チャイムで訪客言語が変わることがある — answer/close は残す)
        var i = list.childCount - 1
        while (i >= 0) {
            val v = list.getChildAt(i)
            if (v !== close && v !== answer) list.removeViewAt(i)
            i--
        }
        val replies = (app.core.dig(cfg, "quick_replies") as? JSONObject) ?: return
        // ラベルは訪客言語 (訳が無ければ ja へ回落)
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
            @Suppress("DEPRECATION")  // minSdk 21 (Context.getColor は API 23+)
            b.setTextColor(resources.getColor(R.color.fg))
            b.background = getDrawable(R.drawable.bg_tv_button)
            b.isFocusable = true
            b.isAllCaps = false
            val lp = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
            lp.topMargin = dp(4)
            lp.bottomMargin = dp(4)
            b.layoutParams = lp
            b.setOnClickListener { sendReply(id, b.text.toString()) }
            list.addView(b, list.childCount - 1)  // close_button の手前へ
            if (first == null) first = b
        }
        // 初期フォーカス: 先頭の返信 (無ければ閉じる) — D-pad 即操作可能に
        (first ?: close).requestFocus()
    }

    private fun sendReply(replyId: String, label: String) {
        app.core.quickReply(replyId, door)
        val sent = findViewById<TextView>(R.id.sent_text)
        sent.text = texts.t("reply.sent", R.string.reply_sent, label)
        sent.visibility = View.VISIBLE
        ui.removeCallbacks(autoClose)
        if (!inCall) ui.postDelayed(autoClose, 3000)  // 通話中は返信後も画面を保つ
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val EXTRA_DOOR = "door"
        private const val EXTRA_PURPOSE = "purpose"
        private const val EXTRA_LANG = "visitor_lang"
        private const val AUTO_CLOSE_MS = 90_000L
        private const val CANCELLED_CLOSE_MS = 15_000L
        private const val DIRECT_PORT = 47190  // docs/network-ports.md / sipctl.h と一致

        /** chime イベントから起動 (App — core スレッドから呼ばれるため NEW_TASK)。 */
        fun launch(ctx: Context, door: String, purpose: String = "", visitorLang: String = "") {
            try {
                ctx.startActivity(
                    Intent(ctx, IncomingActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        .putExtra(EXTRA_DOOR, door)
                        .putExtra(EXTRA_PURPOSE, purpose)
                        .putExtra(EXTRA_LANG, visitorLang))
            } catch (_: Exception) {
                // バックグラウンド起動制限 (SYSTEM_ALERT_WINDOW 未付与) — provision.md 参照
            }
        }
    }
}
