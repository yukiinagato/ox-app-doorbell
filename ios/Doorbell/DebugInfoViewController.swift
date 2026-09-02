import CoreImage
import Darwin
import UIKit

/// PIN-gated diagnostics for the modern iOS shell. Values come from bounded Core snapshots;
/// secrets and the persisted boot JSON are intentionally not rendered here.
final class DebugInfoViewController: UIViewController {
    private let core: CoreBridge
    private let boot: BootConfig
    private let texts: Texts
    private let onPairing: () -> Void
    private let onMonitor: (() -> Void)?

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let titleLabel = UILabel()
    private let infoLabel = UILabel()
    private let addressLabel = UILabel()
    private let ipSelector = UISegmentedControl(items: ["IPv4", "IPv6"])
    private let cycleButton = UIButton(type: .system)
    private let qrImageView = UIImageView()
    private let qrURLLabel = UILabel()
    private let refreshButton = UIButton(type: .system)
    private let pairingButton = UIButton(type: .system)
    private let monitorButton = UIButton(type: .system)

    private var ipv4 = [String]()
    private var ipv6 = [String]()
    private var addressIndex = 0
    private var currentQRURL: String?
    private var refreshGeneration = 0

    private static let qrContext = CIContext()

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
        view.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)
        texts.setConfig(core.config())
        buildUI()
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func buildUI() {
        titleLabel.text = texts.t("info.title")
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2

        let closeButton = makeButton(title: texts.t("monitor.close"), filled: true)
        closeButton.accessibilityIdentifier = "debug_info_close"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [titleLabel, closeButton])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 16
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        infoLabel.font = UIFont(name: "Menlo", size: 14) ?? .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        infoLabel.textColor = UIColor(white: 0.92, alpha: 1)
        infoLabel.numberOfLines = 0
        infoLabel.accessibilityIdentifier = "debug_info_summary"

        addressLabel.font = UIFont(name: "Menlo", size: 14) ?? .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        addressLabel.textColor = UIColor(red: 0.55, green: 0.85, blue: 1, alpha: 1)
        addressLabel.numberOfLines = 0
        addressLabel.accessibilityIdentifier = "debug_info_addresses"

        ipSelector.selectedSegmentIndex = 0
        ipSelector.addTarget(self, action: #selector(addressTypeChanged), for: .valueChanged)
        ipSelector.accessibilityIdentifier = "debug_info_address_type"

        cycleButton.titleLabel?.font = .systemFont(ofSize: 16)
        cycleButton.setTitleColor(UIColor(red: 0.35, green: 0.72, blue: 1, alpha: 1), for: .normal)
        cycleButton.addTarget(self, action: #selector(cycleAddress), for: .touchUpInside)
        cycleButton.isHidden = true

        qrImageView.contentMode = .scaleAspectFit
        qrImageView.backgroundColor = .white
        qrImageView.layer.cornerRadius = 6
        qrImageView.clipsToBounds = true
        qrImageView.heightAnchor.constraint(equalToConstant: 280).isActive = true
        qrImageView.accessibilityIdentifier = "debug_info_qr"

        qrURLLabel.font = UIFont(name: "Menlo", size: 14) ?? .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        qrURLLabel.textColor = UIColor(white: 0.85, alpha: 1)
        qrURLLabel.textAlignment = .center
        qrURLLabel.numberOfLines = 0

        refreshButton.setTitle(texts.t("info.refresh"), for: .normal)
        refreshButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        refreshButton.setTitleColor(UIColor(red: 0.35, green: 0.72, blue: 1, alpha: 1), for: .normal)
        refreshButton.addTarget(self, action: #selector(refresh), for: .touchUpInside)
        refreshButton.accessibilityIdentifier = "debug_info_refresh"

        pairingButton.setTitle(texts.t("pair.panel_title"), for: .normal)
        pairingButton.addTarget(self, action: #selector(openPairing), for: .touchUpInside)
        pairingButton.accessibilityIdentifier = "debug_info_pairing"

        monitorButton.setTitle(texts.t("monitor.open"), for: .normal)
        monitorButton.addTarget(self, action: #selector(openMonitor), for: .touchUpInside)
        monitorButton.isHidden = onMonitor == nil
        monitorButton.accessibilityIdentifier = "debug_info_monitor"

        let actions = UIStackView(arrangedSubviews: [pairingButton, monitorButton, refreshButton])
        actions.axis = .vertical
        actions.spacing = 8

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.alignment = .fill
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 8, left: 20, bottom: 28, right: 20)
        contentStack.addArrangedSubview(infoLabel)
        contentStack.addArrangedSubview(addressLabel)
        contentStack.addArrangedSubview(ipSelector)
        contentStack.addArrangedSubview(cycleButton)
        contentStack.addArrangedSubview(qrImageView)
        contentStack.addArrangedSubview(qrURLLabel)
        contentStack.addArrangedSubview(actions)

        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func makeButton(title: String, filled: Bool = false) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = filled
            ? UIColor(red: 0.20, green: 0.24, blue: 0.30, alpha: 1)
            : UIColor(white: 1, alpha: 0.12)
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        return button
    }

    @objc private func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshButton.isEnabled = false
        let core = self.core
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = core.status()
            let debug = core.debugInfo()
            let capabilities = core.capabilities()
            let config = core.config()
            DispatchQueue.main.async {
                guard let self = self, self.refreshGeneration == generation else { return }
                self.texts.setConfig(config)
                self.refreshButton.isEnabled = true
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
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        let coreVersion = value(node["version"], fallback: value(debugNode["version"], fallback: "-"))

        var addresses = Set<String>()
        for value in (node["local_addrs"] as? [String] ?? []) where !value.isEmpty {
            addresses.insert(value)
        }
        for value in (debug?["addresses"] as? [String] ?? []) where !value.isEmpty {
            addresses.insert(value)
        }
        ipv4 = addresses.filter { !$0.contains(":") }.sorted()
        ipv6 = addresses.filter { $0.contains(":") }.sorted()

        var sections = [[String]]()
        sections.append([
            line("info.node", value: "\(value(node["name"], fallback: value(debugNode["node"], fallback: "-"))) (\(value(node["id"], fallback: "-")))"),
            line("info.role", value: value(node["role"], fallback: boot.role)),
            line("info.version", value: "App \(appVersion) (\(build)) · Core \(coreVersion)"),
            line("info.microphone", value: capabilityState(capabilities?["microphone"])),
            line("info.camera", value: capabilityState(capabilities?["camera"])),
        ])

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
            "safe_mode: \(localizedBool(runtime["safe_mode"]))",
            "last_exit: \(value(runtime["last_exit_reason"], fallback: texts.t("info.unknown")))",
            "heartbeat: \(timestamp(runtime["heartbeat_ms"]))",
            "sip: \(value(sip["state"], fallback: value(runtime["sip"], fallback: texts.t("info.unknown"))))",
        ]))

        if let components = runtime["components"] as? [String: Any], !components.isEmpty {
            sections.append(section("info.components", lines: components.keys.sorted().map {
                "\($0): \(value(components[$0], fallback: "-") )"
            }))
        }

        if let capabilities = capabilities, !capabilities.isEmpty {
            var capabilityLines = [String]()
            for key in ["sip_backend", "camera", "microphone", "h264_encode", "h264_decode", "sip", "tls12", "wan"] {
                if let item = capabilities[key] { capabilityLines.append("\(key): \(value(item, fallback: "-"))") }
            }
            if let features = capabilities["features"] as? [String: Any] {
                let enabled = features.keys.sorted().filter { localizedBool(features[$0]) == texts.t("admin.enabled") }
                capabilityLines.append("features: \(enabled.isEmpty ? texts.t("info.no_data") : enabled.joined(separator: ", "))")
            }
            sections.append(section("info.capabilities", lines: capabilityLines))
        }

        if let peers = status?["peers"] as? [[String: Any]] {
            let peerLines = peers.sorted { value($0["name"], fallback: value($0["id"], fallback: "")) <
                value($1["name"], fallback: value($1["id"], fallback: "")) }.map { peer in
                let name = value(peer["name"], fallback: value(peer["id"], fallback: "-"))
                return "\(name): \(value(peer["status"], fallback: "-")) / \(value(peer["role"], fallback: "-") )"
            }
            sections.append(section("info.peers", lines: peerLines.isEmpty ? [texts.t("info.no_data")] : peerLines))
        }

        let activeCalls = (status?["active_calls"] as? [[String: Any]])?.count ?? 0
        sections.append(section("info.active_calls", lines: [String(activeCalls)]))
        infoLabel.text = sections.filter { !$0.isEmpty }.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
        updateAddressUI()
    }

    private func line(_ key: String, value: String) -> String {
        "\(texts.t(key)) : \(value)"
    }

    private func section(_ key: String, lines: [String]) -> [String] {
        guard !lines.isEmpty else { return [] }
        return ["── \(texts.t(key)) ──"] + lines
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
        return "\(percent) (\(value(device["battery_state"], fallback: texts.t("info.unknown"))) )"
    }

    private func timestamp(_ raw: Any?) -> String {
        guard let number = raw as? NSNumber, number.int64Value > 0 else { return "-" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(number.int64Value) / 1000))
    }

    private func portLine(_ name: String, port: Int, suffix: String? = nil) -> String {
        guard port > 0, port <= 65535 else { return "\(name) : \(texts.t("info.unknown"))" }
        let state = isPortListening(port) ? "LISTEN ✓" : texts.t("info.port_closed")
        let tail = suffix.map { "  \($0)" } ?? ""
        return "\(name)  \(port) : \(state)\(tail)"
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

    @objc private func cycleAddress() {
        let list = selectedAddresses()
        if list.count > 1 { addressIndex = (addressIndex + 1) % list.count }
        updateAddressUI()
    }

    private func selectedAddresses() -> [String] {
        ipSelector.selectedSegmentIndex == 1 ? ipv6 : ipv4
    }

    private func updateAddressUI() {
        let addressLines = [
            "── \(texts.t("info.addresses")) ──",
            ipv4.isEmpty ? "IPv4: \(texts.t("info.no_address"))" : "IPv4:\n  \(ipv4.joined(separator: "\n  "))",
            ipv6.isEmpty ? "IPv6: \(texts.t("info.no_address"))" : "IPv6:\n  \(ipv6.joined(separator: "\n  "))",
        ]
        addressLabel.text = addressLines.joined(separator: "\n")
        ipSelector.setEnabled(!ipv4.isEmpty, forSegmentAt: 0)
        ipSelector.setEnabled(!ipv6.isEmpty, forSegmentAt: 1)
        if ipSelector.selectedSegmentIndex == 1 && ipv6.isEmpty { ipSelector.selectedSegmentIndex = 0 }
        if ipSelector.selectedSegmentIndex == 0 && ipv4.isEmpty && !ipv6.isEmpty { ipSelector.selectedSegmentIndex = 1 }

        let list = selectedAddresses()
        if addressIndex >= list.count { addressIndex = 0 }
        cycleButton.isHidden = list.count <= 1
        if list.count > 1 {
            cycleButton.setTitle(texts.t("info.address_cycle", "\(addressIndex + 1)", "\(list.count)"), for: .normal)
        }
        guard !list.isEmpty else {
            currentQRURL = nil
            qrImageView.image = nil
            qrImageView.isHidden = true
            qrURLLabel.text = texts.t("info.no_address")
            return
        }
        let address = list[addressIndex]
        let host = ipSelector.selectedSegmentIndex == 1 ? "[\(address)]" : address
        let url = "http://\(host):\(boot.httpPort)/admin/"
        currentQRURL = url
        qrImageView.isHidden = false
        qrURLLabel.text = "\(texts.t("info.scan_admin"))\n\(url)"
        qrImageView.image = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.qrImage(for: url)
            DispatchQueue.main.async {
                guard let self = self, self.currentQRURL == url else { return }
                self.qrImageView.image = image
            }
        }
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

    @objc private func openPairing() {
        dismiss(animated: true) { [weak self] in self?.onPairing() }
    }

    @objc private func openMonitor() {
        guard onMonitor != nil else { return }
        dismiss(animated: true) { [weak self] in self?.onMonitor?() }
    }
}
