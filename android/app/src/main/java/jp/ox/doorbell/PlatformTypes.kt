// The vocabulary shared code uses to ask its flavor for a native control.
//
// `PlatformUi` and `ShellActivity` exist once per flavor with the same API: Material Components
// under src/modern, framework (Holo/DeviceDefault) widgets under src/legacy19. Screens in src/main
// build from these handles, so no screen names a Material or AppCompat type and legacy19 never
// links one.
package jp.ox.doorbell

import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout

/** Material's button emphasis levels; legacy19 maps them onto the stock and borderless buttons. */
internal enum class ButtonKind { FILLED, TONAL, OUTLINED, TEXT }

/** STATUS only reports, ACTION is tappable, FILTER is checkable. */
internal enum class ChipKind { STATUS, ACTION, FILTER }

/** The platform type ramp, largest first. */
internal enum class TextRole { DISPLAY, HEADLINE, TITLE, SUBTITLE, BODY, SUPPORTING, LABEL }

/** A card: add [root] to the layout and children to [content]. */
internal class CardHandle(
    val root: ViewGroup,
    val content: LinearLayout,
    private val onHighlight: (Boolean) -> Unit,
) {
    /** Marks the card as the one demanding attention (a ringing door). */
    fun setHighlighted(value: Boolean) = onHighlight(value)
}

/** A labelled text field: add [view] to the layout, read and write through [input]. */
internal class FieldHandle(
    val view: View,
    val input: EditText,
    private val onError: (CharSequence?) -> Unit,
) {
    var text: String
        get() = input.text.toString()
        set(value) { input.setText(value) }

    fun setError(message: CharSequence?) = onError(message)
}

internal class SliderHandle(
    val view: View,
    private val read: () -> Int,
    private val write: (Int) -> Unit,
) {
    var value: Int
        get() = read()
        set(next) = write(next)
}

/** The title row of a screen: back navigation, title, and trailing actions. */
internal interface AppBarHandle {
    val view: View
    fun setTitle(title: CharSequence)
    fun setSubtitle(subtitle: CharSequence?)

    /** Null [onBack] removes the navigation control. */
    fun setBack(label: CharSequence, onBack: (() -> Unit)?)
    fun clearActions()

    /** [icon] 0 shows the label as a text action. */
    fun addAction(icon: Int, label: CharSequence, onClick: () -> Unit)

    /** Ink for a bar drawn over the wallpaper; null returns to the theme's colours. */
    fun setInk(rgb: Int?)
}

/** A modal sheet; the screen underneath keeps running while it is shown. */
internal interface SheetHandle {
    val content: LinearLayout
    val showing: Boolean
    fun show()
    fun dismiss()
}

/** A single-choice segmented control. */
internal interface SegmentedHandle {
    val view: View
    fun select(id: String)
}
