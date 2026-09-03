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

/// The three small marks beside the counts, from the vendored Tabler set.
///
/// They used to be drawn here with UIBezierPath, which meant three glyphs nobody had reviewed,
/// drifting from the same three marks on the other shells. They are template images now, so each
/// takes the ink of the region it sits in.
final class ClusterIconView: UIView {

    enum Kind {
        case cluster
        case doorStation
        case indoorPanel

        var iconName: String {
            switch self {
            case .cluster: return "TablerTopologyStar3"
            case .doorStation: return "TablerDoor"
            case .indoorPanel: return "TablerDeviceTablet"
            }
        }
    }

    static let side: CGFloat = 18
    private let glyph = UIImageView()

    init(kind: Kind) {
        super.init(frame: CGRect(x: 0, y: 0, width: ClusterIconView.side,
                                 height: ClusterIconView.side))
        backgroundColor = .clear
        isOpaque = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: ClusterIconView.side).isActive = true
        heightAnchor.constraint(equalToConstant: ClusterIconView.side).isActive = true
        isAccessibilityElement = false

        glyph.image = TablerIcon.image(kind.iconName)
        glyph.contentMode = .scaleAspectFit
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.topAnchor.constraint(equalTo: topAnchor),
            glyph.bottomAnchor.constraint(equalTo: bottomAnchor),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: ClusterIconView.side, height: ClusterIconView.side)
    }

    /// A template image follows its tint, so this is one assignment rather than a redraw.
    func apply(ink: UIColor) {
        guard tintColor != ink else { return }
        tintColor = ink
        glyph.tintColor = ink
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
