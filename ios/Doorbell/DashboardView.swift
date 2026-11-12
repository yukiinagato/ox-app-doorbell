import ImageIO
import UIKit

/// Indoor home surface. One job: the doors. A status header (the household clock, who is in the
/// cluster, a notice while missed calls are unread), then one tile per door in a collection view
/// that takes one, two or three columns from the width it has, and the admin QR underneath. The
/// SOS slide is pinned below the scrolling content, in the fixed action zone.
///
/// The household wallpaper is behind this view; the clock and date are drawn straight on it with
/// Core's per-region ink, and everything else sits on the system material. Call history lives in
/// its own tab and is not repeated here.
///
/// The view owns no call state; its host routes every action.
final class DashboardView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    private var lastCounts = ClusterCounts()

    var onOpenHistory: (() -> Void)?
    var onOpenDoor: ((String) -> Void)?
    var onOpenOfflineDoors: (() -> Void)?
    var onOpenNotice: ((String) -> Void)?
    var onOpenPairing: (() -> Void)?
    /// The unread missed-call count, for the History tab's badge.
    var onUnreadMissedChanged: ((Int) -> Void)?
    /// Extra focusable entries shown as a row of cells. tvOS has no bar button items to put the
    /// home actions in, so its host lists them here; iOS leaves this empty.
    var quickActions: [QuickAction] = [] {
        didSet { collection.reloadData() }
    }

    struct QuickAction {
        let title: String
        let icon: String
        let identifier: String
        let handler: () -> Void
    }

    private let core: CoreBridge
    private let boot: BootConfig
    private let texts: Texts

    private let clockLabel = HaloLabel()
    private let dateLabel = HaloLabel()
    private lazy var counters = ClusterCountersView(texts: texts)
    private let missedButton = UIButton(type: .system)
    private let pairingButton = UIButton(type: .system)
    private let offlineDoorButton = UIButton(type: .system)
    private let doorPageButton = UIButton(type: .system)
    private let statusCard = MaterialCardView()
    private let headerView = UIStackView()
    private let footerCard = MaterialCardView()
    private let adminQr: AdminQrView
    let sosControl: UIView

    private let layout = UICollectionViewFlowLayout()
    private(set) lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let root = UIStackView()

    private var config: [String: Any]?
    private var skin = DoorbellSkin.plain(.dark)
    private var tiles: [String: DoorTileView] = [:]
    private var shownDoors: [String] = []
    private var allDoors: [String] = []
    private var previewPriority: [String] = []
    private var previewPage = 0
    private var stillTimer: Timer?
    private var activePreviewRate: Double?
    private var unreadMissed = 0
    private var laidOutWidth: CGFloat = 0

    private enum Section: Int, CaseIterable {
        case header, actions, doors, footer
    }

    init(core: CoreBridge, boot: BootConfig, texts: Texts, sosControl: UIView) {
        self.core = core
        self.boot = boot
        self.texts = texts
        self.adminQr = AdminQrView(core: core, boot: boot, texts: texts, compact: true,
                                   qrSide: 44, showsCaption: false)
        self.sosControl = sosControl
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(previewRateChanged),
                                               name: UserDefaults.didChangeNotification,
                                               object: UserDefaults.standard)
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged),
                                               name: SystemStyle.changed, object: nil)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        stillTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Construction

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        clockLabel.accessibilityIdentifier = "dashboard_clock"
        clockLabel.adjustsFontSizeToFitWidth = true
        clockLabel.minimumScaleFactor = 0.5
        dateLabel.font = SystemStyle.font(.title3, weight: .semibold)
        dateLabel.numberOfLines = 0
        SystemStyle.followContentSize(dateLabel)
        clockLabel.inkCompanion = dateLabel
        dateLabel.inkCompanion = clockLabel

        counters.accessibilityIdentifier = "cluster_counters"

        statusRow(missedButton, icon: "TablerBell", identifier: "missed_badge",
                  action: #selector(openHistory))
        missedButton.isHidden = true
        statusRow(offlineDoorButton, icon: "TablerVideoOff", identifier: "dashboard_offline_doors",
                  action: #selector(openOfflineDoors))
        offlineDoorButton.isHidden = true
        statusRow(doorPageButton, icon: "TablerDoor", identifier: "dashboard_door_page",
                  action: #selector(nextDoorPage))
        doorPageButton.isHidden = true

        statusRow(pairingButton, icon: "TablerAlertTriangle", identifier: "pairing_banner",
                  action: #selector(openPairing))
        pairingButton.isHidden = true

        let statusStack = UIStackView(arrangedSubviews: [pairingButton, counters, missedButton,
                                                         offlineDoorButton, doorPageButton])
        statusStack.axis = .vertical
        statusStack.spacing = 0
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusCard.contentView.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.topAnchor.constraint(equalTo: statusCard.contentView.topAnchor),
            statusStack.bottomAnchor.constraint(equalTo: statusCard.contentView.bottomAnchor),
            statusStack.leadingAnchor.constraint(equalTo: statusCard.contentView.leadingAnchor),
            statusStack.trailingAnchor.constraint(equalTo: statusCard.contentView.trailingAnchor),
            counters.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchTarget.minimum),
        ])

        headerView.axis = .vertical
        headerView.spacing = Space.xxs
        headerView.addArrangedSubview(clockLabel)
        headerView.addArrangedSubview(dateLabel)
        headerView.addArrangedSubview(statusCard)
        IOSAvailability.setCustomSpacing(Space.s, after: dateLabel, in: headerView)

        footerCard.contentView.addSubview(adminQr)
        NSLayoutConstraint.activate([
            adminQr.topAnchor.constraint(equalTo: footerCard.contentView.topAnchor,
                                         constant: Space.xs),
            adminQr.bottomAnchor.constraint(equalTo: footerCard.contentView.bottomAnchor,
                                            constant: -Space.xs),
            adminQr.leadingAnchor.constraint(equalTo: footerCard.contentView.leadingAnchor,
                                             constant: Space.s),
            adminQr.trailingAnchor.constraint(equalTo: footerCard.contentView.trailingAnchor,
                                              constant: -Space.s),
        ])

        layout.minimumInteritemSpacing = Space.s
        layout.minimumLineSpacing = Space.s
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.alwaysBounceVertical = true
        collection.accessibilityIdentifier = "dashboard_tiles"
        collection.register(HostCell.self, forCellWithReuseIdentifier: HostCell.reuse)
        collection.register(QuickActionCell.self, forCellWithReuseIdentifier: QuickActionCell.reuse)
        #if os(tvOS)
        collection.clipsToBounds = false
        collection.remembersLastFocusedIndexPath = true
        #endif

        // The SOS trigger sits at the leading edge of the fixed action zone, below the scrolling
        // content: compact, outlined, and gone entirely where SOS is not offered.
        sosControl.setContentCompressionResistancePriority(.required, for: .vertical)
        root.axis = .vertical
        root.spacing = Space.s
        root.alignment = .leading
        root.addArrangedSubview(collection)
        root.addArrangedSubview(sosControl)
        collection.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applyClockFont(for: bounds.size)
        startStillTimer()
    }

    /// One tappable line of the status card: an icon, a sentence and a chevron, like a table row.
    private func statusRow(_ button: UIButton, icon: String, identifier: String,
                           action: Selector) {
        button.setImage(TablerIcon.image(icon), for: .normal)
        button.titleLabel?.font = SystemStyle.font(.body)
        button.titleLabel?.numberOfLines = 0
        SystemStyle.followContentSize(button.titleLabel)
        button.contentHorizontalAlignment = .left
        #if !os(tvOS)
        button.contentEdgeInsets = UIEdgeInsets(top: Space.xs, left: Space.m, bottom: Space.xs,
                                                right: Space.m)
        button.titleEdgeInsets = UIEdgeInsets(top: 0, left: Space.xs, bottom: 0, right: -Space.xs)
        #endif
        button.accessibilityIdentifier = identifier
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchTarget.minimum)
            .isActive = true
        button.addTarget(self, action: action, for: .primaryActionTriggered)
    }

    // MARK: - Layout

    /// The grid is chosen from the size the view is about to have, never from the device model:
    /// one column when compact, two when medium, three when expanded.
    func applyLayout(for size: CGSize) {
        applyClockFont(for: size)
        layout.invalidateLayout()
    }

    private func applyClockFont(for size: CGSize) {
        let compact = LayoutClass.of(width: size.width) == .compact || size.height < 500
        clockLabel.font = SystemStyle.digits(size: compact ? 52 : 72, traits: traitCollection)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - laidOutWidth) > 0.5 {
            laidOutWidth = bounds.width
            applyLayout(for: bounds.size)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyLayout(for: bounds.size)
    }

    static func columnCount(forWidth width: CGFloat) -> Int {
        return LayoutClass.of(width: width).columns(maximum: 3)
    }

    private var contentWidth: CGFloat {
        return max(1, collection.bounds.width - layout.sectionInset.left - layout.sectionInset.right)
    }

    static func tileSize(contentWidth: CGFloat, columns: Int, spacing: CGFloat) -> CGSize {
        let count = CGFloat(max(1, columns))
        let width = floor((contentWidth - spacing * (count - 1)) / count)
        // A door camera is 16:9; the tile keeps that shape between a height a finger can hit and
        // one that still leaves the second row on screen.
        return CGSize(width: width, height: min(360, max(160, (width * 9 / 16).rounded())))
    }

    // MARK: - Collection view

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return Section.allCases.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .header?, .footer?: return 1
        case .actions?: return quickActions.count
        case .doors?: return shownDoors.count
        case nil: return 0
        }
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if Section(rawValue: indexPath.section) == .actions {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: QuickActionCell.reuse, for: indexPath) as! QuickActionCell
            cell.apply(quickActions[indexPath.item])
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: HostCell.reuse,
                                                      for: indexPath) as! HostCell
        switch Section(rawValue: indexPath.section) {
        case .header?:
            cell.host(headerView)
            cell.isAccessibilityElement = false
        case .footer?:
            cell.host(footerCard)
        case .doors?:
            let door = shownDoors[indexPath.item]
            if let tile = tiles[door] { cell.host(tile) }
            cell.accessibilityIdentifier = "door_tile_\(door)"
        default:
            break
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = contentWidth
        switch Section(rawValue: indexPath.section) {
        case .doors?:
            // Fewer doors than columns: the tiles share the whole row instead of leaving it empty.
            let columns = min(DashboardView.columnCount(forWidth: width), max(1, shownDoors.count))
            return DashboardView.tileSize(contentWidth: width, columns: columns,
                                          spacing: layout.minimumInteritemSpacing)
        case .actions?:
            let count = CGFloat(max(1, quickActions.count))
            return CGSize(width: floor((width - layout.minimumInteritemSpacing * (count - 1))
                                        / count), height: 120)
        case .header?:
            return CGSize(width: width, height: fittingHeight(headerView, width: width))
        default:
            return CGSize(width: width, height: fittingHeight(footerCard, width: width))
        }
    }

    private func fittingHeight(_ view: UIView, width: CGFloat) -> CGFloat {
        let size = view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return ceil(max(1, size.height))
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        insetForSectionAt section: Int) -> UIEdgeInsets {
        let empty = self.collectionView(collectionView, numberOfItemsInSection: section) == 0
        return UIEdgeInsets(top: 0, left: 0, bottom: empty ? 0 : Space.m, right: 0)
    }

    func collectionView(_ collectionView: UICollectionView,
                        shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        let section = Section(rawValue: indexPath.section)
        return section == .doors || section == .actions
    }

    func collectionView(_ collectionView: UICollectionView,
                        canFocusItemAt indexPath: IndexPath) -> Bool {
        let section = Section(rawValue: indexPath.section)
        return section == .doors || section == .actions
    }

    func collectionView(_ collectionView: UICollectionView,
                        didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        switch Section(rawValue: indexPath.section) {
        case .doors?:
            guard indexPath.item < shownDoors.count else { return }
            onOpenDoor?(shownDoors[indexPath.item])
        case .actions?:
            guard indexPath.item < quickActions.count else { return }
            quickActions[indexPath.item].handler()
        default:
            break
        }
    }

    // MARK: - Content

    /// `skin` carries the household's theme background, which this panel wears, and the ink for
    /// the text drawn straight on it. One reload, one status snapshot.
    func reload(config: [String: Any]?, skin: DoorbellSkin) {
        IOSAvailability.PerfProbe.measure("dashboard.reload") {
            reloadBody(config: config, skin: skin)
        }
    }

    private func reloadBody(config: [String: Any]?, skin: DoorbellSkin) {
        self.config = config
        self.skin = skin
        let status = core.status()
        let nowMs = DoorbellClock.nowMs(core)
        lastCounts = ClusterCounts.from(status: status, selfRole: boot.role)
        applySkin()
        rebuildTiles(status: status, nowMs: nowMs)
        adminQr.reload(status: status)
        refreshMissedBadge()
        refreshVersionLine(status: status)
        refreshStills(status: status)
    }

    /// The clock and the date sit straight on the theme background, so their colours come from
    /// Core's per-region automatic ink. Everything else is on the system material and takes the
    /// system label colours.
    private func applySkin() {
        skin.apply("clock", to: clockLabel)
        skin.apply("date", to: dateLabel)
        counters.update(lastCounts, ink: SystemStyle.label, surface: .clear)
        missedButton.tintColor = SystemStyle.negative
        pairingButton.tintColor = SystemStyle.warning
        offlineDoorButton.tintColor = SystemStyle.label
        doorPageButton.tintColor = SystemStyle.label
        statusCard.showsMaterial = skin.decorated
        footerCard.showsMaterial = skin.decorated
        statusCard.refresh()
        footerCard.refresh()
        adminQr.refreshColors()
    }

    @objc private func styleChanged() {
        applySkin()
        collection.reloadData()
    }

    /// The reading is handed in by the screen that owns the clock. Asking Core for a second one
    /// meant two synchronous Core calls per tick on the main thread.
    func updateClock(_ reading: DoorbellClock.Reading) {
        let first = (clockLabel.text ?? "").isEmpty
        clockLabel.text = reading.hhmmss
        let date = DoorbellClock.longDate(reading, lang: boot.uiLang)
        if dateLabel.text != date {
            dateLabel.text = date
            invalidateHeader()
        } else if first {
            // The header was measured before the first reading arrived.
            invalidateHeader()
        }
    }

    /// While missed calls are unread, one row says so and leads to the History tab; the count
    /// itself is the tab's badge.
    func refreshMissedBadge() {
        let unread = CallHistory.unreadMissed(core)
        let hidden = unread <= 0
        let title = texts.t("history.missed_badge", "\(unread)")
        var changed = false
        if missedButton.isHidden != hidden { missedButton.isHidden = hidden; changed = true }
        if missedButton.title(for: .normal) != title {
            missedButton.setTitle(title, for: .normal)
            changed = true
        }
        if unread != unreadMissed {
            unreadMissed = unread
            onUnreadMissedChanged?(unread)
        }
        if changed { invalidateHeader() }
    }

    /// While this device is not in a cluster, one row says so and leads to pairing. Nil hides it.
    func setPairingNotice(_ text: String?) {
        let hidden = text == nil
        guard pairingButton.isHidden != hidden || pairingButton.title(for: .normal) != text
        else { return }
        pairingButton.isHidden = hidden
        pairingButton.setTitle(text, for: .normal)
        invalidateHeader()
    }

    func refreshHistory() {
        refreshMissedBadge()
    }

    private func invalidateHeader() {
        layout.invalidateLayout()
    }

    static let previewRates: [Double] = [0.5, 1, 2, 4]
    static let previewRateDefaultsKey = "dashboard.preview_fps"
    static let defaultPreviewFramesPerSecond = 2.0

    static func previewRateValue(_ rate: Double) -> String {
        rate.rounded() == rate ? String(Int(rate)) : String(rate)
    }

    static func previewInterval(for framesPerSecond: Double) -> TimeInterval {
        1 / framesPerSecond
    }

    static var savedPreviewFramesPerSecond: Double {
        let saved = UserDefaults.standard.double(forKey: previewRateDefaultsKey)
        return Self.previewRates.contains(saved) ? saved : Self.defaultPreviewFramesPerSecond
    }

    private func startStillTimer() {
        stillTimer?.invalidate()
        let rate = Self.savedPreviewFramesPerSecond
        activePreviewRate = rate
        stillTimer = IOSAvailability.scheduledTimer(
            withTimeInterval: Self.previewInterval(for: rate), repeats: true
        ) { [weak self] _ in self?.refreshStills() }
    }

    @objc private func previewRateChanged() {
        guard activePreviewRate != Self.savedPreviewFramesPerSecond else { return }
        startStillTimer()
        refreshStills()
    }

    private func refreshVersionLine(status: [String: Any]? = nil) {
        let snapshot = status ?? core.status()
        let power = (snapshot?["self"] as? [String: Any])?["power"] as? [String: Any]
        adminQr.setDetailText(DoorbellTheme.versionLine(name: boot.name,
                                                        coreVersion: DoorbellTheme.coreVersion(),
                                                        texts: texts, power: power))
    }

    func refreshNoticeState() {
        let nowMs = DoorbellClock.nowMs(core)
        let status = core.status()
        for (door, tile) in tiles {
            let notice = DoorbellNotice.effective(status: status, config: config, door: door,
                                                  nowMs: nowMs)
            tile.updateNotice(active: notice != nil)
        }
    }

    func prioritizeDoor(_ door: String) {
        guard !door.isEmpty, allDoors.contains(door) else { return }
        previewPriority.removeAll { $0 == door }
        previewPriority.insert(door, at: 0)
        if previewPriority.count > Self.previewCapacity {
            previewPriority.removeLast(previewPriority.count - Self.previewCapacity)
        }
        previewPage = 0
        let status = core.status()
        rebuildTiles(status: status, nowMs: DoorbellClock.nowMs(core))
        refreshStills(status: status)
    }

    // MARK: - Door tiles

    private func rebuildTiles(status: [String: Any]?, nowMs: Int64) {
        // A door station with no camera has nothing for a tile to show. It stays reachable from
        // the monitor page's device list and still delivers its notices.
        allDoors = ConfigUtil.doorsWithCamera(config: config, status: status)
        let doors = selectedDoors()
        var headerChanged = false
        let paged = allDoors.count > Self.previewCapacity
        if doorPageButton.isHidden == paged { doorPageButton.isHidden = !paged; headerChanged = true }
        if paged {
            doorPageButton.setTitle(
                "\(texts.t("settings.doors")) · \(doors.count)/\(allDoors.count)", for: .normal)
        }
        let offlinePeers = ConfigUtil.offlineDoorPeers(config: config, status: status)
        if offlineDoorButton.isHidden != offlinePeers.isEmpty {
            offlineDoorButton.isHidden = offlinePeers.isEmpty
            headerChanged = true
        }
        if !offlinePeers.isEmpty {
            offlineDoorButton.setTitle(
                "\(texts.t("dashboard.offline_doors")) · \(offlinePeers.count)", for: .normal)
        }
        if doors != shownDoors {
            for door in doors where tiles[door] == nil {
                let tile = DoorTileView(texts: texts)
                tile.door = door
                tile.onNotice = { [weak self] in self?.onOpenNotice?(door) }
                tiles[door] = tile
            }
            for door in Array(tiles.keys) where !doors.contains(door) { tiles[door] = nil }
            shownDoors = doors
            collection.reloadData()
        } else if headerChanged {
            invalidateHeader()
        }
        for door in doors {
            guard let tile = tiles[door] else { continue }
            let entry = ConfigUtil.dig(config, "doors.\(door)") as? [String: Any]
            let peer = ConfigUtil.onlineDoorPeer(status, door: door)
            let notice = DoorbellNotice.effective(status: status, config: config, door: door,
                                                  nowMs: nowMs)
            tile.apply(label: ConfigUtil.labelOf(entry, boot.uiLang, door),
                       online: peer != nil, noticeActive: notice != nil)
        }
    }

    /// At most this many doors are sampled at once; more are paged through from the status card.
    private static let previewCapacity = 4

    /// The rows a two-column grid arranges a set of doors in.
    static func previewRows(for doors: [String]) -> [[String]] {
        switch doors.count {
        case 0: return []
        case 1: return [doors]
        case 2: return [doors]
        case 3: return [Array(doors.prefix(2)), [doors[2]]]
        default:
            return stride(from: 0, to: doors.count, by: 2).map {
                Array(doors[$0..<min($0 + 2, doors.count)])
            }
        }
    }

    private func selectedDoors() -> [String] {
        guard allDoors.count > Self.previewCapacity else { return allDoors }
        var selected = previewPriority.filter { allDoors.contains($0) }
        let start = (previewPage * Self.previewCapacity) % allDoors.count
        for offset in 0..<allDoors.count where selected.count < Self.previewCapacity {
            let door = allDoors[(start + offset) % allDoors.count]
            if !selected.contains(door) { selected.append(door) }
        }
        return selected
    }

    /// Sampled stills from the door station's own snapshot endpoint. An
    /// unreachable door greys out instead of freezing on a stale frame.
    private func refreshStills(status: [String: Any]? = nil) {
        IOSAvailability.PerfProbe.measure("dashboard.stills") {
            refreshStillsBody(status: status)
        }
    }

    private func refreshStillsBody(status: [String: Any]?) {
        guard window != nil, !tiles.isEmpty else { return }
        let snapshot = status ?? core.status()
        for (door, tile) in tiles {
            guard let peer = ConfigUtil.onlineDoorPeer(snapshot, door: door),
                  let url = snapshotUrl(peer: peer) else {
                tile.setStill(nil)
                continue
            }
            tile.loadStill(from: url, videoMetaUrl: videoMetaUrl(peer: peer))
        }
    }

    /// Core publishes peer media as loopback proxy URLs (security protocol v3 section 8); the
    /// still is the stream's sibling. A peer is never fetched directly, so there is no host
    /// fallback.
    private func snapshotUrl(peer: [String: Any]) -> URL? {
        guard let stream = ConfigUtil.str(peer, "stream"), let url = URL(string: stream) else {
            return nil
        }
        return LocalMediaAuth.sibling(url, "snapshot.jpg")
    }

    private func videoMetaUrl(peer: [String: Any]) -> URL? {
        if let value = ConfigUtil.str(peer, "video_meta"), let url = URL(string: value) {
            return url
        }
        guard let stream = ConfigUtil.str(peer, "stream"), let url = URL(string: stream) else {
            return nil
        }
        return LocalMediaAuth.sibling(url, "video-meta")
    }

    // MARK: - Actions

    @objc private func openHistory() { onOpenHistory?() }

    @objc private func openPairing() { onOpenPairing?() }

    @objc private func nextDoorPage() {
        guard allDoors.count > Self.previewCapacity else { return }
        previewPriority.removeAll()
        let pages = (allDoors.count + Self.previewCapacity - 1) / Self.previewCapacity
        previewPage = (previewPage + 1) % pages
        let status = core.status()
        rebuildTiles(status: status, nowMs: DoorbellClock.nowMs(core))
        refreshStills(status: status)
    }

    @objc private func openOfflineDoors() { onOpenOfflineDoors?() }
}

/// A collection cell that shows one view the dashboard keeps alive across reloads.
private final class HostCell: UICollectionViewCell {
    static let reuse = "host"
    private weak var hosted: UIView?

    func host(_ view: UIView) {
        accessibilityIdentifier = nil
        guard hosted !== view || view.superview !== contentView else { return }
        if let old = hosted, old.superview === contentView { old.removeFromSuperview() }
        hosted = view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let old = hosted, old.superview === contentView { old.removeFromSuperview() }
        hosted = nil
    }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.7 : 1 }
    }

    #if os(tvOS)
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        (hosted as? DoorTileView)?.setFocused(isFocused, coordinator: coordinator)
    }
    #endif
}

/// One home action as a focusable card: an icon over its title.
private final class QuickActionCell: UICollectionViewCell {
    static let reuse = "action"
    private let card = MaterialCardView()
    private let icon = UIImageView()
    private let title = SystemStyle.label(.headline, lines: 2)

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .scaleAspectFit
        icon.tintColor = SystemStyle.label
        title.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [icon, title])
        stack.axis = .vertical
        stack.spacing = Space.xs
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        contentView.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: card.contentView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor,
                                           constant: Space.xs),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor,
                                            constant: -Space.xs),
            icon.heightAnchor.constraint(equalToConstant: 36),
            icon.widthAnchor.constraint(equalToConstant: 36),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func apply(_ action: DashboardView.QuickAction) {
        icon.image = TablerIcon.image(action.icon)
        title.text = action.title
        accessibilityLabel = action.title
        accessibilityIdentifier = action.identifier
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations({ [weak self] in
            guard let self = self else { return }
            self.transform = self.isFocused ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
        }, completion: nil)
    }
}

/// The door stations that are not answering, as a plain list pushed from the home screen.
final class OfflineDoorStationsViewController: UITableViewController {
    private let core: CoreBridge
    private let config: [String: Any]?
    private let texts: Texts
    private var rows: [(title: String, detail: String)] = []

    init(core: CoreBridge, config: [String: Any]?, texts: Texts) {
        self.core = core
        self.config = config
        self.texts = texts
        super.init(style: SystemStyle.tableStyle())
        title = texts.t("dashboard.offline_doors_title")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        SystemStyle.style(tableView)
        tableView.accessibilityIdentifier = "offline_doors"
        tableView.allowsSelection = false
        let peers = ConfigUtil.offlineDoorPeers(config: config, status: core.status())
        rows = peers.map { peer in
            let door = ConfigUtil.evStr(peer, "door")
            let entry = ConfigUtil.dig(config, "doors.\(door)") as? [String: Any]
            let label = ConfigUtil.labelOf(entry, texts.lang, door)
            let name = ConfigUtil.evStr(peer, "name")
            let state = ConfigUtil.evStr(peer, "status") == "missing"
                ? texts.t("dashboard.device_status_missing")
                : texts.t("dashboard.device_status_offline")
            return (name.isEmpty ? (label.isEmpty ? door : label) : name,
                    [label, state].filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        return rows.isEmpty ? texts.t("dashboard.offline_doors_empty") : nil
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        SystemStyle.style(cell)
        cell.textLabel?.text = rows[indexPath.row].title
        cell.detailTextLabel?.text = rows[indexPath.row].detail
        cell.imageView?.image = TablerIcon.image("TablerVideoOff")
        cell.imageView?.tintColor = SystemStyle.secondaryLabel
        return cell
    }
}

/// One door: its most recent still, its name, whether it is reachable, and whether an
/// announcement is showing there.
final class DoorTileView: UIView {

    /// One session for every tile. Tiles are rebuilt whenever the door set changes; a session per
    /// tile was never invalidated and accumulated for the life of the process.
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        return URLSession(configuration: configuration)
    }()

    var door = ""
    var onNotice: (() -> Void)?

    private let still = UIImageView()
    private let nameLabel = UILabel()
    private let stateLabel = UILabel()
    private let noticeChip: NoticeChipView
    private let captionBackground = UIView()
    private let captionGradient = CAGradientLayer()
    private var pendingUrl: URL?
    private var videoMetaUrl: URL?
    private var videoRotation = 0
    private var lastRotationRefresh: TimeInterval = 0
    private var rotationRequestActive = false
    /// Identifies the rotation request in flight, so a reply to a superseded one cannot clear the
    /// flag that belongs to its replacement.
    private var rotationRequestSerial = 0
    private var stillRequestActive = false
    private var pendingStillRefresh: (url: URL, rotation: Int)?
    /// The last frame actually painted, so an unchanged scene costs nothing.
    private var lastStillData: Data?
    private var session: URLSession { return DoorTileView.sharedSession }
    private let texts: Texts

    init(texts: Texts) {
        self.texts = texts
        self.noticeChip = NoticeChipView(texts: texts)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "door_tile"
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        backgroundColor = UIColor(white: 0.12, alpha: 1)
        layer.cornerRadius = 12
        if #available(iOS 13.0, tvOS 13.0, *) { layer.cornerCurve = .continuous }
        clipsToBounds = true

        still.contentMode = .scaleAspectFill
        still.clipsToBounds = true
        still.translatesAutoresizingMaskIntoConstraints = false
        addSubview(still)

        nameLabel.font = SystemStyle.font(.headline)
        stateLabel.font = SystemStyle.font(.subheadline)
        SystemStyle.followContentSize(nameLabel)
        SystemStyle.followContentSize(stateLabel)
        nameLabel.textColor = .white
        stateLabel.textColor = .white
        nameLabel.numberOfLines = 0
        nameLabel.lineBreakMode = .byCharWrapping
        nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        noticeChip.onTap = { [weak self] in self?.onNotice?() }

        noticeChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        let captionRow = UIStackView(arrangedSubviews: [nameLabel, stateLabel, UIView(),
                                                        noticeChip])
        captionRow.axis = .horizontal
        captionRow.spacing = 6
        captionRow.alignment = .center
        captionBackground.translatesAutoresizingMaskIntoConstraints = false
        captionBackground.isUserInteractionEnabled = false
        captionGradient.colors = [
            UIColor(white: 0, alpha: 0).cgColor,
            UIColor(white: 0, alpha: 0.88).cgColor,
        ]
        captionGradient.locations = [0, 1]
        captionBackground.layer.addSublayer(captionGradient)
        addSubview(captionBackground)
        captionRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(captionRow)

        NSLayoutConstraint.activate([
            still.topAnchor.constraint(equalTo: topAnchor),
            still.bottomAnchor.constraint(equalTo: bottomAnchor),
            still.leadingAnchor.constraint(equalTo: leadingAnchor),
            still.trailingAnchor.constraint(equalTo: trailingAnchor),
            captionBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            captionBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            captionBackground.topAnchor.constraint(equalTo: captionRow.topAnchor, constant: -8),
            captionBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            captionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            captionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            captionRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            captionRow.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        captionGradient.frame = captionBackground.bounds
    }

    #if os(tvOS)
    /// The system focus look for a card: lifted, slightly larger, with a shadow.
    func setFocused(_ focused: Bool, coordinator: UIFocusAnimationCoordinator) {
        coordinator.addCoordinatedAnimations({ [weak self] in
            guard let self = self else { return }
            self.transform = focused ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
            self.layer.borderWidth = focused ? 4 : 0
            self.layer.borderColor = UIColor.white.cgColor
        }, completion: nil)
    }
    #endif

    /// The name sits over the live image, so its ink and gradient remain legible independently of
    /// the household theme or the colours in the camera frame.
    func apply(label: String, online: Bool, noticeActive: Bool) {
        if nameLabel.text != label { nameLabel.text = label }
        accessibilityLabel = label
        accessibilityHint = texts.t("door.view")
        let state = online ? "" : texts.t("admin.offline")
        if stateLabel.text != state { stateLabel.text = state }
        stateLabel.isHidden = state.isEmpty
        accessibilityValue = state
        let alpha: CGFloat = online ? 1 : 0.35
        if still.alpha != alpha { still.alpha = alpha }
        noticeChip.update(active: noticeActive, overPicture: true)
    }

    func updateNotice(active: Bool) {
        noticeChip.update(active: active, overPicture: true)
    }

    func setStill(_ image: UIImage?) {
        pendingUrl = nil
        pendingStillRefresh = nil
        lastStillData = nil
        still.image = image
    }

    func loadStill(from url: URL, videoMetaUrl: URL?) {
        pendingUrl = url
        if self.videoMetaUrl != videoMetaUrl {
            self.videoMetaUrl = videoMetaUrl
            videoRotation = 0
            lastRotationRefresh = 0
            lastStillData = nil
            rotationRequestActive = false
            rotationRequestSerial &+= 1
        }
        if let videoMetaUrl = videoMetaUrl,
           lastRotationRefresh == 0 || Date.timeIntervalSinceReferenceDate - lastRotationRefresh >= 60 {
            guard !rotationRequestActive else { return }
            rotationRequestActive = true
            rotationRequestSerial &+= 1
            let serial = rotationRequestSerial
            session.dataTask(with: LocalMediaAuth.request(videoMetaUrl, timeout: 4)) {
                [weak self] data, response, _ in
                let rotation: Int? = {
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          let data = data,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { return nil }
                    return object["rotation"] as? Int
                }()
                DispatchQueue.main.async {
                    guard let self = self, self.rotationRequestSerial == serial else { return }
                    self.rotationRequestActive = false
                    guard self.videoMetaUrl == videoMetaUrl,
                          self.pendingUrl == url else { return }
                    self.lastRotationRefresh = Date.timeIntervalSinceReferenceDate
                    self.videoRotation = rotation.map(Self.normalizedRotation) ?? 0
                    self.lastStillData = nil
                    self.fetchStill(from: url, rotation: self.videoRotation)
                }
            }.resume()
            return
        }
        fetchStill(from: url, rotation: videoRotation)
    }

    private func fetchStill(from url: URL, rotation: Int) {
        guard !stillRequestActive else {
            pendingStillRefresh = (url, rotation)
            return
        }
        stillRequestActive = true
        let fittingSize = still.bounds.size
        session.dataTask(with: LocalMediaAuth.request(url, timeout: 4)) { [weak self] data, _, _ in
            let bytes = data.flatMap { $0.isEmpty ? nil : $0 }
            let image = bytes.flatMap {
                DoorTileView.thumbnail(from: $0, fitting: fittingSize, rotation: rotation)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.stillRequestActive = false
                if self.pendingUrl == url, let bytes = bytes, let image = image,
                   bytes != self.lastStillData {
                    self.lastStillData = bytes
                    self.still.image = image
                }
                if let next = self.pendingStillRefresh {
                    self.pendingStillRefresh = nil
                    guard self.pendingUrl == next.url else { return }
                    self.fetchStill(from: next.url, rotation: next.rotation)
                }
            }
        }.resume()
    }

    /// Decodes straight to the size the tile draws at. `UIImage(data:)` only records the bytes and
    /// leaves the real work — a full-resolution JPEG decode and downscale — to the main thread at
    /// commit time, which is exactly the periodic hitch this page had.
    static func normalizedRotation(_ degrees: Int) -> Int {
        let normalized = ((degrees % 360) + 360) % 360
        return [0, 90, 180, 270].contains(normalized) ? normalized : 0
    }

    private static func thumbnail(from data: Data, fitting size: CGSize,
                                  rotation: Int) -> UIImage? {
        let side = max(size.width, size.height)
        let pixels = Int((side > 0 ? side : 132) * IOSAvailability.screenScale())
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, pixels),
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return rotated(UIImage(cgImage: thumb), clockwiseDegrees: rotation)
    }

    private static func rotated(_ image: UIImage, clockwiseDegrees: Int) -> UIImage {
        let degrees = normalizedRotation(clockwiseDegrees)
        guard degrees != 0, image.size.width > 0, image.size.height > 0 else { return image }
        let swapsDimensions = degrees == 90 || degrees == 270
        let outputSize = swapsDimensions
            ? CGSize(width: image.size.height, height: image.size.width) : image.size
        UIGraphicsBeginImageContextWithOptions(outputSize, false, image.scale)
        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return image
        }
        context.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
        context.rotate(by: CGFloat(degrees) * .pi / 180)
        image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2,
                              width: image.size.width, height: image.size.height))
        let output = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return output ?? image
    }
}
