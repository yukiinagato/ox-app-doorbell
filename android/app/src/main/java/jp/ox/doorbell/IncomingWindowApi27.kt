package jp.ox.doorbell

import android.annotation.TargetApi
import android.app.Activity

@TargetApi(27)
internal object IncomingWindowApi27 {
    fun apply(activity: Activity) {
        activity.setShowWhenLocked(true)
        activity.setTurnScreenOn(true)
    }
}
