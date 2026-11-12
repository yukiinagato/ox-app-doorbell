import Foundation

/// Everything the catalog reads. The controller fills it from Core and the boot profile; tests
/// fill it by hand.
struct SettingsContext {
    var config: [String: Any]?
    var status: [String: Any]?
    var nodeId: String
    var name: String
    var role: String
    var door: String
    var uiLang: String
    var isTV: Bool
    /// A shell that owns its blur renderer may offer a numeric radius. UIBlurEffect does not
    /// expose one, so the modern iOS and tvOS shells show the radius as system-managed.
    var ownsBlurRenderer = false
    var supportsPasswordChange = true
    var sipBackend = "pjsip"
    var audioVolumes: [String: Any]?
    var previewRate = "1"
    var previewRates: [String] = ["0.5", "1", "2", "5"]
    var membershipSummary = ""
    var historySummary = ""
    var versionLine = ""
    var coreVersion = ""
    var lastSyncText = ""
    /// Cluster key state from the pairing snapshot (security protocol v3).
    var pskId = ""
    var staleMembers = 0
    var canRotateKey = false
    /// Core's corrected wall clock, for announcement expiry.
    var nowMs = Int64(Date().timeIntervalSince1970 * 1000)

    init(config: [String: Any]?, status: [String: Any]?, nodeId: String, name: String,
         role: String, door: String, uiLang: String, isTV: Bool) {
        self.config = config
        self.status = status
        self.nodeId = nodeId
        self.name = name
        self.role = role
        self.door = door
        self.uiLang = uiLang
        self.isTV = isTV
    }
}

/// Builds the settings tree. Category, page and item ids are stable: they are accessibility
/// identifiers and the drill-down path the UI uses to rebuild a page after a write.
struct SettingsCatalog {

    let ctx: SettingsContext
    let texts: Texts

    init(_ ctx: SettingsContext, texts: Texts) {
        self.ctx = ctx
        self.texts = texts
    }

    private var cfg: [String: Any]? { return ctx.config }
    private var isDoor: Bool { return ctx.role == "door_station" }
    private func t(_ key: String) -> String { return texts.t(key) }
    private func t(_ key: String, _ arg: String) -> String { return texts.t(key, arg) }

    // MARK: Categories

    func categories() -> [SettingsCategory] {
        var result: [SettingsCategory] = [
            SettingsCategory(id: "device", title: t("settings.section_device"),
                             icon: SettingIcon(glyph: "TablerDeviceTablet", tint: 0x8E8E93),
                             summary: ctx.name, page: devicePage),
            SettingsCategory(id: "sounds", title: t("prefs.sounds"),
                             icon: SettingIcon(glyph: "TablerBell", tint: 0xFF3B30),
                             summary: volumeSummary(), page: soundsPage),
            SettingsCategory(id: "display", title: t("prefs.display"),
                             icon: SettingIcon(glyph: "TablerPalette", tint: 0x007AFF),
                             summary: appearanceTitle(), page: displayPage),
            SettingsCategory(id: "calls", title: t("prefs.calls"),
                             icon: SettingIcon(glyph: "TablerPhone", tint: 0x34C759),
                             summary: callFlowTitle(), page: callsPage),
            SettingsCategory(id: "doors", title: t("settings.section_doors"),
                             icon: SettingIcon(glyph: "TablerDoor", tint: 0xA2845E),
                             summary: countSummary("doors"), page: doorsPage),
            SettingsCategory(id: "sos", title: t("prefs.sos"),
                             icon: SettingIcon(glyph: "TablerAlertTriangle", tint: 0xFF2D55),
                             summary: "", page: sosPage),
            SettingsCategory(id: "time", title: t("time.title"),
                             icon: SettingIcon(glyph: "TablerClock", tint: 0x5856D6),
                             summary: ConfigUtil.str(cfg, "time.zone") ?? "", page: timePage),
            SettingsCategory(id: "notifications", title: t("settings.section_rules"),
                             icon: SettingIcon(glyph: "TablerNote", tint: 0xFF9500),
                             summary: ruleSummary(), page: notificationsPage),
        ]
        if !ctx.isTV {
            result.append(SettingsCategory(id: "sip", title: t("prefs.sip"),
                                           icon: SettingIcon(glyph: "TablerTopologyStar3", tint: 0x30B0C7),
                                           summary: ctx.sipBackend, page: sipPage))
        }
        result.append(contentsOf: [
            SettingsCategory(id: "cluster", title: t("settings.section_cluster"),
                             icon: SettingIcon(glyph: "TablerLink", tint: 0x32ADE6),
                             summary: ctx.membershipSummary, page: clusterPage),
            SettingsCategory(id: "about", title: t("prefs.about"),
                             icon: SettingIcon(glyph: "TablerInfoCircle", tint: 0x636366),
                             summary: "", page: aboutPage),
        ])
        return result
    }

    /// Resolves a drill-down path (category id, then item ids, then list row ids) to the page it
    /// names in a freshly built catalog, so an open page shows the state after a write.
    func page(path: [String]) -> SettingsPage? {
        guard let first = path.first,
              let category = categories().first(where: { $0.id == first }) else { return nil }
        var page = category.page()
        var index = 1
        while index < path.count {
            guard let item = page.item(path[index]) else { return nil }
            switch item.control {
            case .page(let build):
                page = build()
                index += 1
            case .list(let build):
                guard index + 1 < path.count,
                      let row = build().rows.first(where: { $0.id == path[index + 1] }),
                      let edit = row.edit else { return nil }
                page = edit()
                index += 2
            default:
                return nil
            }
        }
        return page
    }

    func list(path: [String]) -> SettingsListModel? {
        guard path.count >= 2, let parent = page(path: Array(path.dropLast())),
              let item = parent.item(path[path.count - 1]),
              case .list(let build) = item.control else { return nil }
        return build()
    }

    // MARK: Commit helpers

    private func deviceKey(_ suffix: String) -> String? {
        return ctx.nodeId.isEmpty ? nil : "devices.\(ctx.nodeId).\(suffix)"
    }

    static func encode(_ value: SettingValue) -> Any {
        switch value {
        case .bool(let v): return v
        case .int(let v): return v
        case .string(let v): return v
        case .strings(let v): return v
        }
    }

    private func set(_ key: String?) -> (SettingValue) -> SettingEffect {
        return { value in
            guard let key = key else { return .invalid("prefs.no_node") }
            return .write([.set(key, SettingsCatalog.encode(value))])
        }
    }

    private func setInt(_ key: String?, _ minimum: Int, _ maximum: Int,
                        scale: Int = 1) -> (SettingValue) -> SettingEffect {
        return { value in
            guard let key = key else { return .invalid("prefs.no_node") }
            guard let number = value.intValue, (minimum...maximum).contains(number) else {
                return .invalid("prefs.out_of_range")
            }
            return .write([.set(key, number * scale)])
        }
    }

    private func setClock(_ key: String) -> (SettingValue) -> SettingEffect {
        return { value in
            guard let clock = value.stringValue.flatMap(SettingValidation.clock) else {
                return .invalid("prefs.invalid_time")
            }
            return .write([.set(key, clock)])
        }
    }

    private func setOptional(_ key: String?) -> (SettingValue) -> SettingEffect {
        return { value in
            guard let key = key else { return .invalid("prefs.no_node") }
            if value.stringValue == "" { return .write([.delete(key)]) }
            return .write([.set(key, SettingsCatalog.encode(value))])
        }
    }

    private func str(_ key: String, _ fallback: String) -> String {
        return ConfigUtil.str(cfg, key) ?? fallback
    }

    private func int(_ key: String, _ fallback: Int) -> Int {
        return ConfigUtil.int(cfg, key, fallback)
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        return ConfigUtil.bool(cfg, key, fallback)
    }

    private func labelPage(id: String, title: String, prefix: String,
                           entry: [String: Any]?, limit: Int) -> [SettingItem] {
        return [("ja", "admin.label_ja"), ("en", "admin.label_en"), ("zh", "admin.label_zh")].map {
            lang, titleKey in
            let value = ((entry?["label"] as? [String: Any])?[lang] as? String) ?? ""
            return SettingItem("\(id)_label_\(lang)", t(titleKey), detail: value,
                               .text(value: value, placeholder: title, numeric: false)) { value in
                guard let text = value.stringValue else { return .none }
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    return lang == "ja" ? .invalid("prefs.label_required")
                        : .write([.delete("\(prefix).label.\(lang)")])
                }
                guard let label = SettingValidation.label(text, limit: limit) else {
                    return .invalid("prefs.label_invalid")
                }
                return .write([.set("\(prefix).label.\(lang)", label)])
            }
        }
    }

    // MARK: This device

    private func devicePage() -> SettingsPage {
        var identity: [SettingItem] = [
            SettingItem("device_name", t("settings.device_name"), detail: ctx.name,
                        .text(value: ctx.name, placeholder: t("settings.device_name"),
                              numeric: false)) { value in
                guard let text = value.stringValue, SettingValidation.label(text, limit: 64) != nil
                else { return .invalid("prefs.label_invalid") }
                return .local("identity.name")
            },
        ]
        // The role is shown here and changed in its own form: a change restarts the app, so
        // nothing is written until that form is confirmed. An Apple TV is always an indoor panel.
        identity.append(SettingItem("device_role", t("settings.device_role"),
                                    .info(t(isDoor ? "admin.role_door" : "admin.role_indoor"))))
        if isDoor {
            identity.append(SettingItem("device_door", t("settings.device_door"),
                                        .info(ctx.door)))
        }
        if !ctx.isTV {
            identity.append(SettingItem("change_role", t("settings.change_role"),
                                        .shell("change_role")))
        }
        let languages = (ConfigUtil.dig(cfg, "ui.languages") as? [Any])?
            .compactMap { $0 as? String } ?? ["ja", "en", "zh"]
        let lang = deviceKey("local.ui_lang").flatMap { ConfigUtil.str(cfg, $0) } ?? ctx.uiLang
        var sections = [
            SettingSection(t("prefs.identity"),
                           footer: t(ctx.isTV ? "settings.role_tv_fixed" : "settings.role_restart"),
                           identity),
            SettingSection(t("admin.language"), [
                SettingItem("device_lang", t("settings.ui_lang"),
                            .choice(value: lang, options: languages.map {
                                SettingOption(value: $0, title: Texts.langDisplayName($0))
                            }, searchable: false), commit: set(deviceKey("local.ui_lang"))),
            ]),
        ]
        if !ctx.isTV {
            // The same replicated key the web Admin edits; the root helper reads it on the
            // devices that have one.
            let helper = str(deviceKey("local.recovery.helper_mode") ?? "", "auto")
            sections.append(SettingSection([
                SettingItem("device_helper_mode", t("settings.helper_mode"),
                            .segmented(value: helper, options: [
                                SettingOption(value: "off", title: t("admin.helper_off")),
                                SettingOption(value: "auto", title: t("admin.helper_auto")),
                                SettingOption(value: "on", title: t("admin.helper_on"))]),
                            commit: set(deviceKey("local.recovery.helper_mode"))),
            ]))
        }
        var video: [SettingItem] = [
            SettingItem("device_playback", t("settings.video_playback"),
                        .segmented(value: str(deviceKey("local.video.playback") ?? "", "low_latency"),
                                   options: [SettingOption(value: "low_latency", title: t("prefs.playback_low_latency")),
                                             SettingOption(value: "hls", title: "HLS"),
                                             SettingOption(value: "mjpeg", title: "MJPEG")]),
                        commit: set(deviceKey("local.video.playback"))),
            SettingItem("device_rotation", t("settings.video_rotation"),
                        .choice(value: str(deviceKey("local.video.rotation") ?? "", "auto"),
                                options: [SettingOption(value: "auto", title: t("admin.rotation_auto"))]
                                    + ["0", "90", "180", "270"].map {
                                        SettingOption(value: $0, title: "\($0)°") },
                                searchable: false),
                        commit: set(deviceKey("local.video.rotation"))),
        ]
        if !isDoor {
            video.append(SettingItem("preview_rate", t("dashboard.preview_rate_title"),
                .choice(value: ctx.previewRate, options: ctx.previewRates.map {
                    SettingOption(value: $0, title: t("dashboard.preview_rate_format", $0))
                }, searchable: false)) { _ in .local("preview_rate") })
        }
        if isDoor {
            video.append(SettingItem("visitor_layout", t("settings.visitor_layout"),
                .segmented(value: str(deviceKey("local.visitor_layout") ?? "", "standard"),
                           options: ["standard", "left", "right", "edges"].map {
                               SettingOption(value: $0, title: t("settings.visitor_layout_" + $0))
                           }), commit: set(deviceKey("local.visitor_layout"))))
            video.append(SettingItem("camera", t("prefs.camera"), .page(cameraPage)))
        }
        sections.append(SettingSection(t("prefs.video"), video))
        if ctx.supportsPasswordChange {
            sections.append(SettingSection(t("settings.change_password"),
                                           footer: t("settings.password_shared"), [
                SettingItem("password_current", t("settings.password_current"), .secret) { _ in
                    .local("password.current") },
                SettingItem("password_new", t("settings.password_new"), .secret) { value in
                    guard (value.stringValue ?? "").count >= 8 else {
                        return .invalid("prefs.password_too_short")
                    }
                    return .local("password.new")
                },
                SettingItem("password_apply", t("settings.change_password"),
                            .action(destructive: false)) { _ in .local("password.apply") },
            ]))
        }
        if isDoor && !ctx.isTV {
            sections.append(SettingSection([
                SettingItem("exit_kiosk", t("admin.menu_exit_kiosk"),
                            .action(destructive: true)) { _ in .local("exit_kiosk") },
            ]))
        }
        return SettingsPage(id: "device", title: t("settings.section_device"), sections: sections)
    }

    private func cameraPage() -> SettingsPage {
        let base = deviceKey("local.camera")
        let motion = deviceKey("local.motion")
        func key(_ root: String?, _ leaf: String) -> String? { return root.map { "\($0).\(leaf)" } }
        func value(_ root: String?, _ leaf: String, _ fallback: Int) -> Int {
            return key(root, leaf).map { int($0, fallback) } ?? fallback
        }
        let codec = key(base, "codec").map { str($0, "auto") } ?? "auto"
        return SettingsPage(id: "camera", title: t("prefs.camera"), sections: [
            SettingSection(t("prefs.camera_codec"), footer: t("prefs.camera_codec_footer"), [
                SettingItem("camera_codec", t("prefs.camera_codec"),
                            .segmented(value: codec, options: [
                                SettingOption(value: "auto", title: t("admin.rotation_auto")),
                                SettingOption(value: "h264", title: "H.264"),
                                SettingOption(value: "mjpeg", title: "MJPEG")]),
                            commit: set(key(base, "codec"))),
            ]),
            SettingSection("MJPEG", [
                SettingItem("camera_resolution", t("prefs.resolution"),
                            .choice(value: key(base, "resolution").map { str($0, "640x480") } ?? "640x480",
                                    options: ["320x240", "640x480", "1280x720"].map {
                                        SettingOption(value: $0, title: $0) }, searchable: false),
                            commit: set(key(base, "resolution"))),
                SettingItem("camera_mjpeg_fps", t("prefs.frame_rate"),
                            .stepper(value: value(base, "mjpeg_fps", 8), minimum: 1, maximum: 30,
                                     step: 1, unit: "fps"),
                            commit: setInt(key(base, "mjpeg_fps"), 1, 30)),
                SettingItem("camera_mjpeg_quality", t("prefs.quality"),
                            .slider(value: value(base, "mjpeg_quality", 60), minimum: 10,
                                    maximum: 95, step: 5),
                            commit: setInt(key(base, "mjpeg_quality"), 10, 95)),
            ]),
            SettingSection("H.264", [
                SettingItem("camera_h264_resolution", t("prefs.resolution"),
                            .choice(value: key(base, "h264_resolution").map { str($0, "640x360") } ?? "640x360",
                                    options: ["640x360", "960x540", "1280x720"].map {
                                        SettingOption(value: $0, title: $0) }, searchable: false),
                            commit: set(key(base, "h264_resolution"))),
                SettingItem("camera_h264_fps", t("prefs.frame_rate"),
                            .stepper(value: value(base, "h264_fps", 30), minimum: 5, maximum: 30,
                                     step: 5, unit: "fps"),
                            commit: setInt(key(base, "h264_fps"), 5, 30)),
                SettingItem("camera_h264_bitrate", t("prefs.bitrate"),
                            .stepper(value: value(base, "h264_bitrate_kbps", 700), minimum: 200,
                                     maximum: 4000, step: 100, unit: "kbps"),
                            commit: setInt(key(base, "h264_bitrate_kbps"), 200, 4000)),
            ]),
            SettingSection(t("prefs.motion"), [
                SettingItem("motion_enabled", t("prefs.motion_enabled"),
                            .toggle(key(motion, "enabled").map { bool($0, false) } ?? false),
                            commit: set(key(motion, "enabled"))),
                SettingItem("motion_sensitivity", t("prefs.motion_sensitivity"),
                            .slider(value: value(motion, "sensitivity", 40), minimum: 1,
                                    maximum: 100, step: 1),
                            commit: setInt(key(motion, "sensitivity"), 1, 100)),
                SettingItem("motion_interval", t("prefs.motion_interval"),
                            .stepper(value: value(motion, "min_interval_s", 30), minimum: 5,
                                     maximum: 600, step: 5, unit: t("prefs.unit_seconds")),
                            commit: setInt(key(motion, "min_interval_s"), 5, 600)),
            ]),
        ])
    }

    // MARK: Sounds

    private func volumeSummary() -> String {
        let volumes = ctx.audioVolumes
        return "\(t("volume.call")) \(ConfigUtil.int(volumes, "call", 80))"
            + " · \(t("volume.sos")) \(ConfigUtil.int(volumes, "sos", 100))"
    }

    /// Whether this device inherits the cluster volumes (no device override object).
    var volumeInherits: Bool {
        guard let key = deviceKey("local.audio.volume") else { return true }
        return ConfigUtil.dig(cfg, key) == nil
    }

    private func soundOptions(builtIn: [String], allowNone: Bool) -> [SettingOption] {
        var options: [SettingOption] = []
        if allowNone { options.append(SettingOption(value: "", title: t("prefs.sound_none"))) }
        options += builtIn.map { SettingOption(value: $0, title: t("prefs.sound_" + $0)) }
        if let assets = ConfigUtil.dig(cfg, "assets") as? [String: Any] {
            for hash in assets.keys.sorted() {
                let entry = assets[hash] as? [String: Any]
                guard (ConfigUtil.str(entry, "type") ?? "").hasPrefix("audio/") else { continue }
                options.append(SettingOption(value: "asset:" + hash,
                                             title: ConfigUtil.str(entry, "label") ?? String(hash.prefix(8))))
            }
        }
        return options
    }

    private func soundItem(_ id: String, _ title: String, key: String, fallback: String,
                           builtIn: [String], allowNone: Bool = true) -> SettingItem {
        return SettingItem(id, title, .choice(value: str(key, fallback),
                                              options: soundOptions(builtIn: builtIn, allowNone: allowNone),
                                              searchable: false), commit: set(key))
    }

    private func soundsPage() -> SettingsPage {
        let inherits = volumeInherits
        var levels: [SettingItem] = [
            SettingItem("volume_inherit", t("volume.inherit"), .toggle(inherits)) { value in
                guard let inherit = value.boolValue,
                      let key = self.deviceKey("local.audio.volume") else { return .invalid("prefs.no_node") }
                if inherit { return .write([.delete(key)]) }
                return .write([.set(key, ["call": self.int("audio.volume.call", 80),
                                          "sos": self.int("audio.volume.sos", 100),
                                          "idle": self.int("audio.volume.idle", 60)])])
            },
        ]
        for (name, titleKey, fallback) in [("call", "volume.call", 80), ("sos", "volume.sos", 100),
                                           ("idle", "volume.idle", 60)] {
            let current: Int
            if !inherits, let key = deviceKey("local.audio.volume.\(name)"),
               let number = ConfigUtil.dig(cfg, key) as? NSNumber {
                current = number.intValue
            } else {
                current = ConfigUtil.int(ctx.audioVolumes, name, int("audio.volume.\(name)", fallback))
            }
            let target = inherits ? "audio.volume.\(name)" : deviceKey("local.audio.volume.\(name)")
            levels.append(SettingItem("volume_\(name)", t(titleKey),
                                      detail: t("volume.cluster_default",
                                                "\(int("audio.volume.\(name)", fallback))"),
                                      .slider(value: current, minimum: 0, maximum: 100, step: 1),
                                      commit: setInt(target, 0, 100)))
            levels.append(SettingItem("preview_\(name)", t("volume.preview") + " · " + t(titleKey),
                                      .action(destructive: false)) { _ in .local("preview.\(name)") })
        }
        var tones: [SettingItem] = [
            soundItem("ringtone", t("prefs.ringtone"), key: "ui.ringtone", fallback: "school_chime",
                      builtIn: ["school_chime", "ding1", "ding2", "classic"], allowNone: false),
            soundItem("button_sound", t("prefs.button_sound"), key: "ui.button_sound",
                      fallback: "button_click", builtIn: ["button_click"]),
            soundItem("update_sound", t("prefs.update_sound"), key: "ui.update_sound",
                      fallback: "indoor_update", builtIn: ["indoor_update"]),
            soundItem("launch_sound", t("prefs.launch_sound"), key: "ui.launch_sound",
                      fallback: "title_display", builtIn: ["title_display"]),
            soundItem("call_sound", t("prefs.call_sound"), key: "ui.call_sound",
                      fallback: "outdoor_call_alert", builtIn: ["outdoor_call_alert"]),
            SettingItem("call_sound_loop", t("prefs.call_sound_loop"),
                        .toggle(bool("ui.call_sound_loop", false)), commit: set("ui.call_sound_loop")),
        ]
        tones.append(contentsOf: soundsLibraryItems())
        return SettingsPage(id: "sounds", title: t("prefs.sounds"), sections: [
            SettingSection(t("volume.device_title"), footer: t("volume.hint"), levels),
            SettingSection(t("prefs.tones"), tones),
        ])
    }

    // MARK: Display

    private func appearanceTitle() -> String {
        return t("settings.appearance_" + str("display.appearance", "auto_system"))
    }

    private func displayPage() -> SettingsPage {
        let appearance = str("display.appearance", "auto_system")
        var look: [SettingItem] = [
            SettingItem("appearance", t("settings.appearance"),
                        .choice(value: appearance, options: ["auto_system", "auto_schedule", "light", "dark"].map {
                            SettingOption(value: $0, title: t("settings.appearance_" + $0)) },
                                searchable: false), commit: set("display.appearance")),
        ]
        if appearance == "auto_schedule" {
            look.append(SettingItem("appearance_dark_from", t("settings.appearance_dark_from"),
                                    .time(str("display.appearance_schedule.dark_from", "19:00")),
                                    commit: setClock("display.appearance_schedule.dark_from")))
            look.append(SettingItem("appearance_light_from", t("settings.appearance_light_from"),
                                    .time(str("display.appearance_schedule.light_from", "06:30")),
                                    commit: setClock("display.appearance_schedule.light_from")))
        }
        let background = str("display.theme.bg_color", "#101418")
        var imageOptions = [SettingOption(value: "", title: t("settings.theme_image_none"))]
        if let assets = ConfigUtil.dig(cfg, "assets") as? [String: Any] {
            for hash in assets.keys.sorted() {
                let entry = assets[hash] as? [String: Any]
                guard (ConfigUtil.str(entry, "type") ?? "").hasPrefix("image/") else { continue }
                imageOptions.append(SettingOption(value: hash, title: ConfigUtil.str(entry, "label")
                    ?? String(hash.prefix(8))))
            }
        }
        let theme: [SettingItem] = [
            SettingItem("theme_bg_color", t("settings.theme_bg_color"), detail: background,
                        .text(value: background, placeholder: "#101418", numeric: false)) { value in
                guard let color = value.stringValue.flatMap(SettingValidation.hexColor) else {
                    return .invalid("prefs.invalid_color")
                }
                return .write([.set("display.theme.bg_color", color)])
            },
            SettingItem("theme_bg_image", t("settings.theme_bg_image"),
                        .choice(value: str("display.theme.bg_image", ""), options: imageOptions,
                                searchable: false), commit: setOptional("display.theme.bg_image")),
            SettingItem("backdrop_enabled", t("prefs.backdrop"),
                        .toggle(bool("display.theme.backdrop.enabled", true)),
                        commit: set("display.theme.backdrop.enabled")),
            SettingItem("backdrop_opacity", t("prefs.backdrop_opacity"),
                        .slider(value: int("display.theme.backdrop.opacity", 62), minimum: 0,
                                maximum: 100, step: 1),
                        commit: setInt("display.theme.backdrop.opacity", 0, 100)),
            SettingItem("backdrop_color", t("prefs.backdrop_color"),
                        detail: str("display.theme.backdrop.color", "#000000"),
                        .text(value: str("display.theme.backdrop.color", "#000000"),
                              placeholder: "#000000", numeric: false)) { value in
                guard let color = value.stringValue.flatMap(SettingValidation.hexColor) else {
                    return .invalid("prefs.invalid_color")
                }
                return .write([.set("display.theme.backdrop.color", color)])
            },
            ctx.ownsBlurRenderer
                ? SettingItem("glass_blur", t("prefs.blur_radius"),
                              .slider(value: int("display.theme.glass.blur_radius", 32), minimum: 0,
                                      maximum: 40, step: 1),
                              commit: setInt("display.theme.glass.blur_radius", 0, 40))
                : SettingItem("glass_blur", t("prefs.blur_radius"),
                              .info(t("prefs.blur_system_managed"))),
        ]
        let saverKey = "display.screensaver"
        let night: [SettingItem] = [
            SettingItem("brightness", t("prefs.brightness"),
                        .slider(value: int("display.brightness", 70), minimum: 0, maximum: 100, step: 1),
                        commit: setInt("display.brightness", 0, 100)),
            SettingItem("night_enabled", t("prefs.night_mode"),
                        .toggle(bool("display.night.enabled", false)), commit: set("display.night.enabled")),
            SettingItem("night_from", t("prefs.from"), .time(str("display.night.from", "22:00")),
                        commit: setClock("display.night.from")),
            SettingItem("night_to", t("prefs.to"), .time(str("display.night.to", "06:00")),
                        commit: setClock("display.night.to")),
            SettingItem("night_brightness", t("prefs.night_brightness"),
                        .slider(value: int("display.night.brightness", 15), minimum: 1, maximum: 100, step: 1),
                        commit: setInt("display.night.brightness", 1, 100)),
            SettingItem("night_red_tint", t("prefs.red_tint"),
                        .toggle(bool("display.night.red_tint", false)), commit: set("display.night.red_tint")),
        ]
        let saverSchedule = str("\(saverKey).schedule", "always")
        var saver: [SettingItem] = [
            SettingItem("saver_enabled", t("prefs.screensaver"),
                        .toggle(bool("\(saverKey).enabled", int("display.screensaver_after_s", 120) > 0)),
                        commit: set("\(saverKey).enabled")),
            SettingItem("saver_after", t("prefs.screensaver_after"),
                        .stepper(value: int("\(saverKey).after_s", int("display.screensaver_after_s", 120)),
                                 minimum: 10, maximum: 3600, step: 10, unit: t("prefs.unit_seconds")),
                        commit: setInt("\(saverKey).after_s", 10, 3600)),
            SettingItem("saver_mode", t("prefs.screensaver_mode"),
                        .segmented(value: str("\(saverKey).mode", "dim"), options: ["dim", "minimal", "clock"].map {
                            SettingOption(value: $0, title: t("prefs.saver_" + $0)) }),
                        commit: set("\(saverKey).mode")),
            SettingItem("saver_brightness", t("prefs.screensaver_brightness"),
                        .slider(value: int("\(saverKey).brightness", 10), minimum: 1, maximum: 100, step: 1),
                        commit: setInt("\(saverKey).brightness", 1, 100)),
            SettingItem("saver_schedule", t("prefs.screensaver_schedule"),
                        .segmented(value: saverSchedule, options: [
                            SettingOption(value: "always", title: t("prefs.saver_always")),
                            SettingOption(value: "daily", title: t("prefs.saver_daily"))]),
                        commit: set("\(saverKey).schedule")),
        ]
        if saverSchedule == "daily" {
            saver.append(SettingItem("saver_from", t("prefs.from"), .time(str("\(saverKey).from", "22:00")),
                                     commit: setClock("\(saverKey).from")))
            saver.append(SettingItem("saver_to", t("prefs.to"), .time(str("\(saverKey).to", "06:00")),
                                     commit: setClock("\(saverKey).to")))
        }
        saver.append(SettingItem("pixel_shift", t("prefs.pixel_shift"),
                                 .stepper(value: int("display.pixel_shift_s", 300), minimum: 0,
                                          maximum: 3600, step: 60, unit: t("prefs.unit_seconds")),
                                 commit: setInt("display.pixel_shift_s", 0, 3600)))
        return SettingsPage(id: "display", title: t("prefs.display"), sections: [
            SettingSection(t("settings.appearance"), look),
            SettingSection(t("prefs.theme"), footer: backgroundFooter(background),
                           theme + themeImageItems(prefix: "display.theme")),
            SettingSection(t("prefs.brightness"), night),
            SettingSection(t("prefs.screensaver"), saver),
            SettingSection([SettingItem("wording", t("editor.wording"), .list(wordingList))]),
        ])
    }

    private func backgroundFooter(_ background: String) -> String {
        guard let color = DoorbellTheme.color(hex: background) else { return "" }
        let ink = DoorbellTheme.luminance(color) >= 0.5 ? DoorbellPalette.light.ink
            : DoorbellPalette.dark.ink
        return DoorbellTheme.contrastWarning(texts, foreground: ink, background: color) ?? ""
    }

    // MARK: Calls, replies and purposes

    private func callFlowTitle() -> String {
        return t("prefs.flow_" + str("ui.call_flow", "purpose_first"))
    }

    private func callsPage() -> SettingsPage {
        let offered = (ConfigUtil.dig(cfg, "ui.languages") as? [Any])?.compactMap { $0 as? String }
            ?? ["ja", "en", "zh"]
        return SettingsPage(id: "calls", title: t("prefs.calls"), sections: [
            SettingSection(t("prefs.call_flow"), footer: t("prefs.call_flow_footer"), [
                SettingItem("call_flow", t("prefs.call_flow"),
                            .segmented(value: str("ui.call_flow", "purpose_first"), options: [
                                SettingOption(value: "purpose_first", title: t("prefs.flow_purpose_first")),
                                SettingOption(value: "ring_then_purpose", title: t("prefs.flow_ring_then_purpose"))]),
                            commit: set("ui.call_flow")),
                SettingItem("call_ttl", t("prefs.call_ttl"),
                            .stepper(value: int("ui.call_ttl_s", 60), minimum: 10, maximum: 300,
                                     step: 5, unit: t("prefs.unit_seconds")),
                            commit: setInt("ui.call_ttl_s", 10, 300)),
                SettingItem("reply_ttl", t("prefs.reply_ttl"),
                            .stepper(value: int("reply.display_ttl_s", 30), minimum: 5, maximum: 300,
                                     step: 5, unit: t("prefs.unit_seconds")),
                            commit: setInt("reply.display_ttl_s", 5, 300)),
            ]),
            callReturnSection(),
            SettingSection(t("prefs.visitor_languages"), footer: t("prefs.visitor_languages_footer"), [
                SettingItem("visitor_languages", t("prefs.visitor_languages"),
                            detail: offered.map(Texts.langDisplayName).joined(separator: ", "),
                            .multiChoice(values: offered, options: ["ja", "en", "zh"].map {
                                SettingOption(value: $0, title: Texts.langDisplayName($0)) },
                                         ordered: true, minimumCount: 1)) { value in
                    guard let list = value.stringsValue, !list.isEmpty else {
                        return .invalid("prefs.need_one_language")
                    }
                    return .write([.set("ui.languages", list)])
                },
                SettingItem("visitor_lang_revert", t("prefs.visitor_lang_revert"),
                            .stepper(value: int("ui.visitor_lang_revert_s", 60), minimum: 5,
                                     maximum: 600, step: 5, unit: t("prefs.unit_seconds")),
                            commit: setInt("ui.visitor_lang_revert_s", 5, 600)),
            ]),
            SettingSection([
                SettingItem("quick_replies", t("prefs.quick_replies"),
                            detail: countSummary("quick_replies"), .list(quickReplyList)),
                SettingItem("visit_purposes", t("settings.section_purposes"),
                            detail: "\(ConfigUtil.enabledPurposeIds(cfg).count)/\(ConfigUtil.allPurposeIds(cfg).count)",
                            .list(purposeList)),
                SettingItem("reply_audio", t("prefs.reply_audio"), detail: "\(assetEntries("audio/").count)",
                            .list({ self.assetList("audio/", title: self.t("editor.sounds")) })),
            ]),
        ])
    }

    func quickReplyList() -> SettingsListModel {
        let map = ConfigUtil.dig(cfg, "quick_replies") as? [String: Any] ?? [:]
        let ids = ConfigUtil.sortedByOrder(map)
        let rows = ids.map { id -> SettingsListRow in
            let entry = map[id] as? [String: Any]
            return SettingsListRow(id: id, title: ConfigUtil.labelOf(entry, ctx.uiLang, id),
                                   detail: ConfigUtil.bool(entry, "speak", true) ? "🔊" : "",
                                   enabled: nil, toggle: nil,
                                   edit: { self.quickReplyPage(id: id, entry: entry) })
        }
        return SettingsListModel(
            id: "quick_replies", title: t("prefs.quick_replies"),
            footer: t("prefs.list_footer"), rows: rows,
            reorder: { order in .write(SettingValidation.orderOperations(prefix: "quick_replies", ids: order)) },
            delete: { id in .write([.delete("quick_replies.\(id)")]) },
            addTitle: t("prefs.add_reply"), add: nil, addPrompt: t("admin.label_ja"),
            addWithText: { text in
                guard let label = SettingValidation.label(text, limit: 80) else {
                    return .invalid("prefs.label_invalid")
                }
                let id = SettingValidation.newId("qr")
                return .write([.set("quick_replies.\(id)", ["label": ["ja": label], "speak": true,
                                                            "order": ids.count + 1])])
            })
    }

    private func quickReplyPage(id: String, entry: [String: Any]?) -> SettingsPage {
        let prefix = "quick_replies.\(id)"
        let title = ConfigUtil.labelOf(entry, ctx.uiLang, id)
        return SettingsPage(id: id, title: title, sections: [
            SettingSection(labelPage(id: id, title: title, prefix: prefix, entry: entry, limit: 80)),
            SettingSection(footer: t("prefs.speak_footer"), [
                SettingItem("\(id)_speak", t("prefs.speak"),
                            .toggle(ConfigUtil.bool(entry, "speak", true)), commit: set("\(prefix).speak")),
            ]),
            // Recorded or uploaded audio per visitor language; it takes priority over speech.
            SettingSection(t("prefs.reply_audio"), SettingsCatalog.editorLanguages.map { lang -> SettingItem in
                let options = [SettingOption(value: "", title: t("prefs.sound_none"))]
                    + assetEntries("audio/").map {
                        SettingOption(value: $0.hash, title: ConfigUtil.str($0.entry, "label") ?? String($0.hash.prefix(8))) }
                return SettingItem("\(id)_audio_\(lang)", Texts.langDisplayName(lang),
                                   .choice(value: str("\(prefix).audio.\(lang)", ""), options: options,
                                           searchable: false),
                                   commit: setOptional("\(prefix).audio.\(lang)"))
            }),
        ])
    }

    func purposeList() -> SettingsListModel {
        let map = ConfigUtil.dig(cfg, "visit_purposes") as? [String: Any] ?? [:]
        let ids = ConfigUtil.allPurposeIds(cfg)
        let rows = ids.map { id -> SettingsListRow in
            let entry = map[id] as? [String: Any]
            let icon = ConfigUtil.str(entry, "icon") ?? ""
            let label = ConfigUtil.labelOf(entry, ctx.uiLang, id)
            return SettingsListRow(id: id, title: icon.isEmpty ? label : "\(icon) \(label)",
                                   detail: "", enabled: ConfigUtil.purposeIsEnabled(entry),
                                   toggle: { on in .write([.set("visit_purposes.\(id).enabled", on)]) },
                                   edit: { self.purposePage(id: id, entry: entry) })
        }
        return SettingsListModel(
            id: "visit_purposes", title: t("settings.section_purposes"),
            footer: t("prefs.purpose_footer"), rows: rows,
            reorder: { order in .write(SettingValidation.orderOperations(prefix: "visit_purposes", ids: order)) },
            delete: { id in .write([.delete("visit_purposes.\(id)")]) },
            addTitle: t("prefs.add_purpose"), add: nil, addPrompt: t("admin.label_ja"),
            addWithText: { text in
                guard let label = SettingValidation.label(text, limit: 40) else {
                    return .invalid("prefs.label_invalid")
                }
                let id = SettingValidation.newId("p")
                return .write([.set("visit_purposes.\(id)", ["label": ["ja": label], "icon": "🔔",
                                                             "order": ids.count + 1, "enabled": true])])
            })
    }

    private func purposePage(id: String, entry: [String: Any]?) -> SettingsPage {
        let prefix = "visit_purposes.\(id)"
        let title = ConfigUtil.labelOf(entry, ctx.uiLang, id)
        let icon = ConfigUtil.str(entry, "icon") ?? ""
        return SettingsPage(id: id, title: title, sections: [
            SettingSection([
                SettingItem("\(id)_enabled", t("settings.purpose_shown"),
                            .toggle(ConfigUtil.purposeIsEnabled(entry)), commit: set("\(prefix).enabled")),
                SettingItem("\(id)_icon", t("prefs.icon"), detail: icon,
                            .text(value: icon, placeholder: "📦", numeric: false)) { value in
                    guard let text = value.stringValue.flatMap({ SettingValidation.label($0, limit: 8) })
                    else { return .invalid("prefs.label_invalid") }
                    return .write([.set("\(prefix).icon", text)])
                },
            ]),
            SettingSection(labelPage(id: id, title: title, prefix: prefix, entry: entry, limit: 40)),
        ])
    }

    // MARK: Doors and announcements

    private func countSummary(_ key: String) -> String {
        let count = (ConfigUtil.dig(cfg, key) as? [String: Any])?.count ?? 0
        return count > 0 ? "\(count)" : ""
    }

    private func doorsPage() -> SettingsPage {
        let doors = ConfigUtil.dig(cfg, "doors") as? [String: Any] ?? [:]
        let nowMs = ctx.nowMs
        var items: [SettingItem] = ConfigUtil.sortedByOrder(doors).map { door in
            let entry = doors[door] as? [String: Any]
            return SettingItem("door_\(door)", ConfigUtil.labelOf(entry, ctx.uiLang, door),
                               detail: door, .page({ self.doorPage(door: door, entry: entry) }))
        }
        if items.isEmpty { items = [SettingItem("doors_none", t("prefs.no_doors"), .info(""))] }
        let global = DoorbellNotice.effective(status: ctx.status, config: cfg, door: "", nowMs: nowMs)
        return SettingsPage(id: "doors", title: t("settings.section_doors"), sections: [
            SettingSection(t("settings.section_doors"), footer: t("prefs.doors_footer"), items),
            SettingSection(t("notice.title"), [
                SettingItem("notice_global", t("prefs.notice_global"),
                            detail: global?.text ?? t("notice.none"), .shell("notice:")),
                SettingItem("notice_presets", t("prefs.notice_presets"),
                            detail: "\((ConfigUtil.dig(cfg, "notice.presets") as? [Any])?.count ?? 0)",
                            .list(noticePresetList)),
            ]),
            SettingSection(placesItems()),
        ])
    }

    private func doorPage(door: String, entry: [String: Any]?) -> SettingsPage {
        let nowMs = ctx.nowMs
        let notice = DoorbellNotice.effective(status: ctx.status, config: cfg, door: door, nowMs: nowMs)
        let configured = DoorUnlock.isConfigured(status: ctx.status, config: cfg, door: door)
        let title = ConfigUtil.labelOf(entry, ctx.uiLang, door)
        return SettingsPage(id: door, title: title, sections: [
            SettingSection(t("prefs.label"),
                           labelPage(id: "door_\(door)", title: title, prefix: "doors.\(door)",
                                     entry: entry, limit: 40)),
            SettingSection(footer: configured ? "" : t("door.unlock_not_configured"), [
                SettingItem("door_\(door)_unlock", t("settings.unlock_show_button"),
                            .toggle(DoorUnlock.showsButton(status: ctx.status, config: cfg, door: door)),
                            commit: set("doors.\(door).unlock.show_button")),
            ]),
            SettingSection([
                SettingItem("door_\(door)_notice", t("notice.title"),
                            detail: notice?.text ?? t("notice.none"), .shell("notice:\(door)")),
            ]),
        ])
    }

    func noticePresetList() -> SettingsListModel {
        let presets = (ConfigUtil.dig(cfg, "notice.presets") as? [Any])?
            .compactMap { $0 as? [String: Any] } ?? []
        let rows = presets.enumerated().map { index, preset -> SettingsListRow in
            let id = ConfigUtil.str(preset, "id") ?? "np_\(index)"
            return SettingsListRow(id: id, title: ConfigUtil.str(preset, "text") ?? id)
        }
        func write(_ list: [[String: Any]]) -> SettingEffect {
            return .write([.set("notice.presets", list)])
        }
        return SettingsListModel(
            id: "notice_presets", title: t("prefs.notice_presets"), footer: t("prefs.presets_footer"),
            rows: rows,
            reorder: { order in
                write(order.compactMap { id in presets.first { ConfigUtil.str($0, "id") == id } })
            },
            delete: { id in write(presets.filter { ConfigUtil.str($0, "id") != id }) },
            addTitle: t("prefs.add_preset"), add: nil, addPrompt: t("notice.title"),
            addWithText: { text in
                guard presets.count < 8 else { return .invalid("prefs.presets_full") }
                guard let value = SettingValidation.label(text, limit: 200) else {
                    return .invalid("prefs.label_invalid")
                }
                return write(presets + [["id": SettingValidation.newId("np"), "text": value]])
            })
    }

    // MARK: SOS

    /// Seconds the call screen counts down before an indoor panel goes back to its home screen:
    /// the cluster default, and this device's own value, which wins while it is set. Going back
    /// to the default deletes the device leaf rather than copying the cluster value into it.
    private func callReturnSection() -> SettingSection {
        let cluster = int("call.indoor.return_s", 60)
        let deviceKey = self.deviceKey("local.call.return_s")
        let override = deviceKey.flatMap { ConfigUtil.dig(cfg, $0) as? NSNumber }?.intValue
        var items = [
            SettingItem("call_return", t("settings.call_return"),
                        .stepper(value: cluster, minimum: 5, maximum: 600, step: 5,
                                 unit: t("prefs.unit_seconds")),
                        commit: setInt("call.indoor.return_s", 5, 600)),
            SettingItem("call_return_here", t("settings.call_return_here"),
                        detail: override == nil ? t("settings.inherit") : "",
                        .stepper(value: override ?? cluster, minimum: 5, maximum: 600, step: 5,
                                 unit: t("prefs.unit_seconds")),
                        commit: setInt(deviceKey, 5, 600)),
        ]
        if override != nil, let key = deviceKey {
            items.append(SettingItem("call_return_inherit", t("settings.inherit"),
                                     .action(destructive: false)) { _ in
                .write([.delete(key)])
            })
        }
        return SettingSection(t("settings.grp_call_return"), items)
    }

    private func sosPage() -> SettingsPage {
        let roles = (ConfigUtil.dig(cfg, "emergency.button_on_roles") as? [Any])?
            .compactMap { $0 as? String } ?? ["indoor_panel"]
        return SettingsPage(id: "sos", title: t("prefs.sos"), sections: [
            SettingSection(t("prefs.sos_trigger"), footer: t("prefs.sos_trigger_footer"), [
                SettingItem("sos_roles", t("prefs.sos_roles"),
                            detail: roles.map { t($0 == "door_station" ? "admin.role_door" : "admin.role_indoor") }
                                .joined(separator: ", "),
                            .multiChoice(values: roles, options: [
                                SettingOption(value: "indoor_panel", title: t("admin.role_indoor")),
                                SettingOption(value: "door_station", title: t("admin.role_door"))],
                                         ordered: false, minimumCount: 0)) { value in
                    .write([.set("emergency.button_on_roles", value.stringsValue ?? [])])
                },
                SettingItem("sos_countdown", t("prefs.sos_countdown"),
                            .stepper(value: int("emergency.trigger.countdown_s", 3), minimum: 0,
                                     maximum: 10, step: 1, unit: t("prefs.unit_seconds")),
                            commit: setInt("emergency.trigger.countdown_s", 0, 10)),
                SettingItem("sos_cancel_pin", t("prefs.sos_cancel_pin"),
                            .toggle(bool("emergency.cancel_requires_pin", true)),
                            commit: set("emergency.cancel_requires_pin")),
                SettingItem("sos_web_alerts", t("prefs.sos_web_alerts"),
                            .toggle(bool("emergency.web_active_page_alerts", true)),
                            commit: set("emergency.web_active_page_alerts")),
            ]),
            SettingSection(t("prefs.sos_alarm"), [
                soundItem("sos_sound", t("prefs.sos_sound"), key: "emergency.alarm_sound",
                          fallback: "siren1", builtIn: ["siren1"], allowNone: false),
                SettingItem("sos_alarm_volume", t("sos.alarm_volume"),
                            .slider(value: int("emergency.alarm_volume", 100), minimum: 0,
                                    maximum: 100, step: 5),
                            commit: setInt("emergency.alarm_volume", 0, 100)),
            ]),
            SettingSection(t("prefs.sos_sip"), footer: t("prefs.sos_sip_footer"), [
                SettingItem("sos_sip_enabled", t("prefs.sos_sip_enabled"),
                            .toggle(bool("emergency.sip_call.enabled", false)),
                            commit: set("emergency.sip_call.enabled")),
                SettingItem("sos_sip_target", t("prefs.sos_sip_target"),
                            detail: str("emergency.sip_call.target_extension", ""),
                            .text(value: str("emergency.sip_call.target_extension", ""),
                                  placeholder: "600", numeric: true)) { value in
                    let text = (value.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                    guard text.isEmpty || (text.count <= 32 && text.allSatisfy({ $0.isNumber || $0 == "*" || $0 == "#" }))
                    else { return .invalid("prefs.invalid_extension") }
                    return .write([.set("emergency.sip_call.target_extension", text)])
                },
            ]),
            SettingSection([SettingItem("sos_rules", t("prefs.sos_presentation"), .list(ruleList))]),
        ])
    }

    // MARK: Time

    private func timePage() -> SettingsPage {
        let status = ctx.status?["time"] as? [String: Any]
        let zones = TimeZone.knownTimeZoneIdentifiers.sorted()
        return SettingsPage(id: "time", title: t("time.title"), sections: [
            SettingSection(footer: t("time.zone_hint"), [
                SettingItem("time_zone", t("time.zone"),
                            .choice(value: str("time.zone", "Asia/Tokyo"),
                                    options: zones.map { SettingOption(value: $0, title: $0) },
                                    searchable: true)) { value in
                    guard let zone = value.stringValue, zones.contains(zone) else {
                        return .invalid("time.invalid_zone")
                    }
                    return .write([.set("time.zone", zone)])
                },
            ]),
            SettingSection(t("prefs.ntp"), footer: t("time.ntp_hint"), [
                SettingItem("time_ntp", t("time.ntp_enabled"),
                            .toggle(bool("time.ntp.enabled", false)), commit: set("time.ntp.enabled")),
                SettingItem("time_servers", t("time.servers"),
                            detail: "\((ConfigUtil.dig(cfg, "time.ntp.servers") as? [Any])?.count ?? 0)",
                            .list(ntpServerList)),
                SettingItem("time_interval", t("prefs.sync_interval"),
                            .stepper(value: max(1, int("time.ntp.interval_s", 86400) / 3600),
                                     minimum: 1, maximum: 168, step: 1, unit: t("prefs.unit_hours")),
                            commit: setInt("time.ntp.interval_s", 1, 168, scale: 3600)),
                SettingItem("time_sync_now", t("time.sync_now"), .action(destructive: false)) { _ in
                    .local("time.sync") },
            ]),
            SettingSection(t("time.status"), [
                SettingItem("time_source", t("time.source"),
                            .info(ConfigUtil.str(status, "source") == "ntp" ? t("time.source_ntp")
                                  : t("time.source_system"))),
                SettingItem("time_offset", t("time.offset"),
                            .info("\(ConfigUtil.int(status, "offset_ms", 0)) ms")),
                SettingItem("time_last_sync", t("time.last_sync"),
                            .info(ctx.lastSyncText.isEmpty ? t("time.never") : ctx.lastSyncText)),
                SettingItem("time_server", t("time.server"), .info(ConfigUtil.str(status, "server") ?? "")),
            ]),
        ])
    }

    func ntpServerList() -> SettingsListModel {
        let servers = (ConfigUtil.dig(cfg, "time.ntp.servers") as? [Any])?
            .compactMap { $0 as? String } ?? []
        return SettingsListModel(
            id: "time_servers", title: t("time.servers"), footer: t("time.servers_hint"),
            rows: servers.map { SettingsListRow(id: $0, title: $0) },
            reorder: { order in .write([.set("time.ntp.servers", order)]) },
            delete: { id in
                let remaining = servers.filter { $0 != id }
                return remaining.isEmpty ? .invalid("time.invalid_servers")
                    : .write([.set("time.ntp.servers", remaining)])
            },
            addTitle: t("prefs.add_server"), add: nil, addPrompt: "ntp.nict.jp",
            addWithText: { text in
                guard servers.count < 4, let server = SettingValidation.ntpServer(text),
                      !servers.contains(server) else { return .invalid("time.invalid_servers") }
                return .write([.set("time.ntp.servers", servers + [server])])
            })
    }

    // MARK: Notifications and rules

    private func rules() -> [(key: String, id: String, rule: [String: Any]?)] {
        var result: [(key: String, id: String, rule: [String: Any]?)] = []
        for root in ["trigger_rules", "rules"] {
            guard let map = ConfigUtil.dig(cfg, root) as? [String: Any] else { continue }
            for id in map.keys.sorted() {
                result.append(("\(root).\(id)", id, map[id] as? [String: Any]))
            }
        }
        return result
    }

    private func ruleSummary() -> String {
        let all = rules()
        guard !all.isEmpty else { return "" }
        return "\(all.filter { ConfigUtil.bool($0.rule, "enabled", true) }.count)/\(all.count)"
    }

    private func notificationsPage() -> SettingsPage {
        let ruleItems = rules().map { entry in
            SettingItem("rule_\(entry.id)", ConfigUtil.str(entry.rule, "name") ?? ruleTitle(entry.id, entry.rule),
                        detail: ConfigUtil.str(entry.rule, "when.type") ?? "",
                        .toggle(ConfigUtil.bool(entry.rule, "enabled", true)),
                        commit: set("\(entry.key).enabled"))
        }
        func configured(_ key: String) -> String {
            return (ConfigUtil.str(cfg, key) ?? "").isEmpty ? t("admin.not_ready") : t("admin.configured")
        }
        return SettingsPage(id: "notifications", title: t("settings.section_rules"), sections: [
            SettingSection(t("prefs.rules"),
                           ruleItems + [SettingItem("rule_edit", t("prefs.rule_edit"), .list(ruleList))]),
            SettingSection(t("settings.quiet_hours"), footer: t("prefs.quiet_footer"), [
                SettingItem("quiet_hours", t("settings.quiet_hours"),
                            detail: "\((ConfigUtil.dig(cfg, "quiet_hours.default.windows") as? [Any])?.count ?? 0)",
                            .list(quietWindowList)),
            ]),
            SettingSection(t("prefs.history"), [
                SettingItem("retention", t("prefs.retention"),
                            .stepper(value: int("events.retention_days", 90), minimum: 1, maximum: 3650,
                                     step: 30, unit: t("prefs.unit_days")),
                            commit: setInt("events.retention_days", 1, 3650)),
                SettingItem("history", t("settings.section_history"), detail: ctx.historySummary,
                            .shell("history")),
            ]),
            SettingSection(t("admin.notify"), footer: t("editor.secret_hint"), [
                SettingItem("telegram", t("settings.telegram"),
                            detail: configured("integrations.telegram.bot_token_ref"), .page(telegramPage)),
                SettingItem("web_push", t("settings.web_push"),
                            detail: configured("integrations.web_push.sender_url"),
                            .page(webPushPage)),
                SettingItem("mqtt", t("editor.mqtt"), detail: configured("integrations.mqtt.host"),
                            .page(mqttPage)),
                SettingItem("integrations", t("editor.secrets"), .page(secretsPage)),
            ]),
        ])
    }

    /// Web Push: the sender, the VAPID identity, and the two secrets, which go to this device's
    /// secure store and reach configuration only as references.
    private func webPushPage() -> SettingsPage {
        let base = "integrations.web_push"
        return SettingsPage(id: "web_push", title: t("settings.web_push"), sections: [
            SettingSection([
                textItem("web_push_sender_url", t("settings.web_push_sender_url"),
                         key: "\(base).sender_url", placeholder: "https://", limit: 512),
                textItem("web_push_public_key", t("settings.web_push_public_key"),
                         key: "\(base).vapid_public_key", limit: 512),
                textItem("web_push_subject", t("settings.web_push_subject"),
                         key: "\(base).vapid_subject", placeholder: "mailto:", limit: 255),
            ]),
            SettingSection(footer: t("settings.web_push_private_key_native"), [
                secretItem("web_push_private_key", t("settings.web_push_private_key"),
                           key: "\(base).vapid_private_key_ref", base: "webpush.vapid"),
            ]),
            SettingSection(footer: t("settings.web_push_sender_bearer_native"), [
                secretItem("web_push_sender_bearer", t("settings.web_push_sender_bearer"),
                           key: "\(base).sender_secret_ref", base: "webpush.sender"),
            ]),
        ])
    }

    private func ruleTitle(_ id: String, _ rule: [String: Any]?) -> String {
        switch ConfigUtil.str(rule, "when.type") ?? "" {
        case "emergency_on": return t("prefs.rule_sos_on")
        case "emergency_off": return t("prefs.rule_sos_off")
        case "call_missed", "missed_call": return t("prefs.rule_missed")
        default: return id
        }
    }

    func quietWindowList() -> SettingsListModel {
        let windows = (ConfigUtil.dig(cfg, "quiet_hours.default.windows") as? [Any])?
            .map { ($0 as? [String: Any]) ?? [:] } ?? []
        func write(_ list: [[String: Any]]) -> SettingEffect {
            return .write([.set("quiet_hours.default.windows", list)])
        }
        let rows = windows.enumerated().map { index, window -> SettingsListRow in
            let from = ConfigUtil.str(window, "from") ?? "23:00"
            let to = ConfigUtil.str(window, "to") ?? "07:00"
            return SettingsListRow(id: "w\(index)", title: "\(from) – \(to)", edit: {
                SettingsPage(id: "w\(index)", title: "\(from) – \(to)", sections: [SettingSection([
                    SettingItem("w\(index)_from", t("prefs.from"), .time(from)) { value in
                        guard let clock = value.stringValue.flatMap(SettingValidation.clock) else {
                            return .invalid("prefs.invalid_time") }
                        var updated = windows
                        updated[index]["from"] = clock
                        return write(updated)
                    },
                    SettingItem("w\(index)_to", t("prefs.to"), .time(to)) { value in
                        guard let clock = value.stringValue.flatMap(SettingValidation.clock) else {
                            return .invalid("prefs.invalid_time") }
                        var updated = windows
                        updated[index]["to"] = clock
                        return write(updated)
                    },
                ])])
            })
        }
        return SettingsListModel(
            id: "quiet_hours", title: t("settings.quiet_hours"), footer: t("prefs.quiet_footer"),
            rows: rows,
            reorder: nil,
            delete: { id in
                guard let index = Int(id.dropFirst()), index < windows.count else { return .none }
                var updated = windows
                updated.remove(at: index)
                return write(updated)
            },
            addTitle: t("prefs.add_window"),
            add: { write(windows + [["from": "23:00", "to": "07:00"]]) })
    }

    // MARK: SIP

    private func sipPage() -> SettingsPage {
        let account = ctx.nodeId.isEmpty ? nil : "sip.accounts.\(ctx.nodeId)"
        let answerDefault = isDoor ? "auto" : "ring"
        return SettingsPage(id: "sip", title: t("prefs.sip"), sections: [
            SettingSection(t("prefs.sip_server"), footer: t("prefs.sip_server_footer"), [
                SettingItem("sip_server", t("prefs.sip_host"), detail: str("sip.server", ""),
                            .text(value: str("sip.server", ""), placeholder: "10.0.1.5", numeric: false)) { value in
                    let text = (value.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                    if text.isEmpty { return .write([.delete("sip.server")]) }
                    guard text.count <= 255, !text.contains(" "), !text.contains("/") else {
                        return .invalid("prefs.invalid_host")
                    }
                    return .write([.set("sip.server", text)])
                },
                SettingItem("sip_port", t("prefs.port"), detail: "\(int("sip.port", 5060))",
                            .text(value: "\(int("sip.port", 5060))", placeholder: "5060", numeric: true)) { value in
                    guard let port = value.stringValue.flatMap(SettingValidation.port) else {
                        return .invalid("prefs.invalid_port")
                    }
                    return .write([.set("sip.port", port)])
                },
                SettingItem("sip_transport", t("prefs.transport"),
                            .segmented(value: str("sip.transport", "udp"), options: [
                                SettingOption(value: "udp", title: "UDP"),
                                SettingOption(value: "tcp", title: "TCP")]),
                            commit: set("sip.transport")),
                SettingItem("sip_direct_port", t("prefs.direct_port"), detail: "\(int("sip.direct_port", 47190))",
                            .text(value: "\(int("sip.direct_port", 47190))", placeholder: "47190", numeric: true)) { value in
                    guard let port = value.stringValue.flatMap(SettingValidation.port) else {
                        return .invalid("prefs.invalid_port")
                    }
                    return .write([.set("sip.direct_port", port)])
                },
            ]),
            SettingSection(t("prefs.sip_account"), footer: t("prefs.sip_account_footer"), [
                SettingItem("sip_user", t("prefs.sip_user"),
                            detail: account.map { str("\($0).user", "") } ?? "",
                            .text(value: account.map { str("\($0).user", "") } ?? "", placeholder: "201",
                                  numeric: false)) { value in
                    guard let account = account else { return .invalid("prefs.no_node") }
                    let text = (value.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                    if text.isEmpty { return .write([.delete("\(account).user")]) }
                    guard text.count <= 64, !text.contains(" "), !text.contains("@") else {
                        return .invalid("prefs.invalid_extension")
                    }
                    return .write([.set("\(account).user", text)])
                },
                SettingItem("sip_answer_mode", t("prefs.answer_mode"),
                            .segmented(value: account.map { str("\($0).answer_mode", answerDefault) } ?? answerDefault,
                                       options: [SettingOption(value: "ring", title: t("prefs.answer_ring")),
                                                 SettingOption(value: "auto", title: t("prefs.answer_auto"))]),
                            commit: set(account.map { "\($0).answer_mode" })),
                secretItem("sip_password", t("prefs.sip_password"), key: account.map { "\($0).pass_ref" },
                           base: "sip.\(ctx.nodeId)"),
            ]),
            SettingSection(footer: t("editor.srtp_hint"), [
                choiceItem("sip_srtp", "SRTP", key: "sip.srtp", fallback: "optional", options: [
                    SettingOption(value: "optional", title: t("editor.srtp_optional")),
                    SettingOption(value: "mandatory", title: t("editor.srtp_mandatory"))]),
            ]),
            SettingSection([SettingItem("dtmf", t("prefs.dtmf"), detail: countSummary("sip.dtmf_actions"),
                                        .list(dtmfList))]),
        ])
    }

    // MARK: Cluster and about

    private func clusterPage() -> SettingsPage {
        return SettingsPage(id: "cluster", title: t("settings.section_cluster"), sections: [
            SettingSection([
                SettingItem("cluster_members", t("prefs.members"), .info(ctx.membershipSummary)),
                SettingItem("add_device", t("prefs.add_device"), .shell("add_device")),
            ]),
            SettingSection(t("prefs.cluster_key"), footer: t("prefs.rotate_key_footer"),
                           [SettingItem("cluster_key_id", t("prefs.cluster_key"), .info(ctx.pskId)),
                            SettingItem("cluster_stale", t("prefs.members_need_rejoin"),
                                        .info("\(ctx.staleMembers)"))]
                + (ctx.canRotateKey ? [SettingItem("cluster_rotate", t("prefs.rotate_key"),
                                                   .action(destructive: true)) { _ in
                                           .local("cluster.rotate") }] : [])),
            SettingSection(footer: t("editor.panels_hint"), [
                SettingItem("devices", t("admin.devices"), detail: countSummary("devices"), .list(deviceList)),
                SettingItem("panels", t("prefs.panels"), .shell("panels")),
                SettingItem("media_sources", t("prefs.media_sources"), detail: countSummary("media_sources"),
                            .list(mediaSourceList)),
                SettingItem("households", t("prefs.households"), detail: countSummary("households"),
                            .list(householdList)),
            ] + (ctx.isTV ? [] : [
                // File and clipboard transfer need a share sheet and a pasteboard; tvOS has neither.
                SettingItem("import_export", t("prefs.import_export"), .page(transferPage)),
            ])),
        ])
    }

    private func aboutPage() -> SettingsPage {
        return SettingsPage(id: "about", title: t("prefs.about"), sections: [
            SettingSection([
                SettingItem("about_name", t("settings.device_name"), .info(ctx.name)),
                SettingItem("about_role", t("settings.device_role"),
                            .info(t(isDoor ? "admin.role_door" : "admin.role_indoor"))),
                SettingItem("about_node", "ID", .info(ctx.nodeId)),
                SettingItem("about_version", t("prefs.version"), .info(ctx.versionLine)),
                SettingItem("about_core", "Core", .info(ctx.coreVersion)),
                SettingItem("about_sip", "SIP", .info(ctx.sipBackend)),
            ]),
            // Apple TV has no diagnostics page; what it would show is the section above.
            SettingSection((ctx.isTV ? [] : [
                SettingItem("device_info", t("settings.section_info"), .shell("device_info")),
            ]) + [
                SettingItem("web_admin", t("settings.section_web"), .shell("web_admin")),
            ]),
        ])
    }
}

// MARK: - Native editors for what used to open the web admin

extension SettingsCatalog {
    static let editorLanguages = ["ja", "en", "zh"]

    /// A write-only secret. The value is stored in this device's Keychain by the controller
    /// (`secret|<name base>|<config key>`); configuration only ever receives `secret:<name>`.
    func secretItem(_ id: String, _ title: String, key: String?, base: String) -> SettingItem {
        let stored = key.map { (ConfigUtil.str(cfg, $0) ?? "").hasPrefix("secret:") } ?? false
        return SettingItem(id, title, detail: t(stored ? "editor.secret_set" : "editor.secret_unset"),
                           .secret) { value in
            guard let key = key else { return .invalid("prefs.no_node") }
            if (value.stringValue ?? "").isEmpty { return .write([.delete(key)]) }
            return .local("secret|\(base)|\(key)")
        }
    }

    func textItem(_ id: String, _ title: String, key: String, placeholder: String = "",
                  numeric: Bool = false, limit: Int = 255) -> SettingItem {
        let value = str(key, "")
        return SettingItem(id, title, detail: value,
                           .text(value: value, placeholder: placeholder, numeric: numeric)) { value in
            let text = (value.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return .write([.delete(key)]) }
            guard text.count <= limit,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return .invalid("prefs.label_invalid") }
            return .write([.set(key, text)])
        }
    }

    func portItem(_ id: String, _ title: String, key: String, fallback: Int) -> SettingItem {
        let value = "\(int(key, fallback))"
        return SettingItem(id, title, detail: value,
                           .text(value: value, placeholder: "\(fallback)", numeric: true)) { value in
            guard let port = value.stringValue.flatMap(SettingValidation.port) else {
                return .invalid("prefs.invalid_port")
            }
            return .write([.set(key, port)])
        }
    }

    func choiceItem(_ id: String, _ title: String, key: String, fallback: String,
                    options: [SettingOption]) -> SettingItem {
        return SettingItem(id, title, .choice(value: str(key, fallback), options: options,
                                              searchable: options.count > 12),
                           commit: setOptional(key))
    }

    func multiItem(_ id: String, _ title: String, values: [String], options: [SettingOption],
                   commit: @escaping ([String]) -> SettingEffect) -> SettingItem {
        let detail = values.isEmpty ? t("editor.all")
            : values.map { value in options.first { $0.value == value }?.title ?? value }
                .joined(separator: ", ")
        return SettingItem(id, title, detail: detail,
                           .multiChoice(values: values, options: options, ordered: false,
                                        minimumCount: 0)) { value in
            commit(value.stringsValue ?? [])
        }
    }

    func strings(_ key: String) -> [String] {
        return (ConfigUtil.dig(cfg, key) as? [Any])?.compactMap { $0 as? String } ?? []
    }

    func map(_ key: String) -> [String: Any] {
        return ConfigUtil.dig(cfg, key) as? [String: Any] ?? [:]
    }

    func labelled(_ key: String) -> [SettingOption] {
        let entries = map(key)
        return ConfigUtil.sortedByOrder(entries).map {
            SettingOption(value: $0, title: ConfigUtil.labelOf(entries[$0] as? [String: Any], ctx.uiLang, $0))
        }
    }

    func doorOptions() -> [SettingOption] { return labelled("doors") }

    // MARK: Assets

    func assetEntries(_ prefix: String) -> [(hash: String, entry: [String: Any])] {
        let assets = map("assets")
        return assets.keys.sorted().compactMap { hash -> (hash: String, entry: [String: Any])? in
            let entry = assets[hash] as? [String: Any] ?? [:]
            return (ConfigUtil.str(entry, "type") ?? "").hasPrefix(prefix) ? (hash, entry) : nil
        }
    }

    func assetList(_ prefix: String, title: String) -> SettingsListModel {
        let rows = assetEntries(prefix).map { asset -> SettingsListRow in
            let size = ConfigUtil.int(asset.entry, "size", 0)
            return SettingsListRow(id: asset.hash,
                                   title: ConfigUtil.str(asset.entry, "label") ?? String(asset.hash.prefix(8)),
                                   detail: "\(ConfigUtil.str(asset.entry, "type") ?? "") · \(size / 1024) KB")
        }
        var model = SettingsListModel(id: "assets_\(prefix.dropLast())", title: title,
                                      footer: t("editor.assets_hint"), rows: rows)
        model.delete = { hash in .local("asset.remove|\(hash)") }
        if !ctx.isTV && prefix == "audio/" {
            model.addTitle = t("editor.record_sound")
            model.add = { .local("asset.record") }
        }
        return model
    }

    func soundsLibraryItems() -> [SettingItem] {
        var items = [SettingItem("sound_library", t("editor.sounds"),
                                 detail: "\(assetEntries("audio/").count)",
                                 .list({ self.assetList("audio/", title: self.t("editor.sounds")) }))]
        if !ctx.isTV {
            items.append(SettingItem("sound_import", t("prefs.sound_upload"),
                                     .action(destructive: false)) { _ in .local("asset.file") })
        }
        return items
    }

    func themeImageItems(prefix: String) -> [SettingItem] {
        var items: [SettingItem] = []
        if !ctx.isTV {
            items.append(SettingItem("theme_upload", t("editor.choose_photo"),
                                     .action(destructive: false)) { _ in
                .local("asset.image|\(prefix).bg_image") })
        }
        items.append(SettingItem("theme_images", t("editor.images"),
                                 detail: "\(assetEntries("image/").count)",
                                 .list({ self.assetList("image/", title: self.t("editor.images")) })))
        items.append(SettingItem("theme_ink", t("editor.ink_overrides"), .page({
            self.inkPage(prefix: prefix) })))
        return items
    }

    func inkPage(prefix: String) -> SettingsPage {
        let items = ["clock", "date", "status_line", "hint", "tile_label"].map { region -> SettingItem in
            let key = "\(prefix).ink_override.\(region)"
            let value = str(key, "")
            return SettingItem("ink_\(region)", t("editor.region_\(region)"),
                               detail: value.isEmpty ? t("editor.automatic") : value,
                               .text(value: value, placeholder: "#FFFFFF", numeric: false)) { value in
                let text = (value.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                if text.isEmpty { return .write([.delete(key)]) }
                guard let color = SettingValidation.hexColor(text) else { return .invalid("prefs.invalid_color") }
                return .write([.set(key, color)])
            }
        }
        return SettingsPage(id: "theme_ink", title: t("editor.ink_overrides"),
                            sections: [SettingSection(footer: t("editor.ink_hint"), items)])
    }

    // MARK: Wording overrides

    func wordingList() -> SettingsListModel {
        let builtin = Texts.builtinStrings(ctx.uiLang)
        let overrides = map("i18n_overrides")
        var changed = Set<String>()
        for lang in SettingsCatalog.editorLanguages {
            changed.formUnion((overrides[lang] as? [String: Any] ?? [:]).keys)
        }
        let mine = overrides[ctx.uiLang] as? [String: Any] ?? [:]
        let keys = builtin.keys.sorted { a, b in
            let ca = changed.contains(a), cb = changed.contains(b)
            return ca != cb ? ca : a < b
        }
        let rows = keys.map { key -> SettingsListRow in
            let text = (mine[key] as? String) ?? builtin[key] ?? ""
            return SettingsListRow(id: key, title: (changed.contains(key) ? "✎ " : "") + key,
                                   detail: text, edit: { self.wordPage(key) })
        }
        var model = SettingsListModel(id: "wording", title: t("editor.wording"),
                                      footer: t("editor.wording_hint"), rows: rows)
        model.searchable = true
        return model
    }

    /// How many values a wording takes: `{name}` in an override, `%@` / `%1$@` in the shipped
    /// platform strings. An override must keep the same number.
    static func placeholderCount(_ text: String) -> Int {
        guard let pattern = try? NSRegularExpression(pattern: "\\{[A-Za-z0-9_]+\\}|%(\\d+\\$)?@")
        else { return 0 }
        return pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }



    func wordPage(_ key: String) -> SettingsPage {
        let overrides = map("i18n_overrides")
        var items = SettingsCatalog.editorLanguages.map { lang -> SettingItem in
            let builtin = Texts.builtinStrings(lang)[key] ?? ""
            let langMap = overrides[lang] as? [String: Any] ?? [:]
            let current = (langMap[key] as? String) ?? builtin
            return SettingItem("word_\(lang)", Texts.langDisplayName(lang) + (langMap[key] != nil ? " ✎" : ""),
                               detail: current,
                               .text(value: current, placeholder: builtin, numeric: false)) { value in
                var text = value.stringValue ?? ""
                if text == builtin { text = "" }
                if !text.isEmpty && !builtin.isEmpty &&
                    SettingsCatalog.placeholderCount(text) != SettingsCatalog.placeholderCount(builtin) {
                    return .invalid("editor.placeholder_hint")
                }
                var next = langMap
                if text.isEmpty { next.removeValue(forKey: key) } else { next[key] = text }
                let mapKey = "i18n_overrides.\(lang)"
                return .write([next.isEmpty ? .delete(mapKey) : .set(mapKey, next)])
            }
        }
        let any = SettingsCatalog.editorLanguages.contains {
            (overrides[$0] as? [String: Any])?[key] != nil }
        if any {
            items.append(SettingItem("word_reset", t("editor.reset"), .action(destructive: true)) { _ in
                var operations: [ConfigWriter.Operation] = []
                for lang in SettingsCatalog.editorLanguages {
                    guard var next = overrides[lang] as? [String: Any], next[key] != nil else { continue }
                    next.removeValue(forKey: key)
                    let mapKey = "i18n_overrides.\(lang)"
                    operations.append(next.isEmpty ? .delete(mapKey) : .set(mapKey, next))
                }
                return .write(operations)
            })
        }
        return SettingsPage(id: key, title: key,
                            sections: [SettingSection(footer: t("editor.placeholder_hint"), items)])
    }

    // MARK: Buildings, doors and households

    func labelledList(_ root: String, title: String, prefix: String, addTitle: String,
                      extra: ((String, [String: Any]?) -> [SettingItem])? = nil) -> SettingsListModel {
        let entries = map(root)
        let ids = ConfigUtil.sortedByOrder(entries)
        let rows = ids.map { id -> SettingsListRow in
            let entry = entries[id] as? [String: Any]
            let label = ConfigUtil.labelOf(entry, ctx.uiLang, id)
            return SettingsListRow(id: id, title: label, detail: id, edit: {
                var sections = [SettingSection(t("editor.label"),
                    self.labelPage(id: "\(root)_\(id)", title: label, prefix: "\(root).\(id)",
                                   entry: entry, limit: 40))]
                if let more = extra?(id, entry), !more.isEmpty { sections.append(SettingSection(more)) }
                return SettingsPage(id: id, title: label, sections: sections)
            })
        }
        var model = SettingsListModel(id: root, title: title, rows: rows)
        model.delete = { id in .write([.delete("\(root).\(id)")]) }
        model.addTitle = addTitle
        model.addPrompt = t("admin.label_ja")
        model.addWithText = { text in
            guard let label = SettingValidation.label(text, limit: 40) else {
                return .invalid("prefs.label_invalid")
            }
            return .write([.set("\(root).\(SettingValidation.newId(prefix))",
                                ["label": ["ja": label], "order": ids.count + 1])])
        }
        return model
    }

    func placesItems() -> [SettingItem] {
        let buildings = labelled("buildings")
        return [
            SettingItem("buildings", t("editor.buildings"), detail: countSummary("buildings"),
                        .list({ self.labelledList("buildings", title: self.t("editor.buildings"),
                                                  prefix: "b", addTitle: self.t("editor.new_building")) })),
            SettingItem("doors_edit", t("editor.doors"), detail: countSummary("doors"),
                        .list({ self.labelledList("doors", title: self.t("editor.doors"), prefix: "d",
                                                  addTitle: self.t("editor.new_door")) { id, entry in
                            [SettingItem("door_\(id)_building", self.t("editor.building"),
                                         .choice(value: ConfigUtil.str(entry, "building") ?? "",
                                                 options: [SettingOption(value: "", title: "—")] + buildings,
                                                 searchable: false),
                                         commit: self.setOptional("doors.\(id).building"))]
                        } })),
            SettingItem("households", t("editor.households"), detail: countSummary("households"),
                        .list(householdList)),
        ]
    }

    func householdList() -> SettingsListModel {
        return labelledList("households", title: t("editor.households"), prefix: "h",
                            addTitle: t("editor.new_household")) { id, entry in
            let chats = ((entry?["telegram_chat_ids"] as? [Any]) ?? []).map { "\($0)" }
                .joined(separator: ", ")
            let extensions = ((entry?["sip_extensions"] as? [Any]) ?? []).map { "\($0)" }
                .joined(separator: ", ")
            return [
                SettingItem("household_\(id)_chats", self.t("editor.chat_ids"), detail: chats,
                            .text(value: chats, placeholder: "123456789", numeric: true)) { value in
                    var ids: [Int64] = []
                    for part in (value.stringValue ?? "").split(separator: ",") {
                        let text = part.trimmingCharacters(in: .whitespaces)
                        guard let number = Int64(text), number != 0 else { return .invalid("prefs.out_of_range") }
                        ids.append(number)
                    }
                    let key = "households.\(id).telegram_chat_ids"
                    return .write([ids.isEmpty ? .delete(key) : .set(key, ids)])
                },
                SettingItem("household_\(id)_extensions", self.t("editor.sip_extensions"),
                            detail: extensions,
                            .text(value: extensions, placeholder: "201", numeric: true)) { value in
                    let list = (value.stringValue ?? "").split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let key = "households.\(id).sip_extensions"
                    return .write([list.isEmpty ? .delete(key) : .set(key, list)])
                },
            ]
        }
    }

    // MARK: Devices

    func deviceList() -> SettingsListModel {
        let devices = map("devices")
        let rows = devices.keys.sorted().map { id -> SettingsListRow in
            let entry = devices[id] as? [String: Any]
            let role = ConfigUtil.str(entry, "role") ?? ""
            let name = ConfigUtil.str(entry, "name") ?? id
            return SettingsListRow(id: id, title: name,
                                   detail: t(role == "door_station" ? "admin.role_door" : "admin.role_indoor")
                                       + (id == ctx.nodeId ? " · " + t("editor.this_device") : ""),
                                   edit: {
                var items = [
                    SettingItem("device_\(id)_name", self.t("settings.device_name"), detail: name,
                                .text(value: name, placeholder: id, numeric: false)) { value in
                        guard let text = value.stringValue.flatMap({ SettingValidation.label($0, limit: 64) })
                        else { return .invalid("prefs.label_invalid") }
                        return .write([.set("devices.\(id).name", text)])
                    },
                    SettingItem("device_\(id)_role", self.t("settings.device_role"),
                                .info(self.t(role == "door_station" ? "admin.role_door" : "admin.role_indoor"))),
                ]
                if role == "door_station" {
                    items.append(SettingItem("device_\(id)_door", self.t("settings.device_door"),
                                             .choice(value: ConfigUtil.str(entry, "door") ?? "",
                                                     options: self.doorOptions(), searchable: false),
                                             commit: self.set("devices.\(id).door")))
                }
                var sections = [SettingSection(footer: self.t("editor.role_on_device"), items)]
                if id != self.ctx.nodeId {
                    sections.append(SettingSection([SettingItem("device_\(id)_remove",
                        self.t("editor.remove_device"), .action(destructive: true)) { _ in
                            .local("device.remove|\(id)") }]))
                }
                return SettingsPage(id: id, title: name, sections: sections)
            })
        }
        return SettingsListModel(id: "devices", title: t("prefs.members"), rows: rows)
    }

    // MARK: Trigger rules

    func whenOptions() -> [SettingOption] {
        return ["button", "motion", "call_missed", "device_offline", "emergency_on", "emergency_off"]
            .map { SettingOption(value: $0, title: t("editor.when_\($0)")) }
    }

    func actionTypeOptions() -> [SettingOption] {
        return ["chime", "device_alert", "sip_call", "telegram", "ha_event", "ha_command", "auto_reply"]
            .map { SettingOption(value: $0, title: t("editor.action_\($0)")) }
    }

    func ruleList() -> SettingsListModel {
        let rules = map("trigger_rules")
        let rows = rules.keys.sorted().map { id -> SettingsListRow in
            let rule = rules[id] as? [String: Any]
            let when = ConfigUtil.str(rule, "when.type") ?? ""
            return SettingsListRow(id: id, title: ConfigUtil.str(rule, "name") ?? ruleTitle(id, rule),
                                   detail: t("editor.when_\(when)"),
                                   enabled: ConfigUtil.bool(rule, "enabled", true),
                                   toggle: { on in .write([.set("trigger_rules.\(id).enabled", on)]) },
                                   edit: { self.rulePage(id) })
        }
        var model = SettingsListModel(id: "rules", title: t("prefs.rule_edit"), rows: rows)
        model.delete = { id in .write([.delete("trigger_rules.\(id)")]) }
        model.addTitle = t("editor.new_rule")
        model.addPrompt = t("editor.name")
        model.addWithText = { text in
            guard let name = SettingValidation.label(text, limit: 64) else { return .invalid("prefs.label_invalid") }
            return .write([.set("trigger_rules.\(SettingValidation.newId("r"))",
                                ["enabled": true, "name": name, "when": ["type": "button"],
                                 "schedule": ["always": true], "actions": [["type": "chime"]]])])
        }
        return model
    }

    func rulePage(_ id: String) -> SettingsPage {
        let base = "trigger_rules.\(id)"
        let rule = ConfigUtil.dig(cfg, base) as? [String: Any]
        let when = ConfigUtil.str(rule, "when.type") ?? "button"
        var whenItems = [SettingItem("rule_when", t("editor.when"),
                                     .choice(value: when, options: whenOptions(), searchable: false),
                                     commit: set("\(base).when.type"))]
        if ["button", "motion", "call_missed"].contains(when) {
            whenItems.append(multiItem("rule_doors", t("editor.doors"), values: strings("\(base).when.doors"),
                                       options: doorOptions()) { list in
                .write([list.isEmpty ? .delete("\(base).when.doors") : .set("\(base).when.doors", list)]) })
        }
        if when == "button" {
            whenItems.append(multiItem("rule_purposes", t("editor.purposes"),
                                       values: strings("\(base).when.purposes"),
                                       options: labelled("visit_purposes")) { list in
                .write([list.isEmpty ? .delete("\(base).when.purposes") : .set("\(base).when.purposes", list)]) })
        }
        let windows = (ConfigUtil.dig(cfg, "\(base).schedule.windows") as? [Any]) ?? []
        let always = windows.isEmpty || bool("\(base).schedule.always", false)
        var scheduleItems = [SettingItem("rule_always", t("editor.always"), .toggle(always)) { value in
            if value.boolValue == true { return .write([.set("\(base).schedule", ["always": true])]) }
            return .write([.set("\(base).schedule", ["windows": [["from": "08:00", "to": "20:00"]]])])
        }]
        if !always {
            scheduleItems.append(SettingItem("rule_windows", t("editor.windows"), detail: "\(windows.count)",
                                             .list({ self.windowList("\(base).schedule.windows",
                                                                     title: self.t("editor.windows")) })))
        }
        let actions = (ConfigUtil.dig(cfg, "\(base).actions") as? [Any]) ?? []
        return SettingsPage(id: id, title: ConfigUtil.str(rule, "name") ?? ruleTitle(id, rule), sections: [
            SettingSection([
                textItem("rule_name", t("editor.name"), key: "\(base).name", limit: 64),
                SettingItem("rule_enabled", t("editor.enabled"),
                            .toggle(bool("\(base).enabled", true)), commit: set("\(base).enabled")),
            ]),
            SettingSection(t("editor.when"), whenItems),
            SettingSection(t("editor.schedule"), scheduleItems),
            SettingSection(t("editor.actions"), footer: t("editor.never_suppress_hint"), [
                SettingItem("rule_actions", t("editor.actions"), detail: "\(actions.count)",
                            .list({ self.actionList("\(base).actions") })),
            ]),
        ])
    }

    /// Time windows `[{from, to, days?}]` stored as one array.
    func windowList(_ key: String, title: String) -> SettingsListModel {
        let windows = (ConfigUtil.dig(cfg, key) as? [Any])?.map { ($0 as? [String: Any]) ?? [:] } ?? []
        func write(_ list: [[String: Any]]) -> SettingEffect { return .write([.set(key, list)]) }
        let days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
            .map { SettingOption(value: $0, title: t("editor.day_\($0)")) }
        let rows = windows.enumerated().map { index, window -> SettingsListRow in
            let from = ConfigUtil.str(window, "from") ?? "22:00"
            let to = ConfigUtil.str(window, "to") ?? "07:00"
            let picked = (window["days"] as? [Any])?.compactMap { $0 as? String } ?? []
            return SettingsListRow(id: "w\(index)", title: "\(from) – \(to)",
                                   detail: picked.map { t("editor.day_\($0)") }.joined(separator: " "),
                                   edit: {
                SettingsPage(id: "w\(index)", title: "\(from) – \(to)", sections: [SettingSection(
                    footer: self.t("editor.weekdays_hint"), [
                    SettingItem("w\(index)_from", self.t("editor.from"), .time(from)) { value in
                        guard let clock = value.stringValue.flatMap(SettingValidation.clock) else {
                            return .invalid("prefs.invalid_time") }
                        var updated = windows
                        updated[index]["from"] = clock
                        return write(updated)
                    },
                    SettingItem("w\(index)_to", self.t("editor.to"), .time(to)) { value in
                        guard let clock = value.stringValue.flatMap(SettingValidation.clock) else {
                            return .invalid("prefs.invalid_time") }
                        var updated = windows
                        updated[index]["to"] = clock
                        return write(updated)
                    },
                    self.multiItem("w\(index)_days", self.t("editor.weekdays"), values: picked,
                                   options: days) { list in
                        var updated = windows
                        if list.isEmpty { updated[index].removeValue(forKey: "days") }
                        else { updated[index]["days"] = list }
                        return write(updated)
                    },
                ])])
            })
        }
        var model = SettingsListModel(id: "windows", title: title, rows: rows)
        model.delete = { id in
            guard let index = Int(id.dropFirst()), index < windows.count else { return .none }
            var updated = windows
            updated.remove(at: index)
            return write(updated)
        }
        model.addTitle = t("editor.add_window")
        model.add = { write(windows + [["from": "22:00", "to": "07:00"]]) }
        return model
    }

    func actionList(_ key: String) -> SettingsListModel {
        let actions = (ConfigUtil.dig(cfg, key) as? [Any])?.map { ($0 as? [String: Any]) ?? [:] } ?? []
        func write(_ list: [[String: Any]]) -> SettingEffect { return .write([.set(key, list)]) }
        let rows = actions.enumerated().map { index, action -> SettingsListRow in
            let type = ConfigUtil.str(action, "type") ?? ""
            let never = ConfigUtil.bool(action, "never_suppress", false)
            return SettingsListRow(id: "a\(index)", title: t("editor.action_\(type)"),
                                   detail: never ? t("editor.never_suppress_short") : "",
                                   edit: { self.actionPage(key, index: index, actions: actions) })
        }
        var model = SettingsListModel(id: "actions", title: t("editor.actions"), rows: rows)
        model.reorder = { order in
            let indexes = order.compactMap { Int($0.dropFirst()) }.filter { $0 < actions.count }
            return write(indexes.map { actions[$0] })
        }
        model.delete = { id in
            guard let index = Int(id.dropFirst()), index < actions.count else { return .none }
            var updated = actions
            updated.remove(at: index)
            return write(updated)
        }
        model.addTitle = t("editor.add_action")
        model.add = { write(actions + [["type": "chime", "sound": "ding1"]]) }
        return model
    }

    func actionPage(_ key: String, index: Int, actions: [[String: Any]]) -> SettingsPage {
        let action = actions[index]
        let type = ConfigUtil.str(action, "type") ?? ""
        func update(_ change: (inout [String: Any]) -> Void) -> SettingEffect {
            var updated = actions
            change(&updated[index])
            return .write([.set(key, updated)])
        }
        func text(_ id: String, _ title: String, _ field: String, numeric: Bool = false) -> SettingItem {
            let value = ConfigUtil.str(action, field) ?? ""
            return SettingItem(id, title, detail: value,
                               .text(value: value, placeholder: "", numeric: numeric)) { value in
                let trimmed = (value.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                return update { entry in
                    if trimmed.isEmpty { entry.removeValue(forKey: field) } else { entry[field] = trimmed }
                }
            }
        }
        func flag(_ id: String, _ title: String, _ path: [String], _ fallback: Bool) -> SettingItem {
            let current: Bool
            if path.count == 2 {
                current = ConfigUtil.bool(action[path[0]] as? [String: Any], path[1], fallback)
            } else {
                current = ConfigUtil.bool(action, path[0], fallback)
            }
            return SettingItem(id, title, .toggle(current)) { value in
                let on = value.boolValue ?? false
                return update { entry in
                    if path.count == 2 {
                        var inner = entry[path[0]] as? [String: Any] ?? [:]
                        inner[path[1]] = on
                        entry[path[0]] = inner
                    } else {
                        entry[path[0]] = on
                    }
                }
            }
        }
        /// "all" or a list, as Core stores targets.
        func targets(_ id: String, _ title: String, _ path: [String],
                     _ options: [SettingOption]) -> SettingItem {
            let raw: Any? = path.count == 2 ? (action[path[0]] as? [String: Any])?[path[1]] : action[path[0]]
            let all = (raw as? String) == "all"
            let values = all ? ["all"] : ((raw as? [Any])?.compactMap { $0 as? String } ?? [])
            return multiItem(id, title, values: values,
                             options: [SettingOption(value: "all", title: t("editor.all"))] + options) { list in
                var stored: Any = list.filter { $0 != "all" }
                if list.last == "all" { stored = "all" }
                return update { entry in
                    if path.count == 2 {
                        var inner = entry[path[0]] as? [String: Any] ?? [:]
                        inner[path[1]] = stored
                        entry[path[0]] = inner
                    } else {
                        entry[path[0]] = stored
                    }
                }
            }
        }
        var items = [SettingItem("action_type", t("editor.type"),
                                 .choice(value: type, options: actionTypeOptions(), searchable: false)) { value in
            guard let next = value.stringValue else { return .none }
            var updated = actions
            updated[index] = ["type": next]
            return .write([.set(key, updated)])
        }]
        switch type {
        case "sip_call":
            items.append(text("action_extension", t("editor.extension"), "target_extension", numeric: true))
        case "telegram":
            items.append(targets("action_households", t("editor.households"), ["households"],
                                 labelled("households")))
            items.append(flag("action_snapshot", t("editor.with_snapshot"), ["with_snapshot"], false))
        case "ha_command":
            items.append(text("action_command", t("editor.command"), "command"))
            items.append(SettingItem("action_door", t("editor.door"),
                                     .choice(value: ConfigUtil.str(action, "door") ?? "self",
                                             options: [SettingOption(value: "self", title: t("editor.this_door"))]
                                                 + doorOptions(), searchable: false)) { value in
                update { $0["door"] = value.stringValue ?? "self" } })
        case "chime":
            items.append(SettingItem("action_sound", t("prefs.ringtone"),
                                     .choice(value: ConfigUtil.str(action, "sound") ?? "ding1",
                                             options: soundOptions(builtIn: ["school_chime", "ding1", "ding2", "classic"],
                                                                   allowNone: false),
                                             searchable: false)) { value in
                update { $0["sound"] = value.stringValue ?? "ding1" } })
        case "auto_reply":
            items.append(SettingItem("action_reply", t("prefs.quick_replies"),
                                     .choice(value: ConfigUtil.str(action, "reply_id") ?? "",
                                             options: labelled("quick_replies"), searchable: false)) { value in
                update { $0["reply_id"] = value.stringValue ?? "" } })
        case "device_alert":
            items.append(targets("action_roles", t("editor.target_roles"), ["targets", "roles"], [
                SettingOption(value: "indoor_panel", title: t("admin.role_indoor")),
                SettingOption(value: "door_station", title: t("admin.role_door"))]))
            let channels = (action["channels"] as? [Any])?.compactMap { $0 as? String } ?? []
            items.append(multiItem("action_channels", t("editor.channels"), values: channels,
                                   options: ["in_app", "system_notification", "web_push"].map {
                                       SettingOption(value: $0, title: t("editor.channel_\($0)")) }) { list in
                update { $0["channels"] = list } })
            items.append(flag("action_visual", t("editor.visual"), ["presentation", "visual"], true))
            items.append(flag("action_sticky", t("editor.sticky"), ["presentation", "sticky"], false))
            let ttl = ConfigUtil.int(action["presentation"] as? [String: Any], "ttl_s", 30)
            items.append(SettingItem("action_ttl", t("editor.ttl"), detail: "\(ttl)",
                                     .text(value: "\(ttl)", placeholder: "30", numeric: true)) { value in
                guard let seconds = value.stringValue.flatMap({ Int($0) }), (0...86400).contains(seconds)
                else { return .invalid("prefs.out_of_range") }
                return update { entry in
                    var inner = entry["presentation"] as? [String: Any] ?? [:]
                    inner["ttl_s"] = seconds
                    entry["presentation"] = inner
                }
            })
        default:
            break
        }
        return SettingsPage(id: "a\(index)", title: t("editor.action_\(type)"), sections: [
            SettingSection(items),
            SettingSection(footer: t("editor.never_suppress_hint"), [
                flag("action_never_suppress", t("editor.never_suppress"), ["never_suppress"], false)]),
        ])
    }

    // MARK: Integrations

    func telegramPage() -> SettingsPage {
        let key = "integrations.telegram.bot_token_ref"
        var items = [
            secretItem("telegram_token", t("editor.bot_token"), key: key, base: "tg_bot"),
            SettingItem("telegram_poll", t("editor.poll_updates"),
                        .toggle(bool("integrations.telegram.poll_updates", true)),
                        commit: set("integrations.telegram.poll_updates")),
            SettingItem("telegram_households", t("editor.households"), detail: countSummary("households"),
                        .list(householdList)),
        ]
        if !str(key, "").isEmpty {
            items.append(SettingItem("telegram_test", t("editor.test_message"),
                                     .action(destructive: false)) { _ in .local("telegram.test") })
            items.append(SettingItem("telegram_off", t("editor.disable"), .action(destructive: true)) { _ in
                .write([.delete(key)]) })
        }
        return SettingsPage(id: "telegram", title: t("settings.telegram"),
                            sections: [SettingSection(footer: t("editor.secret_hint"), items)])
    }

    func mqttPage() -> SettingsPage {
        let m = "integrations.mqtt."
        let h = "integrations.ha."
        return SettingsPage(id: "mqtt", title: t("editor.mqtt"), sections: [
            SettingSection(t("editor.broker"), footer: t("editor.tls_hint"), [
                textItem("mqtt_host", t("editor.server"), key: m + "host", placeholder: "10.0.1.5"),
                portItem("mqtt_port", t("editor.port"), key: m + "port", fallback: 1883),
                SettingItem("mqtt_tls", "TLS", .toggle(bool(m + "tls", false)), commit: set(m + "tls")),
                textItem("mqtt_pin", t("editor.tls_pin"), key: m + "tls_sha256", placeholder: "sha256"),
                textItem("mqtt_user", t("editor.user"), key: m + "user"),
                secretItem("mqtt_password", t("editor.mqtt_password"), key: m + "pass_ref", base: "mqtt"),
                textItem("mqtt_topic", t("editor.base_topic"), key: m + "base_topic", placeholder: "doorbell"),
                textItem("mqtt_discovery", t("editor.discovery_prefix"), key: m + "discovery_prefix",
                         placeholder: "homeassistant"),
            ]),
            SettingSection("Home Assistant", footer: t("editor.ha_control_hint"), [
                choiceItem("ha_language", t("editor.entity_language"), key: h + "language", fallback: "ja",
                           options: SettingsCatalog.editorLanguages.map {
                               SettingOption(value: $0, title: Texts.langDisplayName($0)) }),
                SettingItem("ha_sos", t("editor.allow_sos_control"), .toggle(bool(h + "allow_sos_control", false)),
                            commit: set(h + "allow_sos_control")),
                SettingItem("ha_notice", t("editor.allow_notice_control"),
                            .toggle(bool(h + "allow_notice_control", false)),
                            commit: set(h + "allow_notice_control")),
            ]),
        ])
    }

    func secretsPage() -> SettingsPage {
        var items: [SettingItem] = []
        if !ctx.nodeId.isEmpty {
            items.append(secretItem("secret_sip", t("editor.sip_password"),
                                    key: "sip.accounts.\(ctx.nodeId).pass_ref", base: "sip.\(ctx.nodeId)"))
        }
        items.append(secretItem("secret_mqtt", t("editor.mqtt_password"), key: "integrations.mqtt.pass_ref",
                                base: "mqtt"))
        items.append(secretItem("secret_telegram", t("editor.bot_token"),
                                key: "integrations.telegram.bot_token_ref", base: "tg_bot"))
        for source in map("media_sources").keys.sorted() where SettingValidation.doorId(source) {
            let stored = (ConfigUtil.str(cfg, "media_sources.\(source).secret_ref") ?? "").hasPrefix("secret:")
            items.append(SettingItem("secret_media_\(source)", "\(t("editor.camera_credential")) · \(source)",
                                     detail: t(stored ? "editor.secret_set" : "editor.secret_unset"), .secret) { value in
                (value.stringValue ?? "").isEmpty ? .none : .local("mediasecret|\(source)")
            })
        }
        return SettingsPage(id: "secrets", title: t("editor.secrets"),
                            sections: [SettingSection(footer: t("editor.secret_hint"), items)])
    }

    // MARK: SIP keypad actions

    func dtmfList() -> SettingsListModel {
        let actions = map("sip.dtmf_actions")
        func write(_ next: [String: Any]) -> SettingEffect { return .write([.set("sip.dtmf_actions", next)]) }
        let types = ["hangup", "ha_command", "quick_reply", "decline"].map {
            SettingOption(value: $0, title: t("editor.dtmf_\($0)")) }
        let rows = actions.keys.sorted().map { code -> SettingsListRow in
            let action = actions[code] as? [String: Any] ?? [:]
            let type = ConfigUtil.str(action, "type") ?? "hangup"
            return SettingsListRow(id: code, title: code, detail: t("editor.dtmf_\(type)"), edit: {
                func change(_ body: (inout [String: Any]) -> Void) -> SettingEffect {
                    var entry = action
                    body(&entry)
                    var next = actions
                    next[code] = entry
                    return write(next)
                }
                var items = [SettingItem("dtmf_type", self.t("editor.type"),
                                         .choice(value: type, options: types, searchable: false)) { value in
                    guard let next = value.stringValue else { return .none }
                    var entry: [String: Any] = ["type": next]
                    if next == "ha_command" { entry["command"] = "unlock"; entry["door"] = "self" }
                    if next == "quick_reply" {
                        guard let first = self.labelled("quick_replies").first else { return .invalid("prefs.out_of_range") }
                        entry["reply_id"] = first.value
                    }
                    var all = actions
                    all[code] = entry
                    return write(all)
                }]
                if type == "ha_command" {
                    let command = ConfigUtil.str(action, "command") ?? ""
                    items.append(SettingItem("dtmf_command", self.t("editor.command"), detail: command,
                                             .text(value: command, placeholder: "unlock", numeric: false)) { value in
                        change { $0["command"] = (value.stringValue ?? "").trimmingCharacters(in: .whitespaces) } })
                    items.append(SettingItem("dtmf_door", self.t("editor.door"),
                                             .choice(value: ConfigUtil.str(action, "door") ?? "self",
                                                     options: [SettingOption(value: "self", title: self.t("editor.this_door"))]
                                                         + self.doorOptions(), searchable: false)) { value in
                        change { $0["door"] = value.stringValue ?? "self" } })
                } else if type == "quick_reply" {
                    items.append(SettingItem("dtmf_reply", self.t("prefs.quick_replies"),
                                             .choice(value: ConfigUtil.str(action, "reply_id") ?? "",
                                                     options: self.labelled("quick_replies"), searchable: false)) { value in
                        change { $0["reply_id"] = value.stringValue ?? "" } })
                }
                return SettingsPage(id: code, title: code, sections: [SettingSection(items)])
            })
        }
        var model = SettingsListModel(id: "dtmf", title: t("editor.dtmf_actions"),
                                      footer: t("editor.dtmf_hint"), rows: rows)
        model.delete = { code in
            var next = actions
            next.removeValue(forKey: code)
            return write(next)
        }
        model.addTitle = t("editor.add_dtmf")
        model.addPrompt = t("editor.dtmf_code")
        model.addWithText = { text in
            let code = text.trimmingCharacters(in: .whitespaces).uppercased()
            guard (1...8).contains(code.count), code.allSatisfy({ "0123456789*#ABCD".contains($0) }) else {
                return .invalid("editor.dtmf_code_hint")
            }
            var next = actions
            next[code] = ["type": "hangup"]
            return write(next)
        }
        return model
    }

    // MARK: External cameras

    func mediaSourceList() -> SettingsListModel {
        let sources = map("media_sources")
        let rows = sources.keys.sorted().map { id -> SettingsListRow in
            let entry = sources[id] as? [String: Any] ?? [:]
            let streams = entry["streams"] as? [String: Any] ?? [:]
            return SettingsListRow(id: id, title: id, detail: streams.keys.sorted().joined(separator: ", "),
                                   edit: { self.mediaSourcePage(id, entry: entry) })
        }
        var model = SettingsListModel(id: "media_sources", title: t("prefs.media_sources"),
                                      footer: t("editor.media_hint"), rows: rows)
        model.delete = { id in .write([.delete("media_sources.\(id)")]) }
        model.addTitle = t("prefs.media_sources")
        model.addPrompt = "http://192.0.2.20/live.mjpeg"
        model.addWithText = { text in
            let url = text.trimmingCharacters(in: .whitespaces)
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return .invalid("editor.media_url_hint") }
            return .write([.set("media_sources.\(SettingValidation.newId("cam"))",
                                ["schema_version": 1, "kind": "ip_camera",
                                 "streams": ["mjpeg": ["url": url]]])])
        }
        return model
    }

    func mediaSourcePage(_ id: String, entry: [String: Any]) -> SettingsPage {
        let streams = entry["streams"] as? [String: Any] ?? [:]
        let items = [("mjpeg", "MJPEG (http/https)"), ("snapshot", "Snapshot JPEG (http/https)"),
                     ("h264", "H.264 (rtsp, TCP, Baseline)")].map { name, title -> SettingItem in
            let url = ConfigUtil.str(streams[name] as? [String: Any], "url") ?? ""
            return SettingItem("media_\(name)", title, detail: url,
                               .text(value: url, placeholder: name == "h264" ? "rtsp://" : "http://",
                                     numeric: false)) { value in
                let text = (value.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                var next = streams
                if text.isEmpty {
                    next.removeValue(forKey: name)
                } else if name == "h264" {
                    next[name] = ["url": text, "transport": "tcp", "profile": "baseline"]
                } else {
                    next[name] = ["url": text]
                }
                guard !next.isEmpty else { return .invalid("editor.media_url_hint") }
                var updated = entry
                updated["schema_version"] = 1
                updated["kind"] = "ip_camera"
                updated["streams"] = next
                return .write([.set("media_sources.\(id)", updated)])
            }
        }
        let stored = (ConfigUtil.str(entry, "secret_ref") ?? "").hasPrefix("secret:")
        return SettingsPage(id: id, title: id, sections: [
            SettingSection(t("editor.streams"), footer: t("editor.media_url_hint"), items),
            SettingSection(footer: t("editor.media_hint"), [
                SettingItem("media_credential", t("editor.camera_credential"),
                            detail: t(stored ? "editor.secret_set" : "editor.secret_unset"), .secret) { value in
                    (value.stringValue ?? "").isEmpty ? .none : .local("mediasecret|\(id)")
                }]),
        ])
    }

    func transferPage() -> SettingsPage {
        var items = [SettingItem("config_export", t("editor.export_file"), .action(destructive: false)) { _ in
            .local("config.export") }]
        items.append(SettingItem("config_import_file", t("editor.import_file"),
                                 .action(destructive: true)) { _ in .local("config.import_file") })
        items.append(SettingItem("config_import", t("editor.import_clipboard"), .action(destructive: true)) { _ in
            .local("config.import") })
        return SettingsPage(id: "import_export", title: t("editor.config_transfer"),
                            sections: [SettingSection(footer: t("editor.config_transfer_hint"), items)])
    }
}
