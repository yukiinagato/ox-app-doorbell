import UIKit

/// Home of the living-room screen: a glanceable header, the door cameras as the largest thing on
/// screen, and a short action row. Nothing here is a port of the tablet dashboard.
final class TVHomeViewController: UIViewController, UICollectionViewDataSource,
                                  UICollectionViewDelegateFlowLayout {

    static let showSosKey = "tv.show_sos_home"

    var onOpenDoor: ((String) -> Void)?
    var onOpenNotice: (() -> Void)?
    var onOpenPairing: (() -> Void)?
    var onUnreadMissedChanged: ((Int) -> Void)?

    struct Card {
        let door: String
        let name: String
        let online: Bool
        let notice: Bool
    }

    private let core: CoreBridge
    private let boot: BootConfig
    private let texts: Texts
    private let sos: UIControl

    private let scrim = TVGradientView()
    private let clockLabel = UILabel()
    private let dateLabel = UILabel()
    private let statusLabel = UILabel()
    private let emptyLabel = UILabel()
    private let actions = UIStackView()
    private let noticeButton: UIButton
    private let pairingButton: UIButton
    private let qrSource: AdminQrView
    private let qrThumb = TVQrThumbnail()
    private var focusQrNext = false
    private let layout = UICollectionViewFlowLayout()
    private lazy var shelf = UICollectionView(frame: .zero, collectionViewLayout: layout)

    private var cards: [Card] = []
    private var config: [String: Any]?
    private var unreadMissed = 0
    private var stillTimer: Timer?
    private var pairingReady = true
    private var defaultsObserver: NSObjectProtocol?

    init(core: CoreBridge, boot: BootConfig, texts: Texts, sos: UIControl) {
        self.core = core
        self.boot = boot
        self.texts = texts
        self.sos = sos
        noticeButton = SystemStyle.button(.gray, title: texts.t("notice.global_button"),
                                          icon: .note, large: true)
        pairingButton = SystemStyle.button(.filled, title: texts.t("pair.not_set_up_banner"),
                                           icon: .plus, large: true)
        qrSource = AdminQrView(core: core, boot: boot, texts: texts, compact: true,
                               qrSide: 96, showsCaption: false)
        super.init(nibName: nil, bundle: nil)
        title = texts.t("nav.home")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        stillTimer?.invalidate()
        if let observer = defaultsObserver { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Construction

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "tv_home"

        scrim.isUserInteractionEnabled = false
        scrim.gradient.colors = [UIColor(white: 0, alpha: 0.6).cgColor,
                                 UIColor(white: 0, alpha: 0.5).cgColor,
                                 UIColor(white: 0, alpha: 0.8).cgColor]
        scrim.gradient.locations = [0, 0.5, 1]
        scrim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrim)

        clockLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 96, weight: .light)
        clockLabel.accessibilityIdentifier = "tv_clock"
        dateLabel.font = SystemStyle.font(.title3, weight: .medium)
        statusLabel.font = SystemStyle.font(.headline, weight: .semibold)
        statusLabel.textAlignment = .right
        statusLabel.accessibilityIdentifier = "tv_status"
        for label in [clockLabel, dateLabel, statusLabel] {
            label.textColor = .white
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.6
            label.layer.shadowRadius = 6
            label.layer.shadowOffset = .zero
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
        }

        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 40
        shelf.register(TVDoorCardCell.self, forCellWithReuseIdentifier: "card")
        shelf.dataSource = self
        shelf.delegate = self
        shelf.backgroundColor = .clear
        shelf.clipsToBounds = false
        shelf.remembersLastFocusedIndexPath = true
        shelf.showsHorizontalScrollIndicator = false
        shelf.accessibilityIdentifier = "tv_door_shelf"
        shelf.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shelf)

        emptyLabel.text = texts.t("tv.no_doors")
        emptyLabel.font = SystemStyle.font(.title3)
        emptyLabel.textColor = UIColor(white: 1, alpha: 0.85)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        noticeButton.accessibilityIdentifier = "dashboard_notice_global"
        noticeButton.addTarget(self, action: #selector(noticeTapped), for: .primaryActionTriggered)
        pairingButton.accessibilityIdentifier = "membership_status"
        pairingButton.addTarget(self, action: #selector(pairingTapped),
                                for: .primaryActionTriggered)
        actions.axis = .horizontal
        actions.spacing = 32
        actions.alignment = .center
        for item in [noticeButton, pairingButton, sos] as [UIView] {
            actions.addArrangedSubview(item)
        }
        actions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actions)

        qrThumb.caption.text = texts.t("web_admin.open")
        qrThumb.accessibilityIdentifier = "admin_qr"
        qrThumb.addTarget(self, action: #selector(qrTapped), for: .primaryActionTriggered)
        qrThumb.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(qrThumb)
        qrSource.onImageReady = { [weak self] in
            guard let self = self else { return }
            self.qrThumb.setImage(self.qrSource.qrImage)
        }

        let g = view.safeAreaLayoutGuide
        let sideInset: CGFloat = 80
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: view.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            clockLabel.topAnchor.constraint(equalTo: g.topAnchor),
            clockLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: sideInset),
            dateLabel.topAnchor.constraint(equalTo: clockLabel.bottomAnchor, constant: -4),
            dateLabel.leadingAnchor.constraint(equalTo: clockLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                                  constant: -sideInset),
            statusLabel.centerYAnchor.constraint(equalTo: dateLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: dateLabel.trailingAnchor,
                                                 constant: 40),
            shelf.topAnchor.constraint(equalTo: dateLabel.bottomAnchor, constant: 12),
            shelf.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: sideInset),
            shelf.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -sideInset),
            shelf.bottomAnchor.constraint(equalTo: qrThumb.topAnchor, constant: -16),
            emptyLabel.centerXAnchor.constraint(equalTo: shelf.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: shelf.centerYAnchor),
            qrThumb.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: sideInset - 12),
            qrThumb.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -48),
            qrThumb.widthAnchor.constraint(lessThanOrEqualToConstant: 900),
            actions.centerYAnchor.constraint(equalTo: qrThumb.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -sideInset),
        ])

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyActionVisibility() }
        applyActionVisibility()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = max(1, shelf.bounds.height - 40)
        if abs(layout.itemSize.height - height) > 0.5 || layout.itemSize.width < 1 {
            layout.itemSize = itemSize(height: height)
            layout.sectionInset = UIEdgeInsets(top: 20, left: 0, bottom: 20, right: 0)
            layout.invalidateLayout()
        }
    }

    private func itemSize(height: CGFloat) -> CGSize {
        let full = max(1, shelf.bounds.width)
        if cards.count <= 1 { return CGSize(width: full, height: height) }
        if cards.count == 2 { return CGSize(width: ((full - 40) / 2).rounded(.down), height: height) }
        return CGSize(width: min(full, (height * 16 / 9).rounded()), height: height)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        startStillTimer()
        refreshStills()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stillTimer?.invalidate()
        stillTimer = nil
    }

    // MARK: State

    func reload(config: [String: Any]?) {
        self.config = config
        let status = core.status()
        let nowMs = DoorbellClock.nowMs(core)
        let doors = ConfigUtil.doorsWithCamera(config: config, status: status)
        var next = doors.map { door -> Card in
            let entry = ConfigUtil.dig(config, "doors.\(door)") as? [String: Any]
            return Card(door: door, name: ConfigUtil.labelOf(entry, boot.uiLang, door),
                        online: ConfigUtil.onlineDoorPeer(status, door: door) != nil,
                        notice: DoorbellNotice.effective(status: status, config: config,
                                                         door: door, nowMs: nowMs) != nil)
        }
        // Reachable doors lead, so the first card is also the one that has a picture.
        next = next.filter { $0.online } + next.filter { !$0.online }
        let changed = next.map { $0.door } != cards.map { $0.door }
        cards = next
        emptyLabel.isHidden = !cards.isEmpty
        if changed {
            layout.itemSize = itemSize(height: max(1, shelf.bounds.height - 40))
            shelf.reloadData()
            setNeedsFocusUpdate()
        } else {
            for case let cell as TVDoorCardCell in shelf.visibleCells {
                if let path = shelf.indexPath(for: cell) { cell.apply(cards[path.item]) }
            }
        }
        applyStatusLine(status: status)
        qrSource.reload(status: status)
        let info = Bundle.main.infoDictionary
        let app = (info?["CFBundleShortVersionString"] as? String ?? "") + " ("
            + (info?["CFBundleVersion"] as? String ?? "") + ")"
        let core = DoorbellTheme.coreVersion().split(separator: "+").first.map(String.init) ?? ""
        qrThumb.detail.text = [boot.name, "v" + app, "core " + core]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        refreshMissedBadge()
        refreshStills()
    }

    private func applyStatusLine(status: [String: Any]?) {
        let counts = ClusterCounts.from(status: status, selfRole: "indoor_panel")
        let line = texts.t("tv.status_doors", "\(counts.doorStationsOnline)",
                           "\(counts.doorStations)")
            + "  ·  " + texts.t("tv.status_indoor", "\(counts.indoorPanelsOnline)",
                                "\(counts.indoorPanels)")
        let offline = (counts.doorStations - counts.doorStationsOnline)
            + (counts.indoorPanels - counts.indoorPanelsOnline)
        let text = NSMutableAttributedString(string: line)
        if offline > 0 {
            let attachment = NSTextAttachment()
            attachment.image = UIImage(systemName: "exclamationmark.triangle.fill")?
                .withTintColor(.systemYellow, renderingMode: .alwaysOriginal)
            text.append(NSAttributedString(string: "   "))
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " " + texts.t("admin.offline") + " \(offline)"))
        }
        text.addAttributes([.font: statusLabel.font as Any, .foregroundColor: UIColor.white],
                           range: NSRange(location: 0, length: text.length))
        statusLabel.attributedText = text
        statusLabel.accessibilityLabel = line + (offline > 0 ? " · \(offline)" : "")
    }

    func updateClock(_ reading: DoorbellClock.Reading) {
        clockLabel.text = reading.hhmmss
        dateLabel.text = DoorbellClock.longDate(reading, lang: boot.uiLang)
    }

    func setPairingReady(_ ready: Bool) {
        pairingReady = ready
        applyActionVisibility()
    }

    func refreshMissedBadge() {
        let unread = CallHistory.unreadMissed(core)
        guard unread != unreadMissed else { return }
        unreadMissed = unread
        onUnreadMissedChanged?(unread)
    }

    private func applyActionVisibility() {
        sos.isHidden = !UserDefaults.standard.bool(forKey: Self.showSosKey)
        pairingButton.isHidden = pairingReady
        setNeedsFocusUpdate()
    }

    private func startStillTimer() {
        stillTimer?.invalidate()
        let interval = DashboardView.previewInterval(
            for: DashboardView.savedPreviewFramesPerSecond)
        stillTimer = Timer.scheduledTimer(withTimeInterval: max(1, interval), repeats: true) {
            [weak self] _ in self?.refreshStills()
        }
    }

    func refreshStills() {
        guard isViewLoaded, view.window != nil else { return }
        let status = core.status()
        for case let cell as TVDoorCardCell in shelf.visibleCells {
            guard let path = shelf.indexPath(for: cell), path.item < cards.count else { continue }
            guard let peer = ConfigUtil.onlineDoorPeer(status, door: cards[path.item].door),
                  let stream = ConfigUtil.str(peer, "stream"), let url = URL(string: stream),
                  let still = LocalMediaAuth.sibling(url, "snapshot.jpg") else {
                cell.tile.setStill(nil)
                continue
            }
            cell.tile.loadStill(from: still, videoMetaUrl: LocalMediaAuth.sibling(url, "video-meta"))
        }
    }

    // MARK: Actions

    @objc func qrTapped() {
        guard presentedViewController == nil, !qrSource.adminAddress.isEmpty else { return }
        let sheet = TVQrSheetViewController(core: core, texts: texts, address: qrSource.adminAddress)
        sheet.onClose = { [weak self] in
            self?.focusQrNext = true
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
            self?.focusQrNext = false
        }
        present(sheet, animated: true)
    }

    @objc private func noticeTapped() { onOpenNotice?() }
    @objc private func pairingTapped() { onOpenPairing?() }

    /// Play/Pause on Home opens the first reachable door.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .playPause }),
           let first = cards.first(where: { $0.online }) {
            onOpenDoor?(first.door)
            return
        }
        super.pressesEnded(presses, with: event)
    }

    // MARK: Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if focusQrNext { return [qrThumb] }
        return cards.isEmpty ? [noticeButton] : [shelf]
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        return cards.isEmpty ? nil : IndexPath(item: 0, section: 0)
    }

    // MARK: Collection

    func collectionView(_ collectionView: UICollectionView,
                        numberOfItemsInSection section: Int) -> Int { return cards.count }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card",
                                                      for: indexPath)
        if let card = cell as? TVDoorCardCell {
            card.configure(texts: texts)
            card.apply(cards[indexPath.item])
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        didSelectItemAt indexPath: IndexPath) {
        onOpenDoor?(cards[indexPath.item].door)
    }

}

extension TVDoorCardCell {
    func apply(_ card: TVHomeViewController.Card) {
        tile.door = card.door
        tile.apply(label: card.name, online: card.online, noticeActive: card.notice)
    }
}

/// One door camera on the shelf. The system focus engine lifts and scales it.
final class TVDoorCardCell: UICollectionViewCell {

    private(set) var tile: DoorTileView!

    func configure(texts: Texts) {
        guard tile == nil else { return }
        let tile = DoorTileView(texts: texts)
        tile.layer.cornerRadius = 24
        tile.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tile)
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: contentView.topAnchor),
            tile.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            tile.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        self.tile = tile
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tile?.setStill(nil)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        tile?.setFocused(context.nextFocusedView === self, coordinator: coordinator)
    }
}

final class TVGradientView: UIView {
    override class var layerClass: AnyClass { return CAGradientLayer.self }
    var gradient: CAGradientLayer { return layer as! CAGradientLayer }
}
