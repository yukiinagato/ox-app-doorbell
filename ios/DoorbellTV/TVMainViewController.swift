// tvOS 監視端の待機画面 — 時計 + ノード情報 + fleet 状態の常駐表示。
// 来鈴 (chime) の全画面被せは TVAppDelegate → IncomingViewController。
// ここは待機のほか、reply バナー / 緊急 (SOS) 警報の全画面赤 + サイレン + PIN 解除
// (描画テンキー — Siri Remote フォーカス対応) を持つ。
import UIKit

final class TVMainViewController: UIViewController {

    private let core: CoreBridge
    private let boot: BootConfig
    private let texts = Texts()
    private let audio = SirenPlayer()

    private var cfg: [String: Any]?
    private var emergencyActive = false
    private var cancelRequiresPin = true

    private let clockLabel = UILabel()
    private let dateLabel = UILabel()
    private let statusLabel = UILabel()
    private let nodeInfo = UILabel()
    private let replyBanner = UIView()
    private let replyCaption = UILabel()
    private let replyText = UILabel()
    private let emergencyView = UIView()
    private let emergencyTitle = UILabel()
    private let emergencyNote = UILabel()
    private let emergencyCancel = UIButton(type: .system)

    private var clockTimer: Timer?
    private var replyTimer: Timer?

    init(core: CoreBridge, boot: BootConfig) {
        self.core = core
        self.boot = boot
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.063, green: 0.078, blue: 0.094, alpha: 1)
        texts.setLang(boot.uiLang)
        buildUi()
        refreshNodeInfo()
        core.addHandler("tv_main") { [weak self] ev in self?.onUiEvent(ev) }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
        updateClock()
    }

    private func buildUi() {
        clockLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 140, weight: .thin)
        clockLabel.textColor = UIColor(white: 0.94, alpha: 1)
        dateLabel.font = .systemFont(ofSize: 40)
        dateLabel.textColor = UIColor(white: 0.62, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 30)
        statusLabel.textColor = UIColor(white: 0.62, alpha: 1)
        let stack = UIStackView(arrangedSubviews: [clockLabel, dateLabel, statusLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        nodeInfo.font = .systemFont(ofSize: 24)
        nodeInfo.textColor = UIColor(white: 1, alpha: 0.35)
        nodeInfo.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nodeInfo)

        replyBanner.backgroundColor = UIColor(red: 0.11, green: 0.30, blue: 0.16, alpha: 0.97)
        replyBanner.layer.cornerRadius = 20
        replyBanner.isHidden = true
        replyBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(replyBanner)
        replyCaption.font = .systemFont(ofSize: 26)
        replyCaption.textColor = UIColor(white: 1, alpha: 0.7)
        replyText.font = .systemFont(ofSize: 44, weight: .bold)
        replyText.textColor = .white
        replyText.numberOfLines = 0
        replyText.textAlignment = .center
        let rstack = UIStackView(arrangedSubviews: [replyCaption, replyText])
        rstack.axis = .vertical
        rstack.spacing = 10
        rstack.alignment = .center
        rstack.translatesAutoresizingMaskIntoConstraints = false
        replyBanner.addSubview(rstack)

        emergencyView.backgroundColor = UIColor(red: 0.55, green: 0.05, blue: 0.04, alpha: 1)
        emergencyView.isHidden = true
        emergencyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emergencyView)
        emergencyTitle.font = .systemFont(ofSize: 100, weight: .heavy)
        emergencyTitle.textColor = .white
        emergencyNote.font = .systemFont(ofSize: 38)
        emergencyNote.textColor = UIColor(white: 1, alpha: 0.85)
        emergencyCancel.titleLabel?.font = .systemFont(ofSize: 34, weight: .semibold)
        emergencyCancel.addTarget(self, action: #selector(onEmergencyCancel),
                                  for: .primaryActionTriggered)
        let estack = UIStackView(arrangedSubviews: [emergencyTitle, emergencyNote,
                                                    emergencyCancel])
        estack.axis = .vertical
        estack.spacing = 40
        estack.alignment = .center
        estack.translatesAutoresizingMaskIntoConstraints = false
        emergencyView.addSubview(estack)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            nodeInfo.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 40),
            nodeInfo.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -30),
            replyBanner.topAnchor.constraint(equalTo: g.topAnchor, constant: 40),
            replyBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            replyBanner.widthAnchor.constraint(lessThanOrEqualTo: g.widthAnchor, constant: -120),
            rstack.topAnchor.constraint(equalTo: replyBanner.topAnchor, constant: 24),
            rstack.bottomAnchor.constraint(equalTo: replyBanner.bottomAnchor, constant: -24),
            rstack.leadingAnchor.constraint(equalTo: replyBanner.leadingAnchor, constant: 44),
            rstack.trailingAnchor.constraint(equalTo: replyBanner.trailingAnchor, constant: -44),
            emergencyView.topAnchor.constraint(equalTo: view.topAnchor),
            emergencyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emergencyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emergencyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            estack.centerXAnchor.constraint(equalTo: emergencyView.centerXAnchor),
            estack.centerYAnchor.constraint(equalTo: emergencyView.centerYAnchor),
        ])
    }

    private func applyStrings() {
        statusLabel.text = texts.t("panel.monitor_title")
        replyCaption.text = texts.t("reply.banner")
        emergencyTitle.text = texts.t("emergency.title")
        emergencyNote.text = texts.t("emergency.notified")
        emergencyCancel.setTitle(texts.t("emergency.cancel"), for: .normal)
    }

    private func updateClock() {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: Date())
        clockLabel.text = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0,
                                 c.second ?? 0)
        let yobi = ["日", "月", "火", "水", "木", "金", "土"]
        dateLabel.text = String(format: "%d年%d月%d日 (%@)", c.year ?? 0, c.month ?? 0,
                                c.day ?? 0, yobi[((c.weekday ?? 1) - 1) % 7])
    }

    private func refreshNodeInfo() {
        cfg = core.config()
        texts.setConfig(cfg)
        cancelRequiresPin = ConfigUtil.bool(cfg, "emergency.cancel_requires_pin", true)
        if let st = core.status() {
            if let node = st["node"] as? [String: Any] {
                let peers = (st["peers"] as? [Any])?.count ?? 0
                nodeInfo.text =
                    "\(ConfigUtil.evStr(node, "name")) · v\(ConfigUtil.evStr(node, "version"))" +
                    " · peers \(peers)"
            }
            if let em = st["emergency"] as? [String: Any] {
                if ConfigUtil.evBool(em, "active") {
                    let wasActive = emergencyActive
                    showEmergency()
                    // 再起動追い付き時もサイレンを鳴らす (内蔵音 — MainViewController と同じ)
                    if !wasActive {
                        audio.startSiren(customPath: "",
                                         volume: ConfigUtil.int(cfg, "emergency.alarm_volume", 100))
                    }
                } else {
                    hideEmergency()
                }
            }
        }
        applyStrings()
    }

    // MARK: - core イベント (main queue)

    private func onUiEvent(_ ev: [String: Any]) {
        switch ConfigUtil.evStr(ev, "t") {
        case "reply":
            replyText.text = ConfigUtil.evStr(ev, "text")
            replyBanner.isHidden = false
            var ttl = ConfigUtil.double(ev, "ttl_s", 30)
            if ttl <= 0 { ttl = 30 }
            replyTimer?.invalidate()
            replyTimer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) { [weak self] _ in
                self?.replyBanner.isHidden = true
            }
        case "emergency":
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

    // MARK: - 緊急 (SOS)

    private func showEmergency() {
        guard !emergencyActive else { return }
        emergencyActive = true
        presentedViewController?.dismiss(animated: false)  // 来鈴より警報優先
        emergencyView.isHidden = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func hideEmergency() {
        guard emergencyActive else { return }
        emergencyActive = false
        audio.stop()
        emergencyView.isHidden = true
    }

    @objc private func onEmergencyCancel() {
        if cancelRequiresPin {
            let dlg = AdminPinViewController(texts: texts)
            dlg.onUnlocked = { [weak self] in
                self?.core.emergency(false)
                self?.hideEmergency()
            }
            present(dlg, animated: true)
            return
        }
        core.emergency(false)
        hideEmergency()
    }
}
