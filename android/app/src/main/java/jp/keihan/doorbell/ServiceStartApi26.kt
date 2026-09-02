package jp.keihan.doorbell

import android.annotation.TargetApi
import android.content.Context
import android.content.Intent

@TargetApi(26)
internal object ServiceStartApi26 {
    fun start(context: Context, intent: Intent) {
        context.startForegroundService(intent)
    }
}
