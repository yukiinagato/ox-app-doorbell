import UIKit

final class TVMainViewController: UIViewController {

    private let core: CoreBridge
    private let boot: BootConfig
    private let texts = Texts()
    private let audio = SirenPlayer()
    private let styleApplier = UIStyleApplier()
    private let deviceAlertReporter: ([String: Any]) -> Void

    private var cfg: [String: Any]?
    private var emergencyActive = false
    private var emergencyPresentationTimer: Timer?
    private var cancelRequiresPin = true
    private var nodeId = ""

    private let clockLabel = UILabel()
    private let dateLabel = UILabel()
    private let statusLabel = UILabel()
    private let monitorButton = UIButton(type: .system)
    private let membershipButton = UIButton(type: .system)
    private let nodeInfo = UILabel()
    private let replyBanner = UIView()
    private let replyCaption = UILabel()
    private let replyText = UILabel()
    private let emergencyView = UIView()
    private let emergencyTitle = UILabel()
    private let emergencyNote = UILabel()
    private let emergencyCancel = UIButton(type: .system)

    private var clockTimer: Timer?
    private var replyTimer: Timer?
    private var pairingObserver: NSObjectProtocol?
    private var pairingReady = false

    init(core: CoreBridge, boot: BootConfig,
         deviceAlertReporter: @escaping ([String: Any]) -> Void) {
        self.core = core
        self.boot = boot
        self.deviceAlertReporter = deviceAlertReporter
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let observer = pairingObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.063, green: 0.078, blue: 0.094, alpha: 1)
        texts.setLang(boot.uiLang)
        buildUi()
        refreshNodeInfo()
        core.addHandler("tv_main") { [weak self] ev in self?.onUiEvent(ev) }
        pairingObserver = NotificationCenter.default.addObserver(
            forName: .doorbellPairingChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPairingStatus() }
        refreshPairingStatus()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
        updateClock()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: "sos.cancel",
                           to: emergencyCancel)
    }

    private func buildUi() {
        clockLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 140, weight: .thin)
        clockLabel.textColor = UIColor(white: 0.94, alpha: 1)
        dateLabel.font = .systemFont(ofSize: 40)
        dateLabel.textColor = UIColor(white: 0.62, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 30)
        statusLabel.textColor = UIColor(white: 0.62, alpha: 1)
        monitorButton.titleLabel?.font = .systemFont(ofSize: 30, weight: .semibold)
        monitorButton.addTarget(self, action: #selector(openMonitor), for: .primaryActionTriggered)
        // Membership status is focusable so the remote reaches the Add-device panel without any
        // hidden gesture; while the device is not a member it reopens the onboarding screen.
        membershipButton.titleLabel?.font = .systemFont(ofSize: 28, weight: .semibold)
        membershipButton.accessibilityIdentifier = "membership_status"
        membershipButton.addTarget(self, action: #selector(openPairing),
                                   for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [clockLabel, dateLabel, statusLabel,
                                                   monitorButton, membershipButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        nodeInfo.font = .systemFont(ofSize: 24)
        nodeInfo.textColor = UIColor(white: 1, alpha: 0.35)
        nodeInfo.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nodeInfo)

        replyBanner.backgroundColor = UIColor(red: 0.11, green: 0.30, blue: 0.16, alpha: 0.97)
        replyBanner.layer.cornerRadius = 20
        replyBanner.isHidden = true
        replyBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(replyBanner)
        replyCaption.font = .systemFont(ofSize: 26)
        replyCaption.textColor = UIColor(white: 1, alpha: 0.7)
        replyText.font = .systemFont(ofSize: 44, weight: .bold)
        replyText.textColor = .white
        replyText.numberOfLines = 0
        replyText.textAlignment = .center
        let rstack = UIStackView(arrangedSubviews: [replyCaption, replyText])
        rstack.axis = .vertical
        rstack.spacing = 10
        rstack.alignment = .center
        rstack.translatesAutoresizingMaskIntoConstraints = false
        replyBanner.addSubview(rstack)

        emergencyView.backgroundColor = UIColor(red: 0.55, green: 0.05, blue: 0.04, alpha: 1)
        emergencyView.isHidden = true
        emergencyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emergencyView)
        emergencyTitle.font = .systemFont(ofSize: 100, weight: .heavy)
        emergencyTitle.textColor = .white
        emergencyNote.font = .systemFont(ofSize: 38)
        emergencyNote.textColor = UIColor(white: 1, alpha: 0.85)
        emergencyCancel.titleLabel?.font = .systemFont(ofSize: 34, weight: .semibold)
        emergencyCancel.addTarget(self, action: #selector(onEmergencyCancel),
                                  for: .primaryActionTriggered)
        let estack = UIStackView(arrangedSubviews: [emergencyTitle, emergencyNote,
                                                    emergencyCancel])
        estack.axis = .vertical
        estack.spacing = 40
        estack.alignment = .center
        estack.translatesAutoresizingMaskIntoConstraints = false
        emergencyView.addSubview(estack)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            nodeInfo.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 40),
            nodeInfo.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -30),
            replyBanner.topAnchor.constraint(equalTo: g.topAnchor, constant: 40),
            replyBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            replyBanner.widthAnchor.constraint(lessThanOrEqualTo: g.widthAnchor, constant: -120),
            rstack.topAnchor.constraint(equalTo: replyBanner.topAnchor, constant: 24),
            rstack.bottomAnchor.constraint(equalTo: replyBanner.bottomAnchor, constant: -24),
            rstack.leadingAnchor.constraint(equalTo: replyBanner.leadingAnchor, constant: 44),
            rstack.trailingAnchor.constraint(equalTo: replyBanner.trailingAnchor, constant: -44),
            emergencyView.topAnchor.constraint(equalTo: view.topAnchor),
            emergencyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emergencyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emergencyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            estack.centerXAnchor.constraint(equalTo: emergencyView.centerXAnchor),
            estack.centerYAnchor.constraint(equalTo: emergencyView.centerYAnchor),
        ])
    }

    private func applyStrings() {
        statusLabel.text = texts.t("panel.monitor_title")
        refreshPairingStatus()
        monitorButton.setTitle(texts.t("monitor.open"), for: .normal)
        replyCaption.text = texts.t("reply.banner")
        emergencyTitle.text = texts.t("emergency.title")
        emergencyNote.text = texts.t("emergency.notified")
        emergencyCancel.setTitle(texts.t("emergency.cancel"), for: .normal)
    }

    private func updateClock() {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: Date())
        clockLabel.text = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0,
                                 c.second ?? 0)
        let yobi = ["日", "月", "火", "水", "木", "金", "土"]
        dateLabel.text = String(format: "%d年%d月%d日 (%@)", c.year ?? 0, c.month ?? 0,
                                c.day ?? 0, yobi[((c.weekday ?? 1) - 1) % 7])
    }

    private func refreshNodeInfo() {
        cfg = core.config()
        texts.setConfig(cfg)
        cancelRequiresPin = ConfigUtil.bool(cfg, "emergency.cancel_requires_pin", true)
        if let st = core.status() {
            if let node = st["node"] as? [String: Any] {
                nodeId = ConfigUtil.evStr(node, "id")
                let peers = (st["peers"] as? [Any])?.count ?? 0
                nodeInfo.text =
                    "\(ConfigUtil.evStr(node, "name")) · v\(ConfigUtil.evStr(node, "version"))" +
                    " · peers \(peers)"
            }
            if let em = st["emergency"] as? [String: Any] {
                if !ConfigUtil.evBool(em, "active") { hideEmergency() }
            }
        }
        applyStrings()
    }


    private func onUiEvent(_ ev: [String: Any]) {
        switch ConfigUtil.evStr(ev, "t") {
        case "chime":
            let path = ConfigUtil.evStr(ev, "audio_path")
            if path.isEmpty {
                audio.playConfigured(ConfigUtil.evStr(ev, "sound"))
            } else {
                audio.playAsset(path: path, fallback: nil)
            }
        case "reply":
            replyText.text = ConfigUtil.evStr(ev, "text")
            replyBanner.isHidden = false
            var ttl = ConfigUtil.double(ev, "ttl_s", 30)
            if ttl <= 0 { ttl = 30 }
            replyTimer?.invalidate()
            replyTimer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) { [weak self] _ in
                self?.replyBanner.isHidden = true
            }
        case "emergency":
            presentEmergency(ev)
        case "peers_changed", "config_changed":
            refreshNodeInfo()
        case "pairing_state", "paired", "device_joined", "pending_changed":
            refreshPairingStatus()
        default:
            break
        }
    }

    /// Renders the authoritative snapshot: membership when ready, the not-set-up prompt when not.
    private func refreshPairingStatus() {
        let snapshot = PairingSnapshot.load(core)
        guard snapshot.hasSnapshot else {
            membershipButton.isHidden = true
            return
        }
        membershipButton.isHidden = false
        pairingReady = snapshot.state == .ready
        guard pairingReady else {
            membershipButton.setTitle(texts.t("pair.not_set_up_banner"), for: .normal)
            return
        }
        var title = texts.t("pair.membership",
                            "\(max(snapshot.memberCount, snapshot.paired ? 1 : 0))")
        if snapshot.connectedCount > 0 {
            title += " · " + texts.t("pair.membership_connected", "\(snapshot.connectedCount)")
        }
        membershipButton.setTitle(title, for: .normal)
    }

    @objc private func openPairing() {
        guard presentedViewController == nil else { return }
        guard pairingReady else {
            NotificationCenter.default.post(name: .doorbellOpenPairing, object: nil)
            return
        }
        let dlg = AdminPinViewController(texts: texts)
        dlg.onUnlocked = { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            self.present(AddDeviceViewController(core: self.core, boot: self.boot,
                                                 texts: self.texts), animated: true)
        }
        present(dlg, animated: true)
    }

    @objc private func openMonitor() {
        guard presentedViewController == nil else { return }
        present(MonitorViewController(core: core, boot: boot), animated: true)
    }


    private func presentEmergency(_ ev: [String: Any]) {
        emergencyPresentationTimer?.invalidate()
        emergencyPresentationTimer = nil
        let active = ConfigUtil.evBool(ev, "active")
        let eventHlc = ConfigUtil.evStr(ev, "event_hlc")
        let requestedInApp = ConfigUtil.eventUsesChannel(ev, "in_app")
        guard active else {
            hideEmergency()
            reportDeviceAlert(eventHlc: eventHlc, active: false,
                              result: requestedInApp ? "cleared" : "not_requested",
                              visual: false, sound: false, sticky: false, ttl: 0,
                              requested: requestedInApp)
            return
        }
        guard requestedInApp else {
            hideEmergency()
            reportDeviceAlert(eventHlc: eventHlc, active: true, result: "not_requested",
                              visual: false, sound: false, sticky: false, ttl: 0,
                              requested: false)
            return
        }
        let visual = ev["visual"] == nil ? true : ConfigUtil.evBool(ev, "visual")
        showEmergency(visual: visual)
        let sound = ConfigUtil.evStr(ev, "alarm_sound")
        let path = ConfigUtil.evStr(ev, "audio_path")
        let volume = min(100, max(0, ConfigUtil.int(ev, "alarm_volume", 100)))
        let soundApplied = volume > 0 && (!sound.isEmpty || !path.isEmpty)
        if soundApplied {
            audio.startSiren(customPath: path, volume: volume)
        } else {
            audio.stop()
        }
        let sticky = ev["sticky"] == nil ? true : ConfigUtil.evBool(ev, "sticky")
        let ttl = max(0, ConfigUtil.double(ev, "ttl_s", 0))
        reportDeviceAlert(eventHlc: eventHlc, active: true, result: "presented",
                          visual: visual, sound: soundApplied, sticky: sticky, ttl: ttl,
                          requested: true)
        if !sticky && ttl > 0 {
            emergencyPresentationTimer = Timer.scheduledTimer(
                withTimeInterval: ttl, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.hideEmergency()
                    self.reportDeviceAlert(eventHlc: eventHlc, active: true,
                                           result: "ttl_expired", visual: false,
                                           sound: false, sticky: false, ttl: ttl,
                                           requested: true)
                }
        }
    }

    private func reportDeviceAlert(eventHlc: String, active: Bool, result: String,
                                   visual: Bool, sound: Bool, sticky: Bool, ttl: Double,
                                   requested: Bool) {
        var channels: [[String: Any]] = []
        if requested {
            channels.append([
                "channel": "in_app",
                "result": result,
                "visual_applied": visual,
                "sound_applied": sound,
                "sticky_applied": sticky,
                "ttl_s": ttl,
            ])
        }
        deviceAlertReporter([
            "schema_version": 1,
            "event_hlc": eventHlc,
            "active": active,
            "result": requested ? "applied" : "not_requested",
            "channels": channels,
            "updated_at_ms": Int64(Date().timeIntervalSince1970 * 1000),
        ])
    }

    private func showEmergency(visual: Bool) {
        if emergencyActive {
            emergencyView.isHidden = !visual
            return
        }
        emergencyActive = true
        if visual {
            presentedViewController?.dismiss(animated: false)
            emergencyView.isHidden = false
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        } else {
            emergencyView.isHidden = true
        }
    }

    private func hideEmergency() {
        guard emergencyActive else { return }
        emergencyActive = false
        emergencyPresentationTimer?.invalidate()
        emergencyPresentationTimer = nil
        audio.stop()
        emergencyView.isHidden = true
    }

    @objc private func onEmergencyCancel() {
        if cancelRequiresPin {
            let dlg = AdminPinViewController(texts: texts)
            dlg.onUnlocked = { [weak self] in
                guard let self = self, self.core.emergency(false) else { return }
                self.hideEmergency()
            }
            present(dlg, animated: true)
            return
        }
        if core.emergency(false) { hideEmergency() }
    }
}
