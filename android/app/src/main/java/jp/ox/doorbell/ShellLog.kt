package jp.ox.doorbell

import android.util.Log

/**
 * A failure the caller deliberately tolerates (releasing an already-dead player, closing a socket
 * twice). It is still logged at debug level so a recurring one shows up in logcat instead of
 * disappearing.
 */
internal object ShellLog {
    fun ignored(where: String, error: Throwable) {
        Log.d("doorbell-ignored", "$where: ${error.javaClass.simpleName}: ${error.message.orEmpty()}")
    }
}
