// Local bootstrap identity gate. It runs before Core/network startup whenever the
// explicit confirmation is missing, the role is invalid, or a door station has
// no valid door ID.
package jp.keihan.doorbell

import android.app.Activity
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast

class BootSetupActivity : Activity() {
    private lateinit var app: App
    private lateinit var role: Spinner
    private lateinit var door: EditText
    private lateinit var doorLabel: TextView
    private lateinit var doorHint: TextView
    private lateinit var name: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        if (!app.bootSetupRequired) {
            finish()
            return
        }
        setFinishOnTouchOutside(false)
        setContentView(buildUi())
    }

    private fun buildUi(): View {
        val pad = dp(24)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(pad, pad, pad, pad)
        }
        fun text(value: Int, size: Float = 16f) = TextView(this).apply {
            setText(value)
            textSize = size
        }
        root.addView(text(R.string.setup_title, 26f), lp())
        root.addView(text(R.string.setup_message).apply {
            setPadding(0, dp(16), 0, dp(16))
        }, lp())
        root.addView(text(R.string.setup_name), lp())
        name = EditText(this).apply {
            setText(app.boot.name)
            inputType = InputType.TYPE_CLASS_TEXT
            setSingleLine(true)
        }
        root.addView(name, lp())
        root.addView(text(R.string.setup_role).apply { setPadding(0, dp(12), 0, 0) }, lp())
        role = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@BootSetupActivity,
                android.R.layout.simple_spinner_dropdown_item,
                listOf(getString(R.string.admin_role_door), getString(R.string.admin_role_indoor)),
            )
            setSelection(if (app.boot.role == "indoor_panel") 1 else 0)
            onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
                override fun onNothingSelected(parent: android.widget.AdapterView<*>?) = Unit
                override fun onItemSelected(
                    parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long,
                ) {
                    if (::door.isInitialized) updateDoorVisibility(position == 0)
                }
            }
        }
        root.addView(role, lp())
        doorLabel = text(R.string.setup_door).apply { setPadding(0, dp(12), 0, 0) }
        root.addView(doorLabel, lp())
        door = EditText(this).apply {
            setText(app.boot.suggestedDoor)
            hint = getString(R.string.setup_door_hint)
            inputType = InputType.TYPE_CLASS_TEXT
            setSingleLine(true)
        }
        root.addView(door, lp())
        doorHint = text(R.string.setup_door_hint).apply { textSize = 13f }
        root.addView(doorHint, lp())
        root.addView(Button(this).apply {
            setText(R.string.setup_finish)
            setOnClickListener { save() }
            setPadding(0, dp(20), 0, 0)
        }, lp())
        updateDoorVisibility(role.selectedItemPosition == 0)
        return root
    }

    private fun updateDoorVisibility(isDoorStation: Boolean) {
        val visibility = if (isDoorStation) View.VISIBLE else View.GONE
        doorLabel.visibility = visibility
        door.visibility = visibility
        doorHint.visibility = visibility
    }

    private fun save() {
        val roleValue = if (role.selectedItemPosition == 0) "door_station" else "indoor_panel"
        val doorValue = door.text?.toString().orEmpty().trim()
        if (roleValue == "door_station" && !BootConfig.validDoor(doorValue)) {
            door.error = getString(R.string.setup_invalid_door)
            return
        }
        if (!app.completeBootSetup(name.text?.toString().orEmpty(), roleValue, doorValue)) {
            Toast.makeText(this, R.string.setup_invalid_door, Toast.LENGTH_LONG).show()
            return
        }
        finish()
    }

    private fun lp(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
    )

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
