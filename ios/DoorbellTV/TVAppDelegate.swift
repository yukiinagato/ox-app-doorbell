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
    private let pairingTexts = Texts()
    private var pairingGate: PairingViewController?
    private var pairingDeferred = false
    private var pairingGateTimer: Timer?
    private var openPairingObserver: NSObjectProtocol?
    private var resetObserver: NSObjectProtocol?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        boot = BootConfig.load()
        if BootConfig.migrateLegacyPskIntoSecureStore() { boot = BootConfig.load() }
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

        pairingTexts.setLang(boot.uiLang)
        pairingTexts.setConfig(soundConfig)
        if openPairingObserver == nil {
            openPairingObserver = NotificationCenter.default.addObserver(
                forName: .doorbellOpenPairing, object: nil, queue: .main
            ) { [weak self] _ in
                self?.pairingDeferred = false
                self?.presentPairingGate()
            }
        }
        if resetObserver == nil {
            resetObserver = NotificationCenter.default.addObserver(
                forName: .doorbellResetLocalPairing, object: nil, queue: .main
            ) { [weak self] _ in self?.resetLocalPairing() }
        }
        evaluatePairingGate()
        pairingGateTimer = IOSAvailability.scheduledTimer(withTimeInterval: 3, repeats: true) {
            [weak self] _ in self?.evaluatePairingGate()
        }
        return true
    }


    /// Apple TV gets the same unpaired gate as the handheld clients; it is display-only because
    /// the device has no camera.
    private func evaluatePairingGate() {
        guard core.isRunning else { return }
        let snapshot = PairingSnapshot.load(core)
        guard snapshot.hasSnapshot else { return }
        NotificationCenter.default.post(name: .doorbellPairingChanged, object: nil)
        guard snapshot.state.blocksMainUi else {
            // A member device starts over with a clean slate: a later revocation must gate again.
            pairingDeferred = false
            return
        }
        guard !pairingDeferred else { return }
        presentPairingGate()
    }

    private func presentPairingGate() {
        guard pairingGate == nil, let root = window?.rootViewController,
              root.presentedViewController == nil else { return }
        let gate = PairingViewController(core: core, boot: boot, texts: pairingTexts)
        gate.onDefer = { [weak self] in self?.closePairingGate(deferred: true) }
        gate.onFinished = { [weak self] in self?.closePairingGate(deferred: false) }
        pairingGate = gate
        root.present(gate, animated: false)
    }

    private func closePairingGate(deferred: Bool) {
        pairingDeferred = deferred
        guard let gate = pairingGate else { return }
        pairingGate = nil
        gate.dismiss(animated: true) { [weak self] in
            NotificationCenter.default.post(name: .doorbellPairingChanged, object: nil)
            self?.evaluatePairingGate()
        }
    }

    /// Leaving the cluster, or being removed from it, returns the device to its first-run state:
    /// the stored key, the pairing fields and its own identity all go, and the pairing gate is
    /// what comes back.
    private func resetLocalPairing() {
        pairingGate?.dismiss(animated: false)
        pairingGate = nil
        pairingDeferred = false
        pairingGateTimer?.invalidate()
        pairingGateTimer = nil
        runtime?.stop(clean: false)
        runtime = nil
        core.stop()
        guard Keychain.removeAll(), BootConfig.clearPersistedState() else {
            IOSAvailability.logDebug("local pairing reset failed")
            return
        }
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        UserDefaults.standard.synchronize()
        boot = BootConfig.load()
        _ = core.start(dataDir: BootConfig.dataDir(), bootJson: boot.rawJson)
        runtime = RuntimeSupervisor(core: core, boot: boot)
        runtime?.start()
        if let win = window {
            win.rootViewController = TVMainViewController(
                core: core, boot: boot,
                deviceAlertReporter: { [weak self] report in
                    self?.runtime?.recordDeviceAlert(report)
                })
            win.makeKeyAndVisible()
        }
        pairingGateTimer = IOSAvailability.scheduledTimer(withTimeInterval: 3, repeats: true) {
            [weak self] _ in self?.evaluatePairingGate()
        }
        presentPairingGate()
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
        if t == "pairing_persistence_error" {
            presentPairingGate()
            if pairingGate == nil { presentPairingPersistenceError() }
        }
        if t == "pairing_state" || t == "paired" { evaluatePairingGate() }
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
            title: pairingTexts.t("pair.persist_error_title"),
            message: pairingTexts.t("pair.persist_error_body"),
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
