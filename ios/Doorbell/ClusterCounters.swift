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
/// They used to be stroked here by hand, which meant three glyphs nobody had reviewed, drifting
/// from the same three marks on every other shell. They are generated template images now, so
/// each takes the ink of the region it sits in and every shell shows the same mark.
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
    private let title = UILabel()

    init(kind: ClusterIconView.Kind, identifier: String, title: String) {
        icon = ClusterIconView(kind: kind)
        super.init(frame: .zero)
        axis = .horizontal
        spacing = 5
        alignment = .center
        self.title.text = title
        self.title.font = .systemFont(ofSize: 11, weight: .semibold)
        self.title.numberOfLines = 1
        self.title.adjustsFontSizeToFitWidth = true
        self.title.minimumScaleFactor = 0.75
        self.title.textColor = UIColor(white: 0.08, alpha: 1)
        value.font = .monospacedDigitSystemFont(ofSize: 18, weight: .bold)
        value.textColor = UIColor(white: 0.08, alpha: 1)
        let labels = UIStackView(arrangedSubviews: [self.title, value])
        labels.axis = .vertical
        labels.spacing = 1
        addArrangedSubview(icon)
        addArrangedSubview(labels)
        accessibilityIdentifier = identifier
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        isLayoutMarginsRelativeArrangement = true
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 5, leading: 6,
                                                           bottom: 5, trailing: 6)
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    func update(text: String, ink: UIColor, accessibility: String) {
        if value.text != text { value.text = text }
        let labelInk = UIColor(white: 0.08, alpha: 1)
        if title.textColor != labelInk { title.textColor = labelInk }
        if value.textColor != labelInk { value.textColor = labelInk }
        icon.apply(ink: labelInk)
        accessibilityLabel = accessibility
    }
}

/// The cluster's three counts, in place of the old membership pill: how many devices there are,
/// and how many of each kind can be reached.
final class ClusterCountersView: UIView {

    private let texts: Texts
    private let devices: ClusterCounterView
    private let doors: ClusterCounterView
    private let panels: ClusterCounterView
    private let row = UIStackView()
    private let dividers = (0..<2).map { _ in UIView() }

    init(texts: Texts) {
        self.texts = texts
        devices = ClusterCounterView(kind: .cluster, identifier: "count_devices",
                                     title: texts.t("admin.devices"))
        doors = ClusterCounterView(kind: .doorStation, identifier: "count_door_stations",
                                   title: texts.t("pair.role_door_station"))
        panels = ClusterCounterView(kind: .indoorPanel, identifier: "count_indoor_panels",
                                    title: texts.t("admin.role_indoor"))
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.94, alpha: 1)
        layer.cornerRadius = 9
        clipsToBounds = true
        row.axis = .horizontal
        row.spacing = 0
        row.alignment = .fill
        row.distribution = .fillEqually
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 5,
                                                               bottom: 0, trailing: 5)
        for counter in [devices, doors, panels] { row.addArrangedSubview(counter) }
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for (index, divider) in dividers.enumerated() {
            divider.backgroundColor = UIColor(white: 0.45, alpha: 0.55)
            divider.translatesAutoresizingMaskIntoConstraints = false
            addSubview(divider)
            let anchor = index == 0 ? devices.trailingAnchor : doors.trailingAnchor
            NSLayoutConstraint.activate([
                divider.centerYAnchor.constraint(equalTo: centerYAnchor),
                divider.centerXAnchor.constraint(equalTo: anchor),
                divider.widthAnchor.constraint(equalToConstant: 1),
                divider.heightAnchor.constraint(equalToConstant: 18),
            ])
        }
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
