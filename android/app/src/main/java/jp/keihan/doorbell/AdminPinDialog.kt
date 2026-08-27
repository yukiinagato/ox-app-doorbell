// 隠し管理入口の PIN ダイアログ (WPF 版 AdminDialog と同仕様)。5 回失敗で 10 分ロック
// (プロセス内)。照合先: filesDir/exit_pin.txt の SHA-256 hex (無ければ既定 PIN "000000" —
// 初回設置手順で必ず変更するよう docs に記載)。
package jp.keihan.doorbell

import android.app.AlertDialog
import android.content.Context
import android.text.InputType
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import java.io.File
import java.security.MessageDigest

object AdminPinDialog {

    private var fails = 0
    private var lockedUntilMs = 0L

    fun show(context: Context, dataDir: File, onUnlocked: () -> Unit) {
        val pad = (16 * context.resources.displayMetrics.density).toInt()
        val box = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad / 2, pad, 0)
        }
        val error = TextView(context).apply { setTextColor(0xFFE05B4C.toInt()) }
        val pin = EditText(context).apply {
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
        }
        box.addView(pin)
        box.addView(error)

        val dlg = AlertDialog.Builder(context)
            .setTitle(context.getString(R.string.admin_pin_prompt))
            .setView(box)
            .setPositiveButton(android.R.string.ok, null)  // 自前処理 (失敗時に閉じない)
            .setNegativeButton(R.string.calling_cancel, null)
            .create()
        dlg.setOnShowListener {
            dlg.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                if (System.currentTimeMillis() < lockedUntilMs) {
                    error.text = context.getString(R.string.admin_locked)
                    return@setOnClickListener
                }
                var expected = sha256Hex("000000")
                try {
                    val f = File(dataDir, "exit_pin.txt")
                    if (f.exists()) expected = f.readText().trim()
                } catch (_: Exception) { }
                if (sha256Hex(pin.text.toString()) == expected) {
                    fails = 0
                    dlg.dismiss()
                    onUnlocked()
                } else if (++fails >= 5) {
                    fails = 0
                    lockedUntilMs = System.currentTimeMillis() + 10 * 60_000L
                    error.text = context.getString(R.string.admin_locked)
                    pin.text.clear()
                } else {
                    error.text = context.getString(R.string.admin_pin_wrong)
                    pin.text.clear()
                }
            }
        }
        dlg.show()
    }

    private fun sha256Hex(s: String): String =
        MessageDigest.getInstance("SHA-256").digest(s.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}
