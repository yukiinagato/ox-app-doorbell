// Local bootstrap identity gate. It runs before Core/network startup whenever the
// explicit confirmation is missing, the role is invalid, or a door station has
// no valid door ID.
package jp.ox.doorbell

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView

class BootSetupActivity : ShellActivity() {

    /** Typed but unsaved identity fields must survive an appearance flip. */
    override fun onAppearanceChanged() = Unit

    private lateinit var app: App
    private var doorStation = true
    private lateinit var door: FieldHandle
    private lateinit var doorLabel: TextView
    private lateinit var doorHint: TextView
    private lateinit var name: FieldHandle

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        // The maintenance menu reopens this screen deliberately, even once setup is complete.
        if (!app.bootSetupRequired && !intent.getBooleanExtra(EXTRA_REENTRY, false)) {
            finish()
            return
        }
        setFinishOnTouchOutside(false)
        setContentView(buildUi())
    }

    private fun buildUi(): View {
        val pad = dp(24)
        val tokens = PlatformUi.tokens(this)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }
        root.addView(ShellUi.label(this, getString(R.string.setup_title), TextRole.HEADLINE), lp())
        root.addView(ShellUi.label(this, getString(R.string.setup_message), TextRole.BODY,
                                   tokens.muted).apply {
            setPadding(0, dp(12), 0, dp(20))
        }, lp())
        name = PlatformUi.field(this, getString(R.string.setup_name), app.boot.name)
        root.addView(name.view, lp())
        root.addView(ShellUi.label(this, getString(R.string.setup_role), TextRole.LABEL).apply {
            setPadding(0, dp(16), 0, dp(4))
        }, lp())
        doorStation = app.boot.role != "indoor_panel"
        val role = PlatformUi.segmented(this, listOf(
            ROLE_DOOR to getString(R.string.admin_role_door),
            ROLE_INDOOR to getString(R.string.admin_role_indoor),
        ), onPick = { picked ->
            doorStation = picked == ROLE_DOOR
            if (::door.isInitialized) updateDoorVisibility(doorStation)
        })
        role.select(if (doorStation) ROLE_DOOR else ROLE_INDOOR)
        root.addView(role.view, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        doorLabel = ShellUi.label(this, "", TextRole.LABEL).apply { visibility = View.GONE }
        door = PlatformUi.field(this, getString(R.string.setup_door), app.boot.suggestedDoor)
        root.addView(door.view, lp().apply { topMargin = dp(16) })
        doorHint = ShellUi.label(this, getString(R.string.setup_door_hint), TextRole.SUPPORTING)
            .apply { setPadding(dp(16), dp(4), dp(16), 0) }
        root.addView(doorHint, lp())
        root.addView(PlatformUi.button(this, ButtonKind.FILLED).apply {
            setText(R.string.setup_finish)
            minHeight = dp(56)
            minimumHeight = dp(56)
            setOnClickListener { save() }
        }, lp().apply { topMargin = dp(24) })
        updateDoorVisibility(doorStation)
        // One reading column, centred on a wide window.
        val column = android.widget.FrameLayout(this)
        column.addView(root, android.widget.FrameLayout.LayoutParams(
            minOf(resources.displayMetrics.widthPixels, dp(UiTokens.MAX_CONTENT_DP)),
            ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_HORIZONTAL,
        ))
        return android.widget.ScrollView(this).apply {
            setBackgroundColor(ShellUi.opaque(tokens.ground))
            addView(column)
        }
    }

    private fun updateDoorVisibility(isDoorStation: Boolean) {
        val visibility = if (isDoorStation) View.VISIBLE else View.GONE
        door.view.visibility = visibility
        doorHint.visibility = visibility
    }

    private fun save() {
        val roleValue = if (doorStation) ROLE_DOOR else ROLE_INDOOR
        val doorValue = door.text.trim()
        if (roleValue == "door_station" && !BootConfig.validDoor(doorValue)) {
            door.setError(getString(R.string.setup_invalid_door))
            return
        }
        if (!app.completeBootSetup(name.text, roleValue, doorValue)) {
            PlatformUi.toast(this, getString(R.string.setup_invalid_door), long = true)
            return
        }
        finish()
    }

    private fun lp(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
    )

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val EXTRA_REENTRY = "reentry"
        private const val ROLE_DOOR = "door_station"
        private const val ROLE_INDOOR = "indoor_panel"

        /** Open the identity gate again from the maintenance menu. */
        fun reentryIntent(activity: Activity): android.content.Intent =
            android.content.Intent(activity, BootSetupActivity::class.java)
                .putExtra(EXTRA_REENTRY, true)
    }
}
