// Framework controls for the legacy19 flavor (API 19): android.widget under the device theme,
// which is Holo on the hardware this flavor exists for. Same API as the modern flavor's
// PlatformUi, with no Material Components or AndroidX dependency.
package jp.ox.doorbell

import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.graphics.Color
import android.graphics.PorterDuff
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.widget.Button
import android.widget.CheckBox
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.SeekBar
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast

internal typealias ShellAlertDialog = android.app.AlertDialog
internal typealias ShellDialogBuilder = android.app.AlertDialog.Builder

internal object PlatformUi {

    const val MATERIAL = false

    // ---------- theme ----------

    fun isDark(@Suppress("UNUSED_PARAMETER") context: Context): Boolean = ShellAppearance.dark

    fun applyNightMode(dark: Boolean) = ShellActivity.applyAppearance(dark)

    @Suppress("DEPRECATION")
    private fun themeColor(context: Context, attr: Int, fallback: Int): Int {
        val value = TypedValue()
        if (!context.theme.resolveAttribute(attr, value, true)) return fallback
        return try {
            if (value.resourceId != 0) context.resources.getColorStateList(value.resourceId).defaultColor
            else value.data
        } catch (_: Exception) {
            fallback
        } and 0xffffff
    }

    /** The device theme's colours as the token set shared code paints with. */
    fun tokens(context: Context): Palette {
        val base = if (ShellAppearance.dark) Palette.DARK else Palette.LIGHT
        val ground = themeColor(context, android.R.attr.colorBackground, base.ground)
        val ink = themeColor(context, android.R.attr.textColorPrimary, base.ink)
        val accent = ShellAppearance.accent
        return base.copy(
            ground = ground,
            surface = blend(ink, ground, 0.06f),
            surfaceAlt = blend(ink, ground, 0.12f),
            ink = ink,
            muted = themeColor(context, android.R.attr.textColorSecondary, base.muted),
            line = blend(ink, ground, 0.2f),
            accent = accent?.first ?: HOLO_BLUE,
            accentInk = accent?.second ?: 0xFFFFFF,
        )
    }

    private fun opaque(rgb: Int): Int = 0xff000000.toInt() or (rgb and 0xffffff)

    private fun blend(overRgb: Int, underRgb: Int, amount: Float): Int {
        fun channel(shift: Int): Int {
            val over = overRgb ushr shift and 0xff
            val under = underRgb ushr shift and 0xff
            return (over * amount + under * (1f - amount)).toInt().coerceIn(0, 255)
        }
        return (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
    }

    private fun dp(context: Context, value: Int): Int =
        (value * context.resources.displayMetrics.density + 0.5f).toInt()

    private fun selectable(context: Context): Int {
        val value = TypedValue()
        context.theme.resolveAttribute(android.R.attr.selectableItemBackground, value, true)
        return value.resourceId
    }

    // ---------- buttons ----------

    fun button(context: Context, kind: ButtonKind): Button {
        val button = if (kind == ButtonKind.TEXT)
            Button(context, null, android.R.attr.borderlessButtonStyle) else Button(context)
        button.isAllCaps = false
        styleButton(button, kind, null, null)
        return button
    }

    /**
     * The stock button keeps its own frame; a role colour is laid over it as a tint, which is how
     * Holo applications coloured a positive or destructive action. Tonal and outlined buttons are
     * the plain stock button.
     */
    fun styleButton(view: TextView, kind: ButtonKind, fillRgb: Int?, inkRgb: Int?) {
        val tokens = tokens(view.context)
        val background = view.background?.mutate()
        when (kind) {
            ButtonKind.FILLED -> {
                val fill = fillRgb ?: tokens.accent
                background?.setColorFilter(opaque(fill), PorterDuff.Mode.SRC_ATOP)
                view.setTextColor(opaque(inkRgb ?: if (fillRgb == null) tokens.accentInk
                                         else tokens.inkOver(fill)))
                view.setTypeface(Typeface.create(view.typeface, Typeface.BOLD))
            }
            ButtonKind.TONAL, ButtonKind.OUTLINED -> {
                background?.clearColorFilter()
                view.setTextColor(opaque(tokens.ink))
                view.setTypeface(Typeface.create(view.typeface, Typeface.NORMAL))
            }
            ButtonKind.TEXT -> {
                background?.clearColorFilter()
                view.setTextColor(opaque(fillRgb?.let { ColorRoles.asText(it, tokens.ground) }
                                         ?: tokens.ink))
            }
        }
    }

    @Suppress("DEPRECATION")
    fun setButtonIcon(view: TextView, icon: Int) {
        if (icon == 0) {
            view.setCompoundDrawables(null, null, null, null)
            return
        }
        val drawable = view.resources.getDrawable(icon).mutate()
        val size = dp(view.context, 24)
        drawable.setBounds(0, 0, size, size)
        drawable.setColorFilter(view.currentTextColor, PorterDuff.Mode.SRC_IN)
        view.setCompoundDrawables(drawable, null, null, null)
        view.compoundDrawablePadding = dp(view.context, 8)
    }

    fun iconButton(context: Context, icon: Int, label: CharSequence, onClick: () -> Unit): View =
        ImageButton(context).apply {
            setImageResource(icon)
            setColorFilter(opaque(tokens(context).ink))
            contentDescription = label
            minimumWidth = dp(context, 48)
            minimumHeight = dp(context, 48)
            setOnClickListener { onClick() }
        }

    // ---------- containers ----------

    fun card(context: Context, @Suppress("UNUSED_PARAMETER") outlined: Boolean = false): CardHandle {
        val tokens = tokens(context)
        fun plate(highlighted: Boolean) = GradientDrawable().apply {
            setColor(opaque(tokens.surface))
            cornerRadius = dp(context, 2).toFloat()
            if (highlighted) setStroke(dp(context, 3), opaque(tokens.accent))
            else setStroke(dp(context, 1), opaque(tokens.line))
        }
        val panel = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            background = plate(false)
            val inset = dp(context, 1)
            setPadding(inset, inset, inset, inset)
        }
        return CardHandle(panel, panel) { highlighted ->
            val left = panel.paddingLeft
            val top = panel.paddingTop
            val right = panel.paddingRight
            val bottom = panel.paddingBottom
            panel.background = plate(highlighted)
            panel.setPadding(left, top, right, bottom)
        }
    }

    fun cardBackground(context: Context): android.graphics.drawable.Drawable {
        val tokens = tokens(context)
        return GradientDrawable().apply {
            setColor(opaque(tokens.surface))
            cornerRadius = dp(context, 2).toFloat()
            setStroke(dp(context, 1), opaque(tokens.line))
        }
    }

    @Suppress("DEPRECATION")
    fun divider(context: Context): View = View(context).apply {
        val value = TypedValue()
        if (context.theme.resolveAttribute(android.R.attr.listDivider, value, true) &&
            value.resourceId != 0) setBackgroundResource(value.resourceId)
        else setBackgroundColor(opaque(tokens(context).line))
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(context, 1))
    }

    // ---------- selection controls ----------

    fun toggle(context: Context): CompoundButton = Switch(context)

    fun checkbox(context: Context): CompoundButton = CheckBox(context)

    fun radio(context: Context): android.widget.RadioButton = android.widget.RadioButton(context)

    fun slider(
        context: Context,
        min: Int,
        max: Int,
        value: Int,
        enabled: Boolean,
        onChange: (Int) -> Unit,
        onCommit: (Int) -> Unit,
    ): SliderHandle {
        val top = maxOf(max, min + 1)
        val bar = SeekBar(context).apply {
            this.max = top - min
            progress = value.coerceIn(min, top) - min
            isEnabled = enabled
            minimumHeight = dp(context, 48)
        }
        var dragging = false
        val commit = Runnable { onCommit(bar.progress + min) }
        bar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                onChange(progress + min)
                if (fromUser && !dragging) {
                    seekBar.removeCallbacks(commit)
                    seekBar.postDelayed(commit, KEY_COMMIT_MS)
                }
            }

            override fun onStartTrackingTouch(seekBar: SeekBar) {
                dragging = true
                seekBar.removeCallbacks(commit)
            }

            override fun onStopTrackingTouch(seekBar: SeekBar) {
                dragging = false
                onCommit(seekBar.progress + min)
            }
        })
        return SliderHandle(bar, { bar.progress + min },
                            { bar.progress = it.coerceIn(min, top) - min })
    }

    /** A status label, or a borderless button for an action or a filter. */
    fun chip(
        context: Context,
        text: CharSequence,
        kind: ChipKind,
        icon: Int = 0,
        fillRgb: Int? = null,
        inkRgb: Int? = null,
    ): TextView {
        val tokens = tokens(context)
        val chip: TextView = if (kind == ChipKind.STATUS) TextView(context)
            else Button(context, null, android.R.attr.borderlessButtonStyle).apply {
                isAllCaps = false
                minHeight = dp(context, 48)
                minimumHeight = dp(context, 48)
            }
        chip.text = text
        chip.textSize = 13f
        chip.gravity = Gravity.CENTER
        val ink = opaque(inkRgb ?: tokens.ink)
        chip.setTextColor(ink)
        if (kind == ChipKind.STATUS || fillRgb != null) {
            chip.background = GradientDrawable().apply {
                setColor(opaque(fillRgb ?: tokens.surfaceAlt))
                cornerRadius = dp(context, 2).toFloat()
            }
            val padH = dp(context, 8)
            val padV = dp(context, 4)
            chip.setPadding(padH, padV, padH, padV)
        }
        if (icon != 0) {
            @Suppress("DEPRECATION")
            val drawable = context.resources.getDrawable(icon).mutate()
            val size = dp(context, 16)
            drawable.setBounds(0, 0, size, size)
            drawable.setColorFilter(ink, PorterDuff.Mode.SRC_IN)
            chip.setCompoundDrawables(drawable, null, null, null)
            chip.compoundDrawablePadding = dp(context, 4)
        }
        return chip
    }

    /** A checked filter is drawn the Holo way: bold, in the accent, with the tab underline. */
    fun setChipChecked(view: View, checked: Boolean) {
        val chip = view as? TextView ?: return
        val tokens = tokens(chip.context)
        chip.isSelected = checked
        chip.setTypeface(Typeface.create(chip.typeface, if (checked) Typeface.BOLD else Typeface.NORMAL))
        chip.setTextColor(opaque(if (checked) tokens.accent else tokens.ink))
    }

    fun segmented(
        context: Context,
        options: List<Pair<String, String>>,
        @Suppress("UNUSED_PARAMETER") plated: Boolean = false,
        onPick: (String) -> Unit,
    ): SegmentedHandle {
        val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
        val buttons = HashMap<String, Button>()
        for ((id, label) in options) {
            val button = Button(context).apply {
                text = label
                isAllCaps = false
                minHeight = dp(context, 48)
                setOnClickListener { onPick(id) }
            }
            buttons[id] = button
            row.addView(button, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ))
        }
        return object : SegmentedHandle {
            override val view: View = row
            override fun select(id: String) {
                for ((key, button) in buttons) {
                    val selected = key == id
                    button.isSelected = selected
                    styleButton(button, if (selected) ButtonKind.FILLED else ButtonKind.TONAL,
                                null, null)
                }
            }
        }
    }

    // ---------- text entry ----------

    fun field(
        context: Context,
        hint: CharSequence = "",
        value: CharSequence = "",
        inputType: Int = InputType.TYPE_CLASS_TEXT,
        lines: Int = 1,
        icon: Int = 0,
    ): FieldHandle {
        val input = EditText(context)
        if (icon != 0) {
            @Suppress("DEPRECATION")
            val drawable = context.resources.getDrawable(icon).mutate()
            val size = dp(context, 20)
            drawable.setBounds(0, 0, size, size)
            drawable.setColorFilter(opaque(tokens(context).muted), PorterDuff.Mode.SRC_IN)
            input.setCompoundDrawables(drawable, null, null, null)
            input.compoundDrawablePadding = dp(context, 8)
        }
        if (lines > 1) {
            input.setSingleLine(false)
            input.minLines = lines
            input.gravity = Gravity.TOP or Gravity.START
        } else {
            input.setSingleLine(true)
        }
        // After setSingleLine: that call installs its own transformation and would unmask a
        // password field.
        input.inputType = if (lines > 1) inputType or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            else inputType
        input.hint = hint
        input.setText(value)
        return FieldHandle(input, input) { message -> input.error = message }
    }

    // ---------- progress ----------

    fun progress(context: Context, linear: Boolean = false): View =
        if (linear) ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = true
        } else ProgressBar(context).apply { isIndeterminate = true }

    // ---------- navigation ----------

    /** An ActionBar-style title row: up control, title and subtitle, actions on the right. */
    fun appBar(context: Context, title: CharSequence): AppBarHandle {
        val tokens = tokens(context)
        val value = TypedValue()
        val height = if (context.theme.resolveAttribute(android.R.attr.actionBarSize, value, true))
            TypedValue.complexToDimensionPixelSize(value.data, context.resources.displayMetrics)
            else dp(context, 48)
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = height
        }
        val back = ImageButton(context).apply {
            setImageResource(R.drawable.ic_tabler_chevron_left)
            setBackgroundResource(selectable(context))
            setColorFilter(opaque(tokens.ink))
            visibility = View.GONE
        }
        row.addView(back, LinearLayout.LayoutParams(dp(context, 48), height))
        val titles = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            val pad = dp(context, 12)
            setPadding(pad, 0, pad, 0)
        }
        val titleView = TextView(context).apply {
            text = title
            textSize = 18f
            setSingleLine(true)
            ellipsize = android.text.TextUtils.TruncateAt.END
            setTextColor(opaque(tokens.ink))
        }
        val subtitleView = TextView(context).apply {
            textSize = 13f
            setSingleLine(true)
            setTextColor(opaque(tokens.muted))
            visibility = View.GONE
        }
        titles.addView(titleView)
        titles.addView(subtitleView)
        row.addView(titles, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val actions = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        row.addView(actions)
        // The Holo action bar's accent rule under the row.
        val rule = View(context).apply { setBackgroundColor(opaque(HOLO_BLUE)) }
        val column = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(row, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(rule, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(context, 2)))
        }
        var ink = opaque(tokens.ink)
        return object : AppBarHandle {
            override val view: View = column
            override fun setTitle(title: CharSequence) { titleView.text = title }
            override fun setSubtitle(subtitle: CharSequence?) {
                subtitleView.text = subtitle
                subtitleView.visibility = if (subtitle.isNullOrEmpty()) View.GONE else View.VISIBLE
            }

            override fun setBack(label: CharSequence, onBack: (() -> Unit)?) {
                back.visibility = if (onBack == null) View.GONE else View.VISIBLE
                back.contentDescription = label
                back.setOnClickListener { onBack?.invoke() }
            }

            override fun clearActions() = actions.removeAllViews()

            override fun addAction(icon: Int, label: CharSequence, onClick: () -> Unit) {
                val action: View = if (icon != 0) ImageButton(context).apply {
                    setImageResource(icon)
                    setBackgroundResource(selectable(context))
                    setColorFilter(ink)
                    contentDescription = label
                } else Button(context, null, android.R.attr.borderlessButtonStyle).apply {
                    text = label
                    isAllCaps = false
                    setTextColor(ink)
                }
                action.setOnClickListener { onClick() }
                actions.addView(action, LinearLayout.LayoutParams(
                    if (icon != 0) dp(context, 48) else ViewGroup.LayoutParams.WRAP_CONTENT, height,
                ))
            }

            override fun setInk(rgb: Int?) {
                ink = opaque(rgb ?: tokens.ink)
                titleView.setTextColor(ink)
                subtitleView.setTextColor(rgb?.let { opaque(it) } ?: opaque(tokens.muted))
                back.setColorFilter(ink)
                for (index in 0 until actions.childCount) when (val child = actions.getChildAt(index)) {
                    is ImageView -> child.setColorFilter(ink)
                    is TextView -> child.setTextColor(ink)
                }
            }
        }
    }

    /** Holo tabs: icon above label, the selected one marked with the accent rule. */
    fun navigation(
        context: Context,
        style: NavStyle,
        items: List<NavItem>,
        selected: String,
        badges: Map<String, Int>,
        onSelect: (NavItem) -> Unit,
    ): View {
        val tokens = tokens(context)
        val rail = style == NavStyle.RAIL
        return LinearLayout(context).apply {
            orientation = if (rail) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
            setBackgroundColor(opaque(tokens.surface))
            for (item in items) {
                val active = item.id == selected
                val ink = opaque(if (active) tokens.accent else tokens.ink)
                val cell = LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER
                    minimumHeight = dp(context, 56)
                    minimumWidth = dp(context, if (rail) 80 else 48)
                    isClickable = true
                    isFocusable = true
                    isSelected = active
                    contentDescription = item.label
                    setBackgroundResource(selectable(context))
                    setOnClickListener { if (!active) onSelect(item) }
                    addView(ImageView(context).apply {
                        setImageResource(item.icon)
                        setColorFilter(ink)
                        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                    }, LinearLayout.LayoutParams(dp(context, 24), dp(context, 24)))
                    addView(TextView(context).apply {
                        val count = badges[item.id] ?: 0
                        text = if (count > 0) "${item.label} ($count)" else item.label
                        textSize = 12f
                        gravity = Gravity.CENTER
                        maxLines = 2
                        setTextColor(ink)
                        if (active) setTypeface(typeface, Typeface.BOLD)
                    })
                    addView(View(context).apply {
                        setBackgroundColor(if (active) opaque(HOLO_BLUE) else Color.TRANSPARENT)
                    }, LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, dp(context, 3),
                    ).apply { topMargin = dp(context, 4) })
                }
                if (rail) addView(cell, LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
                else addView(cell, LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            }
        }
    }

    // ---------- sheets and transient feedback ----------

    /** A plain dialog window at the bottom or the end edge; the screen underneath keeps running. */
    fun sheet(context: Context, atSide: Boolean, onDismiss: () -> Unit = {}): SheetHandle {
        val tokens = tokens(context)
        val content = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            val pad = dp(context, 16)
            setPadding(pad, pad, pad, pad)
            setBackgroundColor(opaque(tokens.ground))
        }
        val dialog = Dialog(context)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
        dialog.setContentView(content)
        dialog.setOnDismissListener { onDismiss() }
        dialog.window?.let { window ->
            window.setBackgroundDrawable(ColorDrawable(opaque(tokens.ground)))
            window.setGravity(if (atSide) Gravity.END else Gravity.BOTTOM)
            window.setLayout(
                if (atSide) dp(context, SIDE_SHEET_DP) else WindowManager.LayoutParams.MATCH_PARENT,
                if (atSide) WindowManager.LayoutParams.MATCH_PARENT
                else WindowManager.LayoutParams.WRAP_CONTENT,
            )
        }
        return object : SheetHandle {
            override val content: LinearLayout = content
            override val showing: Boolean get() = dialog.isShowing
            override fun show() { if (!dialog.isShowing) dialog.show() }
            override fun dismiss() { if (dialog.isShowing) dialog.dismiss() }
        }
    }

    /** The surface a safety confirmation opens on: a stock alert dialog around the content. */
    fun confirmSurface(context: Context, onDismiss: () -> Unit = {}): SheetHandle {
        val content = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            val pad = dp(context, 16)
            setPadding(pad, pad, pad, pad)
        }
        val dialog = android.app.AlertDialog.Builder(context).setView(content).create()
        dialog.setOnDismissListener { onDismiss() }
        return object : SheetHandle {
            override val content: LinearLayout = content
            override val showing: Boolean get() = dialog.isShowing
            override fun show() { if (!dialog.isShowing) dialog.show() }
            override fun dismiss() { if (dialog.isShowing) dialog.dismiss() }
        }
    }

    fun toast(activity: Activity, message: CharSequence, long: Boolean = false) {
        Toast.makeText(activity, message, if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT).show()
    }

    // ---------- administrator overrides on semantic IDs ----------

    // Framework widgets take an override as a background drawable, which SemanticUi builds.

    fun captureStyle(@Suppress("UNUSED_PARAMETER") view: View): Any? = null

    fun restoreStyle(@Suppress("UNUSED_PARAMETER") view: View,
                     @Suppress("UNUSED_PARAMETER") saved: Any?): Boolean = false

    fun fillRgb(@Suppress("UNUSED_PARAMETER") view: View): Int? = null

    @Suppress("UNUSED_PARAMETER")
    fun applyStyle(
        view: View,
        fillArgb: Int?,
        borderArgb: Int?,
        accentArgb: Int?,
        radiusPx: Float?,
        borderPx: Float,
        accentPx: Float,
    ): Boolean = false

    private const val HOLO_BLUE = 0x33B5E5
    private const val KEY_COMMIT_MS = 600L
    private const val SIDE_SHEET_DP = 360
}
