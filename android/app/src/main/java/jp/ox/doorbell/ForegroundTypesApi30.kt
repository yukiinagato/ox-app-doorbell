package jp.ox.doorbell

import android.Manifest
import android.annotation.TargetApi
import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build

/** Foreground-service type selection for API 30+ (see DoorbellService.enterForeground). */
@TargetApi(30)
internal object ForegroundTypesApi30 {

    /** The always-allowed resident type: special use on API 34+, none before. */
    fun residentOnly(): Int =
        if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0

    /**
     * Door stations capture the camera headless; every role may carry SIP audio. A type is
     * declared only when its runtime permission is granted.
     */
    fun wanted(context: Context, role: String): Int {
        var types = residentOnly()
        if (role == "door_station" && granted(context, Manifest.permission.CAMERA))
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        if (granted(context, Manifest.permission.RECORD_AUDIO))
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        return types
    }

    fun start(service: Service, id: Int, notification: Notification, types: Int) {
        service.startForeground(id, notification, types)
    }

    private fun granted(context: Context, permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
}
