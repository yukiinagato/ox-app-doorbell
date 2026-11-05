import ImageIO
import UIKit

/// Indoor home screen. Everything the household needs at a glance: the household clock, who is
/// in the cluster, unanswered calls, one tile per door with a recent still, a history shortcut,
/// the admin QR that is always visible, and the SOS slider.
///
/// The view owns no call state; `MainViewController` hosts it and routes every action.
final class DashboardView: UIView {

    private var lastCounts = ClusterCounts()

    var onOpenAdmin: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onOpenDoor: ((String) -> Void)?
    var onOpenOfflineDoors: (() -> Void)?
    var onOpenNotice: ((String) -> Void)?

    private let core: CoreBridge
    private let boot: BootConfig
    private let texts: Texts

    private let clockLabel = HaloLabel()
    private let dateLabel = HaloLabel()
    /// Three counts with a drawn mark each, in place of the old one-line membership pill.
    private lazy var counters = ClusterCountersView(texts: texts)
    private let missedBadge = PaddedLabel()
    private let adminButton = UIButton(type: .system)
    private let noticeButton = UIButton(type: .system)
    private let doorPageButton = UIButton(type: .system)
    private let offlineDoorButton = UIButton(type: .system)
    private let historyHeader = HaloLabel()
    private let seeAllButton = UIButton(type: .system)
    private let tilesStack = UIStackView()
    private let adminQr: AdminQrView
    private let footerEffect = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    let sosControl: SosSlideControl

    private let columns = UIStackView()
    private let leftColumn = UIStackView()
    private let rightColumn = UIStackView()
    private let dashboardHeader = UIStackView()
    private let headerControls = UIStackView()
    private let leftHeader = UIStackView()
    private let rightHeader = UIView()

    private var config: [String: Any]?
    private var skin = DoorbellSkin.plain(.dark)
    private var tiles: [String: DoorTileView] = [:]
    private var allDoors: [String] = []
    private var previewPriority: [String] = []
    private var previewPage = 0
    private var stillTimer: Timer?
    private var activePreviewRate: Double?

    init(core: CoreBridge, boot: BootConfig, texts: Texts, sosControl: SosSlideControl) {
        self.core = core
        self.boot = boot
        self.texts = texts
        self.adminQr = AdminQrView(core: core, boot: boot, texts: texts, compact: true,
                                   qrSide: 36, showsCaption: false)
        self.sosControl = sosControl
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(previewRateChanged),
                                               name: UserDefaults.didChangeNotification,
                                               object: UserDefaults.standard)
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

        clockLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 64, weight: .light)
        clockLabel.accessibilityIdentifier = "dashboard_clock"
        dateLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        dateLabel.textColor = .white
        dateLabel.outlineColor = UIColor.black.withAlphaComponent(0.9)

        DoorbellTheme.pill(missedBadge, background: skin.palette.danger,
                           ink: DoorbellTheme.readableInk(on: skin.palette.danger),
                           fontSize: 15)
        counters.accessibilityIdentifier = "cluster_counters"
        DoorbellTheme.pill(missedBadge, background: skin.palette.danger, ink: .white, fontSize: 15)
        missedBadge.accessibilityIdentifier = "missed_badge"
        missedBadge.isHidden = true
        missedBadge.isUserInteractionEnabled = true
        missedBadge.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(openHistory)))

        style(adminButton, title: texts.t("admin.title"), filled: false)
        adminButton.accessibilityIdentifier = "dashboard_admin"
        adminButton.addTarget(self, action: #selector(openAdmin), for: .primaryActionTriggered)

        style(noticeButton, title: texts.t("notice.global_button"), filled: false)
        noticeButton.accessibilityIdentifier = "dashboard_notice_global"
        noticeButton.addTarget(self, action: #selector(openGlobalNotice),
                               for: .primaryActionTriggered)

        let clockColumn = UIStackView(arrangedSubviews: [clockLabel, dateLabel])
        clockColumn.axis = .vertical
        clockColumn.spacing = 2

        let statusRow = UIStackView(arrangedSubviews: [counters, missedBadge, UIView(), adminButton])
        statusRow.axis = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .center

        leftHeader.axis = .vertical
        leftHeader.addArrangedSubview(clockColumn)

        tilesStack.axis = .vertical
        tilesStack.spacing = 12
        tilesStack.distribution = .equalSpacing
        tilesStack.setContentHuggingPriority(.required, for: .vertical)

        style(doorPageButton, title: "", filled: false)
        doorPageButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        doorPageButton.contentHorizontalAlignment = .left
        doorPageButton.addTarget(self, action: #selector(nextDoorPage),
                                 for: .primaryActionTriggered)
        doorPageButton.isHidden = true

        style(offlineDoorButton, title: "", filled: false)
        offlineDoorButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        offlineDoorButton.contentHorizontalAlignment = .left
        offlineDoorButton.accessibilityIdentifier = "dashboard_offline_doors"
        offlineDoorButton.addTarget(self, action: #selector(openOfflineDoors),
                                    for: .primaryActionTriggered)
        offlineDoorButton.isHidden = true

        historyHeader.text = texts.t("history.title")
        historyHeader.font = .systemFont(ofSize: 19, weight: .semibold)
        style(seeAllButton, title: texts.t("history.see_all"), filled: false)
        seeAllButton.accessibilityIdentifier = "dashboard_see_all"
        seeAllButton.addTarget(self, action: #selector(openHistory), for: .primaryActionTriggered)
        let historyRow = UIStackView(arrangedSubviews: [historyHeader, UIView(), seeAllButton])
        historyRow.axis = .horizontal
        historyRow.spacing = 12
        historyRow.alignment = .center
        historyRow.translatesAutoresizingMaskIntoConstraints = false
        rightHeader.addSubview(historyRow)
        NSLayoutConstraint.activate([
            historyRow.topAnchor.constraint(equalTo: rightHeader.topAnchor),
            historyRow.bottomAnchor.constraint(equalTo: rightHeader.bottomAnchor),
            historyRow.leadingAnchor.constraint(equalTo: rightHeader.leadingAnchor),
            historyRow.trailingAnchor.constraint(equalTo: rightHeader.trailingAnchor),
        ])

        footerEffect.layer.cornerRadius = 12
        footerEffect.layer.borderWidth = 0.5
        footerEffect.clipsToBounds = true
        footerEffect.contentView.addSubview(adminQr)
        NSLayoutConstraint.activate([
            footerEffect.heightAnchor.constraint(equalToConstant: 44),
            adminQr.topAnchor.constraint(equalTo: footerEffect.contentView.topAnchor, constant: 4),
            adminQr.bottomAnchor.constraint(equalTo: footerEffect.contentView.bottomAnchor,
                                            constant: -4),
            adminQr.leadingAnchor.constraint(equalTo: footerEffect.contentView.leadingAnchor,
                                             constant: 8),
            adminQr.trailingAnchor.constraint(equalTo: footerEffect.contentView.trailingAnchor,
                                              constant: -8),
        ])

        dashboardHeader.axis = .horizontal
        dashboardHeader.spacing = 16
        dashboardHeader.alignment = .center
        dashboardHeader.distribution = .fill
        headerControls.axis = .vertical
        headerControls.spacing = 4
        headerControls.alignment = .fill
        headerControls.addArrangedSubview(statusRow)
        headerControls.addArrangedSubview(footerEffect)
        dashboardHeader.addArrangedSubview(leftHeader)
        dashboardHeader.addArrangedSubview(headerControls)
        leftHeader.widthAnchor.constraint(equalTo: dashboardHeader.widthAnchor,
                                          multiplier: 0.30).isActive = true
        dashboardHeader.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dashboardHeader)

        leftColumn.axis = .vertical
        leftColumn.spacing = 14
        for view in [doorPageButton, offlineDoorButton, tilesStack, noticeButton] {
            leftColumn.addArrangedSubview(view)
        }
        leftColumn.addArrangedSubview(UIView())

        rightColumn.axis = .vertical
        rightColumn.spacing = 14
        for view in [rightHeader, UIView(), sosControl] {
            rightColumn.addArrangedSubview(view)
        }

        columns.axis = .horizontal
        columns.spacing = 24
        columns.alignment = .fill
        columns.distribution = .fill
        columns.addArrangedSubview(leftColumn)
        columns.addArrangedSubview(rightColumn)
        leftColumn.widthAnchor.constraint(equalTo: rightColumn.widthAnchor,
                                          multiplier: 1.35).isActive = true
        columns.translatesAutoresizingMaskIntoConstraints = false
        addSubview(columns)
        NSLayoutConstraint.activate([
            dashboardHeader.topAnchor.constraint(equalTo: topAnchor),
            dashboardHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            dashboardHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
            columns.topAnchor.constraint(equalTo: dashboardHeader.bottomAnchor, constant: 14),
            columns.bottomAnchor.constraint(equalTo: bottomAnchor),
            columns.leadingAnchor.constraint(equalTo: leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        startStillTimer()
    }

    private func style(_ button: UIButton, title: String, filled: Bool) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.layer.cornerRadius = 10
        #if !os(tvOS)
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
        #endif
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    // MARK: - Layout

    /// Portrait stacks the tiles above the call list; landscape puts them side by side. The
    /// decision is made from the size the view is about to have, never from a fixed orientation.
    func applyLayout(for size: CGSize) {
        let portrait = size.height > size.width
        columns.axis = portrait ? .vertical : .horizontal
        columns.distribution = .fill
        clockLabel.font = UIFont.monospacedDigitSystemFont(ofSize: portrait ? 48 : 64,
                                                           weight: .light)
    }

    // MARK: - Content

    /// `skin` carries both halves of the answer: the household's theme background, which this
    /// panel paints like the door station does, and the light/dark palette that owns the cards
    /// laid on top of it.
    /// One reload, one snapshot. Every part of this page used to fetch `core.status()` for
    /// itself — five parses of the same JSON, microseconds apart, on the main thread.
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
        adminQr.skin = skin
        adminQr.reload(status: status)
        refreshMissedBadge()
        refreshVersionLine(status: status)
        sosControl.countdownSeconds = ConfigUtil.int(config, "emergency.trigger.countdown_s", 3)
        sosControl.refreshStrings()
        refreshStills(status: status)
    }

    /// The clock, the date, the section heading and the identity line sit straight on the theme
    /// background, so their colours come from Core's per-region automatic ink. Everything with a
    /// fill of its own — pills, chips, buttons, the tiles, the call list — is a surface this view
    /// painted from the palette, and keeps the palette's ink.
    private func applySkin() {
        skin.apply("clock", to: clockLabel)
        dateLabel.textColor = .white
        skin.apply("status_line", to: historyHeader)
        footerEffect.contentView.backgroundColor = skin.surface.withAlphaComponent(0.65)
        footerEffect.layer.borderColor = skin.cardInk("footer").withAlphaComponent(0.35).cgColor
        counters.update(lastCounts, ink: skin.cardInk("status_line"))
        DoorbellTheme.pill(missedBadge, background: skin.palette.danger,
                           ink: DoorbellTheme.readableInk(on: skin.palette.danger), fontSize: 15)
        for button in [adminButton, noticeButton, doorPageButton,
                       offlineDoorButton, seeAllButton] {
            button.setTitleColor(skin.cardInk("status_line"), for: .normal)
            button.backgroundColor = skin.surface
        }
    }

    /// The reading is handed in by the screen that owns the clock. Asking Core for a second one
    /// meant two synchronous Core calls per tick on the main thread.
    func updateClock(_ reading: DoorbellClock.Reading) {
        clockLabel.text = reading.hhmmss
        dateLabel.text = DoorbellClock.longDate(reading, lang: boot.uiLang)
    }

    func refreshMissedBadge() {
        let unread = CallHistory.unreadMissed(core)
        missedBadge.isHidden = unread <= 0
        missedBadge.text = texts.t("history.missed_badge", "\(unread)")
    }

    func refreshHistory() {
        refreshMissedBadge()
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
            tile.updateNotice(active: notice != nil, skin: skin)
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
        doorPageButton.isHidden = allDoors.count <= Self.previewCapacity
        if !doorPageButton.isHidden {
            doorPageButton.setTitle("\(texts.t("settings.doors")) · \(doors.count)/\(allDoors.count) ›",
                                    for: .normal)
        }
        let offlinePeers = ConfigUtil.offlineDoorPeers(config: config, status: status)
        offlineDoorButton.isHidden = offlinePeers.isEmpty
        if !offlineDoorButton.isHidden {
            offlineDoorButton.setTitle("\(texts.t("dashboard.offline_doors")) · \(offlinePeers.count) ›",
                                       for: .normal)
        }
        let existing = Set(tiles.keys)
        if existing != Set(doors) {
            for view in tilesStack.arrangedSubviews { view.removeFromSuperview() }
            tiles = [:]
            for door in doors {
                let tile = DoorTileView(texts: texts)
                tile.door = door
                tile.onOpen = { [weak self] in self?.onOpenDoor?(door) }
                tile.onNotice = { [weak self] in self?.onOpenNotice?(door) }
                tiles[door] = tile
            }
        }
        for row in tilesStack.arrangedSubviews { tilesStack.removeArrangedSubview(row); row.removeFromSuperview() }
        let rows = Self.previewRows(for: doors)
        for rowDoors in rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .fill
            row.distribution = .fillEqually
            row.spacing = 12
            row.setContentHuggingPriority(.required, for: .vertical)
            let cardHeight: CGFloat = rowDoors.count > 1
                ? (doors.count == 4 ? 170 : 204) : 304
            row.heightAnchor.constraint(equalToConstant: cardHeight).isActive = true
            for door in rowDoors {
                guard let tile = tiles[door] else { continue }
                tile.applyDensity(visibleCount: doors.count, grid: rowDoors.count > 1)
                tile.setContentHuggingPriority(.required, for: .vertical)
                row.addArrangedSubview(tile)
            }
            tilesStack.addArrangedSubview(row)
        }
        for door in doors {
            guard let tile = tiles[door] else { continue }
            let entry = ConfigUtil.dig(config, "doors.\(door)") as? [String: Any]
            let peer = ConfigUtil.onlineDoorPeer(status, door: door)
            let notice = DoorbellNotice.effective(status: status, config: config, door: door,
                                                  nowMs: nowMs)
            tile.apply(label: ConfigUtil.labelOf(entry, boot.uiLang, door),
                       online: peer != nil,
                       noticeActive: notice != nil,
                       skin: skin)
        }
    }

    private static let previewCapacity = 4

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

    private func snapshotUrl(peer: [String: Any]) -> URL? {
        if let stream = ConfigUtil.str(peer, "stream"),
           var components = URLComponents(string: stream) {
            components.path = "/snapshot.jpg"
            components.query = nil
            if let url = components.url { return url }
        }
        guard let host = ConfigUtil.peerHost(peer) else { return nil }
        return URL(string: "http://\(host):47180/snapshot.jpg")
    }

    private func videoMetaUrl(peer: [String: Any]) -> URL? {
        if let value = ConfigUtil.str(peer, "video_meta"), let url = URL(string: value) {
            return url
        }
        guard let stream = ConfigUtil.str(peer, "stream"),
              var components = URLComponents(string: stream) else { return nil }
        components.path = "/video-meta"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: - Actions

    @objc private func openAdmin() { onOpenAdmin?() }

    @objc private func openHistory() { onOpenHistory?() }

    @objc private func openGlobalNotice() { onOpenNotice?("") }

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

final class OfflineDoorStationsViewController: SettingsFormViewController {
    private let core: CoreBridge
    private let config: [String: Any]?

    init(core: CoreBridge, config: [String: Any]?, texts: Texts) {
        self.core = core
        self.config = config
        super.init(texts: texts)
        screenTitle = texts.t("dashboard.offline_doors_title")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func fields() -> [SettingsField] {
        let peers = ConfigUtil.offlineDoorPeers(config: config, status: core.status())
        guard !peers.isEmpty else { return [.note(texts.t("dashboard.offline_doors_empty"))] }
        return peers.map { peer in
            let door = ConfigUtil.evStr(peer, "door")
            let entry = ConfigUtil.dig(config, "doors.\(door)") as? [String: Any]
            let label = ConfigUtil.labelOf(entry, texts.lang, door)
            let name = ConfigUtil.evStr(peer, "name")
            let detail = [label, texts.t("dashboard.device_status_offline")]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            return .value(title: name.isEmpty ? door : name, detail: detail)
        }
    }
}

/// One door: its most recent still, its name, whether it is reachable, and whether an
/// announcement is showing there.
final class DoorTileView: UIView, UIGestureRecognizerDelegate {

    var door = ""
    var onOpen: (() -> Void)?
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
    private var stillRequestActive = false
    private var pendingStillRefresh: (url: URL, rotation: Int)?
    /// The last frame actually painted, so an unchanged scene costs nothing.
    private var lastStillData: Data?
    private let session: URLSession
    private let texts: Texts
    private var minimumHeightConstraint: NSLayoutConstraint!

    init(texts: Texts) {
        self.texts = texts
        self.noticeChip = NoticeChipView(texts: texts)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        self.session = URLSession(configuration: configuration)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "door_tile"
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        layer.cornerRadius = 12
        clipsToBounds = true

        still.contentMode = .scaleAspectFill
        still.clipsToBounds = true
        still.translatesAutoresizingMaskIntoConstraints = false
        addSubview(still)

        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        stateLabel.font = .systemFont(ofSize: 14)
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

        minimumHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
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
            minimumHeightConstraint,
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(open))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        captionGradient.frame = captionBackground.bounds
    }

    func applyDensity(visibleCount: Int, grid: Bool) {
        let height: CGFloat = grid ? (visibleCount == 4 ? 116 : 150) : 250
        let minimum = height + 54
        if minimumHeightConstraint.constant != minimum { minimumHeightConstraint.constant = minimum }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        var candidate = touch.view
        while let view = candidate, view !== self {
            if view is UIControl { return false }
            candidate = view.superview
        }
        return true
    }

    /// The name sits over the live image, so its ink and gradient remain legible independently of
    /// the household theme or the colours in the camera frame.
    func apply(label: String, online: Bool, noticeActive: Bool, skin: DoorbellSkin) {
        if nameLabel.text != label { nameLabel.text = label }
        accessibilityLabel = label
        accessibilityHint = texts.t("door.view")
        let state = online ? "" : texts.t("admin.offline")
        if stateLabel.text != state { stateLabel.text = state }
        stateLabel.isHidden = state.isEmpty
        if nameLabel.textColor != .white { nameLabel.textColor = .white }
        if stateLabel.textColor != .white { stateLabel.textColor = .white }
        let alpha: CGFloat = online ? 1 : 0.35
        if still.alpha != alpha { still.alpha = alpha }
        noticeChip.update(active: noticeActive, palette: skin.palette)
    }

    func updateNotice(active: Bool, skin: DoorbellSkin) {
        noticeChip.update(active: active, palette: skin.palette)
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
        }
        if let videoMetaUrl = videoMetaUrl,
           lastRotationRefresh == 0 || Date.timeIntervalSinceReferenceDate - lastRotationRefresh >= 60 {
            guard !rotationRequestActive else { return }
            rotationRequestActive = true
            session.dataTask(with: videoMetaUrl) { [weak self] data, response, _ in
                let rotation: Int? = {
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          let data = data,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { return nil }
                    return object["rotation"] as? Int
                }()
                DispatchQueue.main.async {
                    guard let self = self else { return }
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
        session.dataTask(with: url) { [weak self] data, _, _ in
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

    @objc private func open() { onOpen?() }
}
