import UIKit

/// One announcement as it is stored in configuration: `doors.<id>.notice` for a single door, or
/// `notice.global` for the whole home. A door-specific announcement always wins over the global
/// one, which is what "全体 / この門口機" means on every shell.
struct DoorbellNotice {
    let text: String
    let fromDevice: String
    let createdMs: Int64
    let expiresMs: Int64
    /// True when this door is showing the home-wide announcement rather than its own.
    let isGlobal: Bool

    static func parse(_ value: Any?, isGlobal: Bool) -> DoorbellNotice? {
        guard let object = value as? [String: Any] else { return nil }
        let text = ConfigUtil.str(object, "text") ?? ""
        guard !text.isEmpty else { return nil }
        return DoorbellNotice(text: text,
                              fromDevice: ConfigUtil.str(object, "from_device") ?? "",
                              createdMs: Int64(ConfigUtil.double(object, "created_ms", 0)),
                              expiresMs: Int64(ConfigUtil.double(object, "expires_ms", 0)),
                              isGlobal: isGlobal)
    }

    func isActive(nowMs: Int64) -> Bool {
        return expiresMs == 0 || expiresMs > nowMs
    }

    /// The announcement one door actually shows, as Core resolved it: `status.doors.<id>.notice`
    /// already applies the rule that a door-specific message overrides the house-wide one and
    /// carries the scope it came from.
    static func effective(status: [String: Any]?, config: [String: Any]?, door: String,
                          nowMs: Int64) -> DoorbellNotice? {
        if !door.isEmpty,
           let resolved = ConfigUtil.dig(status, "doors.\(door).notice") as? [String: Any],
           let notice = parse(resolved,
                              isGlobal: ConfigUtil.str(resolved, "scope") == "global") {
            return notice.isActive(nowMs: nowMs) ? notice : nil
        }
        return effective(config: config, door: door, nowMs: nowMs)
    }

    /// Effective announcement for one door. Core prunes expired values on its own tick; the
    /// deadline is re-checked here so a shell never shows a notice a second past its expiry.
    static func effective(config: [String: Any]?, door: String, nowMs: Int64) -> DoorbellNotice? {
        if !door.isEmpty,
           let own = parse(ConfigUtil.dig(config, "doors.\(door).notice"), isGlobal: false),
           own.isActive(nowMs: nowMs) {
            return own
        }
        if let global = parse(ConfigUtil.dig(config, "notice.global"), isGlobal: true),
           global.isActive(nowMs: nowMs) {
            return global
        }
        return nil
    }

    /// Administrator-editable quick phrases. The three seeded defaults are used only while the
    /// cluster has no list of its own.
    static func presets(config: [String: Any]?, texts: Texts) -> [String] {
        if let raw = ConfigUtil.dig(config, "notice.presets") as? [Any] {
            let values = raw.compactMap { entry -> String? in
                if let object = entry as? [String: Any] { return ConfigUtil.str(object, "text") }
                return entry as? String
            }.filter { !$0.isEmpty }
            if !values.isEmpty { return Array(values.prefix(8)) }
        }
        return [texts.t("notice.preset_absent"), texts.t("notice.preset_delivery"),
                texts.t("notice.preset_construction")]
    }
}

/// Compact "お知らせ" chip with a dot when an announcement is showing. Tapping opens the popover
/// the owner asked for: the current text, 編集, 取り消す and the target selector.
final class NoticeChipView: UIControl {

    var onTap: (() -> Void)?

    private let dot = UIView()
    private let label = UILabel()

    init(texts: Texts) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "notice_chip"
        backgroundColor = UIColor(white: 1, alpha: 0.14)
        layer.cornerRadius = 8
        clipsToBounds = true

        dot.backgroundColor = UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1)
        dot.layer.cornerRadius = 5
        dot.isHidden = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        label.text = texts.t("notice.chip")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            // The padded-pill rule: 6pt vertical, 12pt horizontal.
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        #if os(tvOS)
        addTarget(self, action: #selector(fire), for: .primaryActionTriggered)
        #else
        addTarget(self, action: #selector(fire), for: .touchUpInside)
        #endif
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func update(active: Bool, palette: DoorbellPalette) {
        dot.isHidden = !active
        dot.backgroundColor = palette.notice
        // Opaque on both states: the chip may be lying on the household's theme picture, and a
        // translucent fill would let that picture decide whether its label is readable.
        backgroundColor = active
            ? DoorbellTheme.solid(palette.notice.withAlphaComponent(0.24),
                                  over: palette.background)
            : palette.surfaceSolid
        label.textColor = palette.ink
    }

    @objc private func fire() { onTap?() }

    #if os(tvOS)
    override var canBecomeFocused: Bool { return true }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({ [weak self] in
            self?.layer.borderWidth = focused ? 3 : 0
            self?.layer.borderColor = UIColor.white.cgColor
        }, completion: nil)
    }
    #endif
}

/// The announcement dialog shared by all three entry points: the dashboard's home-wide button, a
/// door tile's status chip, and the monitor/incoming screen's "この門口機にお知らせ".
final class NoticeDialogViewController: UIViewController {

    private let core: CoreBridge
    private let texts: Texts
    private let writer: ConfigWriter
    private let lang: String
    private var config: [String: Any]?

    /// door ids offered in the target selector, in configuration order.
    private var doors: [String] = []
    private var selectedDoor: String
    private var expiryChoice = 2

    private let scroll = UIScrollView()
    private let content = UIStackView()
    private let targetControl = UISegmentedControl(items: [])
    private let textView = UITextView()
    private let counter = UILabel()
    private let presetStack = UIStackView()
    private let expiryControl = UISegmentedControl(items: [])
    private let customHours = UITextField()
    private let statusLabel = UILabel()
    private let publishButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)

    private var palette = DoorbellPalette.dark

    /// `door` empty selects the home-wide target.
    init(core: CoreBridge, texts: Texts, httpPort: Int, lang: String, door: String) {
        self.core = core
        self.texts = texts
        self.writer = ConfigWriter(core: core, httpPort: httpPort)
        self.lang = lang
        self.selectedDoor = door
        super.init(nibName: nil, bundle: nil)
        #if os(tvOS)
        modalPresentationStyle = .fullScreen
        #else
        modalPresentationStyle = .formSheet
        #endif
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        config = core.config()
        palette = DoorbellPalette.of(DoorbellTheme.appearance(
            config: config, nodeId: "", localTime: core.localTime()))
        view.backgroundColor = palette.background
        doors = doorIds()
        if !selectedDoor.isEmpty && !doors.contains(selectedDoor) { selectedDoor = "" }
        build()
        loadExistingText()
    }

    private func doorIds() -> [String] {
        guard let map = ConfigUtil.dig(config, "doors") as? [String: Any] else { return [] }
        return ConfigUtil.sortedByOrder(map)
    }

    private func doorLabel(_ door: String) -> String {
        let entry = ConfigUtil.dig(config, "doors.\(door)") as? [String: Any]
        return ConfigUtil.labelOf(entry, lang, door)
    }

    // MARK: - Layout

    private func build() {
        let title = UILabel()
        title.text = texts.t("notice.title")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = palette.ink

        targetControl.removeAllSegments()
        targetControl.insertSegment(withTitle: texts.t("notice.target_global"), at: 0,
                                    animated: false)
        for (index, door) in doors.enumerated() {
            targetControl.insertSegment(
                withTitle: texts.t("notice.target_door", doorLabel(door)),
                at: index + 1, animated: false)
        }
        targetControl.selectedSegmentIndex = selectedDoor.isEmpty
            ? 0 : (doors.firstIndex(of: selectedDoor).map { $0 + 1 } ?? 0)
        targetControl.accessibilityIdentifier = "notice_target"
        targetControl.addTarget(self, action: #selector(targetChanged), for: .valueChanged)

        textView.font = .systemFont(ofSize: 20)
        textView.textColor = palette.ink
        textView.backgroundColor = palette.surface
        textView.layer.cornerRadius = 10
        textView.accessibilityIdentifier = "notice_text"
        textView.delegate = self
        textView.heightAnchor.constraint(equalToConstant: 120).isActive = true

        counter.font = .systemFont(ofSize: 14)
        counter.textColor = palette.inkMuted

        presetStack.axis = .vertical
        presetStack.spacing = 8
        rebuildPresets()

        expiryControl.removeAllSegments()
        for (index, key) in ["notice.expiry_1h", "notice.expiry_today",
                             "notice.expiry_until_cleared", "notice.expiry_custom"].enumerated() {
            expiryControl.insertSegment(withTitle: texts.t(key), at: index, animated: false)
        }
        expiryControl.selectedSegmentIndex = expiryChoice
        expiryControl.accessibilityIdentifier = "notice_expiry"
        expiryControl.addTarget(self, action: #selector(expiryChanged), for: .valueChanged)

        customHours.placeholder = texts.t("notice.expiry_hours")
        customHours.text = "3"
        customHours.textColor = palette.ink
        customHours.backgroundColor = palette.surface
        customHours.borderStyle = .roundedRect
        customHours.isHidden = true
        #if os(iOS)
        customHours.keyboardType = .numberPad
        #endif

        statusLabel.font = .systemFont(ofSize: 16)
        statusLabel.textColor = palette.inkMuted
        statusLabel.numberOfLines = 0

        publishButton.setTitle(texts.t("notice.publish"), for: .normal)
        publishButton.accessibilityIdentifier = "notice_publish"
        style(publishButton, filled: true)
        publishButton.addTarget(self, action: #selector(publish), for: .primaryActionTriggered)

        clearButton.setTitle(texts.t("notice.clear"), for: .normal)
        clearButton.accessibilityIdentifier = "notice_clear"
        style(clearButton, filled: false)
        clearButton.addTarget(self, action: #selector(clear), for: .primaryActionTriggered)

        let close = UIButton(type: .system)
        close.setTitle(texts.t("settings.close"), for: .normal)
        style(close, filled: false)
        close.addTarget(self, action: #selector(dismissSelf), for: .primaryActionTriggered)

        let actions = UIStackView(arrangedSubviews: [clearButton, publishButton])
        actions.axis = .horizontal
        actions.spacing = 12
        actions.distribution = .fillEqually

        content.axis = .vertical
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        for item in [title, sectionLabel(texts.t("notice.target")), targetControl,
                     sectionLabel(texts.t("notice.text")), textView, counter,
                     sectionLabel(texts.t("notice.presets")), presetStack,
                     sectionLabel(texts.t("notice.expiry")), expiryControl, customHours,
                     statusLabel, actions, close] {
            content.addArrangedSubview(item)
        }

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        view.addSubview(scroll)
        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -20),
            content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -40),
        ])
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = palette.inkMuted
        return label
    }

    private func style(_ button: UIButton, filled: Bool) {
        button.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        button.setTitleColor(filled ? palette.onAccent : palette.ink, for: .normal)
        button.backgroundColor = filled ? palette.accent : palette.surface
        button.layer.cornerRadius = 12
        #if !os(tvOS)
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 22, bottom: 12, right: 22)
        #endif
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func rebuildPresets() {
        for view in presetStack.arrangedSubviews { view.removeFromSuperview() }
        for (index, preset) in DoorbellNotice.presets(config: config, texts: texts).enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(preset, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 17)
            button.titleLabel?.numberOfLines = 0
            button.setTitleColor(palette.ink, for: .normal)
            button.backgroundColor = palette.surface
            button.layer.cornerRadius = 10
            button.tag = index
            button.accessibilityIdentifier = "notice_preset_\(index)"
            #if !os(tvOS)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
            #endif
            button.addTarget(self, action: #selector(usePreset(_:)), for: .primaryActionTriggered)
            presetStack.addArrangedSubview(button)
        }
    }

    // MARK: - State

    private func loadExistingText() {
        let nowMs = DoorbellClock.nowMs(core)
        let existing: DoorbellNotice?
        if selectedDoor.isEmpty {
            existing = DoorbellNotice.parse(ConfigUtil.dig(config, "notice.global"),
                                            isGlobal: true)
        } else {
            existing = DoorbellNotice.parse(
                ConfigUtil.dig(config, "doors.\(selectedDoor).notice"), isGlobal: false)
        }
        textView.text = existing.map { $0.isActive(nowMs: nowMs) ? $0.text : "" } ?? ""
        updateCounter()
    }

    private func updateCounter() {
        let count = (textView.text ?? "").count
        counter.text = count > 200 ? texts.t("notice.too_long", "\(count)") : "\(count) / 200"
        counter.textColor = count > 200 ? palette.danger : palette.inkMuted
    }

    @objc private func targetChanged() {
        let index = targetControl.selectedSegmentIndex
        selectedDoor = index <= 0 ? "" : doors[index - 1]
        loadExistingText()
    }

    @objc private func expiryChanged() {
        expiryChoice = expiryControl.selectedSegmentIndex
        customHours.isHidden = expiryChoice != 3
    }

    @objc private func usePreset(_ sender: UIButton) {
        textView.text = sender.currentTitle ?? ""
        updateCounter()
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    private func expiresMs() -> Int64 {
        let now = DoorbellClock.nowMs(core)
        switch expiryChoice {
        case 0: return now + 3_600_000
        case 1: return DoorbellClock.endOfTodayMs(core)
        case 3:
            let hours = max(1, min(720, Int(customHours.text ?? "") ?? 3))
            return now + Int64(hours) * 3_600_000
        default: return 0
        }
    }

    // MARK: - Writes

    @objc private func publish() {
        let text = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusLabel.text = texts.t("notice.empty")
            return
        }
        guard text.count <= 200 else {
            statusLabel.text = texts.t("notice.too_long", "\(text.count)")
            return
        }
        let deadline = expiresMs()
        if selectedDoor.isEmpty {
            publishGlobal(text: text, expiresMs: deadline)
            return
        }
        finish(core.setDoorNotice(door: selectedDoor, text: text, expiresMs: deadline)
            ? texts.t("notice.saved") : texts.t("notice.failed"))
    }

    /// The house-wide announcement goes through the same Core entry point as a door's, addressed
    /// as "*". Only a Core that predates that target falls back to writing the key directly.
    private func publishGlobal(text: String, expiresMs: Int64) {
        if core.setGlobalNotice(text: text, expiresMs: expiresMs) {
            finish(texts.t("notice.saved"))
            return
        }
        var nodeId = ""
        if let node = core.status()?["node"] as? [String: Any] {
            nodeId = ConfigUtil.evStr(node, "id")
        }
        let value: [String: Any] = [
            "text": text,
            "from_device": nodeId,
            "created_ms": DoorbellClock.nowMs(core),
            "expires_ms": expiresMs,
        ]
        publishButton.isEnabled = false
        writer.apply([.set("notice.global", value)]) { [weak self] result in
            guard let self = self else { return }
            self.publishButton.isEnabled = true
            self.finish(result.isOk ? self.texts.t("notice.saved") : self.texts.t("notice.failed"))
        }
    }

    @objc private func clear() {
        if selectedDoor.isEmpty {
            if core.clearGlobalNotice() {
                finish(texts.t("notice.cleared"))
                return
            }
            clearButton.isEnabled = false
            writer.apply([.delete("notice.global")]) { [weak self] result in
                guard let self = self else { return }
                self.clearButton.isEnabled = true
                self.finish(result.isOk ? self.texts.t("notice.cleared")
                    : self.texts.t("notice.failed"))
            }
            return
        }
        finish(core.clearDoorNotice(door: selectedDoor) ? texts.t("notice.cleared")
            : texts.t("notice.failed"))
    }

    private func finish(_ message: String) {
        statusLabel.text = message
        config = core.config()
        guard message != texts.t("notice.failed") else { return }
        _ = IOSAvailability.scheduledTimer(withTimeInterval: 0.9, repeats: false) {
            [weak self] _ in self?.dismiss(animated: true)
        }
    }
}

extension NoticeDialogViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) { updateCounter() }
}
