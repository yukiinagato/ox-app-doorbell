import AVFoundation
import Security
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
    /// Uploads, secrets, panels and import/export: the native editors' shell actions.
    private lazy var editorActions = SettingsEditorActions(host: self)

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

    private static let handlerKey = "settings"

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
            return editorActions.perform(id, value: value, from: from)
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
        case "panels":
            editorActions.openPanels(from: from)
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

// MARK: - Shell actions of the native editors

/// What the settings catalog cannot do as a plain configuration write: secrets into the
/// Keychain, photo and sound uploads into the asset ledger, the administrator-session operations
/// (Web panels, configuration import, the Telegram test) and device removal.
final class SettingsEditorActions: NSObject {
    private weak var host: SettingsViewController?
    private var session: LoopbackAdminSession?
    private var pickerKey = ""
    #if os(iOS)
    private var recorder: AVAudioRecorder?
    #endif

    init(host: SettingsViewController) {
        self.host = host
        super.init()
    }

    private var core: CoreBridge? { return host?.core }

    private func t(_ key: String) -> String { return host?.texts.t(key) ?? key }

    private func status(_ key: String) { host?.setStatus(t(key)) }

    private func write(_ operations: [ConfigWriter.Operation], from: UIViewController) {
        host?.perform(.write(operations), item: nil, value: nil, from: from, completion: nil)
    }

    static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return "" }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func perform(_ id: String, value: SettingValue?, from: UIViewController) -> Bool {
        let parts = id.components(separatedBy: "|")
        switch parts[0] {
        case "secret":
            guard parts.count == 3, let secret = value?.stringValue, !secret.isEmpty else { return false }
            return storeSecret(secret, base: parts[1], key: parts[2], from: from)
        case "mediasecret":
            guard parts.count == 2, let secret = value?.stringValue, !secret.isEmpty else { return false }
            return storeMediaSecret(secret, source: parts[1], from: from)
        case "asset.remove":
            guard parts.count == 2 else { return false }
            removeAsset(parts[1])
            return true
        case "device.remove":
            guard parts.count == 2 else { return false }
            removeDevice(parts[1], from: from)
            return true
        case "telegram.test":
            telegramTest(from: from)
            return true
        #if os(iOS)
        case "asset.image":
            pickImage(key: parts.count == 2 ? parts[1] : "", from: from)
            return true
        case "asset.record":
            recordSound(from: from)
            return true
        case "asset.file":
            importAudioFile(from: from)
            return true
        case "config.export":
            exportConfig()
            return true
        case "config.import":
            importConfig(from: from)
            return true
        #endif
        default:
            return false
        }
    }

    // MARK: Secrets

    /// A fresh reference per change, as the web admin does: peers that still hold the old value
    /// keep working until they fetch the new one.
    private func storeSecret(_ secret: String, base: String, key: String, from: UIViewController) -> Bool {
        let suffix = SettingsEditorActions.randomHex(4)
        guard let core = core, !suffix.isEmpty else { return false }
        let name = "\(base).\(suffix)"
        guard core.storeSecret(name, secret) else {
            status("editor.secret_store_failed")
            return false
        }
        write([.set(key, "secret:\(name)")], from: from)
        return true
    }

    private func storeMediaSecret(_ secret: String, source: String, from: UIViewController) -> Bool {
        let suffix = SettingsEditorActions.randomHex(4)
        guard let core = core, !suffix.isEmpty,
              var entry = ConfigUtil.dig(core.config(), "media_sources.\(source)") as? [String: Any]
        else { return false }
        let name = "media.\(source).\(suffix)"
        guard core.storeSecret(name, secret) else {
            status("editor.secret_store_failed")
            return false
        }
        // A media source is always replaced as one complete definition.
        entry["secret_ref"] = "secret:\(name)"
        write([.set("media_sources.\(source)", entry)], from: from)
        return true
    }

    // MARK: Assets

    private func upload(_ data: Data, type: String, label: String, key: String, from: UIViewController) {
        guard let core = core else { return }
        guard core.supportsAssets else {
            status("editor.core_too_old")
            return
        }
        let result = core.addAsset(data, type: type, label: label)
        let hash = ConfigUtil.str(result, "hash") ?? ""
        if ConfigUtil.bool(result, "ok", false), !hash.isEmpty {
            if key.isEmpty {
                status("settings.saved")
                host?.refreshAll()
            } else {
                write([.set(key, hash)], from: from)
            }
            return
        }
        if ConfigUtil.str(result, "err") == "admin_required" {
            AdminReauthentication.request(core: core) { [weak self] unlocked in
                if unlocked { self?.upload(data, type: type, label: label, key: key, from: from) }
            }
            return
        }
        host?.setStatus(t("settings.save_failed") + " " + (ConfigUtil.str(result, "err") ?? ""))
    }

    private func removeAsset(_ hash: String) {
        guard let core = core else { return }
        let result = core.removeAsset(hash)
        if ConfigUtil.bool(result, "ok", false) {
            status("settings.saved")
        } else if ConfigUtil.str(result, "err") == "admin_required" {
            AdminReauthentication.request(core: core) { [weak self] unlocked in
                if unlocked { self?.removeAsset(hash) }
            }
            return
        } else {
            status("settings.save_failed")
        }
        host?.refreshAll()
    }

    private func removeDevice(_ id: String, from: UIViewController) {
        guard let core = core else { return }
        var code = core.removeDeviceV2(id)
        if code == -100 {
            core.removeDevice(id)
            code = 0
        }
        if code == CoreBridge.resultAdminRequired {
            AdminReauthentication.request(core: core) { [weak self] unlocked in
                if unlocked { self?.removeDevice(id, from: from) }
            }
            return
        }
        status(code == 0 ? "settings.saved" : "settings.save_failed")
        if code == 0 { from.navigationController?.popViewController(animated: true) }
        host?.refreshAll()
    }

    // MARK: Administrator session

    func withSession(from: UIViewController, then: @escaping (LoopbackAdminSession) -> Void) {
        if let session = session {
            then(session)
            return
        }
        let alert = UIAlertController(title: t("editor.password_for_session"), message: nil,
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: t("admin.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: t("editor.ok"), style: .default) { [weak self, weak alert] _ in
            guard let self = self, let password = alert?.textFields?.first?.text, !password.isEmpty,
                  let port = self.host?.boot.httpPort else { return }
            LoopbackAdminSession.open(password: password, port: port) { [weak self] session, error in
                guard let self = self else { return }
                guard let session = session else {
                    self.status(error == "password" ? "editor.password_wrong" : "editor.unreachable")
                    return
                }
                self.session = session
                then(session)
            }
        })
        from.present(alert, animated: true)
    }

    private func telegramTest(from: UIViewController) {
        var chat = ""
        let households = ConfigUtil.dig(core?.config(), "households") as? [String: Any] ?? [:]
        for id in ConfigUtil.sortedByOrder(households) {
            if let first = ((households[id] as? [String: Any])?["telegram_chat_ids"] as? [Any])?.first {
                chat = "\(first)"
                break
            }
        }
        let alert = UIAlertController(title: t("editor.chat_id"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = chat
            field.keyboardType = .numbersAndPunctuation
        }
        alert.addAction(UIAlertAction(title: t("admin.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: t("editor.test_message"), style: .default) {
            [weak self, weak alert, weak from] _ in
            guard let self = self, let from = from,
                  let target = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces),
                  !target.isEmpty else { return }
            self.withSession(from: from) { [weak self] session in
                session.request("POST", "/api/test/telegram", body: ["chat_id": target]) { status, json in
                    guard let self = self else { return }
                    let ok = status == 200 && ConfigUtil.bool(json, "ok", false)
                    self.host?.setStatus(ok ? self.t("admin.test_sent")
                        : self.t("settings.save_failed") + " " + (ConfigUtil.str(json, "err") ?? ""))
                }
            }
        })
        from.present(alert, animated: true)
    }

    func openPanels(from: UIViewController) {
        guard host != nil else { return }
        withSession(from: from) { [weak self] session in
            guard let self = self, let host = self.host else { return }
            host.show(PanelAdminController(host: host, session: session, actions: self), from: from)
        }
    }

    func forgetSession() { session = nil }
}

#if os(iOS)
extension SettingsEditorActions: UIImagePickerControllerDelegate, UINavigationControllerDelegate,
    UIDocumentPickerDelegate, AVAudioRecorderDelegate {

    // MARK: Photos

    fileprivate func pickImage(key: String, from: UIViewController) {
        guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else {
            status("editor.no_photos")
            return
        }
        pickerKey = key
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.mediaTypes = ["public.image"]
        picker.delegate = self
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = from.view
        picker.popoverPresentationController?.sourceRect =
            CGRect(x: from.view.bounds.midX, y: 80, width: 1, height: 1)
        from.present(picker, animated: true)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    /// At most 1600 px on the long edge, JPEG, comfortably below Core's 3 MiB asset limit.
    static func jpeg(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > 1600 ? 1600 / longest : 1
        let size = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        image.draw(in: CGRect(origin: .zero, size: size))
        let scaled = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        var quality: CGFloat = 0.85
        var data = scaled.flatMap { $0.jpegData(compressionQuality: quality) }
        while let current = data, current.count > 2_800_000, quality > 0.35 {
            quality -= 0.15
            data = scaled.flatMap { $0.jpegData(compressionQuality: quality) }
        }
        return data
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        var target: UIViewController? = picker.presentingViewController
        if target == nil { target = host }
        picker.dismiss(animated: true)
        guard let picked = image, let data = SettingsEditorActions.jpeg(picked), let from = target else {
            status("settings.save_failed")
            return
        }
        upload(data, type: "image/jpeg", label: "photo.jpg", key: pickerKey, from: from)
    }

    // MARK: Sounds

    /// 16 kHz mono 16-bit WAV, at most 60 seconds (about 1.9 MB).
    fileprivate func recordSound(from: UIViewController) {
        guard let core = core, core.supportsAssets else {
            status("editor.core_too_old")
            return
        }
        guard IOSAvailability.configureCallAudioSession(AVAudioSession.sharedInstance()) else {
            status("editor.no_microphone")
            return
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doorbell-recording.wav")
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings),
              recorder.record(forDuration: 60) else {
            status("editor.no_microphone")
            return
        }
        recorder.delegate = self
        self.recorder = recorder
        let alert = UIAlertController(title: t("editor.recording"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: t("editor.stop_recording"), style: .default) { [weak self] _ in
            self?.recorder?.stop()
        })
        from.present(alert, animated: true)
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        self.recorder = nil
        let url = recorder.url
        let data: Data? = flag ? (try? Data(contentsOf: url)) : nil
        try? FileManager.default.removeItem(at: url)
        guard let host = host else { return }
        if let alert = host.presentedViewController as? UIAlertController { alert.dismiss(animated: true) }
        guard let recorded = data, recorded.count > 1024 else {
            status("settings.save_failed")
            return
        }
        let name = UIAlertController(title: t("editor.sound_name"), message: nil, preferredStyle: .alert)
        name.addTextField { $0.placeholder = "chime.wav" }
        name.addAction(UIAlertAction(title: t("editor.ok"), style: .default) { [weak self, weak name] _ in
            guard let self = self, let host = self.host else { return }
            let text = name?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            self.upload(recorded, type: "audio/wav", label: text.isEmpty ? "recording.wav" : text,
                        key: "", from: host)
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak host] in
            host?.present(name, animated: true)
        }
    }

    fileprivate func importAudioFile(from: UIViewController) {
        if #available(iOS 11.0, *) {
            let picker = UIDocumentPickerViewController(documentTypes: ["public.audio"], in: .import)
            picker.delegate = self
            from.present(picker, animated: true)
        } else {
            recordSound(from: from)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let host = host else { return }
        let ext = url.pathExtension.lowercased()
        let type = ext == "mp3" ? "audio/mpeg" : (ext == "wav" ? "audio/wav" : "")
        guard !type.isEmpty, let data = try? Data(contentsOf: url) else {
            status("settings.save_failed")
            return
        }
        upload(data, type: type, label: url.lastPathComponent, key: "", from: host)
    }

    // MARK: Configuration export and import

    fileprivate func exportConfig() {
        guard let snapshot = core?.configSnapshot() else {
            status("editor.core_too_old")
            return
        }
        let document: [String: Any] = ["schema_version": 2,
                                       "config": snapshot["config"] as? [String: Any] ?? [:]]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else {
            status("settings.save_failed")
            return
        }
        UIPasteboard.general.string = json
        host?.setStatus(host?.texts.t("editor.exported", "\(data.count / 1024 + 1)") ?? "")
    }

    fileprivate func importConfig(from: UIViewController) {
        guard let text = UIPasteboard.general.string, let data = text.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            status("editor.clipboard_not_config")
            return
        }
        let config = parsed["config"] as? [String: Any] ?? parsed
        guard let core = core, let revision = ConfigUtil.str(core.configSnapshot(), "revision") else {
            status("editor.core_too_old")
            return
        }
        withSession(from: from) { [weak self, weak from] session in
            guard let self = self, let from = from else { return }
            let stage = core.configImport("stage", request: [
                "schema_version": 2, "expected_revision": revision,
                "document": ["schema_version": 2, "config": config]], session: session.session,
                csrf: session.csrf)
            guard ConfigUtil.bool(stage, "ok", false), let token = ConfigUtil.str(stage, "stage_token"),
                  let digest = ConfigUtil.str(stage, "digest") else {
                self.host?.setStatus(self.t("settings.save_failed") + " "
                    + (ConfigUtil.str(stage, "error_code") ?? ConfigUtil.str(stage, "err") ?? ""))
                return
            }
            let envelope: [String: Any] = ["schema_version": 2, "stage_token": token, "digest": digest]
            let preflight = core.configImport("preflight", request: envelope, session: session.session,
                                              csrf: session.csrf)
            guard ConfigUtil.bool(preflight, "can_commit", false) else {
                _ = core.configImport("cancel", request: envelope, session: session.session,
                                      csrf: session.csrf)
                self.status("editor.import_blocked")
                return
            }
            let changes = ConfigUtil.int(preflight, "expanded_leaf_mutations", 0)
            let confirm = UIAlertController(title: self.t("editor.import_clipboard"),
                                            message: self.host?.texts.t("editor.import_confirm", "\(changes)"),
                                            preferredStyle: .alert)
            confirm.addAction(UIAlertAction(title: self.t("admin.cancel"), style: .cancel) { _ in
                _ = core.configImport("cancel", request: envelope, session: session.session,
                                      csrf: session.csrf)
            })
            confirm.addAction(UIAlertAction(title: self.t("editor.confirm"), style: .destructive) {
                [weak self] _ in
                var commit = envelope
                commit["operation_id"] = SettingsEditorActions.randomHex(16)
                let result = core.configImport("commit", request: commit, session: session.session,
                                               csrf: session.csrf)
                self?.status(ConfigUtil.bool(result, "ok", false) ? "settings.saved" : "settings.save_failed")
                self?.host?.refreshAll()
            })
            from.present(confirm, animated: true)
        }
    }
}
#endif

// MARK: - Web panels

/// Panel identities through Core's administrator-session entry point. A credential is generated
/// here, stored in this device's Keychain, and appears only in the one-time link.
final class PanelAdminController: UITableViewController {
    private(set) weak var host: SettingsViewController?
    private let session: LoopbackAdminSession
    private weak var actions: SettingsEditorActions?
    private var panels: [[String: Any]] = []

    static let grants = ["view", "call.monitor", "call.answer", "call.initiate", "sos.trigger",
                         "door.open", "media.publish", "notice.write"]

    init(host: SettingsViewController, session: LoopbackAdminSession, actions: SettingsEditorActions) {
        self.host = host
        self.session = session
        self.actions = actions
        super.init(style: SettingsStyle.tableStyle())
        title = host.texts.t("prefs.panels")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func t(_ key: String) -> String { return host?.texts.t(key) ?? key }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let host = host { SettingsStyle.apply(host.palette, to: tableView) }
        reload()
    }

    func reload() {
        guard let core = host?.core else { return }
        let result = core.panelIdentity("list", request: [:], session: session.session, csrf: session.csrf)
        if result == nil { host?.setStatus(t("editor.core_too_old")) }
        panels = (result?["panels"] as? [[String: Any]]) ?? []
        tableView.reloadData()
    }

    /// Every mutation names the configuration revision it was decided against.
    func call(_ action: String, _ body: [String: Any]) -> [String: Any]? {
        guard let core = host?.core else { return nil }
        let list = core.panelIdentity("list", request: [:], session: session.session, csrf: session.csrf)
        guard let revision = ConfigUtil.str(list, "revision") else {
            host?.setStatus(t("editor.unreachable"))
            return nil
        }
        var request = body
        request["expected_revision"] = revision
        let result = core.panelIdentity(action, request: request, session: session.session,
                                        csrf: session.csrf)
        guard ConfigUtil.bool(result, "ok", false) else {
            if ConfigUtil.str(result, "error_code") == "permission_denied" { actions?.forgetSession() }
            host?.setStatus(t("settings.save_failed") + " " + (ConfigUtil.str(result, "error_code") ?? ""))
            return nil
        }
        return result
    }

    /// Returns (credential, reference) after storing the credential, or nil.
    func provisionCredential() -> (String, String)? {
        let credential = SettingsEditorActions.randomHex(32)
        let suffix = SettingsEditorActions.randomHex(8)
        guard !credential.isEmpty, !suffix.isEmpty, let core = host?.core,
              core.storeSecret("panel.\(suffix)", credential) else {
            host?.setStatus(t("editor.secret_store_failed"))
            return nil
        }
        return (credential, "secret:panel.\(suffix)")
    }

    func showLinks(_ credential: String) {
        guard let host = host else { return }
        host.show(PanelLinkController(host: host, credential: credential), from: self)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { return 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? panels.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return section == 1 ? t("editor.panels_hint") : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if let host = host { SettingsStyle.apply(host.palette, to: cell) }
        guard indexPath.section == 0 else {
            cell.textLabel?.text = t("panels.create")
            cell.textLabel?.textColor = host?.palette.accent
            return cell
        }
        let panel = panels[indexPath.row]
        let id = ConfigUtil.str(panel, "panel_id") ?? ""
        let doors = ConfigUtil.dig(host?.core.config(), "doors") as? [String: Any] ?? [:]
        let scope = ((panel["door_scope"] as? [Any]) ?? []).compactMap { $0 as? String }
            .map { ConfigUtil.labelOf(doors[$0] as? [String: Any], host?.boot.uiLang ?? "ja", $0) }
        let revoked = ConfigUtil.bool(panel, "revoked", false)
        let last = ConfigUtil.double(panel, "last_activity_ms", 0)
        cell.textLabel?.text = String(id.prefix(8))
        cell.detailTextLabel?.text = revoked ? t("panels.revoked")
            : scope.joined(separator: ", ") + " · " + t("panels.last_activity") + " "
                + (last > 0 ? DateFormatter.localizedString(from: Date(timeIntervalSince1970: last / 1000),
                                                            dateStyle: .short, timeStyle: .short) : "—")
        cell.accessoryType = revoked ? .none : .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let host = host else { return }
        if indexPath.section == 1 {
            host.show(PanelScopeController(panels: self, panelId: nil, doorScope: [],
                                           grants: ["view", "call.monitor", "call.answer"]), from: self)
            return
        }
        let panel = panels[indexPath.row]
        guard !ConfigUtil.bool(panel, "revoked", false), let id = ConfigUtil.str(panel, "panel_id") else { return }
        let sheet = UIAlertController(title: String(id.prefix(8)), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: t("panels.door_scope") + " / " + t("panels.grants"), style: .default) {
            [weak self] _ in
            guard let self = self, let host = self.host else { return }
            host.show(PanelScopeController(
                panels: self, panelId: id,
                doorScope: ((panel["door_scope"] as? [Any]) ?? []).compactMap { $0 as? String },
                grants: ((panel["grants"] as? [Any]) ?? []).compactMap { $0 as? String }), from: self)
        })
        sheet.addAction(UIAlertAction(title: t("prefs.rotate_key"), style: .default) { [weak self] _ in
            guard let self = self, let provisioned = self.provisionCredential(),
                  self.call("rotate", ["panel_id": id, "credential_ref": provisioned.1]) != nil else { return }
            self.reload()
            self.showLinks(provisioned.0)
        })
        sheet.addAction(UIAlertAction(title: t("panels.revoke"), style: .destructive) { [weak self] _ in
            guard let self = self, self.call("revoke", ["panel_id": id]) != nil else { return }
            self.host?.setStatus(self.t("panels.revoked_done"))
            self.reload()
        })
        sheet.addAction(UIAlertAction(title: t("admin.cancel"), style: .cancel))
        #if os(iOS)
        if let cell = tableView.cellForRow(at: indexPath) {
            sheet.popoverPresentationController?.sourceView = cell
            sheet.popoverPresentationController?.sourceRect = cell.bounds
        }
        #endif
        present(sheet, animated: true)
    }
}

/// Doors and grants of one panel, or of a new one.
final class PanelScopeController: UITableViewController {
    private weak var panels: PanelAdminController?
    private let panelId: String?
    private var doorScope: [String]
    private var grants: [String]
    private let doors: [(String, String)]

    init(panels: PanelAdminController, panelId: String?, doorScope: [String], grants: [String]) {
        self.panels = panels
        self.panelId = panelId
        self.doorScope = doorScope
        self.grants = grants
        let host = panels.host
        let map = ConfigUtil.dig(host?.core.config(), "doors") as? [String: Any] ?? [:]
        let lang = host?.boot.uiLang ?? "ja"
        doors = ConfigUtil.sortedByOrder(map).map {
            ($0, ConfigUtil.labelOf(map[$0] as? [String: Any], lang, $0)) }
        super.init(style: SettingsStyle.tableStyle())
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private var host: SettingsViewController? { return panels?.host }

    private func t(_ key: String) -> String { return host?.texts.t(key) ?? key }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let palette = host?.palette { SettingsStyle.apply(palette, to: tableView) }
        title = panelId.map { String($0.prefix(8)) } ?? t("panels.create")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { return 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? doors.count : (section == 1 ? PanelAdminController.grants.count : 1)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? t("panels.door_scope") : (section == 1 ? t("panels.grants") : nil)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if let palette = host?.palette { SettingsStyle.apply(palette, to: cell) }
        switch indexPath.section {
        case 0:
            cell.textLabel?.text = doors[indexPath.row].1
            cell.accessoryType = doorScope.contains(doors[indexPath.row].0) ? .checkmark : .none
        case 1:
            let grant = PanelAdminController.grants[indexPath.row]
            cell.textLabel?.text = t("panels.grant_" + grant.replacingOccurrences(of: ".", with: "_"))
            cell.accessoryType = grants.contains(grant) ? .checkmark : .none
        default:
            cell.textLabel?.text = panelId == nil ? t("panels.create") : t("prefs.save")
            cell.textLabel?.textColor = host?.palette.accent
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
        case 0:
            let door = doors[indexPath.row].0
            if let index = doorScope.firstIndex(of: door) { doorScope.remove(at: index) } else { doorScope.append(door) }
            tableView.reloadData()
        case 1:
            let grant = PanelAdminController.grants[indexPath.row]
            if let index = grants.firstIndex(of: grant) { grants.remove(at: index) } else { grants.append(grant) }
            tableView.reloadData()
        default:
            save()
        }
    }

    private func save() {
        guard let panels = panels else { return }
        guard !doorScope.isEmpty, !grants.isEmpty else {
            host?.setStatus(t("panels.scope_required"))
            return
        }
        if let id = panelId {
            guard panels.call("update", ["panel_id": id, "door_scope": doorScope, "grants": grants]) != nil
            else { return }
            panels.reload()
            navigationController?.popViewController(animated: true)
            return
        }
        guard let provisioned = panels.provisionCredential(),
              panels.call("create", ["credential_ref": provisioned.1, "door_scope": doorScope,
                                     "grants": grants]) != nil
        else { return }
        panels.reload()
        navigationController?.popViewController(animated: false)
        panels.showLinks(provisioned.0)
    }
}

/// The one-time links, as QR codes and text. The credential travels in the URL fragment, which a
/// browser never sends to a server.
final class PanelLinkController: UITableViewController {
    private weak var host: SettingsViewController?
    private let links: [(String, String)]

    init(host: SettingsViewController, credential: String) {
        self.host = host
        let status = host.core.status()
        let addresses = ((status?["node"] as? [String: Any])?["local_addrs"] as? [String]) ?? []
        let address = addresses.first { !$0.contains(":") } ?? "127.0.0.1"
        links = ["door", "monitor", "call"].map { screen in
            (host.texts.t("panels.link_\(screen)"),
             "https://\(address):\(ConfigUtil.peerAdminHttpsPort)/panel/\(screen)#k=\(credential)")
        }
        super.init(style: SettingsStyle.tableStyle())
        title = host.texts.t("panels.created")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let host = host { SettingsStyle.apply(host.palette, to: tableView) }
        tableView.rowHeight = 300
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return links.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return host?.texts.t("editor.panel_link_once")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard let host = host else { return cell }
        SettingsStyle.apply(host.palette, to: cell)
        cell.selectionStyle = .none
        let link = links[indexPath.row]
        cell.textLabel?.text = link.0
        cell.detailTextLabel?.text = link.1
        cell.detailTextLabel?.numberOfLines = 0
        cell.imageView?.image = PairingQR.image(core: host.core, text: link.1, points: 220)
        return cell
    }
}
