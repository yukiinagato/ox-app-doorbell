// The 管理パスワード gate in front of every native settings entry (spec §0.2, §3, §5.5).
//
// The device password and the web admin password are one cluster-wide secret. Core verifies it
// through db_core_admin_password_verify; when no password exists yet the gate turns into
// 「管理パスワードを設定」 and sets one through db_core_admin_password_set. The loopback
// administration API stays behind that as the fallback for a core without those exports, and it is
// also what supplies the configuration-write session on such a core.
//
// The legacy local digest in filesDir/exit_pin.txt is deleted the first time core accepts or sets
// a password, and is never consulted once core can answer.
package jp.ox.doorbell

import android.app.Activity
import android.app.AlertDialog
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import java.io.File
import java.security.MessageDigest

/** What the gate handed back: the writer to use, and whether core owns the password now. */
internal data class AdminUnlock(
    val session: AdminSession?,
    val verifiedByCore: Boolean,
)

internal object AdminGate {

    /** Five failures lock entry for ten minutes when core is not tracking attempts itself. */
    private var failures = 0
    private var lockedUntilMs = 0L

    /**
     * Ask for the 管理パスワード, or offer to set one when the cluster has none yet.
     *
     * [onUnlocked] receives a loopback session when one was established, and null when core
     * verified the password directly or when only the legacy local digest matched. Callers pair it
     * with [ConfigWriters.choose] to decide where writes go.
     */
    fun unlock(
        activity: Activity,
        port: Int,
        texts: Texts,
        allowLocalFallback: Boolean = true,
        onUnlocked: (AdminSession?) -> Unit,
    ) {
        val app = activity.application as? App
        val core = app?.core
        val state = if (core != null && app.coreOk)
            AdminPassword.stateOf(core.adminPasswordVerify("")) else AdminPasswordState.UNSUPPORTED
        if (state == AdminPasswordState.UNSET) {
            promptForNewPassword(activity, texts, core) { onUnlocked(null) }
            return
        }
        promptForPassword(activity, port, texts, core, allowLocalFallback, onUnlocked)
    }

    // ---------- entering an existing password ----------

    private fun promptForPassword(
        activity: Activity,
        port: Int,
        texts: Texts,
        core: DoorbellCore?,
        allowLocalFallback: Boolean,
        onUnlocked: (AdminSession?) -> Unit,
    ) {
        val ui = Handler(Looper.getMainLooper())
        val box = column(activity)
        val field = passwordField(activity, texts.t("admin.password", R.string.admin_password))
        val error = errorLabel(activity)
        box.addView(field, ShellUi.matchWrap())
        box.addView(error, ShellUi.matchWrap())

        val dialog = AlertDialog.Builder(activity)
            .setTitle(texts.t("admin.pin_prompt", R.string.admin_pin_prompt))
            .setView(box)
            .setPositiveButton(texts.t("admin.login", R.string.admin_login), null)
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
            .create()

        fun fail(message: String, countsAgainstLockout: Boolean) {
            error.text = message
            error.visibility = View.VISIBLE
            field.setText("")
            if (!countsAgainstLockout) return
            if (++failures >= MAX_FAILURES) {
                failures = 0
                lockedUntilMs = System.currentTimeMillis() + LOCKOUT_MS
                error.text = texts.t("admin.locked", R.string.admin_locked)
            }
        }

        fun submit() {
            if (System.currentTimeMillis() < lockedUntilMs) {
                error.text = texts.t("admin.locked", R.string.admin_locked)
                error.visibility = View.VISIBLE
                return
            }
            val password = field.text.toString()
            if (password.isEmpty()) return
            // Core verification and the loopback login are both blocking; neither runs on the
            // main thread even though the loopback one never leaves the device.
            Thread({
                val state = AdminPassword.stateOf(core?.adminPasswordVerify(password))
                val session = if (state == AdminPasswordState.OK || core == null ||
                    state == AdminPasswordState.UNSUPPORTED
                ) AdminSession.open(port, password) else null to ""
                ui.post {
                    if (activity.isFinishing) return@post
                    when {
                        state == AdminPasswordState.OK -> {
                            failures = 0
                            retireLocalDigest(activity)
                            dialog.dismiss()
                            onUnlocked(session?.first)
                        }
                        state == AdminPasswordState.WRONG ->
                            fail(texts.t("admin.pin_wrong", R.string.admin_pin_wrong), true)
                        state == AdminPasswordState.LOCKED ->
                            fail(texts.t("admin.locked", R.string.admin_locked), false)
                        // Core cannot answer: the loopback login is the fallback, and it also
                        // initialises the password on a cluster that has never had one.
                        session?.first != null -> {
                            failures = 0
                            dialog.dismiss()
                            onUnlocked(session.first)
                        }
                        session?.second == AdminSession.ERR_PASSWORD ->
                            fail(texts.t("admin.pin_wrong", R.string.admin_pin_wrong), true)
                        allowLocalFallback && matchesLocalDigest(activity.filesDir, password) -> {
                            failures = 0
                            dialog.dismiss()
                            onUnlocked(null)
                        }
                        else -> fail(texts.t("settings.offline", R.string.settings_offline), false)
                    }
                }
            }, "doorbell-admin-login").apply { isDaemon = true }.start()
        }

        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { submit() }
        }
        dialog.show()
        field.requestFocus()
    }

    // ---------- setting the first password ----------

    /**
     * No cluster password exists yet, so the gate asks for a new one instead of refusing entry.
     * The same secret then works on the web admin.
     */
    private fun promptForNewPassword(
        activity: Activity,
        texts: Texts,
        core: DoorbellCore?,
        onDone: () -> Unit,
    ) {
        val ui = Handler(Looper.getMainLooper())
        val box = column(activity)
        box.addView(
            ShellUi.text(
                activity,
                texts.t("settings.set_password_hint", R.string.settings_set_password_hint),
                13f, Palette.LIGHT.muted,
            ),
            ShellUi.matchWrap(),
        )
        val first = passwordField(
            activity, texts.t("settings.password_new", R.string.settings_password_new),
        )
        val second = passwordField(
            activity, texts.t("settings.password_confirm", R.string.settings_password_confirm),
        )
        val error = errorLabel(activity)
        box.addView(first, ShellUi.matchWrap())
        box.addView(second, ShellUi.matchWrap())
        box.addView(error, ShellUi.matchWrap())

        val dialog = AlertDialog.Builder(activity)
            .setTitle(texts.t("settings.set_password", R.string.settings_set_password))
            .setView(box)
            .setPositiveButton(texts.t("admin.save", R.string.admin_save), null)
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
            .create()

        fun submit() {
            val value = first.text.toString()
            val repeat = second.text.toString()
            if (!AdminPassword.newPasswordValid(value)) {
                error.text = texts.t("settings.password_empty", R.string.settings_password_empty)
                error.visibility = View.VISIBLE
                return
            }
            if (value != repeat) {
                error.text =
                    texts.t("settings.password_mismatch", R.string.settings_password_mismatch)
                error.visibility = View.VISIBLE
                return
            }
            Thread({
                val result = core?.adminPasswordSet("", value)
                ui.post {
                    if (activity.isFinishing) return@post
                    if (result == 0) {
                        retireLocalDigest(activity)
                        dialog.dismiss()
                        onDone()
                    } else {
                        error.text = texts.t(
                            "settings.password_set_failed", R.string.settings_password_set_failed,
                        )
                        error.visibility = View.VISIBLE
                    }
                }
            }, "doorbell-admin-password-set").apply { isDaemon = true }.start()
        }

        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { submit() }
        }
        dialog.show()
        first.requestFocus()
    }

    // ---------- the legacy local digest ----------

    /**
     * Delete filesDir/exit_pin.txt once core has accepted or set a cluster password. The local
     * digest defaulted to a well-known value on an unprovisioned device, so it is removed rather
     * than kept as a second way in.
     */
    internal fun retireLocalDigest(activity: Activity) {
        val file = File(activity.filesDir, LEGACY_PIN_FILE)
        if (!file.exists()) return
        if (!file.delete()) file.deleteOnExit()
    }

    /**
     * The pre-existing local maintenance digest. Consulted only when core cannot verify and the
     * loopback administration API is unreachable, and never after core has answered once.
     */
    internal fun matchesLocalDigest(dataDir: File, value: String): Boolean {
        val file = File(dataDir, LEGACY_PIN_FILE)
        // A device whose digest has been retired has no local escape hatch by design.
        if (!file.exists()) return false
        val expected = try { file.readText().trim() } catch (_: Exception) { return false }
        return expected.isNotEmpty() && sha256Hex(value) == expected
    }

    private fun sha256Hex(value: String): String =
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    // ---------- shared views ----------

    private fun column(activity: Activity): LinearLayout {
        val pad = ShellUi.dp(activity, 20)
        return LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, ShellUi.dp(activity, 12), pad, ShellUi.dp(activity, 8))
        }
    }

    private fun passwordField(activity: Activity, label: String): EditText = EditText(activity).apply {
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        isFocusable = true
        isFocusableInTouchMode = true
        minHeight = ShellUi.dp(activity, ShellUi.TOUCH_FLOOR_DP)
        hint = label
    }

    private fun errorLabel(activity: Activity): TextView = TextView(activity).apply {
        setTextColor(ShellUi.opaque(Palette.LIGHT.danger))
        gravity = Gravity.START
        textSize = 13f
        visibility = View.GONE
    }

    internal const val LEGACY_PIN_FILE = "exit_pin.txt"
    private const val MAX_FAILURES = 5
    private const val LOCKOUT_MS = 10 * 60_000L
}
