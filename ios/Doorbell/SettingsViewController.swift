import UIKit

/// The settings screen presented from the home screen's admin entry. On iPhone it is a grouped
/// drill-down in a navigation controller; on iPad and Apple TV it is a master–detail split with the
/// category list on the left, like the system Settings app. It owns the config writer, and leaving
/// it closes the native admin window.
final class SettingsViewController: UIViewController, SettingsHosting, UISplitViewControllerDelegate {

    let core: CoreBridge
    private(set) var boot: BootConfig
    let texts: Texts
    private let writer: ConfigWriter
    private(set) var palette = DoorbellPalette.dark
    private(set) var usesSplit = false

    /// The screen that hosts settings supplies these so the entries behave exactly as they do
    /// from the home screen.
    var onOpenAddDevice: (() -> Void)?
    var onExitKiosk: (() -> Void)?
    var onOpenDeviceInfo: (() -> Void)?

    private let screens = NSHashTable<AnyObject>.weakObjects()
    private var categoryList: SettingsCategoryListController?
    private let toast = UILabel()
    private var toastTimer: Timer?
    private let preview = SirenPlayer()
    private var pendingName: String
    private var pendingRole: String
    private var pendingDoor: String
    private var currentPassword = ""
    private var newPassword = ""

    init(core: CoreBridge, boot: BootConfig, texts: Texts) {
        self.core = core
        self.boot = boot
        self.texts = texts
        self.writer = ConfigWriter(core: core, httpPort: boot.httpPort)
        pendingName = boot.name
        pendingRole = boot.role
        pendingDoor = boot.door
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: Layout

    override func viewDidLoad() {
        super.viewDidLoad()
        let config = core.config()
        palette = DoorbellPalette.of(DoorbellTheme.appearance(
            config: config, nodeId: nodeId(), localTime: core.localTime()))
        view.backgroundColor = palette.background
        #if os(tvOS)
        usesSplit = true
        #else
        usesSplit = UIDevice.current.userInterfaceIdiom == .pad
        #endif

        let list = SettingsCategoryListController(host: self)
        list.onClose = { [weak self] in self?.dismiss(animated: true) }
        categoryList = list
        let master = UINavigationController(rootViewController: list)
        SettingsStyle.apply(palette, to: master.navigationBar)
        let root: UIViewController
        if usesSplit {
            let split = UISplitViewController()
            let firstId = catalog().categories().first?.id ?? "device"
            let detail = UINavigationController(
                rootViewController: SettingsPageController(host: self, path: [firstId]))
            SettingsStyle.apply(palette, to: detail.navigationBar)
            split.viewControllers = [master, detail]
            split.delegate = self
            split.preferredDisplayMode = .allVisible
            split.preferredPrimaryColumnWidthFraction = 0.34
            split.maximumPrimaryColumnWidth = 380
            split.view.backgroundColor = palette.background
            root = split
            list.select(firstId)
        } else {
            root = master
        }
        addChild(root)
        root.view.frame = view.bounds
        root.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(root.view)
        root.didMove(toParent: self)
        buildToast()
        // Announcements, remote edits and replication land here too, so an open page never shows a
        // value another device has since changed.
        core.addHandler(SettingsViewController.handlerKey) { [weak self] ev in
            let kind = ConfigUtil.evStr(ev, "t")
            if ["config_changed", "notice_changed", "peers_changed", "pairing_state",
                "cluster_key_changed", "peer_rejected"].contains(kind) {
                self?.refreshAll()
            }
        }
    }

    private static let handlerKey = "settings

    /// An iPad in compact multitasking shows the category list first, never an orphan detail.
    func splitViewController(_ splitViewController: UISplitViewController,
                             collapseSecondary secondaryViewController: UIViewController,
                             onto primaryViewController: UIViewController) -> Bool {
        return true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Leaving settings closes the native admin window (security protocol v3 §10); a screen
        // presented over settings is not a departure.
        if isBeingDismissed || presentingViewController == nil {
            core.adminLock()
            core.removeHandler(SettingsViewController.handlerKey)
        }
    }

    private func buildToast() {
        toast.backgroundColor = palette.surfaceStrongSolid
        toast.textColor = palette.ink
        toast.textAlignment = .center
        toast.numberOfLines = 0
        toast.font = .systemFont(ofSize: 15, weight: .semibold)
        toast.layer.cornerRadius = 10
        toast.clipsToBounds = true
        toast.alpha = 0
        toast.accessibilityIdentifier = "settings_status"
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
            toast.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
    }

    func setStatus(_ message: String) {
        guard !message.isEmpty else { return }
        toast.text = "  " + message + "  "
        view.bringSubviewToFront(toast)
        UIView.animate(withDuration: 0.2) { self.toast.alpha = 1 }
        toastTimer?.invalidate()
        toastTimer = IOSAvailability.scheduledTimer(withTimeInterval: 2.5, repeats: false) {
            [weak self] _ in UIView.animate(withDuration: 0.3) { self?.toast.alpha = 0 }
        }
    }

    // MARK: SettingsHosting

    private func nodeId() -> String {
        return ConfigUtil.evStr((core.status()?["node"] as? [String: Any]) ?? [:], "id")
    }

    func catalog() -> SettingsCatalog {
        let status = core.status()
        var ctx = SettingsContext(config: core.config(), status: status, nodeId: nodeId(),
                                  name: pendingName, role: pendingRole, door: pendingDoor,
                                  uiLang: boot.uiLang, isTV: SettingsStyle.isTV)
        ctx.supportsPasswordChange = core.supportsAdminPasswordChange
        ctx.sipBackend = core.sipBackend
        ctx.audioVolumes = core.audioVolumes()
        ctx.previewRate = DashboardView.previewRateValue(DashboardView.savedPreviewFramesPerSecond)
        ctx.previewRates = DashboardView.previewRates.map(DashboardView.previewRateValue)
        let snapshot = PairingSnapshot.load(core)
        ctx.membershipSummary = snapshot.hasSnapshot
            ? texts.t("pair.membership", "\(max(snapshot.memberCount, snapshot.paired ? 1 : 0))") : ""
        let unread = CallHistory.unreadMissed(core)
        ctx.historySummary = unread > 0 ? texts.t("history.missed_badge", "\(unread)") : ""
        let power = (status?["self"] as? [String: Any])?["power"] as? [String: Any]
        ctx.versionLine = DoorbellTheme.versionLine(name: boot.name, coreVersion: DoorbellTheme.coreVersion(),
                                                    texts: texts, power: power)
        ctx.coreVersion = DoorbellTheme.shortVersion(DoorbellTheme.coreVersion())
        let lastSync = Int64(ConfigUtil.double(status?["time"] as? [String: Any], "last_sync_ms", 0))
        ctx.lastSyncText = lastSync > 0 ? DoorbellClock.timeOfDay(core, wallMs: lastSync) : ""
        ctx.nowMs = DoorbellClock.nowMs(core)
        ctx.pskId = snapshot.security.pskId
        ctx.staleMembers = snapshot.security.legacyPeers.count + snapshot.security.rekeyRequired.count
        ctx.canRotateKey = core.supportsKeyRotation && snapshot.state == .ready
        return SettingsCatalog(ctx, texts: texts)
    }

    func register(_ screen: SettingsRefreshable) { screens.add(screen) }

    func refreshAll() {
        for case let screen as SettingsRefreshable in screens.allObjects { screen.refreshFromHost() }
    }

    func show(_ controller: UIViewController, from: UIViewController) {
        if let nav = from.navigationController {
            nav.pushViewController(controller, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: controller)
            SettingsStyle.apply(palette, to: nav.navigationBar)
            from.present(nav, animated: true)
        }
    }

    func commit(_ item: SettingItem, _ value: SettingValue, from: UIViewController) {
        guard let commit = item.commit else { return }
        perform(commit(value), item: item, value: value, from: from, completion: nil)
    }

    func perform(_ effect: SettingEffect, item: SettingItem?, value: SettingValue?,
                 from: UIViewController, completion: ((Bool) -> Void)?) {
        switch effect {
        case .write(let operations):
            writer.apply(operations) { [weak self] result in
                guard let self = self else { return }
                self.setStatus(ConfigWriter.message(self.texts, result))
                self.refreshAll()
                completion?(result.isOk)
            }
        case .invalid(let key):
            setStatus(texts.t(key))
            refreshAll()
            completion?(false)
        case .local(let id):
            completion?(performLocal(id, value: value, from: from))
        case .none:
            completion?(true)
        }
    }

    // MARK: Shell actions

    @discardableResult
    private func performLocal(_ id: String, value: SettingValue?, from: UIViewController) -> Bool {
        switch id {
        case "identity.name", "identity.role", "identity.door":
            guard let text = value?.stringValue else { return false }
            if id == "identity.name" { pendingName = text }
            if id == "identity.role" { pendingRole = text }
            if id == "identity.door" { pendingDoor = text }
            guard let updated = BootConfig.persistSetup(name: pendingName, role: pendingRole,
                                                        door: pendingDoor) else {
                setStatus(texts.t("settings.save_failed"))
                return false
            }
            boot = updated
            setStatus(texts.t(id == "identity.role" ? "settings.role_restart_notice" : "settings.saved"))
            refreshAll()
            return true
        case "password.current":
            currentPassword = value?.stringValue ?? ""
            return true
        case "password.new":
            newPassword = value?.stringValue ?? ""
            return true
        case "password.apply":
            applyPasswordChange()
            return true
        case "preview_rate":
            guard let rate = value?.stringValue.flatMap(Double.init) else { return false }
            UserDefaults.standard.set(rate, forKey: DashboardView.previewRateDefaultsKey)
            refreshAll()
            return true
        case "preview.call", "preview.sos", "preview.idle":
            play(String(id.dropFirst("preview.".count)))
            return true
        case "time.sync":
            syncTime()
            return true
        case "cluster.rotate":
            confirmKeyRotation(from: from)
            return true
        case "exit_kiosk":
            dismiss(animated: true) { [weak self] in self?.onExitKiosk?() }
            return true
        default:
            return false
        }
    }

    /// Rotation drops every device that is offline for longer than the seven-day grace period, so
    /// it is confirmed first.
    private func confirmKeyRotation(from: UIViewController) {
        let alert = UIAlertController(title: texts.t("prefs.rotate_key"),
                                      message: texts.t("prefs.rotate_key_confirm"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: texts.t("prefs.rotate_key"), style: .destructive) {
            [weak self] _ in
            guard let self = self else { return }
            self.setStatus(self.texts.t(self.core.rotateClusterKey() == 0 ? "pair.cluster_key_changed"
                                                                            : "prefs.rotate_key_failed"))
            self.refreshAll()
        })
        present(alert, animated: true)
    }

    private func applyPasswordChange() {
        guard newPassword.count >= 8 else {
            setStatus(texts.t("prefs.password_too_short"))
            return
        }
        switch core.setAdminPassword(current: currentPassword, new: newPassword) {
        case .ok:
            setStatus(texts.t("settings.password_changed"))
            currentPassword = ""
            newPassword = ""
            refreshAll()
        case .wrongCurrent: setStatus(texts.t("admin.pin_wrong"))
        case .lockedOut: setStatus(texts.t("admin.locked"))
        case .failed: setStatus(texts.t("settings.password_failed"))
        }
    }

    private func play(_ name: String) {
        let config = core.config()
        let value = ConfigUtil.int(core.audioVolumes(), name, 80)
        preview.volume = value
        switch name {
        case "sos":
            preview.startSiren(customPath: "", volume: value)
            _ = IOSAvailability.scheduledTimer(withTimeInterval: 1.5, repeats: false) {
                [weak self] _ in self?.preview.stop()
            }
        case "call":
            preview.playConfigured(ConfigUtil.str(config, "ui.ringtone") ?? "school_chime")
        default:
            preview.playConfigured(ConfigUtil.str(config, "ui.button_sound") ?? "button_click")
        }
    }

    private func syncTime() {
        guard ConfigUtil.bool(core.config(), "time.ntp.enabled", false) else {
            setStatus(texts.t("time.ntp_off"))
            return
        }
        let previous = ConfigUtil.double(core.status()?["time"] as? [String: Any], "last_sync_ms", 0)
        guard core.timeSyncNow() else {
            setStatus(texts.t("time.sync_failed"))
            return
        }
        setStatus(texts.t("time.sync_started"))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for _ in 0..<60 {
                Thread.sleep(forTimeInterval: 0.1)
                guard let status = self?.core.status()?["time"] as? [String: Any],
                      !ConfigUtil.bool(status, "syncing", false) else { continue }
                let succeeded = ConfigUtil.double(status, "last_sync_ms", 0) > previous
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.setStatus(self.texts.t(succeeded ? "time.sync_succeeded" : "time.sync_result_failed"))
                    self.refreshAll()
                }
                return
            }
        }
    }

    func openShell(_ id: String, title: String, from: UIViewController) {
        if id.hasPrefix("notice:") {
            let door = String(id.dropFirst("notice:".count))
            let dialog = NoticeDialogViewController(core: core, texts: texts, httpPort: boot.httpPort,
                                                    lang: boot.uiLang, door: door)
            dialog.modalPresentationStyle = NoticeDialogViewController.overCallPresentationStyle
            present(dialog, animated: true)
            return
        }
        switch id {
        case "history":
            present(CallHistoryViewController(core: core, texts: texts, lang: boot.uiLang), animated: true)
        case "add_device":
            guard let handler = onOpenAddDevice else { return }
            dismiss(animated: true) { handler() }
        case "device_info":
            guard let handler = onOpenDeviceInfo else { return }
            dismiss(animated: true) { handler() }
        case "web_admin":
            openWeb(title: title, reason: "", from: from)
        default:
            break
        }
    }

    func openWeb(title: String, reason: String, from: UIViewController) {
        show(SettingsWebAdminController(core: core, boot: boot, texts: texts, palette: palette,
                                        title: title, reason: reason), from: from)
    }

    /// Notice dialogs and history refresh the summaries when they close.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isViewLoaded { refreshAll() }
    }
}

/// Whether the 開錠 control is offered, and whether it would actually do anything. Core resolves
/// both and publishes them as `status.doors.<id>.unlock`; the configuration fallback below only
/// matters on a Core that predates that contract.
enum DoorUnlock {
    static func isConfigured(status: [String: Any]?, config: [String: Any]?,
                             door: String) -> Bool {
        if !door.isEmpty,
           let value = ConfigUtil.dig(status, "doors.\(door).unlock.configured") as? NSNumber {
            return value.boolValue
        }
        guard let actions = ConfigUtil.dig(config, "sip.dtmf_actions") as? [String: Any] else {
            return false
        }
        for value in actions.values {
            let entry = value as? [String: Any]
            if ConfigUtil.str(entry, "type") == "ha_command",
               !(ConfigUtil.str(entry, "command") ?? "").isEmpty { return true }
        }
        return false
    }

    static func showsButton(status: [String: Any]?, config: [String: Any]?,
                            door: String) -> Bool {
        if !door.isEmpty,
           let value = ConfigUtil.dig(status, "doors.\(door).unlock.show_button") as? NSNumber {
            return value.boolValue
        }
        if !door.isEmpty,
           let explicit = ConfigUtil.dig(config, "doors.\(door).unlock.show_button") as? NSNumber {
            return explicit.boolValue
        }
        return isConfigured(status: status, config: config, door: door)
    }
}
