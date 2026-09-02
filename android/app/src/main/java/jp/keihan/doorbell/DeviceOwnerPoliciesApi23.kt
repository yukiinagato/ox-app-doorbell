package jp.keihan.doorbell

import android.annotation.TargetApi
import android.app.admin.DevicePolicyManager
import android.app.admin.SystemUpdatePolicy
import android.content.ComponentName

@TargetApi(23)
internal object DeviceOwnerPoliciesApi23 {
    fun apply(dpm: DevicePolicyManager, admin: ComponentName) {
        dpm.setKeyguardDisabled(admin, true)
        dpm.setStatusBarDisabled(admin, true)
        dpm.setSystemUpdatePolicy(admin, SystemUpdatePolicy.createPostponeInstallPolicy())
    }
}
