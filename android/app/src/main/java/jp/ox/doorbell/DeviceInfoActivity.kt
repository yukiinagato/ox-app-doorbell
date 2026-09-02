// 本機情報 / Debug — the diagnostics screen behind the admin password.
//
// It is a port of the iOS DebugInfoViewController: bounded Core snapshots only. Secrets, the
// pre-shared key, and the persisted boot JSON are deliberately never rendered.
package jp.ox.doorbell

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

class DeviceInfoActivity : Activity() {

    private lateinit var app: App
    private lateinit var texts: Texts
    private val ui = Handler(Looper.getMainLooper())
    private lateinit var bodyView: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as App
        texts = Texts(this)
        texts.setConfig(if (app.coreOk) app.core.config() else null)
        texts.setLang(app.boot.uiLang)
        setContentView(buildUi())
        refresh()
    }

    /** Core snapshots take locks on the run loop, so they are collected off the main thread. */
    private fun refresh() {
        Thread {
            val status = if (app.coreOk) app.core.status() else null
            val debug = if (app.coreOk) app.core.debugInfo() else null
            val capabilities = if (app.coreOk) app.core.capabilities() else null
            val config = if (app.coreOk) app.core.config() else null
            val text = render(status, debug, capabilities, config)
            ui.post {
                texts.setConfig(config)
                bodyView.text = text
            }
        }.apply { name = "doorbell-debug-info" }.start()
    }

    private fun render(
        status: JSONObject?,
        debug: JSONObject?,
        capabilities: JSONObject?,
        config: JSONObject?,
    ): String {
        val node = status?.optJSONObject("node")
        val device = debug?.optJSONObject("device")
        val runtime = status?.optJSONObject("runtime")
        val sip = status?.optJSONObject("sip")
        val out = StringBuilder()

        out.append(
            lines(
                line("info.node", R.string.info_node,
                     "${text(node?.optString("name"), app.boot.name)} " +
                         "(${text(node?.optString("id"), "-")})"),
                line("info.role", R.string.info_role,
                     text(node?.optString("role"), app.boot.role)),
                line("info.version", R.string.info_version,
                     "App ${appVersion()} · Core ${text(node?.optString("version"),
                         text(debug?.optString("version"), "-"))}"),
                line("info.microphone", R.string.info_microphone,
                     bool(capabilities?.opt("microphone"))),
                line("info.camera", R.string.info_camera, bool(capabilities?.opt("camera"))),
            ),
        )

        out.append(
            section(
                "info.device", R.string.info_device,
                line("info.system", R.string.info_system,
                     "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})"),
                line("info.model", R.string.info_model,
                     "${Build.MANUFACTURER} ${Build.MODEL}"),
                line("info.machine", R.string.info_machine, "${Build.DEVICE} / ${Build.HARDWARE}"),
                line("info.memory", R.string.info_memory, memory()),
                line("info.uptime", R.string.info_uptime, uptime()),
                line("info.battery", R.string.info_battery, battery(device)),
            ),
        )

        val directPort = (app.core.dig(config, "sip.direct_port") as? Number)?.toInt() ?: 47190
        out.append(
            section(
                "info.ports", R.string.info_ports,
                "http : ${app.boot.httpPort}",
                "mesh : 47172",
                "sip  : $directPort " + texts.t("info.sip_direct", R.string.info_sip_direct),
            ),
        )

        val triggers = debug?.optJSONObject("triggers")
        if (triggers != null) {
            val last = triggers.optJSONObject("last")
            out.append(
                section(
                    "info.triggers", R.string.info_triggers,
                    line("info.total_press", R.string.info_total_press,
                         triggers.optLong("total_press", 0).toString()),
                    line(
                        "info.last_press", R.string.info_last_press,
                        if (last == null) texts.t("info.no_press", R.string.info_no_press)
                        else "${timestamp(last.optLong("wall_ms", 0))} " +
                            "door=${text(last.optString("door"), "-")}",
                    ),
                ),
            )
        }

        out.append(
            section(
                "info.runtime", R.string.info_runtime,
                "safe_mode : " + bool(runtime?.opt("safe_mode")),
                "last_exit : " + text(runtime?.optString("last_exit_reason"),
                                      texts.t("info.unknown", R.string.info_unknown)),
                "heartbeat : " + timestamp(runtime?.optLong("heartbeat_ms", 0) ?: 0),
                "sip       : " + text(sip?.optString("state"),
                                      texts.t("info.unknown", R.string.info_unknown)),
            ),
        )

        runtime?.optJSONObject("components")?.let { components ->
            val keys = components.keys().asSequence().sorted().toList()
            if (keys.isNotEmpty()) {
                out.append(
                    section(
                        "info.components", R.string.info_components,
                        *keys.map { "$it : ${flatten(components.opt(it))}" }.toTypedArray(),
                    ),
                )
            }
        }

        if (capabilities != null && capabilities.length() > 0) {
            val wanted = listOf(
                "sip_backend", "camera", "microphone", "h264_encode", "h264_decode", "sip",
                "tls12", "wan",
            )
            val rows = ArrayList<String>()
            for (key in wanted) {
                if (capabilities.has(key)) rows.add("$key : ${flatten(capabilities.opt(key))}")
            }
            capabilities.optJSONObject("features")?.let { features ->
                val enabled = features.keys().asSequence().filter { features.optBoolean(it) }
                    .sorted().toList()
                rows.add(
                    "features : " + if (enabled.isEmpty())
                        texts.t("info.no_data", R.string.info_no_data)
                    else enabled.joinToString(", "),
                )
            }
            if (rows.isNotEmpty()) {
                out.append(
                    section("info.capabilities", R.string.info_capabilities,
                            *rows.toTypedArray()),
                )
            }
        }

        val peers = status?.optJSONArray("peers")
        val peerRows = peerLines(peers)
        out.append(
            section(
                "info.peers", R.string.info_peers,
                *(if (peerRows.isEmpty())
                    arrayOf(texts.t("info.no_data", R.string.info_no_data))
                else peerRows.toTypedArray()),
            ),
        )

        out.append(
            section(
                "info.active_calls", R.string.info_active_calls,
                (status?.optJSONArray("active_calls")?.length() ?: 0).toString(),
            ),
        )

        val addresses = ArrayList<String>()
        collect(node?.optJSONArray("local_addrs"), addresses)
        collect(debug?.optJSONArray("addresses"), addresses)
        out.append(
            section(
                "info.addresses", R.string.info_addresses,
                *(if (addresses.isEmpty())
                    arrayOf(texts.t("info.no_address", R.string.info_no_address))
                else addresses.distinct().sorted().toTypedArray()),
            ),
        )
        return out.toString().trimEnd()
    }

    private fun peerLines(peers: JSONArray?): List<String> {
        if (peers == null) return emptyList()
        val rows = ArrayList<String>(peers.length())
        for (i in 0 until peers.length()) {
            val peer = peers.optJSONObject(i) ?: continue
            val name = text(peer.optString("name"), text(peer.optString("id"), "-"))
            rows.add("$name : ${text(peer.optString("status"), "-")} / " +
                text(peer.optString("role"), "-"))
        }
        return rows.sorted()
    }

    private fun collect(array: JSONArray?, into: MutableList<String>) {
        if (array == null) return
        for (i in 0 until array.length()) {
            array.optString(i).takeIf { it.isNotEmpty() }?.let(into::add)
        }
    }

    private fun lines(vararg rows: String): String = rows.joinToString("\n") + "\n\n"

    private fun section(key: String, resId: Int, vararg rows: String): String {
        if (rows.isEmpty()) return ""
        return "── " + texts.t(key, resId) + " ──\n" + rows.joinToString("\n") + "\n\n"
    }

    private fun line(key: String, resId: Int, value: String): String =
        texts.t(key, resId) + " : " + value

    private fun text(value: String?, fallback: String): String =
        if (value.isNullOrEmpty() || value == "null") fallback else value

    private fun bool(value: Any?): String = when (value) {
        null -> texts.t("info.unknown", R.string.info_unknown)
        is Boolean -> if (value) texts.t("admin.enabled", R.string.admin_enabled)
            else texts.t("admin.disabled", R.string.admin_disabled)
        is Number -> if (value.toInt() != 0) texts.t("admin.enabled", R.string.admin_enabled)
            else texts.t("admin.disabled", R.string.admin_disabled)
        else -> flatten(value)
    }

    private fun flatten(value: Any?): String = when (value) {
        null -> "-"
        is Boolean -> if (value) "true" else "false"
        else -> value.toString()
    }

    private fun appVersion(): String = try {
        val info = packageManager.getPackageInfo(packageName, 0)
        @Suppress("DEPRECATION")
        "${info.versionName} (${info.versionCode})"
    } catch (_: Exception) {
        "-"
    }

    private fun memory(): String = try {
        val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        manager.getMemoryInfo(info)
        val total = info.totalMem.toDouble()
        val available = info.availMem.toDouble()
        String.format(Locale.US, "%.1f / %.1f GiB", available / GIB, total / GIB)
    } catch (_: Exception) {
        texts.t("info.unknown", R.string.info_unknown)
    }

    private fun uptime(): String {
        val total = SystemClock.elapsedRealtime() / 1000
        return "${total / 3600}h ${(total / 60) % 60}m ${total % 60}s"
    }

    private fun battery(device: JSONObject?): String {
        val percent = device?.optInt("battery", -1) ?: -1
        if (percent < 0) return texts.t("info.unknown", R.string.info_unknown)
        val charging = device?.optBoolean("charging") == true
        return "$percent%" + if (charging) " ⚡" else ""
    }

    private fun timestamp(wallMs: Long): String {
        if (wallMs <= 0) return texts.t("info.unknown", R.string.info_unknown)
        return java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
            .format(java.util.Date(wallMs))
    }

    private fun dp(v: Int) = PairingUi.dp(this, v)

    private fun buildUi(): View {
        val scroll = ScrollView(this).apply { setBackgroundColor(PairingUi.BG) }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(24), dp(20), dp(32))
        }
        scroll.addView(
            root,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        root.addView(
            PairingUi.title(this, texts.t("info.title", R.string.info_title)),
            PairingUi.matchWrap(),
        )
        bodyView = TextView(this).apply {
            setTextColor(PairingUi.DIM)
            textSize = 13f
            typeface = android.graphics.Typeface.MONOSPACE
            setTextIsSelectable(true)
            setPadding(0, dp(14), 0, dp(14))
        }
        root.addView(bodyView, PairingUi.matchWrap())
        root.addView(
            PairingUi.button(this, texts.t("info.refresh", R.string.info_refresh)) { refresh() },
            PairingUi.matchWrap(),
        )
        root.addView(PairingUi.spacer(this, 8))
        root.addView(
            PairingUi.button(this, texts.t("admin.menu_close", R.string.admin_menu_close)) {
                finish()
            },
            PairingUi.matchWrap(),
        )
        return scroll
    }

    companion object {
        private const val GIB = 1_073_741_824.0

        fun launch(activity: Activity) {
            activity.startActivity(Intent(activity, DeviceInfoActivity::class.java))
        }
    }
}
