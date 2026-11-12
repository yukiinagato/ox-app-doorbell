// The application-wide appearance: light or dark as Core resolves it, and Core's accent.
//
// Core publishes display.appearance.effective (follow_system defers to the platform setting) and
// the accent it computed for the theme. Every screen reports what it read through [resolve]; the
// flavor then switches its theme (AppCompat night mode on modern, the DeviceDefault light/dark
// theme on legacy19) and the screens rebuild from the platform's own colours.
package jp.ox.doorbell

import android.app.Activity
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Handler
import android.os.Looper
import org.json.JSONObject

internal object ShellAppearance {
    private const val PREFS = "shell_appearance"
    private const val KEY_DARK = "dark"

    private val main = Handler(Looper.getMainLooper())
    private var loaded = false

    /** The appearance every new screen starts in. */
    var dark = true
        private set

    /** The administrator's accent as (fill, ink), or null to keep the platform's primary. */
    var accent: Pair<Int, Int>? = null
        private set

    /** Restore the last appearance so the first screen does not start in the wrong one. */
    fun load(context: Context) {
        if (loaded) return
        loaded = true
        dark = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_DARK, true)
        PlatformUi.applyNightMode(dark)
    }

    /**
     * The platform's own dark setting, or null where it has none (before Android 10). Read from
     * the system resources: an activity's configuration already carries the mode this app forced.
     */
    fun systemDark(): Boolean? {
        if (android.os.Build.VERSION.SDK_INT < 29) return null
        return when (Resources.getSystem().configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) {
            Configuration.UI_MODE_NIGHT_YES -> true
            Configuration.UI_MODE_NIGHT_NO -> false
            else -> null
        }
    }

    /**
     * Report what a screen just read from Core and get the colour tokens to paint with. Core's
     * resolved appearance wins; an older Core falls back to the local schedule computation.
     */
    fun resolve(
        activity: Activity,
        status: JSONObject?,
        config: JSONObject?,
        minuteOfDay: Int,
    ): Palette {
        val display = CoreDisplays.parse(status?.optJSONObject("display"))
        val nodeId = status?.optJSONObject("node")?.optString("id").orEmpty()
        val appearance = display.appearance
        val next = when {
            appearance != null -> CoreDisplays.isDark(appearance, systemDark())
            status == null && config == null -> dark
            else -> Appearance.resolve(config, nodeId, systemDark(), minuteOfDay).dark
        }
        // Only a call-button colour the administrator chose may become the primary role; the
        // accent Core computes from the wallpaper stays on the door station's Call button.
        val chosen = UiContrast.parseRgb(
            SettingsModel.dig(config, "devices.$nodeId.local.theme.call_button_bg")?.toString(),
        ) ?: UiContrast.parseRgb(
            SettingsModel.dig(config, "display.theme.call_button_bg")?.toString(),
        )
        update(activity, next, ColorRoles.primary(chosen, PlatformUi.tokens(activity).ground),
               accentKnown = config != null)
        return PlatformUi.tokens(activity)
    }

    private fun update(context: Context, nextDark: Boolean, nextAccent: Pair<Int, Int>?,
                       accentKnown: Boolean) {
        if (accentKnown) accent = nextAccent
        if (nextDark == dark) return
        dark = nextDark
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_DARK, nextDark).apply()
        // Posted: switching reconfigures or rebuilds the calling screen, which must not happen
        // while it is in the middle of reading its own state.
        main.post { PlatformUi.applyNightMode(dark) }
    }
}
