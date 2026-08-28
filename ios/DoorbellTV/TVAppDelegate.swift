// tvOS 監視端 (DoorbellTV) の起動 — Android TV (role=indoor_panel + tv:true) と同じ立ち位置。
// 常駐監視: フォアグラウンド前提 (TV は常時給電・自動ロックなし。isIdleTimerDisabled で
// スクリーンセーバも抑止)。来客 (chime) で全画面来鈴 (IncomingViewController — 門口 MJPEG +
// クイック返信を Siri Remote フォーカスで操作)。
// boot.json 相当は UserDefaults "boot_json" (BootConfig 参照 — tvOS はローカル保存が
// Caches のみのため)。data_dir は Caches — 消えても CRDT 設定は mesh から自動復元される。
// 制約: pjsip の tvOS ビルドは未整備 — SIP 監聴/応答は不可 (来鈴は映像のみ。
// core は sipctl スタブでビルドされ sipCall は no-op)。TODO は IncomingViewController 参照。
import UIKit

@UIApplicationMain
final class TVAppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    let core = CoreBridge()
    private(set) var boot = BootConfig()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        boot = BootConfig.load()
        _ = core.start(dataDir: BootConfig.dataDir(), bootJson: boot.rawJson)
        core.addHandler("app") { [weak self] ev in self?.onUiEvent(ev) }

        let win = UIWindow(frame: UIScreen.main.bounds)
        win.rootViewController = TVMainViewController(core: core, boot: boot)
        win.makeKeyAndVisible()
        window = win

        application.isIdleTimerDisabled = true  // 監視端 — スクリーンセーバへ落とさない
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        core.stop()
    }

    // MARK: - core イベント (main queue — CoreBridge が marshal 済み)

    private func onUiEvent(_ ev: [String: Any]) {
        // 来客 (press イベントの複製 — WPF/iOS 室内機と同じ流儀) → 全画面来鈴。
        if ConfigUtil.evStr(ev, "t") == "event" && ConfigUtil.evStr(ev, "type") == "press" {
            presentIncoming(door: ConfigUtil.evStr(ev, "door"),
                            purpose: ConfigUtil.evStr(ev, "purpose"),
                            visitorLang: ConfigUtil.evStr(ev, "visitor_lang"))
        }
    }

    private func presentIncoming(door: String, purpose: String, visitorLang: String) {
        guard let root = window?.rootViewController else { return }
        if let vc = root.presentedViewController as? IncomingViewController {
            vc.refresh(purpose: purpose, visitorLang: visitorLang)
            return
        }
        guard root.presentedViewController == nil else { return }
        let vc = IncomingViewController(core: core, boot: boot, door: door,
                                        purpose: purpose, visitorLang: visitorLang)
        root.present(vc, animated: true)
    }
}
