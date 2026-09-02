import ImageIO
import UIKit

/// Indoor home screen. Everything the household needs at a glance: the household clock, who is
/// in the cluster, unanswered calls, one tile per door with a recent still, the recent call list,
/// the admin QR that is always visible, and the SOS slider.
///
/// The view owns no call state; `MainViewController` hosts it and routes every action.
final class DashboardView: UIView {

    var onOpenAdmin: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onOpenDoor: ((String) -> Void)?
    var onOpenNotice: ((String) -> Void)?

    private let core: CoreBridge
    private let boot: BootConfig
    private let texts: Texts

    private let clockLabel = HaloLabel()
    private let dateLabel = HaloLabel()
    private let membershipPill = PaddedLabel()
    private let missedBadge = PaddedLabel()
    private let adminButton = UIButton(type: .system)
    private let noticeButton = UIButton(type: .system)
    private let historyHeader = HaloLabel()
    private let seeAllButton = UIButton(type: .system)
    private let tilesStack = UIStackView()
    private let recentCalls: RecentCallsView
    private let adminQr: AdminQrView
    private let versionLabel = HaloLabel()
    let sosControl: SosSlideControl

    private let columns = UIStackView()
    private let leftColumn = UIStackView()
    private let rightColumn = UIStackView()

    private var config: [String: Any]?
    private var skin = DoorbellSkin.plain(.dark)
    private var tiles: [String: DoorTileView] = [:]
    private var stillTimer: Timer?

    init(core: CoreBridge, boot: BootConfig, texts: Texts, sosControl: SosSlideControl) {
        self.core = core
        self.boot = boot
        self.texts = texts
        self.recentCalls = RecentCallsView(core: core, texts: texts, lang: boot.uiLang)
        self.adminQr = AdminQrView(core: core, boot: boot, texts: texts, compact: false)
        self.sosControl = sosControl
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { stillTimer?.invalidate() }

    // MARK: - Construction

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        clockLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 64, weight: .light)
        clockLabel.accessibilityIdentifier = "dashboard_clock"
        dateLabel.font = .systemFont(ofSize: 20)

        DoorbellTheme.pill(membershipPill, background: skin.surface, ink: skin.cardInk("status_line"),
                           fontSize: 15)
        membershipPill.accessibilityIdentifier = "membership_status"
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

        let statusRow = UIStackView(arrangedSubviews: [membershipPill, missedBadge, UIView(),
                                                        adminButton])
        statusRow.axis = .horizontal
        statusRow.spacing = 12
        statusRow.alignment = .center

        tilesStack.axis = .vertical
        tilesStack.spacing = 12

        historyHeader.text = texts.t("history.title")
        historyHeader.font = .systemFont(ofSize: 19, weight: .semibold)
        style(seeAllButton, title: texts.t("history.see_all"), filled: false)
        seeAllButton.accessibilityIdentifier = "dashboard_see_all"
        seeAllButton.addTarget(self, action: #selector(openHistory), for: .primaryActionTriggered)
        let historyRow = UIStackView(arrangedSubviews: [historyHeader, UIView(), seeAllButton])
        historyRow.axis = .horizontal
        historyRow.spacing = 12
        historyRow.alignment = .center

        versionLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        versionLabel.accessibilityIdentifier = "app_version"
        versionLabel.numberOfLines = 0


        leftColumn.axis = .vertical
        leftColumn.spacing = 14
        for view in [clockColumn, statusRow, tilesStack, noticeButton] {
            leftColumn.addArrangedSubview(view)
        }
        leftColumn.addArrangedSubview(UIView())

        rightColumn.axis = .vertical
        rightColumn.spacing = 12
        for view in [historyRow, recentCalls, adminQr, versionLabel, sosControl] {
            rightColumn.addArrangedSubview(view)
        }
        recentCalls.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        columns.axis = .horizontal
        columns.spacing = 24
        columns.alignment = .fill
        columns.distribution = .fillEqually
        columns.addArrangedSubview(leftColumn)
        columns.addArrangedSubview(rightColumn)
        columns.translatesAutoresizingMaskIntoConstraints = false
        addSubview(columns)
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: topAnchor),
            columns.bottomAnchor.constraint(equalTo: bottomAnchor),
            columns.leadingAnchor.constraint(equalTo: leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        stillTimer = IOSAvailability.scheduledTimer(withTimeInterval: 5, repeats: true) {
            [weak self] _ in self?.refreshStills()
        }
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
        columns.distribution = portrait ? .fill : .fillEqually
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
        applySkin()
        rebuildTiles(status: status, nowMs: nowMs)
        recentCalls.reload(config: config, skin: skin)
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
        skin.apply("date", to: dateLabel, quiet: true)
        skin.apply("status_line", to: historyHeader)
        skin.apply("footer", to: versionLabel, quiet: true)
        DoorbellTheme.pill(membershipPill, background: skin.surface,
                           ink: skin.cardInk("status_line"), fontSize: 15)
        DoorbellTheme.pill(missedBadge, background: skin.palette.danger,
                           ink: DoorbellTheme.readableInk(on: skin.palette.danger), fontSize: 15)
        for button in [adminButton, noticeButton, seeAllButton] {
            button.setTitleColor(skin.cardInk("status_line"), for: .normal)
            button.backgroundColor = skin.surface
        }
    }

    func updateClock() {
        guard let reading = DoorbellClock.read(core) else { return }
        clockLabel.text = reading.hhmmss
        dateLabel.text = DoorbellClock.longDate(reading, lang: boot.uiLang)
    }

    func updateMembership(_ text: String, hidden: Bool) {
        membershipPill.text = text
        membershipPill.isHidden = hidden
    }

    func refreshMissedBadge() {
        let unread = CallHistory.unreadMissed(core)
        missedBadge.isHidden = unread <= 0
        missedBadge.text = texts.t("history.missed_badge", "\(unread)")
    }

    func refreshHistory() {
        recentCalls.reload(config: config, skin: skin)
        refreshMissedBadge()
    }

    private func refreshVersionLine(status: [String: Any]? = nil) {
        let snapshot = status ?? core.status()
        let power = (snapshot?["self"] as? [String: Any])?["power"] as? [String: Any]
        versionLabel.text = DoorbellTheme.versionLine(name: boot.name,
                                                      coreVersion: DoorbellTheme.coreVersion(),
                                                      texts: texts, power: power)
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

    // MARK: - Door tiles

    private func rebuildTiles(status: [String: Any]?, nowMs: Int64) {
        let doors = (ConfigUtil.dig(config, "doors") as? [String: Any])
            .map { ConfigUtil.sortedByOrder($0) } ?? []
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
                tilesStack.addArrangedSubview(tile)
            }
        }
        for door in doors {
            guard let tile = tiles[door] else { continue }
            let entry = ConfigUtil.dig(config, "doors.\(door)") as? [String: Any]
            let peer = ConfigUtil.findDoorPeer(status, door: door)
            let notice = DoorbellNotice.effective(status: status, config: config, door: door,
                                                  nowMs: nowMs)
            tile.apply(label: ConfigUtil.labelOf(entry, boot.uiLang, door),
                       online: peer != nil,
                       noticeActive: notice != nil,
                       skin: skin)
        }
    }

    /// Live stills, five seconds apart, from the door station's own snapshot endpoint. An
    /// unreachable door greys out instead of freezing on a stale frame.
    private func refreshStills(status: [String: Any]? = nil) {
        IOSAvailability.PerfProbe.measure("dashboard.stills") {
            refreshStillsBody(status: status)
        }
    }

    private func refreshStillsBody(status: [String: Any]?) {
        let snapshot = status ?? core.status()
        for (door, tile) in tiles {
            guard let peer = ConfigUtil.findDoorPeer(snapshot, door: door),
                  let url = snapshotUrl(peer: peer) else {
                tile.setStill(nil)
                continue
            }
            tile.loadStill(from: url)
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

    // MARK: - Actions

    @objc private func openAdmin() { onOpenAdmin?() }

    @objc private func openHistory() { onOpenHistory?() }

    @objc private func openGlobalNotice() { onOpenNotice?("") }
}

/// One door: its most recent still, its name, whether it is reachable, and whether an
/// announcement is showing there.
final class DoorTileView: UIView {

    var door = ""
    var onOpen: (() -> Void)?
    var onNotice: (() -> Void)?

    private let still = UIImageView()
    private let nameLabel = UILabel()
    private let stateLabel = UILabel()
    private let noticeChip: NoticeChipView
    private let openButton = UIButton(type: .system)
    private var pendingUrl: URL?
    /// The last frame actually painted, so an unchanged scene costs nothing.
    private var lastStillData: Data?
    private let session: URLSession
    private let texts: Texts

    init(texts: Texts) {
        self.texts = texts
        self.noticeChip = NoticeChipView(texts: texts)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        self.session = URLSession(configuration: configuration)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "door_tile"
        layer.cornerRadius = 12
        clipsToBounds = true

        still.contentMode = .scaleAspectFill
        still.clipsToBounds = true
        still.translatesAutoresizingMaskIntoConstraints = false
        addSubview(still)

        nameLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        stateLabel.font = .systemFont(ofSize: 14)

        openButton.setTitle(texts.t("door.view"), for: .normal)
        openButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        openButton.addTarget(self, action: #selector(open), for: .primaryActionTriggered)
        openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        noticeChip.onTap = { [weak self] in self?.onNotice?() }

        let textColumn = UIStackView(arrangedSubviews: [nameLabel, stateLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 1

        noticeChip.setContentHuggingPriority(.required, for: .horizontal)
        noticeChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [textColumn, UIView(), noticeChip, openButton])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            still.topAnchor.constraint(equalTo: topAnchor),
            still.leadingAnchor.constraint(equalTo: leadingAnchor),
            still.widthAnchor.constraint(equalToConstant: 132),
            still.heightAnchor.constraint(equalToConstant: 84),
            still.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: still.trailingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The tile is an opaque card, so its caption keeps the palette's ink rather than the ink
    /// Core measured for the theme background — an administrator's `tile_label` override still
    /// wins, because that is a colour somebody chose on purpose.
    func apply(label: String, online: Bool, noticeActive: Bool, skin: DoorbellSkin) {
        if nameLabel.text != label { nameLabel.text = label }
        let state = online ? "" : texts.t("admin.offline")
        if stateLabel.text != state { stateLabel.text = state }
        let ink = skin.cardInk("tile_label")
        if nameLabel.textColor != ink {
            nameLabel.textColor = ink
            openButton.setTitleColor(ink, for: .normal)
        }
        let muted = skin.cardMuted("tile_label")
        if stateLabel.textColor != muted { stateLabel.textColor = muted }
        if backgroundColor != skin.surface { backgroundColor = skin.surface }
        let alpha: CGFloat = online ? 1 : 0.35
        if still.alpha != alpha { still.alpha = alpha }
        noticeChip.update(active: noticeActive, palette: skin.palette)
    }

    func updateNotice(active: Bool, skin: DoorbellSkin) {
        noticeChip.update(active: active, palette: skin.palette)
    }

    func setStill(_ image: UIImage?) {
        lastStillData = nil
        still.image = image
    }

    func loadStill(from url: URL) {
        pendingUrl = url
        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, !data.isEmpty else { return }
            guard data != self.lastStillData else { return }
            guard let image = DoorTileView.thumbnail(from: data, fitting: self.still.bounds.size)
            else { return }
            DispatchQueue.main.async {
                guard self.pendingUrl == url else { return }
                self.lastStillData = data
                self.still.image = image
            }
        }.resume()
    }

    /// Decodes straight to the size the tile draws at. `UIImage(data:)` only records the bytes and
    /// leaves the real work — a full-resolution JPEG decode and downscale — to the main thread at
    /// commit time, which is exactly the periodic hitch this page had.
    private static func thumbnail(from data: Data, fitting size: CGSize) -> UIImage? {
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
        return UIImage(cgImage: thumb)
    }

    @objc private func open() { onOpen?() }
}
