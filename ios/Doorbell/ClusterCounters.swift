import UIKit

/// How many devices the cluster holds, and how many of each kind are reachable right now.
struct ClusterCounts: Equatable {

    var devices = 0
    var doorStations = 0
    var doorStationsOnline = 0
    var indoorPanels = 0
    var indoorPanelsOnline = 0

    /// Counts every entry in `status.peers`. Core lists this device there too and marks it
    /// `self`; when a snapshot does not carry that entry, `selfRole` adds it, because a panel that
    /// cannot see itself in the list is still a device in the cluster. This device is always
    /// counted as reachable — it is the one asking.
    static func from(status: [String: Any]?, selfRole: String = "") -> ClusterCounts {
        var counts = ClusterCounts()
        var sawSelf = false
        for peer in (status?["peers"] as? [[String: Any]]) ?? [] {
            let isSelf = ConfigUtil.evBool(peer, "self")
            if isSelf { sawSelf = true }
            counts.add(role: ConfigUtil.evStr(peer, "role"),
                       online: isSelf || ConfigUtil.evStr(peer, "status") != "dead")
        }
        if !sawSelf && !selfRole.isEmpty {
            counts.add(role: selfRole, online: true)
        }
        return counts
    }

    private mutating func add(role: String, online: Bool) {
        devices += 1
        switch role {
        case "door_station":
            doorStations += 1
            if online { doorStationsOnline += 1 }
        case "indoor_panel":
            indoorPanels += 1
            if online { indoorPanelsOnline += 1 }
        default:
            // A role this build does not know still counts as a device in the cluster; it simply
            // has no row of its own.
            break
        }
    }
}

/// The three small marks drawn beside the counts. They are drawn rather than set as text: an
/// emoji renders differently on every one of these devices and carries a colour the palette does
/// not choose, and the shell ships no icon font.
final class ClusterIconView: UIView {

    enum Kind {
        case cluster
        case doorStation
        case indoorPanel
    }

    private let kind: Kind
    static let side: CGFloat = 18

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: CGRect(x: 0, y: 0, width: ClusterIconView.side,
                                 height: ClusterIconView.side))
        backgroundColor = .clear
        isOpaque = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: ClusterIconView.side).isActive = true
        heightAnchor.constraint(equalToConstant: ClusterIconView.side).isActive = true
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: ClusterIconView.side, height: ClusterIconView.side)
    }

    /// Redrawn rather than tinted, because the ink comes from the palette and changes with it.
    func apply(ink: UIColor) {
        guard tintColor != ink else { return }
        tintColor = ink
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let ink = tintColor ?? .white
        ink.setStroke()
        ink.setFill()
        let side = min(bounds.width, bounds.height)
        let scale = side / ClusterIconView.side
        let line = max(1, 1.4 * scale)
        switch kind {
        case .cluster:
            drawCluster(in: bounds, line: line)
        case .doorStation:
            drawDoorStation(in: bounds, line: line)
        case .indoorPanel:
            drawIndoorPanel(in: bounds, line: line)
        }
    }

    /// One node with three around it: the shape of a cluster rather than of any one device.
    private func drawCluster(in rect: CGRect, line: CGFloat) {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.34
        let satellite = min(rect.width, rect.height) * 0.13
        let spokes = UIBezierPath()
        for step in 0..<3 {
            let angle = CGFloat(step) * (2 * CGFloat.pi / 3) - CGFloat.pi / 2
            let point = CGPoint(x: centre.x + cos(angle) * radius,
                                y: centre.y + sin(angle) * radius)
            spokes.move(to: centre)
            spokes.addLine(to: point)
            UIBezierPath(ovalIn: CGRect(x: point.x - satellite, y: point.y - satellite,
                                        width: satellite * 2, height: satellite * 2)).fill()
        }
        spokes.lineWidth = line
        spokes.stroke()
        let hub = min(rect.width, rect.height) * 0.11
        UIBezierPath(ovalIn: CGRect(x: centre.x - hub, y: centre.y - hub,
                                    width: hub * 2, height: hub * 2)).fill()
    }

    /// A doorway with its call button beside it.
    private func drawDoorStation(in rect: CGRect, line: CGFloat) {
        let width = rect.width * 0.46
        let door = CGRect(x: rect.midX - width * 0.72, y: rect.height * 0.12,
                          width: width, height: rect.height * 0.76)
        let path = UIBezierPath(roundedRect: door, cornerRadius: door.width * 0.32)
        path.lineWidth = line
        path.stroke()
        let button = min(rect.width, rect.height) * 0.09
        UIBezierPath(ovalIn: CGRect(x: door.maxX + button * 1.4, y: rect.midY - button,
                                    width: button * 2, height: button * 2)).fill()
    }

    /// A screen on a stand.
    private func drawIndoorPanel(in rect: CGRect, line: CGFloat) {
        let screen = CGRect(x: rect.width * 0.12, y: rect.height * 0.16,
                            width: rect.width * 0.76, height: rect.height * 0.54)
        let path = UIBezierPath(roundedRect: screen, cornerRadius: screen.height * 0.22)
        path.lineWidth = line
        path.stroke()
        let stand = UIBezierPath()
        stand.move(to: CGPoint(x: rect.midX, y: screen.maxY))
        stand.addLine(to: CGPoint(x: rect.midX, y: rect.height * 0.82))
        stand.move(to: CGPoint(x: rect.width * 0.3, y: rect.height * 0.84))
        stand.addLine(to: CGPoint(x: rect.width * 0.7, y: rect.height * 0.84))
        stand.lineWidth = line
        stand.lineCapStyle = .round
        stand.stroke()
    }
}

/// One icon and the number beside it.
final class ClusterCounterView: UIStackView {

    private let icon: ClusterIconView
    private let value = UILabel()

    init(kind: ClusterIconView.Kind, identifier: String) {
        icon = ClusterIconView(kind: kind)
        super.init(frame: .zero)
        axis = .horizontal
        spacing = 5
        alignment = .center
        value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        addArrangedSubview(icon)
        addArrangedSubview(value)
        accessibilityIdentifier = identifier
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    func update(text: String, ink: UIColor, accessibility: String) {
        if value.text != text { value.text = text }
        if value.textColor != ink { value.textColor = ink }
        icon.apply(ink: ink)
        accessibilityLabel = accessibility
    }
}

/// The cluster's three counts, in place of the old membership pill: how many devices there are,
/// and how many of each kind can be reached.
final class ClusterCountersView: UIStackView {

    private let texts: Texts
    private let devices = ClusterCounterView(kind: .cluster, identifier: "count_devices")
    private let doors = ClusterCounterView(kind: .doorStation, identifier: "count_door_stations")
    private let panels = ClusterCounterView(kind: .indoorPanel, identifier: "count_indoor_panels")

    init(texts: Texts) {
        self.texts = texts
        super.init(frame: .zero)
        axis = .horizontal
        spacing = 14
        alignment = .center
        for counter in [devices, doors, panels] { addArrangedSubview(counter) }
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    func update(_ counts: ClusterCounts, ink: UIColor) {
        devices.update(text: "\(counts.devices)", ink: ink,
                       accessibility: texts.t("cluster.devices_a11y", "\(counts.devices)"))
        doors.update(text: "\(counts.doorStationsOnline)/\(counts.doorStations)", ink: ink,
                     accessibility: texts.t("cluster.door_stations_a11y",
                                            "\(counts.doorStationsOnline)",
                                            "\(counts.doorStations)"))
        panels.update(text: "\(counts.indoorPanelsOnline)/\(counts.indoorPanels)", ink: ink,
                      accessibility: texts.t("cluster.indoor_panels_a11y",
                                             "\(counts.indoorPanelsOnline)",
                                             "\(counts.indoorPanels)"))
    }
}
