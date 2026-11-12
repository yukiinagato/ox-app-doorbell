// Onboarding screen for a device that is not a cluster member yet (spec §5.0).
//
// It replaces the main UI whenever `pairing.state` is unpaired, joining or persist_error, and it
// renders every pairing event Core publishes: join_result, pairing_state, paired,
// pairing_persistence_error, join_token_changed. Nothing here decides the state on its own.
//
// The same controller serves iOS and tvOS: one grouped table under the stock navigation bar.
// tvOS never offers a camera path and enters the address and the Pairing PIN through the system
// text alert; its actions are table rows, because a row is what the remote focuses.
import UIKit

final class PairingViewController: PairingTableScreen {

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
        case created       // cluster created: keep the PIN section on screen
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
    private var errorText: String?
    private var errorDetail = ""

    private let headerView = UIView()
    private let titleLabel = SystemStyle.label(.title1, weight: .bold)
    private let identityLabel = SystemStyle.label(.footnote, color: SystemStyle.secondaryLabel)
    private let spinner = PairingCells.spinner()

    /// This device's eight-digit confirmation code, read out to whoever adds it.
    private let confirmLabel = UILabel()
    private lazy var confirmRow = PairingCells.custom(confirmLabel, vertical: 16)
    private let statusRow = PairingCells.text(identifier: "pair_status")
    private let errorRow = PairingCells.text(style: .subtitle, tone: .negative,
                                             identifier: "pair_error")
    private let inviteRow = PairingCells.text(tone: .secondary)
    private lazy var qrRow = PairingQrRow(core: core, texts: texts)
    private lazy var codeRows = PairingCodeRows(texts: texts, core: core)

    private lazy var hostRow = PairingFieldRow(label: texts.t("pair.address_label"),
                                               placeholder: texts.t("pair.address_example"),
                                               identifier: "pair_host_field")
    private lazy var pinRow = PairingFieldRow(label: texts.t("pair.code_label"),
                                              placeholder: "",
                                              identifier: "pair_pin_field")

    private lazy var joinRow = PairingCells.action(
        title: texts.t("pair.join_with_code"), identifier: "pair_join_with_code") {
        [weak self] in self?.showCodeEntry()
    }
    /// The one action of the "pair again after the upgrade" warning.
    private lazy var rejoinRow = PairingCells.button(
        title: texts.t("pair.upgrade_rejoin_action"), identifier: "pair_join_with_code") {
        [weak self] in self?.showCodeEntry()
    }
    private lazy var createRow = PairingCells.action(
        title: texts.t("pair.create_home"), identifier: "pair_create_home") {
        [weak self] in self?.createCluster()
    }
    private lazy var retryRow = PairingCells.button(
        title: texts.t("pair.retry"), identifier: "pair_retry") {
        [weak self] in self?.retryPersistence()
    }
    private lazy var submitRow = PairingCells.button(
        title: texts.t("pair.join_with_code"), identifier: "pair_join_submit") {
        [weak self] in self?.submitJoin()
    }

#if os(iOS)
    private lazy var laterItem = barButton(texts.t("pair.later"), #selector(deferSetup),
                                           "pair_later", style: .plain)
    private lazy var doneItem = barButton(texts.t("editor.done"), #selector(deferSetup),
                                          "pair_later", style: .done)
    private lazy var backItem = barButton(texts.t("panel.back"), #selector(showStatus),
                                          "pair_back", style: .plain)
#else
    private lazy var laterRow = PairingCells.action(
        title: texts.t("pair.later"), identifier: "pair_later") {
        [weak self] in self?.deferSetup()
    }
    private lazy var doneRow = PairingCells.action(
        title: texts.t("editor.done"), identifier: "pair_later") {
        [weak self] in self?.deferSetup()
    }
    private lazy var backRow = PairingCells.action(
        title: texts.t("panel.back"), identifier: "pair_back") {
        [weak self] in self?.showStatus()
    }
#endif

    override var prefersLargeTitle: Bool { return false }

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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
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
        titleLabel.text = texts.t("pair.title_unpaired")
        titleLabel.textAlignment = .center
        titleLabel.accessibilityIdentifier = "pair_title"
        titleLabel.accessibilityTraits = .header
        identityLabel.textAlignment = .center
        let heading = UIStackView(arrangedSubviews: [titleLabel, identityLabel])
        heading.axis = .vertical
        heading.spacing = 6
        heading.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(heading)
        headerView.layoutMargins = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        let margins = headerView.layoutMarginsGuide
        let bottom = heading.bottomAnchor.constraint(equalTo: headerView.bottomAnchor,
                                                     constant: -8)
        bottom.priority = UILayoutPriority(999)
        let trailing = heading.trailingAnchor.constraint(equalTo: margins.trailingAnchor)
        trailing.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 16),
            heading.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            trailing,
            bottom,
        ])
        setHeader(headerView)

        confirmLabel.font = SystemStyle.digits(size: PairingTheme.codeSize, weight: .semibold)
        confirmLabel.textAlignment = .center
        confirmLabel.adjustsFontSizeToFitWidth = true
        confirmLabel.minimumScaleFactor = 0.5
        confirmLabel.accessibilityIdentifier = "pair_confirm_code"
        confirmRow.decorate = { [unowned self] in
            self.confirmLabel.textColor = SystemStyle.label
        }
        confirmRow.paint()

#if os(iOS)
        hostRow.onReturn = { [weak self] in self?.pinRow.focus() }
        pinRow.onReturn = { [weak self] in self?.submitJoin() }
        hostRow.field.keyboardType = .numbersAndPunctuation
        hostRow.field.returnKeyType = .next
        pinRow.field.keyboardType = .numberPad
#else
        hostRow.keyboardType = .numbersAndPunctuation
        pinRow.keyboardType = .numberPad
        for field in [hostRow, pinRow] {
            field.presenter = self
            field.confirmTitle = texts.t("editor.ok")
            field.cancelTitle = texts.t("admin.cancel")
        }
#endif
        codeRows.onNewCode = { [weak self] in self?.startCodeCard() }
        codeRows.onChange = { [weak self] in self?.render() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(onInvitation(_:)),
            name: .doorbellPairInvitation, object: nil)
    }

#if os(iOS)
    private func barButton(_ title: String, _ action: Selector, _ identifier: String,
                           style: UIBarButtonItem.Style) -> UIBarButtonItem {
        let item = UIBarButtonItem(title: title, style: style, target: self, action: action)
        item.accessibilityIdentifier = identifier
        return item
    }
#endif

    override func styleDidChange() {
        titleLabel.textColor = SystemStyle.label
        identityLabel.textColor = SystemStyle.secondaryLabel
    }

    /// Takes one authoritative snapshot and renders it. Every visible element is derived from it.
    private func refresh(_ next: PairingSnapshot) {
        guard next.hasSnapshot || snapshot.hasSnapshot else { return }
        if next.hasSnapshot { snapshot = next }

        if snapshot.state == .persistError { screen = .persistError }
        if screen == .persistError && snapshot.state != .persistError { screen = .status }
        // A successful code join must leave the entry form and show the confirmation, never
        // dismiss silently from behind the keyboard.
        if snapshot.state == .ready && screen == .codeEntry { screen = .status }

        render()
        if snapshot.state == .ready && screen != .created { finish() }
    }

    private enum Trailing {
        case none
        case later
        case done
    }

    private func render() {
        qrRow.update(payload: snapshot.pairQr)
        codeRows.update(snapshot)
        confirmLabel.text = PairingCopy.groupedCode(snapshot.confirmCode)
        confirmRow.note = snapshot.confirmCode
        errorRow.cell.textLabel?.text = errorText
        errorRow.cell.detailTextLabel?.text = errorDetail
        let errors = errorText == nil ? [] : [errorRow]

        var title = texts.t("pair.title_unpaired")
        var sections: [PairingSection] = []
        var trailing = Trailing.none
        var back = false
        let qrSection = PairingSection(footer: texts.t("pair.qr_caption"), rows: [qrRow.row])

        switch screen {
        case .persistError:
            title = texts.t("pair.persist_error_title")
            setStatus(texts.t("pair.persist_error_body"), notice: .negative)
            sections.append(PairingSection(rows: [statusRow] + errors))
            sections.append(PairingSection(rows: [retryRow]))
        case .codeEntry:
            title = texts.t("pair.join_with_code")
            back = true
            if let cluster = pendingInvitation?.cluster, !cluster.isEmpty {
                inviteRow.cell.textLabel?.text = texts.t("pair.invite_cluster", cluster)
                sections.append(PairingSection(rows: [inviteRow]))
            }
            sections.append(PairingSection(footer: texts.t("pair.code_instructions"),
                                           rows: [hostRow.row, pinRow.row]))
            setStatus(texts.t("pair.joining"), busy: true)
            let progress = (joinInFlight ? [statusRow] : []) + errors
            if !progress.isEmpty { sections.append(PairingSection(rows: progress)) }
            submitRow.isEnabled = !joinInFlight
            sections.append(PairingSection(rows: [submitRow]))
        case .created:
            title = texts.t("pair.created")
            trailing = .done
            setStatus(texts.t("pair.created_next"))
            sections.append(PairingSection(
                footer: texts.t("pair.membership", "\(max(1, snapshot.memberCount))"),
                rows: [statusRow] + errors))
            sections += codeRows.sections()
        case .status:
            switch snapshot.state {
            case .joining:
                setStatus(texts.t("pair.joining"), busy: true)
                sections.append(PairingSection(rows: [statusRow] + errors))
                sections.append(qrSection)
            case .ready:
                setStatus(texts.t("pair.joined"), tone: .positive, done: true)
                sections.append(PairingSection(rows: [statusRow] + errors))
            case .revoked:
                setStatus(texts.t("pair.revoked"))
                sections.append(PairingSection(rows: [statusRow] + errors))
                sections.append(qrSection)
            default:
                trailing = .later
                let confirm = snapshot.state == .unpaired && !snapshot.confirmCode.isEmpty
                    ? [PairingSection(footer: texts.t("pair.confirm_code_caption"),
                                      rows: [confirmRow])] : []
                if snapshot.upgradeRejoinRequired {
                    // Paired under protocol v2: the old key no longer opens the cluster, but the
                    // local history is kept. Joining again is the only way back, so the warning
                    // leads and carries the one action.
                    title = texts.t("pair.upgrade_title")
                    setStatus(texts.t("pair.upgrade_body"), notice: .warning)
                    sections.append(PairingSection(footer: texts.t("pair.searching_hint"),
                                                   rows: [statusRow] + errors))
                    sections.append(PairingSection(rows: [rejoinRow]))
                    sections += confirm
                    sections.append(qrSection)
                    sections.append(PairingSection(rows: [createRow]))
                } else {
                    setStatus(texts.t("pair.searching"), busy: true)
                    sections += confirm
                    sections.append(PairingSection(footer: texts.t("pair.searching_hint"),
                                                   rows: [statusRow] + errors))
                    sections.append(qrSection)
                    sections.append(PairingSection(rows: [joinRow, createRow]))
                }
            }
        }

#if os(iOS)
        let right: UIBarButtonItem?
        switch trailing {
        case .none: right = nil
        case .later: right = laterItem
        case .done: right = doneItem
        }
        if barItem.rightBarButtonItem !== right { barItem.rightBarButtonItem = right }
        let left = back ? backItem : nil
        if barItem.leftBarButtonItem !== left { barItem.leftBarButtonItem = left }
#else
        switch trailing {
        case .none: break
        case .later: sections.append(PairingSection(rows: [laterRow]))
        case .done: sections.append(PairingSection(rows: [doneRow]))
        }
        if back { sections.append(PairingSection(rows: [backRow])) }
#endif

        let identity = snapshot.identityLine()
        if titleLabel.text != title || identityLabel.text != identity {
            titleLabel.text = title
            identityLabel.text = identity
            identityLabel.isHidden = identity.isEmpty
            headerChanged()
        }
        setSections(sections)
    }

    /// The status row: progress, a finished state, or the leading notice of a warning state.
    private func setStatus(_ text: String, busy: Bool = false, tone: PairingTone = .primary,
                           done: Bool = false, notice: PairingTone? = nil) {
        let cell = statusRow.cell
        cell.textLabel?.text = text
        if statusRow.tone != tone { statusRow.tone = tone }
        PairingCells.setBusy(busy, statusRow, spinner: spinner)
        let accessory: UITableViewCell.AccessoryType = done ? .checkmark : .none
        if cell.accessoryType != accessory { cell.accessoryType = accessory }
        let icon = notice == nil ? nil : TablerIcon.image("TablerAlertTriangle")
        if (cell.imageView?.image == nil) != (icon == nil) { cell.imageView?.image = icon }
        cell.imageView?.tintColor = notice?.color
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
        errorText = PairingCopy.error(texts, code)
        errorDetail = PairingCopy.errorDetail(texts, code)
    }

    private func showError(text: String) {
        errorText = text
        errorDetail = ""
    }

    private func clearError() {
        errorText = nil
        errorDetail = ""
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
        showError(text: texts.t(key))
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
        hostRow.text = invitation.host
        pinRow.text = invitation.pin
        screen = .codeEntry
        submitRow.setTitle(texts.t("pair.invite_join"))
        refresh(snapshot)
    }

    private func showCodeEntry() {
        pendingInvitation = nil
        submitRow.setTitle(texts.t("pair.join_with_code"))
        clearError()
        screen = .codeEntry
        refresh(snapshot)
        table.layoutIfNeeded()
        hostRow.focus()
    }

    @objc private func showStatus() {
        view.endEditing(true)
        clearError()
        screen = .status
        refresh(snapshot)
    }

    private func submitJoin() {
        view.endEditing(true)
        let host = hostRow.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pin = pinRow.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, pin.count == 6, pin.allSatisfy({ $0.isNumber }) else {
            showError(text: texts.t("setup.join_required"))
            render()
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

    private func createCluster() {
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
                self.showError(text: self.texts.t("setup.new_cluster_failed"))
                self.render()
                return
            }
            self.refresh(PairingSnapshot.load(self.core))
        })
        present(alert, animated: true)
    }

    /// After creating a cluster the PIN section must already be live, so the user can add the
    /// next device without hunting for a menu. The screen never auto-dismisses here, and nothing
    /// is added automatically: minting a PIN is separate from opening the bulk-add window.
    private func startCodeCard() {
        guard core.supportsMintJoinToken else {
            showError(text: texts.t("pair.pin_unavailable"))
            render()
            return
        }
        _ = core.mintJoinToken(seconds: 600)
        refresh(PairingSnapshot.load(core))
    }

    private func retryPersistence() {
        clearError()
        core.retryPairingPersistence()
        refresh(PairingSnapshot.load(core))
    }

    @objc private func deferSetup() {
        view.endEditing(true)
        onDefer?()
    }

    /// Called by the host when the cluster was created through this screen so the PIN section is
    /// primed before the user is asked to add the next device.
    func enterCreatedState() {
        createConfirmed = true
        screen = .created
        startCodeCard()
    }
}
