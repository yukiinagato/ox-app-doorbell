// 起動: filesDir/boot.json を読み core を生成・起動する (WPF 版 App.xaml.cs 相当)。
package jp.keihan.doorbell

import android.app.Application
import java.io.File

class App : Application() {

    lateinit var boot: BootConfig
        private set
    val core = DoorbellCore()
    var coreOk = false
        private set

    override fun onCreate() {
        super.onCreate()
        boot = BootConfig.load(File(filesDir, "boot.json"))
        // 失敗しても UI は起動する (オフライン表示)。ログは logcat doorbell-core タグ。
        coreOk = core.start(filesDir.absolutePath, boot.rawJson)
    }

    override fun onTerminate() {
        core.destroy()
        super.onTerminate()
    }
}
