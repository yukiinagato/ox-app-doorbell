// 隠し管理入口の PIN ダイアログ (WPF 版 AdminDialog と同仕様)。5 回失敗で 10 分ロック
// (プロセス内)。入力は描画テンキーのみ — システム IME は使わない (実体キーボード無しの
// 門口機/TV 前提。ボタンは focusable で D-pad でも操作可)。●伏字表示。
// 照合先: filesDir/exit_pin.txt の SHA-256 hex (無ければ既定 PIN "000000" —
// 初回設置手順で必ず変更するよう docs に記載)。
package jp.keihan.doorbell

import android.app.AlertDialog
import android.content.Context
import android.graphics.Typeface
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import java.io.File
import java.security.MessageDigest

object AdminPinDialog {

    private const val MAX_LEN = 6
    private var fails = 0
    private var lockedUntilMs = 0L

    fun show(context: Context, dataDir: File, onUnlocked: () -> Unit) {
        val dp = context.resources.displayMetrics.density
        fun px(v: Int) = (v * dp).toInt()

        var pin = ""
        val box = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(px(24), px(12), px(24), px(8))
        }
        val display = TextView(context).apply {
            textSize = 30f
            gravity = Gravity.CENTER
            typeface = Typeface.MONOSPACE
            minHeight = px(48)
        }
        val error = TextView(context).apply {
            setTextColor(0xFFE05B4C.toInt())
            gravity = Gravity.CENTER
        }
        box.addView(display)
        box.addView(error)

        val dlg = AlertDialog.Builder(context)
            .setTitle(context.getString(R.string.admin_pin_prompt))
            .setView(box)
            .setNegativeButton(R.string.calling_cancel, null)
            .create()

        fun render() { display.text = "●".repeat(pin.length) }

        fun submit() {
            if (System.currentTimeMillis() < lockedUntilMs) {
                error.text = context.getString(R.string.admin_locked)
                pin = ""; render(); return
            }
            var expected = sha256Hex("000000")
            try {
                val f = File(dataDir, "exit_pin.txt")
                if (f.exists()) expected = f.readText().trim()
            } catch (_: Exception) { }
            if (sha256Hex(pin) == expected) {
                fails = 0
                dlg.dismiss()
                onUnlocked()
                return
            }
            if (++fails >= 5) {
                fails = 0
                lockedUntilMs = System.currentTimeMillis() + 10 * 60_000L
                error.text = context.getString(R.string.admin_locked)
            } else {
                error.text = context.getString(R.string.admin_pin_wrong)
            }
            pin = ""; render()
        }

        fun tap(key: String) {
            error.text = ""
            when (key) {
                "back" -> { if (pin.isNotEmpty()) pin = pin.dropLast(1); render() }
                "ok" -> submit()
                else -> { if (pin.length < MAX_LEN) pin += key; render() }
            }
        }

        // 3x4 描画テンキー (1-9 / ⌫ 0 OK)
        val rows = listOf(listOf("1", "2", "3"), listOf("4", "5", "6"),
                          listOf("7", "8", "9"), listOf("back", "0", "ok"))
        var first: Button? = null
        for (r in rows) {
            val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
            for (key in r) {
                val b = Button(context).apply {
                    text = when (key) { "back" -> "⌫"; "ok" -> "OK"; else -> key }
                    textSize = 22f
                    isFocusable = true  // TV の D-pad 対応
                    isAllCaps = false
                    setOnClickListener { tap(key) }
                }
                val lp = LinearLayout.LayoutParams(0, px(64), 1f)
                lp.setMargins(px(4), px(4), px(4), px(4))
                row.addView(b, lp)
                if (first == null) first = b
            }
            box.addView(row)
        }
        dlg.show()
        first?.requestFocus()
    }

    private fun sha256Hex(s: String): String =
        MessageDigest.getInstance("SHA-256").digest(s.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}
