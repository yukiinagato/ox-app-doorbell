// "Add device" panel for a cluster member (spec 5.1): nearby devices, a Pairing PIN card,
// the bulk-add window, this device's own Add QR, and the QR scanner entry point.
//
// Every result is rendered inline on the row or card that produced it; there is no toast-only
// success or failure, and no raw error code is ever the primary message.
package jp.ox.doorbell

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject

class AddDeviceActivity : Activity(), DoorbellCore.Listener {

    private lateinit var app: App
    private lateinit var texts: Texts
    private val ui = Handler(Looper.getMainLooper())

    private lateinit var membershipView: TextView
    private lateinit var connectedView: TextView
    private lateinit var founderBadge: TextView

    private lateinit var nearbyList: LinearLayout
    private lateinit var nearbyEmpty: TextView
    private lateinit var nearbySpinner: ProgressBar

    private lateinit var codeButton: Button
    private lateinit var codeCard: LinearLayout
    private lateinit var codeHost: TextView
    private lateinit var codePin: TextView
    private lateinit var codeCountdown: TextView
    private lateinit var codeAttempts: TextView
    private lateinit var codeRenew: Button
    private lateinit var codeError: TextView

    private lateinit var bulkButton: Button
    private lateinit var bulkStatus: TextView
    private lateinit var bulkStop: Button

    private lateinit var scanButton: Button
    private lateinit var qrView: ImageView
    private lateinit var qrPlaceholder: TextView

    private var lastQr = ""
    private var codeCardOpen = false
    private var mintInFlight = false

    private class Row(
        val container: LinearLayout,
        val name: TextView,
        val detail: TextView,
        val status: TextView,
        val add: Button,
        val deny: Button,
    )

    private val rows = LinkedHashMap<String, Row>()

    /** Per-device UI overlay: adding / added / failed with its human message. */
    private class RowState(var phase: String, var message: String = "", var atMs: Long = 0L)

    private val rowStates = HashMap<String, RowState>()
    private val joinedNames = LinkedHashMap<String, String>()

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
        // An unpaired node cannot add anything, so it goes to onboarding instead (spec 5.1.6).
        if (!app.pairingReady()) {
            PairingActivity.launch(this)
            finish()
            return
        }
        setContentView(buildUi())
        refresh()
    }

    override fun onResume() {
        super.onResume()
        app.bindForeground(this)
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

    // ---------- Core events ----------

    override fun onUiEvent(ev: JSONObject) {
        ui.post { handleEvent(ev) }
    }

    override fun onTts(text: String, lang: String) {}

    private fun handleEvent(ev: JSONObject) {
        when (ev.optString("t")) {
            "invite_result" -> {
                val id = ev.optString("id")
                if (id.isNotEmpty()) {
                    if (ev.optBoolean("ok")) {
                        // Positive confirmation only arrives with device_joined.
                        rowStates[id] = RowState(PHASE_ADDING)
                    } else {
                        rowStates[id] = RowState(
                            PHASE_FAILED,
                            errorText(ev.optString("err")),
                            SystemClock.elapsedRealtime(),
                        )
                    }
                }
                refresh()
            }
            "device_joined" -> {
                val id = ev.optString("id")
                if (id.isNotEmpty()) {
                    rowStates[id] = RowState(PHASE_ADDED, "", SystemClock.elapsedRealtime())
                    joinedNames[id] = ev.optString("name").ifEmpty { id }
                }
                refresh()
            }
            "qr_scanned" -> refresh()
            "pending_changed", "pairing_mode_changed", "join_token_changed",
            "pairing_state", "peers_changed" -> refresh()
            "config_changed" -> {
                texts.setConfig(app.core.config())
                refresh()
            }
        }
    }

    private fun errorText(code: String): String {
        val message = texts.t(PairingModel.errorKey(code), PairingModel.errorResource(code))
        if (code.isEmpty()) return message
        return message + " · " + texts.t("pair.err_detail", R.string.pair_err_detail, code)
    }

    // ---------- rendering ----------

    private fun refresh() {
        val p = if (app.coreOk) app.core.pairingInfo() else null
        renderMembership(p)
        renderNearby(p)
        renderCode(p)
        renderBulk(p)
        renderQr(p)
    }

    private fun renderMembership(p: JSONObject?) {
        membershipView.text = texts.t(
            "pair.membership", R.string.pair_membership,
            PairingModel.memberCount(p).toString(),
        )
        connectedView.text = texts.t(
            "pair.membership_connected", R.string.pair_membership_connected,
            PairingModel.connectedCount(p).toString(),
        )
        founderBadge.visibility = if (PairingModel.isFounder(p)) View.VISIBLE else View.GONE
    }

    private fun renderNearby(p: JSONObject?) {
        val pending = PairingModel.pending(p)
        val now = SystemClock.elapsedRealtime()
        // Drop finished overlays once their dwell time is up.
        val expired = rowStates.filter { (_, s) ->
            (s.phase == PHASE_ADDED || s.phase == PHASE_FAILED) &&
                s.atMs != 0L && now - s.atMs > OVERLAY_DWELL_MS
        }.keys
        for (id in expired) {
            rowStates.remove(id)
            joinedNames.remove(id)
        }

        val visible = LinkedHashMap<String, PairingModel.PendingDevice>()
        for (d in pending) visible[d.id] = d
        // A device that just joined has already left pending; keep the confirmation on screen.
        for ((id, name) in joinedNames) {
            if (!visible.containsKey(id)) {
                visible[id] = PairingModel.PendingDevice(
                    id = id, addr = "", name = name, role = "", model = "", platform = "",
                    sw = "", ageSeconds = 0, inviteState = "joined", attempts = 0, lastError = "",
                )
            }
        }

        for (id in rows.keys.toList()) {
            if (!visible.containsKey(id)) {
                nearbyList.removeView(rows.remove(id)?.container)
            }
        }
        for ((id, device) in visible) {
            val row = rows.getOrPut(id) { addRow(id) }
            bindRow(row, device)
        }
        val empty = visible.isEmpty()
        nearbyEmpty.visibility = if (empty) View.VISIBLE else View.GONE
        nearbySpinner.visibility = if (empty) View.VISIBLE else View.GONE
        nearbyList.visibility = if (empty) View.GONE else View.VISIBLE
    }

    private fun addRow(id: String): Row {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(10), 0, dp(10))
        }
        val name = PairingUi.body(this).apply {
            setTextColor(PairingUi.TEXT)
            textSize = 16f
        }
        val detail = PairingUi.small(this)
        val status = PairingUi.small(this).apply { visibility = View.GONE }
        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(6), 0, 0)
        }
        val add = PairingUi.chip(this, texts.t("pair.add", R.string.pair_add)) { onAdd(id) }
        val deny = PairingUi.chip(
            this,
            texts.t("pair.deny", R.string.pair_deny),
            primary = false,
        ) { onDeny(id) }
        actions.addView(add, LinearLayout.LayoutParams(0, dp(48), 1f).apply {
            rightMargin = dp(8)
        })
        actions.addView(deny, LinearLayout.LayoutParams(0, dp(48), 1f))
        container.addView(name, PairingUi.matchWrap())
        container.addView(detail, PairingUi.matchWrap())
        container.addView(status, PairingUi.matchWrap())
        container.addView(actions, PairingUi.matchWrap())
        nearbyList.addView(container, PairingUi.matchWrap())
        return Row(container, name, detail, status, add, deny)
    }

    private fun bindRow(row: Row, device: PairingModel.PendingDevice) {
        row.name.text = device.displayName()
        val detail = listOf(
            device.detail(),
            if (device.ageSeconds > 0) texts.t(
                "pair.nearby_waiting_since", R.string.pair_nearby_waiting_since,
                device.ageSeconds.toString(),
            ) else "",
        ).filter { it.isNotEmpty() }.joinToString(" · ")
        row.detail.text = detail
        val state = rowStates[device.id]
        when (state?.phase) {
            PHASE_ADDING -> {
                row.status.visibility = View.VISIBLE
                row.status.setTextColor(PairingUi.DIM)
                row.status.text = texts.t("pair.adding", R.string.pair_adding)
                row.add.isEnabled = false
                row.deny.isEnabled = false
            }
            PHASE_ADDED -> {
                row.status.visibility = View.VISIBLE
                row.status.setTextColor(PairingUi.OK)
                row.status.text = "✓ " + texts.t("pair.added", R.string.pair_added)
                row.add.visibility = View.GONE
                row.deny.visibility = View.GONE
            }
            PHASE_FAILED -> {
                row.status.visibility = View.VISIBLE
                row.status.setTextColor(PairingUi.ERR)
                row.status.text = texts.t("pair.add_failed", R.string.pair_add_failed) + "\n" +
                    state.message
                row.add.isEnabled = true
                row.deny.isEnabled = true
                row.add.visibility = View.VISIBLE
                row.deny.visibility = View.VISIBLE
            }
            else -> {
                // Core may already report an invitation this shell did not start.
                if (device.inviteState == "sent" || device.inviteState == "acked") {
                    row.status.visibility = View.VISIBLE
                    row.status.setTextColor(PairingUi.DIM)
                    row.status.text = texts.t("pair.adding", R.string.pair_adding)
                    row.add.isEnabled = false
                } else {
                    row.status.visibility = View.GONE
                    row.add.isEnabled = true
                }
                row.deny.isEnabled = true
                row.add.visibility = View.VISIBLE
                row.deny.visibility = View.VISIBLE
            }
        }
    }

    private fun onAdd(id: String) {
        rowStates[id] = RowState(PHASE_ADDING)
        app.core.inviteDevice(id)
        refresh()
    }

    private fun onDeny(id: String) {
        AlertDialog.Builder(this)
            .setMessage(texts.t("pair.deny", R.string.pair_deny))
            .setPositiveButton(texts.t("pair.deny", R.string.pair_deny)) { _, _ ->
                app.core.denyDevice(id)
                rowStates.remove(id)
                joinedNames.remove(id)
                refresh()
            }
            .setNegativeButton(texts.t("calling.cancel", R.string.calling_cancel), null)
            .show()
    }

    // ---------- Pairing PIN card ----------

    private fun renderCode(p: JSONObject?) {
        val token = PairingModel.token(p)
        if (token.active) codeCardOpen = true
        codeCard.visibility = if (codeCardOpen) View.VISIBLE else View.GONE
        if (!codeCardOpen) return
        codeHost.text = token.host.ifEmpty {
            p?.optJSONObject("self")?.optString("addr").orEmpty()
        }
        if (token.active) {
            codePin.text = token.pin
            codeCountdown.setTextColor(PairingUi.DIM)
            codeCountdown.text = texts.t(
                "pair.code_expires_in", R.string.pair_code_expires_in,
                PairingModel.minutes(token.expiresSeconds),
                PairingModel.seconds(token.expiresSeconds),
            )
            codeAttempts.visibility = View.VISIBLE
            codeAttempts.text = texts.t(
                "pair.code_attempts_left", R.string.pair_code_attempts_left,
                token.attemptsLeft.toString(),
            )
            codeRenew.visibility = View.GONE
        } else {
            codePin.text = "——————"
            codeCountdown.setTextColor(PairingUi.WARN)
            codeCountdown.text = texts.t("pair.code_expired", R.string.pair_code_expired)
            codeAttempts.visibility = View.GONE
            codeRenew.visibility = View.VISIBLE
        }
    }

    /**
     * The PIN card mints a code and nothing else. Core's PIN-only entry point leaves pairing mode
     * closed; on an older core the combined call is used and the window is closed again at once,
     * unless the operator already opened 「まとめて追加」 themselves.
     */
    private fun mintCode() {
        if (mintInFlight) return
        mintInFlight = true
        codeError.visibility = View.GONE
        codeCardOpen = true
        codeCard.visibility = View.VISIBLE
        Thread {
            val result = JoinTokenMinting.mint(app.core, PairingModel.PAIRING_WINDOW_S)
            ui.post {
                mintInFlight = false
                if (result == null || !result.optBoolean("ok")) {
                    codeError.visibility = View.VISIBLE
                    codeError.text = errorText(result?.optString("err").orEmpty())
                }
                refresh()
            }
        }.apply { name = "doorbell-mint-pin" }.start()
    }

    // ---------- bulk add ----------

    private var bulkRequestedAtMs = 0L

    /** True while the operator's own bulk-add window is the one that is open. */
    private fun bulkOwnedByUser(): Boolean = bulkRequestedAtMs != 0L &&
        SystemClock.elapsedRealtime() - bulkRequestedAtMs <
            PairingModel.PAIRING_WINDOW_S * 1_000L

    private fun renderBulk(p: JSONObject?) {
        val bulk = PairingModel.bulkAdd(p)
        if (bulk.active) {
            bulkButton.visibility = View.GONE
            bulkStatus.visibility = View.VISIBLE
            bulkStop.visibility = View.VISIBLE
            bulkStatus.text = texts.t(
                "pair.add_all_on", R.string.pair_add_all_on,
                PairingModel.minutes(bulk.leftSeconds), PairingModel.seconds(bulk.leftSeconds),
                bulk.addedCount.toString(),
            )
        } else {
            bulkButton.visibility = View.VISIBLE
            bulkStop.visibility = View.GONE
            // The window closing is itself information, so the last count stays visible.
            bulkStatus.visibility = if (bulk.addedCount > 0) View.VISIBLE else View.GONE
            if (bulk.addedCount > 0) {
                bulkStatus.text = texts.t(
                    "pair.add_all_on", R.string.pair_add_all_on, "0", "00",
                    bulk.addedCount.toString(),
                )
            }
        }
    }

    private fun onBulkAdd() {
        AlertDialog.Builder(this)
            .setTitle(texts.t("pair.add_all", R.string.pair_add_all))
            .setMessage(texts.t("pair.add_all_warning", R.string.pair_add_all_warning))
            .setPositiveButton(texts.t("pair.add_all", R.string.pair_add_all)) { _, _ ->
                bulkRequestedAtMs = SystemClock.elapsedRealtime()
                app.core.setPairingMode(PairingModel.PAIRING_WINDOW_S)
                refresh()
            }
            .setNegativeButton(texts.t("calling.cancel", R.string.calling_cancel), null)
            .show()
    }

    private fun onBulkStop() {
        bulkRequestedAtMs = 0L
        app.core.setPairingMode(0)
        refresh()
    }

    // ---------- own QR and scanner ----------

    private fun renderQr(p: JSONObject?) {
        val qr = p?.optString("pair_qr").orEmpty()
        if (qr.isEmpty() || qr == lastQr) return
        val bmp = PairingUi.qrBitmap(app.core, qr, QR_PX) ?: return
        lastQr = qr
        qrView.setImageBitmap(bmp)
        qrView.visibility = View.VISIBLE
        qrPlaceholder.visibility = View.GONE
    }

    private fun onUnpair() {
        AlertDialog.Builder(this)
            .setTitle(texts.t("pair.clear_title", R.string.pair_clear_title))
            .setMessage(texts.t("pair.clear_confirm", R.string.pair_clear_confirm))
            .setPositiveButton(texts.t("pair.clear_title", R.string.pair_clear_title)) { _, _ ->
                confirmUnpair()
            }
            .setNegativeButton(texts.t("calling.cancel", R.string.calling_cancel), null)
            .show()
    }

    /** Second step of the two-step confirmation; the shell state is cleared by App. */
    private fun confirmUnpair() {
        AlertDialog.Builder(this)
            .setMessage(texts.t("pair.clear_confirm", R.string.pair_clear_confirm))
            .setPositiveButton(texts.t("pair.clear_title", R.string.pair_clear_title)) { _, _ ->
                app.core.unpair()
                app.onClusterLeft()
                PairingActivity.launch(this)
                finish()
            }
            .setNegativeButton(texts.t("calling.cancel", R.string.calling_cancel), null)
            .show()
    }

    private fun copyToClipboard(label: String, value: String) {
        if (value.isEmpty()) return
        try {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText(label, value))
        } catch (_: Exception) { /* A kiosk image may have no clipboard service. */ }
    }

    // ---------- view construction ----------

    private fun dp(v: Int) = PairingUi.dp(this, v)

    private fun buildUi(): View {
        val scroll = ScrollView(this).apply { setBackgroundColor(PairingUi.BG) }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(24), dp(20), dp(32))
        }
        scroll.addView(
            root,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        root.addView(
            PairingUi.title(this, texts.t("admin.menu_add_device", R.string.admin_menu_add_device)),
            PairingUi.matchWrap(),
        )
        membershipView = PairingUi.body(this).apply {
            setTextColor(PairingUi.TEXT)
            setPadding(0, dp(8), 0, 0)
        }
        root.addView(membershipView, PairingUi.matchWrap())
        connectedView = PairingUi.small(this)
        root.addView(connectedView, PairingUi.matchWrap())
        founderBadge = PairingUi.small(
            this,
            texts.t("pair.created_badge", R.string.pair_created_badge),
        ).apply {
            setTextColor(PairingUi.ACCENT)
            visibility = View.GONE
        }
        root.addView(founderBadge, PairingUi.matchWrap())

        root.addView(PairingUi.spacer(this, 16))
        root.addView(buildNearbyCard(), PairingUi.matchWrap())
        root.addView(PairingUi.spacer(this, 12))
        root.addView(buildCodeSection(), PairingUi.matchWrap())
        root.addView(PairingUi.spacer(this, 12))
        root.addView(buildBulkSection(), PairingUi.matchWrap())
        root.addView(PairingUi.spacer(this, 12))
        root.addView(buildQrCard(), PairingUi.matchWrap())
        root.addView(PairingUi.spacer(this, 12))
        root.addView(
            PairingUi.button(this, texts.t("pair.clear_title", R.string.pair_clear_title)) {
                onUnpair()
            },
            PairingUi.matchWrap(),
        )
        root.addView(PairingUi.spacer(this, 8))
        root.addView(
            PairingUi.button(this, texts.t("admin.menu_close", R.string.admin_menu_close)) {
                finish()
            },
            PairingUi.matchWrap(),
        )
        return scroll
    }

    private fun buildNearbyCard(): View {
        val card = PairingUi.card(this)
        card.addView(
            PairingUi.heading(this, texts.t("pair.nearby_title", R.string.pair_nearby_title)),
            PairingUi.matchWrap(),
        )
        val emptyRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(10), 0, 0)
        }
        nearbySpinner = ProgressBar(this).apply { isIndeterminate = true }
        emptyRow.addView(nearbySpinner, LinearLayout.LayoutParams(dp(20), dp(20)).apply {
            rightMargin = dp(10)
        })
        nearbyEmpty = PairingUi.body(
            this,
            texts.t("pair.nearby_none", R.string.pair_nearby_none),
        )
        emptyRow.addView(nearbyEmpty, PairingUi.matchWrap())
        card.addView(emptyRow, PairingUi.matchWrap())
        nearbyList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        card.addView(nearbyList, PairingUi.matchWrap())
        return card
    }

    private fun buildCodeSection(): View {
        val holder = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        codeButton = PairingUi.button(
            this,
            texts.t("pair.add_with_code", R.string.pair_add_with_code),
        ) { mintCode() }
        holder.addView(codeButton, PairingUi.matchWrap())

        codeCard = PairingUi.card(this).apply {
            visibility = View.GONE
            layoutParams = PairingUi.matchWrap().apply { topMargin = dp(8) }
        }
        codeCard.addView(
            PairingUi.small(this, texts.t("pair.address_label", R.string.pair_address_label)),
            PairingUi.matchWrap(),
        )
        codeHost = PairingUi.mono(this, "", 20f)
        codeCard.addView(codeHost, PairingUi.matchWrap())
        codeCard.addView(
            PairingUi.button(this, texts.t("pair.copy", R.string.pair_copy)) {
                copyToClipboard("address", codeHost.text.toString())
            },
            PairingUi.matchWrap().apply { topMargin = dp(6) },
        )
        codeCard.addView(
            PairingUi.small(this, texts.t("pair.code_label", R.string.pair_code_label)).apply {
                setPadding(0, dp(14), 0, dp(2))
            },
            PairingUi.matchWrap(),
        )
        codePin = PairingUi.mono(this, "", 42f)
        codeCard.addView(codePin, PairingUi.matchWrap())
        codeCard.addView(
            PairingUi.button(this, texts.t("pair.copy", R.string.pair_copy)) {
                copyToClipboard("pin", codePin.text.toString())
            },
            PairingUi.matchWrap().apply { topMargin = dp(6) },
        )
        codeCountdown = PairingUi.body(this).apply { setPadding(0, dp(8), 0, 0) }
        codeCard.addView(codeCountdown, PairingUi.matchWrap())
        codeAttempts = PairingUi.small(this)
        codeCard.addView(codeAttempts, PairingUi.matchWrap())
        codeCard.addView(
            PairingUi.small(
                this,
                texts.t("pair.code_instructions", R.string.pair_code_instructions),
            ).apply { setPadding(0, dp(10), 0, 0) },
            PairingUi.matchWrap(),
        )
        codeError = PairingUi.body(this).apply {
            setTextColor(PairingUi.ERR)
            visibility = View.GONE
            setPadding(0, dp(8), 0, 0)
        }
        codeCard.addView(codeError, PairingUi.matchWrap())
        codeRenew = PairingUi.button(
            this,
            texts.t("pair.code_expired", R.string.pair_code_expired),
            primary = true,
        ) { mintCode() }
        codeRenew.visibility = View.GONE
        codeCard.addView(codeRenew, PairingUi.matchWrap().apply { topMargin = dp(10) })
        holder.addView(codeCard)
        return holder
    }

    private fun buildBulkSection(): View {
        val holder = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        holder.addView(
            PairingUi.small(this, texts.t("pair.add_all_warning", R.string.pair_add_all_warning)),
            PairingUi.matchWrap(),
        )
        bulkButton = PairingUi.button(this, texts.t("pair.add_all", R.string.pair_add_all)) {
            onBulkAdd()
        }
        holder.addView(bulkButton, PairingUi.matchWrap().apply { topMargin = dp(6) })
        bulkStatus = PairingUi.body(this).apply {
            setTextColor(PairingUi.WARN)
            visibility = View.GONE
            setPadding(0, dp(8), 0, 0)
        }
        holder.addView(bulkStatus, PairingUi.matchWrap())
        bulkStop = PairingUi.button(
            this,
            texts.t("pair.add_all_stop", R.string.pair_add_all_stop),
            primary = true,
        ) { onBulkStop() }
        bulkStop.visibility = View.GONE
        holder.addView(bulkStop, PairingUi.matchWrap().apply { topMargin = dp(6) })
        return holder
    }

    private fun buildQrCard(): View {
        val card = PairingUi.card(this)
        scanButton = PairingUi.button(this, texts.t("pair.scan_qr", R.string.pair_scan_qr)) {
            startActivity(Intent(this, QrScanActivity::class.java))
        }
        // A device with no camera can only display its own QR (spec 5.1.4).
        scanButton.visibility = if (app.runtime.hasCamera()) View.VISIBLE else View.GONE
        card.addView(scanButton, PairingUi.matchWrap())
        card.addView(
            PairingUi.small(this, texts.t("pair.qr_caption", R.string.pair_qr_caption)).apply {
                gravity = Gravity.CENTER
                setPadding(0, dp(14), 0, dp(8))
            },
            PairingUi.matchWrap(),
        )
        val box = android.widget.FrameLayout(this)
        qrPlaceholder = PairingUi.qrPlaceholder(this).apply {
            text = texts.t("pair.searching", R.string.pair_searching)
        }
        box.addView(
            qrPlaceholder,
            android.widget.FrameLayout.LayoutParams(dp(QR_DP), dp(QR_DP), Gravity.CENTER),
        )
        qrView = ImageView(this).apply {
            setBackgroundColor(Color.WHITE)
            visibility = View.GONE
            setPadding(dp(6), dp(6), dp(6), dp(6))
        }
        box.addView(
            qrView,
            android.widget.FrameLayout.LayoutParams(dp(QR_DP), dp(QR_DP), Gravity.CENTER),
        )
        card.addView(box, PairingUi.matchWrap())
        return card
    }

    companion object {
        private const val POLL_MS = 1_000L
        private const val OVERLAY_DWELL_MS = 6_000L
        private const val QR_DP = 200
        private const val QR_PX = 560
        private const val PHASE_ADDING = "adding"
        private const val PHASE_ADDED = "added"
        private const val PHASE_FAILED = "failed"

        fun launch(activity: Activity) {
            activity.startActivity(Intent(activity, AddDeviceActivity::class.java))
        }
    }
}
