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
        backgroundColor = SystemStyle.fill
        layer.cornerRadius = 8
        clipsToBounds = true

        dot.backgroundColor = SystemStyle.warning
        dot.layer.cornerRadius = 5
        dot.isHidden = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        label.text = texts.t("notice.chip")
        label.font = SystemStyle.font(.subheadline, weight: .semibold)
        label.textColor = SystemStyle.label
        SystemStyle.followContentSize(label)
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

    /// A dot marks an announcement that is showing. `overPicture` is for a chip laid on a camera
    /// still, where only a fixed dark fill with white text stays readable.
    func update(active: Bool, overPicture: Bool = false) {
        dot.isHidden = !active
        dot.backgroundColor = SystemStyle.warning
        backgroundColor = overPicture ? UIColor(white: 0, alpha: 0.55) : SystemStyle.fill
        label.textColor = overPicture ? .white : SystemStyle.label
        accessibilityTraits = .button
        accessibilityLabel = label.text
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

/// The announcement editor shared by its entry points: the home screen's bar button, a door
/// tile's chip, and the call screen's chip. A navigation bar with Close and Publish over a
/// grouped table: target, text, saved messages, expiry, and Clear in red at the end. It opens as
/// a sheet, so the screen underneath (a live call included) stays in place.
final class NoticeDialogViewController: UINavigationController {

    /// `door` empty selects the home-wide target.
    init(core: CoreBridge, texts: Texts, httpPort: Int, lang: String, door: String) {
        let editor = NoticeEditorController(core: core, texts: texts, httpPort: httpPort,
                                            lang: lang, door: door)
        super.init(rootViewController: editor)
        SystemStyle.style(self, largeTitles: false)
        #if os(tvOS)
        modalPresentationStyle = .fullScreen
        #else
        modalPresentationStyle = .formSheet
        #endif
    }

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The style to use when the editor opens over a live call. A sheet keeps its presenter in
    /// the hierarchy from iOS 13; before that a form sheet on a compact iPhone, and any
    /// presentation on tvOS, replaces it, so those use over-full-screen instead.
    static var overCallPresentationStyle: UIModalPresentationStyle {
        #if os(iOS)
        if #available(iOS 13.0, *) { return .formSheet }
        #endif
        return .overFullScreen
    }
}

private final class NoticeEditorController: UITableViewController, UITextViewDelegate {

    private enum Section: Int, CaseIterable {
        case target, text, presets, expiry, actions
    }

    private let core: CoreBridge
    private let texts: Texts
    private let writer: ConfigWriter
    private let lang: String
    private var config: [String: Any]?

    /// door ids offered as targets, in configuration order.
    private var doors: [String] = []
    private var selectedDoor: String
    private var expiryChoice = 2
    private var presets: [String] = []
    private var busy = false

    private let textView = UITextView()
    private let customHours = UITextField()
    private static let expiryKeys = ["notice.expiry_1h", "notice.expiry_today",
                                     "notice.expiry_until_cleared", "notice.expiry_custom"]

    init(core: CoreBridge, texts: Texts, httpPort: Int, lang: String, door: String) {
        self.core = core
        self.texts = texts
        self.writer = ConfigWriter(core: core, httpPort: httpPort)
        self.lang = lang
        self.selectedDoor = door
        super.init(style: SystemStyle.tableStyle())
        title = texts.t("notice.title")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        SystemStyle.style(tableView)
        tableView.accessibilityIdentifier = "notice_editor"
        tableView.keyboardDismissMode = .interactive
        config = core.config()
        doors = doorIds()
        if !selectedDoor.isEmpty && !doors.contains(selectedDoor) { selectedDoor = "" }
        presets = DoorbellNotice.presets(config: config, texts: texts)

        textView.font = SystemStyle.font(.body)
        textView.textColor = SystemStyle.label
        textView.backgroundColor = .clear
        textView.accessibilityIdentifier = "notice_text"
        textView.accessibilityLabel = texts.t("notice.text")
        textView.delegate = self
        if #available(iOS 10.0, tvOS 10.0, *) { textView.adjustsFontForContentSizeCategory = true }

        customHours.placeholder = texts.t("notice.expiry_hours")
        customHours.text = "3"
        customHours.textAlignment = .right
        customHours.font = SystemStyle.font(.body)
        customHours.textColor = SystemStyle.label
        customHours.accessibilityIdentifier = "notice_expiry_hours"
        #if os(iOS)
        customHours.keyboardType = .numberPad
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: texts.t("settings.close"), style: .plain, target: self,
            action: #selector(dismissSelf))
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "notice_close"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: texts.t("notice.publish"), style: .done, target: self,
            action: #selector(publish))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "notice_publish"
        #endif
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

    // MARK: - Table

    /// tvOS has no bar buttons to carry Publish and Close, so they are rows there.
    private var actionRows: [String] {
        #if os(tvOS)
        return ["notice.publish", "notice.clear", "settings.close"]
        #else
        return ["notice.clear"]
        #endif
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .target?: return doors.count + 1
        case .text?: return 1
        case .presets?: return presets.count
        case .expiry?: return NoticeEditorController.expiryKeys.count + (expiryChoice == 3 ? 1 : 0)
        case .actions?: return actionRows.count
        case nil: return 0
        }
    }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .target?: return texts.t("notice.target")
        case .text?: return texts.t("notice.text")
        case .presets?: return presets.isEmpty ? nil : texts.t("notice.presets")
        case .expiry?: return texts.t("notice.expiry")
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section) == .text else { return nil }
        return counterText()
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath)
        -> CGFloat {
        return Section(rawValue: indexPath.section) == .text ? 132 : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        SystemStyle.style(cell)
        switch Section(rawValue: indexPath.section) {
        case .target?:
            let door = indexPath.row == 0 ? "" : doors[indexPath.row - 1]
            cell.textLabel?.text = door.isEmpty ? texts.t("notice.target_global")
                : texts.t("notice.target_door", doorLabel(door))
            cell.accessoryType = door == selectedDoor ? .checkmark : .none
            cell.accessibilityIdentifier = "notice_target_" + (door.isEmpty ? "global" : door)
        case .text?:
            cell.selectionStyle = .none
            textView.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(textView)
            let margins = cell.contentView.layoutMarginsGuide
            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 4),
                textView.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor,
                                                 constant: -4),
                textView.leadingAnchor.constraint(equalTo: margins.leadingAnchor, constant: -4),
                textView.trailingAnchor.constraint(equalTo: margins.trailingAnchor, constant: 4),
            ])
        case .presets?:
            cell.textLabel?.text = presets[indexPath.row]
            cell.accessibilityIdentifier = "notice_preset_\(indexPath.row)"
        case .expiry?:
            if indexPath.row < NoticeEditorController.expiryKeys.count {
                cell.textLabel?.text = texts.t(NoticeEditorController.expiryKeys[indexPath.row])
                cell.accessoryType = indexPath.row == expiryChoice ? .checkmark : .none
                cell.accessibilityIdentifier = "notice_expiry_\(indexPath.row)"
            } else {
                cell.selectionStyle = .none
                cell.textLabel?.text = texts.t("notice.expiry_hours")
                customHours.frame = CGRect(x: 0, y: 0, width: 96, height: 36)
                cell.accessoryView = customHours
            }
        case .actions?:
            let key = actionRows[indexPath.row]
            cell.textLabel?.text = texts.t(key)
            // Clearing removes the announcement from every screen showing it.
            cell.textLabel?.textColor = key == "notice.clear" ? SystemStyle.negative
                : SystemStyle.tint
            cell.accessibilityIdentifier = key.replacingOccurrences(of: ".", with: "_")
                .replacingOccurrences(of: "settings_close", with: "notice_close")
            cell.accessibilityTraits = .button
        case nil:
            break
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .target?:
            selectedDoor = indexPath.row == 0 ? "" : doors[indexPath.row - 1]
            loadExistingText()
            tableView.reloadData()
        case .presets?:
            textView.text = presets[indexPath.row]
            updateCounter()
        case .expiry?:
            guard indexPath.row < NoticeEditorController.expiryKeys.count else { return }
            expiryChoice = indexPath.row
            tableView.reloadData()
        case .actions?:
            switch actionRows[indexPath.row] {
            case "notice.publish": publish()
            case "notice.clear": clear()
            default: dismissSelf()
            }
        default:
            break
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

    private func counterText() -> String {
        let count = (textView.text ?? "").count
        return count > 200 ? texts.t("notice.too_long", "\(count)") : "\(count) / 200"
    }

    private func updateCounter() {
        guard isViewLoaded,
              let footer = tableView.footerView(forSection: Section.text.rawValue) else { return }
        footer.textLabel?.text = counterText()
        footer.textLabel?.textColor = (textView.text ?? "").count > 200 ? SystemStyle.negative
            : SystemStyle.secondaryLabel
        footer.setNeedsLayout()
    }

    func textViewDidChange(_ textView: UITextView) { updateCounter() }

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

    /// What happened to the last action, in the navigation bar's prompt line.
    private func setStatus(_ message: String) {
        #if os(iOS)
        navigationItem.prompt = message
        #else
        title = message
        #endif
    }

    private func setBusy(_ value: Bool) {
        busy = value
        navigationItem.rightBarButtonItem?.isEnabled = !value
    }

    // MARK: - Writes

    @objc private func publish() {
        guard !busy else { return }
        let text = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            setStatus(texts.t("notice.empty"))
            return
        }
        guard text.count <= 200 else {
            setStatus(texts.t("notice.too_long", "\(text.count)"))
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
        setBusy(true)
        writer.apply([.set("notice.global", value)]) { [weak self] result in
            guard let self = self else { return }
            self.setBusy(false)
            self.finish(result.isOk ? self.texts.t("notice.saved") : self.texts.t("notice.failed"))
        }
    }

    private func clear() {
        guard !busy else { return }
        if selectedDoor.isEmpty {
            if core.clearGlobalNotice() {
                finish(texts.t("notice.cleared"))
                return
            }
            setBusy(true)
            writer.apply([.delete("notice.global")]) { [weak self] result in
                guard let self = self else { return }
                self.setBusy(false)
                self.finish(result.isOk ? self.texts.t("notice.cleared")
                    : self.texts.t("notice.failed"))
            }
            return
        }
        finish(core.clearDoorNotice(door: selectedDoor) ? texts.t("notice.cleared")
            : texts.t("notice.failed"))
    }

    private func finish(_ message: String) {
        setStatus(message)
        config = core.config()
        guard message != texts.t("notice.failed") else { return }
        _ = IOSAvailability.scheduledTimer(withTimeInterval: 0.9, repeats: false) {
            [weak self] _ in self?.dismiss(animated: true)
        }
    }
}
