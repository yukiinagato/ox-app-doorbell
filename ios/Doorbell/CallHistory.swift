import UIKit

/// One row of `db_core_call_log_json`.
struct CallLogRow {
    let id: String
    let callId: String
    let tsMs: Int64
    let door: String
    let purpose: String
    let outcome: String
    let answeredBy: String
    let durationMs: Int64
    let hlc: String
    let seen: Bool

    /// The row a reusable view holds before it has been pointed at a call.
    static let empty = CallLogRow(id: "", callId: "", tsMs: 0, door: "", purpose: "",
                                  outcome: "", answeredBy: "", durationMs: 0, hlc: "", seen: true)

    static func parse(_ value: [String: Any]) -> CallLogRow {
        return CallLogRow(id: ConfigUtil.evStr(value, "id"),
                          callId: ConfigUtil.evStr(value, "call_id"),
                          tsMs: Int64(ConfigUtil.double(value, "ts", 0)),
                          door: ConfigUtil.evStr(value, "door"),
                          purpose: ConfigUtil.evStr(value, "purpose"),
                          outcome: ConfigUtil.evStr(value, "outcome"),
                          answeredBy: ConfigUtil.evStr(value, "answered_by"),
                          durationMs: Int64(ConfigUtil.double(value, "duration_ms", 0)),
                          hlc: ConfigUtil.evStr(value, "hlc"),
                          seen: ConfigUtil.evBool(value, "seen"))
    }
}

/// Shared reading and wording of the call log, so every surface describes a call the same way.
enum CallHistory {

    static let pageSize = 50
    private static let abiMaxRows = 500

    /// Newest-first page ending strictly before `beforeMs`. Core's paging entry point is used when
    /// it exists; the older ABI exposes only an inclusive lower bound, so the window is read whole
    /// and trimmed here instead. Either way the contract is the same: 50 rows, then さらに読み込む.
    static func page(_ core: CoreBridge, beforeMs: Int64, limit: Int = pageSize) -> [CallLogRow] {
        if let json = core.callLogPage(sinceMs: 0, beforeMs: beforeMs, limit: limit),
           let raw = json["rows"] as? [[String: Any]] {
            return raw.map(CallLogRow.parse)
        }
        guard let json = core.callLog(sinceMs: 0, limit: abiMaxRows),
              let raw = json["rows"] as? [[String: Any]] else { return [] }
        var rows = raw.map(CallLogRow.parse)
        if beforeMs > 0 { rows = rows.filter { $0.tsMs < beforeMs } }
        return Array(rows.prefix(limit))
    }

    static func unreadMissed(_ core: CoreBridge) -> Int {
        return ConfigUtil.int(core.callLog(sinceMs: 0, limit: 1), "unread_missed", 0)
    }

    static func matches(_ row: CallLogRow, filter: String) -> Bool {
        if filter == "missed" { return row.outcome == "missed" }
        if filter.hasPrefix("door:") { return row.door == String(filter.dropFirst(5)) }
        return true
    }

    static func outcomeText(_ texts: Texts, _ outcome: String) -> String {
        switch outcome {
        case "answered": return texts.t("history.outcome_answered")
        case "replied": return texts.t("history.outcome_replied")
        case "cancelled": return texts.t("history.outcome_cancelled")
        default: return texts.t("history.outcome_missed")
        }
    }

    static func doorLabel(_ config: [String: Any]?, _ door: String, lang: String) -> String {
        guard !door.isEmpty else { return "" }
        let entry = ConfigUtil.dig(config, "doors.\(door)") as? [String: Any]
        return ConfigUtil.labelOf(entry, lang, door)
    }

    static func purposeLabel(_ config: [String: Any]?, _ purpose: String, lang: String) -> String {
        guard !purpose.isEmpty else { return "" }
        let entry = ConfigUtil.dig(config, "visit_purposes.\(purpose)") as? [String: Any]
        return ConfigUtil.labelOf(entry, lang, purpose)
    }

    static func durationText(_ texts: Texts, _ durationMs: Int64) -> String {
        guard durationMs > 0 else { return "" }
        let seconds = Int(durationMs / 1000)
        return texts.t("history.duration", String(format: "%d:%02d", seconds / 60, seconds % 60))
    }

    /// "玄関 · 配達" then "応答 · iPad · 0:42", matching the reviewed layout.
    static func subtitle(_ texts: Texts, config: [String: Any]?, row: CallLogRow,
                         lang: String) -> String {
        var parts = [outcomeText(texts, row.outcome)]
        if !row.answeredBy.isEmpty { parts.append(row.answeredBy) }
        let duration = durationText(texts, row.durationMs)
        if !duration.isEmpty { parts.append(duration) }
        return parts.joined(separator: " · ")
    }

    static func title(config: [String: Any]?, row: CallLogRow, lang: String) -> String {
        var parts: [String] = []
        let door = doorLabel(config, row.door, lang: lang)
        if !door.isEmpty { parts.append(door) }
        let purpose = purposeLabel(config, row.purpose, lang: lang)
        if !purpose.isEmpty { parts.append(purpose) }
        return parts.joined(separator: " · ")
    }
}

extension CallHistory {
    /// The vendored icon and the colour role for one outcome.
    static func outcomeIcon(_ outcome: String) -> (name: String, color: UIColor) {
        switch outcome {
        case "answered": return ("TablerPhone", SystemStyle.positive)
        case "replied": return ("TablerMessageReply", SystemStyle.tint)
        case "cancelled": return ("TablerX", SystemStyle.secondaryLabel)
        default: return ("TablerPhoneOff", SystemStyle.negative)
        }
    }

    /// Fills a stock subtitle cell for one call: outcome icon, door and purpose, the outcome
    /// line, and the time of day on the trailing edge. An unread missed call is set in bold.
    static func configure(_ cell: UITableViewCell, core: CoreBridge, texts: Texts,
                          config: [String: Any]?, row: CallLogRow, lang: String) {
        SystemStyle.style(cell)
        let unread = row.outcome == "missed" && !row.seen
        let title = CallHistory.title(config: config, row: row, lang: lang)
        cell.textLabel?.text = title.isEmpty ? outcomeText(texts, row.outcome) : title
        cell.textLabel?.font = SystemStyle.font(.body, weight: unread ? .semibold : nil)
        cell.detailTextLabel?.text = subtitle(texts, config: config, row: row, lang: lang)
        cell.detailTextLabel?.font = SystemStyle.font(.subheadline)
        cell.detailTextLabel?.textColor = row.outcome == "missed" ? SystemStyle.negative
            : SystemStyle.secondaryLabel
        let icon = outcomeIcon(row.outcome)
        cell.imageView?.image = TablerIcon.image(icon.name)
        cell.imageView?.tintColor = icon.color
        let time = (cell.accessoryView as? UILabel) ?? UILabel()
        time.font = SystemStyle.digits(size: 15, weight: .regular)
        time.textColor = SystemStyle.secondaryLabel
        time.text = DoorbellClock.timeOfDay(core, wallMs: row.tsMs)
        time.sizeToFit()
        cell.accessoryView = time
        cell.accessibilityIdentifier = "history_row_\(row.id)"
    }
}

/// Call history: a table grouped by day with a filter in the navigation bar, fifty rows a page
/// and a row that loads more. Selecting a call shows its details, pushed on a compact window and
/// in the secondary column of a split view on a wide one. Showing the list moves the device-local
/// seen watermark, which is what clears the History tab's badge.
final class CallHistoryViewController: UIViewController, UISplitViewControllerDelegate {

    private let core: CoreBridge
    private let texts: Texts
    private let lang: String
    private let embedded: Bool
    private var list: CallHistoryListController?
    private var split: UISplitViewController?
    /// Called after the list marked the log seen, so the host can refresh its badge.
    var onSeen: (() -> Void)?

    /// `embedded` is true for the History tab; a presented history carries a Close button.
    init(core: CoreBridge, texts: Texts, lang: String, embedded: Bool = false) {
        self.core = core
        self.texts = texts
        self.lang = lang
        self.embedded = embedded
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        title = texts.t("history.title")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SystemStyle.groupedBackground
        let list = CallHistoryListController(core: core, texts: texts, lang: lang)
        list.onClose = embedded ? nil : { [weak self] in self?.dismiss(animated: true) }
        list.onSeen = { [weak self] in self?.onSeen?() }
        self.list = list
        let master = SystemStyle.navigation(list, largeTitles: false)
        let root: UIViewController
        #if os(tvOS)
        let wide = true
        #else
        let wide = UIDevice.current.userInterfaceIdiom == .pad
        #endif
        if wide {
            let split = UISplitViewController()
            let placeholder = CallHistoryDetailController(core: core, texts: texts, lang: lang,
                                                          row: nil)
            split.viewControllers = [master, SystemStyle.navigation(placeholder,
                                                                    largeTitles: false)]
            split.delegate = self
            split.preferredDisplayMode = .allVisible
            split.preferredPrimaryColumnWidthFraction = 0.42
            split.maximumPrimaryColumnWidth = 460
            list.showsDetailInSplit = true
            self.split = split
            root = split
        } else {
            root = master
        }
        addChild(root)
        root.view.frame = view.bounds
        root.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(root.view)
        root.didMove(toParent: self)
    }

    /// A compact window shows the list first, never an empty detail.
    func splitViewController(_ splitViewController: UISplitViewController,
                             collapseSecondary secondaryViewController: UIViewController,
                             onto primaryViewController: UIViewController) -> Bool {
        return true
    }

    func refresh() { list?.reload(reset: true) }
}

final class CallHistoryListController: UITableViewController {

    private let core: CoreBridge
    private let texts: Texts
    private let lang: String
    private var config: [String: Any]?
    var onClose: (() -> Void)?
    var onSeen: (() -> Void)?
    var showsDetailInSplit = false

    private var filter = "all"
    private var rows: [CallLogRow] = []
    private var days: [(key: String, title: String, rows: [CallLogRow])] = []
    private var reachedEnd = false
    private var doorFilters: [String] = []
    private let filterControl = UISegmentedControl(items: [])
    private var logObserverKey: String { return "history-\(ObjectIdentifier(self).hashValue)" }

    init(core: CoreBridge, texts: Texts, lang: String) {
        self.core = core
        self.texts = texts
        self.lang = lang
        super.init(style: SystemStyle.tableStyle())
        title = texts.t("history.title")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        SystemStyle.style(tableView)
        tableView.accessibilityIdentifier = "history_list"
        config = core.config()
        buildFilter()
        #if os(iOS)
        if #available(iOS 11.0, *) { navigationItem.largeTitleDisplayMode = .never }
        navigationItem.titleView = filterControl
        if onClose != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: texts.t("settings.close"), style: .done, target: self,
                action: #selector(closeSelf))
            navigationItem.leftBarButtonItem?.accessibilityIdentifier = "history_close"
        }
        navigationItem.rightBarButtonItem = SystemStyle.barItem(
            icon: "TablerCheck", label: texts.t("history.mark_seen"), target: self,
            action: #selector(markAllSeen), identifier: "history_mark_seen")
        #else
        filterControl.sizeToFit()
        tableView.tableHeaderView = filterControl
        #endif
    }

    private func buildFilter() {
        doorFilters = (ConfigUtil.dig(config, "doors") as? [String: Any])
            .map { ConfigUtil.sortedByOrder($0) } ?? []
        // A segmented control holds a handful of choices; beyond that the per-door filters would
        // be too narrow to read or touch.
        if doorFilters.count > 3 { doorFilters = Array(doorFilters.prefix(3)) }
        filterControl.removeAllSegments()
        filterControl.insertSegment(withTitle: texts.t("history.filter_all"), at: 0,
                                    animated: false)
        filterControl.insertSegment(withTitle: texts.t("history.outcome_missed"), at: 1,
                                    animated: false)
        for (index, door) in doorFilters.enumerated() {
            filterControl.insertSegment(
                withTitle: CallHistory.doorLabel(config, door, lang: lang), at: index + 2,
                animated: false)
        }
        filterControl.selectedSegmentIndex = 0
        filterControl.accessibilityIdentifier = "history_filter"
        filterControl.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
    }

    /// The list is on screen: load what is there, then move the seen watermark. The rows keep
    /// the unread emphasis they were loaded with, so the user sees which calls were new.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        core.addHandler(logObserverKey) { [weak self] event in
            if ConfigUtil.evStr(event, "t") == "call_log_changed" { self?.reload(reset: true) }
        }
        config = core.config()
        reload(reset: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        core.markCallLogSeen()
        onSeen?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        core.removeHandler(logObserverKey)
    }

    @objc private func closeSelf() { onClose?() }

    @objc private func markAllSeen() {
        core.markCallLogSeen()
        onSeen?()
        reload(reset: true)
    }

    @objc private func filterChanged() {
        let index = filterControl.selectedSegmentIndex
        if index <= 0 {
            filter = "all"
        } else if index == 1 {
            filter = "missed"
        } else {
            filter = "door:" + doorFilters[index - 2]
        }
        reload(reset: true)
    }

    private func loadMore() {
        let oldest = rows.last?.tsMs ?? 0
        let page = CallHistory.page(core, beforeMs: oldest)
            .filter { CallHistory.matches($0, filter: filter) }
        if page.isEmpty {
            reachedEnd = true
        } else {
            rows.append(contentsOf: page)
        }
        render()
    }

    func reload(reset: Bool) {
        guard isViewLoaded else { return }
        if reset {
            rows = []
            reachedEnd = false
        }
        rows = CallHistory.page(core, beforeMs: 0)
            .filter { CallHistory.matches($0, filter: filter) }
        render()
    }

    /// Rows grouped by day in the cluster's zone, newest day first.
    private func render() {
        days = []
        for row in rows {
            let key = DoorbellClock.dayKey(core, wallMs: row.tsMs)
            if days.last?.key != key {
                days.append((key, DoorbellClock.dayTitle(core, texts: texts, dayKey: key,
                                                         lang: lang), []))
            }
            days[days.count - 1].rows.append(row)
        }
        tableView.reloadData()
    }

    private var hasLoadMore: Bool { return !reachedEnd && rows.count >= CallHistory.pageSize }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return max(1, days.count) + (hasLoadMore ? 1 : 0)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section >= days.count { return days.isEmpty && section == 0 ? 0 : 1 }
        return days[section].rows.count
    }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        return section < days.count ? days[section].title : nil
    }

    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        return days.isEmpty && section == 0 ? texts.t("history.empty") : nil
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView,
                            forSection section: Int) {
        SystemStyle.style(headerFooter: view)
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard indexPath.section < days.count else {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            SystemStyle.style(cell)
            cell.textLabel?.text = texts.t("history.load_more")
            cell.textLabel?.textColor = SystemStyle.tint
            cell.accessibilityIdentifier = "history_load_more"
            cell.accessibilityTraits = .button
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "call")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "call")
        CallHistory.configure(cell, core: core, texts: texts, config: config,
                              row: days[indexPath.section].rows[indexPath.row], lang: lang)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.section < days.count else {
            tableView.deselectRow(at: indexPath, animated: true)
            loadMore()
            return
        }
        let row = days[indexPath.section].rows[indexPath.row]
        let detail = CallHistoryDetailController(core: core, texts: texts, lang: lang, row: row)
        if showsDetailInSplit, let split = splitViewController {
            split.showDetailViewController(
                SystemStyle.navigation(detail, largeTitles: false), sender: self)
            if split.isCollapsed { tableView.deselectRow(at: indexPath, animated: true) }
        } else {
            tableView.deselectRow(at: indexPath, animated: true)
            navigationController?.pushViewController(detail, animated: true)
        }
    }
}

/// One call's details as a grouped table. With no call it is the split view's empty state.
final class CallHistoryDetailController: UITableViewController {

    private let core: CoreBridge
    private let texts: Texts
    private let lang: String
    private let row: CallLogRow?
    private var fields: [(title: String, value: String)] = []

    init(core: CoreBridge, texts: Texts, lang: String, row: CallLogRow?) {
        self.core = core
        self.texts = texts
        self.lang = lang
        self.row = row
        super.init(style: SystemStyle.tableStyle())
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        SystemStyle.style(tableView)
        tableView.accessibilityIdentifier = "history_detail"
        tableView.allowsSelection = false
        guard let row = row else { return }
        let config = core.config()
        let day = DoorbellClock.dayTitle(core, texts: texts,
                                         dayKey: DoorbellClock.dayKey(core, wallMs: row.tsMs),
                                         lang: lang)
        let time = DoorbellClock.timeOfDay(core, wallMs: row.tsMs)
        title = time
        let seconds = Int(row.durationMs / 1000)
        let all: [(String, String)] = [
            (texts.t("history.detail_time"), day + " " + time),
            (texts.t("history.detail_door"), CallHistory.doorLabel(config, row.door, lang: lang)),
            (texts.t("history.detail_purpose"),
             CallHistory.purposeLabel(config, row.purpose, lang: lang)),
            (texts.t("history.detail_outcome"), CallHistory.outcomeText(texts, row.outcome)),
            (texts.t("history.detail_answered_by"), row.answeredBy),
            (texts.t("history.detail_duration"),
             row.durationMs > 0 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : ""),
        ]
        fields = all.filter { !$0.1.isEmpty }.map { (title: $0.0, value: $0.1) }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return fields.count
    }

    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        return row == nil ? texts.t("history.detail_empty") : nil
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        SystemStyle.style(cell)
        cell.textLabel?.text = fields[indexPath.row].title
        cell.detailTextLabel?.text = fields[indexPath.row].value
        if fields[indexPath.row].title == texts.t("history.detail_outcome"), let row = row {
            let icon = CallHistory.outcomeIcon(row.outcome)
            cell.imageView?.image = TablerIcon.image(icon.name)
            cell.imageView?.tintColor = icon.color
        }
        return cell
    }
}
