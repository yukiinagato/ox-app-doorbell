// "Add device" panel for a device that is already a cluster member (spec §5.1).
//
// Replaces the old alert chain. Everything on screen comes from one authoritative
// `db_core_pairing_json` snapshot plus the pairing events; the panel never infers an outcome.
// Reached from the visible membership status behind the admin password, and still from the
// hidden diagnostics screen.
import UIKit

final class AddDeviceViewController: UIViewController {

    private enum RowStatus {
        case idle
        case adding
        case added
        case failed
    }

    private struct RowState {
        var status: RowStatus
        var error: String
        var since: Date
    }

    private let core: CoreBridge
    private let boot: BootConfig
    private let texts: Texts

    private var snapshot = PairingSnapshot(nil)
    private var states: [String: RowState] = [:]
    /// Devices Core no longer lists as pending but that the user must still see: a QR-invited
    /// device before it announces, and a joined device while its "Added ✓" is on screen.
    private var extraDevices: [String: PairingDevice] = [:]
    private var rowViews: [String: PairingDeviceRowView] = [:]
    private var pollTimer: Timer?

    private let scroll = UIScrollView()
    private let contentStack = UIStackView()
    private let membershipLabel = UILabel()
    private let connectedLabel = UILabel()
    private let founderBadge = UILabel()
    private let nearbyTitle = UILabel()
    private let nearbyStack = UIStackView()
    private let nearbyEmpty = UILabel()
    private let nearbySpinner = IOSAvailability.activityIndicator(large: false)
    private lazy var codeButton = PairingTheme.button(texts.t("pair.add_with_code"), filled: true)
    private lazy var codeCard = PairingCodeCardView(texts: texts, core: core)
    private lazy var addAllButton = PairingTheme.button(texts.t("pair.add_all"))
    private let addAllWarning = UILabel()
    private let addAllStatus = UILabel()
    private let codeUnavailable = UILabel()
    private lazy var addAllStop = PairingTheme.button(texts.t("pair.add_all_stop"))
    private lazy var scanButton = PairingTheme.button(texts.t("pair.scan_qr"))
    private let scanUnavailable = UILabel()
    private lazy var qrCard = PairingQrCardView(core: core, texts: texts)
    private lazy var unpairButton = PairingTheme.button(texts.t("pair.clear_title"))
    private lazy var closeButton = PairingTheme.button(texts.t("monitor.close"))
    private let unpairedNotice = UILabel()
    private lazy var createButton = PairingTheme.button(texts.t("pair.create_home"), filled: true)

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
        core.removeHandler("add_device")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PairingTheme.background
        buildUi()
        core.addHandler("add_device") { [weak self] ev in self?.onUiEvent(ev) }
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pollTimer?.invalidate()
        pollTimer = IOSAvailability.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in self?.refresh()
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
        contentStack.spacing = 14
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(contentStack)

        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 22),
            contentStack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -22),
            contentStack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
        ])
        let column = contentStack.widthAnchor.constraint(equalTo: scroll.widthAnchor,
                                                         constant: -48)
        column.priority = UILayoutPriority(999)
        column.isActive = true
        contentStack.widthAnchor.constraint(
            lessThanOrEqualToConstant: PairingTheme.qrSize * 2.6).isActive = true

        let title = PairingTheme.label(PairingTheme.titleSize, PairingTheme.foreground, bold: true)
        title.text = texts.t("pair.panel_title")
        title.accessibilityIdentifier = "add_device_title"

        membershipLabel.font = .systemFont(ofSize: PairingTheme.bodySize, weight: .semibold)
        membershipLabel.textColor = PairingTheme.foreground
        membershipLabel.accessibilityIdentifier = "add_device_membership"
        connectedLabel.font = .systemFont(ofSize: PairingTheme.smallSize)
        connectedLabel.textColor = PairingTheme.dim
        founderBadge.text = texts.t("pair.created_badge")
        founderBadge.font = .systemFont(ofSize: PairingTheme.smallSize)
        founderBadge.textColor = PairingTheme.accent
        founderBadge.isHidden = true

        nearbyTitle.text = texts.t("pair.nearby_title")
        nearbyTitle.font = .boldSystemFont(ofSize: PairingTheme.bodySize)
        nearbyTitle.textColor = PairingTheme.foreground
        nearbyStack.axis = .vertical
        nearbyStack.spacing = 10
        nearbyStack.alignment = .fill
        nearbyEmpty.text = texts.t("pair.nearby_none")
        nearbyEmpty.font = .systemFont(ofSize: PairingTheme.smallSize)
        nearbyEmpty.textColor = PairingTheme.dim
        nearbyEmpty.numberOfLines = 0
        nearbySpinner.color = PairingTheme.dim
        nearbySpinner.startAnimating()
        let emptyRow = UIStackView(arrangedSubviews: [nearbySpinner, nearbyEmpty])
        emptyRow.axis = .horizontal
        emptyRow.spacing = 10
        emptyRow.alignment = .center

        codeButton.addTarget(self, action: #selector(startCode), for: .primaryActionTriggered)
        codeButton.accessibilityIdentifier = "add_device_code"
        codeCard.onNewCode = { [weak self] in self?.startCode() }
        codeCard.isHidden = true
        codeUnavailable.font = .systemFont(ofSize: PairingTheme.smallSize, weight: .semibold)
        codeUnavailable.textColor = PairingTheme.danger
        codeUnavailable.numberOfLines = 0
        codeUnavailable.accessibilityIdentifier = "add_device_code_unavailable"
        codeUnavailable.isHidden = true

        addAllWarning.text = texts.t("pair.add_all_warning")
        addAllWarning.font = .systemFont(ofSize: PairingTheme.smallSize)
        addAllWarning.textColor = PairingTheme.dim
        addAllWarning.numberOfLines = 0
        addAllStatus.font = .systemFont(ofSize: PairingTheme.bodySize, weight: .semibold)
        addAllStatus.textColor = PairingTheme.accent
        addAllStatus.numberOfLines = 0
        addAllStatus.isHidden = true
        addAllButton.addTarget(self, action: #selector(startAddAll), for: .primaryActionTriggered)
        addAllButton.accessibilityIdentifier = "add_device_add_all"
        addAllStop.addTarget(self, action: #selector(stopAddAll), for: .primaryActionTriggered)
        addAllStop.accessibilityIdentifier = "add_device_add_all_stop"
        addAllStop.isHidden = true

        scanButton.addTarget(self, action: #selector(openScanner), for: .primaryActionTriggered)
        scanButton.accessibilityIdentifier = "add_device_scan"
        scanUnavailable.font = .systemFont(ofSize: PairingTheme.smallSize)
        scanUnavailable.textColor = PairingTheme.dim
        scanUnavailable.numberOfLines = 0
        scanUnavailable.isHidden = true
        configureScanAvailability()

        unpairButton.setTitleColor(PairingTheme.danger, for: .normal)
        unpairButton.addTarget(self, action: #selector(confirmUnpair),
                               for: .primaryActionTriggered)
        unpairButton.accessibilityIdentifier = "add_device_unpair"
        closeButton.addTarget(self, action: #selector(close), for: .primaryActionTriggered)
        closeButton.accessibilityIdentifier = "add_device_close"

        unpairedNotice.text = texts.t("admin.pair_self_unpaired")
        unpairedNotice.font = .systemFont(ofSize: PairingTheme.bodySize)
        unpairedNotice.textColor = PairingTheme.danger
        unpairedNotice.numberOfLines = 0
        unpairedNotice.isHidden = true
        createButton.addTarget(self, action: #selector(createCluster),
                               for: .primaryActionTriggered)
        createButton.isHidden = true

        let members = UIStackView(arrangedSubviews: [membershipLabel, connectedLabel,
                                                     founderBadge])
        members.axis = .vertical
        members.spacing = 4
        members.alignment = .leading

        for element in [title, members, unpairedNotice, createButton, nearbyTitle, nearbyStack,
                        emptyRow, codeButton, codeUnavailable, codeCard, addAllButton,
                        addAllWarning,
                        addAllStatus, addAllStop, scanButton, scanUnavailable, qrCard,
                        unpairButton, closeButton] as [UIView] {
            contentStack.addArrangedSubview(element)
        }
        IOSAvailability.setCustomSpacing(24, after: members, in: contentStack)
        IOSAvailability.setCustomSpacing(24, after: emptyRow, in: contentStack)
        IOSAvailability.setCustomSpacing(24, after: codeCard, in: contentStack)
        IOSAvailability.setCustomSpacing(24, after: qrCard, in: contentStack)
    }

    private func configureScanAvailability() {
#if os(iOS)
        if IOSAvailability.qrScanCaptureDevice() == nil {
            scanButton.isHidden = true
            scanUnavailable.text = texts.t("pair.scan_no_camera")
            scanUnavailable.isHidden = false
        }
#else
        // Apple TV has no camera: display-only, as decided in the spec.
        scanButton.isHidden = true
        scanUnavailable.text = texts.t("pair.scan_no_camera")
        scanUnavailable.isHidden = false
#endif
    }


    private func refresh() {
        let next = PairingSnapshot.load(core)
        if next.hasSnapshot { snapshot = next }

        let members = max(snapshot.memberCount, snapshot.paired ? 1 : 0)
        membershipLabel.text = texts.t("pair.membership", "\(members)")
        connectedLabel.text = texts.t("pair.membership_connected", "\(snapshot.connectedCount)")
        founderBadge.isHidden = !snapshot.isFounder
        qrCard.update(payload: snapshot.pairQr)

        // An unpaired node cannot add anything; it may only create a cluster or join one.
        let usable = snapshot.state == .ready
        unpairedNotice.isHidden = usable
        createButton.isHidden = usable
        nearbyTitle.isHidden = !usable
        nearbyStack.isHidden = !usable
        codeButton.isHidden = !usable || snapshot.tokenActive
        codeCard.isHidden = !usable || !snapshot.tokenActive
        addAllButton.isHidden = !usable || snapshot.pairingMode
        addAllWarning.isHidden = !usable || snapshot.pairingMode
        addAllStatus.isHidden = !usable || !snapshot.pairingMode
        addAllStop.isHidden = !usable || !snapshot.pairingMode
        scanButton.isHidden = !usable || !scanAvailable
        unpairButton.isHidden = !snapshot.paired

        codeCard.update(snapshot)
        addAllStatus.text = PairingCopy.addAllOn(texts, leftS: snapshot.pairingModeLeftS,
                                                 added: snapshot.autoAddedCount)
        refreshRows(usable: usable)
    }

    private var scanAvailable: Bool {
#if os(iOS)
        return IOSAvailability.qrScanCaptureDevice() != nil
#else
        return false
#endif
    }

    private func refreshRows(usable: Bool) {
        var devices: [String: PairingDevice] = [:]
        for device in snapshot.devices where !device.id.isEmpty { devices[device.id] = device }
        let now = Date()
        for (id, device) in extraDevices {
            let state = states[id]
            let age = now.timeIntervalSince(state?.since ?? now)
            // A confirmed row stays readable for a moment after Core drops it from pending.
            if state?.status == .added && age > 4 {
                extraDevices.removeValue(forKey: id)
                states.removeValue(forKey: id)
                continue
            }
            if devices[id] == nil { devices[id] = device }
        }

        let ordered = devices.values.sorted { lhs, rhs in
            lhs.ageS != rhs.ageS ? lhs.ageS < rhs.ageS : lhs.id < rhs.id
        }
        let visibleIds = Set(ordered.map { $0.id })
        for (id, row) in rowViews where !visibleIds.contains(id) {
            nearbyStack.removeArrangedSubview(row)
            row.removeFromSuperview()
            rowViews.removeValue(forKey: id)
        }
        for (index, device) in ordered.enumerated() {
            let row: PairingDeviceRowView
            if let existing = rowViews[device.id] {
                row = existing
                if nearbyStack.arrangedSubviews.firstIndex(of: row) != index {
                    nearbyStack.removeArrangedSubview(row)
                    nearbyStack.insertArrangedSubview(row, at: min(index,
                                                                   nearbyStack.arrangedSubviews.count))
                }
            } else {
                row = PairingDeviceRowView(texts: texts)
                row.onAdd = { [weak self] id in self?.add(id) }
                row.onDeny = { [weak self] id in self?.confirmDeny(id) }
                rowViews[device.id] = row
                nearbyStack.insertArrangedSubview(row, at: min(index,
                                                               nearbyStack.arrangedSubviews.count))
            }
            let state = states[device.id] ?? RowState(status: .idle, error: "", since: now)
            row.update(device: device, status: statusText(device: device, state: state),
                       busy: state.status == .adding,
                       canAct: state.status == .idle || state.status == .failed)
        }
        nearbyEmpty.isHidden = !ordered.isEmpty || !usable
        nearbySpinner.isHidden = nearbyEmpty.isHidden
    }

    private func statusText(device: PairingDevice,
                            state: RowState) -> (text: String, color: UIColor) {
        switch state.status {
        case .adding:
            return (texts.t("pair.adding"), PairingTheme.accent)
        case .added:
            return (texts.t("pair.added") + " ✓", PairingTheme.ok)
        case .failed:
            let message = texts.t("pair.add_failed") + " — " + PairingCopy.error(texts,
                                                                                 state.error)
            return (message, PairingTheme.danger)
        case .idle:
            if device.inviteState == "sent" || device.inviteState == "acked" {
                return (texts.t("pair.adding"), PairingTheme.accent)
            }
            return (texts.t("pair.nearby_waiting_since", "\(device.ageS)"), PairingTheme.dim)
        }
    }


    private func onUiEvent(_ ev: [String: Any]) {
        let kind = ConfigUtil.evStr(ev, "t")
        switch kind {
        case "invite_result":
            let id = ConfigUtil.evStr(ev, "id")
            guard !id.isEmpty else { break }
            if ConfigUtil.evBool(ev, "ok") {
                // An accepted invitation is not yet a member: keep "Adding…" until device_joined.
                states[id] = RowState(status: .adding, error: "", since: Date())
            } else {
                states[id] = RowState(status: .failed, error: ConfigUtil.evStr(ev, "err"),
                                      since: Date())
            }
            refresh()
        case "device_joined":
            let id = ConfigUtil.evStr(ev, "id")
            guard !id.isEmpty else { break }
            states[id] = RowState(status: .added, error: "", since: Date())
            if extraDevices[id] == nil {
                let known = snapshot.devices.first { $0.id == id }
                extraDevices[id] = known ?? PairingDevice([
                    "id": id, "name": ConfigUtil.evStr(ev, "name"),
                    "role": ConfigUtil.evStr(ev, "role"),
                ])
            }
            refresh()
        case "qr_scanned":
            refresh()
        case "pending_changed", "pairing_state", "pairing_mode_changed", "join_token_changed",
             "paired", "peers_changed":
            refresh()
        default:
            break
        }
    }


    private func add(_ id: String) {
        guard !id.isEmpty else { return }
        states[id] = RowState(status: .adding, error: "", since: Date())
        core.inviteDevice(id)
        refresh()
    }

    private func confirmDeny(_ id: String) {
        let alert = UIAlertController(title: texts.t("pair.deny"), message: nil,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: texts.t("pair.deny"), style: .destructive) {
            [weak self] _ in
            guard let self = self else { return }
            self.core.denyDevice(id)
            self.states.removeValue(forKey: id)
            self.extraDevices.removeValue(forKey: id)
            self.refresh()
        })
        present(alert, animated: true)
    }

    /// Minting a PIN never opens the bulk-add window: that is a separate control with its own
    /// warning. A Core without the dedicated entry point says so instead of silently starting to
    /// add every device it can see.
    @objc private func startCode() {
        guard core.supportsMintJoinToken else {
            codeUnavailable.text = texts.t("pair.pin_unavailable")
            codeUnavailable.isHidden = false
            return
        }
        _ = core.mintJoinToken(seconds: 600)
        refresh()
    }

    @objc private func startAddAll() {
        core.pairingMode(seconds: 600)
        refresh()
    }

    @objc private func stopAddAll() {
        core.pairingMode(seconds: 0)
        refresh()
    }

    @objc private func createCluster() {
        let alert = UIAlertController(title: texts.t("pair.create_home"),
                                      message: texts.t("pair.create_home_confirm"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: texts.t("pair.create_home"), style: .default) {
            [weak self] _ in
            _ = self?.core.createCluster()
            self?.refresh()
        })
        present(alert, animated: true)
    }

    @objc private func openScanner() {
#if os(iOS)
        let scanner = PairingScannerViewController(texts: texts) { [weak self] payload in
            self?.handleScan(payload)
        }
        present(scanner, animated: true)
#endif
    }

#if os(iOS)
    private func handleScan(_ payload: (addr: String, id: String, pk: String)) {
        states[payload.id] = RowState(status: .adding, error: "", since: Date())
        extraDevices[payload.id] = PairingDevice(["id": payload.id, "addr": payload.addr])
        core.inviteDirect(addr: payload.addr, id: payload.id, pk: payload.pk)
        refresh()
    }
#endif

    @objc private func confirmUnpair() {
        let first = UIAlertController(title: texts.t("pair.clear_title"),
                                      message: texts.t("pair.clear_confirm"),
                                      preferredStyle: .alert)
        first.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel))
        first.addAction(UIAlertAction(title: texts.t("pair.clear_title"),
                                      style: .destructive) { [weak self] _ in
            self?.confirmUnpairSecondStep()
        })
        present(first, animated: true)
    }

    private func confirmUnpairSecondStep() {
        let second = UIAlertController(title: texts.t("pair.clear_title"),
                                       message: texts.t("pair.clear_confirm") + "\n"
                                        + texts.t("pair.clear_resets_device"),
                                       preferredStyle: .alert)
        second.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel))
        second.addAction(UIAlertAction(title: texts.t("pair.clear_title"),
                                       style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            // Leaving the cluster resets this device completely — the stored key, the pairing
            // fields and its own name, role and door — and it comes back on the first-run screen.
            self.core.unpair()
            self.dismiss(animated: true) {
                NotificationCenter.default.post(name: .doorbellResetLocalPairing, object: nil)
            }
        })
        present(second, animated: true)
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

/// One nearby device: identity, waiting time, and the single "Add" verb with its result.
final class PairingDeviceRowView: UIView {
    var onAdd: ((String) -> Void)?
    var onDeny: ((String) -> Void)?

    private let texts: Texts
    private var deviceId = ""
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = IOSAvailability.activityIndicator(large: false)
    private lazy var addButton = PairingTheme.button(texts.t("pair.add"), filled: true)
    private lazy var denyButton = PairingTheme.button(texts.t("pair.deny"))

    init(texts: Texts) {
        self.texts = texts
        super.init(frame: .zero)
        backgroundColor = PairingTheme.card
        layer.cornerRadius = 12

        nameLabel.font = .boldSystemFont(ofSize: PairingTheme.bodySize)
        nameLabel.textColor = PairingTheme.foreground
        nameLabel.numberOfLines = 0
        detailLabel.font = .systemFont(ofSize: PairingTheme.smallSize)
        detailLabel.textColor = PairingTheme.dim
        detailLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: PairingTheme.smallSize, weight: .semibold)
        statusLabel.numberOfLines = 0
        spinner.color = PairingTheme.accent
        spinner.hidesWhenStopped = true

        addButton.addTarget(self, action: #selector(addTapped), for: .primaryActionTriggered)
        denyButton.addTarget(self, action: #selector(denyTapped), for: .primaryActionTriggered)

        let statusRow = UIStackView(arrangedSubviews: [spinner, statusLabel])
        statusRow.axis = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .center
        let info = UIStackView(arrangedSubviews: [nameLabel, detailLabel, statusRow])
        info.axis = .vertical
        info.spacing = 4
        info.alignment = .leading
        let buttons = UIStackView(arrangedSubviews: [addButton, denyButton])
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.alignment = .center
        let row = UIStackView(arrangedSubviews: [info, buttons])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func update(device: PairingDevice, status: (text: String, color: UIColor), busy: Bool,
                canAct: Bool) {
        deviceId = device.id
        nameLabel.text = device.displayName
        nameLabel.accessibilityIdentifier = "pair_row_\(device.id)"
        detailLabel.text = device.subtitle(texts)
        detailLabel.isHidden = (detailLabel.text ?? "").isEmpty
        statusLabel.text = status.text
        statusLabel.textColor = status.color
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        addButton.isEnabled = canAct
        denyButton.isEnabled = canAct
        addButton.accessibilityIdentifier = "pair_add_\(device.id)"
        denyButton.accessibilityIdentifier = "pair_deny_\(device.id)"
    }

    @objc private func addTapped() { onAdd?(deviceId) }
    @objc private func denyTapped() { onDeny?(deviceId) }
}
