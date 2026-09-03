// The appearance and automatic-theme decisions core publishes (spec §5, §5.1, §5.2).
//
// Core resolves the light/dark appearance from the schedule in the cluster time zone and computes
// the automatic ink and the call-button colour once, on the node that serves the theme, so every
// shell in the cluster draws the same thing instead of each deriving its own. This file adapts
// status.display (and the identical {"t":"display"} event) into the values the screens paint, and
// falls back to the local computation only when an older core publishes none of it.
//
// display.theme.auto_ink and auto_accent are computed, never stored: core rejects writes to them.
package jp.ox.doorbell

import org.json.JSONObject

/** display.appearance as core resolves it. */
internal data class CoreAppearance(
    val configured: String,
    val effective: String,
    /** True for auto_system: the shell uses the platform setting and falls back to [effective]. */
    val followSystem: Boolean,
    val darkFrom: String,
    val lightFrom: String,
) {
    val effectiveDark: Boolean get() = effective == "dark"
}

/** display.theme with the automatic decisions and the administrator's overrides folded in. */
internal data class CoreTheme(
    /** The colour actually behind the screen, averaged by core when the background is an image. */
    val backgroundRgb: Int?,
    /**
     * "color", "image", or "image_unsampled" when core declined to average the picture (it caps
     * the pixels it will decode). An older core reported "color" in that last case, which is why
     * this value alone must never be taken as proof that the background is a flat colour.
     */
    val backgroundSource: String,
    /** Why core did not sample, when it says so. Diagnostic only. */
    val backgroundUnsampledReason: String,
    /** display.theme.bg_image: the authoritative signal that the background is a picture. */
    val backgroundImage: String,
    /**
     * display.theme.backdrop: the overlay composited over that picture. Null when core does not
     * publish the field, which is the signal to keep the overlay this shell has always drawn.
     */
    val backdrop: BackdropOverlay?,
    /** Numeric radius used only by shells that advertise frosted_glass_radius_v1. */
    val glassBlurRadius: Int = 32,
    /** Per region: true for the light ink token, false for the dark one. */
    val ink: Map<String, Boolean>,
    /** Only the regions an administrator overrode, as explicit colours. */
    val inkOverride: Map<String, Int>,
    /** What to paint on the call button, override already applied by core. */
    val callButtonBg: Int?,
    /** What to draw on it. Never re-derive this: core returns the best compromise. */
    val callButtonInkLight: Boolean,
) {
    /** True when a background image is configured, whatever core managed to make of it. */
    val hasBackgroundImage: Boolean get() = backgroundImage.isNotEmpty()

    /** True when core actually averaged the picture rather than declining to. */
    val imageSampledByCore: Boolean get() = backgroundSource == "image"
}

internal data class CoreDisplay(val appearance: CoreAppearance?, val theme: CoreTheme?)

internal object CoreDisplays {

    /** The semantic regions core publishes an automatic ink decision for. */
    val INK_REGIONS = listOf(
        "clock", "date", "status_line", "hint", "tile_label", "footer", "notice",
    )

    /** Parse status.display, or the display event, into what the screens need. Never throws. */
    fun parse(display: JSONObject?): CoreDisplay {
        if (display == null) return CoreDisplay(null, null)
        return CoreDisplay(parseAppearance(display), parseTheme(display))
    }

    internal fun parseAppearance(display: JSONObject): CoreAppearance? {
        val appearance = display.optJSONObject("appearance") ?: return null
        val effective = appearance.optString("effective")
        if (effective.isEmpty()) return null
        val schedule = appearance.optJSONObject("schedule")
        return CoreAppearance(
            configured = appearance.optString("configured").ifEmpty { "auto_system" },
            effective = effective,
            followSystem = appearance.optBoolean("follow_system", false),
            darkFrom = schedule?.optString("dark_from").orEmpty().ifEmpty { "19:00" },
            lightFrom = schedule?.optString("light_from").orEmpty().ifEmpty { "06:30" },
        )
    }

    internal fun parseTheme(display: JSONObject): CoreTheme? {
        val theme = display.optJSONObject("theme") ?: return null
        val automatic = theme.optJSONObject("auto_background")
        val background = UiContrast.parseRgb(automatic?.optString("color"))
            ?: UiContrast.parseRgb(theme.optString("bg_color"))
        val inkValues = theme.optJSONObject("auto_ink")
        val ink = HashMap<String, Boolean>(INK_REGIONS.size)
        if (inkValues != null) for (region in INK_REGIONS) {
            val value = inkValues.optString(region)
            if (value.isNotEmpty()) ink[region] = value == "light"
        }
        val overrides = HashMap<String, Int>()
        theme.optJSONObject("ink_override")?.let { document ->
            val keys = document.keys()
            while (keys.hasNext()) {
                val region = keys.next()
                UiContrast.parseRgb(document.optString(region))?.let { overrides[region] = it }
            }
        }
        val accent = theme.optJSONObject("auto_accent")
        val callButton = UiContrast.parseRgb(theme.optString("call_button_bg"))
            ?: UiContrast.parseRgb(accent?.optString("call_button"))
        val callButtonInk = theme.optString("call_button_ink")
            .ifEmpty { accent?.optString("call_button_ink").orEmpty() }
        // bg_image is JSON null when there is none, which optString renders as "null".
        val image = theme.optString("bg_image").takeIf {
            it.isNotEmpty() && it != "null" && !theme.isNull("bg_image")
        }.orEmpty()
        val backdrop = BackdropOverlay.parse(theme.optJSONObject("backdrop"))
        val glassBlurRadius = theme.optJSONObject("glass")
            ?.optInt("blur_radius", 32)?.coerceIn(0, 40) ?: 32
        if (background == null && ink.isEmpty() && callButton == null && image.isEmpty() &&
            backdrop == null)
            return null
        return CoreTheme(
            backgroundRgb = background,
            backgroundSource = automatic?.optString("source").orEmpty(),
            backgroundUnsampledReason = automatic?.optString("reason").orEmpty(),
            backgroundImage = image,
            backdrop = backdrop,
            glassBlurRadius = glassBlurRadius,
            ink = ink,
            inkOverride = overrides,
            callButtonBg = callButton,
            // An absent token means the light ink token, which is what core defaults to.
            callButtonInkLight = callButtonInk != "dark",
        )
    }

    /**
     * Whether the dark palette applies. Core has already resolved the schedule in the cluster time
     * zone, so the shell only supplies the platform's own setting for auto_system and falls back
     * to core's answer when the platform has none (Android before 10).
     */
    fun isDark(appearance: CoreAppearance, systemDark: Boolean?): Boolean =
        if (appearance.followSystem) systemDark ?: appearance.effectiveDark
        else appearance.effectiveDark

    /**
     * The ink for one region: an administrator override wins, then the rule for the kind of
     * background actually on screen.
     *
     * [sampledBackgroundRgb] is what the shell measured under this particular region, and
     * [imageDrawnLocally] says whether this shell is currently painting the background image.
     * Core's per-region ink is authoritative only for a flat colour; whenever a picture is on
     * screen the local sample decides, because core averages the whole image and may not have
     * averaged it at all.
     */
    fun inkFor(
        theme: CoreTheme?,
        region: String,
        fallbackBackgroundRgb: Int,
        sampledBackgroundRgb: Int? = null,
        imageDrawnLocally: Boolean = false,
        knownSurface: Boolean = false,
        sample: RegionSample? = null,
    ): RegionInkResult {
        val kind = if (knownSurface) BackgroundKind.KNOWN_SURFACE
            else backgroundKind(theme, imageDrawnLocally)
        // Core's measured colour describes the theme background, so it is the right fallback
        // while that is what is on screen -- the flat colour itself, or the picture being drawn.
        // A surface the shell painted, and a picture that has not loaded, are neither.
        val fallback = when (kind) {
            BackgroundKind.FLAT_COLOUR -> theme?.backgroundRgb ?: fallbackBackgroundRgb
            // Core averages the picture as it was uploaded; the overlay goes on afterwards. A
            // region the shell could not sample must still be judged against what is on screen,
            // or a bright wallpaper under a heavy overlay takes dark ink on a dark ground.
            BackgroundKind.IMAGE_DRAWN -> ThemeBackdrop.under(
                theme?.backgroundRgb ?: fallbackBackgroundRgb,
                theme?.backdrop ?: BackdropOverlay.LEGACY,
            )
            BackgroundKind.IMAGE_NOT_DRAWN, BackgroundKind.KNOWN_SURFACE -> fallbackBackgroundRgb
        }
        return RegionInkPolicy.resolve(
            override = theme?.inkOverride?.get(region),
            coreInkLight = theme?.ink?.get(region),
            background = kind,
            sampledBackgroundRgb = sampledBackgroundRgb,
            fallbackBackgroundRgb = fallback,
            sample = sample,
        )
    }

    /**
     * Which rule applies. display.theme.bg_image is the signal, never auto_background.source: a
     * core that declined to sample a large picture reported "color" for it, and a shell that
     * trusted that painted light text onto a light photograph.
     */
    fun backgroundKind(theme: CoreTheme?, imageDrawnLocally: Boolean): BackgroundKind = when {
        theme == null -> if (imageDrawnLocally) BackgroundKind.IMAGE_DRAWN
            else BackgroundKind.FLAT_COLOUR
        !theme.hasBackgroundImage && !imageDrawnLocally -> BackgroundKind.FLAT_COLOUR
        imageDrawnLocally -> BackgroundKind.IMAGE_DRAWN
        // Configured but not on screen: the flat colour is what a visitor is looking at.
        else -> BackgroundKind.IMAGE_NOT_DRAWN
    }

    /**
     * The call button's background and its text colour. Core's answer already carries the
     * administrator override; only an older core makes the shell recompute both locally.
     */
    fun callButton(theme: CoreTheme?, fallbackBackgroundRgb: Int): Pair<Int, Int> {
        val background = theme?.callButtonBg
        if (background != null) {
            val ink = if (theme.callButtonInkLight) 0xFFFFFF else 0x111111
            return background to ink
        }
        val computed = UiContrast.autoAccent(fallbackBackgroundRgb)
        return computed to UiContrast.callButtonInk(computed)
    }
}
