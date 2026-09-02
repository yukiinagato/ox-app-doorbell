// Apple TV has no microphone, so the tvOS PJSIP backend is restricted to listen-only monitoring.
import AVFoundation
import UIKit

@UIApplicationMain
final class TVAppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    let core = CoreBridge()
    private(set) var boot = BootConfig()
    private let effects = SirenPlayer()
    private let launchAudio = SirenPlayer()
    private var soundConfig: [String: Any]?
    private var runtime: RuntimeSupervisor?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        boot = BootConfig.load()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        _ = core.start(dataDir: BootConfig.dataDir(), bootJson: boot.rawJson)
        runtime = RuntimeSupervisor(core: core, boot: boot)
        runtime?.start()
        soundConfig = core.config()
        core.addHandler("app") { [weak self] ev in self?.onUiEvent(ev) }

        let win = TVActivityWindow(frame: UIScreen.main.bounds)
        win.onControlTap = { [weak self] in
            self?.effects.playConfigured(self?.soundValue("button_sound", "button_click") ?? "")
        }
        win.rootViewController = TVMainViewController(
            core: core, boot: boot,
            deviceAlertReporter: { [weak self] report in
                self?.runtime?.recordDeviceAlert(report)
            })
        win.makeKeyAndVisible()
        window = win

        application.isIdleTimerDisabled = true
        launchAudio.playConfigured(soundValue("launch_sound", "title_display"))
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        runtime?.stop(clean: true)
        core.stop()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        runtime?.handleMemoryPressure()
    }

    private func onUiEvent(_ ev: [String: Any]) {
        let t = ConfigUtil.evStr(ev, "t")
        let type = ConfigUtil.evStr(ev, "type")
        if t == "event" && (type == "call_cancelled" || type == "call_answered" ||
                            type == "call_ended" || type == "purpose_selected") {
            effects.playConfigured(soundValue("update_sound", "indoor_update"))
        }
        if t == "config_changed" { soundConfig = core.config() }
        if t == "paired" {
            let secretRef = ConfigUtil.evStr(ev, "psk_ref")
            let seeds = ev["seeds"] as? [String] ?? []
            if secretRef == "secret:mesh.psk",
               BootConfig.persistPairing(secretRef: secretRef, seeds: seeds) {
                boot = BootConfig.load()
            } else { presentPairingPersistenceError() }
        }
        if t == "pairing_persistence_error" { presentPairingPersistenceError() }
        if t == "chime" {
            presentIncoming(door: ConfigUtil.evStr(ev, "door"),
                            purpose: ConfigUtil.evStr(ev, "purpose"),
                            visitorLang: ConfigUtil.evStr(ev, "visitor_lang"),
                            callId: ConfigUtil.evStr(ev, "call_id"))
        }
    }

    private func soundValue(_ key: String, _ fallback: String) -> String {
        (ConfigUtil.dig(soundConfig, "ui.\(key)") as? String) ?? fallback
    }

    private func presentPairingPersistenceError() {
        guard let root = window?.rootViewController,
              root.presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: NSLocalizedString("admin.pair_mode", comment: ""),
            message: NSLocalizedString("admin.pair_secure_failed", comment: ""),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        root.present(alert, animated: true)
    }

    private func presentIncoming(door: String, purpose: String, visitorLang: String,
                                 callId: String) {
        guard !callId.isEmpty else { return }
        guard let root = window?.rootViewController else { return }
        if let vc = root.presentedViewController as? IncomingViewController {
            vc.receive(door: door, purpose: purpose, visitorLang: visitorLang, callId: callId)
            return
        }
        guard root.presentedViewController == nil else { return }
        let vc = IncomingViewController(core: core, boot: boot, door: door,
                                        purpose: purpose, visitorLang: visitorLang,
                                        callId: callId)
        root.present(vc, animated: true)
    }
}

private final class TVActivityWindow: UIWindow {
    var onControlTap: (() -> Void)?

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        if presses.contains(where: { $0.type == .select }) { onControlTap?() }
    }
}
