package jp.keihan.doorbell

import android.annotation.TargetApi
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.Log

@TargetApi(21)
internal object DeviceOwnerPoliciesApi21 {
    fun apply(context: Context) {
        try {
            val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            if (!dpm.isDeviceOwnerApp(context.packageName)) return
            val admin = ComponentName(context, AdminReceiver::class.java)
            dpm.setGlobalSetting(admin, Settings.Global.STAY_ON_WHILE_PLUGGED_IN, "7")
            if (Build.VERSION.SDK_INT >= 23) DeviceOwnerPoliciesApi23.apply(dpm, admin)
        } catch (e: Exception) {
            Log.w("doorbell-kiosk", "Device Owner policy failed: $e")
        }
    }
}
