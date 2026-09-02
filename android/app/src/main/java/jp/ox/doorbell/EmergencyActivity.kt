package jp.ox.doorbell

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.TextView

/** Full-screen in-app SOS presentation. It is never launched for notification-only delivery. */
class EmergencyActivity : Activity() {
    private lateinit var app: App
    private var sticky = true

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        app.emergencyActivity = this
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 27) {
            IncomingWindowApi27.apply(this)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD,
            )
        }
        setContentView(R.layout.activity_emergency)
        // Clearing an alarm asks for the same cluster 管理パスワード the rest of the shell uses,
        // but only once one exists: emergency.cancel_requires_pin cannot make an alarm impossible
        // to clear on a cluster where nobody has set a password yet (§5.5).
        findViewById<Button>(R.id.emergency_clear_button).setOnClickListener { button ->
            val config = if (app.coreOk) app.core.config() else null
            val texts = Texts(this).apply {
                setConfig(config)
                setLang(app.boot.uiLang)
            }
            fun clear() {
                if (!app.coreOk) return
                button.isEnabled = false
                if (!app.commitEmergency(false)) button.isEnabled = true
            }
            // Core publishes cancel_requires_pin AND a password actually being set as one
            // answer, so the flag alone can never lock a household out of its own alarm.
            if (AdminPassword.alarmClearNeedsPassword(if (app.coreOk) app.core.status() else null))
                AdminGate.unlock(this, app.boot.httpPort, texts) { clear() }
            else clear()
        }
        renderCurrent()
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        renderCurrent()
    }

    override fun onResume() {
        super.onResume()
        enterImmersive()
        renderCurrent()
    }

    override fun onDestroy() {
        if (app.emergencyActivity === this) app.emergencyActivity = null
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (!sticky) super.onBackPressed()
    }

    internal fun renderPresentation(value: EmergencyPresentation) {
        runOnUiThread {
            if (!value.presentationCurrent(System.currentTimeMillis()) ||
                !value.visual || !value.uses("in_app")) {
                finishForStateClear()
                return@runOnUiThread
            }
            sticky = value.sticky
            val root = findViewById<View>(R.id.emergency_root)
            val title = findViewById<TextView>(R.id.emergency_title_text)
            val source = findViewById<TextView>(R.id.emergency_source_text)
            val clear = findViewById<Button>(R.id.emergency_clear_button)
            title.text = value.title.ifEmpty { getString(R.string.emergency_title) }
            source.text = value.source.ifEmpty { getString(R.string.emergency_notified) }
            root.setBackgroundColor(Color.rgb(139, 0, 0))
            title.setTextColor(Color.WHITE)
            source.setTextColor(Color.WHITE)
            clear.setBackgroundColor(Color.rgb(176, 0, 32))
            clear.setTextColor(Color.WHITE)
            if (!app.safeMode) {
                color(value.background)?.let(root::setBackgroundColor)
                color(value.foreground)?.let {
                    title.setTextColor(it)
                    source.setTextColor(it)
                }
                color(value.accent)?.let(clear::setBackgroundColor)
            }
            clear.isEnabled = true
            val nodeId = app.core.status()?.optJSONObject("node")?.optString("id").orEmpty()
            SemanticUi.invalidate(clear)
            SemanticUi.apply(
                clear,
                "sos.cancel",
                if (app.safeMode) null else app.core.config(),
                nodeId,
            )
        }
    }

    internal fun finishForStateClear() {
        runOnUiThread { if (!isFinishing) finish() }
    }

    private fun renderCurrent() {
        val value = app.emergencyAlerts.current()
        if (value == null) finishForStateClear() else renderPresentation(value)
    }

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

    private fun color(value: String): Int? = try {
        if (value.isEmpty()) null else Color.parseColor(value)
    } catch (_: Exception) {
        null
    }

    companion object {
        fun launch(context: Context): Boolean =
            try {
                context.startActivity(Intent(context, EmergencyActivity::class.java)
                    .addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP,
                    ))
                true
            } catch (_: Exception) {
                false
            }
    }
}
