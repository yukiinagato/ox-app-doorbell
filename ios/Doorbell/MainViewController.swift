import AudioToolbox
import AVFoundation
import UIKit

final class MainViewController: UIViewController {

    private let core: CoreBridge
    private let boot: BootConfig
    private weak var runtime: RuntimeSupervisor?
    private let texts = Texts()
    private let styleApplier = UIStyleApplier()

    private var cfg: [String: Any]?
    private var nodeId = ""
    private var visitorLang = "ja"
    private var themeColor: String?
    private var themeHash: String?
    private let audio = SirenPlayer()
    private let callFeedbackAudio = SirenPlayer()
    private var callTitleOverride: String?

    private var brightness = 70
    private var night = false
    private var redTint = false
    private var screensaverAfterS = 120
    private var pixelShiftS = 300
    private var lastActivity = Date()
    private var screensaverOn = false

    private var emergencyActive = false
    private var sosHoldS = 3.0
    private var cancelRequiresPin = true
    private var sosDownAt = Date.distantPast
    private var sosHolding = false

    private var inCall = false
    private var peerPollBusy = false
    private var activeCallId = ""
    private var activeCallExpiresAtMs: Int64 = 0
    private var reportedRecoveryCallId = ""
    private var safeMode = UserDefaults.standard.bool(forKey: "runtime.safe_mode")
    private var chimeGate = CallChimeRevisionGate()
    private var h264EncoderFailed = false
    private var lastEncoderDemand: Bool?

    private lazy var camera = CameraFeeder(core: core) { [weak self] active, state in
        self?.runtime?.recordCameraRuntime(active: active, state: state)
    }
    private lazy var videoEncoder: VideoEncoderVT = {
        let encoder = VideoEncoderVT(core: core)
        encoder.runtimeStatus = { [weak self] available, state in
            guard let self = self else { return }
            if state == "session_failed" || state == "encode_failed" ||
                state == "invalid_output" || state == "failed" {
                self.h264EncoderFailed = true
            }
            self.runtime?.recordH264Encode(available: available, state: state)
        }
        return encoder
    }()

    private var secretTaps = 0
    private var secretFirst = Date.distantPast
    private var pairingObserver: NSObjectProtocol?

    private var clockTimer: Timer?
    private var callTimeoutTimer: Timer?
    private var replyTimer: Timer?
    private var pixelShiftTimer: Timer?
    private var saverDriftTimer: Timer?
    private var sosTimer: Timer?
    private var emergencyPresentationTimer: Timer?
    private var peerPollTimer: Timer?
    private var encoderPollTimer: Timer?

    private let themeBg = UIImageView()
    private let idleView = UIView()
    private let clockLabel = UILabel()
    private let dateLabel = UILabel()
    private let callButton = UIButton(type: .system)
    private let monitorButton = UIButton(type: .system)
    private let touchHint = UILabel()
    private let nodeInfo = UILabel()
    private let membershipLabel = UILabel()
    private let pairingBanner = UIButton(type: .system)
    private let appVersionLabel = UILabel()
    private let purposeSection = UIStackView()
    private let purposeHint = UILabel()
    private let purposeGrid = UIStackView()
    private let langBar = UIStackView()
    private let sosButton = UIButton(type: .custom)
    private let sosProgress = UIProgressView(progressViewStyle: .bar)
    private let callingView = UIView()
    private let pulse = UIView()
    private let callingText = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let inCallView = UIView()
    private let peerVideo = UIImageView()
    private let inCallTitle = UILabel()
    private let endCallButton = UIButton(type: .system)
    private let replyBanner = UIView()
    private let replyCaption = UILabel()
    private let replyText = UILabel()
    private let offlineView = UIView()
    private let offlineTitle = UILabel()
    private let offlineBody = UILabel()
    private let screensaverView = UIView()
    private let saverClock = UILabel()
    private let saverDate = UILabel()
    private let nightTint = UIView()
    private let emergencyView = UIView()
    private let emergencyTitle = UILabel()
    private let emergencyNote = UILabel()
    private let emergencyCancel = UIButton(type: .system)

    private static let bgColor = UIColor(red: 0.063, green: 0.078, blue: 0.094, alpha: 1)
    private static let fgColor = UIColor(white: 0.94, alpha: 1)
    private static let dimColor = UIColor(white: 0.62, alpha: 1)
    private static let cardColor = UIColor(white: 1, alpha: 0.10)
    private static let accentColor = UIColor(red: 1.0, green: 0.80, blue: 0.25, alpha: 1)
    private static let nightClock = UIColor(red: 0.545, green: 0.141, blue: 0.110, alpha: 1)
    private static let saverClockColor = UIColor(red: 0.224, green: 0.259, blue: 0.298, alpha: 1)

    init(core: CoreBridge, boot: BootConfig, runtime: RuntimeSupervisor?) {
        self.core = core
        self.boot = boot
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let observer = pairingObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }


    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MainViewController.bgColor
        visitorLang = boot.uiLang
        texts.setLang(visitorLang)
        buildUi()
        refreshNodeInfo()
        restoreActiveCallIfNeeded()
        if !core.isRunning { offlineView.isHidden = false }

        core.addHandler("main") { [weak self] ev in self?.onUiEvent(ev) }
        pairingObserver = NotificationCenter.default.addObserver(
            forName: .doorbellPairingChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPairingStatus() }
        refreshPairingStatus()

        clockTimer = IOSAvailability.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.onClockTick()
        }
        updateClock()
        encoderPollTimer = IOSAvailability.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.encoderPoll()
        }
        requestAvPermissionsThenStartCamera()
        encoderPoll()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applySemanticStyles()
    }

    func onActivity() {
        lastActivity = Date()
        exitScreensaver()
    }

    func enterSafeModeForMemoryPressure() {
        safeMode = true
        camera.encoder = nil
        videoEncoder.stop()
        camera.stop()
        themeBg.image = nil
        themeBg.isHidden = true
        // The SIP dialog and its End Call control must survive video memory pressure. Drop only
        // decoder/image state; the user can continue a pure-audio established call or hang it up.
        peerPollTimer?.invalidate()
        peerPollTimer = nil
        inCallStreamer?.stop()
        inCallStreamer = nil
        peerVideo.image = nil
        peerVideo.transform = .identity
        if inCall { inCallView.isHidden = false }
        maybeStartCamera()
    }


    private func buildUi() {
        themeBg.contentMode = .scaleAspectFill
        themeBg.clipsToBounds = true
        themeBg.isHidden = true
        addFull(themeBg)

        buildIdleView()
        buildCallingView()
        buildInCallView()
        buildReplyBanner()
        buildOfflineView()
        // Added before the screensaver, night tint and emergency overlay so those full-screen
        // states cover the banner instead of it floating on top of them.
        buildPairingBanner()
        buildScreensaver()

        nightTint.backgroundColor = UIColor(red: 1.0, green: 0.13, blue: 0.0, alpha: 0.20)
        nightTint.isUserInteractionEnabled = false
        nightTint.isHidden = true
        addFull(nightTint)

        buildEmergencyView()

        let secret = UIButton(type: .custom)
        secret.translatesAutoresizingMaskIntoConstraints = false
        secret.addTarget(self, action: #selector(onSecretCorner), for: .touchUpInside)
        view.addSubview(secret)
        NSLayoutConstraint.activate([
            secret.topAnchor.constraint(equalTo: view.topAnchor),
            secret.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            secret.widthAnchor.constraint(equalToConstant: 120),
            secret.heightAnchor.constraint(equalToConstant: 120),
        ])
    }

    /// Persistent, tappable reminder shown until Core reports state `ready`.
    private func buildPairingBanner() {
        pairingBanner.setTitle(texts.t("pair.not_set_up_banner"), for: .normal)
        pairingBanner.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        pairingBanner.titleLabel?.numberOfLines = 0
        pairingBanner.titleLabel?.textAlignment = .center
        pairingBanner.setTitleColor(.black, for: .normal)
        pairingBanner.backgroundColor = MainViewController.accentColor
        pairingBanner.layer.cornerRadius = 12
        pairingBanner.contentEdgeInsets = UIEdgeInsets(top: 12, left: 22, bottom: 12, right: 22)
        pairingBanner.accessibilityIdentifier = "pairing_banner"
        pairingBanner.isHidden = true
        pairingBanner.translatesAutoresizingMaskIntoConstraints = false
        pairingBanner.addTarget(self, action: #selector(onPairingBannerTap),
                                for: .touchUpInside)
        view.addSubview(pairingBanner)
        let g = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            pairingBanner.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            pairingBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pairingBanner.widthAnchor.constraint(lessThanOrEqualTo: g.widthAnchor, constant: -40),
        ])
    }

    @objc private func onPairingBannerTap() {
        NotificationCenter.default.post(name: .doorbellOpenPairing, object: nil)
    }

    /// Membership status doubles as the entry point to the Add-device panel, behind the admin
    /// password so a kiosk visitor cannot open it.
    @objc private func onMembershipTap() {
        guard presentedViewController == nil else { return }
        let dlg = AdminPinViewController(texts: texts)
        dlg.onUnlocked = { [weak self] in self?.showAddDevicePanel() }
        present(dlg, animated: true)
    }

    private func showAddDevicePanel() {
        guard presentedViewController == nil else { return }
        present(AddDeviceViewController(core: core, boot: boot, texts: texts), animated: true)
    }

    /// Renders the authoritative pairing snapshot into the membership line and the banner.
    private func refreshPairingStatus() {
        let snapshot = PairingSnapshot.load(core)
        guard snapshot.hasSnapshot else {
            membershipLabel.isHidden = true
            pairingBanner.isHidden = true
            return
        }
        membershipLabel.isHidden = false
        var text = texts.t("pair.membership", "\(max(snapshot.memberCount, snapshot.paired ? 1 : 0))")
        if snapshot.connectedCount > 0 {
            text += " · " + texts.t("pair.membership_connected", "\(snapshot.connectedCount)")
        }
        if snapshot.isFounder { text += " · " + texts.t("pair.created_badge") }
        if snapshot.state != .ready { text = texts.t("pair.not_set_up_banner") }
        membershipLabel.text = text
        pairingBanner.setTitle(texts.t("pair.not_set_up_banner"), for: .normal)
        pairingBanner.isHidden = snapshot.state == .ready
    }

    private func addFull(_ v: UIView, into parent: UIView? = nil) {
        let p = parent ?? view!
        v.translatesAutoresizingMaskIntoConstraints = false
        p.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: p.topAnchor),
            v.bottomAnchor.constraint(equalTo: p.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: p.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: p.trailingAnchor),
        ])
    }

    private func buildIdleView() {
        addFull(idleView)

        clockLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 84, weight: .light)
        clockLabel.textColor = MainViewController.fgColor
        clockLabel.textAlignment = .center

        dateLabel.font = .systemFont(ofSize: 24)
        dateLabel.textColor = MainViewController.dimColor
        dateLabel.textAlignment = .center

        callButton.titleLabel?.font = .systemFont(ofSize: 34, weight: .bold)
        callButton.setTitleColor(.black, for: .normal)
        callButton.backgroundColor = MainViewController.accentColor
        callButton.layer.cornerRadius = 18
        callButton.accessibilityIdentifier = "call_primary"
        callButton.contentEdgeInsets = UIEdgeInsets(top: 26, left: 60, bottom: 26, right: 60)
        callButton.addTarget(self, action: #selector(onCallClick), for: .touchUpInside)
        callButton.isHidden = boot.role != "door_station"

        monitorButton.titleLabel?.font = .systemFont(ofSize: 24, weight: .semibold)
        monitorButton.setTitleColor(MainViewController.fgColor, for: .normal)
        monitorButton.backgroundColor = MainViewController.cardColor
        monitorButton.layer.cornerRadius = 14
        monitorButton.contentEdgeInsets = UIEdgeInsets(top: 16, left: 36, bottom: 16, right: 36)
        monitorButton.addTarget(self, action: #selector(onMonitorOpen), for: .touchUpInside)
        monitorButton.isHidden = boot.role == "door_station"

        touchHint.font = .systemFont(ofSize: 20)
        touchHint.textColor = MainViewController.dimColor
        touchHint.textAlignment = .center
        touchHint.isHidden = boot.role != "door_station"

        purposeHint.font = .systemFont(ofSize: 20)
        purposeHint.textColor = MainViewController.dimColor
        purposeHint.textAlignment = .center
        purposeGrid.axis = .vertical
        purposeGrid.spacing = 12
        purposeGrid.alignment = .center
        purposeSection.axis = .vertical
        purposeSection.spacing = 12
        purposeSection.alignment = .center
        purposeSection.addArrangedSubview(purposeHint)
        purposeSection.addArrangedSubview(purposeGrid)

        langBar.axis = .horizontal
        langBar.spacing = 12
        langBar.alignment = .center

        let stack = UIStackView(arrangedSubviews: [clockLabel, dateLabel, callButton, touchHint,
                                                   monitorButton,
                                                   purposeSection, langBar])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .center
        IOSAvailability.setCustomSpacing(6, after: clockLabel, in: stack)
        IOSAvailability.setCustomSpacing(34, after: dateLabel, in: stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        idleView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: idleView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: idleView.centerYAnchor),
        ])

        nodeInfo.font = .systemFont(ofSize: 14)
        nodeInfo.textColor = UIColor(white: 1, alpha: 0.35)
        nodeInfo.translatesAutoresizingMaskIntoConstraints = false
        idleView.addSubview(nodeInfo)

        // The membership status is the visible, documented way into the Add-device panel; the
        // seven-tap corner stays only as a diagnostics shortcut.
        membershipLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        membershipLabel.textColor = UIColor(white: 1, alpha: 0.62)
        membershipLabel.isUserInteractionEnabled = true
        membershipLabel.accessibilityIdentifier = "membership_status"
        membershipLabel.translatesAutoresizingMaskIntoConstraints = false
        membershipLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(onMembershipTap)))
        idleView.addSubview(membershipLabel)

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        appVersionLabel.text = "APP v\(appVersion) (\(build))\nCore v…"
        appVersionLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        appVersionLabel.textColor = UIColor(white: 1, alpha: 0.78)
        appVersionLabel.backgroundColor = UIColor(white: 0, alpha: 0.28)
        appVersionLabel.layer.cornerRadius = 4
        appVersionLabel.clipsToBounds = true
        appVersionLabel.textAlignment = .left
        appVersionLabel.numberOfLines = 2
        appVersionLabel.accessibilityIdentifier = "app_version"
        appVersionLabel.translatesAutoresizingMaskIntoConstraints = false
        idleView.addSubview(appVersionLabel)

        sosButton.setTitle("SOS", for: .normal)
        sosButton.titleLabel?.font = .systemFont(ofSize: 24, weight: .heavy)
        sosButton.setTitleColor(.white, for: .normal)
        sosButton.backgroundColor = UIColor(red: 0.78, green: 0.16, blue: 0.12, alpha: 1)
        sosButton.layer.cornerRadius = 14
        sosButton.contentEdgeInsets = UIEdgeInsets(top: 18, left: 30, bottom: 18, right: 30)
        sosButton.translatesAutoresizingMaskIntoConstraints = false
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(onSosHold(_:)))
        hold.minimumPressDuration = 0.05
        sosButton.addGestureRecognizer(hold)
        idleView.addSubview(sosButton)

        sosProgress.progressTintColor = .white
        sosProgress.trackTintColor = UIColor(white: 1, alpha: 0.25)
        sosProgress.translatesAutoresizingMaskIntoConstraints = false
        idleView.addSubview(sosProgress)

        let g = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            membershipLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            membershipLabel.bottomAnchor.constraint(equalTo: nodeInfo.topAnchor, constant: -4),
            membershipLabel.trailingAnchor.constraint(lessThanOrEqualTo: g.trailingAnchor,
                                                      constant: -16),
            nodeInfo.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            nodeInfo.bottomAnchor.constraint(equalTo: appVersionLabel.topAnchor, constant: -4),
            appVersionLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            appVersionLabel.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -8),
            sosButton.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            sosButton.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -20),
            sosProgress.leadingAnchor.constraint(equalTo: sosButton.leadingAnchor),
            sosProgress.trailingAnchor.constraint(equalTo: sosButton.trailingAnchor),
            sosProgress.bottomAnchor.constraint(equalTo: sosButton.topAnchor, constant: -6),
        ])
    }

    private func buildCallingView() {
        callingView.backgroundColor = MainViewController.bgColor
        callingView.isHidden = true
        addFull(callingView)

        pulse.backgroundColor = MainViewController.accentColor
        pulse.layer.cornerRadius = 60
        pulse.translatesAutoresizingMaskIntoConstraints = false

        callingText.font = .systemFont(ofSize: 34, weight: .semibold)
        callingText.textColor = MainViewController.fgColor
        callingText.textAlignment = .center
        callingText.numberOfLines = 0

        cancelButton.titleLabel?.font = .systemFont(ofSize: 24)
        cancelButton.setTitleColor(MainViewController.fgColor, for: .normal)
        cancelButton.backgroundColor = MainViewController.cardColor
        cancelButton.layer.cornerRadius = 12
        cancelButton.contentEdgeInsets = UIEdgeInsets(top: 14, left: 40, bottom: 14, right: 40)
        cancelButton.addTarget(self, action: #selector(onCancelClick), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [pulse, callingText, cancelButton])
        stack.axis = .vertical
        stack.spacing = 30
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        callingView.addSubview(stack)
        NSLayoutConstraint.activate([
            pulse.widthAnchor.constraint(equalToConstant: 120),
            pulse.heightAnchor.constraint(equalToConstant: 120),
            stack.centerXAnchor.constraint(equalTo: callingView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: callingView.centerYAnchor),
        ])
    }

    private func buildInCallView() {
        inCallView.backgroundColor = .black
        inCallView.isHidden = true
        addFull(inCallView)

        peerVideo.contentMode = .scaleAspectFit
        addFull(peerVideo, into: inCallView)

        inCallTitle.font = .systemFont(ofSize: 24, weight: .semibold)
        inCallTitle.textColor = MainViewController.fgColor
        inCallTitle.translatesAutoresizingMaskIntoConstraints = false
        inCallView.addSubview(inCallTitle)

        endCallButton.titleLabel?.font = .systemFont(ofSize: 24, weight: .semibold)
        endCallButton.setTitleColor(.white, for: .normal)
        endCallButton.backgroundColor = UIColor(red: 0.78, green: 0.16, blue: 0.12, alpha: 1)
        endCallButton.layer.cornerRadius = 12
        endCallButton.contentEdgeInsets = UIEdgeInsets(top: 14, left: 44, bottom: 14, right: 44)
        endCallButton.addTarget(self, action: #selector(onEndCallClick), for: .touchUpInside)
        endCallButton.translatesAutoresizingMaskIntoConstraints = false
        inCallView.addSubview(endCallButton)

        let g = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            inCallTitle.topAnchor.constraint(equalTo: g.topAnchor, constant: 18),
            inCallTitle.centerXAnchor.constraint(equalTo: inCallView.centerXAnchor),
            endCallButton.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -24),
            endCallButton.centerXAnchor.constraint(equalTo: inCallView.centerXAnchor),
        ])
    }

    private func buildReplyBanner() {
        replyBanner.backgroundColor = UIColor(red: 0.11, green: 0.30, blue: 0.16, alpha: 0.97)
        replyBanner.layer.cornerRadius = 16
        replyBanner.isHidden = true
        replyBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(replyBanner)

        replyCaption.font = .systemFont(ofSize: 18)
        replyCaption.textColor = UIColor(white: 1, alpha: 0.7)
        replyText.font = .systemFont(ofSize: 34, weight: .bold)
        replyText.textColor = .white
        replyText.numberOfLines = 0
        replyText.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [replyCaption, replyText])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        replyBanner.addSubview(stack)

        let g = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            replyBanner.topAnchor.constraint(equalTo: g.topAnchor, constant: 20),
            replyBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            replyBanner.widthAnchor.constraint(lessThanOrEqualTo: g.widthAnchor, constant: -40),
            stack.topAnchor.constraint(equalTo: replyBanner.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: replyBanner.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: replyBanner.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: replyBanner.trailingAnchor, constant: -28),
        ])
    }

    private func buildOfflineView() {
        offlineView.backgroundColor = MainViewController.bgColor
        offlineView.isHidden = true
        addFull(offlineView)
        offlineTitle.font = .systemFont(ofSize: 34, weight: .bold)
        offlineTitle.textColor = MainViewController.fgColor
        offlineTitle.textAlignment = .center
        offlineBody.font = .systemFont(ofSize: 22)
        offlineBody.textColor = MainViewController.dimColor
        offlineBody.textAlignment = .center
        offlineBody.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [offlineTitle, offlineBody])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        offlineView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: offlineView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: offlineView.centerYAnchor),
        ])
    }

    private func buildScreensaver() {
        screensaverView.backgroundColor = .black
        screensaverView.isHidden = true
        addFull(screensaverView)
        saverClock.font = UIFont.monospacedDigitSystemFont(ofSize: 64, weight: .light)
        saverClock.textColor = MainViewController.saverClockColor
        saverDate.font = .systemFont(ofSize: 20)
        saverDate.textColor = MainViewController.saverClockColor
        let stack = UIStackView(arrangedSubviews: [saverClock, saverDate])
        stack.axis = .vertical
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        screensaverView.addSubview(stack)
        saverCenterX = stack.centerXAnchor.constraint(equalTo: screensaverView.centerXAnchor)
        saverCenterY = stack.centerYAnchor.constraint(equalTo: screensaverView.centerYAnchor)
        NSLayoutConstraint.activate([saverCenterX!, saverCenterY!])
    }

    private var saverCenterX: NSLayoutConstraint?
    private var saverCenterY: NSLayoutConstraint?

    private func buildEmergencyView() {
        emergencyView.backgroundColor = UIColor(red: 0.55, green: 0.05, blue: 0.04, alpha: 1)
        emergencyView.isHidden = true
        addFull(emergencyView)
        emergencyTitle.font = .systemFont(ofSize: 64, weight: .heavy)
        emergencyTitle.textColor = .white
        emergencyTitle.textAlignment = .center
        emergencyNote.font = .systemFont(ofSize: 26)
        emergencyNote.textColor = UIColor(white: 1, alpha: 0.85)
        emergencyNote.textAlignment = .center
        emergencyNote.numberOfLines = 0
        emergencyCancel.titleLabel?.font = .systemFont(ofSize: 26, weight: .semibold)
        emergencyCancel.setTitleColor(UIColor(red: 0.55, green: 0.05, blue: 0.04, alpha: 1),
                                      for: .normal)
        emergencyCancel.backgroundColor = .white
        emergencyCancel.layer.cornerRadius = 14
        emergencyCancel.contentEdgeInsets = UIEdgeInsets(top: 16, left: 48, bottom: 16, right: 48)
        emergencyCancel.addTarget(self, action: #selector(onEmergencyCancel), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [emergencyTitle, emergencyNote, emergencyCancel])
        stack.axis = .vertical
        stack.spacing = 30
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        emergencyView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emergencyView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emergencyView.centerYAnchor),
        ])
    }


    private func applyStrings() {
        callButton.setTitle(
            texts.t("idle.call_button", doorLabel(boot.door))
                .trimmingCharacters(in: .whitespaces), for: .normal)
        touchHint.text = texts.t("idle.touch_to_call")
        monitorButton.setTitle(texts.t("monitor.open"), for: .normal)
        purposeHint.text = texts.t("idle.choose_purpose")
        callingText.text = callTitleOverride ?? texts.t("calling.title")
        cancelButton.setTitle(texts.t("calling.cancel"), for: .normal)
        replyCaption.text = texts.t("reply.banner")
        offlineTitle.text = texts.t("offline.title")
        offlineBody.text = texts.t("offline.body")
        sosButton.setTitle(texts.t("emergency.button"), for: .normal)
        sosButton.accessibilityHint = texts.t("emergency.hold_hint", "\(sosHoldS)")
        inCallTitle.text = texts.t("incall.title")
        endCallButton.setTitle(texts.t("incall.end"), for: .normal)
        emergencyTitle.text = texts.t("emergency.title")
        emergencyNote.text = texts.t("emergency.notified")
        emergencyCancel.setTitle(texts.t("emergency.cancel"), for: .normal)
        pairingBanner.setTitle(texts.t("pair.not_set_up_banner"), for: .normal)
    }

    private func doorLabel(_ door: String) -> String {
        if door.isEmpty { return "" }
        let entry = ConfigUtil.dig(cfg, "doors.\(door)") as? [String: Any]
        return ConfigUtil.labelOf(entry, texts.lang, door)
    }


    private func onClockTick() {
        updateClock()
        if !screensaverOn && !emergencyActive && screensaverAfterS > 0 &&
            !idleView.isHidden && callingView.isHidden && offlineView.isHidden &&
            inCallView.isHidden && presentedViewController == nil &&
            Date().timeIntervalSince(lastActivity) > Double(screensaverAfterS) {
            enterScreensaver()
        }
    }

    private func updateClock() {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: now)
        clockLabel.text = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0,
                                 c.second ?? 0)
        let yobi = ["日", "月", "火", "水", "木", "金", "土"]
        dateLabel.text = String(format: "%d年%d月%d日 (%@)", c.year ?? 0, c.month ?? 0,
                                c.day ?? 0, yobi[((c.weekday ?? 1) - 1) % 7])
        if screensaverOn {
            saverClock.text = clockLabel.text
            saverDate.text = dateLabel.text
        }
    }

    private func refreshNodeInfo() {
        refreshConfigCache()
        if let st = core.status() {
            if let node = st["node"] as? [String: Any] {
                nodeInfo.text = ConfigUtil.evStr(node, "name")
                let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
                let coreVersion = ConfigUtil.evStr(node, "version")
                appVersionLabel.text = "APP v\(appVersion) (\(build))\nCore v\(coreVersion.isEmpty ? "-" : coreVersion)"
                nodeId = ConfigUtil.evStr(node, "id")
            }
            // Display state is safe to restore directly. Emergency state is replicated even when
            // the administrator selected zero presentation channels, so only a rule-produced
            // device-alert event may restore its UI or sound.
            if let disp = st["display"] as? [String: Any] {
                applyDisplayValues(disp)
            }
            if let em = st["emergency"] as? [String: Any] {
                if !ConfigUtil.evBool(em, "active") { hideEmergency() }
            }
            if boot.role == "door_station" && !boot.door.isEmpty {
                let vl = ConfigUtil.str(st, "visitor_lang.\(boot.door)") ?? "ja"
                setVisitorLang(vl)
            }
        }
        refreshSosConfig()
        refreshPairingStatus()
        applyTheme()
        buildPurposeButtons()
        buildLangBar()
        applyStrings()
        applySemanticStyles()
    }

    private func applySemanticStyles() {
        let bindings: [(String, UIView)] = [
            ("call.primary", callButton), ("cancel.call", cancelButton),
            ("call.end", endCallButton), ("sos.trigger", sosButton),
            ("sos.cancel", emergencyCancel), ("status.offline", offlineTitle),
        ]
        for (id, view) in bindings {
            styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: id, to: view)
        }
        for row in purposeGrid.arrangedSubviews {
            for button in (row as? UIStackView)?.arrangedSubviews ?? [] {
                styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: "purpose.button",
                                   to: button)
            }
        }
    }

    func handleCallRecovery(_ event: [String: Any]) {
        restoreActiveCallIfNeeded(recoveryEvent: event)
    }

    private func restoreActiveCallIfNeeded() {
        restoreActiveCallIfNeeded(recoveryEvent: nil)
    }

    private func restoreActiveCallIfNeeded(recoveryEvent: [String: Any]?) {
        let requestedCallId = recoveryEvent.map { ConfigUtil.evStr($0, "call_id") } ?? ""
        guard !nodeId.isEmpty,
              let calls = core.status()?["active_calls"] as? [[String: Any]] else {
            if !requestedCallId.isEmpty { reportRecovery(requestedCallId, restored: false) }
            return
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for call in calls {
            let callDoor = ConfigUtil.evStr(call, "door")
            let callId = ConfigUtil.evStr(call, "call_id")
            if !requestedCallId.isEmpty && callId != requestedCallId { continue }
            let origin = ConfigUtil.evStr(call, "origin")
            let eventOwner = recoveryEvent.map { ConfigUtil.evStr($0, "dialog_owner") } ?? ""
            let owner = eventOwner.isEmpty ? ConfigUtil.evStr(call, "dialog_owner") : eventOwner
            let expiry = (call["expires_at_ms"] as? NSNumber)?.int64Value ?? 0
            guard !callId.isEmpty else { continue }

            let persistedState = ConfigUtil.evStr(call, "state")
            let eventState = recoveryEvent.map { ConfigUtil.evStr($0, "state") } ?? ""
            if persistedState == "in_call" || eventState == "in_call" {
                if owner != nodeId {
                    if !requestedCallId.isEmpty { return }
                    continue
                }
                // Native PJSIP dialogs do not survive a process/Core restart. A restored view is
                // not proof of an established audio dialog, so the owning node fails closed.
                reportRecovery(callId, restored: false)
                return
            }

            guard persistedState == "ringing" || eventState == "ringing" ||
                    eventState == "purpose_pending" else { continue }
            guard boot.role == "door_station", origin == nodeId,
                  (callDoor.isEmpty || callDoor == boot.door) else {
                if !requestedCallId.isEmpty { return }
                continue
            }
            guard expiry > nowMs else {
                reportRecovery(callId, restored: false)
                return
            }

            activeCallId = callId
            activeCallExpiresAtMs = expiry
            let sound = (ConfigUtil.dig(cfg, "ui.call_sound") as? String) ??
                "outdoor_call_alert"
            callFeedbackAudio.playConfigured(sound,
                loops: ConfigUtil.bool(cfg, "ui.call_sound_loop", false))
            showCalling()

            let callFlow = ConfigUtil.evStr(call, "call_flow")
            let revision = ConfigUtil.int(call, "stage_revision", 0)
            let purposePending = eventState == "purpose_pending" ||
                (callFlow == "ring_then_purpose" && revision == 0 &&
                 ConfigUtil.evStr(call, "purpose").isEmpty)
            if purposePending && !emergencyActive && !availablePurposeIds().isEmpty {
                showPurposeChoice(afterRing: true)
            }
            reportRecovery(callId, restored: true)
            return
        }

        if !requestedCallId.isEmpty { reportRecovery(requestedCallId, restored: false) }
    }

    private func reportRecovery(_ callId: String, restored: Bool) {
        guard !callId.isEmpty, reportedRecoveryCallId != callId else { return }
        reportedRecoveryCallId = callId
        core.reportCallRecovery(callId: callId, restored: restored)
    }

    private func refreshConfigCache() {
        cfg = core.config()
        texts.setConfig(cfg)
    }


    private func themeValue(_ leaf: String) -> String? {
        if !nodeId.isEmpty,
           let v = ConfigUtil.str(cfg, "devices.\(nodeId).local.theme.\(leaf)") {
            return v
        }
        return ConfigUtil.str(cfg, "display.theme.\(leaf)")
    }

    private func applyTheme() {
        let color = themeValue("bg_color")
        if color != themeColor {
            themeColor = color
            if let c = color, let rgb = ConfigUtil.parseHexColor(c) {
                view.backgroundColor = UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
            } else {
                view.backgroundColor = MainViewController.bgColor
            }
        }
        guard let hash = themeValue("bg_image"), !hash.isEmpty else {
            themeHash = nil
            themeBg.image = nil
            themeBg.isHidden = true
            return
        }
        if hash == themeHash && themeBg.image != nil { return }
        themeHash = hash
        loadThemeImage(hash)
    }

    private func loadThemeImage(_ hash: String) {
        let urlStr = "http://127.0.0.1:\(boot.httpPort)/asset/\(hash)"
        guard let url = URL(string: urlStr) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, resp, _ in
            guard let self = self, let data = data,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard self.themeHash == hash else { return }
                self.themeBg.image = img
                self.themeBg.isHidden = false
            }
        }.resume()
    }

    private func buildPurposeButtons() {
        for v in purposeGrid.arrangedSubviews { v.removeFromSuperview() }
        guard boot.role == "door_station",
              let purposes = ConfigUtil.dig(cfg, "visit_purposes") as? [String: Any],
              !purposes.isEmpty else {
            purposeSection.isHidden = true
            return
        }
        let ids = ConfigUtil.sortedByOrder(purposes)
        var row: UIStackView?
        for (i, id) in ids.enumerated() {
            if i % 3 == 0 {
                row = UIStackView()
                row!.axis = .horizontal
                row!.spacing = 12
                purposeGrid.addArrangedSubview(row!)
            }
            let entry = purposes[id] as? [String: Any]
            let label = ConfigUtil.labelOf(entry, texts.lang, id)
            let icon = entry?["icon"] as? String ?? ""
            let b = UIButton(type: .system)
            b.setTitle(icon.isEmpty ? label : "\(icon)\n\(label)", for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 20)
            b.titleLabel?.numberOfLines = 3
            b.titleLabel?.textAlignment = .center
            b.setTitleColor(MainViewController.fgColor, for: .normal)
            b.backgroundColor = MainViewController.cardColor
            b.layer.cornerRadius = 12
            b.widthAnchor.constraint(equalToConstant: 176).isActive = true
            b.heightAnchor.constraint(equalToConstant: 92).isActive = true
            b.accessibilityIdentifier = "purpose_\(id)"
            b.addTarget(self, action: #selector(onPurposeClick(_:)), for: .touchUpInside)
            row!.addArrangedSubview(b)
        }
        purposeSection.isHidden = false
    }

    @objc private func onPurposeClick(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier?.dropFirst("purpose_".count) else { return }
        let purposeId = String(id)
        let purposes = ConfigUtil.dig(cfg, "visit_purposes") as? [String: Any]
        let label = ConfigUtil.labelOf(purposes?[purposeId] as? [String: Any], texts.lang,
                                       purposeId)
        if activeCallId.isEmpty {
            beginCall(purpose: purposeId, title: texts.t("purpose.sent", label))
            return
        } else if !core.selectPurpose(door: boot.door, callId: activeCallId,
                                      purpose: purposeId) {
            showIdle(hint: texts.t("calling.no_answer"))
            return
        }
        showCalling(title: texts.t("purpose.sent", label))
    }

    private func buildLangBar() {
        for v in langBar.arrangedSubviews { v.removeFromSuperview() }
        var list: [String] = []
        if let langs = ConfigUtil.dig(cfg, "ui.languages") as? [Any] {
            for l in langs {
                if let s = l as? String, !s.isEmpty { list.append(s) }
            }
        }
        guard boot.role == "door_station", list.count >= 2 else {
            langBar.isHidden = true
            return
        }
        for lang in list {
            let b = UIButton(type: .system)
            b.setTitle(Texts.langDisplayName(lang), for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 20)
            b.layer.cornerRadius = 10
            b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 22, bottom: 8, right: 22)
            b.accessibilityIdentifier = "lang_\(lang)"
            b.addTarget(self, action: #selector(onLangClick(_:)), for: .touchUpInside)
            langBar.addArrangedSubview(b)
        }
        langBar.isHidden = false
        updateLangBarSelection()
    }

    private func updateLangBarSelection() {
        for v in langBar.arrangedSubviews {
            guard let b = v as? UIButton,
                  let lang = b.accessibilityIdentifier?.dropFirst("lang_".count) else { continue }
            let on = String(lang) == visitorLang
            b.backgroundColor = on ? MainViewController.accentColor : MainViewController.cardColor
            b.setTitleColor(on ? .black : MainViewController.dimColor, for: .normal)
        }
    }

    @objc private func onLangClick(_ sender: UIButton) {
        guard let lang = sender.accessibilityIdentifier?.dropFirst("lang_".count) else { return }
        core.setVisitorLang(door: boot.door, lang: String(lang))
        setVisitorLang(String(lang))
    }

    private func setVisitorLang(_ lang: String) {
        let l = lang.isEmpty ? "ja" : lang
        if visitorLang == l { return }
        visitorLang = l
        texts.setLang(l)
        applyStrings()
        buildPurposeButtons()
        updateLangBarSelection()
    }


    private func applyDisplayValues(_ d: [String: Any]) {
        brightness = ConfigUtil.int(d, "brightness", brightness)
        night = ConfigUtil.evBool(d, "night")
        redTint = ConfigUtil.evBool(d, "red_tint")
        screensaverAfterS = ConfigUtil.int(d, "screensaver_after_s", screensaverAfterS)
        pixelShiftS = ConfigUtil.int(d, "pixel_shift_s", pixelShiftS)
        applyDisplay()
    }

    private func applyDisplay() {
        nightTint.isHidden = !(night && redTint)
        clockLabel.textColor = night ? MainViewController.nightClock : MainViewController.fgColor
        dateLabel.textColor = night ? MainViewController.nightClock : MainViewController.dimColor
        saverClock.textColor = night ? MainViewController.nightClock
                                     : MainViewController.saverClockColor

        pixelShiftTimer?.invalidate()
        pixelShiftTimer = nil
        if pixelShiftS > 0 {
            pixelShiftTimer = IOSAvailability.scheduledTimer(withTimeInterval: Double(pixelShiftS),
                                                   repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.idleView.transform = CGAffineTransform(
                    translationX: CGFloat(Int.random(in: -8...8)),
                    y: CGFloat(Int.random(in: -8...8)))
            }
        } else {
            idleView.transform = .identity
        }

        if !emergencyActive {
            setBrightness(screensaverOn ? min(brightness, 10) : brightness)
        }
    }

    private func setBrightness(_ percent: Int) {
        UIScreen.main.brightness = CGFloat(max(0, min(100, percent))) / 100.0
    }


    private func enterScreensaver() {
        guard !screensaverOn else { return }
        screensaverOn = true
        updateClock()
        screensaverView.isHidden = false
        moveSaverClock()
        saverDriftTimer = IOSAvailability.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.moveSaverClock()
        }
        setBrightness(min(brightness, 10))
    }

    private func exitScreensaver() {
        guard screensaverOn else { return }
        screensaverOn = false
        saverDriftTimer?.invalidate()
        saverDriftTimer = nil
        screensaverView.isHidden = true
        if !emergencyActive { setBrightness(brightness) }
    }

    private func moveSaverClock() {
        let w = max(1, screensaverView.bounds.width * 0.5)
        let h = max(1, screensaverView.bounds.height * 0.5)
        saverCenterX?.constant = CGFloat.random(in: -w / 2...w / 2)
        saverCenterY?.constant = CGFloat.random(in: -h / 2...h / 2)
    }

    private func refreshSosConfig() {
        var show = boot.role == "indoor_panel"
        if let roles = ConfigUtil.dig(cfg, "emergency.button_on_roles") as? [Any] {
            show = roles.contains { ($0 as? String) == boot.role }
        }
        sosButton.isHidden = !show
        sosProgress.isHidden = !show
        sosHoldS = ConfigUtil.double(cfg, "emergency.hold_to_trigger_s", 3)
        if sosHoldS <= 0 { sosHoldS = 3 }
        cancelRequiresPin = ConfigUtil.bool(cfg, "emergency.cancel_requires_pin", true)
    }

    @objc private func onSosHold(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            sosDownAt = Date()
            sosHolding = true
            sosProgress.progress = 0
            sosTimer?.invalidate()
            sosTimer = IOSAvailability.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.onSosTick()
            }
        case .ended, .cancelled, .failed:
            resetSosHold()
        default:
            break
        }
    }

    private func onSosTick() {
        guard sosHolding else {
            sosTimer?.invalidate()
            sosTimer = nil
            return
        }
        let held = Date().timeIntervalSince(sosDownAt)
        sosProgress.progress = Float(min(1, held / sosHoldS))
        if held >= sosHoldS {
            resetSosHold()
            core.emergency(true)
        }
    }

    private func resetSosHold() {
        sosHolding = false
        sosTimer?.invalidate()
        sosTimer = nil
        sosProgress.progress = 0
    }

    private func presentEmergency(_ ev: [String: Any]) {
        emergencyPresentationTimer?.invalidate()
        emergencyPresentationTimer = nil
        guard ConfigUtil.evBool(ev, "active") else { hideEmergency(); return }
        guard ConfigUtil.eventUsesChannel(ev, "in_app") else { hideEmergency(); return }
        let palette = ConfigUtil.emergencyPalette(ev)
        emergencyView.backgroundColor = palette.background
        emergencyTitle.textColor = palette.foreground
        emergencyNote.textColor = palette.foreground
        emergencyCancel.backgroundColor = palette.accent
        emergencyCancel.setTitleColor(ConfigUtil.readableTextColor(on: palette.accent),
                                      for: .normal)
        let visual = ev["visual"] == nil ? true : ConfigUtil.evBool(ev, "visual")
        showEmergency(visual: visual)
        let sound = ConfigUtil.evStr(ev, "alarm_sound")
        let path = ConfigUtil.evStr(ev, "audio_path")
        let volume = ConfigUtil.int(ev, "alarm_volume", 100)
        if volume > 0 && (!sound.isEmpty || !path.isEmpty) {
            audio.startSiren(customPath: path, volume: volume)
        } else {
            audio.stop()
        }
        if !ConfigUtil.evBool(ev, "sticky") {
            let ttl = ConfigUtil.double(ev, "ttl_s", 0)
            if ttl > 0 {
                emergencyPresentationTimer = IOSAvailability.scheduledTimer(
                    withTimeInterval: ttl, repeats: false) { [weak self] _ in
                        self?.hideEmergency()
                    }
            }
        }
    }

    private func showEmergency(visual: Bool) {
        if emergencyActive {
            emergencyView.isHidden = !visual
            return
        }
        emergencyActive = true
        exitScreensaver()
        callTimeoutTimer?.invalidate()
        callingView.isHidden = true
        replyBanner.isHidden = true
        if visual {
            presentedViewController?.dismiss(animated: false)
            emergencyView.isHidden = false
            setBrightness(100)
        } else {
            emergencyView.isHidden = true
        }
    }

    private func hideEmergency() {
        guard emergencyActive else { return }
        emergencyActive = false
        emergencyPresentationTimer?.invalidate()
        emergencyPresentationTimer = nil
        audio.stop()
        emergencyView.isHidden = true
        showIdle()
        lastActivity = Date()
        applyDisplay()
    }

    @objc private func onEmergencyCancel() {
        if cancelRequiresPin {
            let dlg = AdminPinViewController(texts: texts)
            dlg.onUnlocked = { [weak self] in
                guard let self = self, self.core.emergency(false) else { return }
                self.hideEmergency()
            }
            present(dlg, animated: true)
            return
        }
        if core.emergency(false) { hideEmergency() }
    }


    private func showIdle(hint: String? = nil) {
        callFeedbackAudio.stop()
        callTitleOverride = nil
        callTimeoutTimer?.invalidate()
        pulse.layer.removeAllAnimations()
        callingView.isHidden = true
        offlineView.isHidden = true
        idleView.isHidden = false
        activeCallId = ""
        activeCallExpiresAtMs = 0
        if let h = hint { touchHint.text = h }
    }

    private func coreExpiryForActiveCall() -> Int64 {
        guard !activeCallId.isEmpty,
              let calls = core.status()?["active_calls"] as? [[String: Any]] else { return 0 }
        for call in calls where ConfigUtil.evStr(call, "call_id") == activeCallId {
            if let number = call["expires_at_ms"] as? NSNumber {
                return number.int64Value
            }
            if let value = call["expires_at_ms"] as? String {
                return Int64(value) ?? 0
            }
        }
        return 0
    }

    private func showCalling(title: String? = nil) {
        exitScreensaver()
        if let t = title { callTitleOverride = t }
        callingText.text = callTitleOverride ?? texts.t("calling.title")
        idleView.isHidden = true
        callingView.isHidden = false
        callTimeoutTimer?.invalidate()
        if activeCallExpiresAtMs <= 0 { activeCallExpiresAtMs = coreExpiryForActiveCall() }
        if activeCallExpiresAtMs > 0 {
            let timeout = max(0.001,
                Double(activeCallExpiresAtMs) / 1000 - Date().timeIntervalSince1970)
            callTimeoutTimer = IOSAvailability.scheduledTimer(
                withTimeInterval: timeout, repeats: false
            ) { [weak self] _ in
                guard let self = self else { return }
                if !self.activeCallId.isEmpty {
                    _ = self.core.cancelCall(door: self.boot.door, callId: self.activeCallId,
                                             reason: "timeout")
                }
                self.showIdle(hint: self.texts.t("calling.no_answer"))
            }
        }
        pulse.layer.removeAllAnimations()
        if safeMode {
            pulse.alpha = 1
            return
        }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.25
        anim.toValue = 1.0
        anim.duration = 0.9
        anim.autoreverses = true
        anim.repeatCount = .infinity
        pulse.layer.add(anim, forKey: "pulse")
    }


    private func onUiEvent(_ ev: [String: Any]) {
        switch ConfigUtil.evStr(ev, "t") {
        case "state":
            let st = ConfigUtil.evStr(ev, "state")
            if st == "calling" {
                if boot.role == "door_station" { showCalling() }
            } else if st == "idle" {
                onSipIdle()
            } else if st == "in_call" || st == "answered" {
                callFeedbackAudio.stop()
                onSipInCall(ev)
            }
        case "chime":
            guard chimeGate.accept(callId: ConfigUtil.evStr(ev, "call_id"),
                                   stageRevision: ConfigUtil.int(ev, "stage_revision", 0))
            else { break }
            exitScreensaver()
            let path = ConfigUtil.evStr(ev, "audio_path")
            if path.isEmpty {
                audio.playConfigured(ConfigUtil.evStr(ev, "sound")) {
                    AudioServicesPlaySystemSound(1013)
                }
            } else {
                audio.playAsset(path: path) { AudioServicesPlaySystemSound(1013) }
            }
        case "reply":
            exitScreensaver()
            let path = ConfigUtil.evStr(ev, "audio_path")
            if !path.isEmpty {
                let spoken = ConfigUtil.evStr(ev, "text")
                let lang = ConfigUtil.evStr(ev, "lang")
                audio.playAsset(path: path) { [weak self] in
                    self?.core.speak(text: spoken, lang: lang)
                }
            }
            replyText.text = ConfigUtil.evStr(ev, "text")
            replyBanner.isHidden = false
            var ttl = ConfigUtil.double(ev, "ttl_s", 30)
            if ttl <= 0 { ttl = 30 }
            replyTimer?.invalidate()
            replyTimer = IOSAvailability.scheduledTimer(withTimeInterval: ttl, repeats: false) { [weak self] _ in
                self?.replyBanner.isHidden = true
            }
            callTimeoutTimer?.invalidate()
            showIdle()
        case "event":
            let type = ConfigUtil.evStr(ev, "type")
            let eventCall = ConfigUtil.evStr(ev, "call_id")
            if type == "press", !activeCallId.isEmpty, eventCall == activeCallId,
               let expiry = ev["expires_at_ms"] as? NSNumber, expiry.int64Value > 0 {
                activeCallExpiresAtMs = expiry.int64Value
                if !callingView.isHidden { showCalling() }
            }
            if (type == "call_cancelled" || type == "call_ended") &&
                (activeCallId.isEmpty || eventCall.isEmpty || eventCall == activeCallId) {
                showIdle(hint: type == "call_cancelled" ? texts.t("ring.cancelled") : nil)
            }
        case "visitor_lang":
            let door = ConfigUtil.evStr(ev, "door")
            if boot.role == "door_station" && (door.isEmpty || door == boot.door) {
                setVisitorLang(ConfigUtil.evStr(ev, "lang"))
            }
        case "asset_ready":
            if let h = themeHash, ConfigUtil.evStr(ev, "hash") == h, themeBg.image == nil {
                loadThemeImage(h)
            }
        case "display":
            applyDisplayValues(ev)
        case "emergency":
            presentEmergency(ev)
        case "peers_changed", "config_changed":
            refreshNodeInfo()
        case "pairing_state", "paired", "device_joined", "pairing_revoked", "pending_changed":
            refreshPairingStatus()
        default:
            break
        }
    }


    private func onSipInCall(_ ev: [String: Any]) {
        inCall = true
        callingText.text = texts.t("incall.title")
        guard boot.role == "door_station" else { return }
        callTimeoutTimer?.invalidate()
        let stream = ConfigUtil.evStr(ev, "peer_stream")
        peerPollTimer?.invalidate()
        peerPollTimer = nil
        showInCall(streamUrl: stream.isEmpty ? nil : stream)
        if stream.isEmpty && !safeMode {
            peerPollBusy = false
            peerPollTimer = IOSAvailability.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.pollPeerFrame()
            }
        }
    }

    private func onSipIdle() {
        inCall = false
        closeInCall()
        if boot.role == "door_station" { showIdle() }
    }

    private var inCallStreamer: MjpegClient?

    private func showInCall(streamUrl: String?) {
        exitScreensaver()
        idleView.isHidden = true
        callingView.isHidden = true
        inCallStreamer?.stop()
        inCallStreamer = nil
        peerVideo.image = nil
        peerVideo.transform = .identity
        if !safeMode, let u = streamUrl, !u.isEmpty {
            inCallStreamer = MjpegClient(urlString: u) { [weak self] img, rotation in
                guard let self = self else { return }
                self.peerVideo.image = img
                let r = ((rotation % 360) + 360) % 360
                var scale: CGFloat = 1
                if (r == 90 || r == 270), self.peerVideo.bounds.width > 0,
                   self.peerVideo.bounds.height > 0, img.size.width > 0, img.size.height > 0 {
                    let base = min(self.peerVideo.bounds.width / img.size.width,
                                   self.peerVideo.bounds.height / img.size.height)
                    let rotated = min(self.peerVideo.bounds.width / img.size.height,
                                      self.peerVideo.bounds.height / img.size.width)
                    if base > 0 { scale = rotated / base }
                }
                self.peerVideo.transform = CGAffineTransform(
                    rotationAngle: CGFloat(r) * .pi / 180).scaledBy(x: scale, y: scale)
            }
            inCallStreamer?.start()
        }
        inCallView.isHidden = false
    }

    private func closeInCall() {
        peerPollTimer?.invalidate()
        peerPollTimer = nil
        inCallStreamer?.stop()
        inCallStreamer = nil
        peerVideo.image = nil
        peerVideo.transform = .identity
        inCallView.isHidden = true
    }

    @objc private func onEndCallClick() {
        core.sipHangup()
        onSipIdle()
    }

    private func pollPeerFrame() {
        guard inCall, !safeMode, !peerPollBusy else { return }
        peerPollBusy = true
        let url = URL(string: "http://127.0.0.1:\(boot.httpPort)/peer-frame.jpg")!
        URLSession.shared.dataTask(with: url) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.peerPollBusy = false
                guard self.inCall, let data = data,
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let img = UIImage(data: data) else { return }
                if self.inCallView.isHidden { self.showInCall(streamUrl: nil) }
                self.peerVideo.image = img
            }
        }.resume()
    }


    @objc private func onCallClick() {
        if callFlowMode() == "purpose_first", availablePurposeIds().isEmpty == false {
            showPurposeChoice(afterRing: false)
            return
        }
        beginCall(purpose: "", title: nil)
        if !activeCallId.isEmpty, callFlowMode() == "ring_then_purpose",
           availablePurposeIds().isEmpty == false {
            showPurposeChoice(afterRing: true)
        }
    }

    private func beginCall(purpose: String, title: String?) {
        let sound = (ConfigUtil.dig(cfg, "ui.call_sound") as? String) ?? "outdoor_call_alert"
        let loop = ConfigUtil.bool(cfg, "ui.call_sound_loop", false)
        callFeedbackAudio.playConfigured(sound, loops: loop)
        guard let callId = core.pressV2(door: boot.door, purpose: purpose) else {
            showIdle(hint: texts.t("offline.body"))
            return
        }
        activeCallId = callId
        activeCallExpiresAtMs = coreExpiryForActiveCall()
        showCalling(title: title)
    }

    private func callFlowMode() -> String {
        if let mode = ConfigUtil.dig(cfg, "ui.call_flow") as? String { return mode }
        if let object = ConfigUtil.dig(cfg, "ui.call_flow") as? [String: Any],
           let mode = object["mode"] as? String { return mode }
        return "purpose_first"
    }

    private func availablePurposeIds() -> [String] {
        guard let purposes = ConfigUtil.dig(cfg, "visit_purposes") as? [String: Any] else {
            return []
        }
        return ConfigUtil.sortedByOrder(purposes)
    }

    private func showPurposeChoice(afterRing: Bool) {
        guard presentedViewController == nil,
              let purposes = ConfigUtil.dig(cfg, "visit_purposes") as? [String: Any] else { return }
        let alert = UIAlertController(title: texts.t("idle.choose_purpose"), message: nil,
                                      preferredStyle: .alert)
        for purposeId in availablePurposeIds() {
            let label = ConfigUtil.labelOf(purposes[purposeId] as? [String: Any], texts.lang,
                                           purposeId)
            alert.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                guard let self = self else { return }
                if afterRing {
                    if self.core.selectPurpose(door: self.boot.door, callId: self.activeCallId,
                                               purpose: purposeId) {
                        self.showCalling(title: self.texts.t("purpose.sent", label))
                    }
                } else {
                    self.beginCall(purpose: purposeId,
                                   title: self.texts.t("purpose.sent", label))
                }
            })
        }
        if afterRing {
            alert.addAction(UIAlertAction(title: texts.t("purpose.skip"), style: .default))
            alert.addAction(UIAlertAction(title: texts.t("purpose.cancel_call"),
                                          style: .destructive) { [weak self] _ in
                self?.onCancelClick()
            })
        } else {
            // Before emission, cancel is strictly local and produces no Core event.
            alert.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel))
        }
        present(alert, animated: true)
    }

    @objc private func onCancelClick() {
        callTimeoutTimer?.invalidate()
        if !activeCallId.isEmpty {
            _ = core.cancelCall(door: boot.door, callId: activeCallId, reason: "visitor")
        }
        showIdle()
    }

    @objc private func onMonitorOpen() {
        guard boot.role != "door_station", presentedViewController == nil else { return }
        present(MonitorViewController(core: core, boot: boot), animated: true)
    }

    @objc private func onSecretCorner() {
        let now = Date()
        if now.timeIntervalSince(secretFirst) > 5 {
            secretFirst = now
            secretTaps = 0
        }
        secretTaps += 1
        guard secretTaps >= 7 else { return }
        secretTaps = 0
        let dlg = AdminPinViewController(texts: texts)
        dlg.onUnlocked = { [weak self] in self?.showAdminInfo() }
        present(dlg, animated: true)
    }

    private func showAdminInfo() {
#if !IOS9_COMPAT && !os(tvOS)
        let monitorAction: (() -> Void)? = boot.role == "door_station" ? nil : { [weak self] in
            self?.onMonitorOpen()
        }
        let page = DebugInfoViewController(
            core: core, boot: boot, texts: texts,
            onPairing: { [weak self] in self?.showPairingAdmin() },
            onMonitor: monitorAction)
        present(page, animated: true)
#else
        UIApplication.shared.isIdleTimerDisabled = false
        let st = core.status()
        let node = st?["node"] as? [String: Any]
        let peers = (st?["peers"] as? [Any])?.count ?? 0
        let msg = """
        node: \(ConfigUtil.evStr(node ?? [:], "name")) (\(nodeId))
        peers: \(peers)
        data: \(BootConfig.dataDir())
        boot: \(boot.rawJson.prefix(300))
        """
        let a = UIAlertController(title: texts.t("admin.title"), message: msg,
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: texts.t("pair.panel_title"), style: .default) {
            [weak self] _ in self?.showPairingAdmin()
        })
        if boot.role != "door_station" {
            a.addAction(UIAlertAction(title: texts.t("monitor.open"), style: .default) {
                [weak self] _ in self?.onMonitorOpen()
            })
        }
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            UIApplication.shared.isIdleTimerDisabled = true
        })
        present(a, animated: true)
#endif
    }

    private func showPairingAdmin() {
        showAddDevicePanel()
    }


    private func requestAvPermissionsThenStartCamera() {
        runtime?.permissionsDidChange()
        if boot.role == "door_station" {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.runtime?.permissionsDidChange()
                    self?.maybeStartCamera()
                }
            }
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.runtime?.permissionsDidChange() }
        }
    }

    private func cameraLocalCfg() -> [String: Any]? {
        guard !nodeId.isEmpty else { return nil }
        return ConfigUtil.dig(cfg, "devices.\(nodeId).local.camera") as? [String: Any]
    }

    private func maybeStartCamera() {
        guard boot.role == "door_station" else { return }
        if safeMode {
            camera.start(targetW: 640, targetH: 360)
            return
        }
        let cam = cameraLocalCfg()
        var tw = 640
        var th = 480
        if (cam?["codec"] as? String ?? "auto") != "mjpeg" {
            let res = cam?["h264_resolution"] as? String ?? "1280x720"
            let parts = res.split(separator: "x")
            tw = parts.count == 2 ? (Int(parts[0]) ?? 1280) : 1280
            th = parts.count == 2 ? (Int(parts[1]) ?? 720) : 720
        }
        camera.start(targetW: tw, targetH: th)
    }

    private func encoderPoll() {
        guard boot.role == "door_station" else { return }
        if safeMode || h264EncoderFailed || videoEncoder.hasTerminalFailure {
            if videoEncoder.isRunning {
                camera.encoder = nil
                videoEncoder.stop()
            }
            return
        }
        // Keep the door station encoder warm whenever H.264 is configured. The stream endpoint
        // cannot emit its HTTP response before an init segment exists, and legacy clients can
        // time out before demand-only startup produces a keyframe.
        let wanted = (cameraLocalCfg()?["codec"] as? String ?? "auto") != "mjpeg"
        if lastEncoderDemand != wanted {
            lastEncoderDemand = wanted
            IOSAvailability.logDebug("h264 demand=\(wanted) running=\(videoEncoder.isRunning)")
        }
        if wanted && !videoEncoder.isRunning {
            let cam = cameraLocalCfg()
            videoEncoder.start(fps: ConfigUtil.int(cam, "h264_fps", 25),
                               bitrateKbps: ConfigUtil.int(cam, "h264_bitrate_kbps", 1500))
            camera.encoder = videoEncoder
        } else if !wanted && videoEncoder.isRunning {
            camera.encoder = nil
            videoEncoder.stop()
        }
    }

    func debugRefreshH264() {
        IOSAvailability.logDebug("h264 debug refresh requested")
        encoderPoll()
    }
}
