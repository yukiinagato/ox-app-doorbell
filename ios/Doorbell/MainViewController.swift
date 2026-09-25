import AudioToolbox
import AVFoundation
import UIKit

final class PurposeButton: UIButton {
    var contentHeight: NSLayoutConstraint?

    override func layoutSubviews() {
        super.layoutSubviews()
        if let height = contentHeight, let label = titleLabel, bounds.width > 12 {
            let measured = ceil(label.sizeThatFits(CGSize(width: bounds.width - 12,
                height: .greatestFiniteMagnitude)).height) + 56
            let required = max(88, measured)
            if height.constant != required { height.constant = required }
        }
        let iconSize: CGFloat = 24
        imageView?.frame = CGRect(x: (bounds.width - iconSize) / 2, y: 14,
                                  width: iconSize, height: iconSize)
        titleLabel?.frame = CGRect(x: 6, y: 44, width: bounds.width - 12,
                                   height: bounds.height - 50)
    }
}

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
    private var screensaverBrightness = 10
    private var screensaverMode = "dim"
    private var pixelShiftS = 300
    private var lastActivity = Date()
    private var screensaverOn = false

    private var emergencyActive = false
    private var cancelRequiresPin = true

    private var inCall = false
    private var peerPollBusy = false
    private var peerPollGeneration: UInt64 = 0
    private var peerPollTask: URLSessionDataTask?
    private var peerMediaGeneration = ""
    private var peerFrameSequence: UInt64 = 0
    private var peerDisplayedFrameIdentity: PeerFrameIdentity?
    private var peerLastValidFrameAt: TimeInterval?
    private struct PeerFrameIdentity: Equatable {
        let core: UInt64
        let call: String
        let revision: Int
        let owner: String
    }
    private weak var purposeChoice: PurposeChoiceViewController?
    private var activeCallId = ""
    private var visitorActionRevision: UInt64 = 0
    private struct VisitorActionIdentity: Equatable {
        let call: String
        let core: UInt64?
        let revision: UInt64
        let inCall: Bool
    }
    private var heldVisitorActions: [ObjectIdentifier: VisitorActionIdentity] = [:]
    private var reportedRecoveryCallId = ""
    private var callTiming = CallTiming()
    private var callTimingGeneration: UInt64?
    private var callTimerRevision: UInt64 = 0
    private var callTimingSuspended = false
#if DEBUG
    private(set) var callTimerCallbackForTesting: (() -> Void)?
    var callTimingSnapshotForTesting: (() -> CallTiming.Snapshot?)?
    var suppressVisitorMediaForTesting = false
    var peerFrameLoadForTesting: ((URLRequest, @escaping (Data?, URLResponse?) -> Void) -> Void)?
    var peerFrameClockForTesting: (() -> TimeInterval)?
#endif
    private let safeMode = false
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
    /// The clock is drawn from this, never from a Core call on the tick itself.
    private let clockSource = DoorbellClockSource()
    private var clockRefreshTimer: Timer?
    private var lastClockTickUptime: TimeInterval = 0
    /// Core announces `peers_changed` on every *fresh* peer heartbeat, not only when the
    /// membership actually moves, so a cluster of a handful of devices produces several a second.
    /// Rebuilding the home page on each one meant a SQLite call-log query, an admin-QR address
    /// lookup and a full ink pass per event — each of them a synchronous hop onto Core's run
    /// loop. On the door station that is what took the app over the OS CPU limit, and it left
    /// Core's own loop with no time for its mesh heartbeats, so the other nodes called it dead.
    /// The events are coalesced onto one rebuild.
    private static let homeRefreshCoalesceS: TimeInterval = 1
    private var cameraPermissionWarned = false
    private var homeRefreshPending = false
    private var nodeInfoRefreshPending = false
    private var lastHomeRefreshUptime: TimeInterval = 0
    private var wakeObserver: NSObjectProtocol?
    private var inviteObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

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
    private let callingDetail = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let inCallView = UIView()
    private let peerVideo = UIImageView()
    private let inCallTitle = UILabel()
    private let endCallButton = UIButton(type: .system)
    private var visitorActionHeights: [NSLayoutConstraint] = []
    private let replyBanner = UIView()
    private let replyCaption = UILabel()
    private let replyText = UILabel()
    private let offlineView = UIView()
    private let offlineTitle = UILabel()
    private let offlineBody = UILabel()
    private let screensaverView = UIView()
    private let saverHint = UILabel()
    private let saverClock = UILabel()
    private let saverDate = UILabel()
    private let nightTint = UIView()
    private let emergencyView = UIView()
    private let emergencyTitle = UILabel()
    private let emergencyNote = UILabel()
    private let emergencyCancel = UIButton(type: .system)
    private var purposeColumns = 3

    private static let bgColor = UIColor(red: 0.063, green: 0.078, blue: 0.094, alpha: 1)
    private static let fgColor = UIColor(white: 0.94, alpha: 1)
    private static let dimColor = UIColor(white: 0.62, alpha: 1)
    private static let cardColor = UIColor(white: 1, alpha: 0.10)
    private static let accentColor = UIColor(red: 1.0, green: 0.80, blue: 0.25, alpha: 1)
    private static let nightClock = UIColor(red: 0.545, green: 0.141, blue: 0.110, alpha: 1)
    private static let saverClockColor = UIColor(white: 0.85, alpha: 1)

    init(core: CoreBridge, boot: BootConfig, runtime: RuntimeSupervisor?) {
        self.core = core
        self.boot = boot
        self.runtime = runtime
        AdaptiveH264MjpegPlayer.onDecodeState = { [weak runtime] verified, state in
            runtime?.recordH264Decode(verified: verified, state: state)
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        callTimeoutTimer?.invalidate()
        for observer in [pairingObserver, wakeObserver, inviteObserver, activeObserver,
                         backgroundObserver] {
            guard let observer = observer else { continue }
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
        // Anything that would have made somebody look at the panel wakes it the way a finger
        // does, idle timer and all: the screenshot hook's wake request, and an invitation
        // arriving for a device that is waiting to be added.
        wakeObserver = NotificationCenter.default.addObserver(
            forName: .doorbellWakeScreen, object: nil, queue: .main
        ) { [weak self] _ in self?.onActivity() }
        inviteObserver = NotificationCenter.default.addObserver(
            forName: .doorbellPairInvitation, object: nil, queue: .main
        ) { [weak self] _ in self?.onActivity() }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resumeCallTiming() }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.suspendCallTiming() }
        refreshPairingStatus()

        scheduleClockTick()
        refreshClockBase()
        clockRefreshTimer = IOSAvailability.scheduledTimer(
            withTimeInterval: DoorbellClockSource.refreshIntervalS, repeats: true
        ) { [weak self] _ in self?.refreshClockBase() }
        updateClock()
#if DEBUG
        if suppressVisitorMediaForTesting { return }
#endif
        encoderPollTimer = IOSAvailability.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.encoderPoll()
        }
        requestAvPermissionsThenStartCamera()
        encoderPoll()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applySemanticStyles()
        updateVisitorActionMetrics()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyVisitorTypography()
        buildPurposeButtons()
    }

    private func applyVisitorTypography() {
        for label in [callingText, inCallTitle, offlineTitle, emergencyTitle] {
            let size: CGFloat = label === emergencyTitle ? 44 : (label === offlineTitle ? 34 : 30)
            label.font = IOSAvailability.visitorFont(size: size,
                weight: .semibold, traits: traitCollection)
        }
        for label in [callingDetail, offlineBody, emergencyNote] {
            label.font = IOSAvailability.visitorFont(size: label === callingDetail ? 17 : 22,
                                                     traits: traitCollection)
        }
        for button in [cancelButton, endCallButton, emergencyCancel] {
            button.titleLabel?.font = IOSAvailability.visitorFont(size: 24, weight: .semibold,
                                                                  traits: traitCollection)
        }
        updateVisitorActionMetrics()
    }

    private func updateVisitorActionMetrics() {
        let line = max(cancelButton.titleLabel?.font.lineHeight ?? 0,
                       endCallButton.titleLabel?.font.lineHeight ?? 0)
        var height = max(56, ceil(line * 2 + 28))
        for button in [cancelButton, endCallButton, emergencyCancel] {
            let width = max(1, min(420, view.bounds.width - 40) - button.contentEdgeInsets.left -
                            button.contentEdgeInsets.right)
            let textHeight = button.titleLabel?.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height ?? 0
            height = max(height, ceil(textHeight + 28))
        }
        for constraint in visitorActionHeights where constraint.constant != height {
            constraint.constant = height
        }
    }

    func onActivity() {
        lastActivity = Date()
        exitScreensaver()
    }

    func enterSafeModeForMemoryPressure() {
        camera.encoder = nil
        videoEncoder.stop()
        camera.stop()
        themeBg.releaseImage()
        // The SIP dialog and its End Call control must survive video memory pressure. Drop only
        // decoder/image state; the user can continue a pure-audio established call or hang it up.
        peerPollTimer?.invalidate()
        peerPollTimer = nil
        retirePeerFrameRequest()
        inCallStreamer?.stop()
        inCallStreamer = nil
        peerVideo.image = nil
        peerVideo.transform = .identity
        if inCall { inCallView.isHidden = false }
        maybeStartCamera()
    }

    /// Stop admission without waiting on capture callbacks from the main queue. CoreBridge
    /// drains any already acquired leases before destroying the native instance.
    func prepareForCoreShutdown() {
        visitorActionRevision &+= 1
        suspendCallTiming()
        camera.stop()
        camera.encoder = nil
        videoEncoder.stop()
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
        applyVisitorTypography()

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
        purposeGrid.widthAnchor.constraint(lessThanOrEqualTo: purposeSection.widthAnchor).isActive = true

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
        let columns = VisitorScreenView.purposeColumnCount(for: size)
        if columns != purposeColumns {
            purposeColumns = columns
            buildPurposeButtons()
        }
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
        pulse.layer.cornerRadius = 40
        pulse.translatesAutoresizingMaskIntoConstraints = false
        let bell = UIImageView(image: TablerIcon.image("TablerBell"))
        bell.tintColor = .black
        bell.contentMode = .scaleAspectFit
        bell.translatesAutoresizingMaskIntoConstraints = false
        pulse.addSubview(bell)
        NSLayoutConstraint.activate([
            bell.centerXAnchor.constraint(equalTo: pulse.centerXAnchor),
            bell.centerYAnchor.constraint(equalTo: pulse.centerYAnchor),
            bell.widthAnchor.constraint(equalToConstant: 36),
            bell.heightAnchor.constraint(equalToConstant: 36),
        ])

        callingText.font = .systemFont(ofSize: 30, weight: .semibold)
        callingText.textColor = MainViewController.fgColor
        callingText.textAlignment = .center
        callingText.numberOfLines = 0
        callingText.accessibilityIdentifier = "calling_status"
        callingText.accessibilityTraits = .header
        callingDetail.font = .systemFont(ofSize: 17)
        callingDetail.textColor = MainViewController.dimColor
        callingDetail.numberOfLines = 0
        callingDetail.accessibilityIdentifier = "calling_detail"
        callingDetail.textAlignment = .center

        cancelButton.titleLabel?.font = .systemFont(ofSize: 24)
        cancelButton.setTitleColor(MainViewController.fgColor, for: .normal)
        cancelButton.backgroundColor = MainViewController.cardColor
        cancelButton.layer.cornerRadius = 12
        cancelButton.contentEdgeInsets = UIEdgeInsets(top: 14, left: 40, bottom: 14, right: 40)
        cancelButton.addTarget(self, action: #selector(onCancelClick), for: .touchUpInside)
        bindVisitorActionInput(cancelButton)
        cancelButton.accessibilityIdentifier = "calling_cancel"
        callingView.addSubview(cancelButton)
        pinVisitorAction(cancelButton, in: callingView)
        let stack = UIStackView(arrangedSubviews: [pulse, callingText, callingDetail])
        stack.axis = .vertical
        stack.spacing = 18
        stack.alignment = .center
        addVisitorStatus(stack, in: callingView, above: cancelButton)
        NSLayoutConstraint.activate([
            pulse.widthAnchor.constraint(equalToConstant: 80),
            pulse.heightAnchor.constraint(equalToConstant: 80),
            callingText.widthAnchor.constraint(equalTo: stack.widthAnchor),
            callingDetail.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func pinVisitorAction(_ button: UIButton, in container: UIView) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        let width = button.widthAnchor.constraint(equalToConstant: 420)
        width.priority = UILayoutPriority(750)
        let height = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 56)
        visitorActionHeights.append(height)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 20),
            button.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -20),
            width, height,
        ])
    }

    private func addVisitorStatus(_ stack: UIStackView, in container: UIView,
                                   above action: UIView? = nil) {
        let scroll = UIScrollView()
        let content = UIView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        container.addSubview(scroll)
        scroll.addSubview(content)
        content.addSubview(stack)
        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        let fill = content.heightAnchor.constraint(greaterThanOrEqualTo: scroll.heightAnchor)
        fill.priority = UILayoutPriority(250)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: action?.topAnchor ?? guide.bottomAnchor,
                                             constant: -20),
            content.topAnchor.constraint(equalTo: scroll.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fill,
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
        inCallTitle.textAlignment = .center
        inCallTitle.numberOfLines = 0
        inCallTitle.accessibilityIdentifier = "incall_status"
        inCallTitle.accessibilityTraits = .header
        inCallTitle.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        inCallTitle.translatesAutoresizingMaskIntoConstraints = false

        endCallButton.titleLabel?.font = .systemFont(ofSize: 24, weight: .semibold)
        endCallButton.setTitleColor(.white, for: .normal)
        endCallButton.backgroundColor = UIColor(red: 0.78, green: 0.16, blue: 0.12, alpha: 1)
        endCallButton.layer.cornerRadius = 12
        endCallButton.contentEdgeInsets = UIEdgeInsets(top: 14, left: 44, bottom: 14, right: 44)
        endCallButton.addTarget(self, action: #selector(onEndCallClick), for: .touchUpInside)
        bindVisitorActionInput(endCallButton)
        endCallButton.accessibilityIdentifier = "incall_end"
        inCallView.addSubview(endCallButton)
        pinVisitorAction(endCallButton, in: inCallView)

        let statusScroll = UIScrollView()
        statusScroll.accessibilityIdentifier = "incall_status_scroll"
        statusScroll.translatesAutoresizingMaskIntoConstraints = false
        statusScroll.clipsToBounds = true
        inCallView.addSubview(statusScroll)
        statusScroll.addSubview(inCallTitle)
        let g = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            statusScroll.topAnchor.constraint(equalTo: g.topAnchor, constant: 18),
            statusScroll.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            statusScroll.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            statusScroll.bottomAnchor.constraint(equalTo: endCallButton.topAnchor, constant: -20),
            inCallTitle.topAnchor.constraint(equalTo: statusScroll.topAnchor),
            inCallTitle.bottomAnchor.constraint(equalTo: statusScroll.bottomAnchor),
            inCallTitle.leadingAnchor.constraint(equalTo: statusScroll.leadingAnchor),
            inCallTitle.trailingAnchor.constraint(equalTo: statusScroll.trailingAnchor),
            inCallTitle.widthAnchor.constraint(equalTo: statusScroll.widthAnchor),
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
        offlineTitle.numberOfLines = 0
        offlineTitle.accessibilityIdentifier = "visitor_offline_status"
        offlineTitle.accessibilityTraits = .header
        offlineBody.font = .systemFont(ofSize: 22)
        offlineBody.textColor = MainViewController.dimColor
        offlineBody.textAlignment = .center
        offlineBody.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [offlineTitle, offlineBody])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        addVisitorStatus(stack, in: offlineView)
        offlineTitle.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        offlineBody.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func buildScreensaver() {
        screensaverView.backgroundColor = .black
        screensaverView.isHidden = true
        addFull(screensaverView)
        saverClock.font = UIFont.monospacedDigitSystemFont(ofSize: 64, weight: .light)
        saverClock.textColor = MainViewController.saverClockColor
        saverDate.font = .systemFont(ofSize: 20)
        saverDate.textColor = MainViewController.saverClockColor
        saverHint.font = .systemFont(ofSize: 28, weight: .semibold)
        saverHint.textColor = .white
        saverHint.textAlignment = .center
        saverHint.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [saverClock, saverDate, saverHint])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        screensaverView.addSubview(stack)
        saverCenterX = stack.centerXAnchor.constraint(equalTo: screensaverView.centerXAnchor)
        saverCenterY = stack.centerYAnchor.constraint(equalTo: screensaverView.centerYAnchor)
        NSLayoutConstraint.activate([saverCenterX!, saverCenterY!,
                                     stack.widthAnchor.constraint(lessThanOrEqualTo: screensaverView.widthAnchor,
                                                                  multiplier: 0.7)])
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
        emergencyTitle.numberOfLines = 0
        emergencyTitle.accessibilityIdentifier = "visitor_sos_status"
        emergencyTitle.accessibilityTraits = .header
        emergencyView.accessibilityIdentifier = "visitor_sos_screen"
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
        emergencyCancel.accessibilityIdentifier = "visitor_sos_clear"
        emergencyView.addSubview(emergencyCancel)
        pinVisitorAction(emergencyCancel, in: emergencyView)
        let stack = UIStackView(arrangedSubviews: [emergencyTitle, emergencyNote])
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .fill
        addVisitorStatus(stack, in: emergencyView, above: emergencyCancel)
    }


    private func applyStrings() {
        saverHint.text = texts.t(boot.role == "door_station" ? "display.saver_door_hint" : "display.saver_panel_hint")
        // The visitor is standing at this unit, so naming it on the button says nothing they do
        // not already know, and on a narrow panel the id is what pushes the label onto a second
        // line. The button carries the verb alone; the door's name stays in the footer.
        callButton.setTitle(texts.t("idle.call_button_verb"), for: .normal)
        touchHint.text = texts.t("idle.touch_to_call")
        monitorButton.setTitle(texts.t("monitor.open"), for: .normal)
        callingText.text = callTitleOverride ?? texts.t("calling.title")
        callingDetail.text = texts.t("calling.wait_hint")
        cancelButton.setTitle(texts.t("calling.cancel"), for: .normal)
        replyCaption.text = texts.t("reply.banner")
        offlineTitle.text = texts.t("offline.title")
        offlineBody.text = texts.t("offline.body")
        sosSlider.refreshStrings()
        visitorScreen?.setCallFlow(callFlowMode(), hasPurposes: !availablePurposeIds().isEmpty)
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
        // The interval between visible ticks is the whole complaint: the timer fires at 1 Hz, and
        // what mattered was whether anything blocked the run loop between two of them.
        let now = ProcessInfo.processInfo.systemUptime
        if lastClockTickUptime > 0 {
            IOSAvailability.PerfProbe.record("clock.tick", now - lastClockTickUptime)
        }
        lastClockTickUptime = now
        if !callTimingSuspended, core.runningGeneration != callTimingGeneration {
            resetCallTiming()
            refreshCallingDeadline()
        }
        // A base that was refused because Core had not started yet is retried here rather than at
        // the next half minute, so a late start still puts a time on screen within a second of
        // Core being ready. The retry costs one boolean while Core is down.
        if clockSource.waitingForCore { refreshClockBase() }
        updateClock()
        if !screensaverOn && !emergencyActive && screensaverAfterS > 0 &&
            !idleView.isHidden && callingView.isHidden && offlineView.isHidden &&
            inCallView.isHidden && presentedViewController == nil &&
            Date().timeIntervalSince(lastActivity) > Double(screensaverAfterS) {
            enterScreensaver()
        }
        scheduleClockTick()
    }

    private func scheduleClockTick() {
        clockTimer?.invalidate()
        let wallMs = clockSource.reading()?.wallMs ?? 0
        let phase = Double((wallMs % 1000 + 1000) % 1000) / 1000
        let delay = wallMs > 0 ? max(0.01, 1 - phase) : 1
        clockTimer = IOSAvailability.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.onClockTick()
        }
    }

    /// Re-takes the clock's base from Core, off the main thread.
    private func refreshClockBase() {
        clockSource.refresh(core) { [weak self] cost in
            IOSAvailability.PerfProbe.record("clock.refresh", cost)
            self?.updateClock()
        }
    }

    /// Every clock is rendered from Core's zone-corrected reading, so a device whose own clock is
    /// wrong — or that sits in another zone — still shows the household's time.
    private func updateClock() {
        guard let reading = clockSource.reading() else { return }
        clockLabel.text = reading.hhmmss
        dateLabel.text = DoorbellClock.longDate(reading, lang: texts.lang)
        visitorScreen?.updateClock(reading, lang: texts.lang)
        // The dashboard is handed the same reading rather than asking Core for its own.
        dashboard?.updateClock(reading)
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
                let coreVersion = ConfigUtil.evStr(node, "version")
                let appVersion = DoorbellTheme.appVersion(coreVersion: coreVersion)
                appVersionLabel.text = "APP v\(appVersion)\nCore v\(DoorbellTheme.shortVersion(coreVersion))"
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

    /// Coalesces the home rebuild onto at most one pass per second, however many events Core
    /// announces in between. `withNodeInfo` asks for the wider pass that also re-reads the
    /// configuration, this node's status and the pairing state.
    private func scheduleHomeRefresh(withNodeInfo: Bool = false) {
        if withNodeInfo { nodeInfoRefreshPending = true }
        guard !homeRefreshPending else { return }
        homeRefreshPending = true
        let now = ProcessInfo.processInfo.systemUptime
        let due = max(0, lastHomeRefreshUptime + MainViewController.homeRefreshCoalesceS - now)
        DispatchQueue.main.asyncAfter(deadline: .now() + due) { [weak self] in
            guard let self = self else { return }
            self.homeRefreshPending = false
            self.lastHomeRefreshUptime = ProcessInfo.processInfo.systemUptime
            let wide = self.nodeInfoRefreshPending
            self.nodeInfoRefreshPending = false
            if wide { self.refreshNodeInfo() } else { self.refreshHomeSurfaces() }
        }
    }

    /// Recomputes the appearance and hands the current snapshot to whichever home screen this
    /// device shows. Both are pure renderers: they never read Core state on their own.
    private func refreshHomeSurfaces() {
        IOSAvailability.PerfProbe.measure("home.refresh") { refreshHomeSurfacesBody() }
    }

    private func refreshHomeSurfacesBody() {
        // One status document for the whole pass. This used to ask Core three separate times, and
        // every one of those is a synchronous hop onto Core's run loop.
        let status = core.status()
        // The clock's own base, not a fresh Core call: the appearance schedule and a notice's
        // expiry are both minute-scale decisions, and the base is never more than half a minute
        // old — `time_changed` re-takes it the moment Core's idea of the time moves.
        let reading = clockSource.reading()
        // The appearance, the theme picture and the scrim over it all come out of Core's display
        // contract, and this is the freshest copy of it: the status document this pass is already
        // holding. The values `applyDisplayValues` also owns — brightness, the night tint, the
        // screensaver timers — keep their own state and are not re-armed here.
        if let display = status?["display"] as? [String: Any] { displayDoc = display }
        palette = DoorbellPalette.of(DoorbellTheme.appearance(
            display: displayDoc, config: cfg, nodeId: nodeId,
            localTime: reading?.raw ?? core.localTime()))
        let skin = applyTheme()
        applyVolumes()
        updateClock()
        applyIdleControlSkin(skin)
        if let dashboard = dashboard {
            dashboard.reload(config: cfg, skin: skin)
        }
        if let visitor = visitorScreen {
            visitor.setLayoutStyle(ConfigUtil.str(cfg, "devices.\(nodeId).local.visitor_layout") ?? "standard")
            let notice = DoorbellNotice.effective(status: status, config: cfg,
                                                  door: boot.door,
                                                  nowMs: reading?.wallMs ?? DoorbellClock.nowMs(core))
            visitor.updateNotice(notice)
            visitor.setCallFlow(callFlowMode(), hasPurposes: !availablePurposeIds().isEmpty)
            let power = (status?["self"] as? [String: Any])?["power"] as? [String: Any]
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
                button.tintColor = skin.cardInk("tile_label")
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
        // This runs on every layout pass. The SOS slider is only a control on a screen whose role
        // offers one; styling it anywhere else would put it back, because a safety control's style
        // floor forces it visible.
        let sosOffered = ConfigUtil.sosButtonVisible(config: cfg, role: boot.role)
        let bindings: [(String, UIView, Bool)] = [
            ("call.primary", callButton, true), ("cancel.call", cancelButton, true),
            ("call.end", endCallButton, true), ("sos.trigger", sosSlider, sosOffered),
            ("sos.cancel", emergencyCancel, true), ("status.offline", offlineTitle, true),
        ]
        for (id, view, offered) in bindings {
            styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: id, to: view,
                               offered: offered)
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
        guard !callTimingSuspended, !nodeId.isEmpty,
              let snapshot = readCallTimingSnapshot(),
              core.runningGeneration == snapshot.coreGeneration,
              let calls = snapshot.document["active_calls"] as? [[String: Any]] else { return }
        if callTimingGeneration != snapshot.coreGeneration { resetCallTiming() }
        guard callTiming.accepts(snapshot) else { return }
        let requestedCallId = recoveryEvent.map { ConfigUtil.evStr($0, "call_id") } ?? ""
        for candidate in calls {
            let callId = ConfigUtil.evStr(candidate, "call_id")
            if !requestedCallId.isEmpty && callId != requestedCallId { continue }
            let door = ConfigUtil.evStr(candidate, "door")
            guard case .active(let reading) = callTiming.observeRecovery(snapshot, callId: callId,
                role: boot.role, nodeId: nodeId, door: boot.door,
                now: ProcessInfo.processInfo.systemUptime) else { continue }
            let call = reading.call
            let owner = ConfigUtil.evStr(call, "dialog_owner")
            let recoveryRequired = ConfigUtil.evBool(call, "recovery_required")
            if ConfigUtil.evStr(call, "state") == "in_call" {
                // A snapshot cannot recreate PJSIP media after Core restart.
                if owner == nodeId && recoveryRequired {
                    reportRecovery(callId, restored: false, generation: reading.coreGeneration)
                    return
                }
                continue
            }
            guard boot.role == "door_station", ConfigUtil.evStr(call, "origin") == nodeId,
                  door == boot.door else { continue }
            guard (reading.remainingSeconds ?? 0) > 0,
                  !recoveryRequired || reading.mayRestore else {
                // A zero, stale or incomplete timing sample is not a cancellation instruction.
                return
            }
            activeCallId = callId
            let sound = (ConfigUtil.dig(cfg, "ui.call_sound") as? String) ?? "outdoor_call_alert"
            callFeedbackAudio.playConfigured(sound,
                loops: ConfigUtil.bool(cfg, "ui.call_sound_loop", false))
            showCalling()
            let purposePending = ConfigUtil.evStr(call, "call_flow") == "ring_then_purpose" &&
                ConfigUtil.int(call, "stage_revision", 0) == 0 &&
                ConfigUtil.evStr(call, "purpose").isEmpty
            if purposePending && !emergencyActive && !availablePurposeIds().isEmpty {
                showPurposeChoice(afterRing: true)
            }
            if recoveryRequired {
                reportRecovery(callId, restored: true, generation: reading.coreGeneration)
            }
            return
        }
    }

    private func reportRecovery(_ callId: String, restored: Bool, generation: UInt64) {
        guard !callId.isEmpty, core.runningGeneration == generation else { return }
        let identity = "\(generation):\(callId)"
        guard reportedRecoveryCallId != identity else { return }
        reportedRecoveryCallId = identity
        core.reportCallRecovery(callId: callId, restored: restored, coreGeneration: generation)
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
                             httpPort: boot.httpPort, host: view,
                             hideImage: screensaverOn && screensaverMode == "minimal")
    }

    /// Only the purposes an administrator left switched on are offered here; the settings 用件
    /// list is the one surface that shows the others, because that is where they are switched
    /// back on.
    private func buildPurposeButtons() {
        for v in purposeGrid.arrangedSubviews { v.removeFromSuperview() }
        let purposes = (ConfigUtil.dig(cfg, "visit_purposes") as? [String: Any]) ?? [:]
        let ids = ConfigUtil.enabledPurposeIds(cfg)
        guard boot.role == "door_station", callFlowMode() == "purpose_first", !ids.isEmpty else {
            purposeSection.isHidden = true
            return
        }
        var row: UIStackView?
        for (i, id) in ids.enumerated() {
            if i % purposeColumns == 0 {
                row = UIStackView()
                row!.axis = .horizontal
                row!.spacing = 12
                row!.distribution = .fillEqually
                purposeGrid.addArrangedSubview(row!)
            }
            let entry = purposes[id] as? [String: Any]
            let label = ConfigUtil.labelOf(entry, texts.lang, id)
            let icon = entry?["icon"] as? String ?? ""
            let b = PurposeButton(type: .system)
            let glyph = TablerIcon.purpose(id) ?? TablerIcon.image("TablerNote")
            b.setImage(glyph, for: .normal)
            b.tintColor = idleSkin.cardInk("tile_label")
            b.imageView?.contentMode = .scaleAspectFit
            b.setTitle(TablerIcon.purpose(id) != nil || icon.isEmpty ? label : "\(icon) \(label)",
                       for: .normal)
            b.titleLabel?.font = IOSAvailability.visitorFont(size: 16, weight: .medium,
                                                            traits: traitCollection)
            b.titleLabel?.numberOfLines = 0
            b.titleLabel?.textAlignment = .center
            b.setTitleColor(idleSkin.cardInk("tile_label"), for: .normal)
            b.backgroundColor = idleSkin.surface
            b.layer.cornerRadius = 14
            // Width comes from the equal-width row; wrapped content determines its height.
            let minimum = b.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
            minimum.priority = UILayoutPriority(999)
            minimum.isActive = true
            let height = b.heightAnchor.constraint(greaterThanOrEqualToConstant: 88)
            b.contentHeight = height
            height.isActive = true
            b.accessibilityIdentifier = "purpose_\(id)"
            b.addTarget(self, action: #selector(onPurposeClick(_:)), for: .touchUpInside)
            row!.addArrangedSubview(b)
        }
        // A last row with one or two purposes in it keeps the column width of a full row rather
        // than stretching its buttons across the grid.
        if let last = row, last.arrangedSubviews.count < purposeColumns {
            for _ in last.arrangedSubviews.count..<purposeColumns { last.addArrangedSubview(UIView()) }
        }
        purposeSection.isHidden = false
    }

    @objc private func onPurposeClick(_ sender: UIButton) {
        guard callFlowMode() == "purpose_first", activeCallId.isEmpty else { return }
        guard let id = sender.accessibilityIdentifier?.dropFirst("purpose_".count) else { return }
        let purposeId = String(id)
        guard availablePurposeIds().contains(purposeId) else { return }
        let purposes = ConfigUtil.dig(cfg, "visit_purposes") as? [String: Any]
        let label = ConfigUtil.labelOf(purposes?[purposeId] as? [String: Any], texts.lang,
                                       purposeId)
        beginCall(purpose: purposeId, title: texts.t("purpose.sent", label))
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
            b.contentEdgeInsets = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
            #endif
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
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
            b.accessibilityTraits = on ? [.button, .selected] : .button
            let fill = on ? idleSkin.palette.accent : idleSkin.surface
            b.backgroundColor = fill
            let ink = on ? idleSkin.palette.onAccent : idleSkin.cardMuted("hint")
            DoorbellTheme.twoPartTitle(Texts.langDisplayName(code), on: b, primarySize: 17,
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
        screensaverBrightness = ConfigUtil.int(d, "screensaver.brightness", 10)
        screensaverMode = ConfigUtil.str(d, "screensaver.mode") ?? "dim"
        if screensaverAfterS <= 0 { exitScreensaver() }
        if screensaverOn { updateScreensaverPresentation() }
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
            setBrightness(screensaverOn ? min(brightness, screensaverBrightness) : brightness)
        }
    }

    private func setBrightness(_ percent: Int) {
        UIScreen.main.brightness = CGFloat(max(0, min(100, percent))) / 100.0
    }


    private func enterScreensaver() {
        guard !screensaverOn else { return }
        screensaverOn = true
        updateClock()
        updateScreensaverPresentation()
        moveSaverClock()
        saverDriftTimer = IOSAvailability.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.moveSaverClock()
        }
        setBrightness(min(brightness, screensaverBrightness))
    }

    private func updateScreensaverPresentation() {
        screensaverView.isHidden = !screensaverOn || screensaverMode != "clock"
        refreshHomeSurfaces()
    }

    private func exitScreensaver() {
        guard screensaverOn else { return }
        screensaverOn = false
        saverDriftTimer?.invalidate()
        saverDriftTimer = nil
        updateScreensaverPresentation()
        if !emergencyActive { setBrightness(brightness) }
    }

    private func moveSaverClock() {
        let w = max(1, screensaverView.bounds.width * 0.5)
        let h = max(1, screensaverView.bounds.height * 0.5)
        saverCenterX?.constant = CGFloat.random(in: -w / 2...w / 2)
        saverCenterY?.constant = CGFloat.random(in: -h / 2...h / 2)
    }

    private func refreshSosConfig() {
        let show = ConfigUtil.sosButtonVisible(config: cfg, role: boot.role)
        sosSlider.isHidden = !show
        // The visitor screen remembers it, so a rotation cannot put the slider back on a screen
        // whose role does not offer one.
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
        invalidateCallTimer()
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


    private func dismissPurposeChoice() {
        guard let alert = purposeChoice else { return }
        purposeChoice = nil
        alert.invalidate()
        if alert.isBeingPresented, let transition = alert.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { _ in
                alert.dismiss(animated: false)
            }
        } else {
            alert.dismiss(animated: false)
        }
    }

    private func showIdle(hint: String? = nil) {
        visitorActionRevision &+= 1
        dismissPurposeChoice()
        callFeedbackAudio.stop()
        callTitleOverride = nil
        invalidateCallTimer()
        pulse.layer.removeAllAnimations()
        callingView.isHidden = true
        offlineView.isHidden = true
        idleView.isHidden = false
        activeCallId = ""
        if let h = hint {
            touchHint.text = h
            visitorScreen?.updateHint(h)
        }
    }

    private func invalidateCallTimer() {
        callTimerRevision &+= 1
        callTimeoutTimer?.invalidate()
        callTimeoutTimer = nil
    }

    private func resetCallTiming() {
        invalidateCallTimer()
        callTiming.reset()
        let generation = core.runningGeneration
        if generation != callTimingGeneration { reportedRecoveryCallId = "" }
        callTimingGeneration = generation
    }

    private func suspendCallTiming() {
        visitorActionRevision &+= 1
        callTimingSuspended = true
        resetCallTiming()
        callTiming.requireFreshSnapshot(readCallTimingSnapshot())
    }

    private func resumeCallTiming() {
        callTimingSuspended = false
        resetCallTiming()
        callTiming.requireFreshSnapshot(readCallTimingSnapshot())
        refreshClockBase()
        refreshCallingDeadline()
    }

    private func readCallTimingSnapshot() -> CallTiming.Snapshot? {
#if DEBUG
        if let provider = callTimingSnapshotForTesting { return provider() }
#endif
        return core.callTimingSnapshot()
    }

    private func refreshCallingDeadline() {
        if core.runningGeneration != callTimingGeneration { resetCallTiming() }
        invalidateCallTimer()
        guard !callTimingSuspended else { return }
        if activeCallId.isEmpty {
            guard callTiming.waitingForFreshSnapshot else { return }
            restoreActiveCallIfNeeded()
            if !callTiming.waitingForFreshSnapshot { return }
        } else if callingView.isHidden && !inCall { return }
        let snapshot = readCallTimingSnapshot()
        let currentSnapshot = snapshot.flatMap {
            core.runningGeneration == $0.coreGeneration ? $0 : nil
        }
        let observation = callTiming.observe(currentSnapshot, callId: activeCallId, door: boot.door,
                                              now: ProcessInfo.processInfo.systemUptime)
        var delay: TimeInterval = 1
        switch observation {
        case .absent:
            if inCall { onSipIdle() }
            else { showIdle(hint: texts.t("calling.no_answer")) }
            return
        case .unavailable:
            callingDetail.text = texts.t("visitor.restoring")
        case .active(let reading):
            if ConfigUtil.evStr(reading.call, "state") == "in_call" {
                if inCall { return }
                callingDetail.text = texts.t("visitor.restoring")
            } else if let remaining = reading.remainingSeconds, remaining > 0 {
                callingDetail.text = texts.t("calling.wait_hint")
                delay = min(1, max(0.25, remaining))
            } else {
                callingDetail.text = texts.t("visitor.restoring")
            }
        }
        let expectedCall = activeCallId
        let expectedGeneration = core.runningGeneration
        let expectedTimer = callTimerRevision
        let callback: () -> Void = { [weak self] in
            guard let self = self, !self.callTimingSuspended,
                  self.callTimerRevision == expectedTimer,
                  self.core.runningGeneration == expectedGeneration,
                  self.activeCallId == expectedCall else { return }
            self.refreshCallingDeadline()
        }
#if DEBUG
        callTimerCallbackForTesting = callback
#endif
        callTimeoutTimer = IOSAvailability.scheduledTimer(withTimeInterval: delay, repeats: false) {
            _ in callback()
        }
    }

#if DEBUG
    func setVisibleCallForTimingTest(_ callId: String) {
        activeCallId = callId
        callingView.isHidden = false
    }

    func refreshVisitorForTesting() { refreshNodeInfo() }
    func visitorEventForTesting(_ event: [String: Any]) { onUiEvent(event) }
    func refreshCallTimingForTesting() { refreshCallingDeadline() }
    func suspendCallTimingForTesting() { suspendCallTiming() }
    func resumeCallTimingForTesting() { resumeCallTiming() }
    var visibleCallForTimingTest: String { return activeCallId }
    var callTimerRevisionForTesting: UInt64 { return callTimerRevision }
    var callDetailForTimingTest: String? { return callingDetail.text }
#endif

    private func showCalling(title: String? = nil) {
        exitScreensaver()
        if let t = title { callTitleOverride = t }
        callingText.text = callTitleOverride ?? texts.t("calling.title")
        callingDetail.text = texts.t("calling.wait_hint")
        idleView.isHidden = true
        callingView.isHidden = false
        refreshCallingDeadline()
        pulse.layer.removeAllAnimations()
        if safeMode || UIAccessibility.isReduceMotionEnabled {
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
            invalidateCallTimer()
            showIdle()
        case "wake_screen":
            if boot.role == "door_station" { onActivity() }
        case "event":
            let type = ConfigUtil.evStr(ev, "type")
            if type == "motion" || type == "press" {
                dashboard?.prioritizeDoor(ConfigUtil.evStr(ev, "door"))
            }
            let eventCall = ConfigUtil.evStr(ev, "call_id")
            if type == "press", boot.role == "door_station" {
                // A visitor who pressed the button expects the screen to be there, and on a
                // future physical button that press arrives here and nowhere else.
                let door = ConfigUtil.evStr(ev, "door")
                if door.isEmpty || door == boot.door { onActivity() }
            }
            if type == "press", !activeCallId.isEmpty, eventCall == activeCallId {
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
            // A replacement can arrive while the old picture is still on screen. Match the
            // effective configured hash rather than image == nil so that arrival retries the
            // replacement without refreshing for unrelated assets.
            let hash = ConfigUtil.evStr(ev, "hash")
            let configured = ConfigUtil.str(displayDoc, "theme.bg_image")
                ?? (!nodeId.isEmpty
                    ? ConfigUtil.str(cfg, "devices.\(nodeId).local.theme.bg_image") : nil)
                ?? ConfigUtil.str(cfg, "display.theme.bg_image")
            if !hash.isEmpty, hash == configured { scheduleHomeRefresh() }
        case "display":
            applyDisplayValues(ev)
            scheduleHomeRefresh()
        case "emergency":
            presentEmergency(ev)
        case "peers_changed", "config_changed":
            scheduleHomeRefresh(withNodeInfo: true)
        case "time_changed":
            // The source or the applied correction moved, so the base this clock is counting from
            // is stale: re-take it, then redraw every clock at once instead of waiting for the
            // next tick, and re-evaluate a scheduled light/dark switch.
            refreshClockBase()
            scheduleHomeRefresh()
        case "power_changed":
            core.refreshPowerStateCache()
            scheduleHomeRefresh()
        case "notice_changed":
            refreshConfigCache()
            scheduleHomeRefresh()
        case "call_log_changed":
            dashboard?.refreshHistory()
        case "pairing_state", "paired", "device_joined", "pairing_revoked", "pending_changed":
            refreshPairingStatus()
        default:
            break
        }
    }


    private func onSipInCall(_ ev: [String: Any]) {
        visitorActionRevision &+= 1
        dismissPurposeChoice()
        inCall = true
        callingText.text = texts.t("incall.title")
        guard boot.role == "door_station" else { return }
        invalidateCallTimer()
        let stream = ConfigUtil.evStr(ev, "peer_stream")
        peerPollTimer?.invalidate()
        peerPollTimer = nil
        showInCall(streamUrl: stream.isEmpty ? nil : stream)
        if stream.isEmpty && !safeMode {
            peerPollBusy = false
            peerPollTimer = IOSAvailability.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.expirePeerFrameIfNeeded()
                self?.pollPeerFrame()
            }
        }
    }

    private func onSipIdle() {
        visitorActionRevision &+= 1
        inCall = false
        closeInCall()
        if boot.role == "door_station" { showIdle() }
    }

    private var inCallStreamer: MjpegClient?

    private func showInCall(streamUrl: String?) {
        retirePeerFrameRequest()
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
        retirePeerFrameRequest()
        peerPollTimer?.invalidate()
        peerPollTimer = nil
        inCallStreamer?.stop()
        inCallStreamer = nil
        peerVideo.image = nil
        peerVideo.transform = .identity
        inCallView.isHidden = true
    }

    private func bindVisitorActionInput(_ button: UIButton) {
        button.addTarget(self, action: #selector(onVisitorActionDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(onVisitorActionCancelled(_:)),
                         for: [.touchCancel, .touchUpOutside])
    }

    private func visitorActionIdentity() -> VisitorActionIdentity {
        return VisitorActionIdentity(call: activeCallId, core: core.runningGeneration,
                                     revision: visitorActionRevision, inCall: inCall)
    }

    @objc private func onVisitorActionDown(_ sender: UIButton) {
        heldVisitorActions[ObjectIdentifier(sender)] = visitorActionIdentity()
    }

    @objc private func onVisitorActionCancelled(_ sender: UIButton) {
        heldVisitorActions.removeValue(forKey: ObjectIdentifier(sender))
    }

    private func consumeVisitorAction(_ button: UIButton) -> Bool {
        // Assistive activation has no held touch. A physical release must retain the identity
        // captured before any intervening call, Core or nil-ID SIP UI session transition.
        guard let captured = heldVisitorActions.removeValue(forKey: ObjectIdentifier(button)) else {
            return true
        }
        return captured == visitorActionIdentity()
    }

    @objc private func onEndCallClick() {
        guard consumeVisitorAction(endCallButton), inCall, !inCallView.isHidden else { return }
        core.sipHangup()
        onSipIdle()
    }

    private func pollPeerFrame() {
        guard inCall, !safeMode, !peerPollBusy,
              let identity = currentPeerFrameIdentity() else { return }
        let generation = peerPollGeneration
        peerPollBusy = true
        var components = URLComponents(string: "http://127.0.0.1:\(boot.httpPort)/peer-frame.jpg")!
        components.queryItems = [URLQueryItem(name: "door", value: boot.door),
            URLQueryItem(name: "call_id", value: identity.call),
            URLQueryItem(name: "stage_revision", value: String(identity.revision))]
        guard let url = components.url else { peerPollBusy = false; return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let complete: (Data?, URLResponse?) -> Void = { [weak self] data, resp in
            DispatchQueue.main.async {
                guard let self = self, self.peerPollGeneration == generation else { return }
                self.peerPollBusy = false
                self.peerPollTask = nil
                guard self.currentPeerFrameIdentity() == identity, self.inCall else { return }
                guard let response = resp as? HTTPURLResponse else { return }
                // The convenience header accessor requires iOS 13; this shell also supports iOS 9.
                func header(_ name: String) -> String? {
                    for (key, value) in response.allHeaderFields {
                        if String(describing: key).caseInsensitiveCompare(name) == .orderedSame {
                            return value as? String
                        }
                    }
                    return nil
                }
                guard response.statusCode == 200,
                      header("X-Doorbell-Call-Id") == identity.call,
                      header("X-Doorbell-Dialog-Owner") == identity.owner,
                      header("X-Doorbell-Stage-Revision") == String(identity.revision),
                      let media = header("X-Doorbell-Media-Generation"),
                      media.count == 32, media.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
                      let text = header("X-Doorbell-Frame-Sequence"),
                      text.count <= 19, text.range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil,
                      let sequence = UInt64(text), sequence <= UInt64(Int64.max),
                      media != self.peerMediaGeneration || sequence > self.peerFrameSequence,
                      let data = data, data.count <= 1024 * 1024,
                      let img = UIImage(data: data) else { return }
                self.peerMediaGeneration = media
                self.peerFrameSequence = sequence
                self.peerDisplayedFrameIdentity = identity
                self.peerLastValidFrameAt = self.peerFrameMonotonicTime
                self.peerVideo.image = img
            }
        }
#if DEBUG
        if let load = peerFrameLoadForTesting { load(request, complete); return }
#endif
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in complete(data, response) }
        peerPollTask = task
        task.resume()
    }

    private func currentPeerFrameIdentity() -> PeerFrameIdentity? {
        guard let snapshot = readCallTimingSnapshot(), snapshot.coreGeneration == core.runningGeneration,
              !activeCallId.isEmpty,
              let calls = snapshot.document["active_calls"] as? [[String: Any]],
              let call = calls.first(where: { ConfigUtil.evStr($0, "call_id") == activeCallId &&
                  ConfigUtil.evStr($0, "door") == boot.door && ConfigUtil.evStr($0, "state") == "in_call" }),
              let revision = call["stage_revision"] as? NSNumber,
              CFGetTypeID(revision) != CFBooleanGetTypeID(), revision.doubleValue >= 0,
              revision.doubleValue <= Double(Int32.max), revision.doubleValue.rounded(.down) == revision.doubleValue
        else { return nil }
        let owner = ConfigUtil.evStr(call, "dialog_owner")
        guard !owner.isEmpty else { return nil }
        return PeerFrameIdentity(core: snapshot.coreGeneration, call: activeCallId,
                                 revision: revision.intValue, owner: owner)
    }

    private var peerFrameMonotonicTime: TimeInterval {
#if DEBUG
        if let clock = peerFrameClockForTesting { return clock() }
#endif
        return ProcessInfo.processInfo.systemUptime
    }

    private func expirePeerFrameIfNeeded(now: TimeInterval? = nil) {
        guard let displayed = peerDisplayedFrameIdentity else { return }
        let current = currentPeerFrameIdentity()
        let received = peerLastValidFrameAt ?? 0
        let elapsed = (now ?? peerFrameMonotonicTime) - received
        guard current != displayed || received <= 0 || elapsed < 0 || elapsed > 3.0 else { return }
        peerVideo.image = nil
        peerVideo.transform = .identity
        peerDisplayedFrameIdentity = nil
        peerLastValidFrameAt = nil
    }

    private func retirePeerFrameRequest() {
        peerPollGeneration &+= 1
        peerPollTask?.cancel()
        peerPollTask = nil
        peerPollBusy = false
        peerMediaGeneration = ""
        peerFrameSequence = 0
        peerDisplayedFrameIdentity = nil
        peerLastValidFrameAt = nil
    }

#if DEBUG
    func setPeerCallForTesting(_ callId: String) {
        activeCallId = callId
        inCall = !callId.isEmpty
        if inCall { showInCall(streamUrl: nil) } else { closeInCall() }
    }
    func pollPeerFrameForTesting() { pollPeerFrame() }
    func expirePeerFrameForTesting(now: TimeInterval? = nil) { expirePeerFrameIfNeeded(now: now) }
    var peerFrameForTesting: UIImage? { peerVideo.image }
    var peerPollBusyForTesting: Bool { peerPollBusy }
    var inCallForTesting: Bool { inCall }
#endif


    @objc private func onCallClick() {
        guard activeCallId.isEmpty else { return }
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
        showCalling(title: title)
    }

    private func callFlowMode() -> String {
        let value = ConfigUtil.dig(cfg, "ui.call_flow")
        let mode = value as? String ?? (value as? [String: Any])?["mode"] as? String
        return mode == "ring_then_purpose" ? "ring_then_purpose" : "purpose_first"
    }

    private func availablePurposeIds() -> [String] {
        return ConfigUtil.enabledPurposeIds(cfg)
    }

    private func showPurposeChoice(afterRing: Bool) {
        let purposes = (ConfigUtil.dig(cfg, "visit_purposes") as? [String: Any]) ?? [:]
        guard presentedViewController == nil, !availablePurposeIds().isEmpty else { return }
        let items = availablePurposeIds().map { id in
            PurposeChoiceViewController.Item(id: id,
                title: ConfigUtil.labelOf(purposes[id] as? [String: Any], texts.lang, id),
                image: TablerIcon.purpose(id) ?? TablerIcon.image("TablerNote"))
        }
        let screen = PurposeChoiceViewController(items: items, palette: idleSkin.palette,
                                                afterRing: afterRing, texts: texts)
        let choiceCallId = activeCallId
        screen.onSelect = { [weak self] purposeId in
            guard let self = self else { return }
            let label = ConfigUtil.labelOf(purposes[purposeId] as? [String: Any], self.texts.lang,
                                           purposeId)
            if afterRing {
                guard !choiceCallId.isEmpty, self.activeCallId == choiceCallId else { return }
                if self.core.selectPurpose(door: self.boot.door, callId: choiceCallId,
                                           purpose: purposeId) {
                    self.showCalling(title: self.texts.t("purpose.sent", label))
                }
            } else {
                self.beginCall(purpose: purposeId, title: self.texts.t("purpose.sent", label))
            }
        }
        screen.onCancel = { [weak self] in
            guard afterRing, let self = self, self.activeCallId == choiceCallId else { return }
            self.onCancelClick()
        }
        purposeChoice = screen
        present(screen, animated: true)
    }

    @objc private func onCancelClick() {
        guard consumeVisitorAction(cancelButton), !inCall, !activeCallId.isEmpty else { return }
        // A queued touch may arrive after Core has answered. Only an accepted visitor cancel
        // may dismiss this call; a rejection keeps the authoritative call visible.
        guard core.cancelCall(door: boot.door, callId: activeCallId, reason: "visitor") else {
            refreshCallingDeadline()
            return
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
        // A deliberate exit from kiosk mode is the one thing allowed to let the screen sleep,
        // and it is remembered, so re-asserting the override on the next activation does not
        // silently undo the administrator's choice.
        settings.onExitKiosk = { ScreenAwake.want(false) }
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
        // This used to clear the idle timer here and put it back only from the OK button below.
        // Leaving through either of the other two actions left the panel able to auto-lock — and
        // an auto-locked panel is suspended, drops its listeners and is evicted without a trace.
        // The dialog has no need to let the screen sleep, so it no longer asks.
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
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in ScreenAwake.apply() })
        present(a, animated: true)
#endif
    }

    private func showPairingAdmin() {
        showAddDevicePanel()
    }


    /// The ask itself now happens at launch, before the first capability document. This asks
    /// again — `requestAccess` on an answered permission returns the answer without prompting —
    /// so that a screen built after the resident replied still starts capture and drops the
    /// banner.
    private func requestAvPermissionsThenStartCamera() {
        runtime?.permissionsDidChange()
        refreshCameraPermissionBanner()
        AvPermissions.requestAtLaunch(role: boot.role) { [weak self] in
            guard let self = self else { return }
            self.runtime?.permissionsDidChange()
            self.refreshCameraPermissionBanner()
            if self.boot.role == "door_station",
               AvPermissions.state(.video) == "authorized" {
                self.maybeStartCamera()
            }
        }
    }

    /// A door station that cannot see is worth saying out loud: from the other side of the mesh a
    /// refused camera and a broken one look the same, and the tile simply disappears.
    private func refreshCameraPermissionBanner() {
        let permission = AvPermissions.state(.video)
        let warn = AvPermissions.shouldWarn(role: boot.role, permission: permission)
        if warn && !cameraPermissionWarned {
            cameraPermissionWarned = true
            ShellLog.note("camera permission refused: \(permission)")
        }
        if !warn { cameraPermissionWarned = false }
        visitorScreen?.updateCameraWarning(warn ? texts.t("door.camera_denied") : nil)
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
        if videoEncoder.isRunning && core.takeVideoKeyframeRequest() {
            videoEncoder.requestKeyFrame()
        }
    }

    func debugRefreshH264() {
        IOSAvailability.logDebug("h264 debug refresh requested")
        encoderPoll()
    }
}

final class PurposeChoiceViewController: UIViewController {
    struct Item {
        let id: String
        let title: String
        let image: UIImage?
    }

    var onSelect: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let items: [Item]
    private let colors: DoorbellPalette
    private let afterRing: Bool
    private let texts: Texts
    private let heading = UILabel()
    private let hint = UILabel()
    private let scroll = UIScrollView()
    private let footer = UIView()
    private let cancel = UIButton(type: .system)
    private let skip = UIButton(type: .system)
    private var cards: [PurposeChoiceCard] = []
    private var finished = false

    init(items: [Item], palette: DoorbellPalette, afterRing: Bool, texts: Texts) {
        self.items = items
        colors = palette
        self.afterRing = afterRing
        self.texts = texts
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = colors.background
        view.accessibilityIdentifier = "purpose_choice_screen"
        heading.text = texts.t("idle.choose_purpose")
        heading.textColor = colors.ink
        heading.numberOfLines = 0
        heading.accessibilityTraits = .header
        hint.text = texts.t(afterRing ? "purpose.waiting_hint" : "purpose.choose_hint")
        hint.textColor = colors.inkMuted
        hint.numberOfLines = 0
        scroll.alwaysBounceVertical = false
        scroll.delaysContentTouches = false
        view.addSubview(scroll)
        scroll.addSubview(heading)
        scroll.addSubview(hint)
        view.addSubview(footer)
        for (index, item) in items.enumerated() {
            let card = PurposeChoiceCard(type: .custom)
            card.configure(item: item, colors: colors)
            card.tag = index
            card.addTarget(self, action: #selector(choose(_:)), for: .touchUpInside)
            scroll.addSubview(card)
            cards.append(card)
        }
        cancel.setTitle(texts.t(afterRing ? "purpose.cancel_call" : "admin.cancel"), for: .normal)
        cancel.setTitleColor(colors.ink, for: .normal)
        cancel.backgroundColor = colors.surfaceSolid
        cancel.accessibilityIdentifier = "purpose_choice_cancel"
        cancel.addTarget(self, action: #selector(cancelChoice), for: .touchUpInside)
        skip.setTitle(texts.t("purpose.skip"), for: .normal)
        skip.setTitleColor(colors.onAccent, for: .normal)
        skip.backgroundColor = colors.accent
        skip.isHidden = !afterRing
        skip.accessibilityIdentifier = "purpose_choice_skip"
        skip.addTarget(self, action: #selector(skipChoice), for: .touchUpInside)
        for button in [cancel, skip] {
            button.layer.cornerRadius = 18
            button.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
            button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
            footer.addSubview(button)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        var safe = UIEdgeInsets.zero
        if #available(iOS 11.0, *) { safe = view.safeAreaInsets }
        let bounds = view.bounds.inset(by: safe)
        let margin: CGFloat = bounds.width < 500 ? 20 : 36
        let width = min(1100, bounds.width - margin * 2)
        let left = bounds.midX - width / 2
        heading.font = IOSAvailability.visitorFont(size: bounds.width < 500 ? 30 : 38,
                                                    weight: .semibold, traits: traitCollection)
        hint.font = IOSAvailability.visitorFont(size: 20, traits: traitCollection)
        let gap: CGFloat = 16
        let scrollingSkip = afterRing && width < 440
        let actionWidth = afterRing && !scrollingSkip ? (width - gap) / 2 : width
        var actionHeight: CGFloat = 68
        for button in [cancel, skip] {
            button.titleLabel?.font = IOSAvailability.visitorFont(size: 22, weight: .semibold,
                                                                  traits: traitCollection)
            let height = button.titleLabel?.sizeThatFits(CGSize(width: max(1, actionWidth - 36),
                height: .greatestFiniteMagnitude)).height ?? 0
            actionHeight = max(actionHeight, ceil(height + 20))
        }
        footer.frame = CGRect(x: left, y: bounds.maxY - actionHeight - 24,
                              width: width, height: actionHeight)
        cancel.frame = CGRect(x: 0, y: 0, width: actionWidth, height: actionHeight)
        let skipParent = scrollingSkip ? scroll : footer
        if skip.superview !== skipParent { skipParent.addSubview(skip) }
        if !scrollingSkip {
            skip.frame = CGRect(x: actionWidth + gap, y: 0, width: actionWidth, height: actionHeight)
        }
        scroll.frame = CGRect(x: left, y: bounds.minY + 16, width: width,
                              height: max(0, footer.frame.minY - bounds.minY - 32))
        let headingHeight = heading.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        heading.frame = CGRect(x: 0, y: 0, width: width, height: headingHeight)
        let hintHeight = hint.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        hint.frame = CGRect(x: 0, y: heading.frame.maxY + 10, width: width, height: hintHeight)
        let columns = width >= 820 ? 3 : (width >= 440 ? 2 : 1)
        let rows = max(1, (items.count + columns - 1) / columns)
        let cardWidth = (width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let cardHeight = cards.reduce(CGFloat(150)) { max($0, $1.requiredHeight(width: cardWidth)) }
        var top = hint.frame.maxY + 24
        if scrollingSkip {
            skip.frame = CGRect(x: 0, y: top, width: width, height: actionHeight)
            top = skip.frame.maxY + 24
        }
        for (index, card) in cards.enumerated() {
            card.frame = CGRect(x: CGFloat(index % columns) * (cardWidth + gap),
                                y: top + CGFloat(index / columns) * (cardHeight + gap),
                                width: cardWidth, height: cardHeight)
        }
        scroll.contentSize = CGSize(width: width, height: top + CGFloat(rows) * (cardHeight + gap) - gap)
    }

    // A remote reply may arrive during presentation or before a queued touch callback.
    func invalidate() {
        finished = true
        onSelect = nil
        onCancel = nil
        viewIfLoaded?.isUserInteractionEnabled = false
    }

    @objc private func choose(_ sender: UIButton) {
        guard !finished, items.indices.contains(sender.tag) else { return }
        finished = true
        let id = items[sender.tag].id
        dismiss(animated: true) { self.onSelect?(id) }
    }

    @objc private func cancelChoice() {
        guard !finished else { return }
        finished = true
        dismiss(animated: true) { self.onCancel?() }
    }

    @objc private func skipChoice() {
        guard !finished else { return }
        finished = true
        dismiss(animated: true)
    }
}

private final class PurposeChoiceCard: UIButton {
    private let badge = UIView()
    private let glyph = UIImageView()
    private let label = UILabel()
    private var colors = DoorbellPalette.dark

    func configure(item: PurposeChoiceViewController.Item, colors: DoorbellPalette) {
        self.colors = colors
        backgroundColor = colors.surfaceSolid
        layer.cornerRadius = 24
        layer.borderWidth = 1
        layer.borderColor = colors.separator.cgColor
        badge.backgroundColor = colors.accent.withAlphaComponent(0.12)
        badge.layer.cornerRadius = 18
        badge.isUserInteractionEnabled = false
        glyph.image = item.image?.withRenderingMode(.alwaysTemplate)
        glyph.tintColor = colors.accent
        glyph.contentMode = .scaleAspectFit
        label.text = item.title
        label.textColor = colors.ink
        label.font = IOSAvailability.visitorFont(size: 26, weight: .medium, traits: traitCollection)
        label.numberOfLines = 0
        addSubview(badge)
        badge.addSubview(glyph)
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = item.title
        accessibilityIdentifier = "purpose_choice_" + item.id
        accessibilityTraits = .button
    }

    func requiredHeight(width: CGFloat) -> CGFloat {
        label.font = IOSAvailability.visitorFont(size: 26, weight: .medium, traits: traitCollection)
        return 102 + ceil(label.sizeThatFits(CGSize(width: max(1, width - 44),
                                                  height: .greatestFiniteMagnitude)).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        badge.frame = CGRect(x: 22, y: 20, width: 56, height: 56)
        glyph.frame = CGRect(x: 12, y: 12, width: 32, height: 32)
        label.frame = CGRect(x: 22, y: 86, width: bounds.width - 44, height: bounds.height - 102)
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? colors.surfaceStrongSolid : colors.surfaceSolid
            layer.borderColor = (isHighlighted ? colors.accent : colors.separator).cgColor
            layer.borderWidth = isHighlighted ? 2 : 1
        }
    }
}
