package jp.ox.doorbell

import android.content.Context
import android.os.Build

internal object DeviceOwnerPolicies {
    fun apply(context: Context) {
        if (Build.VERSION.SDK_INT >= 21) DeviceOwnerPoliciesApi21.apply(context)
    }

    /** Whether this package is the device owner (API 18+); false wherever that cannot be read. */
    fun isDeviceOwner(context: Context): Boolean = try {
        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE)
            as? android.app.admin.DevicePolicyManager
        dpm?.isDeviceOwnerApp(context.packageName) == true
    } catch (e: Exception) {
        android.util.Log.w("doorbell-owner", "device-owner state unavailable: $e")
        false
    }
}
