// 来鈴画面 (室内機/TV — indoor_panel が press で表示。WPF IncomingView / Android
// IncomingActivity と同役)。
//   - 門口ライブ映像: statusJson peers[].stream (MJPEG) を自前デコード (MjpegClient)
//   - 監聴: core の SIP で門口機の待受 (sip.direct_port 既定 47190) へ Asterisk 非経由の
//     直接監聴呼 (X-Doorbell-Mode: monitor) — 門口機側はマイクのみ一方向で流す。
//   - 応答: 監聴呼を切って 400ms 後に X-Doorbell-Mode: answer の直呼 — 門口機は鳴っている
//     電話腿を取り消して双方向応答する (計画書 §12)。通話中は相手映像 (peer_stream) を表示し
//     「終了」で切る。
//   - クイック返信: config quick_replies を order 順。ラベルは**訪客言語**
//     (quick_replies.<id>.label.<visitor_lang> — 無ければ ja)。
//   - 用件 / 訪客言語バッジ: press イベント payload 由来 (「📦 宅配便」「🌐 EN」)。住人が読む
//     ものなので用件名は室内側の言語 (boot.ui_lang) で表示する。
//   - 応答されないまま 30 秒で自動クローズ (映像/監聴を持続させない。再チャイムで張り直し)。
//     reply イベント (誰かが応対 — 複製で全ノードに届く) でも畳む。
// tvOS: SIP (pjsip) 未リンクのため監聴/応答は出さない — 映像 + クイック返信のみ。
//       ボタンは focusable で Siri Remote の D-pad/クリックで操作する。
//       TODO(tvOS): pjsip の tvOS ビルドが通ったら iOS と同じ監聴/応答を有効化する。
import UIKit

final class IncomingViewController: UIViewController {

    private let core: CoreBridge
    private let boot: BootConfig
    private let texts = Texts()          // 室内側の言語 (住人が読む面)
    private var door: String
    private var purpose: String          // press payload の用件 id (バッジ用)
    private var visitorLang: String      // press payload の訪客言語 (返信ラベル/バッジ用)

    private var cfg: [String: Any]?
    private var streamer: MjpegClient?
    private var incomingStreamUrl = ""
    private var peerHost: String?        // 門口機の mesh 実アドレス host (直呼宛先)
    private var directPort = 47190       // config sip.direct_port (docs/network-ports.md)
    private var sipMode = ""             // "" | "monitor" | "answer"
    private var inCall = false
    private var autoCloseTimer: Timer?
    private var answerDelayTimer: Timer?

    // UI
    private let liveView = UIImageView()
    private let noVideoLabel = UILabel()
    private let titleLabel = UILabel()
    private let purposeBadge = PaddedLabel()
    private let langBadge = PaddedLabel()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let replyStack = UIStackView()
    private let answerButton = UIButton(type: .system)
    private let monitorButton = UIButton(type: .system)
    private let ignoreButton = UIButton(type: .system)

    private static let autoCloseS: TimeInterval = 30
    private static let handlerKey = "incoming"

    init(core: CoreBridge, boot: BootConfig, door: String, purpose: String, visitorLang: String) {
        self.core = core
        self.boot = boot
        self.door = door
        self.purpose = purpose
        self.visitorLang = visitorLang
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - ライフサイクル

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
        cfg = core.config()
        texts.setConfig(cfg)
        texts.setLang(boot.uiLang)
        directPort = ConfigUtil.int(cfg, "sip.direct_port", 47190)
        buildUi()
        applyContent()

        // 門口機 peer 解決 (映像 URL + 直呼宛先 host)
        let peer = ConfigUtil.findDoorPeer(core.status(), door: door)
        peerHost = ConfigUtil.peerHost(peer)
        incomingStreamUrl = peer.flatMap { ConfigUtil.str($0, "stream") } ?? ""
        answerButton.isEnabled = peerHost != nil
        startVideo(url: incomingStreamUrl)

        core.addHandler(IncomingViewController.handlerKey) { [weak self] ev in
            self?.onUiEvent(ev)
        }
        restartAutoClose()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        core.removeHandler(IncomingViewController.handlerKey)
        autoCloseTimer?.invalidate()
        answerDelayTimer?.invalidate()
        streamer?.stop()
        streamer = nil
        if !sipMode.isEmpty {
            core.sipHangup()
            sipMode = ""
        }
    }

    /// 同じ画面が出ている間の再チャイム → 用件/言語を更新しタイマを張り直す (監聴等は継続)。
    func refresh(purpose: String, visitorLang: String) {
        self.purpose = purpose
        self.visitorLang = visitorLang
        cfg = core.config()
        applyContent()
        if !inCall { restartAutoClose() }
    }

    // MARK: - UI 構築

    private func buildUi() {
        liveView.contentMode = .scaleAspectFit
        liveView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(liveView)

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

        // バッジは潰さない (タイトル側が adjustsFontSizeToFitWidth で縮む)
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
        styleActionButton(ignoreButton, prominent: false)
        answerButton.addTarget(self, action: #selector(onAnswer), for: .primaryActionTriggered)
        monitorButton.addTarget(self, action: #selector(onMonitor), for: .primaryActionTriggered)
        ignoreButton.addTarget(self, action: #selector(onIgnore), for: .primaryActionTriggered)
        #if os(tvOS)
        // tvOS: SIP 無し (ヘッダコメント参照) — 監聴/応答は隠す
        answerButton.isHidden = true
        monitorButton.isHidden = true
        #endif
        let actionRow = UIStackView(arrangedSubviews: [answerButton, monitorButton, ignoreButton])
        actionRow.axis = .horizontal
        actionRow.spacing = 14
        actionRow.distribution = .fillEqually

        let rightCol = UIStackView(arrangedSubviews: [statusLabel, replyStack, hintLabel,
                                                      UIView(), actionRow])
        rightCol.axis = .vertical
        rightCol.spacing = 16
        rightCol.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rightCol)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            badgeRow.topAnchor.constraint(equalTo: g.topAnchor, constant: 18),
            badgeRow.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 24),
            badgeRow.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -24),

            noVideoLabel.centerXAnchor.constraint(equalTo: liveView.centerXAnchor),
            noVideoLabel.centerYAnchor.constraint(equalTo: liveView.centerYAnchor),

            liveView.topAnchor.constraint(equalTo: badgeRow.bottomAnchor, constant: 14),
            liveView.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 24),
            rightCol.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -24),
            rightCol.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -18),
        ])
        // 横持ち (kiosk タブレット/TV): 映像は左 58%、操作列は右。
        landscapeCs = [
            liveView.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -18),
            liveView.widthAnchor.constraint(equalTo: g.widthAnchor, multiplier: 0.58),
            rightCol.topAnchor.constraint(equalTo: badgeRow.bottomAnchor, constant: 14),
            rightCol.leadingAnchor.constraint(equalTo: liveView.trailingAnchor, constant: 24),
        ]
        // 縦持ち (スマホ室内機): 映像は上 38%、操作列は下。
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

    /// 文言・バッジ・返信ボタンの貼り直し (初期表示 / 再チャイム / 訪客言語切替)。
    private func applyContent() {
        let doorEntry = ConfigUtil.dig(cfg, "doors.\(door)") as? [String: Any]
        let label = ConfigUtil.labelOf(doorEntry, boot.uiLang, door)
        titleLabel.text = texts.t("ring.incoming", label)
        noVideoLabel.text = texts.t("ring.no_video")
        statusLabel.text = texts.t("reply.choose")
        answerButton.setTitle(inCall ? texts.t("incall.end") : texts.t("ring.answer"),
                              for: .normal)
        monitorButton.setTitle(texts.t("ring.monitor"), for: .normal)
        ignoreButton.setTitle(texts.t("ring.ignore"), for: .normal)
        updateBadges()
        buildReplyButtons()
    }

    /// 来鈴画面の用件バッジ (「📦 宅配便」) と訪客言語バッジ (「🌐 EN」)。
    private func updateBadges() {
        let entry = purpose.isEmpty ? nil
            : ConfigUtil.dig(cfg, "visit_purposes.\(purpose)") as? [String: Any]
        if purpose.isEmpty {
            purposeBadge.isHidden = true
        } else {
            // バッジは室内側の言語 (住人が読む) — 訪客言語ではない
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

    /// クイック返信ボタン (config quick_replies を order 順)。ラベルは訪客言語。
    private func buildReplyButtons() {
        for v in replyStack.arrangedSubviews { v.removeFromSuperview() }
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
        }
    }

    // MARK: - 映像

    private func startVideo(url: String) {
        streamer?.stop()
        streamer = nil
        noVideoLabel.isHidden = false
        liveView.image = nil
        guard !url.isEmpty else { return }  // 「映像なし」表示のまま
        streamer = MjpegClient(urlString: url) { [weak self] img in
            self?.noVideoLabel.isHidden = true
            self?.liveView.image = img
        }
        streamer?.start()
    }

    // MARK: - タイマ

    private func restartAutoClose() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: IncomingViewController.autoCloseS,
                                              repeats: false) { [weak self] _ in
            self?.close()
        }
    }

    private func close() {
        autoCloseTimer?.invalidate()
        dismiss(animated: true)
    }

    // MARK: - 操作

    /// 応答: 監聴呼を切ってから 400ms 待って answer 直呼 (主呼は同時に 1 本 — sipctl の契約)。
    /// 通話中の再押下 = 終了。
    @objc private func onAnswer() {
        guard let host = peerHost else { return }
        if inCall {  // 「終了」
            core.sipHangup()
            sipMode = ""
            close()
            return
        }
        answerButton.isEnabled = false  // 二重発呼防止
        autoCloseTimer?.invalidate()    // 応答操作中は自動クローズしない
        if sipMode == "monitor" {
            core.sipHangup()
            answerDelayTimer?.invalidate()
            answerDelayTimer = Timer.scheduledTimer(withTimeInterval: 0.4,
                                                    repeats: false) { [weak self] _ in
                self?.placeAnswerCall(host: host)
            }
            return
        }
        placeAnswerCall(host: host)
    }

    /// 門口機へ直呼 (X-Doorbell-Mode: answer)。門口機側は電話腿を取消して双方向応答する。
    private func placeAnswerCall(host: String) {
        sipMode = "answer"
        core.sipCall(target: "sip:\(host):\(directPort)", mode: "answer")
    }

    @objc private func onMonitor() {
        guard let host = peerHost, sipMode.isEmpty else { return }
        sipMode = "monitor"
        core.sipCall(target: "sip:\(host):\(directPort)", mode: "monitor")
        hintLabel.text = texts.t("ring.monitoring")
        hintLabel.isHidden = false
    }

    @objc private func onIgnore() { close() }

    @objc private func onReply(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier?.dropFirst("qr_button_".count) else { return }
        core.quickReply(replyId: String(id), door: door)
        hintLabel.text = texts.t("reply.sent", sender.currentTitle ?? "")
        hintLabel.isHidden = false
        // 画面は複製されてくる reply イベント (= 応対済み) で畳む — 届かなくても
        // autoClose の安全弁がある (通話中は保つ)
        if !inCall { restartAutoClose() }
    }

    // MARK: - core イベント (main queue)

    private func onUiEvent(_ ev: [String: Any]) {
        switch ConfigUtil.evStr(ev, "t") {
        case "state":
            let st = ConfigUtil.evStr(ev, "state")
            if st == "in_call" {
                onSipInCall(ev)
            } else if st == "idle" {
                let was = inCall
                inCall = false
                sipMode = ""
                if was { close() }  // 応答通話が終わった → 来鈴画面も畳む
            }
        case "reply":
            // 誰かが応対した → 来鈴画面は閉じる (自分の返信の複製でも同じ)
            if !inCall { close() }
        case "visitor_lang":
            // 来鈴中の訪客言語切替 → 返信ラベル/バッジを追随させる
            let d = ConfigUtil.evStr(ev, "door")
            if d.isEmpty || d == door {
                visitorLang = ConfigUtil.evStr(ev, "lang")
                updateBadges()
                buildReplyButtons()
            }
        case "emergency":
            // 警報 UI (MainViewController) に画面を譲る
            if ConfigUtil.evBool(ev, "active") { close() }
        default:
            break
        }
    }

    /// SIP in_call — 応答が確立。相手映像 = peer_stream (無ければ来鈴と同じ門口 stream)。
    private func onSipInCall(_ ev: [String: Any]) {
        guard sipMode == "answer" else { return }  // monitor は来鈴画面のまま (映像+監聴継続)
        inCall = true
        autoCloseTimer?.invalidate()  // 通話中は自動クローズしない (映像は表示継続)
        answerButton.isEnabled = true
        answerButton.setTitle(texts.t("incall.end"), for: .normal)
        statusLabel.text = texts.t("incall.title")
        hintLabel.isHidden = true
        let stream = ConfigUtil.evStr(ev, "peer_stream")
        if !stream.isEmpty && stream != incomingStreamUrl {
            startVideo(url: stream)
        }
    }
}

/// 内側余白付きラベル (バッジ用)。
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
