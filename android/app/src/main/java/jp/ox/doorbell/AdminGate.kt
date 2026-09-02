// The 管理パスワード gate in front of every native settings entry (spec §0.2, §3).
//
// The prompt authenticates against this node's own administration API, so a successful entry both
// proves the operator is an administrator and yields the session the settings screen writes
// configuration with. When the API cannot be reached the caller still gets a locally verified
// unlock so maintenance actions that need no configuration write (kiosk exit, diagnostics) keep
// working, and the settings screen then presents itself as read-only.
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

internal object AdminGate {

    /** Five failures lock entry for ten minutes, matching the existing maintenance dialog. */
    private var failures = 0
    private var lockedUntilMs = 0L

    /**
     * Ask for the 管理パスワード and hand back an authenticated session.
     *
     * [onUnlocked] receives null when the node's administration API is unreachable but the
     * operator proved themselves against the locally stored digest.
     */
    fun unlock(
        activity: Activity,
        port: Int,
        texts: Texts,
        allowLocalFallback: Boolean = true,
        onUnlocked: (AdminSession?) -> Unit,
    ) {
        val ui = Handler(Looper.getMainLooper())
        val pad = ShellUi.dp(activity, 20)
        val box = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, ShellUi.dp(activity, 12), pad, ShellUi.dp(activity, 8))
        }
        val field = EditText(activity).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            isFocusable = true
            isFocusableInTouchMode = true
            minHeight = ShellUi.dp(activity, ShellUi.TOUCH_FLOOR_DP)
            hint = texts.t("admin.password", R.string.admin_password)
        }
        val error = TextView(activity).apply {
            setTextColor(ShellUi.opaque(Palette.LIGHT.danger))
            gravity = Gravity.START
            textSize = 13f
            visibility = View.GONE
        }
        box.addView(field, ShellUi.matchWrap())
        box.addView(error, ShellUi.matchWrap())

        val dialog = AlertDialog.Builder(activity)
            .setTitle(texts.t("admin.pin_prompt", R.string.admin_pin_prompt))
            .setView(box)
            .setPositiveButton(texts.t("admin.login", R.string.admin_login), null)
            .setNegativeButton(texts.t("admin.cancel", R.string.admin_cancel), null)
            .create()

        fun fail(message: String) {
            error.text = message
            error.visibility = View.VISIBLE
            field.setText("")
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
            // Network I/O never runs on the main thread, even against loopback.
            Thread({
                val (session, reason) = AdminSession.open(port, password)
                ui.post {
                    if (activity.isFinishing) return@post
                    when {
                        session != null -> {
                            failures = 0
                            dialog.dismiss()
                            onUnlocked(session)
                        }
                        reason == AdminSession.ERR_PASSWORD ->
                            fail(texts.t("admin.pin_wrong", R.string.admin_pin_wrong))
                        allowLocalFallback && matchesLocalDigest(activity.filesDir, password) -> {
                            failures = 0
                            dialog.dismiss()
                            onUnlocked(null)
                        }
                        else -> fail(texts.t("settings.offline", R.string.settings_offline))
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

    /**
     * The pre-existing local maintenance digest in filesDir/exit_pin.txt. It is only consulted
     * when the administration API is unreachable, and never grants configuration writes.
     */
    internal fun matchesLocalDigest(dataDir: File, value: String): Boolean {
        var expected = sha256Hex("000000")
        try {
            val file = File(dataDir, "exit_pin.txt")
            if (file.exists()) expected = file.readText().trim()
        } catch (_: Exception) { }
        return sha256Hex(value) == expected
    }

    private fun sha256Hex(value: String): String =
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    private const val MAX_FAILURES = 5
    private const val LOCKOUT_MS = 10 * 60_000L
}
