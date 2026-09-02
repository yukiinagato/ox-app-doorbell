package jp.ox.doorbell

import android.annotation.TargetApi
import android.app.Activity
import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context

@TargetApi(21)
internal object NativeLockTaskApi21 {
    fun isAvailable(context: Context): Boolean = try {
        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        dpm.isDeviceOwnerApp(context.packageName) || dpm.isLockTaskPermitted(context.packageName)
    } catch (_: Exception) { false }

    fun tryEnter(activity: Activity): Boolean {
        return try {
            val dpm = activity.getSystemService(Activity.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            if (dpm.isDeviceOwnerApp(activity.packageName)) {
                dpm.setLockTaskPackages(ComponentName(activity, AdminReceiver::class.java),
                                        arrayOf(activity.packageName))
            }
            if (!dpm.isLockTaskPermitted(activity.packageName)) false else {
                activity.startLockTask()
                isActive(activity)
            }
        } catch (_: Exception) { false }
    }

    @Suppress("DEPRECATION")
    fun isActive(context: Context): Boolean = try {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        manager.isInLockTaskMode
    } catch (_: Exception) { false }

    fun leave(activity: Activity) {
        try { activity.stopLockTask() } catch (_: Exception) { }
    }
}
