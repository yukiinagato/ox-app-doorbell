// Onboarding screen for a device that is not a cluster member yet (spec 5.0).
//
// Core owns the state; this screen renders pairing.state and the pairing events and never infers
// membership from a return value. It offers the three documented paths: wait to be added (with
// this device's own Add QR), join with a Pairing PIN, or create a new cluster here.
package jp.ox.doorbell

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject

class PairingActivity : Activity(), DoorbellCore.Listener {

    private lateinit var app: App
    private lateinit var texts: Texts
    private val ui = Handler(Looper.getMainLooper())

    private lateinit var titleView: TextView
    private lateinit var identityView: TextView
    private lateinit var spinner: ProgressBar
    private lateinit var statusView: TextView
    private lateinit var hintView: TextView
    private lateinit var qrView: ImageView
    private lateinit var qrPlaceholder: TextView
    private lateinit var qrCaption: TextView
    private lateinit var errorView: TextView

    private lateinit var actionBlock: LinearLayout
    private lateinit var joinButton: Button
    private lateinit var createButton: Button
    private lateinit var laterButton: Button

    private lateinit var joinCard: LinearLayout
    private lateinit var hostField: EditText
    private lateinit var pinDisplay: TextView
    private lateinit var joinSubmit: Button
    private lateinit var joinError: TextView

    private lateinit var createdCard: LinearLayout
    private lateinit var createdTitle: TextView
    private lateinit var codeHost: TextView
    private lateinit var codePin: TextView
    private lateinit var codeCountdown: TextView
    private lateinit var codeAttempts: TextView
    private lateinit var createdRenew: Button

    private lateinit var persistCard: LinearLayout
    private lateinit var sosButton: Button

    private var lastQr = ""
    private var pin = ""
    private var joinInFlight = false
    private var createInFlight = false
    /** Set once the user created the cluster here: the code card must stay on screen. */
    private var createdHere = false
    private var closing = false
    private var lastState = ""

    private val tick = object : Runnable {
        override fun run() {
            refresh()
            ui.postDelayed(this, POLL_MS)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        texts = Texts(this)
        texts.setConfig(if (app.coreOk) app.core.config() else null)
        texts.setLang(app.boot.uiLang)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        setContentView(buildUi())
        applyStrings()
        refresh()
    }

    override fun onResume() {
        super.onResume()
        app.bindForeground(this)
        enterImmersive()
        if (finishWhenReady()) return
        ui.removeCallbacks(tick)
        ui.postDelayed(tick, POLL_MS)
    }

    override fun onPause() {
        super.onPause()
        app.unbindForeground(this)
        ui.removeCallbacks(tick)
    }

    override fun onDestroy() {
        app.unbindForeground(this)
        ui.removeCallbacks(tick)
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersive()
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

    /** Back behaves like "set up later": the main UI keeps a banner, and never relaunches here. */
    @Deprecated("Framework Activity API")
    override fun onBackPressed() {
        setUpLater()
    }

    // ---------- state ----------

    private fun pairing(): JSONObject? = if (app.coreOk) app.core.pairingInfo() else null

    private fun finishWhenReady(): Boolean {
        if (closing || createdHere) return false
        if (!app.pairingReady()) return false
        closing = true
        showJoined()
        return true
    }

    private fun showJoined() {
        ui.removeCallbacks(tick)
        spinner.visibility = View.GONE
        statusView.setTextColor(PairingUi.OK)
        statusView.text = "✓ " + texts.t("pair.joined", R.string.pair_joined)
        hintView.visibility = View.GONE
        actionBlock.visibility = View.GONE
        joinCard.visibility = View.GONE
        persistCard.visibility = View.GONE
        errorView.visibility = View.GONE
        ui.postDelayed({ finish() }, JOINED_DWELL_MS)
    }

    private fun setUpLater() {
        app.deferPairing()
        finish()
    }

    /** Redraw everything from the authoritative snapshot; safe to call at any time. */
    private fun refresh() {
        // The success confirmation must stay on screen for its full dwell time.
        if (closing) return
        val p = pairing()
        val state = PairingModel.state(p)
        val self = p?.optJSONObject("self")
        val name = self?.optString("name").orEmpty().ifEmpty { app.boot.name }
        val model = self?.optString("model").orEmpty()
        val addr = self?.optString("addr").orEmpty()
        identityView.text = listOf(name, model, addr).filter { it.isNotEmpty() }
            .joinToString("\n")

        val qr = p?.optString("pair_qr").orEmpty()
        if (qr.isNotEmpty() && qr != lastQr) {
            val bmp = PairingUi.qrBitmap(app.core, qr, QR_PX)
            if (bmp != null) {
                lastQr = qr
                qrView.setImageBitmap(bmp)
                qrView.visibility = View.VISIBLE
                qrPlaceholder.visibility = View.GONE
            }
        }

        if (state != lastState) {
            lastState = state
            joinInFlight = state == PairingModel.JOINING
        }
        renderState(state)
        renderCodeCard(p)
        SemanticUi.apply(
            sosButton,
            "sos.trigger",
            if (app.safeMode) null else app.core.config(),
            app.core.status()?.optJSONObject("node")?.optString("id").orEmpty(),
        )
        if (state == PairingModel.READY) finishWhenReady()
    }

    private fun renderState(state: String) {
        when (state) {
            PairingModel.JOINING -> {
                spinner.visibility = View.VISIBLE
                statusView.setTextColor(PairingUi.TEXT)
                statusView.text = texts.t("pair.joining", R.string.pair_joining)
                hintView.visibility = View.GONE
                persistCard.visibility = View.GONE
                setInputsEnabled(false)
            }
            PairingModel.PERSIST_ERROR -> {
                spinner.visibility = View.GONE
                statusView.setTextColor(PairingUi.ERR)
                statusView.text =
                    texts.t("pair.persist_error_title", R.string.pair_persist_error_title)
                hintView.visibility = View.GONE
                // Only the retry path may be reachable, so nothing else can clear the error.
                persistCard.visibility = View.VISIBLE
                actionBlock.visibility = View.GONE
                joinCard.visibility = View.GONE
                createdCard.visibility = View.GONE
                errorView.visibility = View.GONE
                // Leaving now would hide a device that believes it is paired but cannot save.
                laterButton.visibility = View.GONE
            }
            PairingModel.REVOKED -> {
                spinner.visibility = View.GONE
                statusView.setTextColor(PairingUi.WARN)
                statusView.text = texts.t("pair.revoked", R.string.pair_revoked)
                hintView.visibility = View.GONE
                persistCard.visibility = View.GONE
                setInputsEnabled(true)
            }
            PairingModel.READY -> {
                spinner.visibility = View.GONE
                statusView.setTextColor(PairingUi.OK)
                statusView.text = "✓ " + (if (createdHere)
                    texts.t("pair.created", R.string.pair_created)
                else texts.t("pair.joined", R.string.pair_joined))
                hintView.visibility = View.GONE
                persistCard.visibility = View.GONE
                laterButton.visibility = View.VISIBLE
            }
            else -> {
                spinner.visibility = View.VISIBLE
                statusView.setTextColor(PairingUi.TEXT)
                statusView.text = texts.t("pair.searching", R.string.pair_searching)
                hintView.visibility = View.VISIBLE
                persistCard.visibility = View.GONE
                if (!createInFlight) setInputsEnabled(true)
                actionBlock.visibility = View.VISIBLE
                laterButton.visibility = View.VISIBLE
            }
        }
    }

    private fun setInputsEnabled(enabled: Boolean) {
        joinButton.isEnabled = enabled
        createButton.isEnabled = enabled
        joinSubmit.isEnabled = enabled && pin.length == PIN_LENGTH
        hostField.isEnabled = enabled
    }

    /** The create-cluster confirmation card keeps the live PIN visible until the user leaves. */
    private fun renderCodeCard(p: JSONObject?) {
        if (!createdHere) return
        createdCard.visibility = View.VISIBLE
        actionBlock.visibility = View.GONE
        joinCard.visibility = View.GONE
        val token = PairingModel.token(p)
        codeHost.text = texts.t("pair.address_label", R.string.pair_address_label) + ": " +
            token.host.ifEmpty { p?.optJSONObject("self")?.optString("addr").orEmpty() }
        if (token.active) {
            codePin.text = token.pin
            codeCountdown.setTextColor(PairingUi.DIM)
            codeCountdown.text = texts.t(
                "pair.code_expires_in", R.string.pair_code_expires_in,
                PairingModel.minutes(token.expiresSeconds), PairingModel.seconds(token.expiresSeconds),
            )
            codeAttempts.text = texts.t(
                "pair.code_attempts_left", R.string.pair_code_attempts_left,
                token.attemptsLeft.toString(),
            )
            codeAttempts.visibility = View.VISIBLE
            createdRenew.visibility = View.GONE
        } else {
            codePin.text = "——————"
            codeCountdown.setTextColor(PairingUi.WARN)
            codeCountdown.text = texts.t("pair.code_expired", R.string.pair_code_expired)
            codeAttempts.visibility = View.GONE
            createdRenew.visibility = View.VISIBLE
        }
    }

    /** Mint a fresh Pairing PIN after the previous one expired or burned its attempts. */
    private fun renewCode() {
        createdRenew.isEnabled = false
        Thread {
            val result = app.core.startPairing(PairingModel.PAIRING_WINDOW_S)
            ui.post {
                createdRenew.isEnabled = true
                if (result != null && !result.optBoolean("ok"))
                    showInlineError(errorText(result.optString("err")))
                refresh()
            }
        }.apply { name = "doorbell-renew-pin" }.start()
    }

    // ---------- Core events ----------

    override fun onUiEvent(ev: JSONObject) {
        ui.post { handleEvent(ev) }
    }

    override fun onTts(text: String, lang: String) {}

    private fun handleEvent(ev: JSONObject) {
        when (ev.optString("t")) {
            "pairing_state" -> {
                refresh()
                if (ev.optString("state") == PairingModel.READY && !createdHere) finishWhenReady()
            }
            "join_result" -> {
                joinInFlight = false
                if (ev.optBoolean("ok")) {
                    showInlineError("")
                } else {
                    showInlineError(errorText(ev.optString("err")))
                }
                refresh()
            }
            "invite_rejected" -> {
                joinInFlight = false
                showInlineError(errorText(ev.optString("reason")))
                refresh()
            }
            "pairing_persistence_error" -> refresh()
            "paired" -> refresh()
            "join_token_changed", "pending_changed", "pairing_mode_changed" -> refresh()
            "pairing_revoked" -> {
                createdHere = false
                closing = false
                refresh()
            }
            "config_changed" -> {
                texts.setConfig(app.core.config())
                applyStrings()
                refresh()
            }
        }
    }

    /** Never show a bare code: the human message leads, the code is only a detail line. */
    private fun errorText(code: String): String {
        val message = texts.t(PairingModel.errorKey(code), PairingModel.errorResource(code))
        if (code.isEmpty()) return message
        return message + "\n" + texts.t("pair.err_detail", R.string.pair_err_detail, code)
    }

    private fun showInlineError(message: String) {
        val target = if (joinCard.visibility == View.VISIBLE) joinError else errorView
        target.text = message
        target.visibility = if (message.isEmpty()) View.GONE else View.VISIBLE
    }

    // ---------- actions ----------

    private fun onJoinSubmit() {
        val host = hostField.text.toString().trim()
        if (host.isEmpty() || pin.length != PIN_LENGTH) {
            joinError.text = texts.t("pair.join_required", R.string.pair_join_required)
            joinError.visibility = View.VISIBLE
            return
        }
        joinError.visibility = View.GONE
        joinInFlight = true
        setInputsEnabled(false)
        spinner.visibility = View.VISIBLE
        statusView.text = texts.t("pair.joining", R.string.pair_joining)
        app.core.joinCluster(host, pin)
    }

    private fun onCreateCluster() {
        AlertDialog.Builder(this)
            .setTitle(texts.t("pair.create_home", R.string.pair_create_home))
            .setMessage(texts.t("pair.create_home_confirm", R.string.pair_create_home_confirm))
            .setPositiveButton(texts.t("pair.create_home", R.string.pair_create_home)) { _, _ ->
                startCreateCluster()
            }
            .setNegativeButton(texts.t("calling.cancel", R.string.calling_cancel), null)
            .show()
    }

    /**
     * foundCluster does disk and crypto work, so it runs off the main thread. Success is decided
     * by the pairing state that follows, never by the return value alone.
     */
    private fun startCreateCluster() {
        if (createInFlight) return
        createInFlight = true
        setInputsEnabled(false)
        spinner.visibility = View.VISIBLE
        statusView.text = texts.t("pair.joining", R.string.pair_joining)
        Thread {
            val started = app.core.foundCluster()
            val token = if (started) app.core.startPairing(PairingModel.PAIRING_WINDOW_S) else null
            ui.post {
                createInFlight = false
                if (!started) {
                    setInputsEnabled(true)
                    showInlineError(errorText("already_paired"))
                } else {
                    createdHere = true
                    if (token != null && !token.optBoolean("ok")) {
                        showInlineError(errorText(token.optString("err")))
                    }
                }
                refresh()
            }
        }.apply { name = "doorbell-found-cluster" }.start()
    }

    private fun onRetryPersistence() {
        spinner.visibility = View.VISIBLE
        Thread {
            val ok = app.core.retryPairingPersistence()
            ui.post {
                spinner.visibility = View.GONE
                refresh()
                if (ok) finishWhenReady()
            }
        }.apply { name = "doorbell-retry-persist" }.start()
    }

    // ---------- view construction ----------

    private fun applyStrings() {
        titleView.text = texts.t("pair.title_unpaired", R.string.pair_title_unpaired)
        hintView.text = texts.t("pair.searching_hint", R.string.pair_searching_hint)
        qrCaption.text = texts.t("pair.qr_caption", R.string.pair_qr_caption)
        qrPlaceholder.text = texts.t("pair.searching", R.string.pair_searching)
        joinButton.text = texts.t("pair.join_with_code", R.string.pair_join_with_code)
        createButton.text = texts.t("pair.create_home", R.string.pair_create_home)
        laterButton.text = texts.t("pair.later", R.string.pair_later)
        joinSubmit.text = texts.t("pair.join_with_code", R.string.pair_join_with_code)
        hostField.hint = texts.t("pair.address_label", R.string.pair_address_label) + " " +
            texts.t("pair.address_example", R.string.pair_address_example)
        createdTitle.text = texts.t("pair.created", R.string.pair_created) + " ✓"
    }

    private fun dp(v: Int) = PairingUi.dp(this, v)

    private fun buildUi(): View {
        val frame = FrameLayout(this)
        val scroll = ScrollView(this).apply { setBackgroundColor(PairingUi.BG) }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(24), dp(20), dp(120))
        }
        scroll.addView(
            root,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        titleView = PairingUi.title(this, "")
        root.addView(titleView, PairingUi.matchWrap())
        identityView = PairingUi.small(this).apply { setPadding(0, dp(6), 0, dp(14)) }
        root.addView(identityView, PairingUi.matchWrap())

        // Live status block.
        val statusRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        spinner = ProgressBar(this).apply {
            isIndeterminate = true
        }
        statusRow.addView(spinner, LinearLayout.LayoutParams(dp(28), dp(28)).apply {
            rightMargin = dp(10)
        })
        statusView = PairingUi.body(this).apply { textSize = 17f; setTextColor(PairingUi.TEXT) }
        statusRow.addView(statusView, LinearLayout.LayoutParams(0,
            ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        root.addView(statusRow, PairingUi.matchWrap())
        hintView = PairingUi.body(this).apply { setPadding(0, dp(8), 0, dp(4)) }
        root.addView(hintView, PairingUi.matchWrap())

        errorView = PairingUi.body(this).apply {
            setTextColor(PairingUi.ERR)
            visibility = View.GONE
            setPadding(0, dp(8), 0, 0)
        }
        root.addView(errorView, PairingUi.matchWrap())

        // The device's own Add QR. A placeholder holds the space until Core publishes one.
        root.addView(PairingUi.spacer(this, 16))
        val qrBox = FrameLayout(this)
        qrPlaceholder = PairingUi.qrPlaceholder(this)
        qrBox.addView(qrPlaceholder, FrameLayout.LayoutParams(dp(QR_DP), dp(QR_DP), Gravity.CENTER))
        qrView = ImageView(this).apply {
            setBackgroundColor(Color.WHITE)
            visibility = View.GONE
            setPadding(dp(6), dp(6), dp(6), dp(6))
        }
        qrBox.addView(qrView, FrameLayout.LayoutParams(dp(QR_DP), dp(QR_DP), Gravity.CENTER))
        root.addView(qrBox, PairingUi.matchWrap())
        qrCaption = PairingUi.small(this).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(8), 0, dp(16))
        }
        root.addView(qrCaption, PairingUi.matchWrap())

        // Secondary actions.
        actionBlock = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        joinButton = PairingUi.button(this, "") { toggleJoinCard() }
        actionBlock.addView(joinButton, PairingUi.matchWrap())
        actionBlock.addView(PairingUi.spacer(this, 8))
        createButton = PairingUi.button(this, "") { onCreateCluster() }
        actionBlock.addView(createButton, PairingUi.matchWrap())
        root.addView(actionBlock, PairingUi.matchWrap())

        root.addView(buildJoinCard())
        root.addView(buildCreatedCard())
        root.addView(buildPersistCard())

        root.addView(PairingUi.spacer(this, 12))
        laterButton = PairingUi.button(this, "") { setUpLater() }
        root.addView(laterButton, PairingUi.matchWrap())

        frame.addView(
            scroll,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        sosButton = Button(this).apply {
            text = getString(R.string.emergency_button)
            contentDescription = getString(
                R.string.emergency_hold_hint,
                SosHoldTrigger.HOLD_SECONDS.toString(),
            )
            setBackgroundColor(Color.parseColor("#B00020"))
            setTextColor(Color.WHITE)
            textSize = 20f
            minWidth = dp(88)
            minHeight = dp(56)
            isAllCaps = false
            SosHoldTrigger.bind(this, ui, { app.coreOk }) { app.commitEmergency(true) }
        }
        frame.addView(
            sosButton,
            FrameLayout.LayoutParams(dp(104), dp(64), Gravity.BOTTOM or Gravity.END).apply {
                setMargins(dp(16), dp(16), dp(16), dp(16))
            },
        )
        return frame
    }

    private fun toggleJoinCard() {
        val opening = joinCard.visibility != View.VISIBLE
        joinCard.visibility = if (opening) View.VISIBLE else View.GONE
        if (opening) hostField.requestFocus()
    }

    private fun buildJoinCard(): View {
        joinCard = PairingUi.card(this).apply { visibility = View.GONE }
        joinCard.addView(
            PairingUi.heading(this, texts.t("pair.join_with_code", R.string.pair_join_with_code)),
            PairingUi.matchWrap(),
        )
        joinCard.addView(PairingUi.spacer(this, 8))
        hostField = EditText(this).apply {
            setTextColor(PairingUi.TEXT)
            setHintTextColor(PairingUi.FAINT)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setSingleLine(true)
        }
        joinCard.addView(hostField, PairingUi.matchWrap())
        joinCard.addView(
            PairingUi.small(this, texts.t("pair.code_label", R.string.pair_code_label)).apply {
                setPadding(0, dp(12), 0, dp(4))
            },
            PairingUi.matchWrap(),
        )
        pinDisplay = PairingUi.mono(this, "").apply { gravity = Gravity.CENTER }
        joinCard.addView(pinDisplay, PairingUi.matchWrap())
        joinCard.addView(PairingUi.keypad(this) { onPinKey(it) }, PairingUi.matchWrap())
        joinError = PairingUi.body(this).apply {
            setTextColor(PairingUi.ERR)
            visibility = View.GONE
            setPadding(0, dp(8), 0, 0)
        }
        joinCard.addView(joinError, PairingUi.matchWrap())
        joinSubmit = PairingUi.button(this, "", primary = true) { onJoinSubmit() }
        joinSubmit.isEnabled = false
        joinCard.addView(joinSubmit, PairingUi.matchWrap().apply { topMargin = dp(10) })
        renderPin()
        return joinCard
    }

    private fun onPinKey(key: String) {
        joinError.visibility = View.GONE
        when (key) {
            PairingUi.KEY_BACK -> if (pin.isNotEmpty()) pin = pin.dropLast(1)
            PairingUi.KEY_OK -> {
                if (pin.length == PIN_LENGTH) onJoinSubmit()
                return
            }
            else -> if (pin.length < PIN_LENGTH) pin += key
        }
        renderPin()
    }

    private fun renderPin() {
        pinDisplay.text = pin.padEnd(PIN_LENGTH, '–')
        joinSubmit.isEnabled = !joinInFlight && pin.length == PIN_LENGTH
    }

    private fun buildCreatedCard(): View {
        createdCard = PairingUi.card(this).apply { visibility = View.GONE }
        createdTitle = PairingUi.heading(this, "").apply { setTextColor(PairingUi.OK) }
        createdCard.addView(createdTitle, PairingUi.matchWrap())
        createdCard.addView(
            PairingUi.body(this, texts.t("pair.created_next", R.string.pair_created_next)).apply {
                setPadding(0, dp(6), 0, dp(12))
            },
            PairingUi.matchWrap(),
        )
        codeHost = PairingUi.body(this).apply { setTextColor(PairingUi.TEXT) }
        createdCard.addView(codeHost, PairingUi.matchWrap())
        createdCard.addView(
            PairingUi.small(this, texts.t("pair.code_label", R.string.pair_code_label)).apply {
                setPadding(0, dp(10), 0, dp(2))
            },
            PairingUi.matchWrap(),
        )
        codePin = PairingUi.mono(this, "", 40f)
        createdCard.addView(codePin, PairingUi.matchWrap())
        codeCountdown = PairingUi.body(this)
        createdCard.addView(codeCountdown, PairingUi.matchWrap())
        codeAttempts = PairingUi.small(this)
        createdCard.addView(codeAttempts, PairingUi.matchWrap())
        createdCard.addView(
            PairingUi.small(
                this,
                texts.t("pair.code_instructions", R.string.pair_code_instructions),
            ).apply { setPadding(0, dp(10), 0, 0) },
            PairingUi.matchWrap(),
        )
        createdRenew = PairingUi.button(
            this,
            texts.t("pair.code_expired", R.string.pair_code_expired),
            primary = true,
        ) { renewCode() }
        createdRenew.visibility = View.GONE
        createdCard.addView(createdRenew, PairingUi.matchWrap().apply { topMargin = dp(10) })
        return createdCard
    }

    private fun buildPersistCard(): View {
        persistCard = PairingUi.card(this).apply { visibility = View.GONE }
        persistCard.addView(
            PairingUi.heading(
                this,
                texts.t("pair.persist_error_title", R.string.pair_persist_error_title),
            ).apply { setTextColor(PairingUi.ERR) },
            PairingUi.matchWrap(),
        )
        persistCard.addView(
            PairingUi.body(
                this,
                texts.t("pair.persist_error_body", R.string.pair_persist_error_body),
            ).apply {
                setPadding(0, dp(8), 0, dp(12))
            },
            PairingUi.matchWrap(),
        )
        persistCard.addView(
            PairingUi.button(this, texts.t("pair.retry", R.string.pair_retry), primary = true) {
                onRetryPersistence()
            },
            PairingUi.matchWrap(),
        )
        return persistCard
    }

    companion object {
        private const val POLL_MS = 1_000L
        private const val JOINED_DWELL_MS = 2_000L
        private const val PIN_LENGTH = 6
        private const val QR_DP = 260
        private const val QR_PX = 720

        /** Reopen onboarding from the main UI banner or the maintenance menu. */
        fun launch(activity: Activity) {
            activity.startActivity(Intent(activity, PairingActivity::class.java))
        }
    }
}
