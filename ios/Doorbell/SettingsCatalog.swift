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
                             icon: SettingIcon(glyph: "📱", tint: 0x8E8E93),
                             summary: ctx.name, page: devicePage),
            SettingsCategory(id: "sounds", title: t("prefs.sounds"),
                             icon: SettingIcon(glyph: "🔔", tint: 0xFF3B30),
                             summary: volumeSummary(), page: soundsPage),
            SettingsCategory(id: "display", title: t("prefs.display"),
                             icon: SettingIcon(glyph: "☀️", tint: 0x007AFF),
                             summary: appearanceTitle(), page: displayPage),
            SettingsCategory(id: "calls", title: t("prefs.calls"),
                             icon: SettingIcon(glyph: "📞", tint: 0x34C759),
                             summary: callFlowTitle(), page: callsPage),
            SettingsCategory(id: "doors", title: t("settings.section_doors"),
                             icon: SettingIcon(glyph: "🚪", tint: 0xA2845E),
                             summary: countSummary("doors"), page: doorsPage),
            SettingsCategory(id: "sos", title: t("prefs.sos"),
                             icon: SettingIcon(glyph: "🆘", tint: 0xFF2D55),
                             summary: "", page: sosPage),
            SettingsCategory(id: "time", title: t("time.title"),
                             icon: SettingIcon(glyph: "🕒", tint: 0x5856D6),
                             summary: ConfigUtil.str(cfg, "time.zone") ?? "", page: timePage),
            SettingsCategory(id: "notifications", title: t("settings.section_rules"),
                             icon: SettingIcon(glyph: "📣", tint: 0xFF9500),
                             summary: ruleSummary(), page: notificationsPage),
        ]
        if !ctx.isTV {
            result.append(SettingsCategory(id: "sip", title: t("prefs.sip"),
                                           icon: SettingIcon(glyph: "☎️", tint: 0x30B0C7),
                                           summary: ctx.sipBackend, page: sipPage))
        }
        result.append(contentsOf: [
            SettingsCategory(id: "cluster", title: t("settings.section_cluster"),
                             icon: SettingIcon(glyph: "🔗", tint: 0x32ADE6),
                             summary: ctx.membershipSummary, page: clusterPage),
            SettingsCategory(id: "about", title: t("prefs.about"),
                             icon: SettingIcon(glyph: "ℹ️", tint: 0x636366),
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

    private func webRow(_ id: String, _ title: String, reason: String) -> SettingItem {
        return SettingItem(id, title, detail: t("prefs.open_in_admin"), .web(reason))
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
        if !ctx.isTV {
            identity.append(SettingItem("device_role", t("settings.device_role"),
                .segmented(value: ctx.role, options: [
                    SettingOption(value: "indoor_panel", title: t("admin.role_indoor")),
                    SettingOption(value: "door_station", title: t("admin.role_door"))])) { _ in
                return .local("identity.role")
            })
            if isDoor {
                identity.append(SettingItem("device_door", t("settings.device_door"),
                                            detail: ctx.door,
                                            .text(value: ctx.door, placeholder: "door-front",
                                                  numeric: false)) { value in
                    guard let text = value.stringValue, SettingValidation.doorId(text) else {
                        return .invalid("prefs.invalid_door_id")
                    }
                    return .local("identity.door")
                })
            }
        }
        let languages = (ConfigUtil.dig(cfg, "ui.languages") as? [Any])?
            .compactMap { $0 as? String } ?? ["ja", "en", "zh"]
        let lang = deviceKey("local.ui_lang").flatMap { ConfigUtil.str(cfg, $0) } ?? ctx.uiLang
        var sections = [
            SettingSection(t("prefs.identity"), footer: ctx.isTV ? "" : t("settings.role_restart_notice"),
                           identity),
            SettingSection(t("admin.language"), [
                SettingItem("device_lang", t("settings.ui_lang"),
                            .choice(value: lang, options: languages.map {
                                SettingOption(value: $0, title: Texts.langDisplayName($0))
                            }, searchable: false), commit: set(deviceKey("local.ui_lang"))),
            ]),
        ]
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
        tones.append(webRow("sound_upload", t("prefs.sound_upload"), reason: t("settings.web_only_upload")))
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
            webRow("theme_upload", t("prefs.image_upload"), reason: t("settings.web_only_upload")),
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
            SettingSection(t("prefs.theme"), footer: backgroundFooter(background), theme),
            SettingSection(t("prefs.brightness"), night),
            SettingSection(t("prefs.screensaver"), saver),
            SettingSection([webRow("wording", t("settings.web_only_labels"),
                                   reason: t("settings.web_only_wording"))]),
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
                webRow("reply_audio", t("prefs.reply_audio"), reason: t("settings.web_only_upload")),
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
            SettingSection([webRow("buildings", t("prefs.buildings"), reason: t("prefs.web_only_structure"))]),
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
            SettingSection([webRow("sos_rules", t("prefs.sos_presentation"),
                                   reason: t("settings.web_only_rule_actions"))]),
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
            SettingSection(t("prefs.rules"), footer: t("settings.web_only_rule_actions"),
                           ruleItems + [webRow("rule_edit", t("prefs.rule_edit"),
                                               reason: t("settings.web_only_rule_actions"))]),
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
            SettingSection(t("admin.notify"), footer: t("settings.web_only_secrets"), [
                SettingItem("telegram", t("settings.telegram"),
                            .info(configured("integrations.telegram.bot_token_ref"))),
                SettingItem("web_push", t("settings.web_push"),
                            .info(configured("integrations.web_push.sender_url"))),
                SettingItem("mqtt", "MQTT", .info(configured("integrations.mqtt.host"))),
                webRow("integrations", t("prefs.integrations"), reason: t("settings.web_only_secrets")),
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
                webRow("sip_password", t("prefs.sip_password"), reason: t("settings.web_only_secrets")),
            ]),
            SettingSection([webRow("dtmf", t("prefs.dtmf"), reason: t("prefs.web_only_dtmf"))]),
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
            SettingSection(footer: t("prefs.web_only_panels"), [
                webRow("panels", t("prefs.panels"), reason: t("prefs.web_only_panels")),
                webRow("media_sources", t("prefs.media_sources"), reason: t("prefs.web_only_structure")),
                webRow("households", t("prefs.households"), reason: t("prefs.web_only_structure")),
                webRow("import_export", t("prefs.import_export"), reason: t("prefs.web_only_structure")),
            ]),
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
            SettingSection([
                SettingItem("device_info", t("settings.section_info"), .shell("device_info")),
                SettingItem("web_admin", t("settings.section_web"), .shell("web_admin")),
            ]),
        ])
    }
}
