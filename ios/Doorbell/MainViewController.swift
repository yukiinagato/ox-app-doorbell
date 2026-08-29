// 門口機/室内機メイン画面: 待機 / 呼び出し中 / 通話中 / 返信バナー / スクリーンセーバ /
// 緊急事態 の状態機 (WPF MainWindow / Android MainActivity と同じ)。
// core からの UI イベント (state/chime/reply/display/emergency/visitor_lang/…) で遷移する。
// 個性化: テーマ (display.theme / devices.<自>.local.theme の bg_color + bg_image —
// 自機 httpd の /asset/<hash>?k=<panel token> から取得) / 訪客言語バー (ui.languages) /
// 用件ボタン (visit_purposes) / カスタム音声 (audio_path)。
// 表示制御 ({"t":"display"}): 輝度 = UIScreen.brightness、夜間 red_tint = 全画面赤オーバーレイ、
// 焼付対策 = pixel_shift_s 毎の ±8px 平行移動 + 無操作 screensaver_after_s で
// スクリーンセーバ (黒背景 + 低輝度 + 漂う時計)。
// SOS: 長押し hold_to_trigger_s 秒で db_core_emergency(1)。発報中は全画面赤 + サイレン +
// 「解除」→ PIN (AdminPinViewController) → db_core_emergency(0)。
// 来鈴画面 (室内機) は AppDelegate が IncomingViewController を被せる — ここでは扱わない。
import AudioToolbox
import AVFoundation
import UIKit

final class MainViewController: UIViewController {

    private let core: CoreBridge
    private let boot: BootConfig
    private let texts = Texts()

    // ---- 個性化 (テーマ / 訪客言語 / 用件 / カスタム音声) ----
    private var cfg: [String: Any]?          // 直近の core 設定 (config_changed で差替)
    private var nodeId = ""                  // 自機 node_id (devices.<id>.local.theme 用)
    private var panelToken = ""              // config panel.tokens[0] (/asset の ?k=)
    private var visitorLang = "ja"           // 門口機の表示言語 (訪客言語)
    private var themeColor: String?          // 適用済み bg_color
    private var themeHash: String?           // 適用済み bg_image (sha256)
    private let audio = SirenPlayer()        // reply/chime の audio_path + サイレン
    private var callTitleOverride: String?   // 用件付き按鈴の「{用件} で呼び出しました」

    // ---- 表示制御の実効値 (core {"t":"display"} / status_json.display 由来) ----
    private var brightness = 70
    private var night = false
    private var redTint = false
    private var screensaverAfterS = 120
    private var pixelShiftS = 300
    private var lastActivity = Date()
    private var screensaverOn = false

    // ---- SOS ----
    private var emergencyActive = false
    private var sosHoldS = 3.0
    private var cancelRequiresPin = true
    private var sosDownAt = Date.distantPast
    private var sosHolding = false

    // ---- 通話 (door_station の in_call) ----
    private var inCall = false
    private var peerPollBusy = false

    // ---- カメラ / H.264 (Phase 6a) ----
    private lazy var camera = CameraFeeder(core: core)
    private lazy var videoEncoder = VideoEncoderVT(core: core)

    // ---- 隠し管理入口 ----
    private var secretTaps = 0
    private var secretFirst = Date.distantPast

    // ---- タイマ (WPF DispatcherTimer 相当) ----
    private var clockTimer: Timer?
    private var callTimeoutTimer: Timer?
    private var replyTimer: Timer?
    private var pixelShiftTimer: Timer?
    private var saverDriftTimer: Timer?
    private var sosTimer: Timer?
    private var peerPollTimer: Timer?
    private var encoderPollTimer: Timer?

    // ---- UI 部品 ----
    private let themeBg = UIImageView()
    private let idleView = UIView()
    private let clockLabel = UILabel()
    private let dateLabel = UILabel()
    private let callButton = UIButton(type: .system)
    private let touchHint = UILabel()
    private let nodeInfo = UILabel()
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

    private static let bgColor = UIColor(red: 0.063, green: 0.078, blue: 0.094, alpha: 1) // #101418
    private static let fgColor = UIColor(white: 0.94, alpha: 1)
    private static let dimColor = UIColor(white: 0.62, alpha: 1)
    private static let cardColor = UIColor(white: 1, alpha: 0.10)
    private static let accentColor = UIColor(red: 1.0, green: 0.80, blue: 0.25, alpha: 1)
    private static let nightClock = UIColor(red: 0.545, green: 0.141, blue: 0.110, alpha: 1)
    private static let saverClockColor = UIColor(red: 0.224, green: 0.259, blue: 0.298, alpha: 1)

    init(core: CoreBridge, boot: BootConfig) {
        self.core = core
        self.boot = boot
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - ライフサイクル

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MainViewController.bgColor
        visitorLang = boot.uiLang
        texts.setLang(visitorLang)
        buildUi()
        refreshNodeInfo()
        if !core.isRunning { offlineView.isHidden = false }

        core.addHandler("main") { [weak self] ev in self?.onUiEvent(ev) }

        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.onClockTick()
        }
        updateClock()
        // H.264 硬編の稼働制御 (Phase 6a): /stream.mp4 の購読者がいる間だけエンコーダを回す
        encoderPollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.encoderPoll()
        }
        requestAvPermissionsThenStartCamera()
    }

    /// 無操作検出 (DoorbellWindow.sendEvent から全タッチで呼ばれる)。
    func onActivity() {
        lastActivity = Date()
        exitScreensaver()
    }

    // MARK: - UI 構築 (コード UI — Interface Builder 不使用)

    private func buildUi() {
        // 最背面: テーマ背景画像
        themeBg.contentMode = .scaleAspectFill
        themeBg.clipsToBounds = true
        themeBg.isHidden = true
        addFull(themeBg)

        buildIdleView()
        buildCallingView()
        buildInCallView()
        buildReplyBanner()
        buildOfflineView()
        buildScreensaver()

        // 夜間 red tint (内容の上・警報の下)
        nightTint.backgroundColor = UIColor(red: 1.0, green: 0.13, blue: 0.0, alpha: 0.20)
        nightTint.isUserInteractionEnabled = false
        nightTint.isHidden = true
        addFull(nightTint)

        buildEmergencyView()

        // 隠し管理入口 (右上 7 連打 / 5 秒内)
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
        callButton.contentEdgeInsets = UIEdgeInsets(top: 26, left: 60, bottom: 26, right: 60)
        callButton.addTarget(self, action: #selector(onCallClick), for: .touchUpInside)

        touchHint.font = .systemFont(ofSize: 20)
        touchHint.textColor = MainViewController.dimColor
        touchHint.textAlignment = .center

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
                                                   purposeSection, langBar])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .center
        stack.setCustomSpacing(6, after: clockLabel)
        stack.setCustomSpacing(34, after: dateLabel)
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

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            nodeInfo.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            nodeInfo.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),
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

        let g = view.safeAreaLayoutGuide
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

        let g = view.safeAreaLayoutGuide
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
        // 漂移は center 制約の constant を書き換える
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

    // MARK: - 文言 (i18n_overrides → Localizable.strings)

    /// 全画面の文言を現在言語で貼り直す。訪客言語の切替でも呼ばれる。
    private func applyStrings() {
        callButton.setTitle(
            texts.t("idle.call_button", doorLabel(boot.door))
                .trimmingCharacters(in: .whitespaces), for: .normal)
        touchHint.text = texts.t("idle.touch_to_call")
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
    }

    /// ドアの表示名 (doors.<door>.label.<lang> → ja → door id)。
    private func doorLabel(_ door: String) -> String {
        if door.isEmpty { return "" }
        let entry = ConfigUtil.dig(cfg, "doors.\(door)") as? [String: Any]
        return ConfigUtil.labelOf(entry, texts.lang, door)
    }

    // MARK: - 時計 / ノード情報

    private func onClockTick() {
        updateClock()
        // 無操作 screensaver_after_s でスクリーンセーバへ (待機中のみ)
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
                nodeInfo.text = "\(ConfigUtil.evStr(node, "name")) · v\(ConfigUtil.evStr(node, "version"))"
                nodeId = ConfigUtil.evStr(node, "id")
            }
            // 起動直後の {"t":"display"}/{"t":"emergency"} は購読前に流れていることがある —
            // status_json の同梱値で追い付く
            if let disp = st["display"] as? [String: Any] {
                applyDisplayValues(disp)
            }
            if let em = st["emergency"] as? [String: Any] {
                if ConfigUtil.evBool(em, "active") {
                    let wasActive = emergencyActive
                    showEmergency()
                    // 再起動追い付き時もサイレンを鳴らす (カスタム音は状態からは引けない —
                    // 内蔵サイレンで確実に鳴らす)
                    if !wasActive {
                        audio.startSiren(customPath: "",
                                         volume: ConfigUtil.int(cfg, "emergency.alarm_volume", 100))
                    }
                } else {
                    hideEmergency()
                }
            }
            // 訪客言語の現在値 (status_json visitor_lang.<door>) — 再起動後の追い付き
            if boot.role == "door_station" && !boot.door.isEmpty {
                let vl = ConfigUtil.str(st, "visitor_lang.\(boot.door)") ?? "ja"
                setVisitorLang(vl)
            }
        }
        refreshSosConfig()
        applyTheme()
        buildPurposeButtons()
        buildLangBar()
        applyStrings()
    }

    /// core 設定のキャッシュ更新 (Texts の上書き文言もここで差し替える)。
    private func refreshConfigCache() {
        cfg = core.config()
        texts.setConfig(cfg)
        panelToken = firstPanelToken()
    }

    /// config panel.tokens[0] (資産取得 /asset/<hash>?k= に使う)。
    private func firstPanelToken() -> String {
        guard let toks = ConfigUtil.dig(cfg, "panel.tokens") as? [Any] else { return "" }
        for t in toks {
            if let s = t as? String, !s.isEmpty { return s }
        }
        return ""
    }

    // MARK: - 個性化 (テーマ / 用件 / 訪客言語)

    /// 設定値を「端末別 (devices.<自>.local.theme.*) → 全体 (display.theme.*)」の優先順で引く。
    private func themeValue(_ leaf: String) -> String? {
        if !nodeId.isEmpty,
           let v = ConfigUtil.str(cfg, "devices.\(nodeId).local.theme.\(leaf)") {
            return v
        }
        return ConfigUtil.str(cfg, "display.theme.\(leaf)")
    }

    /// テーマ適用: bg_color を背景に、bg_image (sha256) を最背面へ敷く。
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
        if hash == themeHash && themeBg.image != nil { return }  // 適用済み
        themeHash = hash
        loadThemeImage(hash)
    }

    /// 背景画像を自機 httpd から取得 (未キャッシュなら 404 — asset_ready で再試行)。
    private func loadThemeImage(_ hash: String) {
        var urlStr = "http://127.0.0.1:\(boot.httpPort)/asset/\(hash)"
        if !panelToken.isEmpty { urlStr += "?k=\(panelToken)" }
        guard let url = URL(string: urlStr) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, resp, _ in
            guard let self = self, let data = data,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard self.themeHash == hash else { return }  // 途中で設定が変わった
                self.themeBg.image = img
                self.themeBg.isHidden = false
            }
        }.resume()
    }

    /// 用件ボタン (config visit_purposes)。門口機の待機画面にだけ出す。
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
        let purposes = ConfigUtil.dig(cfg, "visit_purposes") as? [String: Any]
        let label = ConfigUtil.labelOf(purposes?[String(id)] as? [String: Any], texts.lang,
                                       String(id))
        core.pressPurpose(door: boot.door, purpose: String(id))
        showCalling(title: texts.t("purpose.sent", label))
    }

    /// 訪客言語バー (config ui.languages)。門口機の待機画面下部。
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
        core.setVisitorLang(door: boot.door, lang: String(lang))  // 複製で visitor_lang が返る
        setVisitorLang(String(lang))                              // 体感優先で先に切替 (冪等)
    }

    /// 表示言語を切り替えて訪客向け文言を貼り直す (自操作・他端末・自動復帰の共通経路)。
    private func setVisitorLang(_ lang: String) {
        let l = lang.isEmpty ? "ja" : lang
        if visitorLang == l { return }
        visitorLang = l
        texts.setLang(l)
        applyStrings()
        buildPurposeButtons()
        updateLangBarSelection()
    }

    // MARK: - 表示制御

    private func applyDisplayValues(_ d: [String: Any]) {
        brightness = ConfigUtil.int(d, "brightness", brightness)
        night = ConfigUtil.evBool(d, "night")
        redTint = ConfigUtil.evBool(d, "red_tint")
        screensaverAfterS = ConfigUtil.int(d, "screensaver_after_s", screensaverAfterS)
        pixelShiftS = ConfigUtil.int(d, "pixel_shift_s", pixelShiftS)
        applyDisplay()
    }

    private func applyDisplay() {
        // 夜間: red tint オーバーレイ + 時計を暗赤に
        nightTint.isHidden = !(night && redTint)
        clockLabel.textColor = night ? MainViewController.nightClock : MainViewController.fgColor
        dateLabel.textColor = night ? MainViewController.nightClock : MainViewController.dimColor
        saverClock.textColor = night ? MainViewController.nightClock
                                     : MainViewController.saverClockColor

        pixelShiftTimer?.invalidate()
        pixelShiftTimer = nil
        if pixelShiftS > 0 {
            pixelShiftTimer = Timer.scheduledTimer(withTimeInterval: Double(pixelShiftS),
                                                   repeats: true) { [weak self] _ in
                guard let self = self else { return }
                // 焼付対策: 待機画面コンテナを ±8px 移動
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

    /// 輝度設定 (UIScreen.brightness — 0-100%)。
    private func setBrightness(_ percent: Int) {
        UIScreen.main.brightness = CGFloat(max(0, min(100, percent))) / 100.0
    }

    // MARK: - スクリーンセーバ

    private func enterScreensaver() {
        guard !screensaverOn else { return }
        screensaverOn = true
        updateClock()
        screensaverView.isHidden = false
        moveSaverClock()
        saverDriftTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.moveSaverClock()
        }
        setBrightness(min(brightness, 10))  // 低輝度
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

    // MARK: - SOS

    private func refreshSosConfig() {
        // 既定 (config 未設定時) は config-schema の既定 button_on_roles=["indoor_panel"]
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
            sosTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
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
            core.emergency(true)  // {"t":"emergency","active":true} が全ノードへ届き UI が出る
        }
    }

    private func resetSosHold() {
        sosHolding = false
        sosTimer?.invalidate()
        sosTimer = nil
        sosProgress.progress = 0
    }

    private func showEmergency() {
        guard !emergencyActive else { return }
        emergencyActive = true
        exitScreensaver()
        callTimeoutTimer?.invalidate()
        callingView.isHidden = true
        replyBanner.isHidden = true
        presentedViewController?.dismiss(animated: false)  // 来鈴/PIN より警報優先
        emergencyView.isHidden = false
        setBrightness(100)  // 警報中は最大輝度
    }

    private func hideEmergency() {
        guard emergencyActive else { return }
        emergencyActive = false
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
                self?.core.emergency(false)
                self?.hideEmergency()  // core からの active=false 通知も来るが即時に畳む (冪等)
            }
            present(dlg, animated: true)
            return
        }
        core.emergency(false)
        hideEmergency()
    }

    // MARK: - 状態遷移

    private func showIdle(hint: String? = nil) {
        callTitleOverride = nil
        callTimeoutTimer?.invalidate()
        pulse.layer.removeAllAnimations()
        callingView.isHidden = true
        offlineView.isHidden = true
        idleView.isHidden = false
        if let h = hint { touchHint.text = h }
    }

    /// 呼び出し中画面。title 指定時は「{用件} で呼び出しました」等に差し替える
    /// (core からの state=calling で上書きされないよう callTitleOverride に覚える)。
    private func showCalling(title: String? = nil) {
        exitScreensaver()
        if let t = title { callTitleOverride = t }
        callingText.text = callTitleOverride ?? texts.t("calling.title")
        idleView.isHidden = true
        callingView.isHidden = false
        callTimeoutTimer?.invalidate()
        callTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.showIdle(hint: self.texts.t("calling.no_answer"))
        }
        pulse.layer.removeAllAnimations()
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.25
        anim.toValue = 1.0
        anim.duration = 0.9
        anim.autoreverses = true
        anim.repeatCount = .infinity
        pulse.layer.add(anim, forKey: "pulse")
    }

    // MARK: - core イベント (main queue)

    private func onUiEvent(_ ev: [String: Any]) {
        switch ConfigUtil.evStr(ev, "t") {
        case "state":
            let st = ConfigUtil.evStr(ev, "state")
            if st == "calling" {
                if boot.role == "door_station" { showCalling() }
            } else if st == "idle" {
                onSipIdle()
            } else if st == "in_call" {
                onSipInCall(ev)
            }
        case "chime":
            exitScreensaver()
            // カスタム音 (assets の audio_path) があればそれを、無ければ内蔵チャイム音
            let path = ConfigUtil.evStr(ev, "audio_path")
            audio.playAsset(path: path) { AudioServicesPlaySystemSound(1013) }
        case "reply":
            exitScreensaver()
            // カスタム音声があれば再生 (無い時は core が TTS 済み — 二重発話しない)
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
            replyTimer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) { [weak self] _ in
                self?.replyBanner.isHidden = true
            }
            // 訪客が見たら呼び出し継続は不要 → 待機へ
            callTimeoutTimer?.invalidate()
            showIdle()
        case "visitor_lang":
            // 訪客言語の切替 (自操作の複製 / 他端末からの変更 / 無操作復帰)
            let door = ConfigUtil.evStr(ev, "door")
            if boot.role == "door_station" && (door.isEmpty || door == boot.door) {
                setVisitorLang(ConfigUtil.evStr(ev, "lang"))
            }
        case "asset_ready":
            // 前取り完了 — 背景画像が待ちだったら読み直す
            if let h = themeHash, ConfigUtil.evStr(ev, "hash") == h, themeBg.image == nil {
                loadThemeImage(h)
            }
        case "display":
            applyDisplayValues(ev)
        case "emergency":
            // 自端末発報も他端末発報も同じ UI (イベント複製で届く)
            if ConfigUtil.evBool(ev, "active") {
                showEmergency()
                let vol = ConfigUtil.int(ev, "alarm_volume", 100)
                audio.startSiren(customPath: ConfigUtil.evStr(ev, "audio_path"), volume: vol)
            } else {
                hideEmergency()
            }
        case "peers_changed", "config_changed":
            refreshNodeInfo()
        default:
            break
        }
    }

    // MARK: - 通話 (door_station 側の in_call — 室内機側は IncomingViewController)

    /// SIP in_call — 門口機は相手映像 (peer_stream = 対称 MJPEG) を表示。
    private func onSipInCall(_ ev: [String: Any]) {
        inCall = true
        callingText.text = texts.t("incall.title")
        guard boot.role == "door_station" else { return }
        callTimeoutTimer?.invalidate()
        let stream = ConfigUtil.evStr(ev, "peer_stream")
        if !stream.isEmpty {
            showInCall(streamUrl: stream)  // 双方向映像の門口側 (相手 = 室内機)
        } else {
            // 相手不明 (電話/網頁) — 網頁通話なら自機 /peer-frame.jpg にフレームが来る
            peerPollBusy = false
            peerPollTimer?.invalidate()
            peerPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
        inCallStreamer?.stop()
        inCallStreamer = nil
        peerVideo.image = nil
        if let u = streamUrl, !u.isEmpty {
            inCallStreamer = MjpegClient(urlString: u) { [weak self] img in
                self?.peerVideo.image = img
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
        inCallView.isHidden = true
    }

    @objc private func onEndCallClick() {
        core.sipHangup()  // state idle が来て closeInCall される (即時にも畳む)
        closeInCall()
    }

    /// 網頁通話の相手映像: 自機 httpd の /peer-frame.jpg を輪詢 (通話中のみ)。
    private func pollPeerFrame() {
        guard inCall, !peerPollBusy else { return }
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

    // MARK: - 操作

    @objc private func onCallClick() {
        core.press(door: boot.door)
        showCalling()
    }

    @objc private func onCancelClick() {
        callTimeoutTimer?.invalidate()
        showIdle()
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

    /// 管理解錠後の情報画面 (iOS の kiosk 解除は監督 SAM 側 — docs/provision.md 参照)。
    private func showAdminInfo() {
        UIApplication.shared.isIdleTimerDisabled = false  // 保守中は自動ロックを許す
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
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            UIApplication.shared.isIdleTimerDisabled = true
        })
        present(a, animated: true)
    }

    // MARK: - カメラ / H.264 (Phase 6a)

    /// カメラ+マイク権限を求めてから採集開始 (門口機/室内機どちらも — 対称 MJPEG 対講のため)。
    private func requestAvPermissionsThenStartCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            DispatchQueue.main.async { self?.maybeStartCamera() }
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }  // SIP 対講 (pjsip) 用
    }

    /// devices.<自>.local.camera の設定オブジェクト (無ければ nil)。
    private func cameraLocalCfg() -> [String: Any]? {
        guard !nodeId.isEmpty else { return nil }
        return ConfigUtil.dig(cfg, "devices.\(nodeId).local.camera") as? [String: Any]
    }

    private func maybeStartCamera() {
        // codec=h264/auto の間は h264_resolution を採集目標にする (Phase 6a)。
        // MJPEG 側は core の frame_bus が縮小するので大きくても無害。
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
        let wanted = core.videoEncoderWanted()
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
}
