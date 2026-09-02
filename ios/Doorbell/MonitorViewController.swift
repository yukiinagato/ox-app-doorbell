import UIKit

/// Active monitoring uses only peers that Core has confirmed as live door stations.
/// Seed addresses are never promoted to a role by the shell.
final class MonitorViewController: UIViewController {
    private let core: CoreBridge
    private let boot: BootConfig
    private let texts = Texts()
    private let styleApplier = UIStyleApplier()
    private var nodeId = ""
    private var config: [String: Any]?
    private var videoPlayer: AdaptiveH264MjpegPlayer?
    private var monitoringAudio = false
    private var safeMode = UserDefaults.standard.bool(forKey: "runtime.safe_mode")

    private let themeBg = ThemeBackgroundView()
    private let videoBackdrop = UIView()
    private let video = UIImageView()
    private let h264View = UIView()
    private let titleLabel = UILabel()
    private let emptyLabel = UILabel()
    private let deviceStack = UIStackView()
    private let closeButton = UIButton(type: .system)
    private var skin = DoorbellSkin.plain(.dark)

    init(core: CoreBridge, boot: BootConfig) {
        self.core = core
        self.boot = boot
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
        videoPlayer?.stop()
        videoPlayer = nil
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
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.numberOfLines = 2

        emptyLabel.text = texts.t("ring.no_video")
        emptyLabel.textAlignment = .center

        deviceStack.axis = .vertical
        deviceStack.spacing = 12

        closeButton.setTitle(texts.t("monitor.close"), for: .normal)
        closeButton.accessibilityIdentifier = "monitor_close"
        closeButton.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.backgroundColor = UIColor(red: 0.72, green: 0.15, blue: 0.12, alpha: 1)
        closeButton.layer.cornerRadius = 12
        #if !os(tvOS)
        closeButton.contentEdgeInsets = UIEdgeInsets(top: 14, left: 30, bottom: 14, right: 30)
        #endif
        closeButton.addTarget(self, action: #selector(close), for: .primaryActionTriggered)

        let sidebar = UIStackView(arrangedSubviews: [titleLabel, deviceStack, emptyLabel,
                                                      UIView(), closeButton])
        sidebar.axis = .vertical
        sidebar.spacing = 18
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)

        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            themeBg.topAnchor.constraint(equalTo: view.topAnchor),
            themeBg.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            themeBg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            themeBg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
            videoBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoBackdrop.trailingAnchor.constraint(equalTo: video.trailingAnchor),
            video.topAnchor.constraint(equalTo: guide.topAnchor),
            video.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            video.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            video.widthAnchor.constraint(equalTo: guide.widthAnchor, multiplier: 0.68),
            h264View.topAnchor.constraint(equalTo: video.topAnchor),
            h264View.bottomAnchor.constraint(equalTo: video.bottomAnchor),
            h264View.leadingAnchor.constraint(equalTo: video.leadingAnchor),
            h264View.trailingAnchor.constraint(equalTo: video.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: guide.topAnchor, constant: 24),
            sidebar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24),
            sidebar.leadingAnchor.constraint(equalTo: video.trailingAnchor, constant: 24),
            sidebar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
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
            button.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
            button.backgroundColor = skin.surfaceStrong
            button.layer.cornerRadius = 10
            #if !os(tvOS)
            button.contentEdgeInsets = UIEdgeInsets(top: 13, left: 14, bottom: 13, right: 14)
            #endif
            button.accessibilityIdentifier = ConfigUtil.evStr(peer, "id")
            button.addTarget(self, action: #selector(selectDevice(_:)), for: .primaryActionTriggered)
            deviceStack.addArrangedSubview(button)
        }
        if video.image == nil, let first = peers.first { start(peer: first) }
    }

    @objc private func selectDevice(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier,
              let peer = confirmedDoorPeers().first(where: { ConfigUtil.evStr($0, "id") == id })
        else { return }
        start(peer: peer)
    }

    private func start(peer: [String: Any]) {
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
        if core.sipBackend == "pjsip", let host = ConfigUtil.peerHost(peer) {
            let port = ConfigUtil.int(core.config(), "sip.direct_port", 47190)
            core.sipCall(target: "sip:\(host):\(port)", mode: "monitor")
            monitoringAudio = true
        }
    }

    @objc private func close() { dismiss(animated: true) }
}
