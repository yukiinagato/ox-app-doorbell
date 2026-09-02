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
    private var cancelRequiresPin = true

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
    private var emergencyPresentationTimer: Timer?
    private var peerPollTimer: Timer?
    private var encoderPollTimer: Timer?

    private let themeBg = ThemeBackgroundView()
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
    /// The purpose grid's caption. §5.3 allows the door station one hint sentence and the
    /// visitor screen spends it on `door.hint_call`, so this stays hidden there; the plain idle
    /// view, which has no hint of its own, still shows it.
    private let purposeHint = UILabel()
    private let purposeGrid = UIStackView()
    /// The grid never grows past this, however wide the panel is; below it the columns share
    /// whatever width the layout actually offers.
    private static let purposeGridMaxWidth: CGFloat = 552
    private let langBar = UIStackView()
    private lazy var sosSlider = SosSlideControl(texts: texts)
    private var dashboard: DashboardView?
    private var visitorScreen: VisitorScreenView?
    private var palette = DoorbellPalette.dark
    private var idleSkin = DoorbellSkin.plain(.dark)
    private var displayDoc: [String: Any]?
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
        themeBg.releaseImage()
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
        themeBg.onImageLoaded = { [weak self] in self?.refreshHomeSurfaces() }
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
        let dlg = AdminPinViewController(texts: texts, core: core)
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

        // The clock and date labels stay the single source the screensaver mirrors, even on the
        // indoor dashboard where the visible clock belongs to the dashboard itself.
        clockLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 84, weight: .light)
        clockLabel.textColor = MainViewController.fgColor
        clockLabel.textAlignment = .center

        dateLabel.font = .systemFont(ofSize: 24)
        dateLabel.textColor = MainViewController.dimColor
        dateLabel.textAlignment = .center

        callButton.titleLabel?.font = .systemFont(ofSize: 34, weight: .bold)
        callButton.titleLabel?.numberOfLines = 0
        callButton.titleLabel?.textAlignment = .center
        callButton.setTitleColor(.black, for: .normal)
        callButton.backgroundColor = MainViewController.accentColor
        callButton.layer.cornerRadius = 18
        callButton.accessibilityIdentifier = "call_primary"
        callButton.contentEdgeInsets = UIEdgeInsets(top: 26, left: 60, bottom: 26, right: 60)
        callButton.addTarget(self, action: #selector(onCallClick), for: .touchUpInside)

        monitorButton.titleLabel?.font = .systemFont(ofSize: 24, weight: .semibold)
        monitorButton.setTitleColor(MainViewController.fgColor, for: .normal)
        monitorButton.backgroundColor = MainViewController.cardColor
        monitorButton.layer.cornerRadius = 14
        monitorButton.contentEdgeInsets = UIEdgeInsets(top: 16, left: 36, bottom: 16, right: 36)
        monitorButton.addTarget(self, action: #selector(onMonitorOpen), for: .touchUpInside)

        touchHint.font = .systemFont(ofSize: 20)
        touchHint.textColor = MainViewController.dimColor
        touchHint.textAlignment = .center

        purposeHint.font = .systemFont(ofSize: 20)
        purposeHint.textColor = MainViewController.dimColor
        purposeHint.textAlignment = .center
        purposeGrid.axis = .vertical
        purposeGrid.spacing = 12
        // Rows take the grid's width and divide it; the grid takes the width it is given, up to a
        // comfortable maximum. Fixed-width buttons overflowed the landscape column and the third
        // one was cut off at the screen edge.
        purposeGrid.alignment = .fill
        purposeSection.axis = .vertical
        purposeSection.spacing = 12
        purposeSection.alignment = .center
        purposeGrid.translatesAutoresizingMaskIntoConstraints = false
        let gridWidth = purposeGrid.widthAnchor.constraint(
            equalToConstant: MainViewController.purposeGridMaxWidth)
        gridWidth.priority = UILayoutPriority(750)
        gridWidth.isActive = true
        purposeSection.addArrangedSubview(purposeHint)
        purposeSection.addArrangedSubview(purposeGrid)

        langBar.axis = .horizontal
        langBar.spacing = 12
        langBar.alignment = .fill
        langBar.distribution = .fillEqually

        sosSlider.accessibilityIdentifier = "sos_slider"
        sosSlider.onTriggered = { [weak self] in self?.triggerEmergency() }

        nodeInfo.font = .systemFont(ofSize: 14)
        nodeInfo.textColor = UIColor(white: 1, alpha: 0.35)
        membershipLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        membershipLabel.textColor = UIColor(white: 1, alpha: 0.62)
        membershipLabel.accessibilityIdentifier = "membership_status"
        appVersionLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        appVersionLabel.numberOfLines = 2

        let content: UIView
        if boot.role == "door_station" {
            purposeHint.isHidden = true
            let screen = VisitorScreenView(texts: texts, callButton: callButton, langBar: langBar,
                                           purposeSection: purposeSection, sosControl: sosSlider)
            visitorScreen = screen
            content = screen
        } else {
            let board = DashboardView(core: core, boot: boot, texts: texts,
                                      sosControl: sosSlider)
            board.onOpenAdmin = { [weak self] in self?.onAdminEntry() }
            board.onOpenHistory = { [weak self] in self?.openCallHistory() }
            board.onOpenDoor = { [weak self] _ in self?.onMonitorOpen() }
            board.onOpenNotice = { [weak self] door in self?.openNoticeDialog(door: door) }
            dashboard = board
            content = board
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        idleView.addSubview(content)
        let g = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: g.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
        ])
        applyIdleLayout(for: view.bounds.size)
    }

    /// Both home screens are laid out from the size they are about to have, so a rotation or a
    /// split-screen resize re-flows instead of keeping a layout that only suits one orientation.
    private func applyIdleLayout(for size: CGSize) {
        dashboard?.applyLayout(for: size)
        visitorScreen?.applyLayout(for: size)
    }

    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        applyIdleLayout(for: size)
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
        // The visitor is standing at this unit, so naming it on the button says nothing they do
        // not already know, and on a narrow panel the id is what pushes the label onto a second
        // line. The button carries the verb alone; the door's name stays in the footer.
        callButton.setTitle(texts.t("idle.call_button_verb"), for: .normal)
        touchHint.text = texts.t("idle.touch_to_call")
        monitorButton.setTitle(texts.t("monitor.open"), for: .normal)
        callingText.text = callTitleOverride ?? texts.t("calling.title")
        cancelButton.setTitle(texts.t("calling.cancel"), for: .normal)
        replyCaption.text = texts.t("reply.banner")
        offlineTitle.text = texts.t("offline.title")
        offlineBody.text = texts.t("offline.body")
        sosSlider.refreshStrings()
        visitorScreen?.updateHint(texts.t("door.hint_call"))
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

    /// Every clock is rendered from Core's zone-corrected reading, so a device whose own clock is
    /// wrong — or that sits in another zone — still shows the household's time.
    private func updateClock() {
        guard let reading = DoorbellClock.read(core) else { return }
        clockLabel.text = reading.hhmmss
        dateLabel.text = DoorbellClock.longDate(reading, lang: texts.lang)
        visitorScreen?.updateClock(reading, lang: texts.lang)
        dashboard?.updateClock()
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
        buildPurposeButtons()
        buildLangBar()
        applyStrings()
        refreshHomeSurfaces()
        applySemanticStyles()
    }

    /// Recomputes the appearance and hands the current snapshot to whichever home screen this
    /// device shows. Both are pure renderers: they never read Core state on their own.
    private func refreshHomeSurfaces() {
        IOSAvailability.PerfProbe.measure("home.refresh") { refreshHomeSurfacesBody() }
    }

    private func refreshHomeSurfacesBody() {
        palette = DoorbellPalette.of(DoorbellTheme.appearance(
            display: displayDoc, config: cfg, nodeId: nodeId, localTime: core.localTime()))
        let skin = applyTheme()
        applyVolumes()
        updateClock()
        applyIdleControlSkin(skin)
        if let dashboard = dashboard {
            dashboard.reload(config: cfg, skin: skin)
            dashboard.updateMembership(membershipLabel.text ?? "", hidden: membershipLabel.isHidden)
        }
        if let visitor = visitorScreen {
            let notice = DoorbellNotice.effective(status: core.status(), config: cfg,
                                                  door: boot.door,
                                                  nowMs: DoorbellClock.nowMs(core))
            visitor.updateNotice(notice)
            visitor.updateHint(texts.t("door.hint_call"))
            let power = (core.status()?["self"] as? [String: Any])?["power"] as? [String: Any]
            let label = doorLabel(boot.door)
            visitor.updateFooter(DoorbellTheme.versionLine(
                name: label.isEmpty ? boot.name : label,
                coreVersion: DoorbellTheme.coreVersion(), texts: texts, power: power))
            visitor.apply(skin: skin)
        }
    }

    /// The controls the visitor screen borrows from this controller. They are built once and only
    /// recoloured here, so a theme or appearance change never rebuilds them under a finger.
    private func applyIdleControlSkin(_ skin: DoorbellSkin) {
        purposeHint.textColor = skin.muted("hint")
        for row in purposeGrid.arrangedSubviews {
            for view in (row as? UIStackView)?.arrangedSubviews ?? [] {
                guard let button = view as? UIButton else { continue }
                button.backgroundColor = skin.surface
                button.setTitleColor(skin.cardInk("tile_label"), for: .normal)
            }
        }
        idleSkin = skin
        updateLangBarSelection()
    }

    /// Applies the three effective volumes to the players that own each kind of sound.
    private func applyVolumes() {
        guard let volumes = core.audioVolumes() else { return }
        audio.volume = ConfigUtil.int(volumes, "call", 80)
        callFeedbackAudio.volume = ConfigUtil.int(volumes, "idle", 60)
    }

    private func applySemanticStyles() {
        let bindings: [(String, UIView)] = [
            ("call.primary", callButton), ("cancel.call", cancelButton),
            ("call.end", endCallButton), ("sos.trigger", sosSlider),
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


    /// `display.theme` is the household's own background, and every panel wears it — the indoor
    /// dashboard as much as the door station, which is what the iPad 1 indoor panel already does.
    /// Light/dark then owns the cards layered on top rather than the screen itself, and §5's
    /// automatic contrast keeps the bare text legible on whatever picture is behind it.
    private func applyTheme() -> DoorbellSkin {
        return themeBg.apply(display: displayDoc, config: cfg, nodeId: nodeId, palette: palette,
                             httpPort: boot.httpPort, host: view)
    }

    /// Only the purposes an administrator left switched on are offered here; the settings 用件
    /// list is the one surface that shows the others, because that is where they are switched
    /// back on.
    private func buildPurposeButtons() {
        for v in purposeGrid.arrangedSubviews { v.removeFromSuperview() }
        let purposes = (ConfigUtil.dig(cfg, "visit_purposes") as? [String: Any]) ?? [:]
        let ids = ConfigUtil.enabledPurposeIds(cfg)
        guard boot.role == "door_station", !ids.isEmpty else {
            purposeSection.isHidden = true
            return
        }
        var row: UIStackView?
        for (i, id) in ids.enumerated() {
            if i % 3 == 0 {
                row = UIStackView()
                row!.axis = .horizontal
                row!.spacing = 12
                row!.distribution = .fillEqually
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
            b.setTitleColor(idleSkin.cardInk("tile_label"), for: .normal)
            b.backgroundColor = idleSkin.surface
            b.layer.cornerRadius = 12
            // The row divides its width equally, so a button only needs a floor it may not
            // shrink below and a fixed height.
            let minimum = b.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
            minimum.priority = UILayoutPriority(999)
            minimum.isActive = true
            b.heightAnchor.constraint(equalToConstant: 92).isActive = true
            b.accessibilityIdentifier = "purpose_\(id)"
            b.addTarget(self, action: #selector(onPurposeClick(_:)), for: .touchUpInside)
            row!.addArrangedSubview(b)
        }
        // A last row with one or two purposes in it keeps the column width of a full row rather
        // than stretching its buttons across the grid.
        if let last = row, last.arrangedSubviews.count % 3 != 0 {
            for _ in last.arrangedSubviews.count..<3 { last.addArrangedSubview(UIView()) }
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
            b.layer.cornerRadius = 10
            #if !os(tvOS)
            b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 22, bottom: 8, right: 22)
            #endif
            b.accessibilityIdentifier = "lang_\(lang)"
            b.addTarget(self, action: #selector(onLangClick(_:)), for: .primaryActionTriggered)
            langBar.addArrangedSubview(b)
        }
        langBar.isHidden = false
        updateLangBarSelection()
    }

    /// A language chip says one thing — the language's own name — so it has no authored second
    /// line; adding a tag under it would be exactly the decorative label §5.2 rules out. It still
    /// goes through the two-part renderer, so a name that needs a break (「Tiếng Việt」) breaks
    /// where the catalog puts it instead of being squeezed to fit.
    private func updateLangBarSelection() {
        for v in langBar.arrangedSubviews {
            guard let b = v as? UIButton,
                  let lang = b.accessibilityIdentifier?.dropFirst("lang_".count) else { continue }
            let code = String(lang)
            let on = code == visitorLang
            let fill = on ? idleSkin.palette.accent : idleSkin.surface
            b.backgroundColor = fill
            let ink = on ? idleSkin.palette.onAccent : idleSkin.cardMuted("hint")
            DoorbellTheme.twoPartTitle(Texts.langDisplayName(code), on: b, primarySize: 20,
                                       color: ink, focusColor: idleSkin.palette.onAccent,
                                       bold: on)
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
        // Core's display contract carries the resolved appearance and the automatic theme; both
        // home screens paint from it rather than each deriving its own answer.
        displayDoc = d
        brightness = ConfigUtil.int(d, "brightness", brightness)
        night = ConfigUtil.evBool(d, "night")
        redTint = ConfigUtil.evBool(d, "red_tint")
        screensaverAfterS = ConfigUtil.int(d, "screensaver_after_s", screensaverAfterS)
        pixelShiftS = ConfigUtil.int(d, "pixel_shift_s", pixelShiftS)
        applyDisplay()
    }

    private func applyDisplay() {
        nightTint.isHidden = !(night && redTint)
        clockLabel.textColor = night ? MainViewController.nightClock : palette.ink
        dateLabel.textColor = night ? MainViewController.nightClock : palette.inkMuted
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
        sosSlider.isHidden = !show
        visitorScreen?.setSosVisible(show)
        // The countdown is a shell state; Core hears about the emergency only when it reaches
        // zero. `emergency.hold_to_trigger_s` stays in old configurations but no longer drives it.
        sosSlider.countdownSeconds = max(0, min(10,
            ConfigUtil.int(cfg, "emergency.trigger.countdown_s", 3)))
        sosSlider.refreshStrings()
        // Core folds the setting together with "a password actually exists"; the setting
        // alone would stand between a household and a running alarm on a cluster that
        // has never set one.
        cancelRequiresPin = core.sosCancelRequiresPassword
    }

    /// Called only once the slide countdown has elapsed.
    private func triggerEmergency() {
        core.emergency(true)
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
        // The SOS level is one of the three per-device volumes; Core resolves the device
        // override, the cluster default and the legacy emergency.alarm_volume in that order.
        let volume = ConfigUtil.int(core.audioVolumes(), "sos",
                                    ConfigUtil.int(ev, "alarm_volume", 100))
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
            let dlg = AdminPinViewController(texts: texts, core: core)
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
        if let h = hint {
            touchHint.text = h
            visitorScreen?.updateHint(h)
        }
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
            // The theme picture may be the asset that just finished arriving; re-applying is a
            // no-op unless it is, because the background view remembers what it already holds.
            if themeBg.image == nil { refreshHomeSurfaces() }
        case "display":
            applyDisplayValues(ev)
            refreshHomeSurfaces()
        case "emergency":
            presentEmergency(ev)
        case "peers_changed", "config_changed":
            refreshNodeInfo()
        case "time_changed":
            // The source or the applied correction moved: redraw every clock at once instead of
            // waiting for the next tick, and re-evaluate a scheduled light/dark switch.
            refreshHomeSurfaces()
        case "power_changed":
            core.refreshPowerStateCache()
            refreshHomeSurfaces()
        case "notice_changed":
            refreshConfigCache()
            refreshHomeSurfaces()
        case "call_log_changed":
            dashboard?.refreshHistory()
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
        return ConfigUtil.enabledPurposeIds(cfg)
    }

    private func showPurposeChoice(afterRing: Bool) {
        let purposes = (ConfigUtil.dig(cfg, "visit_purposes") as? [String: Any]) ?? [:]
        guard presentedViewController == nil, !availablePurposeIds().isEmpty else { return }
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

    /// The visible 管理 entry on an indoor panel. It always asks for the admin password; a door
    /// station has no visible entry at all and reaches the same screen through the hidden corner.
    private func onAdminEntry() {
        guard presentedViewController == nil else { return }
        let dialog = AdminPinViewController(texts: texts, core: core)
        dialog.onUnlocked = { [weak self] in self?.showSettings() }
        present(dialog, animated: true)
    }

    private func showSettings() {
        guard presentedViewController == nil else { return }
        let settings = SettingsViewController(core: core, boot: boot, texts: texts)
        settings.onOpenAddDevice = { [weak self] in self?.showAddDevicePanel() }
        settings.onOpenDeviceInfo = { [weak self] in self?.showAdminInfo() }
        settings.onExitKiosk = { UIApplication.shared.isIdleTimerDisabled = false }
        present(settings, animated: true)
    }

    private func openCallHistory() {
        guard presentedViewController == nil else { return }
        present(CallHistoryViewController(core: core, texts: texts, lang: texts.lang),
                animated: true)
    }

    /// `door` empty opens the dialog with the home-wide target preselected.
    private func openNoticeDialog(door: String) {
        guard presentedViewController == nil else { return }
        present(NoticeDialogViewController(core: core, texts: texts, httpPort: boot.httpPort,
                                           lang: texts.lang, door: door), animated: true)
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
        let dlg = AdminPinViewController(texts: texts, core: core)
        dlg.onUnlocked = { [weak self] in self?.showSettings() }
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
