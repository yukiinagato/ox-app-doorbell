import UIKit

/// Core's `db_core_air_quality_json` document reduced to what the home screens draw.
struct AirQualityReading: Equatable {
    enum State: String {
        case hidden, unconfigured, waiting, stale, ok
    }

    let state: State
    let pm25: Double?
    let level: String?

    static let hidden = AirQualityReading(state: .hidden, pm25: nil, level: nil)

    static let levels = ["good", "moderate", "sensitive", "unhealthy", "very_unhealthy",
                         "hazardous"]

    /// A missing document, `show:false`, or an unknown state draws nothing. A state that claims
    /// a reading without carrying one is drawn as the waiting placeholder.
    static func from(_ doc: [String: Any]?) -> AirQualityReading {
        guard let doc = doc, (doc["show"] as? Bool) == true,
              let raw = doc["state"] as? String, let state = State(rawValue: raw),
              state != .hidden else { return .hidden }
        let value = (doc["pm25"] as? NSNumber)?.doubleValue
        let level = (doc["level"] as? String).flatMap { levels.contains($0) ? $0 : nil }
        switch state {
        case .ok, .stale:
            guard let pm25 = value, pm25.isFinite, pm25 >= 0 else {
                return AirQualityReading(state: .waiting, pm25: nil, level: nil)
            }
            return AirQualityReading(state: state, pm25: pm25, level: level)
        default:
            return AirQualityReading(state: state, pm25: nil, level: nil)
        }
    }

    var isVisible: Bool { return state != .hidden }
    var isDimmed: Bool { return state == .stale }
    var hasValue: Bool { return pm25 != nil && (state == .ok || state == .stale) }

    var valueText: String? {
        guard hasValue, let pm25 = pm25 else { return nil }
        return String(Int(pm25.rounded()))
    }

    static func levelKey(_ level: String?) -> String? {
        guard let level = level, levels.contains(level) else { return nil }
        return "air.level_" + level
    }

    /// The conventional air-quality index colours. The level is always spelled out beside the
    /// dot, so the colour is never the only carrier of the meaning.
    static func levelColor(_ level: String?) -> UIColor? {
        switch level {
        case "good"?: return UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case "moderate"?: return UIColor(red: 1.00, green: 0.80, blue: 0.00, alpha: 1)
        case "sensitive"?: return UIColor(red: 1.00, green: 0.58, blue: 0.00, alpha: 1)
        case "unhealthy"?: return UIColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1)
        case "very_unhealthy"?: return UIColor(red: 0.60, green: 0.31, blue: 0.82, alpha: 1)
        case "hazardous"?: return UIColor(red: 0.50, green: 0.00, blue: 0.14, alpha: 1)
        default: return nil
        }
    }

    /// The status word after the value: the level while fresh, "not updated" while stale, the
    /// placeholder while there is no value.
    func statusText(_ texts: Texts) -> String {
        switch state {
        case .ok: return AirQualityReading.levelKey(level).map { texts.t($0) } ?? ""
        case .stale: return texts.t("air.stale")
        case .waiting: return texts.t("air.waiting")
        case .unconfigured: return texts.t("air.unconfigured")
        case .hidden: return ""
        }
    }

    func displayText(_ texts: Texts) -> String {
        var parts = [texts.t("air.pm25_label")]
        if let value = valueText { parts.append(value + " " + texts.t("air.unit")) }
        let status = statusText(texts)
        if !status.isEmpty { parts.append(status) }
        return parts.joined(separator: "  ")
    }

    func accessibilityText(_ texts: Texts) -> String {
        if let value = valueText {
            return texts.t("air.a11y", value, statusText(texts))
        }
        return texts.t("air.a11y_no_value", statusText(texts))
    }
}

/// One line on a home screen: a level dot, then the label, the value with its unit, and the
/// level. The text is drawn straight on the theme background, so it takes the `status_line`
/// region's ink like the clock and date around it.
final class AirQualityView: UIView {

    private let texts: Texts
    private let dot = UIView()
    private let row = UIStackView()
    let label = HaloLabel()
    private(set) var reading = AirQualityReading.hidden
    private var skin: DoorbellSkin?

    private static let dotSide: CGFloat = 10

    init(texts: Texts, centred: Bool) {
        self.texts = texts
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityIdentifier = "air_quality"

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = AirQualityView.dotSide / 2
        label.numberOfLines = 0
        label.textAlignment = centred ? .center : .natural
        label.isAccessibilityElement = false

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Space.xs
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(dot)
        row.addArrangedSubview(label)
        addSubview(row)

        var constraints = [
            dot.widthAnchor.constraint(equalToConstant: AirQualityView.dotSide),
            dot.heightAnchor.constraint(equalToConstant: AirQualityView.dotSide),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ]
        constraints.append(centred
            ? row.centerXAnchor.constraint(equalTo: centerXAnchor)
            : row.leadingAnchor.constraint(equalTo: leadingAnchor))
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var font: UIFont? {
        get { return label.font }
        set { label.font = newValue }
    }

    /// Returns true when the line's visibility or text changed, so a host that measures its
    /// header can re-measure.
    @discardableResult
    func update(_ next: AirQualityReading) -> Bool {
        let wasHidden = isHidden
        let oldText = label.text
        let dimmingChanged = next.isDimmed != reading.isDimmed
        reading = next
        render()
        if dimmingChanged, let skin = skin { paint(skin) }
        return wasHidden != isHidden || oldText != label.text
    }

    /// Re-reads the wording after a language change.
    @discardableResult
    func refreshText() -> Bool {
        let oldText = label.text
        render()
        return oldText != label.text
    }

    func apply(skin: DoorbellSkin) {
        self.skin = skin
        paint(skin)
    }

    private func paint(_ skin: DoorbellSkin) {
        skin.apply("status_line", to: label, quiet: reading.isDimmed)
    }

    private func render() {
        isHidden = !reading.isVisible
        guard reading.isVisible else {
            label.text = nil
            accessibilityLabel = nil
            return
        }
        label.text = reading.displayText(texts)
        accessibilityLabel = reading.accessibilityText(texts)
        let color = reading.hasValue ? AirQualityReading.levelColor(reading.level) : nil
        dot.backgroundColor = color
        dot.isHidden = color == nil
        dot.alpha = reading.isDimmed ? 0.4 : 1
    }
}
