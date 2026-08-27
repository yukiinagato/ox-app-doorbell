// 門口機メイン画面: 待機 / 呼び出し中 / 返信バナー / オフライン の状態機 (WPF 版 MainWindow と同じ)。
// core からの UI イベント (state/chime/reply/visitor_lang/asset_ready/…) で遷移する。
// 個性化 (批次②):
//   - テーマ: display.theme / devices.<自 node_id>.local.theme の bg_color + bg_image
//     (自機 httpd の /asset/<hash>?k=<panel token> から取得し centerCrop で最背面へ)。
//     夜間 red_tint は night_tint が最前面に重なる (背景が明るくても夜間は暗く)。
//   - 訪客言語バー (ui.languages): タップで db_core_set_visitor_lang + 画面文言を即時切替。
//   - 用件ボタン (visit_purposes): 1 タップで用件付き按鈴 (db_core_press_purpose)。
//   - 文言は Texts 経由 = config i18n_overrides.<lang>.<key> → 組込 strings.xml の順。
// フルスクリーン immersive sticky + KEEP_SCREEN_ON。kiosk は Device Owner 時 startLockTask。
package jp.keihan.doorbell

import android.Manifest
import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.ToneGenerator
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
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

class MainActivity : Activity(), DoorbellCore.Listener {

    private val ui = Handler(Looper.getMainLooper())
    private lateinit var app: App
    private lateinit var texts: Texts

    private lateinit var rootView: View
    private lateinit var themeBg: ImageView
    private lateinit var nightTint: View
    private lateinit var idleView: View
    private lateinit var clockText: TextView
    private lateinit var dateText: TextView
    private lateinit var callButton: Button
    private lateinit var touchHint: TextView
    private lateinit var nodeInfo: TextView
    private lateinit var purposeSection: View
    private lateinit var purposeHint: TextView
    private lateinit var purposeGrid: GridLayout
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
    private lateinit var preview: SurfaceView

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val camera by lazy { CameraFeeder(app.core) }
    private var surfaceReady = false

    private var secretTaps = 0
    private var secretFirstMs = 0L
    private var adminUnlocked = false

    // ---------- 個性化 (テーマ / 訪客言語 / 用件 / カスタム音声) ----------
    private var cfg: JSONObject? = null      // 直近の core 設定 (config_changed で差替)
    private var nodeId = ""                  // 自機 node_id (devices.<id>.local.theme 用)
    private var panelToken = ""              // config panel.tokens[0] (/asset の ?k=)
    private var visitorLang = "ja"           // 門口機の表示言語 (訪客言語)
    private var themeColor: String? = null   // 適用済み bg_color
    private var themeHash: String? = null    // 適用済み bg_image (sha256)
    private var audio: MediaPlayer? = null   // reply/chime の audio_path 再生
    private var callTitleOverride: String? = null  // 用件付き按鈴の「{用件} で呼び出しました」

    // ---------- タイマ (WPF DispatcherTimer 相当) ----------
    private val clockTick = object : Runnable {
        override fun run() { updateClock(); ui.postDelayed(this, 1000) }
    }
    private val callTimeout = Runnable {
        showIdle(texts.t("calling.no_answer", R.string.calling_no_answer))
    }
    private val replyTimeout = Runnable { replyBanner.visibility = View.GONE }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        texts = Texts(this)
        visitorLang = app.boot.uiLang
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)
        bindViews()

        refreshConfigCache()
        texts.setLang(visitorLang)
        applyStrings()

        callButton.setOnClickListener { onCallClick() }
        cancelButton.setOnClickListener {
            ui.removeCallbacks(callTimeout)
            showIdle()
        }
        // 隠し管理入口 (右上 200dp を 5 秒内 7 連打)
        findViewById<View>(R.id.secret_corner).setOnClickListener { onSecretCorner() }

        tts = TextToSpeech(this) { status -> ttsReady = status == TextToSpeech.SUCCESS }

        preview.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                surfaceReady = true
                maybeStartCamera()
            }
            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, hh: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                surfaceReady = false
                camera.stop()
            }
        })
        requestPermissionsIfNeeded()

        // core イベントは App が一次受け — 前面 Activity として転送先に登録する
        app.activityListener = this
        if (!app.coreOk) showOffline()
        refreshNodeInfo()
    }

    override fun onResume() {
        super.onResume()
        enterImmersive()
        ui.post(clockTick)
        enterKioskIfConfigured()
        maybeStartCamera()
    }

    override fun onPause() {
        ui.removeCallbacks(clockTick)
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersive()
    }

    override fun onDestroy() {
        if (app.activityListener === this) app.activityListener = null
        camera.stop()
        tts?.shutdown()
        try { audio?.release() } catch (_: Exception) { }
        audio = null
        super.onDestroy()
    }

    @Deprecated("kiosk 中は戻れない")
    override fun onBackPressed() {
        if (!app.boot.kiosk || adminUnlocked) super.onBackPressed()
    }

    private fun bindViews() {
        rootView = findViewById(R.id.root_view)
        themeBg = findViewById(R.id.theme_bg)
        nightTint = findViewById(R.id.night_tint)
        idleView = findViewById(R.id.idle_view)
        clockText = findViewById(R.id.clock_text)
        dateText = findViewById(R.id.date_text)
        callButton = findViewById(R.id.call_button)
        touchHint = findViewById(R.id.touch_hint)
        nodeInfo = findViewById(R.id.node_info)
        purposeSection = findViewById(R.id.purpose_section)
        purposeHint = findViewById(R.id.purpose_hint)
        purposeGrid = findViewById(R.id.purpose_grid)
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
        preview = findViewById(R.id.camera_preview)
    }

    // ---------- フルスクリーン / kiosk ----------

    @Suppress("DEPRECATION")  // minSdk 21 — WindowInsetsController は API 30+
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
        if (!app.boot.kiosk || adminUnlocked) return
        val dpm = getSystemService(DEVICE_POLICY_SERVICE) as DevicePolicyManager
        if (dpm.isDeviceOwnerApp(packageName)) {
            // Device Owner (provision.md): 完全ピン留め — 通知シェードもホームも出ない
            dpm.setLockTaskPackages(ComponentName(this, AdminReceiver::class.java),
                                    arrayOf(packageName))
        }
        try {
            if (dpm.isLockTaskPermitted(packageName)) startLockTask()
        } catch (_: Exception) { /* DO でない端末は screen pinning ダイアログ側に任せる */ }
    }

    // ---------- 時計 ----------

    private fun updateClock() {
        val now = Calendar.getInstance()
        clockText.text = String.format(Locale.US, "%02d:%02d",
            now.get(Calendar.HOUR_OF_DAY), now.get(Calendar.MINUTE))
        val yobi = arrayOf("日", "月", "火", "水", "木", "金", "土")
        dateText.text = String.format(Locale.US, "%d年%d月%d日 (%s)",
            now.get(Calendar.YEAR), now.get(Calendar.MONTH) + 1, now.get(Calendar.DAY_OF_MONTH),
            yobi[now.get(Calendar.DAY_OF_WEEK) - 1])
    }

    private fun refreshNodeInfo() {
        refreshConfigCache()
        val st = app.core.status()
        val node = st?.optJSONObject("node")
        if (node != null) {
            nodeInfo.text = node.optString("name") + " · v" + node.optString("version")
            nodeId = node.optString("id")
        }
        // 訪客言語の現在値 (status_json visitor_lang.<door>) — 再起動後の追い付き
        if (st != null && app.boot.role == "door_station" && app.boot.door.isNotEmpty()) {
            val vl = app.core.dig(st, "visitor_lang.${app.boot.door}")
            setVisitorLang(vl?.toString() ?: "ja")
        }
        // 起動直後の {"t":"display"} は購読前に流れていることがある — status で追い付く
        st?.optJSONObject("display")?.let { applyNightTint(it.optBoolean("night"),
                                                          it.optBoolean("red_tint")) }
        applyTheme()
        buildPurposeButtons()
        buildLangBar()
        applyStrings()
    }

    // ---------- 文言 (i18n_overrides → strings.xml) ----------

    /** 全画面の文言を現在言語で貼り直す。訪客言語の切替でも呼ばれる。 */
    private fun applyStrings() {
        callButton.text =
            texts.t("idle.call_button", R.string.idle_call_button, doorLabel(app.boot.door)).trim()
        touchHint.text = texts.t("idle.touch_to_call", R.string.idle_touch_to_call)
        purposeHint.text = texts.t("idle.choose_purpose", R.string.idle_choose_purpose)
        callingText.text = texts.t("calling.title", R.string.calling_title)
        cancelButton.text = texts.t("calling.cancel", R.string.calling_cancel)
        replyCaption.text = texts.t("reply.banner", R.string.reply_banner)
        offlineTitle.text = texts.t("offline.title", R.string.offline_title)
        offlineBody.text = texts.t("offline.body", R.string.offline_body)
    }

    /** ドアの表示名 (doors.<door>.label.<lang> → ja → door id)。 */
    private fun doorLabel(door: String): String {
        if (door.isEmpty()) return ""
        val l = app.core.dig(cfg, "doors.$door.label.${texts.lang}")
            ?: app.core.dig(cfg, "doors.$door.label.ja")
        return l?.toString() ?: door
    }

    // ---------- 個性化 (テーマ / 用件 / 訪客言語) ----------

    private fun refreshConfigCache() {
        cfg = app.core.config()
        texts.setConfig(cfg)
        panelToken = firstPanelToken()
    }

    /** config panel.tokens[0] (資産取得 /asset/<hash>?k= に使う)。 */
    private fun firstPanelToken(): String {
        val arr = app.core.dig(cfg, "panel.tokens") as? JSONArray ?: return ""
        for (i in 0 until arr.length()) {
            val s = arr.optString(i)
            if (s.isNotEmpty()) return s
        }
        return ""
    }

    /** 端末別 (devices.<self>.local.theme.*) → 全体 (display.theme.*) の優先順で引く。 */
    private fun themeValue(leaf: String): String? {
        val v = (if (nodeId.isNotEmpty()) app.core.dig(cfg, "devices.$nodeId.local.theme.$leaf")
                 else null)
            ?: app.core.dig(cfg, "display.theme.$leaf")
        val s = v?.toString().orEmpty()
        return if (s.isEmpty() || s == "null") null else s   // JSON null は JSONObject.NULL
    }

    private fun applyTheme() {
        val color = themeValue("bg_color")
        if (color != themeColor) {
            themeColor = color
            try {
                @Suppress("DEPRECATION")  // minSdk 21 (Context.getColor は API 23+)
                rootView.setBackgroundColor(
                    if (color != null) Color.parseColor(color) else resources.getColor(R.color.bg))
            } catch (e: Exception) {
                Log.w(TAG, "テーマ背景色が不正 (無視): $color $e")
            }
        }
        val hash = themeValue("bg_image")
        if (hash.isNullOrEmpty()) {
            themeHash = null
            themeBg.setImageDrawable(null)
            themeBg.visibility = View.GONE
            return
        }
        if (hash == themeHash && themeBg.drawable != null) return  // 適用済み
        themeHash = hash
        loadThemeImage(hash)
    }

    /** 背景画像を自機 httpd から取得 (未キャッシュなら 404 — asset_ready で再試行)。 */
    private fun loadThemeImage(hash: String) {
        var url = "http://127.0.0.1:${app.boot.httpPort}/asset/$hash"
        if (panelToken.isNotEmpty()) url += "?k=$panelToken"
        Thread({
            var bmp: Bitmap? = null
            var conn: HttpURLConnection? = null
            try {
                conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 4000
                conn.readTimeout = 8000
                bmp = BitmapFactory.decodeStream(conn.inputStream)
            } catch (e: Exception) {
                // 未取得 (mesh 前取り待ち) — asset_ready を待って再試行する
                Log.w(TAG, "背景画像の取得失敗 (asset_ready 待ち): $e")
            } finally {
                try { conn?.disconnect() } catch (_: Exception) { }
            }
            val b = bmp ?: return@Thread
            ui.post {
                if (themeHash != hash) return@post   // 途中で設定が変わった
                themeBg.setImageBitmap(b)
                themeBg.visibility = View.VISIBLE
            }
        }, "theme-bg").apply { isDaemon = true }.start()
    }

    /** 夜間モードの red tint (背景画像が明るくても夜間は暗くする)。 */
    private fun applyNightTint(night: Boolean, redTint: Boolean) {
        nightTint.visibility = if (night && redTint) View.VISIBLE else View.GONE
    }

    /** 設定オブジェクト直下のキーを order 昇順 (同値は id 順) に並べる。 */
    private fun sortedByOrder(o: JSONObject): List<String> {
        val ids = o.keys().asSequence().toMutableList()
        ids.sortWith(compareBy({ o.optJSONObject(it)?.optInt("order", 999) ?: 999 }, { it }))
        return ids
    }

    /** ラベル多言語解決 (label.<lang> → label.ja → 既定)。 */
    private fun labelOf(e: JSONObject?, lang: String, fallback: String): String {
        val l = e?.optJSONObject("label") ?: return fallback
        val s = l.optString(lang)
        if (s.isNotEmpty()) return s
        val ja = l.optString("ja")
        return if (ja.isNotEmpty()) ja else fallback
    }

    /** 用件ボタン (config visit_purposes)。門口機の待機画面にだけ出す。 */
    private fun buildPurposeButtons() {
        purposeGrid.removeAllViews()
        val purposes = app.core.dig(cfg, "visit_purposes") as? JSONObject
        if (app.boot.role != "door_station" || purposes == null || purposes.length() == 0) {
            purposeSection.visibility = View.GONE
            return
        }
        for (id in sortedByOrder(purposes)) {
            val e = purposes.optJSONObject(id)
            val label = labelOf(e, texts.lang, id)
            val icon = e?.optString("icon").orEmpty()
            val b = Button(this)
            b.text = if (icon.isEmpty()) label else "$icon\n$label"
            b.textSize = 17f
            b.isAllCaps = false
            b.setSingleLine(false)
            b.maxLines = 3
            @Suppress("DEPRECATION")  // minSdk 21 (Context.getColor / getDrawable は API 23+)
            b.setTextColor(resources.getColor(R.color.fg))
            @Suppress("DEPRECATION")
            b.background = resources.getDrawable(R.drawable.bg_tv_button)
            b.isFocusable = true
            b.setOnClickListener { onPurposeClick(id, label) }
            val lp = GridLayout.LayoutParams()
            lp.width = dp(176)
            lp.height = dp(92)
            lp.setMargins(dp(6), dp(6), dp(6), dp(6))
            purposeGrid.addView(b, lp)
        }
        purposeSection.visibility = View.VISIBLE
    }

    private fun onPurposeClick(id: String, label: String) {
        app.core.pressPurpose(app.boot.door, id)
        showCalling(texts.t("purpose.sent", R.string.purpose_sent, label))
    }

    /** 訪客言語バー (config ui.languages)。門口機の待機画面下部。 */
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
            b.textSize = 18f
            b.isAllCaps = false
            b.isFocusable = true
            b.tag = l
            @Suppress("DEPRECATION")  // minSdk 21 (getDrawable(id) は API 21 でも使える旧 API)
            b.background = resources.getDrawable(R.drawable.bg_tv_button)
            b.setOnClickListener { onLangClick(l) }
            val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(52))
            lp.leftMargin = dp(6)
            lp.rightMargin = dp(6)
            langBar.addView(b, lp)
        }
        langBar.visibility = View.VISIBLE
        updateLangBarSelection()
    }

    private fun updateLangBarSelection() {
        for (i in 0 until langBar.childCount) {
            val b = langBar.getChildAt(i) as? Button ?: continue
            @Suppress("DEPRECATION")  // minSdk 21 (Context.getColor は API 23+)
            b.setTextColor(resources.getColor(
                if (b.tag == visitorLang) R.color.accent else R.color.dim))
        }
    }

    private fun onLangClick(lang: String) {
        app.core.setVisitorLang(app.boot.door, lang)  // 複製で visitor_lang が返ってくる
        setVisitorLang(lang)                          // 体感優先で先に切り替える (冪等)
    }

    /** 表示言語を切り替えて訪客向け文言を貼り直す (自操作・他端末・自動復帰の共通経路)。 */
    private fun setVisitorLang(lang: String) {
        val l = if (lang.isEmpty()) "ja" else lang
        if (visitorLang == l) return
        visitorLang = l
        texts.setLang(l)
        applyStrings()
        buildPurposeButtons()
        updateLangBarSelection()
    }

    // ---------- 状態遷移 ----------

    private fun showIdle(hint: String? = null) {
        callTitleOverride = null
        ui.removeCallbacks(callTimeout)
        pulse.clearAnimation()
        callingView.visibility = View.GONE
        offlineView.visibility = View.GONE
        idleView.visibility = View.VISIBLE
        if (hint != null) touchHint.text = hint
    }

    /**
     * 呼び出し中画面。title 指定時は「{用件} で呼び出しました」等に差し替える
     * (core からの state=calling で上書きされないよう callTitleOverride に覚える)。
     */
    private fun showCalling(title: String? = null) {
        if (title != null) callTitleOverride = title
        callingText.text = callTitleOverride ?: texts.t("calling.title", R.string.calling_title)
        idleView.visibility = View.GONE
        callingView.visibility = View.VISIBLE
        ui.removeCallbacks(callTimeout)
        ui.postDelayed(callTimeout, 30_000)
        pulse.startAnimation(AlphaAnimation(0.25f, 1.0f).apply {
            duration = 900
            repeatMode = Animation.REVERSE
            repeatCount = Animation.INFINITE
        })
    }

    private fun showOffline() {
        offlineView.visibility = View.VISIBLE
    }

    // ---------- core イベント (core 内部スレッド → UI スレッドへ marshal) ----------

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
            "state" -> when (ev.optString("state")) {
                "calling" -> showCalling()
                "idle" -> showIdle()
                "in_call" -> callingText.text = texts.t("incall.title", R.string.incall_title)
            }
            // カスタム音 (assets の audio_path) があればそれを、無ければ内蔵トーン
            "chime" -> playAudio(ev.optString("audio_path")) { playChimeTone() }
            "reply" -> {
                // カスタム音声があれば再生 (無い時は core が TTS 済み — 二重発話しない)
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
                // 訪客が見たら呼び出し継続は不要 → 待機へ
                showIdle()
            }
            // 訪客言語の切替 (自操作の複製 / 他端末からの変更 / 無操作復帰)
            "visitor_lang" -> {
                val door = ev.optString("door")
                if (app.boot.role == "door_station" &&
                    (door.isEmpty() || door == app.boot.door))
                    setVisitorLang(ev.optString("lang"))
            }
            // 前取り完了 — 背景画像が待ちだったら読み直す
            "asset_ready" -> {
                val h = themeHash
                if (h != null && ev.optString("hash") == h && themeBg.drawable == null)
                    loadThemeImage(h)
            }
            "display" -> applyNightTint(ev.optBoolean("night"), ev.optBoolean("red_tint"))
            "peers_changed", "config_changed" -> refreshNodeInfo()
        }
    }

    // ---------- 音 ----------

    /** 資産のローカルファイルを再生。失敗時は fallback (TTS / 内蔵音) へ回落する。 */
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
                Log.w(TAG, "カスタム音声の再生失敗 ($what/$extra) — 回落")
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
            Log.w(TAG, "カスタム音声を開けない (回落): $e")
            fallback()
        }
    }

    private fun playChimeTone() {
        try {
            ToneGenerator(AudioManager.STREAM_NOTIFICATION, 90)
                .startTone(ToneGenerator.TONE_PROP_BEEP2, 400)
        } catch (_: Exception) { }
    }

    // ---------- 操作 ----------

    private fun onCallClick() {
        app.core.press(app.boot.door)
        showCalling()
    }

    private fun onSecretCorner() {
        val now = System.currentTimeMillis()
        if (now - secretFirstMs > 5000) { secretFirstMs = now; secretTaps = 0 }
        if (++secretTaps < 7) return
        secretTaps = 0
        AdminPinDialog.show(this, filesDir) {
            adminUnlocked = true
            try { stopLockTask() } catch (_: Exception) { }
            finish()  // kiosk を解いて OS へ戻す (再入は HOME/再起動で)
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    // ---------- カメラ / 権限 ----------

    private fun requestPermissionsIfNeeded() {
        if (Build.VERSION.SDK_INT < 23) return  // API 21-22 はインストール時許可
        val want = arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
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
        if (surfaceReady && hasCameraPermission()) camera.start(preview.holder)
    }

    companion object {
        private const val TAG = "doorbell-ui"
    }
}
