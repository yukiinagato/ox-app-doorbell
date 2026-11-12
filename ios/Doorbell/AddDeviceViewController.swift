// "Add device" panel for a device that is already a cluster member (spec §5.1).
//
// Everything on screen comes from one authoritative `db_core_pairing_json` snapshot plus the
// pairing events; the panel never infers an outcome. It is one grouped table under the stock
// navigation bar: membership, nearby devices, the Pairing PIN, bulk add, the QR paths, and the
// destructive "clear pairing" action last.
// Reached from the visible membership status behind the admin password, and still from the
// hidden diagnostics screen.
import UIKit

final class AddDeviceViewController: PairingTableScreen {

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
    /// device before it announces, and a joined device while its "Added" is on screen.
    private var extraDevices: [String: PairingDevice] = [:]
    private var deviceRows: [String: PairingDeviceRow] = [:]
    private var orderedDevices: [PairingDevice] = []
    private var pollTimer: Timer?
    private var codeUnavailable = false
    /// Handshake rejections and key rotations, reported by Core events.
    private var peerNotice: String?

    private let membershipRow = PairingCells.text(style: .subtitle,
                                                  identifier: "add_device_membership")
    private let unpairedRow = PairingCells.text(tone: .negative)
    private let peerRow = PairingCells.text(tone: .negative,
                                            identifier: "add_device_peer_notice")
    /// Members that must be upgraded or re-keyed, from the snapshot's `security` section.
    private let securityRow = PairingCells.text(tone: .negative,
                                                identifier: "add_device_security_notice")
    private let nearbyEmptyRow = PairingCells.text(tone: .secondary)
    private let nearbySpinner = PairingCells.spinner()
    private let codeUnavailableRow = PairingCells.text(
        tone: .negative, identifier: "add_device_code_unavailable")
    private let addAllStatusRow = PairingCells.text()
    private let addAllSpinner = PairingCells.spinner()
    private let scanUnavailableRow = PairingCells.text(tone: .secondary)
    private lazy var codeRows = PairingCodeRows(texts: texts, core: core)
    private lazy var qrRow = PairingQrRow(core: core, texts: texts)

    private lazy var createRow = PairingCells.button(
        title: texts.t("pair.create_home"), identifier: "add_device_create") {
        [weak self] in self?.createCluster()
    }
    private lazy var codeRow = PairingCells.button(
        title: texts.t("pair.add_with_code"), identifier: "add_device_code") {
        [weak self] in self?.startCode()
    }
    private lazy var addAllRow = PairingCells.action(
        title: texts.t("pair.add_all"), identifier: "add_device_add_all") {
        [weak self] in self?.startAddAll()
    }
    private lazy var addAllStopRow = PairingCells.action(
        title: texts.t("pair.add_all_stop"), identifier: "add_device_add_all_stop") {
        [weak self] in self?.stopAddAll()
    }
    private lazy var scanRow: PairingRow = {
        let row = PairingCells.action(title: texts.t("pair.scan_qr"),
                                      identifier: "add_device_scan") {
            [weak self] in self?.openScanner()
        }
        row.cell.accessoryType = .disclosureIndicator
        return row
    }()
    private lazy var unpairRow = PairingCells.action(
        title: texts.t("pair.clear_title"), tone: .negative,
        identifier: "add_device_unpair") {
        [weak self] in self?.confirmUnpair()
    }
#if os(tvOS)
    private lazy var closeRow = PairingCells.action(
        title: texts.t("monitor.close"), identifier: "add_device_close") {
        [weak self] in self?.close()
    }
#endif

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
        if isBeingDismissed || presentingViewController == nil { core.adminLock() }
    }

    private func buildUi() {
        barItem.title = texts.t("pair.panel_title")
        bar?.navigationBar.accessibilityIdentifier = "add_device_title"
#if os(iOS)
        let done = UIBarButtonItem(title: texts.t("monitor.close"), style: .done, target: self,
                                   action: #selector(close))
        done.accessibilityIdentifier = "add_device_close"
        barItem.rightBarButtonItem = done
#endif
        unpairedRow.cell.textLabel?.text = texts.t("admin.pair_self_unpaired")
        nearbyEmptyRow.cell.textLabel?.text = texts.t("pair.nearby_none")
        codeUnavailableRow.cell.textLabel?.text = texts.t("pair.pin_unavailable")
        scanUnavailableRow.cell.textLabel?.text = texts.t("pair.scan_no_camera")
        codeRows.onNewCode = { [weak self] in self?.startCode() }
        codeRows.onChange = { [weak self] in self?.render() }
    }

    private var scanAvailable: Bool {
#if os(iOS)
        return IOSAvailability.qrScanCaptureDevice() != nil
#else
        // Apple TV has no camera: display-only, as decided in the spec.
        return false
#endif
    }

    private func refresh() {
        let next = PairingSnapshot.load(core)
        if next.hasSnapshot { snapshot = next }
        render()
    }

    private func render() {
        let members = max(snapshot.memberCount, snapshot.paired ? 1 : 0)
        membershipRow.cell.textLabel?.text = texts.t("pair.membership", "\(members)")
        membershipRow.cell.detailTextLabel?.text =
            texts.t("pair.membership_connected", "\(snapshot.connectedCount)")
        qrRow.update(payload: snapshot.pairQr)
        codeRows.update(snapshot)

        // An unpaired node cannot add anything; it may only create a cluster or join one.
        let usable = snapshot.state == .ready
        var sections: [PairingSection] = []

        var overview = [membershipRow]
        if !usable { overview.append(unpairedRow) }
        if let notice = peerNotice {
            peerRow.cell.textLabel?.text = notice
            overview.append(peerRow)
        }
        let stale = snapshot.security.legacyPeers.count + snapshot.security.rekeyRequired.count
        if usable && stale > 0 {
            securityRow.cell.textLabel?.text = texts.t("pair.members_need_rejoin", "\(stale)")
            overview.append(securityRow)
        }
        sections.append(PairingSection(
            footer: snapshot.isFounder ? texts.t("pair.created_badge") : nil, rows: overview))
        if !usable { sections.append(PairingSection(rows: [createRow])) }

        refreshDevices()
        if usable {
            var nearby = orderedDevices.compactMap { deviceRows[$0.id]?.row }
            if nearby.isEmpty {
                PairingCells.setBusy(true, nearbyEmptyRow, spinner: nearbySpinner)
                nearby = [nearbyEmptyRow]
            }
            sections.append(PairingSection(header: texts.t("pair.nearby_title"), rows: nearby))

            if snapshot.tokenActive {
                sections += codeRows.sections()
            } else {
                sections.append(PairingSection(rows: [codeRow]))
                if codeUnavailable {
                    sections.append(PairingSection(rows: [codeUnavailableRow]))
                }
            }

            if snapshot.pairingMode {
                addAllStatusRow.cell.textLabel?.text = PairingCopy.addAllOn(
                    texts, leftS: snapshot.pairingModeLeftS, added: snapshot.autoAddedCount)
                PairingCells.setBusy(true, addAllStatusRow, spinner: addAllSpinner)
                sections.append(PairingSection(rows: [addAllStatusRow, addAllStopRow]))
            } else {
                sections.append(PairingSection(footer: texts.t("pair.add_all_warning"),
                                               rows: [addAllRow]))
            }
            sections.append(PairingSection(rows: [scanAvailable ? scanRow : scanUnavailableRow]))
        }

        sections.append(PairingSection(footer: texts.t("pair.qr_caption"), rows: [qrRow.row]))
        if snapshot.paired { sections.append(PairingSection(rows: [unpairRow])) }
#if os(tvOS)
        sections.append(PairingSection(rows: [closeRow]))
#endif
        setSections(sections)
    }

    private func refreshDevices() {
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

        orderedDevices = devices.values.sorted { lhs, rhs in
            lhs.ageS != rhs.ageS ? lhs.ageS < rhs.ageS : lhs.id < rhs.id
        }
        let visibleIds = Set(orderedDevices.map { $0.id })
        for id in deviceRows.keys where !visibleIds.contains(id) {
            deviceRows.removeValue(forKey: id)
        }
        for device in orderedDevices {
            let entry: PairingDeviceRow
            if let existing = deviceRows[device.id] {
                entry = existing
            } else {
                entry = PairingDeviceRow(texts: texts)
                entry.onAdd = { [weak self] id in self?.add(id) }
                entry.onChoose = { [weak self] id in self?.chooseAction(id) }
                deviceRows[device.id] = entry
            }
            let state = states[device.id] ?? RowState(status: .idle, error: "", since: now)
            entry.update(device: device, status: statusText(device: device, state: state),
                         busy: state.status == .adding, added: state.status == .added,
                         canAct: !device.pkConflict &&
                             (state.status == .idle || state.status == .failed))
        }
    }

    private func statusText(device: PairingDevice,
                            state: RowState) -> (text: String, tone: PairingTone) {
        switch state.status {
        case .adding:
            return (texts.t("pair.adding"), .secondary)
        case .added:
            return (texts.t("pair.added"), .positive)
        case .failed:
            let message = texts.t("pair.add_failed") + " — " + PairingCopy.error(texts,
                                                                                 state.error)
            return (message, .negative)
        case .idle:
            if device.pkConflict {
                return (PairingCopy.error(texts, "pk_conflict"), .negative)
            }
            if device.inviteState == "sent" || device.inviteState == "acked" {
                return (texts.t("pair.adding"), .secondary)
            }
            return (texts.t("pair.nearby_waiting_since", "\(device.ageS)"), .secondary)
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
        case "peer_rejected":
            // A member that cannot complete the v3 handshake: shown, not silently dropped.
            let reason = ConfigUtil.evStr(ev, "reason")
            peerNotice = texts.t("pair.peer_rejected", PairingCopy.error(texts, reason))
            refresh()
        case "cluster_key_changed":
            peerNotice = texts.t("pair.cluster_key_changed")
            refresh()
        case "pending_changed", "pairing_state", "pairing_mode_changed", "join_token_changed",
             "paired", "peers_changed":
            refresh()
        default:
            break
        }
    }

    /// A nearby device offers its two verbs in one sheet: add it, or keep it out of the list.
    private func chooseAction(_ id: String) {
        guard let entry = deviceRows[id] else { return }
        let sheet = UIAlertController(title: entry.title, message: nil,
                                      preferredStyle: .actionSheet)
        let addAction = UIAlertAction(title: texts.t("pair.add"), style: .default) {
            [weak self] _ in self?.add(id)
        }
        addAction.accessibilityIdentifier = "pair_add_\(id)"
        let denyAction = UIAlertAction(title: texts.t("pair.deny"), style: .destructive) {
            [weak self] _ in self?.confirmDeny(id)
        }
        denyAction.accessibilityIdentifier = "pair_deny_\(id)"
        sheet.addAction(addAction)
        sheet.addAction(denyAction)
        sheet.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel))
        anchor(sheet, to: entry.row)
        present(sheet, animated: true)
    }

    /// A discovered device's key arrived in an unauthenticated beacon, so Core invites it only
    /// with the eight-digit code that device shows on its own screen.
    private func add(_ id: String) {
        guard !id.isEmpty else { return }
        let alert = UIAlertController(title: texts.t("pair.confirm_code_title"),
                                      message: texts.t("pair.confirm_code_prompt"),
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "1234 5678"
            #if os(iOS)
            field.keyboardType = .numberPad
            #endif
            field.accessibilityIdentifier = "pair_confirm_code"
        }
        alert.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: texts.t("pair.add"), style: .default) {
            [weak self, weak alert] _ in
            guard let self = self else { return }
            guard let code = PairingCopy.normalizedCode(alert?.textFields?.first?.text ?? "") else {
                self.states[id] = RowState(status: .failed, error: "confirm_code_mismatch",
                                           since: Date())
                self.refresh()
                return
            }
            self.states[id] = RowState(status: .adding, error: "", since: Date())
            self.core.inviteDevice(id, confirmCode: code)
            self.refresh()
        })
        present(alert, animated: true)
    }

    private func confirmDeny(_ id: String) {
        let alert = UIAlertController(title: texts.t("pair.deny"),
                                      message: texts.t("pair.deny_confirm"),
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
            // The row reads `pair.pin_unavailable`.
            codeUnavailable = true
            render()
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

    private func createCluster() {
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

    private func openScanner() {
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

    private func confirmUnpair() {
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

/// One nearby device as a subtitle row: identity, then its waiting time or the result of adding
/// it. Selecting the row offers "Add" and "Ignore"; iOS also carries "Add" as the row's accessory.
final class PairingDeviceRow {
    let row = PairingCells.text(style: .subtitle)
    var onAdd: ((String) -> Void)?
    var onChoose: ((String) -> Void)?
    private(set) var title = ""

    private let texts: Texts
    private var deviceId = ""
    private var detail = ""
    private var status: (text: String, tone: PairingTone) = ("", .secondary)
    private let spinner = PairingCells.spinner()
#if os(iOS)
    private lazy var addButton: UIButton = {
        let button = SystemStyle.button(.gray, title: texts.t("pair.add"))
        button.addTarget(self, action: #selector(addTapped), for: .primaryActionTriggered)
        button.sizeToFit()
        return button
    }()
#endif

    init(texts: Texts) {
        self.texts = texts
        row.tone = nil
        row.decorate = { [unowned self] in self.paint() }
        row.onSelect = { [unowned self] in self.onChoose?(self.deviceId) }
    }

    func update(device: PairingDevice, status: (text: String, tone: PairingTone), busy: Bool,
                added: Bool, canAct: Bool) {
        deviceId = device.id
        title = device.displayName
        detail = device.subtitle(texts)
        self.status = status
        let cell = row.cell
        cell.textLabel?.text = title
        cell.textLabel?.accessibilityIdentifier = "pair_row_\(device.id)"
        paint()

        row.isEnabled = canAct
        cell.selectionStyle = canAct ? .default : .none
        cell.accessoryType = added ? .checkmark : .none
        if busy {
            PairingCells.setBusy(true, row, spinner: spinner)
        } else {
            PairingCells.setBusy(false, row, spinner: spinner)
#if os(iOS)
            addButton.accessibilityIdentifier = "pair_add_\(device.id)"
            let accessory: UIView? = canAct ? addButton : nil
            if cell.accessoryView !== accessory { cell.accessoryView = accessory }
#endif
        }
    }

    private func paint() {
        let cell = row.cell
        cell.textLabel?.textColor = SystemStyle.label
        let font = cell.detailTextLabel?.font ?? SystemStyle.font(.footnote)
        let text = NSMutableAttributedString()
        if !detail.isEmpty {
            text.append(NSAttributedString(string: detail + "\n", attributes: [
                .foregroundColor: SystemStyle.secondaryLabel, .font: font,
            ]))
        }
        text.append(NSAttributedString(string: status.text, attributes: [
            .foregroundColor: status.tone.color, .font: font,
        ]))
        if cell.detailTextLabel?.attributedText?.isEqual(to: text) != true {
            cell.detailTextLabel?.attributedText = text
        }
    }

#if os(iOS)
    @objc private func addTapped() { onAdd?(deviceId) }
#endif
}
