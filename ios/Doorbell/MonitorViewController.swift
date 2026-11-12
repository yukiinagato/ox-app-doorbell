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

    private let navBar = UINavigationBar()
    private let navItem = UINavigationItem()
    private let videoBackdrop = UIView()
    /// Pinch, drag and double-tap zoom for the live picture, whichever renderer is drawing it.
    private let videoZoom = ZoomableVideoView()
    private let video = UIImageView()
    private let h264View = UIView()
    private let emptyLabel = UILabel()
    private let doorList = UITableView(frame: .zero, style: SystemStyle.tableStyle())
    private let closeButton = UIButton(type: .system)
    private var peers: [[String: Any]] = []

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
        view.backgroundColor = SystemStyle.background
        texts.setLang(boot.uiLang)
        config = core.config()
        texts.setConfig(config)
        if let node = core.status()?["node"] as? [String: Any] {
            nodeId = ConfigUtil.evStr(node, "id")
        }
        buildUi()
        rebuildDevices()
        core.addHandler("active-monitor") { [weak self] event in
            let type = ConfigUtil.evStr(event, "t")
            if type == "peers_changed" || type == "config_changed" {
                self?.config = self?.core.config()
                self?.rebuildDevices()
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
        videoZoom.resetZoom()
        emptyLabel.isHidden = false
        // Monitoring audio and the Close control remain available until the user exits.
    }

    private func buildUi() {
        // A stock navigation bar carries the door's name and Close. It is hosted directly because
        // this controller itself has to stay the presented screen: the call router looks for it.
        navItem.title = texts.t("monitor.choose")
        closeButton.setTitle(texts.t("monitor.close"), for: .normal)
        closeButton.titleLabel?.font = SystemStyle.font(.body, weight: .semibold)
        closeButton.accessibilityIdentifier = "monitor_close"
        closeButton.addTarget(self, action: #selector(close), for: .primaryActionTriggered)
        #if os(iOS)
        navItem.leftBarButtonItem = UIBarButtonItem(customView: closeButton)
        navBar.delegate = self
        #endif
        navBar.items = [navItem]
        navBar.translatesAutoresizingMaskIntoConstraints = false

        videoBackdrop.backgroundColor = .black
        videoBackdrop.clipsToBounds = true
        videoBackdrop.accessibilityIdentifier = "monitor_video"
        videoBackdrop.accessibilityHint = texts.t("ring.video_zoom_hint")
        videoBackdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoBackdrop)
        videoZoom.translatesAutoresizingMaskIntoConstraints = false
        videoBackdrop.addSubview(videoZoom)
        video.contentMode = .scaleAspectFit
        videoZoom.host(video)
        videoZoom.host(h264View)

        emptyLabel.text = texts.t("ring.no_video")
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.font = SystemStyle.font(.title3)
        emptyLabel.textColor = UIColor(white: 1, alpha: 0.6)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        videoBackdrop.addSubview(emptyLabel)

        // Door switcher: a list under the picture on compact windows, beside it on wider ones.
        SystemStyle.style(doorList)
        doorList.dataSource = self
        doorList.delegate = self
        doorList.accessibilityIdentifier = "monitor_doors"
        doorList.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(doorList)
        view.addSubview(navBar)
        #if os(tvOS)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        #endif

        // Tapping the picture brings hidden controls back (ui-guidelines section 4, live view).
        // The single tap waits for the zoom's double tap, so zooming never toggles the controls.
        let tap = UITapGestureRecognizer(target: self, action: #selector(showControls))
        #if os(iOS)
        tap.require(toFail: videoZoom.doubleTap)
        #endif
        videoBackdrop.addGestureRecognizer(tap)

        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: guide.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoZoom.topAnchor.constraint(equalTo: videoBackdrop.topAnchor),
            videoZoom.bottomAnchor.constraint(equalTo: videoBackdrop.bottomAnchor),
            videoZoom.leadingAnchor.constraint(equalTo: videoBackdrop.leadingAnchor),
            videoZoom.trailingAnchor.constraint(equalTo: videoBackdrop.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: videoBackdrop.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: videoBackdrop.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: videoBackdrop.widthAnchor,
                                              constant: -Space.l),
            videoBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            doorList.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            doorList.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        #if os(tvOS)
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            closeButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
        #endif
        sideConstraints = [
            videoBackdrop.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            videoBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoBackdrop.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.68),
            doorList.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            doorList.leadingAnchor.constraint(equalTo: videoBackdrop.trailingAnchor),
        ]
        stackedConstraints = [
            videoBackdrop.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            videoBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoBackdrop.heightAnchor.constraint(equalTo: videoBackdrop.widthAnchor,
                                                  multiplier: 9.0 / 16.0),
            doorList.topAnchor.constraint(equalTo: videoBackdrop.bottomAnchor),
            doorList.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        ]
        immersiveConstraints = [
            videoBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
            videoBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            doorList.topAnchor.constraint(equalTo: view.bottomAnchor),
            doorList.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        ]
        applyArrangement(for: view.bounds.size)
    }

    private var sideConstraints: [NSLayoutConstraint] = []
    private var stackedConstraints: [NSLayoutConstraint] = []
    private var immersiveConstraints: [NSLayoutConstraint] = []
    private var controlsHidden = false
    private var hideTimer: Timer?

    /// Video beside the list on wide windows, above it on compact ones, or alone once the
    /// controls have hidden themselves.
    private func applyArrangement(for size: CGSize) {
        NSLayoutConstraint.deactivate(sideConstraints + stackedConstraints + immersiveConstraints)
        let side = LayoutClass.sideBySide(size)
        if controlsHidden {
            NSLayoutConstraint.activate(immersiveConstraints)
        } else {
            NSLayoutConstraint.activate(side ? sideConstraints : stackedConstraints)
        }
        navBar.alpha = controlsHidden ? 0 : 1
        doorList.alpha = controlsHidden ? 0 : 1
        navBar.isUserInteractionEnabled = !controlsHidden
        doorList.isUserInteractionEnabled = !controlsHidden
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
            guard let self = self, self.videoPlayer != nil,
                  !UIAccessibility.isVoiceOverRunning else { return }
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

    private func confirmedDoorPeers() -> [[String: Any]] {
        guard let peers = core.status()?["peers"] as? [[String: Any]] else { return [] }
        return peers.filter {
            ConfigUtil.evStr($0, "role") == "door_station" &&
                ConfigUtil.evStr($0, "status") != "dead" &&
                ConfigUtil.peerHost($0) != nil && ConfigUtil.str($0, "stream") != nil
        }.sorted { ConfigUtil.evStr($0, "name") < ConfigUtil.evStr($1, "name") }
    }

    private func rebuildDevices() {
        peers = Array(confirmedDoorPeers().prefix(8))
        doorList.reloadData()
        if videoPlayer == nil { emptyLabel.isHidden = false }
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
        // A different door is a different picture: the zoom starts over.
        videoZoom.resetZoom()
        let name = ConfigUtil.evStr(peer, "name")
        navItem.title = texts.t("monitor.title", name)
        doorList.reloadData()
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

extension MonitorViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return peers.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return texts.t("monitor.choose")
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return peers.isEmpty ? texts.t("ring.no_video") : nil
    }

    func tableView(_ tableView: UITableView,
                   cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        SystemStyle.style(cell)
        let peer = peers[indexPath.row]
        let id = ConfigUtil.evStr(peer, "id")
        let name = ConfigUtil.evStr(peer, "name")
        cell.textLabel?.text = name.isEmpty ? id : name
        cell.imageView?.image = TablerIcon.image("TablerDoor")
        cell.accessoryType = id == selectedPeerId ? .checkmark : .none
        cell.accessibilityIdentifier = id
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < peers.count else { return }
        start(peer: peers[indexPath.row])
    }
}

#if os(iOS)
extension MonitorViewController: UINavigationBarDelegate {
    func position(for bar: UIBarPositioning) -> UIBarPosition { return .topAttached }
}
#endif
