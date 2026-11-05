import CommonCrypto
import UIKit

// The 管理パスワード is one cluster-wide secret. Core verifies it against the replicated salted
// hash — constant-time, rate-limited, and shared with the web admin's login — so an offline device
// still accepts the same password. A build whose Core does not publish that entry point yet falls
// back to the legacy per-node digest in `exit_pin.txt`; the first successful Core verification
// deletes that file, which is the migration the owner asked for.
final class AdminPinViewController: UIViewController, UITextFieldDelegate {

    // Core's admin password bounds (admin_password.h). The password is free text, so it is typed on
    // the system keyboard rather than a digits-only pad.
    private static let minLen = 8
    private static let maxLen = 128
    private static var fails = 0
    private static var lockedUntil = Date.distantPast

    var onUnlocked: (() -> Void)?
    /// Runs after the user dismissed the prompt without unlocking.
    var onCancelled: (() -> Void)?
    private let core: CoreBridge?
    private let texts: Texts
    private var pin = ""
    private let field = UITextField()
    private let errorLabel = UILabel()
    private let promptLabel = UILabel()
    /// A cluster with no password must never be locked out of its own device: the gate turns into
    /// 「管理パスワードを設定」 and the first password entered here becomes the cluster's.
    private var settingPassword = false

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

        settingPassword = core.map { $0.supportsAdminPassword && !$0.adminPasswordIsSet } ?? false
        promptLabel.text = texts.t(settingPassword ? "admin.password_set_prompt"
                                                   : "admin.pin_prompt")
        promptLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        promptLabel.textColor = .white
        promptLabel.textAlignment = .center

        field.isSecureTextEntry = true
        field.keyboardType = .asciiCapable
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        field.delegate = self
        field.font = .systemFont(ofSize: 24)
        field.textColor = UIColor(white: 0.1, alpha: 1)
        field.backgroundColor = .white
        field.textAlignment = .center
        field.layer.cornerRadius = 8
        field.accessibilityIdentifier = "admin_password_field"
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true

        errorLabel.font = .systemFont(ofSize: 17)
        errorLabel.textColor = UIColor(red: 0.88, green: 0.36, blue: 0.30, alpha: 1)
        errorLabel.textAlignment = .center
        errorLabel.text = " "

        let stack = UIStackView(arrangedSubviews: [promptLabel, field, errorLabel])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cancel = UIButton(type: .system)
        cancel.setTitle(texts.t("calling.cancel"), for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 20)
        cancel.setTitleColor(UIColor(white: 1, alpha: 0.75), for: .normal)
        cancel.backgroundColor = UIColor(white: 1, alpha: 0.12)
        cancel.layer.cornerRadius = 10
        cancel.addTarget(self, action: #selector(onCancel), for: .primaryActionTriggered)
        let ok = UIButton(type: .system)
        ok.setTitle(texts.t("admin.login"), for: .normal)
        ok.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        ok.setTitleColor(.white, for: .normal)
        ok.backgroundColor = UIColor(red: 0.05, green: 0.36, blue: 0.75, alpha: 1)
        ok.layer.cornerRadius = 10
        ok.accessibilityIdentifier = "pin_ok"
        ok.addTarget(self, action: #selector(onSubmit), for: .primaryActionTriggered)
        let buttons = UIStackView(arrangedSubviews: [cancel, ok])
        buttons.axis = .horizontal
        buttons.spacing = 12
        buttons.distribution = .fillEqually
        buttons.heightAnchor.constraint(equalToConstant: 52).isActive = true
        stack.addArrangedSubview(buttons)

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

    @objc private func onCancel() {
        let callback = onCancelled
        dismiss(animated: true) { callback?() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        let current = (textField.text ?? "") as NSString
        let next = current.replacingCharacters(in: range, with: string)
        errorLabel.text = " "
        return next.count <= AdminPinViewController.maxLen
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onSubmit()
        return false
    }

    @objc private func onSubmit() {
        pin = field.text ?? ""
        submit()
    }

    private func submit() {
        if Date() < AdminPinViewController.lockedUntil {
            errorLabel.text = texts.t("admin.locked")
            clearEntry()
            return
        }
        if settingPassword {
            setFirstPassword()
            return
        }
        switch core?.verifyAdminPassword(pin) ?? .unavailable {
        case .accepted:
            AdminPinViewController.fails = 0
            AdminPinViewController.retireLegacyDigest()
            unlock()
            return
        case .wrong:
            // Core owns the lockout in this path; the local counter only shapes the message.
            AdminPinViewController.fails += 1
            errorLabel.text = AdminPinViewController.fails >= 5 ? texts.t("admin.locked")
                : texts.t("admin.pin_wrong")
            clearEntry()
            return
        case .lockedOut:
            // Core has stopped answering for everyone; the old local digest must not become a
            // second way past that.
            AdminPinViewController.retireLegacyDigest()
            errorLabel.text = texts.t("admin.locked")
            clearEntry()
            return
        case .unset:
            settingPassword = true
            promptLabel.text = texts.t("admin.password_set_prompt")
            errorLabel.text = " "
            clearEntry()
            return
        case .unavailable:
            break
        }
        // Core could not answer. Only an existing legacy device digest may stand in; there is no
        // built-in default password.
        let pinFile = AdminPinViewController.legacyDigestPath()
        let expected = ((try? String(contentsOfFile: pinFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !expected.isEmpty && AdminPinViewController.sha256Hex(pin) == expected {
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
        clearEntry()
    }

    /// The set-once path: an empty current password is accepted only while the cluster has none,
    /// so this is the same trust-on-first-use the first web login takes.
    private func setFirstPassword() {
        guard pin.count >= AdminPinViewController.minLen else {
            errorLabel.text = texts.t("admin.password_too_short")
            return
        }
        switch core?.setAdminPassword(current: "", new: pin) ?? .failed {
        case .ok:
            AdminPinViewController.fails = 0
            AdminPinViewController.retireLegacyDigest()
            unlock()
        case .lockedOut:
            errorLabel.text = texts.t("admin.locked")
            clearEntry()
        default:
            errorLabel.text = texts.t("settings.password_failed")
            clearEntry()
        }
    }

    private func unlock() {
        let callback = onUnlocked
        dismiss(animated: true) { callback?() }
    }

    private func clearEntry() {
        pin = ""
        field.text = ""
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
