// Onboarding screen for a device that is not a cluster member yet (spec §5.0).
//
// It replaces the main UI whenever `pairing.state` is unpaired, joining or persist_error, and it
// renders every pairing event Core publishes: join_result, pairing_state, paired,
// pairing_persistence_error, join_token_changed. Nothing here decides the state on its own.
//
// The same controller serves iOS and tvOS. tvOS gets the focusable keypad for the Pairing PIN and
// never offers a camera path; the shared layout otherwise matches so the copy stays identical.
import UIKit

final class PairingViewController: UIViewController {

    /// Called when the user chooses "Set up later"; the host shows the persistent banner.
    var onDefer: (() -> Void)?
    /// Called once the device is a cluster member and the success confirmation has been read.
    var onFinished: (() -> Void)?

    private let core: CoreBridge
    private let boot: BootConfig
    private let texts: Texts

    private enum Screen {
        case status        // searching / joining / joined
        case codeEntry     // address + Pairing PIN
        case created       // cluster created: keep the code card on screen
        case persistError
    }

    private var screen = Screen.status
    private var snapshot = PairingSnapshot(nil)
    private var joinInFlight = false
    /// The invitation currently filled into the form, if the form came from a link or a scan.
    private var pendingInvitation: PairUri?
    private var createConfirmed = false
    private var finishing = false
    private var pollTimer: Timer?
    private var dismissTimer: Timer?

    private let scroll = UIScrollView()
    private let contentStack = UIStackView()
    private let titleLabel = UILabel()
    private let identityLabel = UILabel()
    private let spinner = IOSAvailability.activityIndicator(large: true)
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let errorLabel = UILabel()
    private let detailLabel = UILabel()
    private lazy var qrCard = PairingQrCardView(core: core, texts: texts)
    private lazy var codeCard = PairingCodeCardView(texts: texts, core: core)

    private let actionStack = UIStackView()
    private lazy var joinButton = PairingTheme.button(texts.t("pair.join_with_code"))
    private lazy var createButton = PairingTheme.button(texts.t("pair.create_home"))
    private lazy var laterButton = PairingTheme.button(texts.t("pair.later"))
    private lazy var retryButton = PairingTheme.button(texts.t("pair.retry"), filled: true)

    private let codeEntryCard = UIView()
    private let hostField = UITextField()
    private let pinField = UITextField()
    private lazy var submitButton = PairingTheme.button(texts.t("pair.join_with_code"),
                                                        filled: true)
    private lazy var backButton = PairingTheme.button(texts.t("panel.back"))
    private var keyboardInset: NSLayoutConstraint?

    init(core: CoreBridge, boot: BootConfig, texts: Texts) {
        self.core = core
        self.boot = boot
        self.texts = texts
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        pollTimer?.invalidate()
        dismissTimer?.invalidate()
        core.removeHandler("pairing_gate")
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PairingTheme.background
        buildUi()
        core.addHandler("pairing_gate") { [weak self] ev in self?.onUiEvent(ev) }
        refresh(PairingSnapshot.load(core))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pollTimer?.invalidate()
        // Countdowns and the pending list tick from the authoritative snapshot, never from a
        // local clock guess.
        pollTimer = IOSAvailability.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            guard let self = self else { return }
            self.refresh(PairingSnapshot.load(self.core))
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
    }


    private func buildUi() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.alignment = .center
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(contentStack)

        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        let bottom = scroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        keyboardInset = bottom
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            bottom,
            contentStack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -24),
            contentStack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
        ])
        let columnWidth = contentStack.widthAnchor.constraint(equalTo: scroll.widthAnchor,
                                                              constant: -48)
        columnWidth.priority = UILayoutPriority(999)
        columnWidth.isActive = true

        titleLabel.text = texts.t("pair.title_unpaired")
        titleLabel.font = .boldSystemFont(ofSize: PairingTheme.titleSize)
        titleLabel.textColor = PairingTheme.foreground
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityIdentifier = "pair_title"

        identityLabel.font = .systemFont(ofSize: PairingTheme.smallSize)
        identityLabel.textColor = PairingTheme.dim
        identityLabel.textAlignment = .center
        identityLabel.numberOfLines = 0

        spinner.color = PairingTheme.foreground
        spinner.hidesWhenStopped = true

        statusLabel.font = .systemFont(ofSize: PairingTheme.bodySize, weight: .semibold)
        statusLabel.textColor = PairingTheme.foreground
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "pair_status"

        hintLabel.font = .systemFont(ofSize: PairingTheme.smallSize)
        hintLabel.textColor = PairingTheme.dim
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0

        errorLabel.font = .systemFont(ofSize: PairingTheme.bodySize, weight: .semibold)
        errorLabel.textColor = PairingTheme.danger
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "pair_error"

        detailLabel.font = .systemFont(ofSize: PairingTheme.smallSize)
        detailLabel.textColor = PairingTheme.dim
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        detailLabel.isHidden = true

        buildCodeEntryCard()

        joinButton.addTarget(self, action: #selector(showCodeEntry),
                             for: .primaryActionTriggered)
        joinButton.accessibilityIdentifier = "pair_join_with_code"
        createButton.addTarget(self, action: #selector(createCluster),
                               for: .primaryActionTriggered)
        createButton.accessibilityIdentifier = "pair_create_home"
        laterButton.addTarget(self, action: #selector(deferSetup), for: .primaryActionTriggered)
        laterButton.accessibilityIdentifier = "pair_later"
        retryButton.addTarget(self, action: #selector(retryPersistence),
                              for: .primaryActionTriggered)
        retryButton.accessibilityIdentifier = "pair_retry"
        codeCard.onNewCode = { [weak self] in self?.startCodeCard() }

        actionStack.axis = .vertical
        actionStack.spacing = 12
        actionStack.alignment = .fill

        let statusRow = UIStackView(arrangedSubviews: [spinner, statusLabel])
        statusRow.axis = .horizontal
        statusRow.spacing = 12
        statusRow.alignment = .center

        for element in [titleLabel, identityLabel, statusRow, hintLabel, errorLabel, detailLabel,
                        qrCard, codeCard, codeEntryCard, actionStack] as [UIView] {
            contentStack.addArrangedSubview(element)
            element.translatesAutoresizingMaskIntoConstraints = false
        }
        // Every element that carries text takes the whole column. `contentStack` centres its
        // children, so anything left out of this list is laid out at its intrinsic width instead:
        // a multi-line label inside a horizontal row has no useful intrinsic width and collapses
        // to a couple of characters per line, which is what the status row did on an iPad mini.
        for wide in [titleLabel, identityLabel, statusRow, hintLabel, errorLabel, detailLabel,
                     qrCard, codeCard, codeEntryCard, actionStack] as [UIView] {
            wide.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        contentStack.widthAnchor.constraint(
            lessThanOrEqualToConstant: PairingTheme.qrSize * 2.6).isActive = true
        contentStack.widthAnchor.constraint(greaterThanOrEqualToConstant:
                                            PairingTheme.qrSize).isActive = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(onInvitation(_:)),
            name: .doorbellPairInvitation, object: nil)
#if os(iOS)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification, object: nil)
#endif
    }

    private func buildCodeEntryCard() {
        codeEntryCard.backgroundColor = PairingTheme.card
        codeEntryCard.layer.cornerRadius = 14
        codeEntryCard.isHidden = true

        let addressLabel = PairingTheme.label(PairingTheme.smallSize, PairingTheme.dim)
        addressLabel.text = texts.t("pair.address_label")
        let codeLabel = PairingTheme.label(PairingTheme.smallSize, PairingTheme.dim)
        codeLabel.text = texts.t("pair.code_label")
        let instructions = PairingTheme.label(PairingTheme.smallSize, PairingTheme.dim)
        instructions.text = texts.t("pair.code_instructions")

        for field in [hostField, pinField] {
            field.borderStyle = .roundedRect
            field.backgroundColor = UIColor(white: 1, alpha: 0.12)
            field.textColor = PairingTheme.foreground
            field.font = UIFont.monospacedDigitSystemFont(ofSize: PairingTheme.bodySize,
                                                          weight: .medium)
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.delegate = self
        }
        hostField.placeholder = texts.t("pair.address_example")
        hostField.keyboardType = .numbersAndPunctuation
        hostField.accessibilityIdentifier = "pair_host_field"
        pinField.placeholder = texts.t("pair.code_label")
        pinField.keyboardType = .numberPad
        pinField.accessibilityIdentifier = "pair_pin_field"

        submitButton.addTarget(self, action: #selector(submitJoin), for: .primaryActionTriggered)
        submitButton.accessibilityIdentifier = "pair_join_submit"
        backButton.addTarget(self, action: #selector(showStatus), for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [addressLabel, hostField, codeLabel, pinField,
                                                   instructions, submitButton, backButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        codeEntryCard.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: codeEntryCard.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: codeEntryCard.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: codeEntryCard.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: codeEntryCard.trailingAnchor, constant: -18),
        ])

#if os(tvOS)
        // The remote has no numeric row; reuse the drawn keypad style used by the admin password.
        pinField.isHidden = true
        codeLabel.isHidden = true
        let keypad = PairingKeypadView(texts: texts)
        keypad.onChange = { [weak self] value in self?.pinField.text = value }
        keypad.onSubmit = { [weak self] in self?.submitJoin() }
        stack.insertArrangedSubview(keypad, at: 4)
#endif
    }


    /// Renders one authoritative snapshot. Every visible element is derived from it.
    private func refresh(_ next: PairingSnapshot) {
        guard next.hasSnapshot || snapshot.hasSnapshot else { return }
        if next.hasSnapshot { snapshot = next }
        identityLabel.text = snapshot.identityLine()
        statusLabel.isHidden = false
        statusLabel.textColor = PairingTheme.foreground
        qrCard.update(payload: snapshot.pairQr)
        codeCard.update(snapshot)

        if snapshot.state == .persistError { screen = .persistError }
        if screen == .persistError && snapshot.state != .persistError { screen = .status }
        // A successful code join must leave the entry form and show the confirmation, never
        // dismiss silently from behind the keyboard.
        if snapshot.state == .ready && screen == .codeEntry { screen = .status }

        switch screen {
        case .persistError:
            titleLabel.text = texts.t("pair.persist_error_title")
            statusLabel.text = texts.t("pair.persist_error_body")
            hintLabel.text = ""
            spinner.stopAnimating()
            qrCard.isHidden = true
            codeCard.isHidden = true
            codeEntryCard.isHidden = true
            setActions([retryButton])
        case .codeEntry:
            titleLabel.text = texts.t("pair.join_with_code")
            statusLabel.text = joinInFlight ? texts.t("pair.joining") : ""
            statusLabel.isHidden = !joinInFlight
            hintLabel.text = ""
            if joinInFlight { spinner.startAnimating() } else { spinner.stopAnimating() }
            qrCard.isHidden = true
            codeCard.isHidden = true
            codeEntryCard.isHidden = false
            submitButton.isEnabled = !joinInFlight
            setActions([])
        case .created:
            titleLabel.text = texts.t("pair.created")
            statusLabel.text = texts.t("pair.created_next")
            statusLabel.isHidden = false
            hintLabel.text = texts.t("pair.membership", "\(max(1, snapshot.memberCount))")
            spinner.stopAnimating()
            qrCard.isHidden = true
            codeCard.isHidden = false
            codeEntryCard.isHidden = true
            setActions([laterButton])
        case .status:
            titleLabel.text = texts.t("pair.title_unpaired")
            codeEntryCard.isHidden = true
            codeCard.isHidden = true
            qrCard.isHidden = false
            statusLabel.isHidden = false
            switch snapshot.state {
            case .joining:
                statusLabel.text = texts.t("pair.joining")
                hintLabel.text = ""
                spinner.startAnimating()
                setActions([])
            case .ready:
                statusLabel.text = texts.t("pair.joined") + " ✓"
                statusLabel.textColor = PairingTheme.ok
                hintLabel.text = ""
                spinner.stopAnimating()
                qrCard.isHidden = true
                setActions([])
            case .revoked:
                statusLabel.text = texts.t("pair.revoked")
                hintLabel.text = ""
                spinner.stopAnimating()
                setActions([])
            default:
                statusLabel.text = texts.t("pair.searching")
                hintLabel.text = texts.t("pair.searching_hint")
                spinner.startAnimating()
                setActions([joinButton, createButton, laterButton])
            }
        }

        if snapshot.state == .ready && screen != .created { finish() }
    }

    private func setActions(_ buttons: [UIButton]) {
        let current = actionStack.arrangedSubviews
        let unchanged = current.count == buttons.count &&
            !zip(current, buttons).contains { $0 !== $1 }
        guard !unchanged else { return }
        for view in current {
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for button in buttons { actionStack.addArrangedSubview(button) }
        actionStack.isHidden = buttons.isEmpty
    }

    /// Success is confirmed on screen before the gate closes; it is never a toast.
    private func finish() {
        guard !finishing else { return }
        finishing = true
        joinInFlight = false
        dismissTimer?.invalidate()
        dismissTimer = IOSAvailability.scheduledTimer(withTimeInterval: 2, repeats: false) {
            [weak self] _ in
            self?.onFinished?()
        }
    }

    private func showError(code: String) {
        errorLabel.text = PairingCopy.error(texts, code)
        errorLabel.isHidden = false
        let detail = PairingCopy.errorDetail(texts, code)
        detailLabel.text = detail
        detailLabel.isHidden = detail.isEmpty
    }

    private func clearError() {
        errorLabel.isHidden = true
        detailLabel.isHidden = true
    }


    private func onUiEvent(_ ev: [String: Any]) {
        switch ConfigUtil.evStr(ev, "t") {
        case "join_result":
            joinInFlight = false
            if ConfigUtil.evBool(ev, "ok") {
                clearError()
            } else {
                showError(code: ConfigUtil.evStr(ev, "err"))
            }
            refresh(PairingSnapshot.load(core))
        case "invite_rejected":
            showError(code: ConfigUtil.evStr(ev, "reason"))
            refresh(PairingSnapshot.load(core))
        case "pairing_state":
            let state = PairingState(rawValue: ConfigUtil.evStr(ev, "state")) ?? .unknown
            if state == .ready && createConfirmed && screen != .created { enterCreatedState() }
            if state == .ready || state == .joining { clearError() }
            refresh(PairingSnapshot.load(core))
        case "pairing_persistence_error":
            screen = .persistError
            showError(code: ConfigUtil.evStr(ev, "reason"))
            refresh(PairingSnapshot.load(core))
        case "paired", "join_token_changed", "pending_changed", "pairing_mode_changed":
            refresh(PairingSnapshot.load(core))
        default:
            break
        }
    }


    // MARK: - Invitations that arrive as a doorbell://pair link

    @objc private func onInvitation(_ note: Notification) {
        guard let text = note.object as? String else { return }
        present(invitation: text)
    }

    /// An invitation the user has already acted on, by tapping a link or pointing the camera at a
    /// QR. The screen fills in what it carries and asks once; it never makes somebody retype an
    /// address and a PIN they are holding in their hand.
    func present(invitation text: String) {
        switch PairUri.parse(text, core: core) {
        case .failure(let reason):
            showInvitationProblem(reason)
        case .success(let invitation):
            offer(invitation)
        }
    }

    private func showInvitationProblem(_ reason: PairUri.Failure) {
        view.endEditing(true)
        screen = .status
        let key: String
        switch reason {
        case .expired: key = "pair.invite_expired"
        case .missingPin: key = "pair.invite_missing_pin"
        case .missingHost: key = "pair.invite_missing_host"
        case .notAPairUri: key = "pair.invite_invalid"
        }
        errorLabel.text = texts.t(key)
        errorLabel.isHidden = false
        detailLabel.isHidden = true
        refresh(snapshot)
    }

    private func offer(_ invitation: PairUri) {
        // Joining from a device that is already in a cluster is a destructive move: it leaves the
        // cluster and wipes this device's settings. That is worth one deliberate confirmation.
        guard !snapshot.paired else {
            let alert = UIAlertController(title: texts.t("pair.invite_title"),
                                          message: texts.t("pair.invite_leave_current"),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: texts.t("pair.invite_join"),
                                          style: .destructive) { [weak self] _ in
                NotificationCenter.default.post(name: .doorbellResetLocalPairing, object: nil)
                self?.fill(invitation)
            })
            present(alert, animated: true)
            return
        }
        fill(invitation)
    }

    /// Prefills the join form and leaves one button to press.
    private func fill(_ invitation: PairUri) {
        clearError()
        pendingInvitation = invitation
        hostField.text = invitation.host
        pinField.text = invitation.pin
        screen = .codeEntry
        submitButton.setTitle(texts.t("pair.invite_join"), for: .normal)
        if !invitation.cluster.isEmpty {
            detailLabel.text = texts.t("pair.invite_cluster", invitation.cluster)
            detailLabel.isHidden = false
        }
        refresh(snapshot)
    }

    @objc private func showCodeEntry() {
        pendingInvitation = nil
        submitButton.setTitle(texts.t("pair.join_with_code"), for: .normal)
        clearError()
        screen = .codeEntry
        refresh(snapshot)
#if os(iOS)
        hostField.becomeFirstResponder()
#endif
    }

    @objc private func showStatus() {
        view.endEditing(true)
        clearError()
        screen = .status
        refresh(snapshot)
    }

    @objc private func submitJoin() {
        view.endEditing(true)
        let host = (hostField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pin = (pinField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, pin.count == 6, pin.allSatisfy({ $0.isNumber }) else {
            errorLabel.text = texts.t("setup.join_required")
            errorLabel.isHidden = false
            detailLabel.isHidden = true
            return
        }
        if let invitation = pendingInvitation, invitation.expiresAtS > 0,
           Int64(Date().timeIntervalSince1970) >= invitation.expiresAtS {
            // It was valid when it arrived and is not any more; a stale PIN would only burn one
            // of the token's few attempts.
            showInvitationProblem(.expired)
            return
        }
        clearError()
        joinInFlight = true
        refresh(snapshot)
        core.joinCluster(host: host, pin: pin)
    }

    @objc private func createCluster() {
        let alert = UIAlertController(title: texts.t("pair.create_home"),
                                      message: texts.t("pair.create_home_confirm"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: texts.t("pair.create_home"), style: .default) {
            [weak self] _ in
            guard let self = self else { return }
            self.clearError()
            self.createConfirmed = true
            guard self.core.createCluster() else {
                self.createConfirmed = false
                self.errorLabel.text = self.texts.t("setup.new_cluster_failed")
                self.errorLabel.isHidden = false
                return
            }
            self.refresh(PairingSnapshot.load(self.core))
        })
        present(alert, animated: true)
    }

    /// After creating a cluster the code card must already be live, so the user can add the next
    /// device without hunting for a menu. The screen never auto-dismisses here.
    /// After 「この端末で新規作成」 the founder shows the PIN card and its own QR, and nothing is
    /// added automatically: minting a PIN is separate from opening the bulk-add window.
    private func startCodeCard() {
        guard core.supportsMintJoinToken else {
            errorLabel.text = texts.t("pair.pin_unavailable")
            errorLabel.isHidden = false
            return
        }
        _ = core.mintJoinToken(seconds: 600)
        refresh(PairingSnapshot.load(core))
    }

    @objc private func retryPersistence() {
        clearError()
        core.retryPairingPersistence()
        refresh(PairingSnapshot.load(core))
    }

    @objc private func deferSetup() {
        view.endEditing(true)
        onDefer?()
    }

    /// Called by the host when the cluster was created through this screen so the code card is
    /// primed before the user is asked to add the next device.
    func enterCreatedState() {
        createConfirmed = true
        screen = .created
        startCodeCard()
    }


#if os(iOS)
    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                            as? NSValue)?.cgRectValue else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: nil).minY)
        keyboardInset?.constant = -overlap
        view.layoutIfNeeded()
        // Keep the field the user is typing into above the keyboard.
        scroll.scrollRectToVisible(codeEntryCard.frame, animated: true)
    }

    @objc private func keyboardWillHide() {
        keyboardInset?.constant = 0
        view.layoutIfNeeded()
    }
#endif
}

extension PairingViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === hostField {
            pinField.becomeFirstResponder()
        } else {
            submitJoin()
        }
        return true
    }
}

#if os(tvOS)
/// Focusable numeric keypad for remote-only devices. Mirrors the admin-password grid so the two
/// entry surfaces behave identically.
final class PairingKeypadView: UIView {
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?

    private let display = UILabel()
    private var value = "" {
        didSet {
            display.text = value.isEmpty ? "······" : value
            onChange?(value)
        }
    }

    init(texts: Texts) {
        super.init(frame: .zero)
        display.font = UIFont.monospacedDigitSystemFont(ofSize: PairingTheme.codeSize,
                                                        weight: .bold)
        display.textColor = PairingTheme.accent
        display.textAlignment = .center
        display.text = "······"

        let stack = UIStackView(arrangedSubviews: [display])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["back", "0", "ok"]] {
            let line = UIStackView()
            line.axis = .horizontal
            line.spacing = 10
            line.distribution = .fillEqually
            for key in row {
                let title = key == "back" ? "⌫" : (key == "ok" ? texts.t("pair.add") : key)
                let button = PairingTheme.button(title, filled: key == "ok")
                button.accessibilityIdentifier = "pair_key_\(key)"
                button.addTarget(self, action: #selector(keyTapped(_:)),
                                 for: .primaryActionTriggered)
                line.addArrangedSubview(button)
            }
            stack.addArrangedSubview(line)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func keyTapped(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier?
                .replacingOccurrences(of: "pair_key_", with: "") else { return }
        switch id {
        case "back":
            if !value.isEmpty { value.removeLast() }
        case "ok":
            onSubmit?()
        default:
            if value.count < 6 { value += id }
        }
    }
}
#endif
