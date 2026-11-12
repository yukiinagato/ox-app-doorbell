import UIKit

enum IncomingCallAnswerState {
    case unreported
    case pending
    case accepted
    case rejected
}

struct IncomingCallLifecycleState {
    private(set) var answer = IncomingCallAnswerState.unreported
    private(set) var ended = false

    mutating func recordAnswer(_ result: CallLifecycleReportResult) -> Bool {
        switch result {
        case .accepted:
            answer = .accepted
            return false
        case .pending:
            answer = .pending
            return false
        case .rejected:
            answer = .rejected
            ended = true
            return true
        }
    }

    mutating func confirmAnswer(ownerIsLocal: Bool) -> Bool {
        answer = ownerIsLocal ? .accepted : .rejected
        if !ownerIsLocal { ended = true }
        return !ownerIsLocal
    }

    var mayReportEnd: Bool { answer == .accepted || answer == .pending }

    mutating func recordEnd(_ result: CallLifecycleReportResult) {
        _ = result
        ended = true
    }

    mutating func reset() { self = IncomingCallLifecycleState() }
}

final class IncomingViewController: UIViewController {

    private let core: CoreBridge
    private let coreGeneration: UInt64?
    private let boot: BootConfig
    private let texts = Texts()
    private let styleApplier = UIStyleApplier()
    private var nodeId = ""
    private var door: String
    private var purpose: String
    private var visitorLang: String
    private var callId: String
    private var stageRevision: Int
    private var revisionLifecycle: CallRevisionLifecycle
    private var lastChimeRevision: Int

    private var queue = ResidentCallQueue()
    private let queueStack = UIStackView()
    private let occupancyLabel = UILabel()
    private let conversationControls = UIStackView()
    private var conversationButtons: [String: UIButton] = [:]
    private var conversationDocuments: [String: [String: Any]] = [:]
    private var touchedConversationVersion: Int64?
    private var actionTarget: String?
    private var selectedIsLive = true
    private var endingDialog = false
    private var renderedQueue: [ResidentCallQueue.Item] = []
    private var renderedSelection = ""

    private var cfg: [String: Any]?
    private var videoPlayer: AdaptiveH264MjpegPlayer?
    private var incomingStreamUrl = ""
    private var incomingStreamMp4Url = ""
    private var peerHost: String?
    private var directPort = 47190
    private var sipMode = ""
    private var inCall = false
    private var callLifecycle = IncomingCallLifecycleState()
    private var safeMode = UserDefaults.standard.bool(forKey: "runtime.safe_mode")
    private var answerDelayTimer: Timer?
    /// When this panel returns to its home page, and the number beside the title that says so.
    private var returnCountdown = IncomingReturnCountdown(seconds: 0)
    private let returnButton = UIButton(type: .system)

    private let videoBackdrop = UIView()
    /// Pinch, drag and double-tap zoom for the live picture, whichever renderer is drawing it.
    private let videoZoom = ZoomableVideoView()
    private let liveView = UIImageView()
    private let h264View = UIView()
    private let noVideoLabel = UILabel()
    private let titleLabel = UILabel()
    private let purposeBadge = PaddedLabel()
    private let langBadge = PaddedLabel()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let replyStack = UIStackView()
    private let answerButton = CallActionButton(type: .custom)
    private let monitorButton = CallActionButton(type: .custom)
    private let micButton = CallActionButton(type: .custom)
    private let unlockButton = CallActionButton(type: .custom)
    private let ignoreButton = CallActionButton(type: .custom)
    private let quickReplyButton = CallActionButton(type: .custom)
    private let actionZone = ActionZoneView()
    private let detailScroll = UIScrollView()
    private lazy var noticeChip = NoticeChipView(texts: texts)
    private lazy var adminQr = AdminQrView(core: core, boot: boot, texts: texts, compact: true)
    private let purposeSlot = UIView()
    private let debugLine = UILabel()
    private var debugTimer: Timer?
    private var micMuted = false
    private var debugCollapsed = false
    private var monitorOn = false
    private var replyExpanded = false
    private var videoAspect: NSLayoutConstraint?
    private var lastDeviceInfoRefresh: CFTimeInterval = 0
    private var styleObserver: NSObjectProtocol?

    private static let debugHiddenKey = "incoming.debug_line_hidden"

    private static let handlerKey = "incoming"

    init(core: CoreBridge, boot: BootConfig, door: String, purpose: String, visitorLang: String,
         callId: String, stageRevision: Int = 0) {
        self.core = core
        self.coreGeneration = core.runningGeneration
        self.boot = boot
        self.door = door
        self.purpose = purpose
        self.visitorLang = visitorLang
        self.callId = callId
        let normalizedRevision = max(0, stageRevision)
        self.stageRevision = normalizedRevision
        self.revisionLifecycle = CallRevisionLifecycle(stageRevision: normalizedRevision)
        self.lastChimeRevision = normalizedRevision
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not supported") }


    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SystemStyle.background
        cfg = core.config()
        if let node = core.status()?["node"] as? [String: Any] {
            nodeId = ConfigUtil.evStr(node, "id")
        }
        texts.setConfig(cfg)
        texts.setLang(boot.uiLang)
        directPort = ConfigUtil.int(cfg, "sip.direct_port", 47190)
        queue.admit(ResidentCallQueue.Item(door: door, callId: callId, revision: stageRevision,
            purpose: purpose, language: visitorLang, state: "ringing", owner: ""))
        buildUi()
        applyContent()
        reconcileQueue()

        let peer = ConfigUtil.findDoorPeer(core.status(), door: door)
        peerHost = ConfigUtil.peerHost(peer)
        incomingStreamUrl = peer.flatMap { ConfigUtil.str($0, "stream") } ?? ""
        incomingStreamMp4Url = peer.flatMap { ConfigUtil.str($0, "stream_mp4") } ?? ""
        answerButton.isEnabled = peerHost != nil && selectedIsLive
        startVideo(url: incomingStreamUrl)

        core.addHandler(IncomingViewController.handlerKey) { [weak self] ev in
            self?.onUiEvent(ev)
        }
        debugTimer = IOSAvailability.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            self?.refreshDebugLine()
            self?.syncMicFromStatus()
            self?.reconcileQueue()
            self?.tickReturnCountdown()
        }
        returnCountdown = IncomingReturnCountdown(
            seconds: IncomingReturnCountdown.seconds(status: core.status()))
        updateReturnCountdown()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoPlayer?.layout()
        applySemanticStyles()
    }

    /// UIKit also calls this when a full-screen child (the announcement dialog on a compact
    /// device or on tvOS) covers the call. That is not the resident leaving: the call, its media
    /// and its event handler stay up, and only an actual dismissal tears them down.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard presentedViewController == nil || isBeingDismissed ||
              presentingViewController == nil else { return }
        tearDownCall()
    }

    private var tornDown = false

    /// The single owner of hang-up and media release when this screen goes away.
    private func tearDownCall() {
        guard !tornDown else { return }
        tornDown = true
        if let calls = core.status()?["active_calls"] as? [[String: Any]] {
            for call in calls {
                guard let room = roomDocument(call),
                      let members = room["participants"] as? [[String: Any]],
                      members.contains(where: { ConfigUtil.evStr($0, "device") == nodeId }) else { continue }
                _ = core.conversation(["door": ConfigUtil.evStr(call, "door"),
                    "call_id": ConfigUtil.evStr(call, "call_id"),
                    "stage_revision": ConfigUtil.int(call, "stage_revision", 0),
                    "expected_version": ConfigUtil.int(room, "version", 0), "action": "leave"])
            }
        }
        core.removeHandler(IncomingViewController.handlerKey)
        debugTimer?.invalidate()
        debugTimer = nil
        answerDelayTimer?.invalidate()
        videoPlayer?.stop()
        videoPlayer = nil
        videoZoom.resetZoom()
        if !sipMode.isEmpty {
            reportEndedIfNeeded()
            core.sipHangup(coreGeneration: coreGeneration)
            sipMode = ""
        }
    }

    func enterSafeModeForMemoryPressure() {
        safeMode = true
        videoPlayer?.stop()
        videoPlayer = nil
        liveView.image = nil
        liveView.transform = .identity
        videoZoom.resetZoom()
        noVideoLabel.isHidden = false
        // Keep the established audio dialog and its End Call button visible. viewDidDisappear is
        // still the single owner that hangs up when the user actually leaves this screen.
    }

    func refresh(purpose: String, visitorLang: String, callId: String, stageRevision: Int) {
        let normalizedRevision = max(0, stageRevision)
        let update = revisionLifecycle.observeWinningRevision(normalizedRevision)
        guard update != .stale else { return }
        self.purpose = purpose
        self.visitorLang = visitorLang
        self.callId = callId
        self.stageRevision = revisionLifecycle.stageRevision
        queue.admit(ResidentCallQueue.Item(door: door, callId: callId, revision: self.stageRevision,
            purpose: purpose, language: visitorLang, state: inCall ? "in_call" : "ringing", owner: ""))
        renderQueue()
        if update == .answerSuperseded { demoteSupersededAnswer() }
        cfg = core.config()
        applyContent()
        if !inCall { restartReturnCountdown() }
    }

    func receive(door newDoor: String, purpose: String, visitorLang: String, callId newCallId: String,
                 stageRevision newStageRevision: Int = 0) {
        let targetDoor = newDoor.isEmpty ? door : newDoor
        guard targetDoor != door || newCallId != callId else {
            let normalizedRevision = max(0, newStageRevision)
            guard normalizedRevision > lastChimeRevision else { return }
            lastChimeRevision = normalizedRevision
            let update = revisionLifecycle.observeWinningRevision(normalizedRevision)
            self.purpose = purpose
            self.visitorLang = visitorLang
            self.stageRevision = max(self.stageRevision, normalizedRevision)
            queue.admit(ResidentCallQueue.Item(door: door, callId: callId, revision: self.stageRevision,
                purpose: purpose, language: visitorLang, state: inCall ? "in_call" : "ringing", owner: ""))
            renderQueue()
            if update == .answerSuperseded { demoteSupersededAnswer() }
            cfg = core.config()
            applyContent()
            if !inCall {
                selectedIsLive = true
                answerButton.isEnabled = peerHost != nil
                restartReturnCountdown()
            }
            return
        }
        queue.admit(ResidentCallQueue.Item(door: targetDoor, callId: newCallId,
            revision: max(0, newStageRevision), purpose: purpose, language: visitorLang,
            state: "ringing", owner: ""))
        renderQueue()
    }

    private func selectCall(_ item: ResidentCallQueue.Item) {
        guard (!inCall || usesConversation), !endingDialog, sipMode.isEmpty, answerDelayTimer == nil,
              let selected = queue.select(door: item.door, callId: item.callId) else { return }
        if usesConversation {
            _ = core.conversation(["action": "select", "door": selected.door, "call_id": selected.callId])
            inCall = false
        }
        let targetDoor = selected.door
        let purpose = selected.purpose
        let visitorLang = selected.language
        let newCallId = selected.callId
        let newStageRevision = selected.revision
        selectedIsLive = selected.state == "ringing"
        answerDelayTimer?.invalidate()
        answerDelayTimer = nil
        if !sipMode.isEmpty { core.sipHangup(coreGeneration: coreGeneration) }
        sipMode = ""
        self.door = targetDoor
        self.purpose = purpose
        self.visitorLang = visitorLang
        self.callId = newCallId
        stageRevision = max(0, newStageRevision)
        revisionLifecycle = CallRevisionLifecycle(stageRevision: stageRevision)
        lastChimeRevision = stageRevision
        callLifecycle.reset()
        videoZoom.resetZoom()
        cfg = core.config()
        texts.setConfig(cfg)
        directPort = ConfigUtil.int(cfg, "sip.direct_port", 47190)
        applyContent()
        hintLabel.isHidden = true
        let peer = ConfigUtil.findDoorPeer(core.status(), door: targetDoor)
        peerHost = ConfigUtil.peerHost(peer)
        incomingStreamUrl = peer.flatMap { ConfigUtil.str($0, "stream") } ?? ""
        incomingStreamMp4Url = peer.flatMap { ConfigUtil.str($0, "stream_mp4") } ?? ""
        answerButton.isEnabled = peerHost != nil && selectedIsLive
        startVideo(url: incomingStreamUrl)
        restartReturnCountdown()
        reconcileQueue()
    }

    private var selectedSnapshot: [String: Any]? {
        let calls = core.status()?["active_calls"] as? [[String: Any]] ?? []
        return calls.first { ConfigUtil.evStr($0, "door") == door && ConfigUtil.evStr($0, "call_id") == callId }
    }

    private var usesConversation: Bool {
        #if os(tvOS)
        return false
        #else
        return selectedSnapshot.map { ConfigUtil.evBool($0, "conversation_supported") } ?? false
        #endif
    }

    private func roomDocument(_ call: [String: Any]) -> [String: Any]? {
        let snapshot = call["conversation"] as? [String: Any]
        let event = conversationDocuments[ConfigUtil.evStr(call, "call_id")]
        if let event = event, ConfigUtil.int(event, "version", 0) > ConfigUtil.int(snapshot, "version", 0) { return event }
        return snapshot
    }

    private func conversationRequest(_ action: String, version: Int64? = nil) -> [String: Any] {
        let room = selectedSnapshot.flatMap { roomDocument($0) }
        return ["action": action, "door": door, "call_id": callId, "stage_revision": stageRevision,
                "expected_version": version ?? Int64(ConfigUtil.int(room, "version", 0))]
    }

    private func sendConversation(_ request: [String: Any]) {
        if !sipMode.isEmpty { core.sipHangup(coreGeneration: coreGeneration); sipMode = ""; inCall = false }
        let result = core.conversation(request)
        hintLabel.text = texts.t(ConfigUtil.evBool(result ?? [:], "ok") ? "conversation.pending" : "conversation.failed")
        hintLabel.isHidden = false
    }

    @objc private func onConversationAction(_ sender: UIButton) {
        let version = touchedConversationVersion
        touchedConversationVersion = nil
        guard actionStillTargetsSelection(), let action = sender.accessibilityIdentifier else { return }
        let request = conversationRequest(action, version: version)
        if action == "takeover" {
            let alert = UIAlertController(title: texts.t("conversation.takeover"),
                message: texts.t("conversation.takeover_confirm"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: texts.t("conversation.takeover"), style: .destructive) { [weak self] _ in
                self?.sendConversation(request)
            })
            present(alert, animated: !Motion.reduced)
        } else { sendConversation(request) }
    }

    private func refreshConversationControls() {
        conversationControls.isHidden = !usesConversation
        guard usesConversation, let call = selectedSnapshot else { return }
        let room = roomDocument(call)
        let members = room?["participants"] as? [[String: Any]] ?? []
        let me = members.first { ConfigUtil.evStr($0, "device") == nodeId }
        let state = ConfigUtil.evStr(me ?? [:], "state")
        let localMedia = ConfigUtil.evBool(call, "conversation_local_media")
        inCall = state == "connected" && localMedia
        selectedIsLive = true
        answerButton.setTitle(texts.t(me == nil || state == "waiting" ? "conversation.answer" : "conversation.leave"), for: .normal)
        answerButton.isEnabled = me != nil || ConfigUtil.evStr(room ?? [:], "owner").isEmpty
        for (action, button) in conversationButtons {
            button.isHidden = !(action == "respond" && me == nil ||
                (action == "join" || action == "takeover") && me == nil && !ConfigUtil.evStr(room ?? [:], "owner").isEmpty ||
                action == "hold" && state == "connected" && localMedia ||
                action == "resume" && (state == "held" || state == "connected" && !localMedia))
        }
        monitorButton.isHidden = true
        if !state.isEmpty {
            let key = state == "waiting" ? "conversation.queued" : "conversation." + state
            statusLabel.text = texts.t(key, ConfigUtil.labelOf(ConfigUtil.dig(cfg, "doors.\(door)") as? [String: Any], boot.uiLang, door))
        }
        if state == "connected" || state == "held" || state == "dialing" { returnCountdown.pauseForCall() }
    }

    private func reconcileQueue() {
        guard let status = core.status(),
              let calls = status["active_calls"] as? [[String: Any]] else { return }
        occupancyLabel.text = calls.flatMap { call -> [String] in
            let callDoor = ConfigUtil.evStr(call, "door")
            let doorEntry = ConfigUtil.dig(cfg, "doors.\(callDoor)") as? [String: Any]
            let doorName = ConfigUtil.labelOf(doorEntry, boot.uiLang, callDoor)
            if let room = roomDocument(call), let members = room["participants"] as? [[String: Any]] {
                return members.map { member in
                    let owner = ConfigUtil.evStr(member, "device")
                    let entry = ConfigUtil.dig(cfg, "devices.\(owner)") as? [String: Any]
                    let name = ConfigUtil.labelOf(entry, boot.uiLang, owner)
                    let state = ConfigUtil.evStr(member, "state")
                    return doorName + " · " + texts.t(state == "waiting" ? "conversation.queued" : "conversation." + state, name)
                }
            }
            guard ConfigUtil.evStr(call, "state") == "in_call" else { return [] }
            let owner = ConfigUtil.evStr(call, "dialog_owner")
            let entry = ConfigUtil.dig(cfg, "devices.\(owner)") as? [String: Any]
            return [texts.t("ring.queue_in_call", ConfigUtil.labelOf(entry, boot.uiLang, owner), doorName)]
        }.joined(separator: "\n")
        occupancyLabel.isHidden = occupancyLabel.text?.isEmpty != false
        for call in calls where ConfigUtil.evBool(call, "notification_eligible") {
            let item = ResidentCallQueue.Item(door: ConfigUtil.evStr(call, "door"),
                callId: ConfigUtil.evStr(call, "call_id"),
                revision: ConfigUtil.int(call, "stage_revision", -1),
                purpose: ConfigUtil.evStr(call, "purpose"),
                language: ConfigUtil.evStr(call, "visitor_lang"),
                state: roomDocument(call).map { ConfigUtil.evStr($0, "phase") } ?? ConfigUtil.evStr(call, "state"),
                owner: roomDocument(call).map { ConfigUtil.evStr($0, "owner") } ?? ConfigUtil.evStr(call, "dialog_owner"))
            queue.admit(item)
            if item.door == door && item.callId == callId && item.revision >= stageRevision &&
               item.state == "in_call" && item.owner != nodeId && !inCall {
                selectedIsLive = false
                answerButton.isEnabled = false
            }
        }
        renderQueue()
        refreshConversationControls()
    }

    private func renderQueue() {
        guard isViewLoaded else { return }
        let selection = door + ":" + callId
        guard renderedQueue != queue.items || renderedSelection != selection else { return }
        renderedQueue = queue.items
        renderedSelection = selection
        for child in queueStack.arrangedSubviews {
            queueStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        queueStack.isHidden = queue.items.count < 2 && queue.items.allSatisfy { $0.callId == callId }
        for item in queue.items {
            let entry = ConfigUtil.dig(cfg, "doors.\(item.door)") as? [String: Any]
            let name = ConfigUtil.labelOf(entry, boot.uiLang, item.door)
            let button = UIButton(type: .system)
            let current = item.door == door && item.callId == callId
            let title: String
            if item.state != "ringing", !item.owner.isEmpty {
                let ownerEntry = ConfigUtil.dig(cfg, "devices.\(item.owner)") as? [String: Any]
                let ownerName = ConfigUtil.labelOf(ownerEntry, boot.uiLang, item.owner)
                title = item.state == "in_call" ? texts.t("ring.queue_in_call", ownerName, name)
                    : name + " · " + texts.t("conversation." + item.state, ownerName)
            } else {
                title = texts.t(current ? "ring.queue_selected" : "ring.queue_waiting", name)
            }
            button.setTitle(title, for: .normal)
            button.contentHorizontalAlignment = .left
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.font = SystemStyle.font(.body, weight: current ? .semibold : nil)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.accessibilityIdentifier = item.door + ":" + item.callId
            button.addTarget(self, action: #selector(onQueueSelection(_:)), for: .touchUpInside)
            queueStack.addArrangedSubview(button)
        }
    }

    @objc private func onQueueSelection(_ sender: UIButton) {
        guard let item = queue.items.first(where: { $0.door + ":" + $0.callId == sender.accessibilityIdentifier }),
              item.door != door || item.callId != callId else { return }
        guard (!inCall || usesConversation), !endingDialog, sipMode.isEmpty, answerDelayTimer == nil else {
            hintLabel.text = texts.t("ring.queue_finish_first")
            hintLabel.isHidden = false
            return
        }
        selectCall(item)
    }

    @objc private func captureActionTarget() {
        actionTarget = door + ":" + callId + ":" + String(stageRevision)
        touchedConversationVersion = Int64(ConfigUtil.int(selectedSnapshot.flatMap { roomDocument($0) }, "version", 0))
    }

    private func actionStillTargetsSelection() -> Bool {
        defer { actionTarget = nil }
        return actionTarget == nil || actionTarget == door + ":" + callId + ":" + String(stageRevision)
    }

    private func buildUi() {
        // The call screen is a system surface: the picture keeps its own black frame, and the
        // details and actions sit on the system background.
        videoBackdrop.backgroundColor = .black
        videoBackdrop.clipsToBounds = true
        videoBackdrop.accessibilityIdentifier = "incoming_video"
        videoBackdrop.accessibilityHint = texts.t("ring.video_zoom_hint")
        videoBackdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoBackdrop)

        videoZoom.translatesAutoresizingMaskIntoConstraints = false
        videoBackdrop.addSubview(videoZoom)
        liveView.contentMode = .scaleAspectFit
        videoZoom.host(liveView)
        videoZoom.host(h264View)

        noVideoLabel.font = SystemStyle.font(.title3)
        noVideoLabel.textColor = UIColor(white: 1, alpha: 0.6)
        noVideoLabel.textAlignment = .center
        noVideoLabel.numberOfLines = 0
        noVideoLabel.translatesAutoresizingMaskIntoConstraints = false
        videoBackdrop.addSubview(noVideoLabel)

        titleLabel.font = SystemStyle.font(.title1, weight: .bold)
        titleLabel.textColor = SystemStyle.label
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        titleLabel.accessibilityTraits = .header
        SystemStyle.followContentSize(titleLabel)

        // The return countdown reads as the title's own "(60)" suffix but is a control: it is a
        // button so it carries a real tap target and an accessibility label, and it keeps its
        // natural width beside a title that is allowed to shrink.
        returnButton.titleLabel?.font = SystemStyle.digits(size: 22, weight: .semibold)
        returnButton.isHidden = true
        returnButton.accessibilityIdentifier = "ring_return_countdown"
        returnButton.accessibilityLabel = texts.t("ring.return_countdown_a11y")
        returnButton.addTarget(self, action: #selector(onCancelReturnCountdown),
                               for: .primaryActionTriggered)
        returnButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        returnButton.setContentHuggingPriority(.required, for: .horizontal)
        returnButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        returnButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for badge in [purposeBadge, langBadge] {
            badge.font = SystemStyle.font(.subheadline, weight: .semibold)
            badge.layer.cornerRadius = 8
            badge.clipsToBounds = true
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            SystemStyle.followContentSize(badge)
        }

        // The announcement is a compact chip, not a bar: a dot marks an active announcement and a
        // tap opens the same editor the home screen uses, with this door already selected.
        noticeChip.onTap = { [weak self] in self?.openNoticeDialog() }

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, returnButton])
        titleRow.axis = .horizontal
        titleRow.spacing = Space.xs
        titleRow.alignment = .firstBaseline

        // The purpose the visitor chose keeps its own slot under the door name. The slot holds its
        // height even when it is empty, so a purpose arriving after the ring never shifts the
        // layout under the user's finger.
        purposeBadge.translatesAutoresizingMaskIntoConstraints = false
        purposeSlot.translatesAutoresizingMaskIntoConstraints = false
        purposeSlot.addSubview(purposeBadge)
        NSLayoutConstraint.activate([
            purposeSlot.heightAnchor.constraint(equalToConstant: 40),
            purposeBadge.leadingAnchor.constraint(equalTo: purposeSlot.leadingAnchor),
            purposeBadge.centerYAnchor.constraint(equalTo: purposeSlot.centerYAnchor),
            purposeBadge.trailingAnchor.constraint(lessThanOrEqualTo: purposeSlot.trailingAnchor),
        ])
        let badgeRow = UIStackView(arrangedSubviews: [purposeSlot, langBadge, noticeChip])
        badgeRow.axis = .horizontal
        badgeRow.spacing = Space.xs
        badgeRow.alignment = .center

        statusLabel.font = SystemStyle.font(.body)
        statusLabel.textColor = SystemStyle.secondaryLabel
        statusLabel.numberOfLines = 0
        SystemStyle.followContentSize(statusLabel)

        hintLabel.font = SystemStyle.font(.body, weight: .semibold)
        hintLabel.textColor = SystemStyle.positive
        hintLabel.numberOfLines = 0
        hintLabel.isHidden = true
        hintLabel.accessibilityIdentifier = "incoming_hint"
        SystemStyle.followContentSize(hintLabel)

        replyStack.axis = .vertical
        replyStack.spacing = 12
        replyStack.isHidden = true

        let buttons: [(CallActionButton, Selector, String)] = [
            (answerButton, #selector(onAnswer), "incoming_answer"),
            (monitorButton, #selector(onMonitor), "incoming_monitor"),
            (micButton, #selector(onMic), "incoming_mic"),
            (unlockButton, #selector(onUnlock), "incoming_unlock"),
            (ignoreButton, #selector(onIgnore), "incoming_ignore"),
            (quickReplyButton, #selector(onToggleReplies), "incoming_quick_reply"),
        ]
        for (button, action, identifier) in buttons {
            styleActionButton(button, prominent: button === answerButton)
            button.addTarget(self, action: action, for: .primaryActionTriggered)
            button.accessibilityIdentifier = identifier
        }
        applyButtonVisibility()
        // The fixed action zone (ui-guidelines section 4): Answer, the largest and the positive
        // control, then Reply and Ignore; Monitor, Unlock and the in-call microphone below. In a
        // call, End takes Answer's place, so the hand never has to look for it.
        actionZone.setActions(primary: [answerButton, quickReplyButton, ignoreButton],
                              secondary: [monitorButton, unlockButton, micButton])
        actionZone.accessibilityIdentifier = "incoming_actions"
        actionZone.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionZone)

        // Muted single line with the player's live counters. It never covers the video, and the
        // choice to hide it is remembered on this device.
        debugLine.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        debugLine.textColor = SystemStyle.tertiaryLabel
        debugLine.numberOfLines = 1
        debugLine.adjustsFontSizeToFitWidth = true
        debugLine.minimumScaleFactor = 0.7
        debugLine.accessibilityIdentifier = "incoming_debug_line"
        debugLine.isUserInteractionEnabled = true
        debugLine.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(onToggleDebugLine)))
        // Collapsed rather than removed: the strip stays in place so the counters can be
        // brought back with the same tap that hid them.
        debugCollapsed = UserDefaults.standard.bool(forKey: IncomingViewController.debugHiddenKey)
        debugLine.heightAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true

        queueStack.axis = .vertical
        queueStack.spacing = 4
        for button in [answerButton, unlockButton, quickReplyButton, monitorButton, ignoreButton] {
            button.addTarget(self, action: #selector(captureActionTarget), for: .touchDown)
        }
        occupancyLabel.numberOfLines = 0
        occupancyLabel.textColor = SystemStyle.secondaryLabel
        occupancyLabel.font = SystemStyle.font(.footnote)
        occupancyLabel.isHidden = true
        conversationControls.axis = .vertical
        conversationControls.spacing = 4
        conversationControls.isHidden = true
        for action in ["respond", "join", "takeover", "hold", "resume"] {
            let button = UIButton(type: .system)
            button.setTitle(texts.t("conversation." + action), for: .normal)
            button.titleLabel?.font = SystemStyle.font(.body)
            button.contentHorizontalAlignment = .left
            button.accessibilityIdentifier = action
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addTarget(self, action: #selector(captureActionTarget), for: .touchDown)
            button.addTarget(self, action: #selector(onConversationAction(_:)), for: .touchUpInside)
            conversationButtons[action] = button
            conversationControls.addArrangedSubview(button)
        }
        let details = UIStackView(arrangedSubviews: [titleRow, badgeRow, statusLabel, hintLabel,
                                                     occupancyLabel, queueStack,
                                                     conversationControls, replyStack, debugLine,
                                                     adminQr])
        details.axis = .vertical
        details.spacing = Space.s
        details.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.alwaysBounceVertical = false
        detailScroll.addSubview(details)
        view.addSubview(detailScroll)

        let g = IOSAvailability.safeAreaLayoutGuide(for: view)
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            videoZoom.topAnchor.constraint(equalTo: videoBackdrop.topAnchor),
            videoZoom.bottomAnchor.constraint(equalTo: videoBackdrop.bottomAnchor),
            videoZoom.leadingAnchor.constraint(equalTo: videoBackdrop.leadingAnchor),
            videoZoom.trailingAnchor.constraint(equalTo: videoBackdrop.trailingAnchor),
            noVideoLabel.centerXAnchor.constraint(equalTo: videoBackdrop.centerXAnchor),
            noVideoLabel.centerYAnchor.constraint(equalTo: videoBackdrop.centerYAnchor),
            noVideoLabel.widthAnchor.constraint(lessThanOrEqualTo: videoBackdrop.widthAnchor,
                                                constant: -Space.l),

            videoBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
            videoBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoBackdrop.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),

            details.topAnchor.constraint(equalTo: detailScroll.topAnchor),
            details.bottomAnchor.constraint(equalTo: detailScroll.bottomAnchor),
            details.leadingAnchor.constraint(equalTo: detailScroll.leadingAnchor),
            details.trailingAnchor.constraint(equalTo: detailScroll.trailingAnchor),
            details.widthAnchor.constraint(equalTo: detailScroll.widthAnchor),

            detailScroll.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: actionZone.topAnchor,
                                                 constant: -Space.m),
            actionZone.leadingAnchor.constraint(equalTo: detailScroll.leadingAnchor),
            actionZone.trailingAnchor.constraint(equalTo: detailScroll.trailingAnchor),
            actionZone.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -Space.m),
        ])
        actionZone.setContentCompressionResistancePriority(.required, for: .vertical)
        // Side by side: the picture takes the leading two thirds at full height.
        landscapeCs = [
            videoBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoBackdrop.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.64),
            detailScroll.topAnchor.constraint(equalTo: g.topAnchor, constant: Space.m),
            detailScroll.leadingAnchor.constraint(equalTo: videoBackdrop.trailingAnchor,
                                                  constant: Space.l),
        ]
        // Stacked: the picture on top at its own aspect, never more than half the screen.
        let stackedHeight = videoBackdrop.heightAnchor.constraint(equalTo: view.heightAnchor,
                                                                  multiplier: 0.42)
        stackedHeight.priority = UILayoutPriority(750)
        portraitCs = [
            videoBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stackedHeight,
            videoBackdrop.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor,
                                                  multiplier: 0.5),
            detailScroll.topAnchor.constraint(equalTo: videoBackdrop.bottomAnchor,
                                              constant: Space.m),
            detailScroll.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
        ]
        applyOrientationConstraints()
        styleObserver = NotificationCenter.default.addObserver(
            forName: SystemStyle.changed, object: nil, queue: .main
        ) { [weak self] _ in self?.applyColors() }
    }

    deinit {
        if let observer = styleObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private var landscapeCs: [NSLayoutConstraint] = []
    private var portraitCs: [NSLayoutConstraint] = []

    private func applyOrientationConstraints(for size: CGSize? = nil) {
        let s = size ?? view.bounds.size
        let side = LayoutClass.sideBySide(s)
        NSLayoutConstraint.deactivate(side ? portraitCs : landscapeCs)
        NSLayoutConstraint.activate(side ? landscapeCs : portraitCs)
        videoAspect?.isActive = !side
    }

    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        applyOrientationConstraints(for: size)
    }

    private func styleActionButton(_ b: CallActionButton, prominent: Bool) {
        b.titleLabel?.font = SystemStyle.font(prominent ? .subheadline : .footnote,
                                              weight: prominent ? .semibold : .regular)
        b.setTitleColor(SystemStyle.label, for: .normal)
        b.backgroundColor = prominent ? ColorRole.positive : SystemStyle.fill
        b.glyphColor = prominent ? .white : SystemStyle.label
    }

    private func applyContent() {
        let doorEntry = ConfigUtil.dig(cfg, "doors.\(door)") as? [String: Any]
        let label = ConfigUtil.labelOf(doorEntry, boot.uiLang, door)
        titleLabel.text = texts.t("ring.incoming", label)
        noVideoLabel.text = texts.t("ring.no_video")
        statusLabel.text = texts.t("reply.choose")
        updateToggleTitles()
        updateUnlockVisibility()
        updateNoticeChip()
        updateBadges()
        buildReplyButtons()
    }

    /// Both toggles show their state, so nobody has to guess whether the door can hear the room.
    ///
    /// Every label in this row is authored in two parts — what the control does, then the state
    /// it is in — and rendered with the smaller second line, because six controls share one row
    /// and a state suffix is exactly the phrase that would otherwise be shrunk to fit. The colour
    /// and size are read back off the button, so a semantic override an administrator set is
    /// still what gets painted.
    private func updateToggleTitles() {
        let titles: [(UIButton, String)] = [
            (monitorButton, texts.t(monitorOn ? "ring.monitor_two_line_on"
                                              : "ring.monitor_two_line_off")),
            (answerButton, texts.t(inCall ? "incall.end" : "ring.answer")),
            (micButton, texts.t(micMuted ? "ring.mic_two_line_off" : "ring.mic_two_line_on")),
            (unlockButton, texts.t("ring.unlock")),
            (quickReplyButton, texts.t("ring.quick_reply")),
            (ignoreButton, texts.t("ring.ignore")),
        ]
        for (button, text) in titles {
            DoorbellTheme.twoPartTitle(text, on: button,
                                       primarySize: button.titleLabel?.font.pointSize ?? 13,
                                       color: button.titleColor(for: .normal) ?? SystemStyle.label,
                                       focusColor: SystemStyle.label, bold: button === answerButton)
            button.invalidateIntrinsicContentSize()
        }
        // The same vendored icons on every shell: handset, crossed handset, reply bubble.
        answerButton.icon = inCall ? "TablerPhoneOff" : "TablerPhone"
        quickReplyButton.icon = "TablerMessageReply"
        ignoreButton.icon = "TablerBellOff"
        monitorButton.icon = "TablerVolume"
        unlockButton.icon = "TablerLockOpen"
        micButton.icon = micMuted ? "TablerMicrophoneOff" : "TablerMicrophone"
        // A toggle that is on wears the control colour, so its state reads without the caption.
        answerButton.backgroundColor = inCall ? SystemStyle.negative : ColorRole.positive
        monitorButton.backgroundColor = monitorOn ? SystemStyle.tint : SystemStyle.fill
        monitorButton.glyphColor = monitorOn ? DoorbellTheme.readableInk(on: SystemStyle.tint)
                                             : SystemStyle.label
        micButton.backgroundColor = micMuted ? SystemStyle.label : SystemStyle.fill
        micButton.glyphColor = micMuted ? SystemStyle.background : SystemStyle.label
        micButton.isEnabled = inCall
        applyButtonVisibility()
    }

    /// The one place that decides which call controls exist. A build without PJSIP cannot answer,
    /// monitor or mute; tvOS has no microphone and no unlock; the in-call state swaps the
    /// pre-answer controls for the microphone. Unlock visibility is the administrator's choice
    /// and lives in `updateUnlockVisibility`.
    private func applyButtonVisibility() {
        let sipCapable = core.sipBackend == "pjsip"
        #if os(tvOS)
        let hasMicrophone = false
        #else
        let hasMicrophone = true
        #endif
        answerButton.isHidden = !sipCapable || !hasMicrophone
        monitorButton.isHidden = !sipCapable || inCall
        micButton.isHidden = !sipCapable || !hasMicrophone || !inCall
        quickReplyButton.isHidden = inCall
        ignoreButton.isHidden = inCall
        actionZone.refreshRows()
    }

    /// The unlock control stays, and an administrator decides whether it is offered. When it is
    /// shown without a configured action, pressing it says so instead of doing nothing.
    private func updateUnlockVisibility() {
        #if os(tvOS)
        unlockButton.isHidden = true
        #else
        unlockButton.isHidden = !DoorUnlock.showsButton(status: core.status(), config: cfg,
                                                        door: door)
        #endif
        actionZone.refreshRows()
    }

    private func updateNoticeChip() {
        let status = core.status()
        let notice = DoorbellNotice.effective(status: status, config: cfg, door: door,
                                              nowMs: DoorbellClock.nowMs(core))
        SystemStyle.adopt(display: status?["display"] as? [String: Any], config: cfg,
                          nodeId: nodeId, localTime: core.localTime())
        applyColors()
        noticeChip.update(active: notice != nil)
        updateDoorStationAdminEntry(status: status)
        adminQr.reload()
    }

    private func updateDoorStationAdminEntry(status: [String: Any]?) {
        let peer = ConfigUtil.findDoorPeer(status, door: door)
        adminQr.setTargetURL(ConfigUtil.peerAdminURL(peer))
        // The caption describes the device the code opens: the door station, not this panel.
        adminQr.setDetailText(DoorbellTheme.peerVersionLine(peer: peer, texts: texts))
    }

    /// Every colour here is a system role. The answer disc is the positive role and turns into
    /// the negative one while a call is up; the quieter actions sit on the system fill. The video
    /// keeps its own black frame, because a picture is what belongs there.
    private func applyColors() {
        view.backgroundColor = SystemStyle.background
        titleLabel.textColor = SystemStyle.label
        statusLabel.textColor = SystemStyle.secondaryLabel
        hintLabel.textColor = SystemStyle.positive
        occupancyLabel.textColor = SystemStyle.secondaryLabel
        debugLine.textColor = SystemStyle.tertiaryLabel
        for button in [monitorButton, micButton, unlockButton, quickReplyButton, ignoreButton] {
            button.setTitleColor(SystemStyle.label, for: .normal)
            button.backgroundColor = SystemStyle.fill
            button.glyphColor = SystemStyle.label
        }
        answerButton.setTitleColor(SystemStyle.label, for: .normal)
        answerButton.backgroundColor = inCall ? SystemStyle.negative : ColorRole.positive
        answerButton.glyphColor = .white
        purposeBadge.backgroundColor = SystemStyle.tint
        purposeBadge.textColor = DoorbellTheme.readableInk(on: SystemStyle.tint)
        langBadge.backgroundColor = SystemStyle.fill
        langBadge.textColor = SystemStyle.label
        adminQr.refreshColors()
        updateToggleTitles()
    }

    private func openNoticeDialog() {
        guard presentedViewController == nil else { return }
        let dialog = NoticeDialogViewController(core: core, texts: texts, httpPort: boot.httpPort,
                                                lang: boot.uiLang, door: door)
        // Over the call, never instead of it: the call screen stays in the hierarchy, so its
        // media and SIP dialog are not torn down while the announcement is edited.
        dialog.modalPresentationStyle = NoticeDialogViewController.overCallPresentationStyle
        present(dialog, animated: true)
    }

    private func updateBadges() {
        let entry = purpose.isEmpty ? nil
            : ConfigUtil.dig(cfg, "visit_purposes.\(purpose)") as? [String: Any]
        if purpose.isEmpty {
            // The slot keeps its height, so a purpose that arrives after the ring does not move
            // the controls under the user's finger.
            purposeBadge.isHidden = true
        } else {
            let label = ConfigUtil.labelOf(entry, boot.uiLang, purpose)
            purposeBadge.text = label
            purposeBadge.accessibilityLabel = texts.t("ring.purpose_badge", label)
            purposeBadge.isHidden = false
        }
        if visitorLang.isEmpty || visitorLang == "ja" {
            langBadge.isHidden = true
        } else {
            langBadge.text = Texts.langDisplayName(visitorLang)
            langBadge.accessibilityLabel =
                texts.t("ring.lang_badge", Texts.langDisplayName(visitorLang))
            langBadge.isHidden = false
        }
    }

    private func buildReplyButtons() {
        for v in replyStack.arrangedSubviews { v.removeFromSuperview() }
        defer { replyStack.isHidden = !replyExpanded || replyStack.arrangedSubviews.isEmpty }
        guard !inCall else { return }
        guard let replies = ConfigUtil.dig(cfg, "quick_replies") as? [String: Any],
              !replies.isEmpty else { return }
        let lang = visitorLang.isEmpty ? "ja" : visitorLang
        for id in ConfigUtil.sortedByOrder(replies) {
            let entry = replies[id] as? [String: Any]
            let b = UIButton(type: .system)
            b.setTitle(ConfigUtil.labelOf(entry, lang, id), for: .normal)
            SystemStyle.style(b, kind: .gray, classic: true)
            b.accessibilityIdentifier = "qr_button_\(id)"
            b.addTarget(self, action: #selector(onReply(_:)), for: .primaryActionTriggered)
            replyStack.addArrangedSubview(b)
            styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: "reply.button", to: b)
        }
    }

    private func applySemanticStyles() {
        styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: "ring.title", to: titleLabel)
        for button in [answerButton, monitorButton, micButton, unlockButton, quickReplyButton,
                       ignoreButton] {
            styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: "ring.action", to: button)
        }
        if inCall {
            styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: "call.end",
                               to: answerButton)
        }
        for button in replyStack.arrangedSubviews {
            styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: "reply.button", to: button)
        }
        // The style applier paints through setTitleColor/font, which an attributed title ignores;
        // re-rendering the two-part labels afterwards is what carries the override onto them.
        updateToggleTitles()
    }


    private func startVideo(url: String) {
        videoPlayer?.stop()
        let player = AdaptiveH264MjpegPlayer(h264Host: h264View, mjpegView: liveView,
                                             noVideoLabel: noVideoLabel)
        player.onVideoSize = { [weak self] size in self?.applyVideoAspect(size) }
        videoPlayer = player
        player.start(h264URLString: incomingStreamMp4Url, mjpegURL: url, h264Enabled: !safeMode)
    }

    /// The video box takes the door camera's own aspect when it is stacked above the details, so
    /// a portrait stream is shown portrait and is never cropped or stretched. Beside the details
    /// the box fills its column and the picture is letterboxed inside it.
    private func applyVideoAspect(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if let existing = videoAspect { existing.isActive = false }
        let constraint = videoBackdrop.heightAnchor.constraint(equalTo: videoBackdrop.widthAnchor,
                                                                multiplier: size.height / size.width)
        constraint.priority = UILayoutPriority(900)
        constraint.isActive = !LayoutClass.sideBySide(view.bounds.size)
        videoAspect = constraint
        view.setNeedsLayout()
    }

    /// A call arrived, or the screen went back to ringing: the return starts over.
    private func restartReturnCountdown() {
        returnCountdown.restart()
        updateReturnCountdown()
    }

    /// The call ended. The panel is unattended again, so the full countdown runs once more rather
    /// than the screen vanishing under whoever just hung up.
    private func resumeReturnCountdown() {
        returnCountdown.resumeAfterCall()
        updateReturnCountdown()
    }

    private func tickReturnCountdown() {
        guard queue.items.filter({ $0.door != door || $0.callId != callId }).isEmpty else { return }
        guard returnCountdown.tick() else {
            updateReturnCountdown()
            return
        }
        updateReturnCountdown()
        close()
    }

    /// The number is a control, not decoration: a resident who taps it is reading the screen and
    /// wants it to stay.
    @objc private func onCancelReturnCountdown() {
        returnCountdown.stop()
        updateReturnCountdown()
    }

    private func updateReturnCountdown() {
        switch returnCountdown.display {
        case .hidden:
            returnButton.isHidden = true
        case .seconds(let left):
            returnButton.isHidden = false
            returnButton.setTitle("(\(left))", for: .normal)
        }
    }

    /// Dismisses this screen together with anything presented over it. `dismiss` on self would
    /// only close the topmost child (for example an open announcement dialog) and leave the
    /// ended call on screen. Dismissing through the presenter keeps a screen the call was
    /// stacked over (Settings, History) where the resident left it.
    private func close() {
        if let presenter = presentingViewController {
            presenter.dismiss(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    private func demoteSupersededAnswer() {
        answerDelayTimer?.invalidate()
        answerDelayTimer = nil
        _ = callLifecycle.confirmAnswer(ownerIsLocal: false)
        inCall = false
        sipMode = ""
        monitorOn = false
        answerButton.isEnabled = false
        updateUnlockVisibility()
        hintLabel.isHidden = true
        core.sipHangup(coreGeneration: coreGeneration)
    }


    @objc private func onAnswer() {
        if usesConversation {
            guard actionStillTargetsSelection() else { return }
            let room = selectedSnapshot.flatMap { roomDocument($0) }
            let members = room?["participants"] as? [[String: Any]] ?? []
            let me = members.first { ConfigUtil.evStr($0, "device") == nodeId }
            let action = me == nil || ConfigUtil.evStr(me ?? [:], "state") == "waiting" ? "answer" : "leave"
            sendConversation(conversationRequest(action, version: touchedConversationVersion))
            touchedConversationVersion = nil
            return
        }
        guard actionStillTargetsSelection(), !endingDialog, selectedIsLive || inCall else { return }
        guard let host = peerHost else { return }
        if inCall {
            endingDialog = true
            reportEndedIfNeeded()
            core.sipHangup(coreGeneration: coreGeneration)
            sipMode = ""
            inCall = false
            resumeReturnCountdown()
            updateToggleTitles()
            return
        }
        guard let calls = core.status()?["active_calls"] as? [[String: Any]],
              calls.contains(where: { ConfigUtil.evStr($0, "door") == door &&
                  ConfigUtil.evStr($0, "call_id") == callId &&
                  ConfigUtil.int($0, "stage_revision", -1) == stageRevision &&
                  ConfigUtil.evStr($0, "state") == "ringing" }) else {
            selectedIsLive = false
            answerButton.isEnabled = false
            reconcileQueue()
            return
        }
        revisionLifecycle.beginAnswer()
        answerButton.isEnabled = false
        returnCountdown.pauseForCall()
        updateReturnCountdown()
        if sipMode == "monitor" {
            monitorOn = false
            core.sipHangup(coreGeneration: coreGeneration)
            answerDelayTimer?.invalidate()
            let expectedDoor = door
            let expectedCall = callId
            let expectedRevision = stageRevision
            answerDelayTimer = IOSAvailability.scheduledTimer(withTimeInterval: 0.4,
                                                    repeats: false) { [weak self] _ in
                guard let self = self, self.door == expectedDoor, self.callId == expectedCall,
                      self.stageRevision == expectedRevision, self.selectedIsLive else { return }
                self.answerDelayTimer = nil
                self.placeAnswerCall(host: host)
            }
            return
        }
        placeAnswerCall(host: host)
    }

    private func placeAnswerCall(host: String) {
        statusLabel.text = texts.t("calling.title")
        sipMode = "answer"
        callLifecycle.reset()
        core.sipCall(target: "sip:\(host):\(directPort)", mode: "answer",
                     coreGeneration: coreGeneration)
    }

    /// Monitoring is a stateful toggle: pressing it again stops playing the door's audio.
    @objc private func onMonitor() {
        guard actionStillTargetsSelection(), !endingDialog else { return }
        guard let host = peerHost else { return }
        if monitorOn && sipMode == "monitor" {
            core.sipHangup(coreGeneration: coreGeneration)
            sipMode = ""
            monitorOn = false
            hintLabel.isHidden = true
            updateToggleTitles()
            return
        }
        guard sipMode.isEmpty else { return }
        sipMode = "monitor"
        monitorOn = true
        core.sipCall(target: "sip:\(host):\(directPort)", mode: "monitor",
                     coreGeneration: coreGeneration)
        hintLabel.text = texts.t("ring.monitoring")
        hintLabel.isHidden = false
        updateToggleTitles()
    }

    @objc private func onIgnore() {
        guard actionStillTargetsSelection(), !inCall, sipMode.isEmpty else { return }
        queue.retire(door: door, callId: callId, revision: stageRevision)
        selectedIsLive = false
        answerButton.isEnabled = false
        renderQueue()
        if queue.items.isEmpty { close() }
    }

    /// Microphone mute during an established dialog. Core does not publish the entry point yet;
    /// until it does, the control says so rather than pretending to have muted anything.
    @objc private func onMic() {
        guard inCall else { return }
        guard core.supportsMicMute else {
            hintLabel.text = texts.t("ring.mic_unavailable")
            hintLabel.isHidden = false
            return
        }
        let target = !micMuted
        guard core.setMicMuted(target) else {
            hintLabel.text = texts.t("ring.mic_unavailable")
            hintLabel.isHidden = false
            return
        }
        micMuted = target
        updateToggleTitles()
    }

    /// Core remembers the mute across a call and reapplies it when media becomes active, so the
    /// toggle follows `status.call.mic_muted` rather than only what this screen last pressed.
    private func syncMicFromStatus() {
        guard let status = core.status() else { return }
        let now = CACurrentMediaTime()
        if now - lastDeviceInfoRefresh >= 30 {
            lastDeviceInfoRefresh = now
            updateDoorStationAdminEntry(status: status)
        }
        guard let call = status["call"] as? [String: Any], call["mic_muted"] != nil else { return }
        let reported = ConfigUtil.evBool(call, "mic_muted")
        guard reported != micMuted else { return }
        micMuted = reported
        updateToggleTitles()
    }

    /// Quick replies open as a bottom sheet (compact) or a popover (wider windows). The call
    /// screen stays underneath and alive, and one tap sends.
    @objc private func onToggleReplies() {
        guard actionStillTargetsSelection() else { return }
        guard !inCall, presentedViewController == nil,
              let replies = ConfigUtil.dig(cfg, "quick_replies") as? [String: Any],
              !replies.isEmpty else { return }
        let lang = visitorLang.isEmpty ? "ja" : visitorLang
        let choices = ConfigUtil.sortedByOrder(replies).map { id in
            ActionSheetController.Choice(id: id, title: ConfigUtil.labelOf(
                replies[id] as? [String: Any], lang, id))
        }
        let expectedDoor = door
        let expectedCall = callId
        let expectedRevision = stageRevision
        let sheet = ActionSheetController(title: texts.t("ring.quick_reply"), choices: choices,
                                          source: quickReplyButton) {
            [weak self] choice in
            guard let self = self, self.door == expectedDoor, self.callId == expectedCall,
                  self.stageRevision == expectedRevision else { return }
            self.sendQuickReply(id: choice.id, title: choice.title)
        }
        present(sheet, animated: !Motion.reduced)
    }

    /// The debug line is opt-in and the choice is remembered on this device.
    @objc private func onToggleDebugLine() {
        debugCollapsed.toggle()
        UserDefaults.standard.set(debugCollapsed, forKey: IncomingViewController.debugHiddenKey)
        refreshDebugLine()
    }

    private func refreshDebugLine() {
        guard !debugCollapsed, let stats = videoPlayer?.statsSnapshot() else {
            debugLine.text = ""
            return
        }
        debugLine.text = "\(stats.codec) · \(stats.latencyMs) ms · ±\(stats.jitterMs) ms"
            + " · \(stats.fps) fps · drop \(stats.dropped)"
    }

    /// The existing open-door action. Core answers -3 when nothing is configured anywhere and -4
    /// when a configured command failed to run; each is explained rather than silently ignored.
    @objc private func onUnlock() {
        guard actionStillTargetsSelection() else { return }
        switch core.openDoor(door: door, callId: callId, stageRevision: stageRevision) {
        case 0: hintLabel.text = texts.t("ring.unlock_sent")
        case -3: hintLabel.text = texts.t("door.unlock_not_configured")
        default: hintLabel.text = texts.t("ring.unlock_failed")
        }
        hintLabel.isHidden = false
    }

    @objc private func onReply(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier?.dropFirst("qr_button_".count) else { return }
        sendQuickReply(id: String(id), title: sender.currentTitle ?? "")
    }

    private func sendQuickReply(id: String, title: String) {
        guard !inCall else { return }
        let accepted = core.quickReplyV2(replyId: id, door: door, callId: callId,
                                         stageRevision: stageRevision)
        hintLabel.text = accepted ? texts.t("reply.sent", title) : texts.t("reply.failed")
        hintLabel.isHidden = false
        if accepted && !inCall { restartReturnCountdown() }
    }


    private func onUiEvent(_ ev: [String: Any]) {
        if let coreGeneration, core.runningGeneration != coreGeneration { return }
        switch ConfigUtil.evStr(ev, "t") {
        case "conversation":
            let id = ConfigUtil.evStr(ev, "call_id")
            if ConfigUtil.int(ev, "version", 0) > ConfigUtil.int(conversationDocuments[id], "version", 0) {
                conversationDocuments[id] = ev
            }
            reconcileQueue()
        case "conversation_media":
            reconcileQueue()
        case "conversation_result":
            if !ConfigUtil.evBool(ev, "ok") {
                hintLabel.text = texts.t("conversation.failed")
                hintLabel.isHidden = false
            }
        case "state":
            let st = ConfigUtil.evStr(ev, "state")
            if st == "in_call" {
                onSipInCall(ev)
            } else if st == "idle" {
                endingDialog = false
                if revisionLifecycle.consumeSupersededIdle() {
                    inCall = false
                    sipMode = ""
                    monitorOn = false
                    answerButton.isEnabled = peerHost != nil
                    updateToggleTitles()
                    updateUnlockVisibility()
                    statusLabel.text = texts.t("reply.choose")
                    restartReturnCountdown()
                    return
                }
                let was = inCall
                if was { reportEndedIfNeeded() }
                inCall = false
                sipMode = ""
                // A monitor dialog that ended leaves nothing playing, so the toggle must not go
                // on claiming the room is being listened to. Nothing reopens it: the only way
                // back into monitor here is the button.
                monitorOn = false
                updateToggleTitles()
                if was { resumeReturnCountdown() }
            }
        case "reply":
            let d = ConfigUtil.evStr(ev, "door")
            if !inCall && (d.isEmpty || d == door) {
                if queue.items.contains(where: { $0.door != door || $0.callId != callId }) {
                    selectedIsLive = false
                    answerButton.isEnabled = false
                    statusLabel.text = texts.t("reply.sent", ConfigUtil.evStr(ev, "text"))
                } else { close() }
            }
        case "event":
            let type = ConfigUtil.evStr(ev, "type")
            let d = ConfigUtil.evStr(ev, "door")
            let retiredId = ConfigUtil.evStr(ev, "call_id")
            let retiredRevision = ConfigUtil.int(ev, "stage_revision", -1)
            if ["call_ended", "call_cancelled", "reply"].contains(type) {
                queue.retire(door: d, callId: retiredId, revision: retiredRevision)
                if d == door && retiredId == callId && retiredRevision >= stageRevision {
                    selectedIsLive = false
                    if !inCall { answerButton.isEnabled = false }
                }
                renderQueue()
            }
            guard d.isEmpty || d == door else { break }
            let eventCallId = ConfigUtil.evStr(ev, "call_id")
            guard eventCallId.isEmpty || eventCallId == callId else { break }
            let eventStageRevision = ConfigUtil.int(ev, "stage_revision", 0)
            if type == "purpose_selected" {
                let updatedVisitorLang = ConfigUtil.evStr(ev, "visitor_lang")
                refresh(purpose: ConfigUtil.evStr(ev, "purpose"),
                        visitorLang: updatedVisitorLang.isEmpty ? visitorLang : updatedVisitorLang,
                        callId: eventCallId.isEmpty ? callId : eventCallId,
                        stageRevision: ConfigUtil.int(ev, "stage_revision", stageRevision))
            } else if type == "call_answered", eventStageRevision >= stageRevision {
                if usesConversation { reconcileQueue(); break }
                let reportedOwner = ConfigUtil.evStr(ev, "dialog_owner")
                let owner = reportedOwner.isEmpty ? ConfigUtil.evStr(ev, "device") : reportedOwner
                if !owner.isEmpty, !nodeId.isEmpty, owner == nodeId {
                    _ = callLifecycle.confirmAnswer(ownerIsLocal: true)
                    if !inCall { close() }
                } else if !owner.isEmpty, !nodeId.isEmpty, owner != nodeId {
                    // Another confirmed answer won Core's deterministic ownership claim. End the
                    // losing SIP leg without publishing call_ended for the winner's dialog.
                    _ = callLifecycle.confirmAnswer(ownerIsLocal: false)
                    inCall = false
                    sipMode = ""
                    endingDialog = true
                    core.sipHangup(coreGeneration: coreGeneration)
                    selectedIsLive = false
                    answerButton.isEnabled = false
                    let ownerEntry = ConfigUtil.dig(cfg, "devices.\(owner)") as? [String: Any]
                    statusLabel.text = texts.t("ring.queue_answered_elsewhere",
                        ConfigUtil.labelOf(ownerEntry, boot.uiLang, owner))
                    reconcileQueue()
                }
            } else if type == "call_ended", eventStageRevision >= stageRevision {
                reportEndedIfNeeded()
                resumeReturnCountdown()
            } else if type == "call_cancelled", !inCall {
                // The visitor gave up, but a resident may still be walking towards the panel and
                // the live view is what they are coming for. The page stays until the return
                // countdown ends or somebody leaves it by hand.
                statusLabel.text = texts.t("ring.cancelled")
            }
        case "visitor_lang":
            let d = ConfigUtil.evStr(ev, "door")
            if d.isEmpty || d == door {
                visitorLang = ConfigUtil.evStr(ev, "lang")
                updateBadges()
                buildReplyButtons()
            }
        case "notice_changed", "config_changed", "display":
            cfg = core.config()
            updateNoticeChip()
            updateUnlockVisibility()
        case "emergency":
            // Yield only to a rule-selected visual in-app alert. A system-notification-only SOS
            // must not disrupt an active incoming-call screen.
            if ConfigUtil.evBool(ev, "active") &&
                ConfigUtil.eventUsesChannel(ev, "in_app") &&
                ConfigUtil.evBool(ev, "visual") { close() }
        default:
            break
        }
    }

    private func onSipInCall(_ ev: [String: Any]) {
        guard sipMode == "answer" else { return }
        guard !endingDialog else { return }
        inCall = true
        monitorOn = false
        micMuted = false
        updateToggleTitles()
        buildReplyButtons()
        if callLifecycle.answer == .unreported {
            let result = core.reportCallAnsweredResult(door: door, callId: callId,
                                                       stageRevision: stageRevision,
                                                       coreGeneration: coreGeneration)
            if callLifecycle.recordAnswer(result) {
                inCall = false
                sipMode = ""
                endingDialog = true
                core.sipHangup(coreGeneration: coreGeneration)
                selectedIsLive = false
                answerButton.isEnabled = false
                reconcileQueue()
                if queue.items.count <= 1 { close() }
                return
            }
        }
        returnCountdown.pauseForCall()
        updateReturnCountdown()
        answerButton.isEnabled = true
        updateToggleTitles()
        updateUnlockVisibility()
        statusLabel.text = texts.t("incall.title")
        hintLabel.isHidden = true
        let stream = ConfigUtil.evStr(ev, "peer_stream")
        if !stream.isEmpty && stream != incomingStreamUrl {
            startVideo(url: stream)
        }
    }

    private func reportEndedIfNeeded() {
        guard inCall, sipMode == "answer", callLifecycle.mayReportEnd,
              !callLifecycle.ended else { return }
        callLifecycle.recordEnd(core.reportCallEndedResult(door: door, callId: callId,
                                                           stageRevision: stageRevision,
                                                           reason: "sip_ended",
                                                           coreGeneration: coreGeneration))
    }
}

final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right,
                      height: s.height + insets.top + insets.bottom)
    }
}

/// One ring as the router sees it.
struct IncomingCallRequest {
    let door: String
    let purpose: String
    let visitorLang: String
    let callId: String
    let stageRevision: Int
}

/// The single owner of the decision to show an incoming call, shared by the iOS and tvOS app
/// delegates. A ring always wins over the screen in front of it:
/// - an Incoming screen anywhere in the stack takes the new call itself;
/// - a Monitor session is closed first, because it holds its own SIP dialog to a door;
/// - any other screen (Settings, History, announcements, the offline list, a PIN prompt, an
///   alert) stays where it is and the call is stacked over it, so nothing is lost;
/// - during a presentation or dismissal, or while the pairing gate is up, the ring is queued
///   and retried, never dropped.
/// The chime gate records a revision only once the screen is actually on display, so a ring
/// that could not be shown is not spent.
final class IncomingCallRouter {
    typealias RootProvider = () -> UIViewController?

    private let root: RootProvider
    private let blocked: () -> Bool
    private let makeScreen: (IncomingCallRequest) -> IncomingViewController?
    private var gate = CallChimeRevisionGate()
    private var pending: [IncomingCallRequest] = []
    private var retryScheduled = false

    static let retryInterval: TimeInterval = 0.25

    init(root: @escaping RootProvider, blocked: @escaping () -> Bool,
         makeScreen: @escaping (IncomingCallRequest) -> IncomingViewController?) {
        self.root = root
        self.blocked = blocked
        self.makeScreen = makeScreen
    }

    /// Feeds one Core UI event. Only a targeted `chime` opens the screen; a cancellation or end
    /// of the waiting call drops a queued ring.
    func handle(_ ev: [String: Any]) {
        let kind = ConfigUtil.evStr(ev, "t")
        if kind == "chime" {
            let request = IncomingCallRequest(
                door: ConfigUtil.evStr(ev, "door"), purpose: ConfigUtil.evStr(ev, "purpose"),
                visitorLang: ConfigUtil.evStr(ev, "visitor_lang"),
                callId: ConfigUtil.evStr(ev, "call_id"),
                stageRevision: ConfigUtil.int(ev, "stage_revision", 0))
            guard !request.callId.isEmpty,
                  gate.wouldAccept(callId: request.callId,
                                   stageRevision: request.stageRevision) else { return }
            if let index = pending.firstIndex(where: { $0.door == request.door && $0.callId == request.callId }) {
                guard request.stageRevision >= pending[index].stageRevision else { return }
                pending[index] = request
            } else {
                pending.append(request)
            }
            route()
            return
        }
        let type = ConfigUtil.evStr(ev, "type")
        if kind == "event", type == "call_cancelled" || type == "call_ended",
           !ConfigUtil.evStr(ev, "door").isEmpty {
            pending.removeAll {
                $0.door == ConfigUtil.evStr(ev, "door") &&
                $0.callId == ConfigUtil.evStr(ev, "call_id") &&
                ConfigUtil.int(ev, "stage_revision", -1) >= $0.stageRevision
            }
        }
    }

    private func route() {
        guard let request = pending.first, let base = root() else { return }
        var chain: [UIViewController] = [base]
        while let next = chain.last?.presentedViewController { chain.append(next) }

        if let incoming = chain.compactMap({ $0 as? IncomingViewController }).last {
            incoming.receive(door: request.door, purpose: request.purpose,
                             visitorLang: request.visitorLang, callId: request.callId,
                             stageRevision: request.stageRevision)
            shown(request)
            return
        }
        if blocked() || chain.contains(where: { $0.isBeingPresented || $0.isBeingDismissed }) {
            retryLater()
            return
        }
        if let index = chain.firstIndex(where: { $0 is MonitorViewController }), index > 0 {
            chain[index - 1].dismiss(animated: false) { [weak self] in self?.route() }
            return
        }
        guard let top = chain.last, let screen = makeScreen(request) else { return }
        top.present(screen, animated: true)
        shown(request)
    }

    private func shown(_ request: IncomingCallRequest) {
        _ = gate.accept(callId: request.callId, stageRevision: request.stageRevision)
        pending.removeAll { $0.door == request.door && $0.callId == request.callId &&
                            $0.stageRevision <= request.stageRevision }
        if !pending.isEmpty { retryLater() }
    }

    private func retryLater() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + IncomingCallRouter.retryInterval) {
            [weak self] in
            self?.retryScheduled = false
            self?.route()
        }
    }
}
