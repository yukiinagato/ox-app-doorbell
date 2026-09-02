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

/// Shared reading and rendering of the call log, so the dashboard's short list and the full-screen
/// history page describe a call the same way.
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

/// Scrollable list of the most recent calls used on the dashboard. It never pages; the full page
/// behind 「すべて見る」 does.
final class RecentCallsView: UIView {

    var onSelect: ((CallLogRow) -> Void)?

    private let core: CoreBridge
    private let texts: Texts
    private let lang: String
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let emptyLabel = UILabel()
    private var palette = DoorbellPalette.dark

    init(core: CoreBridge, texts: Texts, lang: String) {
        self.core = core
        self.texts = texts
        self.lang = lang
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)

        emptyLabel.text = texts.t("history.empty")
        emptyLabel.font = .systemFont(ofSize: 17)
        emptyLabel.numberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func reload(config: [String: Any]?, palette: DoorbellPalette, limit: Int = 20) {
        self.palette = palette
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        let rows = CallHistory.page(core, beforeMs: 0, limit: limit)
        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.textColor = palette.inkMuted
        for row in rows {
            stack.addArrangedSubview(CallHistoryRowView(core: core, texts: texts, config: config,
                                                        row: row, lang: lang, palette: palette))
        }
    }
}

/// A single history entry. It is a control so the same view works with the tvOS focus engine.
final class CallHistoryRowView: UIControl {

    let row: CallLogRow
    private let timeLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let missedBadge = PaddedLabel()

    init(core: CoreBridge, texts: Texts, config: [String: Any]?, row: CallLogRow, lang: String,
         palette: DoorbellPalette) {
        self.row = row
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "history_row_\(row.id)"

        timeLabel.text = DoorbellClock.timeOfDay(core, wallMs: row.tsMs)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        timeLabel.textColor = palette.inkMuted
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.text = CallHistory.title(config: config, row: row, lang: lang)
        titleLabel.font = .systemFont(ofSize: 17, weight: .medium)
        titleLabel.textColor = palette.ink

        subtitleLabel.text = CallHistory.subtitle(texts, config: config, row: row, lang: lang)
        subtitleLabel.font = .systemFont(ofSize: 15)
        subtitleLabel.textColor = palette.inkMuted

        DoorbellTheme.pill(missedBadge, background: palette.danger,
                           ink: DoorbellTheme.readableInk(on: palette.danger), fontSize: 13)
        missedBadge.text = texts.t("history.outcome_missed")
        missedBadge.isHidden = row.outcome != "missed"
        // A pill hugs its text; only the title column takes the leftover width.
        missedBadge.setContentHuggingPriority(.required, for: .horizontal)
        missedBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textColumn = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 1

        let stack = UIStackView(arrangedSubviews: [timeLabel, textColumn, UIView(),
                                                   missedBadge])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    #if os(tvOS)
    override var canBecomeFocused: Bool { return true }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({ [weak self] in
            self?.backgroundColor = focused ? UIColor(white: 1, alpha: 0.16) : .clear
        }, completion: nil)
    }
    #endif
}

/// Full-screen call history: filters, day groups, 50 rows a page and 「さらに読み込む」. Opening it
/// moves the device-local seen watermark, which is what clears the dashboard's missed badge.
final class CallHistoryViewController: UIViewController {

    private let core: CoreBridge
    private let texts: Texts
    private let lang: String
    private var config: [String: Any]?
    private var palette = DoorbellPalette.dark

    private var filter = "all"
    private var rows: [CallLogRow] = []
    private var reachedEnd = false

    private let filterControl = UISegmentedControl(items: [])
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let loadMoreButton = UIButton(type: .system)
    private let emptyLabel = UILabel()
    private var doorFilters: [String] = []

    init(core: CoreBridge, texts: Texts, lang: String) {
        self.core = core
        self.texts = texts
        self.lang = lang
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        config = core.config()
        palette = DoorbellPalette.of(DoorbellTheme.appearance(
            config: config, nodeId: "", localTime: core.localTime()))
        view.backgroundColor = palette.background
        build()
        // Mark-seen on open, as the owner asked; the badge is gone by the time the list appears.
        core.markCallLogSeen()
        reload(reset: true)
    }

    private func build() {
        let title = UILabel()
        title.text = texts.t("history.title")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = palette.ink

        let close = UIButton(type: .system)
        close.setTitle(texts.t("settings.close"), for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        close.setTitleColor(palette.ink, for: .normal)
        close.accessibilityIdentifier = "history_close"
        close.addTarget(self, action: #selector(closeSelf), for: .primaryActionTriggered)

        let markSeen = UIButton(type: .system)
        markSeen.setTitle(texts.t("history.mark_seen"), for: .normal)
        markSeen.titleLabel?.font = .systemFont(ofSize: 18)
        markSeen.setTitleColor(palette.inkMuted, for: .normal)
        markSeen.accessibilityIdentifier = "history_mark_seen"
        markSeen.addTarget(self, action: #selector(markAllSeen), for: .primaryActionTriggered)

        let header = UIStackView(arrangedSubviews: [title, UIView(), markSeen, close])
        header.axis = .horizontal
        header.spacing = 16
        header.alignment = .center

        doorFilters = (ConfigUtil.dig(config, "doors") as? [String: Any])
            .map { ConfigUtil.sortedByOrder($0) } ?? []
        filterControl.removeAllSegments()
        filterControl.insertSegment(withTitle: texts.t("history.filter_all"), at: 0,
                                    animated: false)
        filterControl.insertSegment(withTitle: texts.t("history.filter_missed"), at: 1,
                                    animated: false)
        for (index, door) in doorFilters.enumerated() {
            filterControl.insertSegment(
                withTitle: CallHistory.doorLabel(config, door, lang: lang), at: index + 2,
                animated: false)
        }
        filterControl.selectedSegmentIndex = 0
        filterControl.accessibilityIdentifier = "history_filter"
        filterControl.addTarget(self, action: #selector(filterChanged), for: .valueChanged)

        emptyLabel.text = texts.t("history.empty")
        emptyLabel.font = .systemFont(ofSize: 18)
        emptyLabel.textColor = palette.inkMuted
        emptyLabel.isHidden = true

        loadMoreButton.setTitle(texts.t("history.load_more"), for: .normal)
        loadMoreButton.titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
        loadMoreButton.setTitleColor(palette.ink, for: .normal)
        loadMoreButton.backgroundColor = palette.surface
        loadMoreButton.layer.cornerRadius = 12
        loadMoreButton.accessibilityIdentifier = "history_load_more"
        loadMoreButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        loadMoreButton.addTarget(self, action: #selector(loadMore), for: .primaryActionTriggered)

        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let root = UIStackView(arrangedSubviews: [header, filterControl, emptyLabel, scroll])
        root.axis = .vertical
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: guide.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -18),
            root.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    @objc private func closeSelf() { dismiss(animated: true) }

    @objc private func markAllSeen() {
        core.markCallLogSeen()
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

    @objc private func loadMore() {
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

    private func reload(reset: Bool) {
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
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        emptyLabel.isHidden = !rows.isEmpty
        var currentDay = ""
        for row in rows {
            let day = DoorbellClock.dayKey(core, wallMs: row.tsMs)
            if day != currentDay {
                currentDay = day
                let header = UILabel()
                header.text = DoorbellClock.dayTitle(core, texts: texts, dayKey: day, lang: lang)
                header.font = .systemFont(ofSize: 15, weight: .semibold)
                header.textColor = palette.inkMuted
                stack.addArrangedSubview(header)
            }
            stack.addArrangedSubview(CallHistoryRowView(core: core, texts: texts, config: config,
                                                        row: row, lang: lang, palette: palette))
        }
        loadMoreButton.removeFromSuperview()
        if !reachedEnd && rows.count >= CallHistory.pageSize {
            stack.addArrangedSubview(loadMoreButton)
        }
    }
}
