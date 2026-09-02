package jp.keihan.doorbell

import android.content.Context
import android.os.Build

internal object DeviceOwnerPolicies {
    fun apply(context: Context) {
        if (Build.VERSION.SDK_INT >= 21) DeviceOwnerPoliciesApi21.apply(context)
    }
}
