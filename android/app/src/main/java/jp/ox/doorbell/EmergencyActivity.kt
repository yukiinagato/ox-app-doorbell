package jp.ox.doorbell

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
class EmergencyActivity : ShellActivity() {

    /** The alarm overlay is the negative role in either appearance; nothing to rebuild. */
    override fun onAppearanceChanged() = Unit

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
        // Clearing takes the same two deliberate gestures as sending (guidelines "SOS"): a tap
        // opens the confirmation surface, and a slide there (or its focusable button) confirms.
        // There is no press-and-hold.
        val clearButton = findViewById<Button>(R.id.emergency_clear_button)
        clearButton.setOnClickListener { button -> confirmClear(button) }
        renderCurrent()
    }

    /**
     * Clearing an alarm asks for the same cluster 管理パスワード the rest of the shell uses, but
     * only once one exists: emergency.cancel_requires_pin cannot make an alarm impossible to clear
     * on a cluster where nobody has set a password yet (§5.5).
     */
    private var clearSurface: SosConfirmSurface? = null

    private fun confirmClear(button: View) {
        if (clearSurface?.showing == true) return
        val texts = Texts(this).apply {
            setConfig(if (app.coreOk) app.core.config() else null)
            setLang(app.boot.uiLang)
        }
        var opened: SosConfirmSurface? = null
        opened = SosConfirmSurface(
            this, android.os.Handler(mainLooper),
            title = texts.t("sos.clear_confirm_title", R.string.sos_clear_confirm_title),
            message = "",
            slideLabel = texts.t("sos.slide_clear", R.string.sos_slide_clear),
            slideSub = "",
            sendLabel = texts.t("emergency.cancel", R.string.emergency_cancel),
            cancelLabel = texts.t("sos.countdown_cancel", R.string.sos_countdown_cancel),
            // Clearing has no countdown: the slide itself is the confirmation.
            countdownSeconds = 0,
            countdownText = { it.toString() },
            palette = PlatformUi.tokens(this),
            enabled = { !isFinishing },
            onConfirmed = { requestClear(button) },
            onClosed = { if (clearSurface === opened) clearSurface = null },
        )
        clearSurface = opened
        opened.show()
    }

    private fun requestClear(button: View) {
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
        // Core publishes cancel_requires_pin AND a password actually being set as one answer,
        // so the flag alone can never lock a household out of its own alarm.
        if (AdminPassword.alarmClearNeedsPassword(if (app.coreOk) app.core.status() else null))
            AdminGate.unlock(this, app.boot.httpPort, texts) { clear() }
        else clear()
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
        clearSurface?.dismiss()
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
            val time = findViewById<TextView>(R.id.emergency_time_text)
            val hint = findViewById<TextView>(R.id.emergency_hint_text)
            val clear = findViewById<Button>(R.id.emergency_clear_button)
            val texts = Texts(this).apply {
                setConfig(if (app.coreOk) app.core.config() else null)
                setLang(app.boot.uiLang)
            }
            title.text = value.title.ifEmpty { texts.t("emergency.title", R.string.emergency_title) }
            source.text = value.source.ifEmpty { texts.t("emergency.notified", R.string.emergency_notified) }
            clear.text = texts.t("emergency.cancel", R.string.emergency_cancel)
            hint.text = texts.t("sos.tap_to_clear", R.string.sos_tap_to_clear)
            if (value.receivedWallMs > 0L) {
                val at = ClusterClock(app.core).format(value.receivedWallMs)
                time.text = texts.t("sos.since", R.string.sos_since,
                    String.format(java.util.Locale.US, "%02d:%02d", at.hour, at.minute))
                time.visibility = View.VISIBLE
            } else {
                time.visibility = View.GONE
            }
            // The negative role on a white-ink surface; a configured presentation colour, when
            // the cluster sets one, is the region colour and wins.
            val roles = UiRoles.from(Palette.LIGHT)
            var ground = roles.negative
            var ink = roles.onNegative
            // The one action is a filled button in the ink colour, so it stands off the ground.
            var button = ink
            var buttonInk = ground
            if (!app.safeMode) {
                color(value.background)?.let { ground = it }
                color(value.foreground)?.let { ink = it }
                button = ink
                buttonInk = ground
                color(value.accent)?.let {
                    button = it
                    buttonInk = Palette.LIGHT.inkOver(it)
                }
            }
            root.setBackgroundColor(ShellUi.opaque(ground))
            for (view in listOf(title, source, time, hint)) view.setTextColor(ShellUi.opaque(ink))
            SemanticUi.release(clear)
            PlatformUi.styleButton(clear, ButtonKind.FILLED, button, buttonInk)
            clear.minHeight = ShellUi.dp(this, UiTokens.VISITOR_TOUCH_MIN_DP)
            clear.minimumHeight = ShellUi.dp(this, UiTokens.VISITOR_TOUCH_MIN_DP)
            clear.isEnabled = true
            val nodeId = app.core.status()?.optJSONObject("node")?.optString("id").orEmpty()
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
