// Layout decisions shared by every Android screen (docs/en/ui-guidelines.md).
//
// Everything here is pure: a screen asks for its arrangement from the current window size and
// text scale, and the answer is host-tested. Screens re-ask on every configuration change, so a
// rotation or a multi-window resize switches layout live rather than by device model.
package jp.ox.doorbell

/** Guidelines section 2: chosen from the window width, never from the device model. */
internal enum class SizeClass {
    COMPACT, MEDIUM, EXPANDED;

    companion object {
        fun fromWidthDp(widthDp: Int): SizeClass = when {
            widthDp >= 900 -> EXPANDED
            widthDp >= 600 -> MEDIUM
            else -> COMPACT
        }
    }
}

/** Where a screen's fixed action zone sits (guidelines principle 3). */
internal enum class ActionEdge { BOTTOM, END }

/** How secondary destinations (History, Monitor, Settings) are reached from the home screen. */
internal enum class NavStyle { BOTTOM_TABS, RAIL }

/** Guidelines section 3: the shared visual tokens, in dp/sp. */
internal object UiTokens {
    const val SPACE_XS = 4
    const val SPACE_S = 8
    const val SPACE_M = 12
    const val SPACE_L = 16
    const val SPACE_XL = 24
    const val SPACE_XXL = 32
    const val SPACE_XXXL = 48

    const val TOUCH_MIN_DP = 48
    const val VISITOR_TOUCH_MIN_DP = 72

    const val RADIUS_CARD = 12
    const val RADIUS_PILL = 999
    const val RADIUS_SHEET = 20

    /** Body text; the type scale multiplies this. */
    const val BODY_SP = 16f
    const val CAPTION = 0.8f
    const val BODY = 1.0f
    const val TITLE = 1.25f
    const val HEADLINE = 1.6f
    const val DISPLAY = 2.2f

    fun sp(scale: Float): Float = BODY_SP * scale

    const val MOTION_MS = 200L

    /** Overlay controls on live video hide after this long without a touch. */
    const val OVERLAY_HIDE_MS = 4_000L
}

/** One window: what every screen needs to choose an arrangement. */
internal data class WindowSpec(
    val widthDp: Int,
    val heightDp: Int,
    /** Configuration.fontScale; 2.0 is the 200 % acceptance case. */
    val fontScale: Float = 1f,
) {
    val sizeClass: SizeClass get() = SizeClass.fromWidthDp(widthDp)
    val landscape: Boolean get() = widthDp > heightDp
    /** Large text: at or above 150 % the layouts give text more room. */
    val largeText: Boolean get() = fontScale >= 1.5f
}

internal object ScreenLayouts {

    /** Visitor purpose grid: 2 compact, 3 medium, 4 expanded; one column less at large text. */
    fun purposeColumns(window: WindowSpec): Int {
        val base = when (window.sizeClass) {
            SizeClass.COMPACT -> 2
            SizeClass.MEDIUM -> 3
            SizeClass.EXPANDED -> 4
        }
        return if (window.largeText) maxOf(1, base - 1) else base
    }

    /** Dashboard door tiles: 1 compact, 2 medium, 3 expanded (4 when very wide). */
    fun tileColumns(window: WindowSpec, tileCount: Int): Int {
        val base = when (window.sizeClass) {
            SizeClass.COMPACT -> 1
            SizeClass.MEDIUM -> 2
            SizeClass.EXPANDED -> if (window.widthDp >= 1280 && !window.largeText) 4 else 3
        }
        val fitted = if (window.largeText && base > 1) base - 1 else base
        return fitted.coerceIn(1, maxOf(1, tileCount))
    }

    /** Navigation: bottom tabs on compact, a navigation rail from medium up. */
    fun navStyle(window: WindowSpec): NavStyle =
        if (window.sizeClass == SizeClass.COMPACT) NavStyle.BOTTOM_TABS else NavStyle.RAIL

    /**
     * Incoming call: video on top with actions below in portrait; video left (at least 60 %)
     * with details and actions in a right column on landscape or expanded windows.
     */
    fun incomingSideBySide(window: WindowSpec): Boolean =
        window.landscape && window.sizeClass != SizeClass.COMPACT

    /** Share of the width the video gets when side by side: 60 %, 65 % on very wide windows. */
    fun incomingVideoFraction(window: WindowSpec): Float =
        if (window.widthDp >= 1200) 0.65f else 0.6f

    /** Fixed action zone placement: right edge only when the screen is side by side. */
    fun actionEdge(sideBySide: Boolean): ActionEdge =
        if (sideBySide) ActionEdge.END else ActionEdge.BOTTOM

    /** Quick replies: a bottom sheet on compact, a side sheet otherwise. */
    fun replySheetAtSide(window: WindowSpec): Boolean = window.sizeClass != SizeClass.COMPACT

    /** History and live view: list/detail or side door list from medium up. */
    fun historyTwoPane(window: WindowSpec): Boolean = window.sizeClass != SizeClass.COMPACT

    fun monitorSideList(window: WindowSpec): Boolean = window.sizeClass == SizeClass.EXPANDED

    /** Visitor call button height: the 72 dp visitor floor, taller on expanded windows. */
    fun visitorActionHeightDp(window: WindowSpec): Int = when {
        window.sizeClass == SizeClass.EXPANDED -> 96
        window.largeText -> 88
        else -> UiTokens.VISITOR_TOUCH_MIN_DP
    }

    /**
     * Touch target for a control: the platform floor, scaled with text so a 200 % label never
     * overflows its button.
     */
    fun touchTargetDp(window: WindowSpec, floorDp: Int = UiTokens.TOUCH_MIN_DP): Int =
        maxOf(floorDp, (floorDp * minOf(window.fontScale, 2f) * 0.75f).toInt())

    /**
     * How many secondary actions fit in one row of the action zone before wrapping to a second
     * row: four on expanded, three otherwise, two at large text on compact.
     */
    fun secondaryPerRow(window: WindowSpec): Int = when {
        window.sizeClass == SizeClass.EXPANDED -> 4
        window.sizeClass == SizeClass.COMPACT && window.largeText -> 2
        else -> 3
    }

    /** Split [items] into rows of at most [perRow], keeping their order. */
    fun <T> rows(items: List<T>, perRow: Int): List<List<T>> =
        if (perRow <= 0) listOf(items) else items.chunked(perRow)
}

/**
 * Semantic colour roles (guidelines section 3). Surface, ink, and accent come from Core's display
 * regions when it publishes them (theme ink, automatic accent, call-button colour); the palette
 * supplies the rest, so nothing a region provides is hard-coded in a screen.
 */
internal data class UiRoles(
    val ground: Int,
    val surface: Int,
    val onSurface: Int,
    val muted: Int,
    val line: Int,
    val accent: Int,
    val onAccent: Int,
    val positive: Int,
    val onPositive: Int,
    val negative: Int,
    val onNegative: Int,
    val warning: Int,
    val onWarning: Int,
) {
    companion object {
        fun from(palette: Palette, coreAccent: Pair<Int, Int>? = null): UiRoles = UiRoles(
            ground = palette.ground,
            surface = palette.surface,
            onSurface = palette.ink,
            muted = palette.muted,
            line = palette.line,
            accent = coreAccent?.first ?: palette.accent,
            onAccent = coreAccent?.second ?: palette.accentInk,
            positive = palette.positive,
            onPositive = palette.onPositive,
            negative = palette.danger,
            onNegative = palette.onNegative,
            warning = palette.warning,
            onWarning = palette.onWarning,
        )
    }
}

/** The role a control takes; the same action keeps the same role on every screen. */
internal enum class ActionRole { PRIMARY, POSITIVE, NEGATIVE, SECONDARY, WARNING }

internal fun UiRoles.fill(role: ActionRole): Int = when (role) {
    ActionRole.PRIMARY -> accent
    ActionRole.POSITIVE -> positive
    ActionRole.NEGATIVE -> negative
    ActionRole.WARNING -> warning
    ActionRole.SECONDARY -> surface
}

internal fun UiRoles.ink(role: ActionRole): Int = when (role) {
    ActionRole.PRIMARY -> onAccent
    ActionRole.POSITIVE -> onPositive
    ActionRole.NEGATIVE -> onNegative
    ActionRole.WARNING -> onWarning
    ActionRole.SECONDARY -> onSurface
}

/** Ink for an icon or glyph in [role] drawn straight on a surface: the fill, or muted for secondary. */
internal fun UiRoles.tint(role: ActionRole): Int = if (role == ActionRole.SECONDARY) muted else fill(role)
