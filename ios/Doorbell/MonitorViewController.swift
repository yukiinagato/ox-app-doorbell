import UIKit

/// Active monitoring uses only peers that Core has confirmed as live door stations.
/// Seed addresses are never promoted to a role by the shell.
final class MonitorViewController: UIViewController {
    private let core: CoreBridge
    private let boot: BootConfig
    private let initialDoor: String?
    private let texts = Texts()
    private let styleApplier = UIStyleApplier()
    private var nodeId = ""
    private var config: [String: Any]?
    private var videoPlayer: AdaptiveH264MjpegPlayer?
    private var monitoringAudio = false
    /// The door the page is showing, so a peer list arriving again does not restart anything.
    private var selectedPeerId = ""
    /// The user wants to listen to `selectedPeerId`. Cleared when the page goes away or the door
    /// turns out to have nothing to listen to; an automatic retry is only allowed while it is set.
    private var monitorWanted = false
    private var monitorRetry = MonitorRetryPolicy()
    private var monitorRetryTimer: Timer?
    /// When the current dialog was asked for, to tell a listen that carried audio from one that
    /// came up and died with nothing in it.
    private var monitorStartedAt: TimeInterval = 0
    private var monitorReachedInCall = false
    /// A dialog that ends within this of being answered carried nothing worth keeping.
    private static let silentDialogS: TimeInterval = 2
    private var safeMode = UserDefaults.standard.bool(forKey: "runtime.safe_mode")

    private let themeBg = ThemeBackgroundView()
    private let videoBackdrop = UIView()
    private let video = UIImageView()
    private let h264View = UIView()
    private let titleLabel = HaloLabel()
    private let emptyLabel = HaloLabel()
    private let deviceStack = UIStackView()
    private let closeButton = UIButton(type: .system)
    private var skin = DoorbellSkin.plain(.dark)

    init(core: CoreBridge, boot: BootConfig, initialDoor: String? = nil) {
        self.core = core
        self.boot = boot
        self.initialDoor = initialDoor
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        texts.setLang(boot.uiLang)
        config = core.config()
        texts.setConfig(config)
        if let node = core.status()?["node"] as? [String: Any] {
            nodeId = ConfigUtil.evStr(node, "id")
        }
        buildUi()
        applySkin()
        rebuildDevices()
        core.addHandler("active-monitor") { [weak self] event in
            let type = ConfigUtil.evStr(event, "t")
            if type == "peers_changed" || type == "config_changed" {
                self?.config = self?.core.config()
                self?.applySkin()
                self?.rebuildDevices()
            } else if type == "display" {
                self?.applySkin()
            } else if type == "state" {
                let state = ConfigUtil.evStr(event, "state")
                if state == "in_call" {
                    self?.monitorReachedInCall = true
                } else if state == "idle" {
                    self?.monitorDialogEnded()
                }
            } else if type == "emergency" && ConfigUtil.evBool(event, "active") {
                self?.close()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoPlayer?.layout()
        styleApplier.apply(config: config, nodeId: nodeId, semanticId: "monitor.close",
                           to: closeButton)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        core.removeHandler("active-monitor")
        hideTimer?.invalidate()
        hideTimer = nil
        videoPlayer?.stop()
        videoPlayer = nil
        monitorWanted = false
        cancelMonitorRetry()
        if monitoringAudio { core.sipHangup() }
        monitoringAudio = false
    }

    func enterSafeModeForMemoryPressure() {
        safeMode = true
        videoPlayer?.stop()
        videoPlayer = nil
        video.image = nil
        themeBg.releaseImage()
        emptyLabel.isHidden = false
        // Monitoring audio and the Close control remain available until the user exits.
    }

    private func buildUi() {
        themeBg.onImageLoaded = { [weak self] in self?.applySkin() }
        themeBg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(themeBg)

        videoBackdrop.backgroundColor = .black
        videoBackdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoBackdrop)

        video.contentMode = .scaleAspectFit
        video.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(video)

        h264View.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(h264View)

        titleLabel.text = texts.t("monitor.choose")
        titleLabel.font = TypeRole.headline.font(weight: .semibold)
        titleLabel.numberOfLines = 2

        emptyLabel.text = texts.t("ring.no_video")
        emptyLabel.textAlignment = .center

        deviceStack.axis = .vertical
        deviceStack.spacing = Space.s

        closeButton.setTitle(texts.t("monitor.close"), for: .normal)
        closeButton.accessibilityIdentifier = "monitor_close"
        closeButton.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.layer.cornerRadius = Radius.card
        #if !os(tvOS)
        closeButton.contentEdgeInsets = UIEdgeInsets(top: 14, left: 30, bottom: 14, right: 30)
        #endif
        closeButton.addTarget(self, action: #selector(close), for: .primaryActionTriggered)

        // Door switcher: a horizontal strip on compact windows, a side list on wider ones.
        deviceScroll.translatesAutoresizingMaskIntoConstraints = false
        deviceStack.translatesAutoresizingMaskIntoConstraints = false
        deviceScroll.addSubview(deviceStack)
        NSLayoutConstraint.activate([
            deviceStack.topAnchor.constraint(equalTo: deviceScroll.topAnchor),
            deviceStack.bottomAnchor.constraint(equalTo: deviceScroll.bottomAnchor),
            deviceStack.leadingAnchor.constraint(equalTo: deviceScroll.leadingAnchor),
            deviceStack.trailingAnchor.constraint(equalTo: deviceScroll.trailingAnchor),
        ])
        stripHeight = deviceScroll.heightAnchor.constraint(equalTo: deviceStack.heightAnchor)
        listWidth = deviceStack.widthAnchor.constraint(equalTo: deviceScroll.widthAnchor)

        sidebar.addArrangedSubview(titleLabel)
        sidebar.addArrangedSubview(deviceScroll)
        sidebar.addArrangedSubview(emptyLabel)
        sidebar.addArrangedSubview(UIView())
        sidebar.addArrangedSubview(closeButton)
        sidebar.axis = .vertical
        sidebar.spacing = Space.m
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)

        // Tapping the picture brings hidden controls back (ui-guidelines §4, live view).
        let tap = UITapGestureRecognizer(target: self, action: #selector(showControls))
        videoBackdrop.isUserInteractionEnabled = true
        videoBackdrop.addGestureRecognizer(tap)
        h264View.isUserInteractionEnabled = false
        video.isUserInteractionEnabled = false

        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            themeBg.topAnchor.constraint(equalTo: view.topAnchor),
            themeBg.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            themeBg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            themeBg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoBackdrop.topAnchor.constraint(equalTo: video.topAnchor),
            videoBackdrop.bottomAnchor.constraint(equalTo: video.bottomAnchor),
            videoBackdrop.leadingAnchor.constraint(equalTo: video.leadingAnchor),
            videoBackdrop.trailingAnchor.constraint(equalTo: video.trailingAnchor),
            video.topAnchor.constraint(equalTo: guide.topAnchor),
            video.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            h264View.topAnchor.constraint(equalTo: video.topAnchor),
            h264View.bottomAnchor.constraint(equalTo: video.bottomAnchor),
            h264View.leadingAnchor.constraint(equalTo: video.leadingAnchor),
            h264View.trailingAnchor.constraint(equalTo: video.trailingAnchor),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchTarget.minimum + 8),
        ])
        sideConstraints = [
            video.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            video.widthAnchor.constraint(equalTo: guide.widthAnchor, multiplier: 0.68),
            sidebar.topAnchor.constraint(equalTo: guide.topAnchor, constant: Space.l),
            sidebar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Space.l),
            sidebar.leadingAnchor.constraint(equalTo: video.trailingAnchor, constant: Space.l),
            sidebar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Space.l),
        ]
        stackedConstraints = [
            video.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            video.heightAnchor.constraint(equalTo: video.widthAnchor, multiplier: 9.0 / 16.0),
            sidebar.topAnchor.constraint(equalTo: video.bottomAnchor, constant: Space.m),
            sidebar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Space.m),
            sidebar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Space.m),
            sidebar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Space.m),
        ]
        immersiveConstraints = [
            video.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            video.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ]
        applyArrangement(for: view.bounds.size)
    }

    private let deviceScroll = UIScrollView()
    private let sidebar = UIStackView()
    private var stripHeight: NSLayoutConstraint?
    private var listWidth: NSLayoutConstraint?
    private var sideConstraints: [NSLayoutConstraint] = []
    private var stackedConstraints: [NSLayoutConstraint] = []
    private var immersiveConstraints: [NSLayoutConstraint] = []
    private var controlsHidden = false
    private var hideTimer: Timer?

    /// Video beside the list on wide windows, above a door strip on compact ones, or alone once
    /// the controls have hidden themselves.
    private func applyArrangement(for size: CGSize) {
        NSLayoutConstraint.deactivate(sideConstraints + stackedConstraints + immersiveConstraints)
        let side = LayoutClass.sideBySide(size)
        if controlsHidden {
            NSLayoutConstraint.activate(immersiveConstraints)
        } else {
            NSLayoutConstraint.activate(side ? sideConstraints : stackedConstraints)
        }
        deviceStack.axis = side ? .vertical : .horizontal
        stripHeight?.isActive = !side
        listWidth?.isActive = side
        sidebar.alpha = controlsHidden ? 0 : 1
        sidebar.isUserInteractionEnabled = !controlsHidden
    }

    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.applyArrangement(for: size) })
    }

    /// Controls hide 4 s after a door starts playing and come back on a tap. tvOS keeps them:
    /// the focus engine needs something to land on.
    private func scheduleControlsHide() {
        hideTimer?.invalidate()
        #if os(iOS)
        hideTimer = IOSAvailability.scheduledTimer(withTimeInterval: 4, repeats: false) {
            [weak self] _ in
            guard let self = self, self.videoPlayer != nil else { return }
            self.controlsHidden = true
            Motion.animate { self.applyArrangement(for: self.view.bounds.size); self.view.layoutIfNeeded() }
        }
        #endif
    }

    @objc private func showControls() {
        guard controlsHidden else {
            scheduleControlsHide()
            return
        }
        controlsHidden = false
        Motion.animate { self.applyArrangement(for: self.view.bounds.size); self.view.layoutIfNeeded() }
        scheduleControlsHide()
    }

    /// The monitor page wears the same theme background as the home screens; only the picture
    /// keeps its black frame, and the sidebar's heading takes the automatic ink for the
    /// background behind it.
    /// The monitor page wears the same theme background as the home screens; only the picture
    /// keeps its black frame, and the sidebar takes the automatic ink for what is behind it.
    private func applySkin() {
        let display = core.status()?["display"] as? [String: Any]
        let palette = DoorbellPalette.of(DoorbellTheme.appearance(
            display: display, config: config, nodeId: nodeId, localTime: core.localTime()))
        skin = themeBg.apply(display: display, config: config, nodeId: nodeId, palette: palette,
                             httpPort: boot.httpPort, host: view)
        skin.apply("status_line", to: titleLabel)
        closeButton.backgroundColor = ColorRole.negative(palette)
        // The empty-video notice lives in the sidebar, not over the picture, so it follows the
        // sidebar's background rather than the video's black frame.
        skin.apply("hint", to: emptyLabel, quiet: true)
        for view in deviceStack.arrangedSubviews {
            guard let button = view as? UIButton else { continue }
            button.setTitleColor(skin.cardInk("tile_label"), for: .normal)
            button.backgroundColor = skin.surfaceStrong
        }
    }

    private func confirmedDoorPeers() -> [[String: Any]] {
        guard let peers = core.status()?["peers"] as? [[String: Any]] else { return [] }
        return peers.filter {
            ConfigUtil.evStr($0, "role") == "door_station" &&
                ConfigUtil.evStr($0, "status") != "dead" &&
                ConfigUtil.peerHost($0) != nil && ConfigUtil.str($0, "stream") != nil
        }.sorted { ConfigUtil.evStr($0, "name") < ConfigUtil.evStr($1, "name") }
    }

    private func rebuildDevices() {
        for child in deviceStack.arrangedSubviews { child.removeFromSuperview() }
        let peers = confirmedDoorPeers()
        emptyLabel.isHidden = !peers.isEmpty
        for peer in peers.prefix(8) {
            let button = UIButton(type: .system)
            let name = ConfigUtil.evStr(peer, "name")
            button.setTitle(name.isEmpty ? ConfigUtil.evStr(peer, "id") : name, for: .normal)
            button.setTitleColor(skin.cardInk("tile_label"), for: .normal)
            button.titleLabel?.font = TypeRole.body.font(weight: .medium, base: 19)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchTarget.minimum + 4)
                .isActive = true
            button.backgroundColor = skin.surfaceStrong
            button.layer.cornerRadius = 10
            #if !os(tvOS)
            button.contentEdgeInsets = UIEdgeInsets(top: 13, left: 14, bottom: 13, right: 14)
            #endif
            button.accessibilityIdentifier = ConfigUtil.evStr(peer, "id")
            button.addTarget(self, action: #selector(selectDevice(_:)), for: .primaryActionTriggered)
            deviceStack.addArrangedSubview(button)
        }
        // Restarting here on every peers_changed is what produced the retry storm: no video
        // frame meant "start again", and starting again is what kept the door too busy to send
        // one. The first open picks a door; after that only the user does.
        if selectedPeerId.isEmpty, let first = Self.preferredPeer(peers, door: initialDoor) {
            start(peer: first)
        }
    }

    static func preferredPeer(_ peers: [[String: Any]], door: String?) -> [String: Any]? {
        if let door = door, !door.isEmpty,
           let match = peers.first(where: { ConfigUtil.evStr($0, "door") == door }) {
            return match
        }
        return peers.first
    }

    @objc private func selectDevice(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier,
              let peer = confirmedDoorPeers().first(where: { ConfigUtil.evStr($0, "id") == id })
        else { return }
        start(peer: peer)
    }

    /// A deliberate request: the page opening, or the user choosing a door. It clears whatever
    /// the last door taught the policy, because this is a different question being asked.
    private func start(peer: [String: Any]) {
        cancelMonitorRetry()
        monitorRetry.reset()
        monitorWanted = true
        selectedPeerId = ConfigUtil.evStr(peer, "id")
        videoPlayer?.stop()
        videoPlayer = nil
        video.image = nil
        let name = ConfigUtil.evStr(peer, "name")
        titleLabel.text = texts.t("monitor.title", name)
        let mjpeg = ConfigUtil.str(peer, "stream") ?? ""
        let h264 = ConfigUtil.str(peer, "stream_mp4") ?? ""
        videoPlayer = AdaptiveH264MjpegPlayer(h264Host: h264View, mjpegView: video,
                                              noVideoLabel: emptyLabel)
        videoPlayer?.start(h264URLString: h264, mjpegURL: mjpeg, h264Enabled: !safeMode)
        if monitoringAudio { core.sipHangup() }
        monitoringAudio = false
        openMonitorDialog(peer: peer)
        scheduleControlsHide()
    }

    /// Opens one listen dialog, if the policy still allows one. A door that has said it has no
    /// microphone is not asked again until somebody selects it by hand.
    private func openMonitorDialog(peer: [String: Any]) {
        guard core.sipBackend == "pjsip", monitorRetry.mayAttempt(wanted: monitorWanted),
              let host = ConfigUtil.peerHost(peer) else { return }
        if ConfigUtil.dig(peer, "capabilities.audio") != nil,
           !ConfigUtil.bool(peer, "capabilities.audio", true) {
            _ = monitorRetry.nextDelay(after: .doorHasNoAudio)
            return
        }
        let port = ConfigUtil.int(core.config(), "sip.direct_port", 47190)
        monitorStartedAt = Date().timeIntervalSince1970
        monitorReachedInCall = false
        core.sipCall(target: "sip:\(host):\(port)", mode: "monitor")
        monitoringAudio = true
    }

    /// One dialog is over. A listen that carried nothing gets a longer wait than the last one; a
    /// listen that carried audio resets the wait entirely.
    private func monitorDialogEnded() {
        guard monitoringAudio else { return }
        monitoringAudio = false
        let lasted = Date().timeIntervalSince1970 - monitorStartedAt
        let outcome: MonitorRetryPolicy.Outcome
        if !monitorReachedInCall {
            outcome = .refused
        } else if lasted < MonitorViewController.silentDialogS {
            outcome = .endedWithoutMedia
        } else {
            outcome = .carriedAudio
        }
        guard let delay = monitorRetry.nextDelay(after: outcome), monitorWanted else { return }
        cancelMonitorRetry()
        monitorRetryTimer = IOSAvailability.scheduledTimer(withTimeInterval: delay,
                                                           repeats: false) { [weak self] _ in
            guard let self = self, self.monitorWanted else { return }
            guard let peer = self.confirmedDoorPeers().first(where: {
                ConfigUtil.evStr($0, "id") == self.selectedPeerId
            }) else { return }
            self.openMonitorDialog(peer: peer)
        }
    }

    private func cancelMonitorRetry() {
        monitorRetryTimer?.invalidate()
        monitorRetryTimer = nil
    }

    @objc private func close() { dismiss(animated: true) }
}
