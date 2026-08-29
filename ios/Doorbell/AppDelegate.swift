// 起動: Documents/boot.json を読み core を生成・起動する (WPF App.xaml.cs / Android App 相当)。
// core の UI イベントは CoreBridge が main queue へ marshal して配る。chime は Activity の
// 生死に関わらずここで拾い、室内機 (indoor_panel) なら来鈴画面 (IncomingViewController) を
// 前面へ被せる。門口機自身は MainViewController が門口 UI なので出さない。
// keep-awake: isIdleTimerDisabled=true。kiosk 硬化は監督 SAM (Single App Mode) 前提 —
// 手順は deploy/provision/ios/provision.md。
// 発見: iOS 14+ の multicast entitlement 制約のため core の UDP beacon は当てにしない —
// boot.json の seed_peers を必須とする (同一 L2 で seed 1 台あれば gossip が全員つなぐ)。
// TODO(iOS): NetServiceBrowser (Bonjour) による補助発見。C ABI に discovery 注入面が
// 無いため、現状は seed_peers 運用 (実害なし)。
import AVFoundation
import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    let core = CoreBridge()
    private(set) var boot = BootConfig()
    private let effects = SirenPlayer()
    private let launchAudio = SirenPlayer()
    private var soundConfig: [String: Any]?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        boot = BootConfig.load()

        // スピーカーフォン運用 (門口機/室内機とも)。VoiceProcessingIO (AEC) は pjsip の
        // coreaudio_dev が実行時に選ぶ — ここでは session をスピーカ出力の通話向けに設定。
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .videoChat,
                                 options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true)

        // 失敗しても UI は起動する (オフライン表示)。ログは os_log (subsystem jp.keihan.doorbell)。
        _ = core.start(dataDir: BootConfig.dataDir(), bootJson: boot.rawJson)
        soundConfig = core.config()

        core.addHandler("app") { [weak self] ev in self?.onUiEvent(ev) }

        let win = ActivityWindow(frame: UIScreen.main.bounds)
        win.onControlTap = { [weak self] control in
            guard control.accessibilityIdentifier != "call_primary" else { return }
            self?.effects.playConfigured(self?.soundValue("button_sound", "button_click") ?? "")
        }
        let main = MainViewController(core: core, boot: boot)
        win.onActivity = { [weak main] in main?.onActivity() }
        win.rootViewController = main
        win.makeKeyAndVisible()
        window = win

        launchAudio.playConfigured(soundValue("launch_sound", "title_display"))

        application.isIdleTimerDisabled = true  // keep-awake (kiosk)
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        core.stop()
    }

    // MARK: - core イベント (main queue — CoreBridge が marshal 済み)

    private func onUiEvent(_ ev: [String: Any]) {
        let type = ConfigUtil.evStr(ev, "type")
        if ConfigUtil.evStr(ev, "t") == "event", boot.role != "door_station",
           type == "call_cancelled" || type == "purpose_selected" {
            effects.playConfigured(soundValue("update_sound", "indoor_update"))
        }
        if ConfigUtil.evStr(ev, "t") == "config_changed" {
            soundConfig = core.config()
        }
        // 来客 (press イベントの複製 — WPF MainWindow と同じ流儀) → 来鈴画面。
        // 用件/訪客言語は press payload 由来 (バッジ + 返信ラベル言語)。
        // 門口機自身 (door_station) は MainViewController が門口 UI なので出さない。
        if ConfigUtil.evStr(ev, "t") == "event" && ConfigUtil.evStr(ev, "type") == "press"
            && boot.role != "door_station" {
            presentIncoming(door: ConfigUtil.evStr(ev, "door"),
                            purpose: ConfigUtil.evStr(ev, "purpose"),
                            visitorLang: ConfigUtil.evStr(ev, "visitor_lang"))
        }
    }

    private func soundValue(_ key: String, _ fallback: String) -> String {
        return (ConfigUtil.dig(soundConfig, "ui.\(key)") as? String) ?? fallback
    }

    private func presentIncoming(door: String, purpose: String, visitorLang: String) {
        guard let root = window?.rootViewController else { return }
        // 同じ画面が出ている間の再チャイム → 用件/言語を更新しタイマを張り直す
        if let vc = root.presentedViewController as? IncomingViewController {
            vc.refresh(purpose: purpose, visitorLang: visitorLang)
            return
        }
        guard root.presentedViewController == nil else { return }  // PIN 等の表示中は奪わない
        let vc = IncomingViewController(core: core, boot: boot, door: door,
                                        purpose: purpose, visitorLang: visitorLang)
        root.present(vc, animated: true)
    }
}

/// 全タッチを無操作検出へ流す window (スクリーンセーバ解除用 — WPF Preview* 相当)。
final class ActivityWindow: UIWindow {
    var onActivity: (() -> Void)?
    var onControlTap: ((UIControl) -> Void)?

    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches { onActivity?() }
        super.sendEvent(event)
        guard event.type == .touches else { return }
        for touch in event.allTouches ?? [] where touch.phase == .ended {
            var view: UIView? = touch.view
            while view != nil, !(view is UIControl) { view = view?.superview }
            if let control = view as? UIControl, control.isEnabled {
                onControlTap?(control)
                break
            }
        }
    }
}
