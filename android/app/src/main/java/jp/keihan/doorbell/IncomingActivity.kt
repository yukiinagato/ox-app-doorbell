// 来客モニタ画面 (TV/室内機)。chime UI イベントで App から起動され、前台アプリの上に被さる。
//   - 門口ライブ映像: statusJson peers[].stream (MJPEG) を自前デコード (MjpegStreamer)
//   - 門口音声: core の SIP で門口機の待受 (udp 47190) へ Asterisk 非経由の直接監聴呼
//     (X-Doorbell-Mode: monitor) — 門口機側はマイクのみ一方向で流す。閉じる時に hangup。
//   - クイック返信: config quick_replies を order 順に縦並び。D-pad フォーカス/タッチ両対応。
// TV リモコン: BACK で閉じる。返信送信後は「送信しました」→ 3 秒でクローズ。
package jp.keihan.doorbell

import android.app.Activity
import android.content.Context
import android.content.Intent
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
    private var door = ""
    private var streamer: MjpegStreamer? = null
    private var sipCalling = false
    private val autoClose = Runnable { finish() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        door = intent?.getStringExtra(EXTRA_DOOR) ?: ""
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_incoming)

        val cfg = app.core.config()
        val st = app.core.status()

        // 門口名 (doors.<door>.label.<lang> → ja → door id)
        val label = app.core.dig(cfg, "doors.$door.label.${app.boot.uiLang}")
            ?: app.core.dig(cfg, "doors.$door.label.ja") ?: door
        findViewById<TextView>(R.id.door_label).text = label.toString()

        buildReplyButtons(cfg)
        findViewById<Button>(R.id.close_button).setOnClickListener { finish() }

        // 門口機 peer の解決 (映像 URL + 直接監聴呼の宛先 host)
        val peer = findDoorPeer(st)
        startVideo(peer)
        startAudio(cfg, peer)

        // 応対されないまま放置された時の安全弁 (映像/監聴を持続させない)
        ui.postDelayed(autoClose, AUTO_CLOSE_MS)
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        // 同じ画面が出ている間の再チャイム → タイマだけ張り直す
        ui.removeCallbacks(autoClose)
        ui.postDelayed(autoClose, AUTO_CLOSE_MS)
    }

    override fun onDestroy() {
        ui.removeCallbacksAndMessages(null)
        streamer?.stop()
        if (sipCalling) app.core.sipHangup()
        super.onDestroy()
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

    private fun startAudio(cfg: JSONObject?, peer: JSONObject?) {
        val host = peerHost(peer) ?: return
        // 直接呼の待受ポート (sipctl の SipSettings.direct_port 既定と一致)
        val port = (app.core.dig(cfg, "sip.direct_port") as? Number)?.toInt() ?: DIRECT_PORT
        app.core.sipCall("sip:$host:$port", "monitor")
        sipCalling = true
        findViewById<TextView>(R.id.audio_hint).visibility = View.VISIBLE
    }

    /** peer の addrs[0] "host:port" → host (Asterisk 非経由 — mesh の実アドレスを使う) */
    private fun peerHost(peer: JSONObject?): String? {
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
        val replies = (app.core.dig(cfg, "quick_replies") as? JSONObject) ?: return
        // order 昇順
        val ids = replies.keys().asSequence().toMutableList()
        ids.sortBy { (replies.optJSONObject(it)?.optInt("order", 999)) ?: 999 }
        var first: Button? = null
        for ((idx, id) in ids.withIndex()) {
            val q = replies.optJSONObject(id) ?: continue
            val label = q.optJSONObject("label")?.let {
                it.optString(app.boot.uiLang).ifEmpty { it.optString("ja") }
            } ?: id
            val b = Button(this)
            b.text = label
            b.textSize = 22f
            @Suppress("DEPRECATION")  // minSdk 21 (Context.getColor は API 23+)
            b.setTextColor(resources.getColor(R.color.fg))
            b.background = getDrawable(R.drawable.bg_tv_button)
            b.isFocusable = true
            b.isAllCaps = false
            val lp = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(72))
            if (idx > 0) lp.topMargin = dp(16)
            b.setOnClickListener { sendReply(id) }
            list.addView(b, list.childCount - 1)  // close_button の手前へ
            if (first == null) first = b
        }
        // 初期フォーカス: 先頭の返信 (無ければ閉じる) — D-pad 即操作可能に
        (first ?: close).requestFocus()
    }

    private fun sendReply(replyId: String) {
        app.core.quickReply(replyId, door)
        findViewById<TextView>(R.id.sent_text).visibility = View.VISIBLE
        ui.removeCallbacks(autoClose)
        ui.postDelayed(autoClose, 3000)
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val EXTRA_DOOR = "door"
        private const val AUTO_CLOSE_MS = 90_000L
        private const val DIRECT_PORT = 47190  // docs/network-ports.md / sipctl.h と一致

        /** chime イベントから起動 (App — core スレッドから呼ばれるため NEW_TASK)。 */
        fun launch(ctx: Context, door: String) {
            try {
                ctx.startActivity(
                    Intent(ctx, IncomingActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        .putExtra(EXTRA_DOOR, door))
            } catch (_: Exception) {
                // バックグラウンド起動制限 (SYSTEM_ALERT_WINDOW 未付与) — provision.md 参照
            }
        }
    }
}
