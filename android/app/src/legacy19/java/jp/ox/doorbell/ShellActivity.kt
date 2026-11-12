// The legacy19 flavor's base activity: a plain framework Activity under the device theme.
package jp.ox.doorbell

import android.app.Activity
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import java.lang.ref.WeakReference

abstract class ShellActivity : Activity() {
    private var night = true

    override fun onCreate(savedInstanceState: Bundle?) {
        night = ShellAppearance.dark
        setTheme(themeFor(night))
        super.onCreate(savedInstanceState)
        live.add(WeakReference(this))
    }

    override fun onDestroy() {
        live.removeAll { it.get() == null || it.get() === this }
        super.onDestroy()
    }

    private fun switchAppearance(dark: Boolean) {
        if (dark == night || isFinishing) return
        night = dark
        // Views built from here on take the new theme; the window keeps its old background
        // until it is replaced.
        setTheme(themeFor(dark))
        window.setBackgroundDrawable(ColorDrawable(
            0xff000000.toInt() or PlatformUi.tokens(this).ground,
        ))
        onAppearanceChanged()
    }

    /**
     * Light/dark changed while this screen is open. The default rebuilds the screen; a screen that
     * must not lose its state overrides this.
     */
    protected open fun onAppearanceChanged() {
        recreate()
    }

    internal companion object {
        private val live = ArrayList<WeakReference<ShellActivity>>()

        fun themeFor(dark: Boolean): Int =
            if (dark) R.style.Theme_Doorbell else R.style.Theme_Doorbell_Light

        /** Main thread only. */
        fun applyAppearance(dark: Boolean) {
            for (reference in ArrayList(live)) reference.get()?.switchAppearance(dark)
        }
    }
}
