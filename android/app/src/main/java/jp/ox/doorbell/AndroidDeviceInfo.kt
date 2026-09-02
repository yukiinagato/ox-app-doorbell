package jp.ox.doorbell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import java.util.Locale
import org.json.JSONObject

/** Maintains a small cached snapshot because core invokes device_info on its run loop. */
internal class AndroidDeviceInfo(context: Context) {
    private val app = context.applicationContext
    @Volatile private var cached = "{}"
    private var batteryPercent = -1
    @Volatile private var charging = false
    @Volatile private var mainsPower = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = refresh(intent)
    }

    init {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            @Suppress("DEPRECATION")
            addAction(ConnectivityManager.CONNECTIVITY_ACTION)
        }
        val sticky = try { app.registerReceiver(receiver, filter) } catch (_: Exception) { null }
        refresh(sticky)
    }

    fun snapshot(): String = cached

    fun isOnMainsPower(): Boolean = mainsPower

    @Suppress("DEPRECATION")
    private fun refresh(intent: Intent?) {
        if (intent?.action == Intent.ACTION_BATTERY_CHANGED) {
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            batteryPercent = if (level >= 0 && scale > 0) level * 100 / scale else -1
            val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
            val plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
            charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL
            mainsPower = AndroidPowerMeasurement.isOnMainsPower(status, plugged)
        }
        val connectivity = try {
            (app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager)
                .activeNetworkInfo
        } catch (_: Exception) { null }
        val wifi = try {
            app.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        }
            catch (_: Exception) { null }
        val gateway = wifi?.dhcpInfo?.gateway?.takeIf { it != 0 }?.let(::ipv4).orEmpty()
        val signal = try { wifi?.connectionInfo?.rssi ?: Int.MIN_VALUE }
            catch (_: Exception) { Int.MIN_VALUE }
        val screenOn = try {
            (app.getSystemService(Context.POWER_SERVICE) as PowerManager).isScreenOn
        } catch (_: Exception) { true }
        val root = JSONObject()
            .put("platform", "android")
            .put("sdk", Build.VERSION.SDK_INT)
            .put("os_release", Build.VERSION.RELEASE ?: "")
            .put("manufacturer", Build.MANUFACTURER ?: "")
            .put("model", Build.MODEL ?: "")
            .put("abi", Build.CPU_ABI ?: "")
            .put("network_connected", connectivity?.isConnected == true)
            .put("network_type", connectivity?.typeName ?: "")
            .put("gateway", gateway)
            .put("battery", batteryPercent)
            .put("charging", charging)
            .put("mains_power", mainsPower)
            .put("screen_on", screenOn)
        if (signal != Int.MIN_VALUE) root.put("wifi_rssi_dbm", signal)
        cached = root.toString()
    }

    private fun ipv4(value: Int): String = String.format(
        Locale.US,
        "%d.%d.%d.%d",
        value and 0xff,
        value shr 8 and 0xff,
        value shr 16 and 0xff,
        value shr 24 and 0xff,
    )
}

internal object AndroidPowerMeasurement {
    fun isOnMainsPower(status: Int, plugged: Int): Boolean =
        plugged != 0 || status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
}
