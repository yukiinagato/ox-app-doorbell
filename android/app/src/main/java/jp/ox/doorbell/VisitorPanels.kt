// The door station's visitor-facing parts that MainActivity used to build inline: the purpose
// grid, the language switch, and the speech used for quick replies (docs/en/ui-guidelines.md,
// "Visitor"). MainActivity keeps the call flow; these components only render and report taps.
package jp.ox.doorbell

import android.app.Activity
import android.speech.tts.TextToSpeech
import android.os.Build
import android.view.Gravity
import android.view.ViewGroup
import android.widget.GridLayout
import android.widget.LinearLayout
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/** Purpose cards in a grid: 2 columns compact, 3 medium, 4 expanded, one fewer at large text. */
internal class VisitorPurposePanel(
    private val activity: Activity,
    private val grid: GridLayout,
    private val onPurpose: (id: String, label: String) -> Unit,
) {
    fun build(config: JSONObject?, lang: String, roles: UiRoles) {
        grid.removeAllViews()
        val ids = VisitPurposes.enabled(config)
        if (ids.isEmpty()) {
            grid.columnCount = 1
            return
        }
        val window = UiKit.window(activity)
        val columns = minOf(ScreenLayouts.purposeColumns(window), ids.size)
        grid.columnCount = columns
        val gap = ShellUi.dp(activity, UiTokens.SPACE_S)
        // The cells share what is inside the grid's own padding, or they run past its edge.
        val available = (grid.width - grid.paddingLeft - grid.paddingRight).takeIf { it > 0 }
            ?: (activity.resources.displayMetrics.widthPixels - ShellUi.dp(activity, UiTokens.SPACE_XXXL))
        val cellWidth = (available - gap * columns) / columns
        for ((index, id) in ids.withIndex()) {
            val label = VisitPurposes.label(config, id, lang)
            val card = PlatformUi.button(activity, ButtonKind.TONAL).apply {
                text = VisitPurposes.decoratedLabel(config, id, lang)
                @Suppress("DEPRECATION")
                setTextAppearance(activity, R.style.TextAppearance_Doorbell_Title)
                setSingleLine(false)
                maxLines = 4
                isFocusable = true
                UiKit.styleAction(this, roles, ActionRole.SECONDARY,
                                  UiTokens.VISITOR_TOUCH_MIN_DP, emphasis = true)
                setOnClickListener { onPurpose(id, label) }
            }
            val params = GridLayout.LayoutParams().apply {
                rowSpec = GridLayout.spec(index / columns)
                columnSpec = GridLayout.spec(index % columns)
                width = cellWidth
                height = ViewGroup.LayoutParams.WRAP_CONTENT
                setMargins(gap / 2, gap / 2, gap / 2, gap / 2)
            }
            grid.addView(card, params)
        }
    }
}

/** Text-labelled language switch as the platform's segmented control; no flags. */
internal class VisitorLanguageBar(
    private val activity: Activity,
    private val bar: LinearLayout,
    private val onPick: (String) -> Unit,
) {
    private var control: SegmentedHandle? = null

    /** Returns false when there is nothing to switch (one language, or not a door station). */
    fun build(config: JSONObject?, @Suppress("UNUSED_PARAMETER") roles: UiRoles, enabled: Boolean): Boolean {
        bar.removeAllViews()
        control = null
        val languages = languages(config)
        if (!enabled || languages.size < 2) return false
        val segmented = PlatformUi.segmented(
            activity, languages.map { it to Texts.langDisplayName(it) }, plated = true,
            onPick = onPick,
        )
        control = segmented
        bar.addView(segmented.view, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        bar.gravity = Gravity.CENTER
        return true
    }

    fun select(current: String) {
        control?.select(current)
    }

    private fun languages(config: JSONObject?): List<String> {
        val array = SettingsModel.dig(config, "ui.languages") as? JSONArray ?: return emptyList()
        return (0 until array.length()).map { array.optString(it) }.filter { it.isNotEmpty() }
    }
}

/** Text-to-speech for quick replies; initialised once per Activity. */
internal class ShellSpeech(activity: Activity) {
    private var ready = false
    private val engine: TextToSpeech = TextToSpeech(activity) { status ->
        ready = status == TextToSpeech.SUCCESS
    }

    fun speak(text: String, lang: String) {
        if (!ready || text.isEmpty()) return
        try {
            engine.language = Locale(if (lang.isEmpty()) "ja" else lang)
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT >= 21)
                engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, "reply")
            else
                engine.speak(text, TextToSpeech.QUEUE_FLUSH, null)
        } catch (e: Exception) {
            ShellLog.ignored("ShellSpeech", e)
        }
    }

    fun shutdown() {
        try { engine.shutdown() } catch (e: Exception) { ShellLog.ignored("ShellSpeech", e) }
    }
}
