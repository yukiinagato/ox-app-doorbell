// The modern flavor's base activity: an AppCompat host for Material Components.
package jp.ox.doorbell

import android.content.res.Configuration
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.view.View
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import com.google.android.material.color.MaterialColors

abstract class ShellActivity : AppCompatActivity() {
    private var night = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        night = PlatformUi.isDark(this)
    }

    override fun setContentView(view: View?) {
        super.setContentView(view)
        fitSystemBars()
    }

    override fun setContentView(layoutResID: Int) {
        super.setContentView(layoutResID)
        fitSystemBars()
    }

    /**
     * Android 15 draws every window edge to edge. The content takes the system bars, the display
     * cutout and the keyboard as padding, and the window background shows behind the bars.
     */
    private fun fitSystemBars() {
        val content = findViewById<View>(android.R.id.content) ?: return
        ViewCompat.setOnApplyWindowInsetsListener(content) { target, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout() or
                    WindowInsetsCompat.Type.ime(),
            )
            target.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            WindowInsetsCompat.CONSUMED
        }
    }

    /**
     * Every activity declares uiMode in configChanges, so AppCompat reconfigures the resources in
     * place when Core's appearance flips and reports it here instead of recreating the activity.
     */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val next = newConfig.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        if (next == night) return
        night = next
        val background = MaterialColors.getColor(this, android.R.attr.colorBackground, 0)
        window.setBackgroundDrawable(ColorDrawable(background))
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = !next
            isAppearanceLightNavigationBars = !next
        }
        onAppearanceChanged()
    }

    /**
     * Light/dark changed while this screen is open. The default rebuilds the screen; a screen that
     * must not lose its state overrides this.
     */
    protected open fun onAppearanceChanged() {
        recreate()
    }
}
