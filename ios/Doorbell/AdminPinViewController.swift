import CommonCrypto
import UIKit

// The 管理パスワード is one cluster-wide secret. Core verifies it against the replicated salted
// hash — constant-time, rate-limited, and shared with the web admin's login — so an offline device
// still accepts the same password. A build whose Core does not publish that entry point yet falls
// back to the legacy per-node digest in `exit_pin.txt`; the first successful Core verification
// deletes that file, which is the migration the owner asked for.
///
/// The prompt itself is the system alert with a secure text field. This controller is the
/// transparent host that presents it, so callers keep presenting one object and get one answer.
final class AdminPinViewController: UIViewController {

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
    private var errorText = ""
    private weak var alert: UIAlertController?
    private weak var confirmAction: UIAlertAction?
    /// A cluster with no password must never be locked out of its own device: the gate turns into
    /// the set-password prompt and the first password entered here becomes the cluster's.
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
        view.backgroundColor = .clear
        settingPassword = core.map { $0.supportsAdminPassword && !$0.adminPasswordIsSet } ?? false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if alert == nil { presentPrompt() }
    }

    /// The system alert: the prompt as its title, the last error as its message, one secure
    /// field, Cancel and the confirming action.
    private func presentPrompt() {
        let prompt = UIAlertController(
            title: texts.t(settingPassword ? "admin.password_set_prompt" : "admin.pin_prompt"),
            message: errorText.isEmpty ? nil : errorText, preferredStyle: .alert)
        prompt.view.accessibilityIdentifier = "admin_password_prompt"
        prompt.addTextField { [weak self] field in
            field.isSecureTextEntry = true
            field.keyboardType = .asciiCapable
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.returnKeyType = .done
            field.placeholder = self?.texts.t("admin.password")
            field.accessibilityIdentifier = "admin_password_field"
            field.addTarget(self, action: #selector(AdminPinViewController.fieldChanged(_:)),
                            for: .editingChanged)
        }
        prompt.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel) {
            [weak self] _ in self?.onCancel()
        })
        let confirm = UIAlertAction(title: texts.t("admin.login"), style: .default) {
            [weak self, weak prompt] _ in
            self?.pin = prompt?.textFields?.first?.text ?? ""
            self?.submit()
        }
        confirm.accessibilityIdentifier = "pin_ok"
        confirm.isEnabled = false
        prompt.addAction(confirm)
        prompt.preferredAction = confirm
        alert = prompt
        confirmAction = confirm
        present(prompt, animated: true)
    }

    @objc private func fieldChanged(_ field: UITextField) {
        let text = field.text ?? ""
        if text.count > AdminPinViewController.maxLen {
            field.text = String(text.prefix(AdminPinViewController.maxLen))
        }
        confirmAction?.isEnabled = !(field.text ?? "").isEmpty
    }

    private func onCancel() {
        let callback = onCancelled
        dismiss(animated: false) { callback?() }
    }

    /// A refused entry puts the prompt back with the reason in it and an empty field.
    private func show(error: String) {
        errorText = error
        pin = ""
        presentPrompt()
    }

    private func submit() {
        if Date() < AdminPinViewController.lockedUntil {
            show(error: texts.t("admin.locked"))
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
            show(error: AdminPinViewController.fails >= 5 ? texts.t("admin.locked")
                : texts.t("admin.pin_wrong"))
            return
        case .lockedOut:
            // Core has stopped answering for everyone; the old local digest must not become a
            // second way past that.
            AdminPinViewController.retireLegacyDigest()
            show(error: texts.t("admin.locked"))
            return
        case .unset:
            settingPassword = true
            show(error: "")
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
            unlock()
            return
        }
        AdminPinViewController.fails += 1
        if AdminPinViewController.fails >= 5 {
            AdminPinViewController.fails = 0
            AdminPinViewController.lockedUntil = Date().addingTimeInterval(10 * 60)
            show(error: texts.t("admin.locked"))
        } else {
            show(error: texts.t("admin.pin_wrong"))
        }
    }

    /// The set-once path: an empty current password is accepted only while the cluster has none,
    /// so this is the same trust-on-first-use the first web login takes.
    private func setFirstPassword() {
        guard pin.count >= AdminPinViewController.minLen else {
            show(error: texts.t("admin.password_too_short"))
            return
        }
        switch core?.setAdminPassword(current: "", new: pin) ?? .failed {
        case .ok:
            AdminPinViewController.fails = 0
            AdminPinViewController.retireLegacyDigest()
            unlock()
        case .lockedOut:
            show(error: texts.t("admin.locked"))
        default:
            show(error: texts.t("settings.password_failed"))
        }
    }

    private func unlock() {
        let callback = onUnlocked
        dismiss(animated: false) { callback?() }
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
