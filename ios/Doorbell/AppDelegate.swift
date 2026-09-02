import AVFoundation
import UIKit
import UserNotifications

// Multicast discovery on recent iOS requires an entitlement, so managed deployments provide at
// least one seed_peers entry in boot.json and let Core gossip discover the remaining LAN nodes.
@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    let core = CoreBridge()
    private(set) var boot = BootConfig()
    private let effects = SirenPlayer()
    private let launchAudio = SirenPlayer()
    private let emergencyNotifications = EmergencySystemNotifier()
    private var soundConfig: [String: Any]?
    private var runtime: RuntimeSupervisor?
    private var chimeGate = CallChimeRevisionGate()
    private var appStarted = false
    private var resetObserver: NSObjectProtocol?
    private var openPairingObserver: NSObjectProtocol?
    private let pairingTexts = Texts()
    private var pairingGate: PairingViewController?
    private var pairingDeferred = false
    private var pairingGateTimer: Timer?
    private var lastPairingFingerprint = ""
    private var screenshots: ScreenshotResponder?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        boot = BootConfig.load()
        IOSAvailability.cacheScreenScale()
        IOSAvailability.PerfProbe.enabled = boot.debugTimings
        if boot.debugScreenshots {
            let responder = ScreenshotResponder(dataDir: BootConfig.dataDir())
            screenshots = responder
            responder.start()
        }
        if resetObserver == nil {
            resetObserver = NotificationCenter.default.addObserver(
                forName: .doorbellResetLocalPairing, object: nil, queue: .main
            ) { [weak self] _ in self?.resetLocalPairing() }
        }
        if openPairingObserver == nil {
            openPairingObserver = NotificationCenter.default.addObserver(
                forName: .doorbellOpenPairing, object: nil, queue: .main
            ) { [weak self] _ in
                self?.pairingDeferred = false
                self?.presentPairingGate()
            }
        }
        emergencyNotifications.configure(application: application, delegate: self)

        let win = ActivityWindow(frame: UIScreen.main.bounds)
        window = win
        application.isIdleTimerDisabled = true
        if boot.setupRequired {
            let setup = BootstrapSetupViewController(boot: boot)
            setup.onSave = { [weak self, weak win, weak application] name, role, door in
                guard let self = self, let win = win, let application = application,
                      let updated = BootConfig.persistSetup(name: name, role: role, door: door)
                else { return false }
                self.boot = updated
                self.startConfiguredApplication(application, window: win)
                return true
            }
            win.rootViewController = setup
            win.makeKeyAndVisible()
        } else {
            startConfiguredApplication(application, window: win)
        }
        return true
    }

    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard url.scheme?.lowercased() == "doorbell" else { return false }
        if url.host?.lowercased() == PairUri.action {
            // The pairing screen owns the decision: it is the surface that can show the cluster
            // being joined, say why an invitation cannot be used, and warn about leaving a
            // cluster this device is already in.
            pairingDeferred = false
            presentPairingGate()
            NotificationCenter.default.post(name: .doorbellPairInvitation,
                                            object: url.absoluteString)
            return true
        }
        guard url.host?.lowercased() == "debug" else { return false }
        switch url.path.lowercased() {
        case "/ping", "/status":
            IOSAvailability.logDebug(debugSummary())
        case "/h264":
            IOSAvailability.logDebug("debug URL requested H.264 refresh")
            (window?.rootViewController as? MainViewController)?.debugRefreshH264()
        default:
            IOSAvailability.logDebug("debug URL ignored path=\(url.path)")
        }
        return true
    }

    private func startConfiguredApplication(_ application: UIApplication,
                                            window win: ActivityWindow) {
        guard !appStarted else { return }
        appStarted = true

        // Configure speakerphone calling. PJSIP selects VoiceProcessingIO for AEC at runtime.
        let session = AVAudioSession.sharedInstance()
        let audioSessionReady = IOSAvailability.configureCallAudioSession(session)

        // A key left in boot.json by an older build moves into the Keychain before Core reads
        // the profile, so provenance is reported as secure_store from the first launch.
        if BootConfig.migrateLegacyPskIntoSecureStore() { boot = BootConfig.load() }

        // Keep the UI available in offline mode if Core cannot start.
        _ = core.start(dataDir: BootConfig.dataDir(), bootJson: boot.rawJson)
        runtime = RuntimeSupervisor(core: core, boot: boot,
                                    audioSessionReady: audioSessionReady)
        runtime?.start()
        if boot.role == "door_station" {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            NotificationCenter.default.addObserver(
                self, selector: #selector(deviceOrientationChanged),
                name: UIDevice.orientationDidChangeNotification, object: nil)
            deviceOrientationChanged()
        }
        soundConfig = core.config()

        core.addHandler("app") { [weak self] ev in self?.onUiEvent(ev) }

        win.onControlTap = { [weak self] control in
            guard control.accessibilityIdentifier != "call_primary" else { return }
            self?.applyEffectVolumes()
            self?.effects.playConfigured(self?.soundValue("button_sound", "button_click") ?? "")
        }
        let main = MainViewController(core: core, boot: boot, runtime: runtime)
        win.onActivity = { [weak main] in main?.onActivity() }
        win.rootViewController = main
        win.makeKeyAndVisible()

        applyEffectVolumes()
        launchAudio.playConfigured(soundValue("launch_sound", "title_display"))

        pairingTexts.setLang(boot.uiLang)
        pairingTexts.setConfig(soundConfig)
        evaluatePairingGate()
        // Core may publish its first pairing snapshot slightly after start, and a later
        // revocation moves the device back to unpaired, so the check keeps running.
        pairingGateTimer?.invalidate()
        pairingGateTimer = IOSAvailability.scheduledTimer(withTimeInterval: 3, repeats: true) {
            [weak self] _ in self?.evaluatePairingGate()
        }
    }


    /// The unpaired gate: an unpaired, joining or persist_error device shows the onboarding
    /// screen instead of the main UI. State always comes from Core.
    private func evaluatePairingGate() {
        guard core.isRunning else { return }
        let snapshot = PairingSnapshot.load(core)
        guard snapshot.hasSnapshot else { return }
        // Only a real change is announced. Posting unconditionally woke every observer twenty
        // times a minute to re-parse the same pairing document and rebuild the same string.
        let fingerprint = snapshot.changeFingerprint
        if fingerprint != lastPairingFingerprint {
            lastPairingFingerprint = fingerprint
            NotificationCenter.default.post(name: .doorbellPairingChanged, object: nil)
        }
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

    func applicationWillTerminate(_ application: UIApplication) {
        NotificationCenter.default.removeObserver(self,
            name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        runtime?.stop(clean: true)
        core.stop()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        runtime?.handleMemoryPressure()
        guard let root = window?.rootViewController as? MainViewController else { return }
        root.enterSafeModeForMemoryPressure()
        if let incoming = root.presentedViewController as? IncomingViewController {
            incoming.enterSafeModeForMemoryPressure()
        } else if let monitor = root.presentedViewController as? MonitorViewController {
            monitor.enterSafeModeForMemoryPressure()
        }
    }

    @objc private func deviceOrientationChanged() {
        guard let degrees = IOSAvailability.cameraFrameRotation(for: UIDevice.current.orientation)
        else { return }  // Keep the previous value for face-up, face-down, and unknown.
        core.setVideoSensorRotation(degrees)
    }


    private func onUiEvent(_ ev: [String: Any]) {
        let eventKind = ConfigUtil.evStr(ev, "t")
        let type = ConfigUtil.evStr(ev, "type")
        if eventKind == "event", boot.role != "door_station",
           type == "call_cancelled" || type == "call_answered" ||
           type == "call_ended" || type == "purpose_selected" {
            applyEffectVolumes()
            effects.playConfigured(soundValue("update_sound", "indoor_update"))
        }
        if eventKind == "config_changed" {
            soundConfig = core.config()
        }
        if eventKind == "emergency" {
            let sosVolume = ConfigUtil.int(core.audioVolumes(), "sos",
                                           ConfigUtil.int(ev, "alarm_volume", 100))
            emergencyNotifications.handle(ev, sosVolume: sosVolume) { [weak self] report in
                self?.runtime?.recordDeviceAlert(report)
            }
        }
        if eventKind == "paired" {
            persistPairing(ev)
        }
        if eventKind == "pairing_persistence_error" {
            // The onboarding screen owns this state; the alert is only a fallback for a device
            // that cannot show the gate right now.
            presentPairingGate()
            if pairingGate == nil { presentPairingPersistenceError() }
        }
        if eventKind == "pairing_state" || eventKind == "paired" {
            evaluatePairingGate()
        }
        if eventKind == "pairing_revoked" {
            announceRevocationThenReset()
            return
        }
        if eventKind == "call_recovery_required" {
            // The view controller validates the replicated active-call record before deciding
            // whether a waiting visitor screen can be rebuilt or an in-call dialog must fail.
            (window?.rootViewController as? MainViewController)?.handleCallRecovery(ev)
        }
        // Only a targeted chime opens the incoming screen. Raw mesh press events update state
        // but never ring twice when more than one rule action observes the same call.
        if eventKind == "chime" && boot.role != "door_station" &&
            chimeGate.accept(callId: ConfigUtil.evStr(ev, "call_id"),
                             stageRevision: ConfigUtil.int(ev, "stage_revision", 0)) {
            presentIncoming(door: ConfigUtil.evStr(ev, "door"),
                            purpose: ConfigUtil.evStr(ev, "purpose"),
                            visitorLang: ConfigUtil.evStr(ev, "visitor_lang"),
                            callId: ConfigUtil.evStr(ev, "call_id"),
                            stageRevision: ConfigUtil.int(ev, "stage_revision", 0))
        }
    }

    private func persistPairing(_ ev: [String: Any]) {
        let secretRef = ConfigUtil.evStr(ev, "psk_ref")
        let seeds = ev["seeds"] as? [String] ?? []
        guard secretRef == "secret:mesh.psk",
              BootConfig.persistPairing(secretRef: secretRef, seeds: seeds)
        else { presentPairingPersistenceError(); return }
        boot = BootConfig.load()
    }

    private func presentPairingPersistenceError() {
        guard let root = window?.rootViewController,
              root.presentedViewController == nil else { return }
        let message = NSLocalizedString("admin.pair_secure_failed", comment: "")
        let alert = UIAlertController(title: NSLocalizedString("admin.pair_mode", comment: ""),
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        root.present(alert, animated: true)
    }

    /// A removed device tells the user why it is resetting before it wipes itself.
    private func announceRevocationThenReset() {
        pairingGate?.dismiss(animated: false)
        pairingGate = nil
        guard let root = window?.rootViewController, root.presentedViewController == nil else {
            resetLocalPairing()
            return
        }
        let alert = UIAlertController(title: pairingTexts.t("pair.revoked"), message: nil,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.resetLocalPairing()
        })
        root.present(alert, animated: true)
        // Never leave a revoked device stuck on a dialog nobody dismisses.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak alert] in
            guard let self = self, let alert = alert,
                  alert.presentingViewController != nil else { return }
            alert.dismiss(animated: false) { self.resetLocalPairing() }
        }
    }

    private func resetLocalPairing() {
        pairingGate?.dismiss(animated: false)
        pairingGate = nil
        pairingDeferred = false
        pairingGateTimer?.invalidate()
        pairingGateTimer = nil
        runtime?.stop(clean: false)
        runtime = nil
        core.stop()
        guard Keychain.removeAll(), BootConfig.clearPersistedState(),
              let win = window as? ActivityWindow else {
            IOSAvailability.logDebug("local pairing reset failed")
            return
        }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        UserDefaults.standard.synchronize()
        boot = BootConfig.load()
        appStarted = false
        let setup = BootstrapSetupViewController(boot: boot)
        setup.onSave = { [weak self, weak win] name, role, door in
            guard let self = self, let win = win,
                  let updated = BootConfig.persistSetup(name: name, role: role, door: door)
            else { return false }
            self.boot = updated
            self.startConfiguredApplication(UIApplication.shared, window: win)
            return true
        }
        win.rootViewController = setup
        win.makeKeyAndVisible()
    }

    /// UI and startup sounds follow the "everyday" level; the ring follows the call level. Core
    /// resolves the device override and the cluster default, so the shell only applies the number.
    private func applyEffectVolumes() {
        guard let volumes = core.audioVolumes() else { return }
        effects.volume = ConfigUtil.int(volumes, "idle", 60)
        launchAudio.volume = ConfigUtil.int(volumes, "idle", 60)
    }

    private func soundValue(_ key: String, _ fallback: String) -> String {
        return (ConfigUtil.dig(soundConfig, "ui.\(key)") as? String) ?? fallback
    }

    private func debugSummary() -> String {
        let video = core.status()?["video"] as? [String: Any] ?? [:]
        let codec = video["codec"] as? String ?? "unknown"
        let active = video["active"] as? Bool ?? false
        let subscribers = video["subscribers"] as? Int ?? 0
        let rotation = video["rotation"] as? Int ?? 0
        return "debug status role=\(boot.role) core=\(core.isRunning) codec=\(codec) active=\(active) subscribers=\(subscribers) rotation=\(rotation)"
    }

    private func presentIncoming(door: String, purpose: String, visitorLang: String,
                                 callId: String, stageRevision: Int) {
        guard !callId.isEmpty else { return }
        guard let root = window?.rootViewController else { return }
        if let vc = root.presentedViewController as? IncomingViewController {
            vc.receive(door: door, purpose: purpose, visitorLang: visitorLang, callId: callId,
                       stageRevision: stageRevision)
            return
        }
        guard root.presentedViewController == nil else { return }
        let vc = IncomingViewController(core: core, boot: boot, door: door,
                                        purpose: purpose, visitorLang: visitorLang,
                                        callId: callId, stageRevision: stageRevision)
        root.present(vc, animated: true)
    }
}

private final class BootstrapSetupViewController: UIViewController {
    var onSave: ((String, String, String) -> Bool)?

    private let initial: BootConfig
    private let nameField = UITextField()
    private let roleControl = UISegmentedControl(items: [
        NSLocalizedString("admin.role_door", comment: ""),
        NSLocalizedString("admin.role_indoor", comment: "")
    ])
    private let doorField = UITextField()
    private let doorRow = UIStackView()
    private let errorLabel = UILabel()

    init(boot: BootConfig) {
        initial = boot
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Same dark/amber theme as the pairing screens that follow it, so first-run setup does
        // not flash a foreign white/blue page.
        view.backgroundColor = PairingTheme.background

        let title = UILabel()
        title.text = NSLocalizedString("setup.title", comment: "")
        title.font = UIFont.boldSystemFont(ofSize: 30)
        title.textAlignment = .center
        title.textColor = PairingTheme.foreground

        let message = UILabel()
        message.text = NSLocalizedString("setup.message", comment: "")
        message.font = UIFont.systemFont(ofSize: 17)
        message.textAlignment = .center
        message.numberOfLines = 0
        message.textColor = PairingTheme.dim

        for field in [nameField, doorField] {
            field.backgroundColor = UIColor(white: 1, alpha: 0.12)
            field.textColor = PairingTheme.foreground
        }
        roleControl.tintColor = PairingTheme.accent

        nameField.borderStyle = .roundedRect
        nameField.placeholder = NSLocalizedString("setup.name", comment: "")
        nameField.text = initial.name
        nameField.autocorrectionType = .no
        nameField.autocapitalizationType = .none

        roleControl.selectedSegmentIndex = initial.role == "indoor_panel" ? 1 : 0
        roleControl.addTarget(self, action: #selector(roleChanged), for: .valueChanged)

        doorField.borderStyle = .roundedRect
        doorField.placeholder = NSLocalizedString("setup.door_hint", comment: "")
        doorField.text = initial.suggestedDoor
        doorField.autocorrectionType = .no
        doorField.autocapitalizationType = .none

        let doorLabel = UILabel()
        doorLabel.text = NSLocalizedString("setup.door", comment: "")
        doorLabel.textColor = PairingTheme.dim
        doorLabel.setContentHuggingPriority(.required, for: .horizontal)
        doorRow.axis = .horizontal
        doorRow.spacing = 12
        doorRow.alignment = .center
        doorRow.addArrangedSubview(doorLabel)
        doorRow.addArrangedSubview(doorField)

        errorLabel.text = NSLocalizedString("setup.invalid_door", comment: "")
        errorLabel.textColor = PairingTheme.danger
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        let save = UIButton(type: .system)
        save.setTitle(NSLocalizedString("setup.finish", comment: ""), for: .normal)
        save.titleLabel?.font = UIFont.boldSystemFont(ofSize: 20)
        save.backgroundColor = PairingTheme.accent
        save.setTitleColor(.black, for: .normal)
        save.layer.cornerRadius = 8
        save.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        save.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, message, nameField, roleControl,
                                                   doorRow, errorLabel, save])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -36),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        ])
        roleChanged()
    }

    @objc private func roleChanged() {
        doorRow.isHidden = roleControl.selectedSegmentIndex == 1
        errorLabel.isHidden = true
    }

    @objc private func saveTapped() {
        view.endEditing(true)
        let role = roleControl.selectedSegmentIndex == 1 ? "indoor_panel" : "door_station"
        let door = role == "door_station" ? (doorField.text ?? "") : ""
        guard onSave?(nameField.text ?? "", role, door) == true else {
            errorLabel.isHidden = false
            return
        }
    }
}

private final class EmergencySystemNotifier {
    private let identifier = "doorbell.emergency"
    private var generation = 0
    private var expiryWork: DispatchWorkItem?

    func configure(application: UIApplication, delegate: AppDelegate) {
        if #available(iOS 10.0, *) {
            let center = UNUserNotificationCenter.current()
            center.delegate = delegate
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        } else {
            application.registerUserNotificationSettings(
                UIUserNotificationSettings(types: [.alert, .sound, .badge], categories: nil))
        }
    }

    /// `sosVolume` is the device's effective SOS level, resolved by Core; the notifier only
    /// decides whether a sound accompanies the alert.
    func handle(_ event: [String: Any], sosVolume: Int,
                report: @escaping ([String: Any]) -> Void) {
        generation += 1
        let currentGeneration = generation
        expiryWork?.cancel()
        expiryWork = nil

        let active = ConfigUtil.evBool(event, "active")
        let channels = ConfigUtil.eventChannels(event)
        let visual = event["visual"] == nil ? true : ConfigUtil.evBool(event, "visual")
        let sticky = event["sticky"] == nil ? active : ConfigUtil.evBool(event, "sticky")
        let ttl = max(0, ConfigUtil.double(event, "ttl_s", active ? 0 : 10))
        let volume = min(100, max(0, sosVolume))
        let requestedSound = !ConfigUtil.evStr(event, "alarm_sound").isEmpty ||
            !ConfigUtil.evStr(event, "audio_path").isEmpty
        let soundEnabled = volume > 0 && requestedSound
        let systemSoundEnabled = soundEnabled && (!channels.contains("in_app") || !active)
        var results: [[String: Any]] = []

        if channels.contains("in_app") {
            let colorLimitation = ConfigUtil.emergencyPalette(event).limitation
            results.append(channelResult(
                "in_app", result: active ? "presented" : "cleared",
                visual: visual && active, sound: soundEnabled && active,
                sticky: sticky && active, ttl: ttl,
                limitation: colorLimitation))
        }
        for channel in channels.sorted()
            where channel != "in_app" && channel != "system_notification" {
            results.append(channelResult(
                channel, result: "unsupported", visual: false, sound: false,
                sticky: false, ttl: 0, limitation: "unsupported_channel"))
        }

        func publish(_ channelResults: [[String: Any]]) {
            report([
                "schema_version": 1,
                "event_hlc": ConfigUtil.evStr(event, "event_hlc"),
                "active": active,
                "result": channelResults.isEmpty ? "not_requested" : "applied",
                "channels": channelResults,
                "updated_at_ms": Int64(Date().timeIntervalSince1970 * 1000),
            ])
        }

        if !active { clear() }
        guard channels.contains("system_notification") else {
            publish(results)
            scheduleExpiry(generation: currentGeneration, active: active, sticky: sticky,
                           ttl: ttl, results: results, publish: publish)
            return
        }

        let title = NSLocalizedString("emergency.title", comment: "")
        let source = ConfigUtil.evStr(event, "source")
        let bodyKey = active ? "emergency.notified" : "emergency.cancel"
        var body = NSLocalizedString(bodyKey, comment: "")
        if !source.isEmpty { body += " · " + source }
        var systemVisualApplied = visual
        var systemSoundApplied = systemSoundEnabled
        var permissionLimitations: [String] = []

        let finish: (String) -> Void = { [weak self] outcome in
            guard let self = self, self.generation == currentGeneration else { return }
            var limitations: [String] = []
            if sticky { limitations.append("sticky_system_notification_unsupported") }
            if !sticky && ttl > 0 && !self.canRemoveDeliveredNotification {
                limitations.append("delivered_notification_removal_unavailable")
            }
            if systemSoundEnabled && volume < 100 {
                limitations.append("system_notification_volume_is_binary")
            }
            if soundEnabled && !systemSoundEnabled {
                limitations.append("sound_owned_by_in_app_channel")
            }
            limitations.append(contentsOf: permissionLimitations)
            var updated = results
            updated.append(self.channelResult(
                "system_notification", result: outcome,
                visual: systemVisualApplied && outcome == "presented",
                sound: systemSoundApplied && outcome == "presented",
                sticky: false, ttl: ttl, limitation: limitations.joined(separator: ";")))
            publish(updated)
            self.scheduleExpiry(generation: currentGeneration, active: active,
                                sticky: sticky, ttl: ttl, results: updated, publish: publish)
        }

        guard visual || systemSoundEnabled else {
            finish("suppressed_by_presentation")
            return
        }
        if #available(iOS 10.0, *) {
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { [weak self] settings in
                DispatchQueue.main.async {
                    guard let self = self, self.generation == currentGeneration else { return }
                    guard self.notificationAuthorized(settings.authorizationStatus) else {
                        finish("permission_denied")
                        return
                    }
                    systemVisualApplied = visual && settings.alertSetting == .enabled
                    systemSoundApplied = systemSoundEnabled && settings.soundSetting == .enabled
                    if visual && !systemVisualApplied {
                        permissionLimitations.append("alert_permission_disabled")
                    }
                    if systemSoundEnabled && !systemSoundApplied {
                        permissionLimitations.append("sound_permission_disabled")
                    }
                    guard systemVisualApplied || systemSoundApplied else {
                        finish("permission_denied")
                        return
                    }
                    let content = UNMutableNotificationContent()
                    if systemVisualApplied {
                        content.title = title
                        content.body = body
                    }
                    content.threadIdentifier = self.identifier
                    content.userInfo = ["kind": active ? "emergency" : "emergency_cancel"]
                    if systemSoundApplied { content.sound = .default }
                    let request = UNNotificationRequest(identifier: self.identifier,
                                                        content: content, trigger: nil)
                    center.add(request) { error in
                        DispatchQueue.main.async {
                            finish(error == nil ? "presented" : "unsupported")
                        }
                    }
                }
            }
        } else {
            let allowed = UIApplication.shared.currentUserNotificationSettings?.types ?? []
            guard !allowed.isEmpty else {
                finish("permission_denied")
                return
            }
            systemVisualApplied = visual && allowed.contains(.alert)
            systemSoundApplied = systemSoundEnabled && allowed.contains(.sound)
            if visual && !systemVisualApplied {
                permissionLimitations.append("alert_permission_disabled")
            }
            if systemSoundEnabled && !systemSoundApplied {
                permissionLimitations.append("sound_permission_disabled")
            }
            guard systemVisualApplied || systemSoundApplied else {
                finish("permission_denied")
                return
            }
            let notification = UILocalNotification()
            if systemVisualApplied {
                notification.alertTitle = title
                notification.alertBody = body
            }
            notification.userInfo = ["kind": active ? "emergency" : "emergency_cancel"]
            if systemSoundApplied { notification.soundName = UILocalNotificationDefaultSoundName }
            UIApplication.shared.presentLocalNotificationNow(notification)
            finish("presented")
        }
    }

    private func channelResult(_ channel: String, result: String, visual: Bool,
                               sound: Bool, sticky: Bool, ttl: Double,
                               limitation: String) -> [String: Any] {
        var value: [String: Any] = [
            "channel": channel,
            "result": result,
            "visual_applied": visual,
            "sound_applied": sound,
            "sticky_applied": sticky,
            "ttl_s": ttl,
        ]
        if !limitation.isEmpty { value["limitation"] = limitation }
        return value
    }

    private func scheduleExpiry(generation expected: Int, active: Bool, sticky: Bool,
                                ttl: Double, results: [[String: Any]],
                                publish: @escaping ([[String: Any]]) -> Void) {
        guard !sticky, ttl > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == expected else { return }
            self.clear()
            let expired = results.map { item -> [String: Any] in
                var next = item
                if next["channel"] as? String == "system_notification" &&
                   !self.canRemoveDeliveredNotification {
                    next["result"] = "unsupported"
                    let removal = "delivered_notification_removal_unavailable"
                    let existing = next["limitation"] as? String ?? ""
                    if !existing.contains(removal) {
                        next["limitation"] = existing.isEmpty ? removal : existing + ";" + removal
                    }
                } else if next["result"] as? String != "permission_denied" &&
                          next["result"] as? String != "unsupported" {
                    next["result"] = active ? "ttl_expired" : "cleared"
                }
                return next
            }
            publish(expired)
        }
        expiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ttl, execute: work)
    }

    private var canRemoveDeliveredNotification: Bool {
        if #available(iOS 10.0, *) { return true }
        return false
    }

    @available(iOS 10.0, *)
    private func notificationAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        if status == .authorized { return true }
        if #available(iOS 12.0, *), status == .provisional { return true }
        return false
    }

    private func clear() {
        if #available(iOS 10.0, *) {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        } else {
            for notification in UIApplication.shared.scheduledLocalNotifications ?? []
                where notification.userInfo?["kind"] != nil {
                UIApplication.shared.cancelLocalNotification(notification)
            }
        }
    }
}

@available(iOS 10.0, *)
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.alert, .sound])
    }
}

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
