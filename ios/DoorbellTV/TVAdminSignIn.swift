import UIKit

/// The administrator sign-in of the Apple TV: a full-screen page with one secure field, the
/// remember choice, Sign in and Cancel. The Menu button always cancels, so focus can never be
/// trapped on this page.
final class TVAdminSignInViewController: UIViewController, UITextFieldDelegate {

    /// Password and the remember choice. The host answers through `showError` or dismisses.
    var onSubmit: ((String, Bool) -> Void)?
    var onCancel: (() -> Void)?

    private let texts: Texts
    private let titleText: String
    private let offersRemember: Bool
    private var remember = false
    private let field = UITextField()
    private let errorLabel = SystemStyle.label(.title3, color: .systemRed)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let signIn: UIButton
    private let cancel: UIButton
    private let rememberButton: UIButton

    init(texts: Texts, title: String, error: String, offersRemember: Bool) {
        self.texts = texts
        titleText = title
        self.offersRemember = offersRemember
        signIn = SystemStyle.button(.filled, title: texts.t("admin.sign_in"), large: true)
        cancel = SystemStyle.button(.gray, title: texts.t("admin.cancel"), large: true)
        rememberButton = SystemStyle.button(.plain, title: "", large: true)
        super.init(nibName: nil, bundle: nil)
        errorLabel.text = error
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SystemStyle.groupedBackground
        view.accessibilityIdentifier = "admin_sign_in"

        let icon = UIImageView(image: AppIcon.image(.shield))
        icon.tintColor = SystemStyle.secondaryLabel
        icon.contentMode = .scaleAspectFit
        let heading = SystemStyle.label(.title1, weight: .semibold)
        heading.text = titleText
        heading.textAlignment = .center

        field.isSecureTextEntry = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        field.textAlignment = .center
        field.placeholder = texts.t("admin.password")
        field.font = SystemStyle.font(.title2, weight: nil)
        field.delegate = self
        field.accessibilityIdentifier = "admin_password_field"

        errorLabel.textAlignment = .center
        errorLabel.isHidden = errorLabel.text?.isEmpty ?? true
        spinner.hidesWhenStopped = true

        signIn.accessibilityIdentifier = "pin_ok"
        signIn.addTarget(self, action: #selector(submit), for: .primaryActionTriggered)
        cancel.accessibilityIdentifier = "admin_cancel"
        cancel.addTarget(self, action: #selector(cancelTapped), for: .primaryActionTriggered)
        rememberButton.accessibilityIdentifier = "admin_remember"
        rememberButton.addTarget(self, action: #selector(toggleRemember),
                                 for: .primaryActionTriggered)
        rememberButton.isHidden = !offersRemember
        updateRemember()

        let buttons = UIStackView(arrangedSubviews: [cancel, signIn])
        buttons.axis = .horizontal
        buttons.spacing = Space.xl
        buttons.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [icon, heading, field, errorLabel,
                                                   rememberButton, buttons, spinner])
        stack.axis = .vertical
        stack.spacing = Space.xl
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            field.widthAnchor.constraint(equalToConstant: 760),
            field.heightAnchor.constraint(equalToConstant: 90),
            errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 1100),
            buttons.widthAnchor.constraint(equalToConstant: 760),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { return [field] }

    /// A wrong password puts the page back in an editable state with the reason on it.
    func showError(_ message: String) {
        setBusy(false)
        field.text = ""
        errorLabel.text = message
        errorLabel.isHidden = message.isEmpty
        setNeedsFocusUpdate()
    }

    private func setBusy(_ busy: Bool) {
        if busy {
            errorLabel.text = texts.t("admin.checking")
            errorLabel.isHidden = false
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        for control in [signIn, cancel, rememberButton, field] as [UIControl] {
            control.isEnabled = !busy
        }
    }

    @objc private func toggleRemember() {
        remember.toggle()
        updateRemember()
    }

    private func updateRemember() {
        let title = texts.t("admin.remember")
        rememberButton.setTitle(title, for: .normal)
        rememberButton.setImage(UIImage(systemName: remember ? "checkmark.square.fill" : "square"),
                                for: .normal)
        rememberButton.accessibilityValue = remember ? "1" : "0"
    }

    @objc private func submit() {
        let password = field.text ?? ""
        guard !password.isEmpty else { return }
        setBusy(true)
        // One turn of the run loop so the busy state is on screen before Core's hash check runs.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onSubmit?(password, self.remember)
        }
    }

    @objc private func cancelTapped() { onCancel?() }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            onCancel?()
            return
        }
        super.pressesEnded(presses, with: event)
    }
}
