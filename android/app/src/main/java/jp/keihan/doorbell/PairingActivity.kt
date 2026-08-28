// 未配対 (全ゼロ PSK) の端末で出す配対引導画面。
//  - 自機の配対 QR を表示 (管理者が『デバイスを追加』一覧で承認 or この QR を読み取る)
//  - 手動フォールバック: seed アドレス + PIN で能動参加
// core の "paired" イベント (App が転送) または pairingInfo ポーリングで配対完了を検知し自動終了。
package jp.keihan.doorbell

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import org.json.JSONObject

class PairingActivity : Activity(), DoorbellCore.Listener {

    private lateinit var app: App
    private val ui = Handler(Looper.getMainLooper())
    private lateinit var qrView: ImageView
    private lateinit var statusText: TextView
    private lateinit var subtitle: TextView
    private lateinit var hostField: EditText
    private lateinit var pinField: EditText
    private var lastQr: String = ""

    private val poll = object : Runnable {
        override fun run() {
            if (isPairedNow()) { finishPaired(); return }
            refresh()
            ui.postDelayed(this, 3000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        setContentView(buildUi())
        refresh()
    }

    override fun onResume() {
        super.onResume()
        if (isPairedNow()) { finishPaired(); return }
        app.activityListener = this   // core イベントの転送先を奪う
        ui.removeCallbacks(poll)
        ui.postDelayed(poll, 3000)
    }

    override fun onPause() {
        super.onPause()
        if (app.activityListener === this) app.activityListener = null
        ui.removeCallbacks(poll)
    }

    private fun isPairedNow(): Boolean =
        app.coreOk && (app.core.pairingInfo()?.optBoolean("paired") == true)

    private fun finishPaired() {
        ui.removeCallbacks(poll)
        finish()
    }

    // ---------- core イベント (App から転送 — main スレッド) ----------
    override fun onUiEvent(ev: JSONObject) {
        when (ev.optString("t")) {
            "paired" -> finishPaired()  // App.onPaired が boot.json を永続化済み
            "join_result" -> {
                val ok = ev.optBoolean("ok")
                if (ok) finishPaired()
                else Toast.makeText(this, "参加できませんでした: ${ev.optString("err")}",
                                    Toast.LENGTH_LONG).show()
            }
        }
    }
    override fun onTts(text: String, lang: String) {}

    // ---------- pairingInfo を反映 ----------
    private fun refresh() {
        val p = (if (app.coreOk) app.core.pairingInfo() else null) ?: return
        val self = p.optJSONObject("self")
        val name = self?.optString("name") ?: ""
        val addr = self?.optString("addr") ?: ""
        subtitle.text = if (name.isNotEmpty()) "$name\n$addr" else addr
        val qr = p.optString("pair_qr")
        if (qr.isNotEmpty() && qr != lastQr) {
            lastQr = qr
            qrView.setImageBitmap(qrBitmap(qr, 720))
        }
    }

    // ---------- QR (core 共通エンコーダで行列 → Bitmap) ----------
    private fun qrBitmap(text: String, targetPx: Int): Bitmap? {
        val enc = app.core.qrEncode(text) ?: return null
        val size = enc[0]
        if (size <= 0 || enc.size < 1 + size * size) return null
        val quiet = 3
        val total = size + quiet * 2
        val scale = maxOf(1, targetPx / total)
        val dim = total * scale
        val bmp = Bitmap.createBitmap(dim, dim, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.drawColor(Color.WHITE)
        val paint = Paint().apply { color = Color.BLACK }
        for (y in 0 until size) for (x in 0 until size) {
            if (enc[1 + y * size + x] != 0) {
                val l = ((x + quiet) * scale).toFloat()
                val t = ((y + quiet) * scale).toFloat()
                canvas.drawRect(l, t, l + scale, t + scale, paint)
            }
        }
        return bmp
    }

    // ---------- UI 構築 (framework views のみ・自己完結) ----------
    private fun buildUi(): View {
        fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
        val scroll = ScrollView(this).apply { setBackgroundColor(Color.parseColor("#0E1621")) }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(32), dp(24), dp(32))
        }
        scroll.addView(root, ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        root.addView(TextView(this).apply {
            text = "この端末を追加"
            setTextColor(Color.WHITE); textSize = 26f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        subtitle = TextView(this).apply {
            setTextColor(Color.parseColor("#9FB0C0")); textSize = 14f
            gravity = Gravity.CENTER
            setPadding(0, dp(6), 0, dp(18))
        }
        root.addView(subtitle)

        qrView = ImageView(this).apply {
            setBackgroundColor(Color.WHITE)
            setPadding(dp(8), dp(8), dp(8), dp(8))
        }
        root.addView(qrView, LinearLayout.LayoutParams(dp(240), dp(240)))

        statusText = TextView(this).apply {
            text = "配対を待っています…\n管理画面の「デバイスを追加」でこの端末を承認するか、この QR を読み取ってください。"
            setTextColor(Color.parseColor("#9FB0C0")); textSize = 14f
            gravity = Gravity.CENTER
            setPadding(0, dp(16), 0, dp(20))
        }
        root.addView(statusText)

        // 区切り + 手動 PIN 参加
        root.addView(TextView(this).apply {
            text = "── または PIN で参加 ──"
            setTextColor(Color.parseColor("#63758A")); textSize = 13f
            setPadding(0, dp(4), 0, dp(10))
        })
        hostField = EditText(this).apply {
            hint = "接続先 (例 10.0.1.5:47172)"
            setTextColor(Color.WHITE); setHintTextColor(Color.parseColor("#63758A"))
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setSingleLine(true)
        }
        root.addView(hostField, LinearLayout.LayoutParams(dp(280), ViewGroup.LayoutParams.WRAP_CONTENT))
        pinField = EditText(this).apply {
            hint = "PIN (6 桁)"
            setTextColor(Color.WHITE); setHintTextColor(Color.parseColor("#63758A"))
            inputType = InputType.TYPE_CLASS_NUMBER
            setSingleLine(true)
        }
        root.addView(pinField, LinearLayout.LayoutParams(dp(280), ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(8)
        })
        root.addView(Button(this).apply {
            text = "参加する"
            setOnClickListener { onJoinClick() }
        }, LinearLayout.LayoutParams(dp(280), ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(12)
        })
        return scroll
    }

    private fun onJoinClick() {
        val host = hostField.text.toString().trim()
        val pin = pinField.text.toString().trim()
        if (host.isEmpty() || pin.isEmpty()) {
            Toast.makeText(this, "接続先と PIN を入力してください", Toast.LENGTH_SHORT).show()
            return
        }
        app.core.joinCluster(host, pin)
        Toast.makeText(this, "参加を試みています…", Toast.LENGTH_SHORT).show()
    }
}
