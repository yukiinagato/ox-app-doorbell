import UIKit

/// Native settings: the device-level and common cluster settings the owner chose to keep off the
/// web admin. Every value is written with the same keys and the same atomic batch the web admin
/// uses, so the two surfaces can never disagree. Anything deliberately left in the web admin says
/// why, in one line, next to the thing it replaces.
final class SettingsViewController: SettingsFormViewController {

    private let core: CoreBridge
    private var boot: BootConfig
    private let writer: ConfigWriter
    private var config: [String: Any]?
    private var nodeId = ""

    /// The screen that hosts settings supplies these so the entries behave exactly as they do
    /// from the home screen.
    var onOpenAddDevice: (() -> Void)?
    var onExitKiosk: (() -> Void)?
    var onOpenDeviceInfo: (() -> Void)?

    init(core: CoreBridge, boot: BootConfig, texts: Texts) {
        self.core = core
        self.boot = boot
        self.writer = ConfigWriter(core: core, httpPort: boot.httpPort)
        super.init(texts: texts)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        refreshSnapshot()
        palette = DoorbellPalette.of(DoorbellTheme.appearance(
            config: config, nodeId: nodeId, localTime: core.localTime()))
        screenTitle = texts.t("settings.title")
        super.viewDidLoad()
    }

    private func refreshSnapshot() {
        config = core.config()
        if let node = core.status()?["node"] as? [String: Any] {
            nodeId = ConfigUtil.evStr(node, "id")
        }
    }

    override func fields() -> [SettingsField] {
        let power = (core.status()?["self"] as? [String: Any])?["power"] as? [String: Any]
        return [
            .action(title: texts.t("settings.section_device"), detail: boot.name,
                    identifier: "settings_device") { [weak self] in self?.openDevice() },
            .action(title: texts.t("settings.section_volume"), detail: volumeSummary(),
                    identifier: "settings_volume") { [weak self] in self?.openVolume() },
            .action(title: texts.t("settings.section_time"), detail: timeSummary(),
                    identifier: "settings_time") { [weak self] in self?.openTime() },
            .action(title: texts.t("settings.section_doors"), detail: doorSummary(),
                    identifier: "settings_doors") { [weak self] in self?.openDoors() },
            .action(title: texts.t("settings.section_purposes"), detail: purposeSummary(),
                    identifier: "settings_purposes") { [weak self] in self?.openPurposes() },
            .action(title: texts.t("settings.section_rules"), detail: ruleSummary(),
                    identifier: "settings_rules") { [weak self] in self?.openRules() },
            .action(title: texts.t("settings.section_cluster"), detail: clusterSummary(),
                    identifier: "settings_cluster") { [weak self] in self?.openCluster() },
            .action(title: texts.t("settings.section_history"), detail: historySummary(),
                    identifier: "settings_history") { [weak self] in self?.openHistory() },
            .action(title: texts.t("settings.section_web"), detail: "",
                    identifier: "settings_web_admin") { [weak self] in self?.openWebAdmin() },
            .action(title: texts.t("settings.section_info"),
                    detail: DoorbellTheme.versionLine(name: boot.name,
                                                      coreVersion: DoorbellTheme.coreVersion(),
                                                      texts: texts, power: power),
                    identifier: "settings_info") { [weak self] in self?.openDeviceInfo() },
        ]
    }

    // MARK: - Summaries

    private func volumeSummary() -> String {
        guard let volumes = core.audioVolumes() else { return "" }
        return "\(texts.t("volume.call")) \(ConfigUtil.int(volumes, "call", 80))"
            + " · \(texts.t("volume.sos")) \(ConfigUtil.int(volumes, "sos", 100))"
            + " · \(texts.t("volume.idle")) \(ConfigUtil.int(volumes, "idle", 60))"
    }

    private func timeSummary() -> String {
        let time = core.status()?["time"] as? [String: Any]
        let zone = ConfigUtil.str(time, "zone") ?? ConfigUtil.str(config, "time.zone") ?? ""
        let source = ConfigUtil.str(time, "source") == "ntp"
            ? texts.t("time.source_ntp") : texts.t("time.source_system")
        return [zone, source].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func doorSummary() -> String {
        let doors = (ConfigUtil.dig(config, "doors") as? [String: Any])?.count ?? 0
        return doors > 0 ? "\(doors)" : ""
    }

    private func purposeSummary() -> String {
        let purposes = ConfigUtil.enabledPurposeIds(config).count
        return purposes > 0 ? "\(purposes)" : ""
    }

    private func ruleSummary() -> String {
        guard let rules = ConfigUtil.dig(config, "rules") as? [String: Any] else { return "" }
        let enabled = rules.values.filter {
            ConfigUtil.bool($0 as? [String: Any], "enabled", true)
        }.count
        return "\(enabled)/\(rules.count)"
    }

    private func clusterSummary() -> String {
        let snapshot = PairingSnapshot.load(core)
        guard snapshot.hasSnapshot else { return "" }
        return texts.t("pair.membership", "\(max(snapshot.memberCount, snapshot.paired ? 1 : 0))")
    }

    private func historySummary() -> String {
        let unread = CallHistory.unreadMissed(core)
        return unread > 0 ? texts.t("history.missed_badge", "\(unread)") : ""
    }

    // MARK: - Navigation

    private func present(_ controller: UIViewController) {
        guard presentedViewController == nil else { return }
        present(controller, animated: true, completion: nil)
    }

    private func openDevice() {
        let screen = DeviceSettingsViewController(core: core, boot: boot, texts: texts)
        screen.onExitKiosk = onExitKiosk
        screen.onBootChanged = { [weak self] updated in
            self?.boot = updated
            self?.rebuild()
        }
        present(screen)
    }

    private func openVolume() {
        present(VolumeSettingsViewController(core: core, boot: boot, texts: texts))
    }

    private func openTime() {
        present(TimeSettingsViewController(core: core, boot: boot, texts: texts))
    }

    private func openDoors() {
        present(DoorSettingsViewController(core: core, boot: boot, texts: texts))
    }

    private func openPurposes() {
        present(PurposeSettingsViewController(core: core, boot: boot, texts: texts))
    }

    private func openRules() {
        present(RuleSettingsViewController(core: core, boot: boot, texts: texts))
    }

    private func openCluster() {
        guard let handler = onOpenAddDevice else { return }
        dismiss(animated: true) { handler() }
    }

    private func openHistory() {
        present(CallHistoryViewController(core: core, texts: texts, lang: boot.uiLang))
    }

    private func openWebAdmin() {
        present(WebAdminViewController(core: core, boot: boot, texts: texts))
    }

    private func openDeviceInfo() {
        guard let handler = onOpenDeviceInfo else { return }
        dismiss(animated: true) { handler() }
    }
}

/// Shared plumbing for the settings sub-screens: one config snapshot, one writer, one status line.
class SettingsChildViewController: SettingsFormViewController {
    let core: CoreBridge
    let boot: BootConfig
    let writer: ConfigWriter
    var config: [String: Any]?
    var nodeId = ""

    init(core: CoreBridge, boot: BootConfig, texts: Texts) {
        self.core = core
        self.boot = boot
        self.writer = ConfigWriter(core: core, httpPort: boot.httpPort)
        super.init(texts: texts)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        reloadConfig()
        palette = DoorbellPalette.of(DoorbellTheme.appearance(
            config: config, nodeId: nodeId, localTime: core.localTime()))
        super.viewDidLoad()
    }

    /// A value changed on a screen presented from this one is what the household just did; the
    /// summaries here have to show it when they come back rather than the state they were built
    /// with.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard isViewLoaded, presentedViewController == nil else { return }
        reloadConfig()
        rebuild()
    }

    func reloadConfig() {
        config = core.config()
        if let node = core.status()?["node"] as? [String: Any] {
            nodeId = ConfigUtil.evStr(node, "id")
        }
    }

    /// Writes one or more keys and reports the outcome on the shared status line.
    func write(_ operations: [ConfigWriter.Operation], rebuildAfter: Bool = false) {
        writer.apply(operations) { [weak self] result in
            guard let self = self else { return }
            self.setStatus(ConfigWriter.message(self.texts, result))
            self.reloadConfig()
            if rebuildAfter { self.rebuild() }
        }
    }

    func deviceKey(_ suffix: String) -> String? {
        guard !nodeId.isEmpty else { return nil }
        return "devices.\(nodeId).\(suffix)"
    }
}

/// この端末 — identity, language, video handling, appearance and the idle-screen theme.
final class DeviceSettingsViewController: SettingsChildViewController {

    var onExitKiosk: (() -> Void)?
    var onBootChanged: ((BootConfig) -> Void)?

    private var pendingName: String
    private var pendingRole: String
    private var pendingDoor: String
    private var currentPassword = ""
    private var newPassword = ""

    override init(core: CoreBridge, boot: BootConfig, texts: Texts) {
        pendingName = boot.name
        pendingRole = boot.role
        pendingDoor = boot.door
        super.init(core: core, boot: boot, texts: texts)
        screenTitle = texts.t("settings.section_device")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func fields() -> [SettingsField] {
        var result: [SettingsField] = [
            .text(title: texts.t("settings.device_name"), value: pendingName,
                  placeholder: texts.t("settings.device_name"), identifier: "device_name") {
                      [weak self] value in self?.pendingName = value; self?.persistIdentity()
                  },
            .choice(title: texts.t("settings.device_role"), value: pendingRole,
                    options: [("door_station", texts.t("admin.role_door")),
                              ("indoor_panel", texts.t("admin.role_indoor"))],
                    identifier: "device_role") { [weak self] value in
                        self?.pendingRole = value
                        self?.persistIdentity()
                        self?.setStatus(self?.texts.t("settings.role_restart_notice") ?? "")
                    },
        ]
        if pendingRole == "door_station" {
            result.append(.text(title: texts.t("settings.device_door"), value: pendingDoor,
                                placeholder: texts.t("settings.device_door"),
                                identifier: "device_door") { [weak self] value in
                                    self?.pendingDoor = value
                                    self?.persistIdentity()
                                })
        }

        // One secret for this device and the web admin; Core keeps the salted hash replicated.
        if core.supportsAdminPasswordChange {
            result.append(.header(texts.t("settings.change_password")))
            result.append(.note(texts.t("settings.password_shared")))
            result.append(.secret(title: texts.t("settings.password_current"),
                                  identifier: "password_current") {
                                      [weak self] value in self?.currentPassword = value
                                  })
            result.append(.secret(title: texts.t("settings.password_new"),
                                  identifier: "password_new") {
                                      [weak self] value in self?.newPassword = value
                                  })
            result.append(.action(title: texts.t("settings.change_password"), detail: "",
                                  identifier: "password_apply") { [weak self] in
                                      self?.applyPasswordChange()
                                  })
        }

        result.append(.header(texts.t("admin.language")))
        let lang = ConfigUtil.str(config, deviceKey("local.ui_lang") ?? "") ?? boot.uiLang
        result.append(.choice(title: texts.t("settings.ui_lang"), value: lang,
                              options: languageOptions(), identifier: "device_lang") {
                                  [weak self] value in
                                  guard let key = self?.deviceKey("local.ui_lang") else { return }
                                  self?.write([.set(key, value)])
                              })

        result.append(.header(texts.t("admin.ui_style")))
        let playback = ConfigUtil.str(config, deviceKey("local.video.playback") ?? "")
            ?? "low_latency"
        result.append(.choice(title: texts.t("settings.video_playback"), value: playback,
                              options: [("low_latency", "low latency"), ("hls", "HLS"),
                                        ("mjpeg", "MJPEG")],
                              identifier: "device_playback") { [weak self] value in
                                  guard let key = self?.deviceKey("local.video.playback")
                                  else { return }
                                  self?.write([.set(key, value)])
                              })
        let rotation = ConfigUtil.str(config, deviceKey("local.video.rotation") ?? "") ?? "auto"
        result.append(.choice(title: texts.t("settings.video_rotation"), value: rotation,
                              options: [("auto", texts.t("admin.rotation_auto")), ("0", "0°"),
                                        ("90", "90°"), ("180", "180°"), ("270", "270°")],
                              identifier: "device_rotation") { [weak self] value in
                                  guard let key = self?.deviceKey("local.video.rotation")
                                  else { return }
                                  self?.write([.set(key, value)])
                              })

        result.append(.header(texts.t("settings.appearance")))
        let appearance = ConfigUtil.str(config, "display.appearance") ?? "auto_system"
        result.append(.choice(title: texts.t("settings.appearance"), value: appearance,
                              options: [("auto_system", texts.t("settings.appearance_auto_system")),
                                        ("auto_schedule",
                                         texts.t("settings.appearance_auto_schedule")),
                                        ("light", texts.t("settings.appearance_light")),
                                        ("dark", texts.t("settings.appearance_dark"))],
                              identifier: "appearance") { [weak self] value in
                                  self?.write([.set("display.appearance", value)],
                                              rebuildAfter: true)
                              })
        if appearance == "auto_schedule" {
            result.append(.text(title: texts.t("settings.appearance_dark_from"),
                                value: ConfigUtil.str(config,
                                                      "display.appearance_schedule.dark_from")
                                    ?? "19:00",
                                placeholder: "19:00", identifier: "appearance_dark_from") {
                                    [weak self] value in
                                    guard DoorbellTheme.minutes(value) != nil else { return }
                                    self?.write([.set("display.appearance_schedule.dark_from",
                                                      value)])
                                })
            result.append(.text(title: texts.t("settings.appearance_light_from"),
                                value: ConfigUtil.str(config,
                                                      "display.appearance_schedule.light_from")
                                    ?? "06:30",
                                placeholder: "06:30", identifier: "appearance_light_from") {
                                    [weak self] value in
                                    guard DoorbellTheme.minutes(value) != nil else { return }
                                    self?.write([.set("display.appearance_schedule.light_from",
                                                      value)])
                                })
        }

        result.append(.header(texts.t("settings.theme_bg_color")))
        let background = ConfigUtil.str(config, "display.theme.bg_color") ?? "#101418"
        result.append(.text(title: texts.t("settings.theme_bg_color"), value: background,
                            placeholder: "#101418", identifier: "theme_bg_color") {
                                [weak self] value in self?.applyBackgroundColor(value)
                            })
        result.append(.note(backgroundWarning(background)))
        result.append(contentsOf: backgroundImageFields())
        result.append(.note(texts.t("settings.web_only_upload")))
        result.append(.note(texts.t("settings.web_only_wording")))

        if boot.role == "door_station", onExitKiosk != nil {
            result.append(.action(title: texts.t("admin.menu_exit_kiosk"), detail: "",
                                  identifier: "exit_kiosk") { [weak self] in
                                      self?.dismiss(animated: true) { self?.onExitKiosk?() }
                                  })
        }
        return result
    }

    /// An installation that has never set the password passes an empty current value, which is
    /// what Core's entry point expects.
    private func applyPasswordChange() {
        guard !newPassword.isEmpty else {
            setStatus(texts.t("settings.password_failed"))
            return
        }
        switch core.setAdminPassword(current: currentPassword, new: newPassword) {
        case .ok:
            setStatus(texts.t("settings.password_changed"))
            currentPassword = ""
            newPassword = ""
            rebuild()
        case .wrongCurrent:
            setStatus(texts.t("admin.pin_wrong"))
        case .lockedOut:
            setStatus(texts.t("admin.locked"))
        case .failed:
            setStatus(texts.t("settings.password_failed"))
        }
    }

    private func languageOptions() -> [(String, String)] {
        let languages = (ConfigUtil.dig(config, "ui.languages") as? [Any])?
            .compactMap { $0 as? String } ?? ["ja", "en", "zh"]
        return languages.map { ($0, Texts.langDisplayName($0)) }
    }

    /// Colour entries are never rejected: an unreadable pair is saved and flagged.
    private func applyBackgroundColor(_ value: String) {
        guard DoorbellTheme.color(hex: value) != nil else {
            setStatus(texts.t("settings.save_failed"))
            return
        }
        write([.set("display.theme.bg_color", value)], rebuildAfter: true)
    }

    private func backgroundWarning(_ value: String) -> String {
        guard let background = DoorbellTheme.color(hex: value) else { return "" }
        let ink = DoorbellTheme.luminance(background) >= 0.5
            ? DoorbellPalette.light.ink : DoorbellPalette.dark.ink
        return DoorbellTheme.contrastWarning(texts, foreground: ink, background: background) ?? ""
    }

    /// Only images already in the asset ledger can be picked; uploading stays in the web admin
    /// because it needs a file picker and a 3 MB downscale.
    private func backgroundImageFields() -> [SettingsField] {
        var result: [SettingsField] = []
        let current = ConfigUtil.str(config, "display.theme.bg_image") ?? ""
        result.append(.action(title: texts.t("settings.theme_image_none"),
                              detail: current.isEmpty ? texts.t("admin.enabled") : "",
                              identifier: "theme_image_none") { [weak self] in
                                  self?.write([.delete("display.theme.bg_image")],
                                              rebuildAfter: true)
                              })
        guard let assets = ConfigUtil.dig(config, "assets") as? [String: Any] else { return result }
        for hash in assets.keys.sorted() {
            let entry = assets[hash] as? [String: Any]
            guard (ConfigUtil.str(entry, "type") ?? "").hasPrefix("image/") else { continue }
            let label = ConfigUtil.str(entry, "label") ?? String(hash.prefix(8))
            result.append(.action(title: label,
                                  detail: hash == current ? texts.t("admin.enabled") : "",
                                  identifier: "theme_image_\(hash.prefix(8))") { [weak self] in
                                      self?.write([.set("display.theme.bg_image", hash)],
                                                  rebuildAfter: true)
                                  })
        }
        return result
    }

    /// Identity lives in this device's boot profile, exactly where the initial setup wrote it.
    private func persistIdentity() {
        guard let updated = BootConfig.persistSetup(name: pendingName, role: pendingRole,
                                                    door: pendingDoor) else {
            setStatus(texts.t("settings.save_failed"))
            return
        }
        setStatus(texts.t("settings.saved"))
        onBootChanged?(updated)
    }
}

/// 音量 — the three levels, with the cluster default and this device's override.
final class VolumeSettingsViewController: SettingsChildViewController {

    private let preview = SirenPlayer()
    private var inheriting = true

    override init(core: CoreBridge, boot: BootConfig, texts: Texts) {
        super.init(core: core, boot: boot, texts: texts)
        screenTitle = texts.t("volume.title")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        inheriting = !hasDeviceOverride()
        rebuild()
    }

    private func hasDeviceOverride() -> Bool {
        guard let key = deviceKey("local.audio.volume") else { return false }
        return ConfigUtil.dig(config, key) != nil
    }

    private func level(_ name: String, fallback: Int) -> Int {
        if !inheriting, let key = deviceKey("local.audio.volume.\(name)"),
           let value = ConfigUtil.dig(config, key) as? NSNumber {
            return value.intValue
        }
        return ConfigUtil.int(core.audioVolumes(), name, fallback)
    }

    override func fields() -> [SettingsField] {
        var result: [SettingsField] = [
            .toggle(title: texts.t("volume.inherit"), detail: "", value: inheriting,
                    identifier: "volume_inherit") { [weak self] value in
                        self?.setInheriting(value)
                    },
            .header(texts.t("volume.device_title")),
        ]
        for (name, titleKey, fallback) in [("call", "volume.call", 80), ("sos", "volume.sos", 100),
                                           ("idle", "volume.idle", 60)] {
            let clusterValue = ConfigUtil.int(config, "audio.volume.\(name)", fallback)
            result.append(.level(title: texts.t(titleKey),
                                 detail: texts.t("volume.cluster_default", "\(clusterValue)"),
                                 value: level(name, fallback: fallback), minimum: 0, maximum: 100,
                                 identifier: "volume_\(name)",
                                 handler: { [weak self] value in self?.store(name, value) },
                                 preview: { [weak self] in self?.play(name) }))
        }
        result.append(.note(texts.t("volume.hint")))
        return result
    }

    private func setInheriting(_ value: Bool) {
        inheriting = value
        guard let key = deviceKey("local.audio.volume") else { return }
        if value {
            write([.delete(key)], rebuildAfter: true)
        } else {
            let object: [String: Any] = [
                "call": ConfigUtil.int(config, "audio.volume.call", 80),
                "sos": ConfigUtil.int(config, "audio.volume.sos", 100),
                "idle": ConfigUtil.int(config, "audio.volume.idle", 60),
            ]
            write([.set(key, object)], rebuildAfter: true)
        }
    }

    /// Writes the cluster default while the device inherits, and the device override otherwise —
    /// the same rule the web admin's Devices tab follows.
    private func store(_ name: String, _ value: Int) {
        if inheriting {
            write([.set("audio.volume.\(name)", value)])
            return
        }
        guard let key = deviceKey("local.audio.volume.\(name)") else { return }
        write([.set(key, value)])
    }

    private func play(_ name: String) {
        let volumes = core.audioVolumes()
        let value = ConfigUtil.int(volumes, name, 80)
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
}

/// 時刻 — cluster zone, the independent time service, and its live state.
final class TimeSettingsViewController: SettingsChildViewController {

    private var zoneQuery = ""

    override init(core: CoreBridge, boot: BootConfig, texts: Texts) {
        super.init(core: core, boot: boot, texts: texts)
        screenTitle = texts.t("time.title")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func fields() -> [SettingsField] {
        let status = core.status()?["time"] as? [String: Any]
        var result: [SettingsField] = [
            .value(title: texts.t("time.zone"),
                   detail: ConfigUtil.str(config, "time.zone") ?? "Asia/Tokyo"),
            .note(texts.t("time.zone_hint")),
            .text(title: texts.t("admin.language"), value: zoneQuery, placeholder: "Asia",
                  identifier: "time_zone_search") { [weak self] value in
                      self?.zoneQuery = value
                      self?.rebuild()
                  },
        ]
        for zone in matchingZones() {
            result.append(.action(title: zone, detail: "",
                                  identifier: "time_zone_\(zone)") { [weak self] in
                                      self?.write([.set("time.zone", zone)], rebuildAfter: true)
                                  })
        }

        result.append(.header(texts.t("time.status")))
        result.append(.toggle(title: texts.t("time.ntp_enabled"), detail: texts.t("time.ntp_hint"),
                              value: ConfigUtil.bool(config, "time.ntp.enabled", false),
                              identifier: "time_ntp") { [weak self] value in
                                  self?.write([.set("time.ntp.enabled", value)],
                                              rebuildAfter: true)
                              })
        let servers = (ConfigUtil.dig(config, "time.ntp.servers") as? [Any])?
            .compactMap { $0 as? String } ?? []
        result.append(.text(title: texts.t("time.servers"),
                            value: servers.joined(separator: ", "),
                            placeholder: "ntp.nict.jp", identifier: "time_servers") {
                                [weak self] value in self?.storeServers(value)
                            })
        result.append(.note(texts.t("time.servers_hint")))
        result.append(.text(title: texts.t("time.interval_s"),
                            value: "\(ConfigUtil.int(config, "time.ntp.interval_s", 900))",
                            placeholder: "900", identifier: "time_interval") {
                                [weak self] value in self?.storeInterval(value)
                            })
        result.append(.value(title: texts.t("time.source"),
                             detail: ConfigUtil.str(status, "source") == "ntp"
                                ? texts.t("time.source_ntp") : texts.t("time.source_system")))
        result.append(.value(title: texts.t("time.offset"),
                             detail: "\(ConfigUtil.int(status, "offset_ms", 0)) ms"))
        result.append(.value(title: texts.t("time.last_sync"), detail: lastSyncText(status)))
        result.append(.value(title: texts.t("time.server"),
                             detail: ConfigUtil.str(status, "server") ?? ""))
        result.append(.value(title: texts.t("time.local_now"), detail: nowText()))
        result.append(.action(title: texts.t("time.sync_now"), detail: "",
                              identifier: "time_sync_now") { [weak self] in self?.syncNow() })
        return result
    }

    private func matchingZones() -> [String] {
        let all = TimeZone.knownTimeZoneIdentifiers.sorted()
        guard !zoneQuery.isEmpty else { return Array(all.prefix(12)) }
        let needle = zoneQuery.lowercased()
        return Array(all.filter { $0.lowercased().contains(needle) }.prefix(20))
    }

    private func lastSyncText(_ status: [String: Any]?) -> String {
        let value = Int64(ConfigUtil.double(status, "last_sync_ms", 0))
        guard value > 0 else { return texts.t("time.never") }
        return DoorbellClock.timeOfDay(core, wallMs: value)
    }

    private func nowText() -> String {
        guard let reading = DoorbellClock.read(core) else { return "" }
        return reading.hhmmss + " " + reading.tz
    }

    private func storeServers(_ value: String) {
        let servers = value.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard (1...4).contains(servers.count) else {
            setStatus(texts.t("time.invalid_servers"))
            return
        }
        write([.set("time.ntp.servers", servers)])
    }

    private func storeInterval(_ value: String) {
        guard let seconds = Int(value.trimmingCharacters(in: .whitespaces)),
              (60...86400).contains(seconds) else {
            setStatus(texts.t("time.invalid_interval"))
            return
        }
        write([.set("time.ntp.interval_s", seconds)])
    }

    private func syncNow() {
        guard ConfigUtil.bool(config, "time.ntp.enabled", false) else {
            setStatus(texts.t("time.ntp_off"))
            return
        }
        setStatus(core.timeSyncNow() ? texts.t("time.sync_started")
            : texts.t("time.sync_failed"))
    }
}

/// 門口 — labels, the unlock button's visibility, and the announcement per door.
final class DoorSettingsViewController: SettingsChildViewController {

    override init(core: CoreBridge, boot: BootConfig, texts: Texts) {
        super.init(core: core, boot: boot, texts: texts)
        screenTitle = texts.t("settings.section_doors")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func fields() -> [SettingsField] {
        guard let doors = ConfigUtil.dig(config, "doors") as? [String: Any] else { return [] }
        var result: [SettingsField] = []
        let nowMs = DoorbellClock.nowMs(core)
        for door in ConfigUtil.sortedByOrder(doors) {
            let entry = doors[door] as? [String: Any]
            result.append(.header(ConfigUtil.labelOf(entry, boot.uiLang, door)))
            for (lang, titleKey) in [("ja", "admin.label_ja"), ("en", "admin.label_en"),
                                     ("zh", "admin.label_zh")] {
                let value = ((entry?["label"] as? [String: Any])?[lang] as? String) ?? ""
                result.append(.text(title: texts.t(titleKey), value: value, placeholder: door,
                                    identifier: "door_label_\(door)_\(lang)") {
                                        [weak self] newValue in
                                        self?.write([.set("doors.\(door).label.\(lang)",
                                                          newValue)])
                                    })
            }
            result.append(.toggle(title: texts.t("settings.unlock_show_button"),
                                  detail: unlockDetail(door),
                                  value: DoorUnlock.showsButton(status: core.status(),
                                                                config: config, door: door),
                                  identifier: "door_unlock_\(door)") { [weak self] value in
                                      self?.write([.set("doors.\(door).unlock.show_button",
                                                        value)])
                                  })
            let notice = DoorbellNotice.effective(status: core.status(), config: config,
                                                  door: door, nowMs: nowMs)
            result.append(.action(title: texts.t("notice.title"),
                                  detail: notice?.text ?? texts.t("notice.none"),
                                  identifier: "door_notice_\(door)") { [weak self] in
                                      self?.openNotice(door: door)
                                  })
        }
        return result
    }

    private func unlockDetail(_ door: String) -> String {
        return DoorUnlock.isConfigured(status: core.status(), config: config, door: door)
            ? "" : texts.t("door.unlock_not_configured")
    }

    private func openNotice(door: String) {
        guard presentedViewController == nil else { return }
        present(NoticeDialogViewController(core: core, texts: texts, httpPort: boot.httpPort,
                                           lang: boot.uiLang, door: door), animated: true)
    }
}

/// 用件 — which purposes visitors are offered, and in what order.
final class PurposeSettingsViewController: SettingsChildViewController {

    override init(core: CoreBridge, boot: BootConfig, texts: Texts) {
        super.init(core: core, boot: boot, texts: texts)
        screenTitle = texts.t("settings.section_purposes")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// This is the one surface that lists every purpose, switched on or not: a purpose that is
    /// switched off is exactly the one a household comes here to switch back on. The door
    /// station's buttons and the ring-then-purpose chooser offer only the enabled ones, and the
    /// toggle writes that single key — nothing else about the purpose is touched here.
    override func fields() -> [SettingsField] {
        guard let purposes = ConfigUtil.dig(config, "visit_purposes") as? [String: Any],
              !purposes.isEmpty else {
            return []
        }
        let ordered = ConfigUtil.allPurposeIds(config)
        var result: [SettingsField] = []
        for (index, id) in ordered.enumerated() {
            let entry = purposes[id] as? [String: Any]
            let label = ConfigUtil.labelOf(entry, boot.uiLang, id)
            let icon = ConfigUtil.str(entry, "icon") ?? ""
            result.append(.toggle(title: icon.isEmpty ? label : "\(icon) \(label)", detail: "",
                                  value: ConfigUtil.purposeIsEnabled(entry),
                                  identifier: "purpose_enabled_\(id)") { [weak self] value in
                                      self?.write([.set("visit_purposes.\(id).enabled", value)])
                                  })
            if index > 0 {
                let previous = ordered[index - 1]
                result.append(.action(title: "▲ \(label)", detail: "",
                                      identifier: "purpose_up_\(id)") { [weak self] in
                                          self?.swapOrder(id, previous, in: purposes)
                                      })
            }
        }
        result.append(.note(texts.t("settings.web_only_wording")))
        return result
    }

    private func swapOrder(_ first: String, _ second: String, in purposes: [String: Any]) {
        let firstOrder = ConfigUtil.int(purposes[first] as? [String: Any], "order", 999)
        let secondOrder = ConfigUtil.int(purposes[second] as? [String: Any], "order", 999)
        write([.set("visit_purposes.\(first).order", secondOrder),
               .set("visit_purposes.\(second).order", firstOrder)], rebuildAfter: true)
    }
}

/// 通知とルール — a rule's on/off state and a one-line summary; quiet hours; whether the two
/// external channels are provisioned. Editing what a rule does, and the secrets themselves, stay
/// in the web admin.
final class RuleSettingsViewController: SettingsChildViewController {

    override init(core: CoreBridge, boot: BootConfig, texts: Texts) {
        super.init(core: core, boot: boot, texts: texts)
        screenTitle = texts.t("settings.section_rules")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func fields() -> [SettingsField] {
        var result: [SettingsField] = []
        if let rules = ConfigUtil.dig(config, "rules") as? [String: Any] {
            for id in rules.keys.sorted() {
                let rule = rules[id] as? [String: Any]
                result.append(.toggle(title: ConfigUtil.str(rule, "name") ?? id,
                                      detail: summary(rule),
                                      value: ConfigUtil.bool(rule, "enabled", true),
                                      identifier: "rule_\(id)") { [weak self] value in
                                          self?.write([.set("rules.\(id).enabled", value)])
                                      })
            }
        }
        result.append(.note(texts.t("settings.web_only_rule_actions")))

        result.append(.header(texts.t("settings.quiet_hours")))
        let windows = ConfigUtil.dig(config, "quiet_hours.default.windows") as? [Any] ?? []
        for (index, window) in windows.enumerated() {
            let entry = window as? [String: Any]
            result.append(.text(title: texts.t("settings.quiet_hours") + " \(index + 1)",
                                value: (ConfigUtil.str(entry, "from") ?? "")
                                    + "-" + (ConfigUtil.str(entry, "to") ?? ""),
                                placeholder: "23:00-07:00",
                                identifier: "quiet_window_\(index)") { [weak self] value in
                                    self?.storeWindow(index, value, windows: windows)
                                })
        }

        result.append(.header(texts.t("admin.notify")))
        result.append(.value(title: texts.t("settings.telegram"),
                             detail: configuredText("integrations.telegram.bot_token_ref")))
        result.append(.value(title: texts.t("settings.web_push"),
                             detail: configuredText("integrations.web_push.sender_url")))
        result.append(.note(texts.t("settings.web_only_secrets")))
        result.append(.note(texts.t("settings.web_only_raw_config")))
        return result
    }

    private func summary(_ rule: [String: Any]?) -> String {
        let trigger = ConfigUtil.str(rule, "when.type") ?? ""
        let actions = (rule?["actions"] as? [Any])?.count ?? 0
        return [trigger, actions > 0 ? "\(actions)" : ""].filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func configuredText(_ key: String) -> String {
        return (ConfigUtil.str(config, key) ?? "").isEmpty ? texts.t("admin.not_ready")
            : texts.t("admin.configured")
    }

    private func storeWindow(_ index: Int, _ value: String, windows: [Any]) {
        let parts = value.components(separatedBy: "-")
        guard parts.count == 2, DoorbellTheme.minutes(parts[0]) != nil,
              DoorbellTheme.minutes(parts[1]) != nil else {
            setStatus(texts.t("settings.save_failed"))
            return
        }
        var updated = windows.map { ($0 as? [String: Any]) ?? [:] }
        guard index < updated.count else { return }
        updated[index]["from"] = parts[0]
        updated[index]["to"] = parts[1]
        write([.set("quiet_hours.default.windows", updated)])
    }
}

/// Web 管理を開く — the QR and URL of this node's admin page, plus the leader's when it differs.
final class WebAdminViewController: SettingsChildViewController {

    override init(core: CoreBridge, boot: BootConfig, texts: Texts) {
        super.init(core: core, boot: boot, texts: texts)
        screenTitle = texts.t("web_admin.open")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let card = AdminQrView(core: core, boot: boot, texts: texts, compact: false)
        // Settings is a sheet layered over the home screen, so it stays in the palette: the
        // theme background is not what is behind this card.
        card.skin = DoorbellSkin.plain(palette)
        card.reload()
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 30),
        ])
    }

    override func fields() -> [SettingsField] {
        return [.note(texts.t("web_admin.scan_hint"))]
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
