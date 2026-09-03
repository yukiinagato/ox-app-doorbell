// Full-screen Add-QR scanner (spec 5.1.4).
//
// No scanning library is bundled: the camera frames already delivered to Core through
// db_core_on_camera_frame are decoded by Core's own scan mode, which invites automatically when
// the payload is a doorbell-pair QR. This Activity only owns the preview, the viewfinder, and the
// result rendering.
package jp.ox.doorbell

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject

class QrScanActivity : Activity(), DoorbellCore.Listener, SurfaceHolder.Callback {


    private lateinit var app: App
    private lateinit var texts: Texts
    private val ui = Handler(Looper.getMainLooper())

    private lateinit var preview: SurfaceView
    private lateinit var hintView: TextView
    private lateinit var resultView: TextView
    private lateinit var messageView: TextView

    private var scanning = false
    private var surfaceReady = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        texts = Texts(this)
        texts.setConfig(if (app.coreOk) app.core.config() else null)
        texts.setLang(app.boot.uiLang)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(buildUi())
        if (!app.runtime.hasCamera()) {
            showMessage(texts.t("pair.scan_no_camera", R.string.pair_scan_no_camera))
        } else if (!hasCameraPermission()) {
            showMessage(texts.t("pair.scan_camera_denied", R.string.pair_scan_camera_denied))
            requestCameraPermission()
        }
    }

    override fun onResume() {
        super.onResume()
        app.bindForeground(this)
        if (surfaceReady) startScanning()
    }

    override fun onPause() {
        super.onPause()
        app.unbindForeground(this)
        stopScanning()
    }

    override fun onDestroy() {
        app.unbindForeground(this)
        stopScanning()
        super.onDestroy()
    }

    // ---------- camera ----------

    private fun hasCameraPermission(): Boolean = Build.VERSION.SDK_INT < 23 ||
        checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun requestCameraPermission() {
        if (Build.VERSION.SDK_INT < 23) return
        requestPermissions(arrayOf(Manifest.permission.CAMERA), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (hasCameraPermission()) {
            showMessage("")
            if (surfaceReady) startScanning()
        } else {
            showMessage(texts.t("pair.scan_camera_denied", R.string.pair_scan_camera_denied))
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceReady = true
        startScanning()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
        stopScanning()
    }

    private fun startScanning() {
        if (scanning || !app.coreOk) return
        if (!app.runtime.hasCamera()) return
        if (!hasCameraPermission()) return
        scanning = true
        app.core.qrScanStart()
        app.runtime.acquireScannerPreview(preview.holder) { started ->
            ui.post {
                if (!started) {
                    scanning = false
                    app.core.qrScanStop()
                    showMessage(texts.t("pair.scan_camera_denied", R.string.pair_scan_camera_denied))
                } else {
                    showMessage("")
                }
            }
        }
    }

    private fun stopScanning() {
        if (!scanning) return
        scanning = false
        app.core.qrScanStop()
        app.runtime.releaseScannerPreview()
    }

    // ---------- Core events ----------

    override fun onUiEvent(ev: JSONObject) {
        ui.post { handleEvent(ev) }
    }

    override fun onTts(text: String, lang: String) {}

    private fun handleEvent(ev: JSONObject) {
        when (ev.optString("t")) {
            "qr_scanned" -> {
                val text = ev.optString("text")
                // A pairing link belongs to whoever opened the scanner, not to the add flow.
                if (PairUri.looksLikePairLink(text)) {
                    setResult(RESULT_OK, Intent().putExtra(EXTRA_SCANNED_TEXT, text))
                    finish()
                    return
                }
                if (!PairingModel.isPairQr(text)) return
                resultView.visibility = View.VISIBLE
                resultView.setTextColor(PairingUi.DIM)
                resultView.text = texts.t("pair.adding", R.string.pair_adding)
            }
            "invite_result" -> {
                if (ev.optBoolean("ok")) return
                resultView.visibility = View.VISIBLE
                resultView.setTextColor(PairingUi.ERR)
                val code = ev.optString("err")
                resultView.text =
                    texts.t("pair.add_failed", R.string.pair_add_failed) + "\n" +
                    texts.t(PairingModel.errorKey(code), PairingModel.errorResource(code))
            }
            "device_joined" -> {
                resultView.visibility = View.VISIBLE
                resultView.setTextColor(PairingUi.OK)
                resultView.text = "✓ " + texts.t("pair.added", R.string.pair_added) + " " +
                    ev.optString("name")
                // The scan succeeded, so the panel below can take over.
                ui.postDelayed({ finish() }, JOINED_DWELL_MS)
            }
            "qr_scan_state" -> if (!ev.optBoolean("active") && scanning) {
                // Core stops scanning by itself after two minutes.
                scanning = false
                app.runtime.releaseScannerPreview()
                showMessage(texts.t("pair.scan_hint", R.string.pair_scan_hint))
            }
        }
    }

    private fun showMessage(message: String) {
        messageView.text = message
        messageView.visibility = if (message.isEmpty()) View.GONE else View.VISIBLE
    }

    // ---------- views ----------

    private fun dp(v: Int) = PairingUi.dp(this, v)

    private fun buildUi(): View {
        val frame = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        preview = SurfaceView(this)
        preview.holder.addCallback(this)
        frame.addView(
            preview,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        frame.addView(
            ViewfinderView(this),
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

        val overlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(20), dp(20), dp(20), dp(24))
        }
        hintView = PairingUi.body(this, texts.t("pair.scan_hint", R.string.pair_scan_hint)).apply {
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        }
        overlay.addView(hintView, PairingUi.matchWrap())
        resultView = PairingUi.body(this).apply {
            gravity = Gravity.CENTER
            visibility = View.GONE
            setPadding(0, dp(10), 0, 0)
        }
        overlay.addView(resultView, PairingUi.matchWrap())
        messageView = PairingUi.body(this).apply {
            setTextColor(PairingUi.WARN)
            gravity = Gravity.CENTER
            visibility = View.GONE
            setPadding(0, dp(10), 0, 0)
        }
        overlay.addView(messageView, PairingUi.matchWrap())
        val cancel: Button = PairingUi.button(
            this,
            texts.t("calling.cancel", R.string.calling_cancel),
        ) { finish() }
        overlay.addView(cancel, PairingUi.matchWrap().apply { topMargin = dp(16) })
        frame.addView(
            overlay,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM,
            ),
        )
        return frame
    }

    /** Dimmed surround with a clear square in the middle, drawn without any drawable assets. */
    private class ViewfinderView(activity: Activity) : View(activity) {
        private val shade = Paint().apply { color = Color.parseColor("#99000000") }
        private val frame = Paint().apply {
            color = PairingUi.ACCENT
            style = Paint.Style.STROKE
            strokeWidth = 6f
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val side = (minOf(width, height) * 0.62f)
            val left = (width - side) / 2f
            val top = (height - side) / 2f
            canvas.drawRect(0f, 0f, width.toFloat(), top, shade)
            canvas.drawRect(0f, top + side, width.toFloat(), height.toFloat(), shade)
            canvas.drawRect(0f, top, left, top + side, shade)
            canvas.drawRect(left + side, top, width.toFloat(), top + side, shade)
            canvas.drawRect(left, top, left + side, top + side, frame)
        }
    }

    companion object {
        /** The decoded text handed back when the caller started this for a result. */
        const val EXTRA_SCANNED_TEXT = "scanned_text"
        private const val PERMISSION_REQUEST = 21
        private const val JOINED_DWELL_MS = 1_500L
    }
}
