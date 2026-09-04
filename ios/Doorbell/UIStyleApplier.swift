import UIKit

/// Applies the constrained semantic style contract. Invalid values never replace the last known
/// good style, and every interactive control retains an effective 44pt hit target.
final class UIStyleApplier {
    static let reportChanged = Notification.Name("DoorbellUIStyleReportChanged")

    private struct Baseline {
        var transform: CGAffineTransform
        var background: UIColor?
        var validationBackground: UIColor?
        var foreground: UIColor?
        var tint: UIColor?
        var border: CGColor?
        var borderWidth: CGFloat
        var radius: CGFloat
        var fontSize: CGFloat?
    }

    private struct StyleState {
        var baseline: Baseline
        var active = false
        var lastApplied: Baseline?
    }

    private var states: [ObjectIdentifier: StyleState] = [:]
    private var minimumSizeConstraints:
        [ObjectIdentifier: (width: NSLayoutConstraint, height: NSLayoutConstraint)] = [:]
    private let safetyIds = Set(["cancel.call", "call.end", "sos.trigger", "sos.cancel",
                                 "maintenance.exit"])
    private let allowed = Set(["scale", "font_scale", "foreground", "background", "accent",
                               "border", "radius"])

    private static let reportLock = NSLock()
    private static var outcomes: [String: [String: Any]] = [:]
    private static var lastError = ""
    private static var updatedAtMs: Int64 = 0

    static func runtimeReport() -> [String: Any] {
        reportLock.lock()
        defer { reportLock.unlock() }
        let ordered = outcomes.keys.sorted()
        let applied = ordered.filter { outcomes[$0]?["applied"] as? Bool == true }
        let rejected: [[String: Any]] = ordered.compactMap { id in
            guard outcomes[id]?["rejected"] as? Bool == true else { return nil }
            return ["semantic_id": id,
                    "reason": outcomes[id]?["error"] as? String ?? "invalid_override"]
        }
        let used = ordered.filter { outcomes[$0]?["source"] as? String == "last_known_good" }
        let persisted = ordered.filter { outcomes[$0]?["lkg_persisted"] as? Bool == true }
        return [
            "schema_version": 1,
            "applied": applied,
            "rejected": rejected,
            "last_known_good": ["used": used, "persisted": persisted],
            "last_error": lastError,
            "updated_at_ms": updatedAtMs,
            "elements": outcomes,
        ]
    }

    /// `offered` says whether this control belongs on this screen at all — a door station has no
    /// SOS slider unless an administrator put its role on `emergency.button_on_roles`. The safety
    /// floor further down exists to stop a *style* hiding a safety control; without this flag it
    /// also resurrected one the shell had never offered, on every layout pass, which is what kept
    /// an SOS slider on the door station's visitor screen after the role gate had hidden it.
    func apply(config: [String: Any]?, nodeId: String, semanticId: String, to view: UIView,
               offered: Bool = true) {
        guard offered else { return }
        guard !nodeId.isEmpty else { return }
        let identity = ObjectIdentifier(view)
        var state = states[identity] ?? StyleState(baseline: snapshot(of: view))
        if state.active {
            rebaseOwnerValues(in: &state, from: view)
        } else {
            // With no semantic override the screen owns its colours. Keep this current so a
            // later override restores the theme the screen actually rendered, not its startup
            // appearance.
            state.baseline = snapshot(of: view)
        }
        let base = state.baseline
        let elements = ConfigUtil.dig(config, "devices.\(nodeId).local.ui.elements")
            as? [String: Any]
        let proposed = elements?[semanticId] as? [String: Any]
        let style: [String: Any]?
        var source = "default"
        var rejected = false
        var persisted = false
        var error = ""
        if let proposed = proposed,
           validationError(proposed, semanticId: semanticId, baseline: base) == nil {
            style = proposed
            source = "override"
            persisted = save(proposed, nodeId: nodeId, semanticId: semanticId)
            if !persisted { error = "last_known_good_persist_failed" }
        } else if proposed != nil {
            rejected = true
            error = validationError(proposed!, semanticId: semanticId, baseline: base) ??
                "invalid_override"
            let saved = load(nodeId: nodeId, semanticId: semanticId)
            style = saved.flatMap {
                validate($0, semanticId: semanticId, baseline: base) ? $0 : nil
            }
            if style != nil {
                source = "last_known_good"
                persisted = true
            }
        } else {
            style = nil
        }
        if let style = style {
            apply(style, baseline: base, semanticId: semanticId, to: view)
            state.active = true
            state.lastApplied = snapshot(of: view)
        } else {
            if state.active { restore(base, to: view) }
            state.active = false
            state.lastApplied = nil
            enforceSafety(semanticId: semanticId, on: view)
            ensureMinimumHitTarget(on: view, scale: 1)
        }
        states[identity] = state
        record(semanticId: semanticId, source: source, applied: style != nil,
               rejected: rejected, persisted: persisted, error: error)
    }

    private func apply(_ style: [String: Any], baseline base: Baseline, semanticId: String,
                       to view: UIView) {
        restore(base, to: view)

        var scale = number(style["scale"]) ?? 1
        scale = min(2, max(0.75, scale))
        if safetyIds.contains(semanticId) {
            let smallest = min(view.bounds.width, view.bounds.height)
            if smallest > 0 { scale = max(scale, min(2, 44 / smallest)) }
            enforceSafety(semanticId: semanticId, on: view)
        }
        view.transform = base.transform.scaledBy(x: CGFloat(scale), y: CGFloat(scale))

        if let fontScale = number(style["font_scale"]), let size = base.fontSize {
            setFontSize(size * CGFloat(min(2, max(0.75, fontScale))), on: view)
        }
        if let color = color(style["foreground"]) { setForeground(color, on: view) }
        if let color = color(style["background"]) { view.backgroundColor = color }
        if let color = color(style["accent"]) { view.tintColor = color }
        if let color = color(style["border"]) {
            view.layer.borderColor = color.cgColor
            view.layer.borderWidth = max(1, base.borderWidth)
        }
        if let radius = number(style["radius"]) {
            view.layer.cornerRadius = CGFloat(min(64, max(0, radius)))
        }
        ensureMinimumHitTarget(on: view, scale: scale)
    }

    private func restore(_ base: Baseline, to view: UIView) {
        view.transform = base.transform
        view.backgroundColor = base.background
        view.tintColor = base.tint
        view.layer.borderColor = base.border
        view.layer.borderWidth = base.borderWidth
        view.layer.cornerRadius = base.radius
        setForeground(base.foreground, on: view)
        setFontSize(base.fontSize, on: view)
    }

    private func enforceSafety(semanticId: String, on view: UIView) {
        if safetyIds.contains(semanticId) {
            view.alpha = max(view.alpha, 0.8)
            view.isHidden = false
            view.isUserInteractionEnabled = true
        }
    }

    private func ensureMinimumHitTarget(on view: UIView, scale: Double) {
        if view is UIControl {
            let identity = ObjectIdentifier(view)
            // UIView transforms also shrink hit testing. Compensate the pre-transform layout
            // whenever an administrator selects scale < 1 so the effective target stays 44pt.
            let minimumHitTarget = CGFloat(scale < 1 ? 44 / scale : 44)
            if let constraints = minimumSizeConstraints[identity] {
                constraints.width.constant = minimumHitTarget
                constraints.height.constant = minimumHitTarget
            } else {
                let width = view.widthAnchor.constraint(
                    greaterThanOrEqualToConstant: minimumHitTarget)
                let height = view.heightAnchor.constraint(
                    greaterThanOrEqualToConstant: minimumHitTarget)
                width.isActive = true
                height.isActive = true
                minimumSizeConstraints[identity] = (width, height)
            }
        }
    }

    private func snapshot(of view: UIView) -> Baseline {
        let foreground: UIColor?
        let fontSize: CGFloat?
        if let button = view as? UIButton {
            foreground = button.titleColor(for: .normal)
            fontSize = button.titleLabel?.font.pointSize
        } else if let label = view as? UILabel {
            foreground = label.textColor
            fontSize = label.font.pointSize
        } else {
            foreground = nil
            fontSize = nil
        }
        return Baseline(transform: view.transform,
                        background: view.backgroundColor,
                        validationBackground: effectiveBackground(for: view),
                        foreground: foreground, tint: view.tintColor,
                        border: view.layer.borderColor,
                        borderWidth: view.layer.borderWidth,
                        radius: view.layer.cornerRadius,
                        fontSize: fontSize)
    }

    private func rebaseOwnerValues(in state: inout StyleState, from view: UIView) {
        guard let last = state.lastApplied else { return }
        let current = snapshot(of: view)
        if current.transform != last.transform { state.baseline.transform = current.transform }
        if !same(current.background, last.background) {
            state.baseline.background = current.background
            state.baseline.validationBackground = current.validationBackground
        }
        if !same(current.foreground, last.foreground) { state.baseline.foreground = current.foreground }
        if !same(current.tint, last.tint) { state.baseline.tint = current.tint }
        if !same(current.border, last.border) { state.baseline.border = current.border }
        if current.borderWidth != last.borderWidth { state.baseline.borderWidth = current.borderWidth }
        if current.radius != last.radius { state.baseline.radius = current.radius }
        if current.fontSize != last.fontSize { state.baseline.fontSize = current.fontSize }
    }

    private func same(_ first: UIColor?, _ second: UIColor?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case let (a?, b?): return a.isEqual(b)
        default: return false
        }
    }

    private func same(_ first: CGColor?, _ second: CGColor?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case let (a?, b?): return a == b
        default: return false
        }
    }

    private func validate(_ style: [String: Any], semanticId: String,
                          baseline: Baseline) -> Bool {
        return validationError(style, semanticId: semanticId, baseline: baseline) == nil
    }

    private func validationError(_ style: [String: Any], semanticId: String,
                                 baseline: Baseline) -> String? {
        guard style.keys.allSatisfy({ allowed.contains($0) }) else {
            return "unsupported_property"
        }
        for key in ["scale", "font_scale"] {
            if let value = style[key] {
                guard let n = number(value), n >= 0.75, n <= 2 else {
                    return "invalid_\(key)"
                }
            }
        }
        if let value = style["radius"] {
            guard let n = number(value), n >= 0, n <= 64 else { return "invalid_radius" }
        }
        for key in ["foreground", "background", "accent", "border"] {
            if let value = style[key], color(value) == nil { return "invalid_\(key)" }
        }
        if safetyIds.contains(semanticId) {
            if let scale = number(style["scale"]), scale < 1 {
                return "safety_minimum_scale"
            }
            if let fontScale = number(style["font_scale"]), fontScale < 1 {
                return "safety_minimum_font_scale"
            }
        }

        let foreground = color(style["foreground"]) ?? baseline.foreground
        let background = color(style["background"]) ?? baseline.validationBackground
        let accent = color(style["accent"]) ?? baseline.tint
        let baselineBorder = baseline.border.flatMap { UIColor(cgColor: $0) }
        let border = color(style["border"]) ?? baselineBorder
        if style["foreground"] != nil || style["background"] != nil {
            guard let fg = foreground, let bg = background, contrast(fg, bg) >= 4.5 else {
                return "text_contrast"
            }
        }
        if style["accent"] != nil || style["background"] != nil {
            guard let accent = accent, let bg = background, contrast(accent, bg) >= 3 else {
                return "control_contrast"
            }
        }
        if style["border"] != nil || (style["background"] != nil && baseline.borderWidth > 0) {
            guard let border = border, let bg = background, contrast(border, bg) >= 3 else {
                return "border_contrast"
            }
        }
        return nil
    }

    private func effectiveBackground(for view: UIView) -> UIColor? {
        var current: UIView? = view
        while let candidate = current {
            if let background = candidate.backgroundColor {
                var alpha: CGFloat = 0
                background.getWhite(nil, alpha: &alpha)
                if alpha == 0 {
                    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
                    if background.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
                       alpha > 0 { return background }
                } else {
                    return background
                }
            }
            current = candidate.superview
        }
        return nil
    }

    private func save(_ style: [String: Any], nodeId: String, semanticId: String) -> Bool {
        guard JSONSerialization.isValidJSONObject(style),
              let data = try? JSONSerialization.data(withJSONObject: style) else { return false }
        UserDefaults.standard.set(data, forKey: "ui.lkg.\(nodeId).\(semanticId)")
        return UserDefaults.standard.synchronize()
    }

    private func load(nodeId: String, semanticId: String) -> [String: Any]? {
        guard let data = UserDefaults.standard.data(forKey: "ui.lkg.\(nodeId).\(semanticId)")
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private func color(_ value: Any?) -> UIColor? {
        guard var text = value as? String, text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.count == 6, let raw = UInt64(text, radix: 16) else { return nil }
        let r = (raw >> 16) & 0xff
        let g = (raw >> 8) & 0xff
        let b = raw & 0xff
        return UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                       blue: CGFloat(b) / 255, alpha: 1)
    }

    private func contrast(_ first: UIColor, _ second: UIColor) -> Double {
        func luminance(_ color: UIColor) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func setForeground(_ color: UIColor?, on view: UIView) {
        guard let color = color else { return }
        if let button = view as? UIButton { button.setTitleColor(color, for: .normal) }
        if let label = view as? UILabel { label.textColor = color }
    }

    private func setFontSize(_ size: CGFloat?, on view: UIView) {
        guard let size = size else { return }
        if let button = view as? UIButton, let font = button.titleLabel?.font {
            button.titleLabel?.font = font.withSize(size)
        }
        if let label = view as? UILabel { label.font = label.font.withSize(size) }
    }

    private func record(semanticId: String, source: String, applied: Bool, rejected: Bool,
                        persisted: Bool, error: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        UIStyleApplier.reportLock.lock()
        let previous = UIStyleApplier.outcomes[semanticId]
        let outcome: [String: Any] = [
            "source": source,
            "applied": applied,
            "rejected": rejected,
            "lkg_persisted": persisted,
            "error": error,
        ]
        UIStyleApplier.outcomes[semanticId] = outcome
        UIStyleApplier.lastError = UIStyleApplier.outcomes.keys.sorted().compactMap { id in
            guard let value = UIStyleApplier.outcomes[id]?["error"] as? String,
                  !value.isEmpty else { return nil }
            return "\(id):\(value)"
        }.last ?? ""
        UIStyleApplier.updatedAtMs = now
        UIStyleApplier.reportLock.unlock()
        if !NSDictionary(dictionary: previous ?? [:]).isEqual(to: outcome) {
            NotificationCenter.default.post(name: UIStyleApplier.reportChanged, object: nil)
        }
    }
}
