import UIKit

extension Notification.Name {
    /// boot.json holds a new name, role or door for this device; the app delegate restarts
    /// Core and rebuilds the interface from it.
    static let doorbellIdentityChanged = Notification.Name("doorbell.identityChanged")
}

/// What the role form decides, kept apart from the table so it can be tested: which doors are
/// offered, whether the choice is valid, and which sentence explains it.
struct RoleChangePlan {
    static let roles = ["indoor_panel", "door_station"]

    var role: String
    /// A configured door id, or empty for "new door".
    var door: String
    var newDoor: String

    /// Configured doors no live door station other than this device serves, in display order,
    /// with this device's own door always among them.
    static func offeredDoors(config: [String: Any]?, status: [String: Any]?,
                             ownDoor: String) -> [String] {
        let doors = (ConfigUtil.dig(config, "doors") as? [String: Any]) ?? [:]
        var offered = ConfigUtil.sortedByOrder(doors).filter {
            $0 == ownDoor || ConfigUtil.onlineDoorPeer(status, door: $0) == nil
        }
        if BootConfig.validDoor(ownDoor), !offered.contains(ownDoor) { offered.insert(ownDoor, at: 0) }
        return offered
    }

    /// The door id that would be written: none for an indoor panel.
    var resolvedDoor: String {
        guard role == "door_station" else { return "" }
        return door.isEmpty ? newDoor.trimmingCharacters(in: .whitespaces) : door
    }

    var isValid: Bool {
        guard BootConfig.validRole(role) else { return false }
        return role != "door_station" || BootConfig.validDoor(resolvedDoor)
    }

    func changes(role currentRole: String, door currentDoor: String) -> Bool {
        return role != currentRole || resolvedDoor != currentDoor
    }

    /// The name of another device already configured as the door station of the chosen door.
    func conflictingDevice(config: [String: Any]?, nodeId: String, lang: String) -> String? {
        let chosen = resolvedDoor
        guard role == "door_station", !chosen.isEmpty,
              let devices = ConfigUtil.dig(config, "devices") as? [String: Any] else { return nil }
        for (id, value) in devices where id != nodeId {
            guard let entry = value as? [String: Any],
                  ConfigUtil.str(entry, "role") == "door_station",
                  ConfigUtil.str(entry, "door") == chosen else { continue }
            return ConfigUtil.str(entry, "name") ?? ConfigUtil.labelOf(entry, lang, id)
        }
        return nil
    }

    /// A role change restarts Core, so it waits while a call, an SOS or pairing is in progress.
    static func isBusy(status: [String: Any]?, pairing: PairingState) -> Bool {
        if let calls = status?["active_calls"] as? [Any], !calls.isEmpty { return true }
        if ConfigUtil.bool(status?["emergency"] as? [String: Any], "active", false) { return true }
        return pairing == .joining
    }
}

#if os(iOS)
/// The "Change role" form, reached from the admin-gated settings on either kind of device (a
/// door station gets there through its hidden corner and the admin password). Nothing is
/// written until the confirmation: boot.json first, then the existing identity restart.
final class RoleChangeController: UITableViewController, UITextFieldDelegate {

    private let core: CoreBridge
    private let boot: BootConfig
    private let texts: Texts
    private var plan: RoleChangePlan
    private var doors: [String] = []
    private let newDoorField = UITextField()
    private var config: [String: Any]?
    private var nodeId = ""

    private enum Section: Int, CaseIterable {
        case role, door, apply
    }

    init(core: CoreBridge, boot: BootConfig, texts: Texts) {
        self.core = core
        self.boot = boot
        self.texts = texts
        plan = RoleChangePlan(role: boot.role, door: boot.role == "door_station" ? boot.door : "",
                              newDoor: boot.suggestedDoor.isEmpty ? BootConfig.suggestedDoorId()
                                                                  : boot.suggestedDoor)
        super.init(style: SystemStyle.tableStyle())
        title = texts.t("settings.change_role")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        SystemStyle.style(tableView)
        tableView.accessibilityIdentifier = "role_change"
        tableView.keyboardDismissMode = .onDrag
        config = core.config()
        let status = core.status()
        nodeId = ConfigUtil.evStr((status?["node"] as? [String: Any]) ?? [:], "id")
        doors = RoleChangePlan.offeredDoors(config: config, status: status, ownDoor: boot.door)
        if plan.role == "door_station", !doors.contains(plan.door) { plan.door = "" }
        newDoorField.text = plan.newDoor
        newDoorField.placeholder = texts.t("settings.role_new_door_id")
        newDoorField.autocapitalizationType = .none
        newDoorField.autocorrectionType = .no
        newDoorField.keyboardType = .asciiCapable
        newDoorField.returnKeyType = .done
        newDoorField.clearButtonMode = .whileEditing
        newDoorField.font = SystemStyle.font(.body)
        newDoorField.textColor = SystemStyle.label
        newDoorField.delegate = self
        newDoorField.accessibilityIdentifier = "role_new_door_field"
        newDoorField.addTarget(self, action: #selector(newDoorChanged), for: .editingChanged)
    }

    private var showsDoors: Bool { return plan.role == "door_station" }

    private func doorLabel(_ door: String) -> String {
        let entry = ConfigUtil.dig(config, "doors.\(door)") as? [String: Any]
        let label = ConfigUtil.labelOf(entry, boot.uiLang, door)
        return label == door ? door : "\(label) (\(door))"
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .role?: return RoleChangePlan.roles.count
        case .door?: return showsDoors ? doors.count + 1 + (plan.door.isEmpty ? 1 : 0) : 0
        default: return 1
        }
    }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .role?: return texts.t("settings.device_role")
        case .door?: return showsDoors ? texts.t("settings.device_door") : nil
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .role?:
            guard !showsDoors else { return nil }
            return boot.role == "door_station"
                ? texts.t("settings.role_indoor_note") + " " + texts.t("settings.role_door_kept_note")
                : texts.t("settings.role_indoor_note")
        case .door?:
            guard showsDoors else { return nil }
            if let other = plan.conflictingDevice(config: config, nodeId: nodeId,
                                                  lang: boot.uiLang) {
                return texts.t("settings.role_door_in_use", other)
            }
            return plan.door.isEmpty ? texts.t("settings.device_door_desc") : nil
        default:
            return texts.t("settings.role_restart")
        }
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        SystemStyle.style(cell)
        switch Section(rawValue: indexPath.section) {
        case .role?:
            let role = RoleChangePlan.roles[indexPath.row]
            cell.textLabel?.text = texts.t(role == "door_station" ? "admin.role_door"
                                                                    : "admin.role_indoor")
            cell.accessoryType = role == plan.role ? .checkmark : .none
            cell.accessibilityIdentifier = "role_\(role)"
        case .door?:
            if indexPath.row < doors.count {
                let door = doors[indexPath.row]
                cell.textLabel?.text = doorLabel(door)
                cell.accessoryType = door == plan.door ? .checkmark : .none
                cell.accessibilityIdentifier = "role_door_\(door)"
            } else if indexPath.row == doors.count {
                cell.textLabel?.text = texts.t("settings.role_new_door")
                cell.accessoryType = plan.door.isEmpty ? .checkmark : .none
                cell.accessibilityIdentifier = "role_door_new"
            } else {
                cell.selectionStyle = .none
                newDoorField.translatesAutoresizingMaskIntoConstraints = false
                cell.contentView.addSubview(newDoorField)
                let margins = cell.contentView.layoutMarginsGuide
                NSLayoutConstraint.activate([
                    newDoorField.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                    newDoorField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                    newDoorField.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
                    newDoorField.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
                    newDoorField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
                ])
            }
        default:
            cell.textLabel?.text = texts.t("settings.change_role")
            cell.textLabel?.textColor = SystemStyle.tint
            cell.accessibilityIdentifier = "role_apply"
            cell.accessibilityTraits = .button
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .role?:
            plan.role = RoleChangePlan.roles[indexPath.row]
            tableView.reloadData()
        case .door?:
            guard indexPath.row <= doors.count else { return }
            plan.door = indexPath.row < doors.count ? doors[indexPath.row] : ""
            tableView.reloadData()
            if plan.door.isEmpty { newDoorField.becomeFirstResponder() }
        default:
            apply()
        }
    }

    @objc private func newDoorChanged() { plan.newDoor = newDoorField.text ?? "" }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: Apply

    private func notify(_ key: String) {
        let alert = UIAlertController(title: nil, message: texts.t(key), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: texts.t("editor.ok"), style: .default))
        present(alert, animated: true)
    }

    private func apply() {
        view.endEditing(true)
        guard plan.isValid else { return notify("prefs.invalid_door_id") }
        guard plan.changes(role: boot.role, door: boot.door) else {
            return notify("settings.role_unchanged")
        }
        guard !RoleChangePlan.isBusy(status: core.status(),
                                     pairing: PairingSnapshot.load(core).state) else {
            return notify("settings.role_busy")
        }
        var message = texts.t("settings.role_restart_confirm")
        if boot.role == "door_station" && plan.role != "door_station" {
            message += "\n\n" + texts.t("settings.role_door_kept_note")
        }
        let alert = UIAlertController(title: texts.t("settings.change_role"), message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: texts.t("settings.change_role"), style: .destructive) {
            [weak self] _ in self?.commit()
        })
        present(alert, animated: true)
    }

    /// boot.json first: it is the source of truth Core reads at start, and it can be written
    /// while unpaired. Core republishes this device's record and tidies the door list itself.
    private func commit() {
        guard BootConfig.persistSetup(name: boot.name, role: plan.role,
                                      door: plan.resolvedDoor) != nil else {
            return notify("settings.save_failed")
        }
        ShellLog.note("role change role=\(plan.role) door=\(plan.resolvedDoor)")
        NotificationCenter.default.post(name: .doorbellIdentityChanged, object: nil)
    }
}
#endif
