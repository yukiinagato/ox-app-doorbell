import CoreImage
import Darwin
import UIKit

/// PIN-gated diagnostics for the modern iOS shell: one grouped table of label and value rows
/// under the stock navigation bar. Values come from bounded Core snapshots; secrets and the
/// persisted boot JSON are intentionally not rendered here.
final class DebugInfoViewController: PairingTableScreen {
    private let core: CoreBridge
    private let boot: BootConfig
    private let texts: Texts
    private let onPairing: () -> Void
    private let onMonitor: (() -> Void)?

    private typealias Line = (label: String, value: String)

    private let ipSelector = UISegmentedControl(items: ["IPv4", "IPv6"])
    private lazy var selectorRow = PairingCells.custom(ipSelector, vertical: 8)
    private lazy var cycleRow = PairingCells.action(title: "", identifier: "debug_info_cycle") {
        [weak self] in self?.cycleAddress()
    }
    private let qrImageView = UIImageView()
    private lazy var qrRow: PairingRow = {
        let box = UIView()
        qrImageView.contentMode = .scaleAspectFit
        qrImageView.backgroundColor = .white
        qrImageView.layer.cornerRadius = 6
        qrImageView.clipsToBounds = true
        qrImageView.isAccessibilityElement = true
        qrImageView.accessibilityIdentifier = "debug_info_qr"
        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(qrImageView)
        let side = qrImageView.widthAnchor.constraint(equalToConstant: 280)
        side.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            side,
            qrImageView.heightAnchor.constraint(equalTo: qrImageView.widthAnchor),
            qrImageView.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor),
            qrImageView.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            qrImageView.topAnchor.constraint(equalTo: box.topAnchor),
            qrImageView.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return PairingCells.custom(box)
    }()
    private let noAddressRow = PairingCells.text(tone: .secondary)
    private lazy var pairingRow = disclosure(PairingCells.action(
        title: texts.t("pair.panel_title"), identifier: "debug_info_pairing") {
        [weak self] in self?.openPairing()
    })
    private lazy var monitorRow = disclosure(PairingCells.action(
        title: texts.t("monitor.open"), identifier: "debug_info_monitor") {
        [weak self] in self?.openMonitor()
    })
    private lazy var refreshItem = SystemStyle.barItem(
        icon: "TablerReload", label: texts.t("info.refresh"), target: self,
        action: #selector(refresh), identifier: "debug_info_refresh")

    private var summary: [PairingSection] = []
    private var ipv4 = [String]()
    private var ipv6 = [String]()
    private var addressIndex = 0
    private var currentQRURL: String?
    private var refreshGeneration = 0

    private static let qrContext = CIContext()

    override var prefersLargeTitle: Bool { return false }

    init(core: CoreBridge, boot: BootConfig, texts: Texts,
         onPairing: @escaping () -> Void, onMonitor: (() -> Void)?) {
        self.core = core
        self.boot = boot
        self.texts = texts
        self.onPairing = onPairing
        self.onMonitor = onMonitor
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        texts.setConfig(core.config())
        buildUI()
        refresh()
    }

    /// The information page does not let the screen sleep either. A panel that auto-locks is
    /// suspended, and a suspended node refuses its ports and is evicted with nothing written
    /// anywhere to say why; leaving this page open is not worth that.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ScreenAwake.apply()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        ScreenAwake.apply()
    }

    private func buildUI() {
        barItem.title = texts.t("info.title")
        let closeItem = UIBarButtonItem(title: texts.t("monitor.close"), style: .done,
                                        target: self, action: #selector(close))
        closeItem.accessibilityIdentifier = "debug_info_close"
        barItem.leftBarButtonItem = closeItem
        barItem.rightBarButtonItem = refreshItem
        table.accessibilityIdentifier = "debug_info_summary"

        ipSelector.selectedSegmentIndex = 0
        ipSelector.addTarget(self, action: #selector(addressTypeChanged), for: .valueChanged)
        ipSelector.accessibilityIdentifier = "debug_info_address_type"
        noAddressRow.cell.textLabel?.text = texts.t("info.no_address")
    }

    private func disclosure(_ row: PairingRow) -> PairingRow {
        row.cell.accessoryType = .disclosureIndicator
        return row
    }

    @objc private func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshItem.isEnabled = false
        let core = self.core
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = core.status()
            let debug = core.debugInfo()
            let capabilities = core.capabilities()
            let config = core.config()
            DispatchQueue.main.async {
                guard let self = self, self.refreshGeneration == generation else { return }
                self.texts.setConfig(config)
                self.refreshItem.isEnabled = true
                self.apply(status: status, debug: debug, capabilities: capabilities, config: config)
            }
        }
    }

    private func apply(status: [String: Any]?, debug: [String: Any]?,
                       capabilities: [String: Any]?, config: [String: Any]?) {
        let node = status?["node"] as? [String: Any] ?? [:]
        let debugNode = debug?["node"] as? [String: Any] ?? [:]
        let device = debug?["device"] as? [String: Any] ?? [:]
        let runtime = status?["runtime"] as? [String: Any] ?? [:]
        let sip = status?["sip"] as? [String: Any] ?? [:]
        let coreVersion = value(node["version"], fallback: value(debugNode["version"], fallback: "-"))
        let appVersion = DoorbellTheme.appVersion(coreVersion: coreVersion)

        var addresses = Set<String>()
        for value in (node["local_addrs"] as? [String] ?? []) where !value.isEmpty {
            addresses.insert(value)
        }
        for value in (debug?["addresses"] as? [String] ?? []) where !value.isEmpty {
            addresses.insert(value)
        }
        ipv4 = addresses.filter { !$0.contains(":") }.sorted()
        ipv6 = addresses.filter { $0.contains(":") }.sorted()

        var sections = [PairingSection]()
        sections.append(section(nil, lines: [
            line("info.node", value: "\(value(node["name"], fallback: value(debugNode["node"], fallback: "-"))) (\(value(node["id"], fallback: "-")))"),
            line("info.role", value: value(node["role"], fallback: boot.role)),
            line("info.version", value: "App \(appVersion) · Core \(DoorbellTheme.shortVersion(coreVersion))"),
            line("info.microphone", value: capabilityState(capabilities?["microphone"])),
            line("info.camera", value: capabilityState(capabilities?["camera"])),
        ]))

        let system = [value(device["system"]), value(device["system_version"])].compactMap { $0 }.joined(separator: " ")
        sections.append(section("info.device", lines: [
            line("info.system", value: system.isEmpty ? "-" : system),
            line("info.model", value: value(device["model"], fallback: "-")),
            line("info.machine", value: value(device["machine"], fallback: "-")),
            line("info.memory", value: formatBytes(device["physical_memory"])),
            line("info.uptime", value: formatDuration(device["uptime_s"])),
            line("info.battery", value: batteryText(device)),
        ]))

        let directPort = ConfigUtil.int(config, "sip.direct_port", 47190)
        sections.append(section("info.ports", lines: [
            portLine("http", port: boot.httpPort),
            portLine("mesh", port: 47172),
            portLine("sip", port: directPort, suffix: texts.t("info.sip_direct")),
        ]))

        if let trigger = debug?["triggers"] as? [String: Any] {
            var triggerLines = [line("info.total_press", value: value(trigger["total_press"], fallback: "0"))]
            if let last = trigger["last"] as? [String: Any] {
                let lastTime = timestamp(last["wall_ms"])
                triggerLines.append(line("info.last_press", value: "\(lastTime)  door=\(value(last["door"], fallback: "-"))"))
            } else {
                triggerLines.append(line("info.last_press", value: texts.t("info.no_press")))
            }
            sections.append(section("info.triggers", lines: triggerLines))
        }

        sections.append(section("info.runtime", lines: [
            ("safe_mode", localizedBool(runtime["safe_mode"])),
            ("last_exit", value(runtime["last_exit_reason"], fallback: texts.t("info.unknown"))),
            ("heartbeat", timestamp(runtime["heartbeat_ms"])),
            ("sip", value(sip["state"], fallback: value(runtime["sip"], fallback: texts.t("info.unknown")))),
        ]))

        if let components = runtime["components"] as? [String: Any], !components.isEmpty {
            sections.append(section("info.components", lines: components.keys.sorted().map {
                ($0, value(components[$0], fallback: "-"))
            }))
        }

        if let capabilities = capabilities, !capabilities.isEmpty {
            var capabilityLines = [Line]()
            for key in ["sip_backend", "camera", "microphone", "h264_encode", "h264_decode", "sip", "tls12", "wan"] {
                if let item = capabilities[key] { capabilityLines.append((key, value(item, fallback: "-"))) }
            }
            if let features = capabilities["features"] as? [String: Any] {
                let enabled = features.keys.sorted().filter { localizedBool(features[$0]) == texts.t("admin.enabled") }
                capabilityLines.append(("features", enabled.isEmpty ? texts.t("info.no_data") : enabled.joined(separator: ", ")))
            }
            sections.append(section("info.capabilities", lines: capabilityLines))
        }

        if let peers = status?["peers"] as? [[String: Any]] {
            let peerLines: [Line] = peers.sorted { value($0["name"], fallback: value($0["id"], fallback: "")) <
                value($1["name"], fallback: value($1["id"], fallback: "")) }.map { peer in
                let name = value(peer["name"], fallback: value(peer["id"], fallback: "-"))
                return (name, "\(value(peer["status"], fallback: "-")) / \(value(peer["role"], fallback: "-"))")
            }
            sections.append(section("info.peers", lines: peerLines.isEmpty ? [(texts.t("info.no_data"), "")] : peerLines))
        }

        let activeCalls = (status?["active_calls"] as? [[String: Any]])?.count ?? 0
        sections.append(section(nil, lines: [line("info.active_calls", value: String(activeCalls))]))
        summary = sections.filter { !$0.rows.isEmpty }
        updateAddressUI()
    }

    private func line(_ key: String, value: String) -> Line {
        return (texts.t(key), value)
    }

    /// Short values sit beside their label; long ones wrap underneath it.
    private func section(_ key: String?, lines: [Line],
                         identifier: String? = nil) -> PairingSection {
        let rows = lines.map { line -> PairingRow in
            let row = PairingCells.text(style: line.value.count > 22 ? .subtitle : .value1,
                                        identifier: identifier)
            row.cell.textLabel?.text = line.label
            row.cell.detailTextLabel?.text = line.value
            return row
        }
        return PairingSection(header: key.map { texts.t($0) }, rows: rows)
    }

    private func value(_ raw: Any?, fallback: String = "") -> String {
        guard let raw = raw, !(raw is NSNull) else { return fallback }
        if let text = raw as? String, !text.isEmpty { return text }
        if let bool = raw as? Bool { return bool ? "true" : "false" }
        if let number = raw as? NSNumber { return number.stringValue }
        return String(describing: raw)
    }

    private func localizedBool(_ raw: Any?) -> String {
        guard let raw = raw, !(raw is NSNull) else { return texts.t("info.unknown") }
        if let bool = raw as? Bool { return bool ? texts.t("admin.enabled") : texts.t("admin.disabled") }
        if let number = raw as? NSNumber { return number.boolValue ? texts.t("admin.enabled") : texts.t("admin.disabled") }
        return value(raw, fallback: texts.t("info.unknown"))
    }

    private func capabilityState(_ raw: Any?) -> String {
        guard raw != nil else { return texts.t("info.unknown") }
        return localizedBool(raw)
    }

    private func formatBytes(_ raw: Any?) -> String {
        guard let number = raw as? NSNumber else { return texts.t("info.unknown") }
        let bytes = Double(number.uint64Value)
        if bytes >= 1_073_741_824 { return String(format: "%.1f GiB", bytes / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.1f MiB", bytes / 1_048_576) }
        return "\(number.uint64Value) B"
    }

    private func formatDuration(_ raw: Any?) -> String {
        guard let number = raw as? NSNumber else { return texts.t("info.unknown") }
        let total = max(0, number.intValue)
        return "\(total / 3600)h \((total / 60) % 60)m \(total % 60)s"
    }

    private func batteryText(_ device: [String: Any]) -> String {
        let percent: String
        if let value = device["battery_percent"] as? NSNumber, value.intValue >= 0 {
            percent = "\(value.intValue)%"
        } else {
            percent = "-"
        }
        return "\(percent) (\(value(device["battery_state"], fallback: texts.t("info.unknown"))))"
    }

    private func timestamp(_ raw: Any?) -> String {
        guard let number = raw as? NSNumber, number.int64Value > 0 else { return "-" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(number.int64Value) / 1000))
    }

    private func portLine(_ name: String, port: Int, suffix: String? = nil) -> Line {
        guard port > 0, port <= 65535 else { return (name, texts.t("info.unknown")) }
        let state = isPortListening(port) ? "LISTEN" : texts.t("info.port_closed")
        let tail = suffix.map { "  \($0)" } ?? ""
        return ("\(name)  \(port)", "\(state)\(tail)")
    }

    private func isPortListening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    @objc private func addressTypeChanged() {
        addressIndex = 0
        updateAddressUI()
    }

    private func cycleAddress() {
        let list = selectedAddresses()
        if list.count > 1 { addressIndex = (addressIndex + 1) % list.count }
        updateAddressUI()
    }

    private func selectedAddresses() -> [String] {
        ipSelector.selectedSegmentIndex == 1 ? ipv6 : ipv4
    }

    private func updateAddressUI() {
        let none = texts.t("info.no_address")
        let listed: [Line] = (ipv4.isEmpty ? [("IPv4", none)] : ipv4.map { ("IPv4", $0) })
            + (ipv6.isEmpty ? [("IPv6", none)] : ipv6.map { ("IPv6", $0) })
        var sections = summary
        sections.append(section("info.addresses", lines: listed,
                                identifier: "debug_info_addresses"))

        ipSelector.setEnabled(!ipv4.isEmpty, forSegmentAt: 0)
        ipSelector.setEnabled(!ipv6.isEmpty, forSegmentAt: 1)
        if ipSelector.selectedSegmentIndex == 1 && ipv6.isEmpty { ipSelector.selectedSegmentIndex = 0 }
        if ipSelector.selectedSegmentIndex == 0 && ipv4.isEmpty && !ipv6.isEmpty { ipSelector.selectedSegmentIndex = 1 }

        let list = selectedAddresses()
        if addressIndex >= list.count { addressIndex = 0 }
        var admin = [selectorRow]
        if list.count > 1 {
            cycleRow.setTitle(texts.t("info.address_cycle", "\(addressIndex + 1)", "\(list.count)"))
            admin.append(cycleRow)
        }
        var footer: String?
        if list.isEmpty {
            currentQRURL = nil
            qrImageView.image = nil
            admin.append(noAddressRow)
        } else {
            let address = list[addressIndex]
            let host = ipSelector.selectedSegmentIndex == 1 ? "[\(address)]" : address
            let url = "https://\(host):\(ConfigUtil.peerAdminHttpsPort)/admin/"
            admin.append(qrRow)
            footer = "\(texts.t("info.scan_admin"))\n\(url)"
            if currentQRURL != url {
                currentQRURL = url
                qrImageView.image = nil
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let image = Self.qrImage(for: url)
                    DispatchQueue.main.async {
                        guard let self = self, self.currentQRURL == url else { return }
                        self.qrImageView.image = image
                    }
                }
            }
        }
        sections.append(PairingSection(footer: footer, rows: admin))
        sections.append(PairingSection(
            rows: [pairingRow] + (onMonitor == nil ? [] : [monitorRow])))
        setSections(sections)
    }

    private static func qrImage(for value: String) -> UIImage? {
        guard let data = value.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = 440 / output.extent.width
        let image = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = qrContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    @objc private func close() { dismiss(animated: true) }

    private func openPairing() {
        dismiss(animated: true) { [weak self] in self?.onPairing() }
    }

    private func openMonitor() {
        guard onMonitor != nil else { return }
        dismiss(animated: true) { [weak self] in self?.onMonitor?() }
    }
}
