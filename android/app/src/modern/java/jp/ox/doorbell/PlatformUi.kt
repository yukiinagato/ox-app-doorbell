// Material 3 controls for the modern flavor (API 21+), built with Material Components for
// Android. Shared screens ask for a control by job (docs/en/ui-guidelines.md section 5) and get
// the stock Material widget with its default appearance; the only colours set here are Core's
// accent on the primary roles and the fixed positive/negative roles.
package jp.ox.doorbell

import android.app.Activity
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.text.InputType
import android.text.method.PasswordTransformationMethod
import android.view.Gravity
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.CompoundButton
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatDelegate
import androidx.appcompat.app.AppCompatDialog
import androidx.core.view.MenuItemCompat
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.button.MaterialButton
import com.google.android.material.button.MaterialButtonToggleGroup
import com.google.android.material.card.MaterialCardView
import com.google.android.material.checkbox.MaterialCheckBox
import com.google.android.material.chip.Chip
import com.google.android.material.color.MaterialColors
import com.google.android.material.divider.MaterialDivider
import com.google.android.material.materialswitch.MaterialSwitch
import com.google.android.material.navigation.NavigationBarView
import com.google.android.material.navigationrail.NavigationRailView
import com.google.android.material.progressindicator.CircularProgressIndicator
import com.google.android.material.progressindicator.LinearProgressIndicator
import com.google.android.material.sidesheet.SideSheetDialog
import com.google.android.material.slider.Slider
import com.google.android.material.snackbar.Snackbar
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout

internal typealias ShellAlertDialog = androidx.appcompat.app.AlertDialog
internal typealias ShellDialogBuilder = com.google.android.material.dialog.MaterialAlertDialogBuilder

internal object PlatformUi {

    /** True where screens may rely on Material patterns (sheets, snackbars, rails). */
    const val MATERIAL = true

    // ---------- theme ----------

    fun isDark(context: Context): Boolean =
        context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES

    /** Must run on the main thread; AppCompat reconfigures every live activity. */
    fun applyNightMode(dark: Boolean) {
        AppCompatDelegate.setDefaultNightMode(
            if (dark) AppCompatDelegate.MODE_NIGHT_YES else AppCompatDelegate.MODE_NIGHT_NO,
        )
    }

    private fun argb(context: Context, attr: Int): Int =
        MaterialColors.getColor(context, attr, Color.MAGENTA)

    private fun rgb(context: Context, attr: Int): Int = argb(context, attr) and 0xffffff

    /**
     * The system colours as the token set shared code paints with, so text a screen colours by
     * hand matches the Material surfaces around it.
     */
    fun tokens(context: Context): Palette {
        val base = if (isDark(context)) Palette.DARK else Palette.LIGHT
        val accent = ShellAppearance.accent
        return base.copy(
            ground = rgb(context, R.attr.colorSurface),
            surface = rgb(context, R.attr.colorSurfaceContainerLow),
            surfaceAlt = rgb(context, R.attr.colorSurfaceContainerHigh),
            ink = rgb(context, R.attr.colorOnSurface),
            muted = rgb(context, R.attr.colorOnSurfaceVariant),
            line = rgb(context, R.attr.colorOutlineVariant),
            accent = accent?.first ?: rgb(context, R.attr.colorPrimary),
            accentInk = accent?.second ?: rgb(context, R.attr.colorOnPrimary),
            danger = rgb(context, R.attr.colorError),
            dangerSoft = rgb(context, R.attr.colorErrorContainer),
            dangerInk = rgb(context, R.attr.colorOnErrorContainer),
            onNegative = rgb(context, R.attr.colorOnError),
            positive = rgb(context, R.attr.dbPositiveColor),
            onPositive = rgb(context, R.attr.dbOnPositiveColor),
            warning = rgb(context, R.attr.dbWarningColor),
            onWarning = rgb(context, R.attr.dbOnWarningColor),
        )
    }

    private fun opaque(rgb: Int): Int = 0xff000000.toInt() or (rgb and 0xffffff)

    private fun withAlpha(color: Int, fraction: Float): Int =
        ((255 * fraction).toInt() shl 24) or (color and 0xffffff)

    private fun blend(overRgb: Int, underRgb: Int, amount: Float): Int {
        fun channel(shift: Int): Int {
            val over = overRgb ushr shift and 0xff
            val under = underRgb ushr shift and 0xff
            return (over * amount + under * (1f - amount)).toInt().coerceIn(0, 255)
        }
        return (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
    }

    private fun enabledStates(enabled: Int, disabled: Int): ColorStateList = ColorStateList(
        arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()),
        intArrayOf(disabled, enabled),
    )

    private fun checkedStates(checked: Int, unchecked: Int): ColorStateList = ColorStateList(
        arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()),
        intArrayOf(checked, unchecked),
    )

    /** A role colour used as text or an outline on the surface: at least 4.5:1 there. */
    private fun inkOnSurface(context: Context, rgb: Int): Int =
        opaque(ColorRoles.asText(rgb, rgb(context, R.attr.colorSurface)))

    private fun dp(context: Context, value: Int): Int =
        (value * context.resources.displayMetrics.density + 0.5f).toInt()

    // ---------- buttons ----------

    fun button(context: Context, kind: ButtonKind): Button {
        val attr = when (kind) {
            ButtonKind.FILLED -> R.attr.materialButtonStyle
            ButtonKind.TONAL -> R.attr.dbButtonTonalStyle
            ButtonKind.OUTLINED -> R.attr.materialButtonOutlinedStyle
            ButtonKind.TEXT -> R.attr.dbButtonTextStyle
        }
        return MaterialButton(context, null, attr).apply {
            isAllCaps = false
            styleButton(this, kind, null, null)
        }
    }

    /**
     * Give a button its emphasis and role colours. [fillRgb]/[inkRgb] null means the primary role:
     * Core's accent when it publishes one, the theme's primary otherwise.
     */
    fun styleButton(view: TextView, kind: ButtonKind, fillRgb: Int?, inkRgb: Int?) {
        val button = view as? MaterialButton ?: return
        val context = button.context
        val onSurface = argb(context, R.attr.colorOnSurface)
        val disabledInk = withAlpha(onSurface, 0.38f)
        val accent = ShellAppearance.accent
        val fill = fillRgb ?: accent?.first
        val ink = inkRgb ?: if (fillRgb == null) accent?.second else null
        val container: Int
        val content: Int
        var stroke = 0
        when (kind) {
            ButtonKind.FILLED -> {
                container = fill?.let(::opaque) ?: argb(context, R.attr.colorPrimary)
                content = ink?.let(::opaque) ?: argb(context, R.attr.colorOnPrimary)
            }
            ButtonKind.TONAL -> {
                container = fill?.let {
                    opaque(blend(it, rgb(context, R.attr.colorSurface), 0.22f))
                } ?: argb(context, R.attr.colorSecondaryContainer)
                content = if (fill != null) onSurface
                    else argb(context, R.attr.colorOnSecondaryContainer)
            }
            ButtonKind.OUTLINED, ButtonKind.TEXT -> {
                container = Color.TRANSPARENT
                content = fill?.let { inkOnSurface(context, it) }
                    ?: argb(context, R.attr.colorPrimary)
                if (kind == ButtonKind.OUTLINED) stroke = dp(context, 1)
            }
        }
        val transparent = kind == ButtonKind.OUTLINED || kind == ButtonKind.TEXT
        button.backgroundTintList = enabledStates(
            container, if (transparent) Color.TRANSPARENT else withAlpha(onSurface, 0.12f),
        )
        val contentStates = enabledStates(content, disabledInk)
        button.setTextColor(contentStates)
        button.iconTint = contentStates
        button.rippleColor = ColorStateList.valueOf(withAlpha(content, 0.16f))
        button.strokeWidth = stroke
        if (stroke > 0) button.strokeColor = ColorStateList.valueOf(argb(context, R.attr.colorOutline))
    }

    fun setButtonIcon(view: TextView, icon: Int) {
        val button = view as? MaterialButton ?: return
        if (icon == 0) {
            button.icon = null
            return
        }
        button.setIconResource(icon)
        button.iconGravity = MaterialButton.ICON_GRAVITY_TEXT_START
        button.iconSize = dp(button.context, 24)
        button.iconPadding = dp(button.context, 8)
    }

    /** A tonal icon button: it carries its own container, so it reads over any wallpaper. */
    fun iconButton(context: Context, icon: Int, label: CharSequence, onClick: () -> Unit): View =
        MaterialButton(context, null, R.attr.materialIconButtonFilledTonalStyle).apply {
            setIconResource(icon)
            contentDescription = label
            if (android.os.Build.VERSION.SDK_INT >= 26) tooltipText = label
            minimumWidth = dp(context, 48)
            minimumHeight = dp(context, 48)
            setOnClickListener { onClick() }
        }

    // ---------- containers ----------

    fun card(context: Context, outlined: Boolean = false): CardHandle {
        val card = MaterialCardView(
            context, null,
            if (outlined) R.attr.materialCardViewOutlinedStyle
            else R.attr.materialCardViewFilledStyle,
        )
        val content = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        card.addView(content, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ))
        val restingWidth = card.strokeWidth
        val restingColor = card.strokeColorStateList
        return CardHandle(card, content) { highlighted ->
            if (highlighted) {
                card.strokeWidth = dp(context, 3)
                card.strokeColor = ShellAppearance.accent?.first?.let(::opaque)
                    ?: argb(context, R.attr.colorPrimary)
            } else {
                card.strokeWidth = restingWidth
                if (restingColor != null) card.setStrokeColor(restingColor)
            }
        }
    }

    /** The filled-card container as a drawable, for a block that must stay a plain layout. */
    fun cardBackground(context: Context): android.graphics.drawable.Drawable =
        com.google.android.material.shape.MaterialShapeDrawable().apply {
            fillColor = ColorStateList.valueOf(argb(context, R.attr.colorSurfaceContainerHighest))
            setCornerSize(dp(context, 12).toFloat())
        }

    fun divider(context: Context): View = MaterialDivider(context)

    // ---------- selection controls ----------

    fun toggle(context: Context): CompoundButton = MaterialSwitch(context).apply {
        ShellAppearance.accent?.let { (fill, ink) ->
            trackTintList = checkedStates(opaque(fill), argb(context, R.attr.colorSurfaceContainerHighest))
            thumbTintList = checkedStates(opaque(ink), argb(context, R.attr.colorOutline))
        }
    }

    fun checkbox(context: Context): CompoundButton = MaterialCheckBox(context)

    fun radio(context: Context): android.widget.RadioButton =
        com.google.android.material.radiobutton.MaterialRadioButton(context)

    /**
     * An integer slider. [onChange] follows the thumb; [onCommit] fires once when the finger
     * lifts, or shortly after the last key press so a D-pad adjustment is written too.
     */
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
        val slider = Slider(context).apply {
            valueFrom = min.toFloat()
            valueTo = top.toFloat()
            stepSize = 1f
            this.value = value.coerceIn(min, top).toFloat()
            isEnabled = enabled
            isTickVisible = false
            setLabelFormatter { it.toInt().toString() }
            ShellAppearance.accent?.first?.let {
                val tint = ColorStateList.valueOf(inkOnSurface(context, it))
                trackActiveTintList = tint
                thumbTintList = tint
                trackInactiveTintList = ColorStateList.valueOf(
                    opaque(blend(it, rgb(context, R.attr.colorSurface), 0.24f)),
                )
            }
        }
        var dragging = false
        val commit = Runnable { onCommit(slider.value.toInt()) }
        slider.addOnChangeListener { _, current, fromUser ->
            onChange(current.toInt())
            if (fromUser && !dragging) {
                slider.removeCallbacks(commit)
                slider.postDelayed(commit, KEY_COMMIT_MS)
            }
        }
        slider.addOnSliderTouchListener(object : Slider.OnSliderTouchListener {
            override fun onStartTrackingTouch(target: Slider) {
                dragging = true
                target.removeCallbacks(commit)
            }

            override fun onStopTrackingTouch(target: Slider) {
                dragging = false
                onCommit(target.value.toInt())
            }
        })
        return SliderHandle(slider, { slider.value.toInt() },
                            { slider.value = it.coerceIn(min, top).toFloat() })
    }

    /**
     * A chip. [fillRgb]/[inkRgb] give a status chip its semantic colours; without them a chip
     * takes a surface container so it stays legible over the wallpaper.
     */
    fun chip(
        context: Context,
        text: CharSequence,
        kind: ChipKind,
        icon: Int = 0,
        fillRgb: Int? = null,
        inkRgb: Int? = null,
    ): TextView {
        val chip = Chip(context, null, when (kind) {
            ChipKind.STATUS -> R.attr.dbChipStatusStyle
            ChipKind.ACTION -> R.attr.dbChipActionStyle
            ChipKind.FILTER -> R.attr.dbChipFilterStyle
        })
        chip.text = text
        chip.isCheckable = kind == ChipKind.FILTER
        if (kind == ChipKind.STATUS) {
            chip.isClickable = false
            chip.isFocusable = false
            chip.setEnsureMinTouchTargetSize(false)
        }
        val ink = inkRgb?.let(::opaque)
        if (fillRgb != null) {
            chip.chipBackgroundColor = ColorStateList.valueOf(opaque(fillRgb))
            chip.chipStrokeWidth = 0f
        } else if (kind != ChipKind.FILTER) {
            chip.chipBackgroundColor =
                ColorStateList.valueOf(argb(context, R.attr.colorSurfaceContainerLow))
        }
        if (ink != null) chip.setTextColor(ink)
        if (icon != 0) {
            chip.setChipIconResource(icon)
            chip.isChipIconVisible = true
            chip.chipIconTint = ColorStateList.valueOf(
                ink ?: argb(context, R.attr.colorOnSurfaceVariant),
            )
        }
        return chip
    }

    fun setChipChecked(view: View, checked: Boolean) {
        (view as? Chip)?.isChecked = checked
    }

    /** [plated] puts the group on a card so the outlined segments read over a photograph. */
    fun segmented(
        context: Context,
        options: List<Pair<String, String>>,
        plated: Boolean = false,
        onPick: (String) -> Unit,
    ): SegmentedHandle {
        val group = MaterialButtonToggleGroup(context).apply {
            isSingleSelection = true
            isSelectionRequired = true
        }
        val ids = HashMap<String, Int>()
        var muted = false
        for ((id, label) in options) {
            val button = MaterialButton(context, null, R.attr.materialButtonOutlinedStyle).apply {
                this.id = View.generateViewId()
                text = label
                isAllCaps = false
                tag = id
                minimumHeight = dp(context, 48)
                minHeight = dp(context, 48)
                insetTop = 0
                insetBottom = 0
            }
            ids[id] = button.id
            group.addView(button, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ))
        }
        group.addOnButtonCheckedListener { _, checkedId, isChecked ->
            if (!isChecked || muted) return@addOnButtonCheckedListener
            ids.entries.firstOrNull { it.value == checkedId }?.let { onPick(it.key) }
        }
        val plate: View = if (!plated) group
            else MaterialCardView(context, null, R.attr.materialCardViewFilledStyle).apply {
                radius = dp(context, 28).toFloat()
                val pad = dp(context, 4)
                setContentPadding(pad, pad, pad, pad)
                addView(group)
            }
        return object : SegmentedHandle {
            override val view: View = plate
            override fun select(id: String) {
                val target = ids[id] ?: return
                muted = true
                group.check(target)
                muted = false
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
        val layout = TextInputLayout(context, null, R.attr.textInputOutlinedStyle)
        if (icon != 0) layout.setStartIconDrawable(icon)
        val input = TextInputEditText(layout.context)
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
        input.setText(value)
        layout.addView(input, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ))
        if (hint.isNotEmpty()) layout.hint = hint
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        val password = (inputType and InputType.TYPE_MASK_CLASS == InputType.TYPE_CLASS_TEXT &&
            variation == InputType.TYPE_TEXT_VARIATION_PASSWORD) ||
            (inputType and InputType.TYPE_MASK_CLASS == InputType.TYPE_CLASS_NUMBER &&
                variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD)
        if (password) {
            // The reveal toggle uses the fleet's Tabler eye rather than the library's own glyph.
            var revealed = false
            layout.endIconMode = TextInputLayout.END_ICON_CUSTOM
            layout.setEndIconDrawable(R.drawable.ic_tabler_eye)
            layout.endIconContentDescription = context.getString(R.string.password_show)
            layout.setEndIconOnClickListener {
                revealed = !revealed
                val cursor = input.selectionEnd
                input.transformationMethod =
                    if (revealed) null else PasswordTransformationMethod.getInstance()
                input.setSelection(cursor.coerceIn(0, input.text?.length ?: 0))
                layout.setEndIconDrawable(
                    if (revealed) R.drawable.ic_tabler_eye_off else R.drawable.ic_tabler_eye,
                )
                layout.endIconContentDescription = context.getString(
                    if (revealed) R.string.password_hide else R.string.password_show,
                )
            }
        }
        return FieldHandle(layout, input) { message ->
            layout.error = message
            layout.isErrorEnabled = !message.isNullOrEmpty()
        }
    }

    // ---------- progress ----------

    fun progress(context: Context, linear: Boolean = false): View {
        val accent = ShellAppearance.accent?.first?.let { inkOnSurface(context, it) }
        return if (linear) LinearProgressIndicator(context).apply {
            isIndeterminate = true
            accent?.let { setIndicatorColor(it) }
        } else CircularProgressIndicator(context).apply {
            isIndeterminate = true
            accent?.let { setIndicatorColor(it) }
        }
    }

    // ---------- navigation ----------

    fun appBar(context: Context, title: CharSequence): AppBarHandle {
        val bar = MaterialToolbar(context)
        bar.title = title
        var ink: Int? = null
        fun iconTint(): ColorStateList =
            ColorStateList.valueOf(ink ?: argb(context, R.attr.colorOnSurfaceVariant))
        return object : AppBarHandle {
            override val view: View = bar
            override fun setTitle(title: CharSequence) { bar.title = title }
            override fun setSubtitle(subtitle: CharSequence?) { bar.subtitle = subtitle }

            override fun setBack(label: CharSequence, onBack: (() -> Unit)?) {
                if (onBack == null) {
                    bar.navigationIcon = null
                    bar.setNavigationOnClickListener(null)
                    return
                }
                bar.setNavigationIcon(R.drawable.ic_tabler_chevron_left)
                bar.setNavigationIconTint(ink ?: argb(context, R.attr.colorOnSurface))
                bar.navigationContentDescription = label
                bar.setNavigationOnClickListener { onBack() }
            }

            override fun clearActions() = bar.menu.clear()

            override fun addAction(icon: Int, label: CharSequence, onClick: () -> Unit) {
                val item = bar.menu.add(Menu.NONE, Menu.NONE, bar.menu.size(), label)
                if (icon != 0) {
                    item.setIcon(icon)
                    MenuItemCompat.setIconTintList(item, iconTint())
                    MenuItemCompat.setContentDescription(item, label)
                    MenuItemCompat.setTooltipText(item, label)
                }
                item.setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
                item.setOnMenuItemClickListener {
                    onClick()
                    true
                }
            }

            override fun setInk(rgb: Int?) {
                ink = rgb?.let(::opaque)
                val title = ink ?: argb(context, R.attr.colorOnSurface)
                bar.setTitleTextColor(title)
                bar.setSubtitleTextColor(ink ?: argb(context, R.attr.colorOnSurfaceVariant))
                if (bar.navigationIcon != null) bar.setNavigationIconTint(title)
                for (index in 0 until bar.menu.size())
                    MenuItemCompat.setIconTintList(bar.menu.getItem(index), iconTint())
            }
        }
    }

    /**
     * Home destinations: a navigation bar on compact windows, a navigation rail from medium up.
     * The other destinations open their own screens, so the selection stays on [selected].
     */
    fun navigation(
        context: Context,
        style: NavStyle,
        items: List<NavItem>,
        selected: String,
        badges: Map<String, Int>,
        onSelect: (NavItem) -> Unit,
    ): View {
        val view: NavigationBarView = if (style == NavStyle.RAIL)
            NavigationRailView(context).apply { menuGravity = Gravity.CENTER }
        else BottomNavigationView(context)
        for ((index, item) in items.withIndex())
            view.menu.add(Menu.NONE, index + 1, index, item.label).setIcon(item.icon)
        view.labelVisibilityMode = NavigationBarView.LABEL_VISIBILITY_LABELED
        for ((index, item) in items.withIndex()) {
            val count = badges[item.id] ?: continue
            if (count > 0) view.getOrCreateBadge(index + 1).number = count
        }
        val current = items.indexOfFirst { it.id == selected }
        if (current >= 0) view.selectedItemId = current + 1
        ShellAppearance.accent?.first?.let {
            view.itemActiveIndicatorColor = ColorStateList.valueOf(
                opaque(blend(it, rgb(context, R.attr.colorSurface), 0.28f)),
            )
        }
        view.setOnItemSelectedListener { entry ->
            val item = items.getOrNull(entry.itemId - 1) ?: return@setOnItemSelectedListener false
            if (item.id == selected) true
            else {
                onSelect(item)
                false
            }
        }
        return view
    }

    // ---------- sheets and transient feedback ----------

    /** A modal bottom sheet, or a modal side sheet when [atSide]. */
    fun sheet(context: Context, atSide: Boolean, onDismiss: () -> Unit = {}): SheetHandle {
        val content = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            val pad = dp(context, 24)
            setPadding(pad, if (atSide) pad else dp(context, 8), pad, pad)
        }
        val dialog: AppCompatDialog = if (atSide) SideSheetDialog(context).apply {
            setContentView(content)
            // The library's modal side sheet is 256 dp wide; an editor needs the standard 360.
            findViewById<View>(R.id.m3_side_sheet)?.let { sheet ->
                sheet.layoutParams = sheet.layoutParams.apply { width = dp(context, SIDE_SHEET_DP) }
            }
        } else BottomSheetDialog(context).apply {
            setContentView(content)
            behavior.skipCollapsed = true
            setOnShowListener { behavior.state = BottomSheetBehavior.STATE_EXPANDED }
        }
        dialog.setOnDismissListener { onDismiss() }
        return object : SheetHandle {
            override val content: LinearLayout = content
            override val showing: Boolean get() = dialog.isShowing
            override fun show() { if (!dialog.isShowing) dialog.show() }
            override fun dismiss() { if (dialog.isShowing) dialog.dismiss() }
        }
    }

    /** The surface a safety confirmation opens on: a modal bottom sheet. */
    fun confirmSurface(context: Context, onDismiss: () -> Unit = {}): SheetHandle =
        sheet(context, atSide = false, onDismiss = onDismiss)

    /** Transient feedback: a snackbar on the screen's content, never a toast. */
    fun toast(activity: Activity, message: CharSequence, long: Boolean = false) {
        val anchor = activity.findViewById<View>(android.R.id.content)
        if (anchor == null || activity.isFinishing || !anchor.isAttachedToWindow) {
            Toast.makeText(activity.applicationContext, message,
                           if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT).show()
            return
        }
        Snackbar.make(anchor, message, if (long) Snackbar.LENGTH_LONG else Snackbar.LENGTH_SHORT)
            .show()
    }

    // ---------- administrator overrides on semantic IDs ----------

    private class ButtonStyle(
        val tint: ColorStateList?,
        val stroke: ColorStateList?,
        val strokeWidth: Int,
        val shape: com.google.android.material.shape.ShapeAppearanceModel,
    )

    /** The parts of a Material button an override may replace, so it can be undone exactly. */
    fun captureStyle(view: View): Any? = (view as? MaterialButton)?.let {
        ButtonStyle(it.backgroundTintList, it.strokeColor, it.strokeWidth, it.shapeAppearanceModel)
    }

    fun restoreStyle(view: View, saved: Any?): Boolean {
        val button = view as? MaterialButton ?: return false
        val style = saved as? ButtonStyle ?: return false
        button.backgroundTintList = style.tint
        button.strokeColor = style.stroke
        button.strokeWidth = style.strokeWidth
        button.shapeAppearanceModel = style.shape
        return true
    }

    /** The opaque container colour of a Material button, which a drawable sample cannot read. */
    fun fillRgb(view: View): Int? {
        val button = view as? MaterialButton ?: return null
        val color = button.backgroundTintList?.getColorForState(button.drawableState, 0) ?: return null
        return if (Color.alpha(color) == 255) color and 0xffffff else null
    }

    /**
     * Apply a validated override to a Material button through its own shape and tint, keeping
     * ripple, focus and elevation. Returns false for any other view, which the caller styles
     * with a background drawable.
     */
    fun applyStyle(
        view: View,
        fillArgb: Int?,
        borderArgb: Int?,
        accentArgb: Int?,
        radiusPx: Float?,
        borderPx: Float,
        accentPx: Float,
    ): Boolean {
        val button = view as? MaterialButton ?: return false
        if (fillArgb != null) button.backgroundTintList = ColorStateList.valueOf(fillArgb)
        if (radiusPx != null)
            button.shapeAppearanceModel = button.shapeAppearanceModel.withCornerSize(radiusPx)
        if (borderArgb != null || accentArgb != null) {
            val resting = borderArgb ?: Color.TRANSPARENT
            val active = accentArgb ?: resting
            button.strokeColor = ColorStateList(
                arrayOf(
                    intArrayOf(android.R.attr.state_pressed),
                    intArrayOf(android.R.attr.state_focused),
                    intArrayOf(),
                ),
                intArrayOf(active, active, resting),
            )
            button.strokeWidth = (if (accentArgb != null && borderArgb == null) accentPx
                                  else borderPx).toInt()
        }
        return true
    }

    private const val KEY_COMMIT_MS = 600L
    private const val SIDE_SHEET_DP = 360
}
