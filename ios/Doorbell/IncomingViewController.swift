import UIKit

final class IncomingViewController: UIViewController {

    private let core: CoreBridge
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

    private var cfg: [String: Any]?
    private var videoPlayer: AdaptiveH264MjpegPlayer?
    private var incomingStreamUrl = ""
    private var incomingStreamMp4Url = ""
    private var peerHost: String?
    private var directPort = 47190
    private var sipMode = ""
    private var inCall = false
    private var lifecycleAnswered = false
    private var lifecycleEnded = false
    private var safeMode = UserDefaults.standard.bool(forKey: "runtime.safe_mode")
    private var autoCloseTimer: Timer?
    private var answerDelayTimer: Timer?

    private let liveView = UIImageView()
    private let h264View = UIView()
    private let noVideoLabel = UILabel()
    private let titleLabel = UILabel()
    private let purposeBadge = PaddedLabel()
    private let langBadge = PaddedLabel()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let replyStack = UIStackView()
    private let answerButton = UIButton(type: .system)
    private let monitorButton = UIButton(type: .system)
    private let unlockButton = UIButton(type: .system)
    private let ignoreButton = UIButton(type: .system)

    private static let autoCloseS: TimeInterval = 30
    private static let cancelledCloseS: TimeInterval = 15
    private static let handlerKey = "incoming"

    init(core: CoreBridge, boot: BootConfig, door: String, purpose: String, visitorLang: String,
         callId: String, stageRevision: Int = 0) {
        self.core = core
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
        view.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
        cfg = core.config()
        if let node = core.status()?["node"] as? [String: Any] {
            nodeId = ConfigUtil.evStr(node, "id")
        }
        texts.setConfig(cfg)
        texts.setLang(boot.uiLang)
        directPort = ConfigUtil.int(cfg, "sip.direct_port", 47190)
        buildUi()
        applyContent()

        let peer = ConfigUtil.findDoorPeer(core.status(), door: door)
        peerHost = ConfigUtil.peerHost(peer)
        incomingStreamUrl = peer.flatMap { ConfigUtil.str($0, "stream") } ?? ""
        incomingStreamMp4Url = peer.flatMap { ConfigUtil.str($0, "stream_mp4") } ?? ""
        answerButton.isEnabled = peerHost != nil
        startVideo(url: incomingStreamUrl)

        core.addHandler(IncomingViewController.handlerKey) { [weak self] ev in
            self?.onUiEvent(ev)
        }
        restartAutoClose()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoPlayer?.layout()
        applySemanticStyles()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        core.removeHandler(IncomingViewController.handlerKey)
        autoCloseTimer?.invalidate()
        answerDelayTimer?.invalidate()
        videoPlayer?.stop()
        videoPlayer = nil
        if !sipMode.isEmpty {
            core.sipHangup()
            reportEndedIfNeeded()
            sipMode = ""
        }
    }

    func enterSafeModeForMemoryPressure() {
        safeMode = true
        videoPlayer?.stop()
        videoPlayer = nil
        liveView.image = nil
        liveView.transform = .identity
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
        if update == .answerSuperseded { demoteSupersededAnswer() }
        cfg = core.config()
        applyContent()
        if !inCall { restartAutoClose() }
    }

    /// Switch all media and SIP targets when another door rings while this view is visible.
    /// A different call cannot displace an established dialog; a winning newer revision of the
    /// same call can demote its stale answer leg.
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
            if update == .answerSuperseded { demoteSupersededAnswer() }
            cfg = core.config()
            applyContent()
            if !inCall { restartAutoClose() }
            return
        }
        guard !inCall else { return }
        answerDelayTimer?.invalidate()
        answerDelayTimer = nil
        if !sipMode.isEmpty { core.sipHangup() }
        sipMode = ""
        self.door = targetDoor
        self.purpose = purpose
        self.visitorLang = visitorLang
        self.callId = newCallId
        stageRevision = max(0, newStageRevision)
        revisionLifecycle = CallRevisionLifecycle(stageRevision: stageRevision)
        lastChimeRevision = stageRevision
        lifecycleAnswered = false
        lifecycleEnded = false
        cfg = core.config()
        texts.setConfig(cfg)
        directPort = ConfigUtil.int(cfg, "sip.direct_port", 47190)
        applyContent()
        hintLabel.isHidden = true
        let peer = ConfigUtil.findDoorPeer(core.status(), door: targetDoor)
        peerHost = ConfigUtil.peerHost(peer)
        incomingStreamUrl = peer.flatMap { ConfigUtil.str($0, "stream") } ?? ""
        incomingStreamMp4Url = peer.flatMap { ConfigUtil.str($0, "stream_mp4") } ?? ""
        answerButton.isEnabled = peerHost != nil
        startVideo(url: incomingStreamUrl)
        restartAutoClose()
    }


    private func buildUi() {
        liveView.contentMode = .scaleAspectFit
        liveView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(liveView)

        h264View.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(h264View)

        noVideoLabel.font = .systemFont(ofSize: 22)
        noVideoLabel.textColor = UIColor(white: 1, alpha: 0.45)
        noVideoLabel.textAlignment = .center
        noVideoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noVideoLabel)

        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.5

        purposeBadge.font = .systemFont(ofSize: 20, weight: .semibold)
        purposeBadge.textColor = .black
        purposeBadge.backgroundColor = UIColor(red: 1.0, green: 0.80, blue: 0.25, alpha: 1)
        purposeBadge.layer.cornerRadius = 8
        purposeBadge.clipsToBounds = true

        langBadge.font = .systemFont(ofSize: 20, weight: .semibold)
        langBadge.textColor = .black
        langBadge.backgroundColor = UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1)
        langBadge.layer.cornerRadius = 8
        langBadge.clipsToBounds = true

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        purposeBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        langBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let badgeRow = UIStackView(arrangedSubviews: [titleLabel, purposeBadge, langBadge,
                                                      UIView()])
        badgeRow.axis = .horizontal
        badgeRow.spacing = 12
        badgeRow.alignment = .center
        badgeRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(badgeRow)

        statusLabel.font = .systemFont(ofSize: 20)
        statusLabel.textColor = UIColor(white: 1, alpha: 0.7)

        hintLabel.font = .systemFont(ofSize: 20)
        hintLabel.textColor = UIColor(red: 0.55, green: 0.9, blue: 0.55, alpha: 1)
        hintLabel.isHidden = true

        replyStack.axis = .vertical
        replyStack.spacing = 12

        styleActionButton(answerButton, prominent: true)
        styleActionButton(monitorButton, prominent: false)
        styleActionButton(unlockButton, prominent: false)
        styleActionButton(ignoreButton, prominent: false)
        answerButton.addTarget(self, action: #selector(onAnswer), for: .primaryActionTriggered)
        monitorButton.addTarget(self, action: #selector(onMonitor), for: .primaryActionTriggered)
        unlockButton.addTarget(self, action: #selector(onUnlock), for: .primaryActionTriggered)
        ignoreButton.addTarget(self, action: #selector(onIgnore), for: .primaryActionTriggered)
        unlockButton.isHidden = true
        if core.sipBackend != "pjsip" {
            answerButton.isHidden = true
            monitorButton.isHidden = true
        }
        #if os(tvOS)
        answerButton.isHidden = true
        unlockButton.isHidden = true
        #endif
        let actionRow = UIStackView(arrangedSubviews: [answerButton, monitorButton,
                                                        unlockButton, ignoreButton])
        actionRow.axis = .horizontal
        actionRow.spacing = 14
        actionRow.distribution = .fillEqually

        let rightCol = UIStackView(arrangedSubviews: [statusLabel, replyStack, hintLabel,
                                                      UIView(), actionRow])
        rightCol.axis = .vertical
        rightCol.spacing = 16
        rightCol.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rightCol)

        let g = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            badgeRow.topAnchor.constraint(equalTo: g.topAnchor, constant: 18),
            badgeRow.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 24),
            badgeRow.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -24),

            noVideoLabel.centerXAnchor.constraint(equalTo: liveView.centerXAnchor),
            noVideoLabel.centerYAnchor.constraint(equalTo: liveView.centerYAnchor),

            liveView.topAnchor.constraint(equalTo: badgeRow.bottomAnchor, constant: 14),
            liveView.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 24),
            h264View.topAnchor.constraint(equalTo: liveView.topAnchor),
            h264View.bottomAnchor.constraint(equalTo: liveView.bottomAnchor),
            h264View.leadingAnchor.constraint(equalTo: liveView.leadingAnchor),
            h264View.trailingAnchor.constraint(equalTo: liveView.trailingAnchor),
            rightCol.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -24),
            rightCol.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -18),
        ])
        landscapeCs = [
            liveView.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -18),
            liveView.widthAnchor.constraint(equalTo: g.widthAnchor, multiplier: 0.58),
            rightCol.topAnchor.constraint(equalTo: badgeRow.bottomAnchor, constant: 14),
            rightCol.leadingAnchor.constraint(equalTo: liveView.trailingAnchor, constant: 24),
        ]
        portraitCs = [
            liveView.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -24),
            liveView.heightAnchor.constraint(equalTo: g.heightAnchor, multiplier: 0.38),
            rightCol.topAnchor.constraint(equalTo: liveView.bottomAnchor, constant: 16),
            rightCol.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 24),
        ]
        applyOrientationConstraints()
    }

    private var landscapeCs: [NSLayoutConstraint] = []
    private var portraitCs: [NSLayoutConstraint] = []

    private func applyOrientationConstraints(for size: CGSize? = nil) {
        let s = size ?? view.bounds.size
        let portrait = s.height > s.width
        NSLayoutConstraint.deactivate(portrait ? landscapeCs : portraitCs)
        NSLayoutConstraint.activate(portrait ? portraitCs : landscapeCs)
    }

    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        applyOrientationConstraints(for: size)
    }

    private func styleActionButton(_ b: UIButton, prominent: Bool) {
        b.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.titleLabel?.minimumScaleFactor = 0.6
        #if os(iOS)
        b.setTitleColor(prominent ? .black : .white, for: .normal)
        b.backgroundColor = prominent
            ? UIColor(red: 0.35, green: 0.78, blue: 0.42, alpha: 1)
            : UIColor(white: 1, alpha: 0.14)
        b.layer.cornerRadius = 12
        b.contentEdgeInsets = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        #endif
    }

    private func applyContent() {
        let doorEntry = ConfigUtil.dig(cfg, "doors.\(door)") as? [String: Any]
        let label = ConfigUtil.labelOf(doorEntry, boot.uiLang, door)
        titleLabel.text = texts.t("ring.incoming", label)
        noVideoLabel.text = texts.t("ring.no_video")
        statusLabel.text = texts.t("reply.choose")
        answerButton.setTitle(inCall ? texts.t("incall.end") : texts.t("ring.answer"),
                              for: .normal)
        monitorButton.setTitle(texts.t("ring.monitor"), for: .normal)
        unlockButton.setTitle(texts.t("ring.unlock"), for: .normal)
        ignoreButton.setTitle(texts.t("ring.ignore"), for: .normal)
        updateBadges()
        buildReplyButtons()
    }

    private func updateBadges() {
        let entry = purpose.isEmpty ? nil
            : ConfigUtil.dig(cfg, "visit_purposes.\(purpose)") as? [String: Any]
        if purpose.isEmpty {
            purposeBadge.isHidden = true
        } else {
            let label = ConfigUtil.labelOf(entry, boot.uiLang, purpose)
            let icon = entry?["icon"] as? String ?? ""
            purposeBadge.text = icon.isEmpty ? label : "\(icon) \(label)"
            purposeBadge.accessibilityLabel = texts.t("ring.purpose_badge", label)
            purposeBadge.isHidden = false
        }
        if visitorLang.isEmpty || visitorLang == "ja" {
            langBadge.isHidden = true
        } else {
            langBadge.text = "🌐 " + visitorLang.uppercased()
            langBadge.accessibilityLabel =
                texts.t("ring.lang_badge", Texts.langDisplayName(visitorLang))
            langBadge.isHidden = false
        }
    }

    private func buildReplyButtons() {
        for v in replyStack.arrangedSubviews { v.removeFromSuperview() }
        guard !inCall else { return }
        guard let replies = ConfigUtil.dig(cfg, "quick_replies") as? [String: Any],
              !replies.isEmpty else { return }
        let lang = visitorLang.isEmpty ? "ja" : visitorLang
        for id in ConfigUtil.sortedByOrder(replies) {
            let entry = replies[id] as? [String: Any]
            let b = UIButton(type: .system)
            b.setTitle(ConfigUtil.labelOf(entry, lang, id), for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 22)
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.titleLabel?.minimumScaleFactor = 0.6
            #if os(iOS)
            b.setTitleColor(.white, for: .normal)
            b.backgroundColor = UIColor(white: 1, alpha: 0.10)
            b.layer.cornerRadius = 12
            b.contentEdgeInsets = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
            #endif
            b.accessibilityIdentifier = "qr_button_\(id)"
            b.addTarget(self, action: #selector(onReply(_:)), for: .primaryActionTriggered)
            replyStack.addArrangedSubview(b)
            styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: "reply.button", to: b)
        }
    }

    private func applySemanticStyles() {
        styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: "ring.title", to: titleLabel)
        for button in [answerButton, monitorButton, unlockButton, ignoreButton] {
            styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: "ring.action", to: button)
        }
        if inCall {
            styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: "call.end",
                               to: answerButton)
        }
        for button in replyStack.arrangedSubviews {
            styleApplier.apply(config: cfg, nodeId: nodeId, semanticId: "reply.button", to: button)
        }
    }


    private func startVideo(url: String) {
        videoPlayer?.stop()
        videoPlayer = AdaptiveH264MjpegPlayer(h264Host: h264View, mjpegView: liveView,
                                              noVideoLabel: noVideoLabel)
        videoPlayer?.start(h264URLString: incomingStreamMp4Url, mjpegURL: url,
                           h264Enabled: !safeMode)
    }


    private func restartAutoClose() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = IOSAvailability.scheduledTimer(withTimeInterval: IncomingViewController.autoCloseS,
                                              repeats: false) { [weak self] _ in
            self?.close()
        }
    }

    private func close() {
        autoCloseTimer?.invalidate()
        dismiss(animated: true)
    }

    private func demoteSupersededAnswer() {
        answerDelayTimer?.invalidate()
        answerDelayTimer = nil
        lifecycleAnswered = false
        lifecycleEnded = true
        inCall = false
        sipMode = ""
        answerButton.isEnabled = false
        unlockButton.isHidden = true
        hintLabel.isHidden = true
        core.sipHangup()
    }


    @objc private func onAnswer() {
        guard let host = peerHost else { return }
        if inCall {
            core.sipHangup()
            reportEndedIfNeeded()
            sipMode = ""
            close()
            return
        }
        revisionLifecycle.beginAnswer()
        answerButton.isEnabled = false
        autoCloseTimer?.invalidate()
        if sipMode == "monitor" {
            core.sipHangup()
            answerDelayTimer?.invalidate()
            answerDelayTimer = IOSAvailability.scheduledTimer(withTimeInterval: 0.4,
                                                    repeats: false) { [weak self] _ in
                self?.placeAnswerCall(host: host)
            }
            return
        }
        placeAnswerCall(host: host)
    }

    private func placeAnswerCall(host: String) {
        sipMode = "answer"
        lifecycleAnswered = false
        lifecycleEnded = false
        core.sipCall(target: "sip:\(host):\(directPort)", mode: "answer")
    }

    @objc private func onMonitor() {
        guard let host = peerHost, sipMode.isEmpty else { return }
        sipMode = "monitor"
        core.sipCall(target: "sip:\(host):\(directPort)", mode: "monitor")
        hintLabel.text = texts.t("ring.monitoring")
        hintLabel.isHidden = false
        #if os(iOS)
        unlockButton.isHidden = false
        #endif
    }

    @objc private func onIgnore() { close() }

    @objc private func onUnlock() {
        if core.sipSendDtmf("*1") {
            hintLabel.text = texts.t("ring.unlock_sent")
            hintLabel.isHidden = false
        }
    }

    @objc private func onReply(_ sender: UIButton) {
        guard !inCall else { return }
        guard let id = sender.accessibilityIdentifier?.dropFirst("qr_button_".count) else { return }
        let accepted = core.quickReplyV2(replyId: String(id), door: door, callId: callId,
                                         stageRevision: stageRevision)
        hintLabel.text = accepted
            ? texts.t("reply.sent", sender.currentTitle ?? "")
            : texts.t("reply.failed")
        hintLabel.isHidden = false
        if accepted && !inCall { restartAutoClose() }
    }


    private func onUiEvent(_ ev: [String: Any]) {
        switch ConfigUtil.evStr(ev, "t") {
        case "state":
            let st = ConfigUtil.evStr(ev, "state")
            if st == "in_call" {
                onSipInCall(ev)
            } else if st == "idle" {
                if revisionLifecycle.consumeSupersededIdle() {
                    inCall = false
                    sipMode = ""
                    answerButton.isEnabled = peerHost != nil
                    answerButton.setTitle(texts.t("ring.answer"), for: .normal)
                    unlockButton.isHidden = true
                    statusLabel.text = texts.t("reply.choose")
                    restartAutoClose()
                    return
                }
                let was = inCall
                if was { reportEndedIfNeeded() }
                inCall = false
                sipMode = ""
                if was { close() }
            }
        case "reply":
            let d = ConfigUtil.evStr(ev, "door")
            if !inCall && (d.isEmpty || d == door) { close() }
        case "event":
            let type = ConfigUtil.evStr(ev, "type")
            let d = ConfigUtil.evStr(ev, "door")
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
            } else if type == "call_answered",
                      eventStageRevision >= stageRevision, !inCall {
                close()
            } else if type == "call_answered",
                      eventStageRevision >= stageRevision, inCall {
                let reportedOwner = ConfigUtil.evStr(ev, "dialog_owner")
                let owner = reportedOwner.isEmpty ? ConfigUtil.evStr(ev, "device") : reportedOwner
                if !owner.isEmpty, !nodeId.isEmpty, owner != nodeId {
                    // Another confirmed answer won Core's deterministic ownership claim. End the
                    // losing SIP leg without publishing call_ended for the winner's dialog.
                    lifecycleAnswered = false
                    lifecycleEnded = true
                    inCall = false
                    sipMode = ""
                    core.sipHangup()
                    close()
                }
            } else if type == "call_ended", eventStageRevision >= stageRevision {
                reportEndedIfNeeded()
                close()
            } else if type == "call_cancelled", !inCall {
                statusLabel.text = texts.t("ring.cancelled")
                autoCloseTimer?.invalidate()
                autoCloseTimer = IOSAvailability.scheduledTimer(
                    withTimeInterval: IncomingViewController.cancelledCloseS,
                    repeats: false) { [weak self] _ in self?.close() }
            }
        case "visitor_lang":
            let d = ConfigUtil.evStr(ev, "door")
            if d.isEmpty || d == door {
                visitorLang = ConfigUtil.evStr(ev, "lang")
                updateBadges()
                buildReplyButtons()
            }
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
        inCall = true
        buildReplyButtons()
        if !lifecycleAnswered {
            lifecycleAnswered = core.reportCallAnswered(door: door, callId: callId,
                                                         stageRevision: stageRevision)
        }
        autoCloseTimer?.invalidate()
        answerButton.isEnabled = true
        answerButton.setTitle(texts.t("incall.end"), for: .normal)
        unlockButton.isHidden = false
        statusLabel.text = texts.t("incall.title")
        hintLabel.isHidden = true
        let stream = ConfigUtil.evStr(ev, "peer_stream")
        if !stream.isEmpty && stream != incomingStreamUrl {
            startVideo(url: stream)
        }
    }

    private func reportEndedIfNeeded() {
        guard inCall, sipMode == "answer", lifecycleAnswered, !lifecycleEnded else { return }
        lifecycleEnded = core.reportCallEnded(door: door, callId: callId,
                                               stageRevision: stageRevision,
                                               reason: "sip_ended")
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
