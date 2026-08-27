// 門口機メイン画面: 待機 / 呼び出し中 / 返信バナー / オフライン の状態機 (WPF 版 MainWindow と同じ)。
// core からの UI イベント (state/chime/reply/…) で遷移する。SIP 実装 (Phase 3 後半) までは
// calling は 30 秒でタイムアウトして待機へ戻る。
// フルスクリーン immersive sticky + KEEP_SCREEN_ON。kiosk は Device Owner 時 startLockTask。
package jp.keihan.doorbell

import android.Manifest
import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.view.animation.AlphaAnimation
import android.view.animation.Animation
import android.widget.Button
import android.widget.TextView
import java.util.Calendar
import java.util.Locale
import org.json.JSONObject

class MainActivity : Activity(), DoorbellCore.Listener {

    private val ui = Handler(Looper.getMainLooper())
    private lateinit var app: App

    private lateinit var idleView: View
    private lateinit var clockText: TextView
    private lateinit var dateText: TextView
    private lateinit var callButton: Button
    private lateinit var touchHint: TextView
    private lateinit var nodeInfo: TextView
    private lateinit var callingView: View
    private lateinit var callingText: TextView
    private lateinit var pulse: View
    private lateinit var replyBanner: View
    private lateinit var replyText: TextView
    private lateinit var offlineView: View
    private lateinit var preview: SurfaceView

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val camera by lazy { CameraFeeder(app.core) }
    private var surfaceReady = false

    private var secretTaps = 0
    private var secretFirstMs = 0L
    private var adminUnlocked = false

    // ---------- タイマ (WPF DispatcherTimer 相当) ----------
    private val clockTick = object : Runnable {
        override fun run() { updateClock(); ui.postDelayed(this, 1000) }
    }
    private val callTimeout = Runnable { showIdle(getString(R.string.calling_no_answer)) }
    private val replyTimeout = Runnable { replyBanner.visibility = View.GONE }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)
        bindViews()

        callButton.text = getString(R.string.idle_call_button, "").trim()
        callButton.setOnClickListener { onCallClick() }
        findViewById<View>(R.id.cancel_button).setOnClickListener {
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

        app.core.listener = this
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
        app.core.listener = null
        camera.stop()
        tts?.shutdown()
        super.onDestroy()
    }

    @Deprecated("kiosk 中は戻れない")
    override fun onBackPressed() {
        if (!app.boot.kiosk || adminUnlocked) super.onBackPressed()
    }

    private fun bindViews() {
        idleView = findViewById(R.id.idle_view)
        clockText = findViewById(R.id.clock_text)
        dateText = findViewById(R.id.date_text)
        callButton = findViewById(R.id.call_button)
        touchHint = findViewById(R.id.touch_hint)
        nodeInfo = findViewById(R.id.node_info)
        callingView = findViewById(R.id.calling_view)
        callingText = findViewById(R.id.calling_text)
        pulse = findViewById(R.id.pulse)
        replyBanner = findViewById(R.id.reply_banner)
        replyText = findViewById(R.id.reply_text)
        offlineView = findViewById(R.id.offline_view)
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
        val st = app.core.status()
        val node = st?.optJSONObject("node")
        if (node != null)
            nodeInfo.text = node.optString("name") + " · v" + node.optString("version")
        // 呼び出しボタンにドアの表示名 (設定 doors.<door>.label.<lang>) を反映
        val door = app.boot.door
        if (door.isNotEmpty()) {
            val cfg = app.core.config()
            val label = app.core.dig(cfg, "doors.$door.label.${app.boot.uiLang}")
                ?: app.core.dig(cfg, "doors.$door.label.ja")
            if (label != null)
                callButton.text = getString(R.string.idle_call_button, label.toString())
        }
    }

    // ---------- 状態遷移 ----------

    private fun showIdle(hint: String? = null) {
        ui.removeCallbacks(callTimeout)
        pulse.clearAnimation()
        callingView.visibility = View.GONE
        offlineView.visibility = View.GONE
        idleView.visibility = View.VISIBLE
        if (hint != null) touchHint.text = hint
    }

    private fun showCalling() {
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
        ui.post {
            if (!ttsReady || text.isEmpty()) return@post
            try {
                tts?.language = Locale(if (lang.isEmpty()) "ja" else lang)
                @Suppress("DEPRECATION")
                if (Build.VERSION.SDK_INT >= 21)
                    tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "reply")
                else
                    tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null)
            } catch (_: Exception) { }
        }
    }

    private fun handleUiEvent(ev: JSONObject) {
        when (ev.optString("t")) {
            "state" -> when (ev.optString("state")) {
                "calling" -> showCalling()
                "idle" -> showIdle()
                "in_call" -> callingText.text = getString(R.string.incall_title)
            }
            "chime" -> playChime()
            "reply" -> {
                replyText.text = ev.optString("text")
                replyBanner.visibility = View.VISIBLE
                var ttl = ev.optDouble("ttl_s", 30.0)
                if (ttl <= 0) ttl = 30.0
                ui.removeCallbacks(replyTimeout)
                ui.postDelayed(replyTimeout, (ttl * 1000).toLong())
                // 訪客が見たら呼び出し継続は不要 → 待機へ
                showIdle()
            }
            "peers_changed", "config_changed" -> refreshNodeInfo()
        }
    }

    private fun playChime() {
        // TODO(Phase3後半): 設定 chime.sound の同梱 wav 再生。まずはトーンで代用
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
}
