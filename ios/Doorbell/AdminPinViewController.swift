import CommonCrypto
import UIKit

// The 管理パスワード is one cluster-wide secret. Core verifies it against the replicated salted
// hash — constant-time, rate-limited, and shared with the web admin's login — so an offline device
// still accepts the same password. A build whose Core does not publish that entry point yet falls
// back to the legacy per-node digest in `exit_pin.txt`; the first successful Core verification
// deletes that file, which is the migration the owner asked for.
final class AdminPinViewController: UIViewController {

    private static let maxLen = 6
    private static var fails = 0
    private static var lockedUntil = Date.distantPast

    var onUnlocked: (() -> Void)?
    private let core: CoreBridge?
    private let texts: Texts
    private var pin = ""
    private let display = UILabel()
    private let errorLabel = UILabel()

    init(texts: Texts, core: CoreBridge? = nil) {
        self.core = core
        self.texts = texts
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.75)

        let card = UIView()
        card.backgroundColor = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)
        card.layer.cornerRadius = 14
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        let title = UILabel()
        title.text = texts.t("admin.pin_prompt")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.textColor = .white
        title.textAlignment = .center

        display.font = UIFont.monospacedDigitSystemFont(ofSize: 34, weight: .medium)
        display.textColor = .white
        display.textAlignment = .center
        display.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        errorLabel.font = .systemFont(ofSize: 17)
        errorLabel.textColor = UIColor(red: 0.88, green: 0.36, blue: 0.30, alpha: 1)
        errorLabel.textAlignment = .center
        errorLabel.text = " "

        let stack = UIStackView(arrangedSubviews: [title, display, errorLabel])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"],
                                ["back", "0", "ok"]]
        for r in rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
            for key in r {
                let b = UIButton(type: .system)
                let label: String
                switch key {
                case "back": label = "⌫"
                case "ok": label = "OK"
                default: label = key
                }
                b.setTitle(label, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 26, weight: .medium)
                b.setTitleColor(.white, for: .normal)
                b.backgroundColor = UIColor(white: 1, alpha: 0.12)
                b.layer.cornerRadius = 10
                b.heightAnchor.constraint(equalToConstant: 64).isActive = true
                b.accessibilityIdentifier = "pin_\(key)"
                b.addTarget(self, action: #selector(onKey(_:)), for: .primaryActionTriggered)
                row.addArrangedSubview(b)
            }
            stack.addArrangedSubview(row)
        }

        let cancel = UIButton(type: .system)
        cancel.setTitle(texts.t("calling.cancel"), for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 20)
        cancel.setTitleColor(UIColor(white: 1, alpha: 0.6), for: .normal)
        cancel.addTarget(self, action: #selector(onCancel), for: .primaryActionTriggered)
        stack.addArrangedSubview(cancel)

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 380),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
        ])
    }

    @objc private func onCancel() { dismiss(animated: true) }

    @objc private func onKey(_ sender: UIButton) {
        errorLabel.text = " "
        guard let id = sender.accessibilityIdentifier?.dropFirst(4) else { return }
        switch id {
        case "back":
            if !pin.isEmpty { pin.removeLast() }
        case "ok":
            submit()
        default:
            if pin.count < AdminPinViewController.maxLen { pin += id }
        }
        display.text = String(repeating: "●", count: pin.count)
    }

    private func submit() {
        if Date() < AdminPinViewController.lockedUntil {
            errorLabel.text = texts.t("admin.locked")
            pin = ""
            display.text = ""
            return
        }
        if let accepted = core?.verifyAdminPassword(pin) {
            if accepted {
                AdminPinViewController.fails = 0
                AdminPinViewController.retireLegacyDigest()
                let cb = onUnlocked
                dismiss(animated: true) { cb?() }
                return
            }
            // Core owns the lockout in this path; the local counter only shapes the message.
            AdminPinViewController.fails += 1
            errorLabel.text = AdminPinViewController.fails >= 5 ? texts.t("admin.locked")
                : texts.t("admin.pin_wrong")
            pin = ""
            display.text = ""
            return
        }
        var expected = AdminPinViewController.sha256Hex("000000")
        let pinFile = AdminPinViewController.legacyDigestPath()
        if let s = try? String(contentsOfFile: pinFile, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            expected = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if AdminPinViewController.sha256Hex(pin) == expected {
            AdminPinViewController.fails = 0
            let cb = onUnlocked
            dismiss(animated: true) { cb?() }
            return
        }
        AdminPinViewController.fails += 1
        if AdminPinViewController.fails >= 5 {
            AdminPinViewController.fails = 0
            AdminPinViewController.lockedUntil = Date().addingTimeInterval(10 * 60)
            errorLabel.text = texts.t("admin.locked")
        } else {
            errorLabel.text = texts.t("admin.pin_wrong")
        }
        pin = ""
        display.text = ""
    }

    private static func legacyDigestPath() -> String {
        return (BootConfig.dataDir() as NSString).appendingPathComponent("exit_pin.txt")
    }

    /// Once Core has accepted the cluster password on this device, the old per-node digest is a
    /// second secret that could still open the screen. It is removed rather than left behind.
    private static func retireLegacyDigest() {
        let path = legacyDigestPath()
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
            IOSAvailability.logDebug("retired the legacy exit_pin digest after a Core verification")
        } catch {
            IOSAvailability.logDebug("could not retire the legacy exit_pin digest")
        }
    }

    private static func sha256Hex(_ s: String) -> String {
        let data = Array(s.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(data, CC_LONG(data.count), &digest)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
