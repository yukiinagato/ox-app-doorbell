import UIKit

/// Light/dark appearance, the ink and accent colours that go with it, and the small shared
/// drawing rules every batch-2 surface follows: padded coloured labels, deliberate two-part
/// labels, and one version/battery footer line.
///
/// Core publishes `display.theme.auto_ink` and `display.theme.auto_accent` so every shell agrees
/// on the same computed colours. When those fields are absent — an older Core, or a background
/// the node has not measured yet — the same arithmetic runs locally, which is why the maths lives
/// here rather than behind a Core call.
enum DoorbellAppearance: String {
    case light
    case dark
}

struct DoorbellPalette {
    let appearance: DoorbellAppearance
    let background: UIColor
    let surface: UIColor
    let surfaceStrong: UIColor
    let ink: UIColor
    let inkMuted: UIColor
    let accent: UIColor
    let onAccent: UIColor
    let notice: UIColor
    let danger: UIColor
    let separator: UIColor

    static let dark = DoorbellPalette(
        appearance: .dark,
        background: UIColor(red: 0.063, green: 0.078, blue: 0.094, alpha: 1),
        surface: UIColor(white: 1, alpha: 0.10),
        surfaceStrong: UIColor(white: 1, alpha: 0.16),
        ink: UIColor(white: 0.94, alpha: 1),
        inkMuted: UIColor(white: 0.66, alpha: 1),
        accent: UIColor(red: 1.0, green: 0.80, blue: 0.25, alpha: 1),
        onAccent: .black,
        notice: UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1),
        danger: UIColor(red: 0.88, green: 0.36, blue: 0.30, alpha: 1),
        separator: UIColor(white: 1, alpha: 0.12))

    static let light = DoorbellPalette(
        appearance: .light,
        background: UIColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1),
        surface: UIColor(white: 0, alpha: 0.06),
        surfaceStrong: UIColor(white: 0, alpha: 0.10),
        ink: UIColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1),
        inkMuted: UIColor(red: 0.36, green: 0.38, blue: 0.41, alpha: 1),
        accent: UIColor(red: 0.16, green: 0.33, blue: 0.72, alpha: 1),
        onAccent: .white,
        notice: UIColor(red: 0.13, green: 0.36, blue: 0.60, alpha: 1),
        danger: UIColor(red: 0.72, green: 0.16, blue: 0.13, alpha: 1),
        separator: UIColor(white: 0, alpha: 0.14))

    static func of(_ appearance: DoorbellAppearance) -> DoorbellPalette {
        return appearance == .light ? .light : .dark
    }
}

enum DoorbellTheme {

    static let changed = Notification.Name("DoorbellThemeChanged")

    // MARK: - Appearance resolution

    /// Resolves `display.appearance` (with the per-device override) into a concrete appearance.
    /// `auto_system` needs a system dark mode; on a runtime that has none it degrades to the
    /// schedule, exactly like the iPad 1 kiosk and old Android shells do.
    static func appearance(config: [String: Any]?, nodeId: String,
                           localTime: [String: Any]?) -> DoorbellAppearance {
        var mode = ConfigUtil.str(config, "display.appearance") ?? "auto_system"
        if !nodeId.isEmpty,
           let override = ConfigUtil.str(config, "devices.\(nodeId).local.display.appearance") {
            mode = override
        }
        switch mode {
        case "light": return .light
        case "dark": return .dark
        case "auto_schedule": return scheduled(config: config, localTime: localTime)
        default:
            if #available(iOS 13.0, tvOS 13.0, *) {
                let style = UITraitCollection.current.userInterfaceStyle
                if style == .dark { return .dark }
                if style == .light { return .light }
            }
            return scheduled(config: config, localTime: localTime)
        }
    }

    private static func scheduled(config: [String: Any]?,
                                  localTime: [String: Any]?) -> DoorbellAppearance {
        let darkFrom = minutes(ConfigUtil.str(config, "display.appearance_schedule.dark_from")
            ?? "19:00") ?? 19 * 60
        let lightFrom = minutes(ConfigUtil.str(config, "display.appearance_schedule.light_from")
            ?? "06:30") ?? 6 * 60 + 30
        let hh = ConfigUtil.int(localTime, "hh", -1)
        guard hh >= 0 else { return .dark }
        let now = hh * 60 + ConfigUtil.int(localTime, "mm", 0)
        if darkFrom == lightFrom { return .dark }
        if darkFrom < lightFrom {
            return (now >= darkFrom && now < lightFrom) ? .dark : .light
        }
        return (now >= darkFrom || now < lightFrom) ? .dark : .light
    }

    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    // MARK: - Colour arithmetic (WCAG 2.x relative luminance)

    static func color(hex: String?) -> UIColor? {
        guard let hex = hex, let rgb = ConfigUtil.parseHexColor(hex) else { return nil }
        return UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

    static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
        let clamp = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", clamp(r), clamp(g), clamp(b))
    }

    static func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        func linear(_ v: CGFloat) -> CGFloat {
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    static func contrast(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Average colour of an image region, used when the theme background is a picture. The area is
    /// reduced to at most 16x16 before averaging, as the cross-platform rule requires.
    static func averageColor(of image: UIImage, in rect: CGRect? = nil) -> UIColor? {
        guard let cg = image.cgImage else { return nil }
        let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let area = (rect.map { full.intersection($0) } ?? full).integral
        guard area.width >= 1, area.height >= 1,
              let cropped = cg.cropping(to: area) else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0, g = 0, b = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            r += Int(pixels[index]); g += Int(pixels[index + 1]); b += Int(pixels[index + 2])
        }
        let count = CGFloat(side * side)
        return UIColor(red: CGFloat(r) / 255 / count, green: CGFloat(g) / 255 / count,
                       blue: CGFloat(b) / 255 / count, alpha: 1)
    }

    /// Ink for one semantic region. Core's `display.theme.auto_ink` wins; an administrator's
    /// `ink_override` wins over both. Without either, the luminance of the region background
    /// decides, which is the same rule Core applies.
    static func ink(config: [String: Any]?, nodeId: String, region: String,
                    background: UIColor, palette: DoorbellPalette) -> UIColor {
        if !nodeId.isEmpty,
           let override = color(hex: ConfigUtil.str(
                config, "devices.\(nodeId).local.theme.ink_override.\(region)")) {
            return override
        }
        if let override = color(hex: ConfigUtil.str(config,
                                                    "display.theme.ink_override.\(region)")) {
            return override
        }
        if let published = ConfigUtil.str(config, "display.theme.auto_ink.\(region)") {
            if published == "dark" { return DoorbellPalette.light.ink }
            if published == "light" { return DoorbellPalette.dark.ink }
        }
        return luminance(background) >= 0.5 ? DoorbellPalette.light.ink : DoorbellPalette.dark.ink
    }

    /// A one-pixel outline is added only when the chosen ink still misses AA against the region
    /// background; it uses the opposite ink at 40 %.
    static func applyInk(_ ink: UIColor, over background: UIColor, to label: UILabel) {
        label.textColor = ink
        guard contrast(ink, background) < 4.5 else {
            label.shadowColor = nil
            label.shadowOffset = .zero
            return
        }
        let opposite = luminance(ink) >= 0.5 ? UIColor.black : UIColor.white
        label.shadowColor = opposite.withAlphaComponent(0.4)
        label.shadowOffset = CGSize(width: 0, height: 1)
    }

    /// Call-button colour for a door station: the complement of the effective background, moved in
    /// lightness until the button separates from the background (3:1) and its text is readable
    /// (4.5:1). Dark directions are tried first on a light background.
    static func autoAccent(on background: UIColor) -> (fill: UIColor, ink: UIColor) {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        if !background.getHue(&hue, saturation: &saturation, brightness: &brightness,
                              alpha: &alpha) {
            return (DoorbellPalette.dark.accent, .black)
        }
        let rotated = hue + 0.5 > 1 ? hue - 0.5 : hue + 0.5
        let saturated = max(0.45, min(1, saturation + 0.25))
        let backgroundIsLight = luminance(background) >= 0.5
        let order: [CGFloat] = backgroundIsLight
            ? [0.18, 0.24, 0.30, 0.38, 0.46, 0.60, 0.74, 0.88]
            : [0.88, 0.80, 0.72, 0.62, 0.52, 0.40, 0.30, 0.20]
        var best = UIColor(hue: rotated, saturation: saturated, brightness: order[0], alpha: 1)
        var bestScore: CGFloat = -1
        for level in order {
            let candidate = UIColor(hue: rotated, saturation: saturated, brightness: level,
                                    alpha: 1)
            let ink = readableInk(on: candidate)
            let separation = contrast(candidate, background)
            let legibility = contrast(ink, candidate)
            if separation >= 3 && legibility >= 4.5 {
                return (candidate, ink)
            }
            let score = min(separation / 3, 1) + min(legibility / 4.5, 1)
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return (best, readableInk(on: best))
    }

    static func readableInk(on background: UIColor) -> UIColor {
        return contrast(.black, background) >= contrast(.white, background) ? .black : .white
    }

    /// Effective call-button colour: administrator override first, then Core's published value,
    /// then the local computation. The returned ink always matches the fill.
    static func callButtonColors(config: [String: Any]?, nodeId: String,
                                 background: UIColor) -> (fill: UIColor, ink: UIColor) {
        if !nodeId.isEmpty,
           let override = color(hex: ConfigUtil.str(
                config, "devices.\(nodeId).local.theme.call_button_bg")) {
            return (override, readableInk(on: override))
        }
        if let override = color(hex: ConfigUtil.str(config, "display.theme.call_button_bg")) {
            return (override, readableInk(on: override))
        }
        if let published = color(hex: ConfigUtil.str(config,
                                                     "display.theme.auto_accent.call_button")) {
            return (published, readableInk(on: published))
        }
        return autoAccent(on: background)
    }

    /// Soft WCAG advice for a colour an administrator typed. Nil means the pair passes; the string
    /// is the localized warning, and the value is never rejected.
    static func contrastWarning(_ texts: Texts, foreground: UIColor, background: UIColor,
                                largeText: Bool = false) -> String? {
        let ratio = contrast(foreground, background)
        let needed: CGFloat = largeText ? 3.0 : 4.5
        guard ratio < needed else { return nil }
        return texts.t("theme.contrast_warning", String(format: "%.1f", Double(ratio)))
    }

    // MARK: - Shared drawing rules

    /// Every coloured-background text gets 6pt vertical / 12pt horizontal padding and a radius.
    static func pill(_ label: PaddedLabel, background: UIColor, ink: UIColor,
                     fontSize: CGFloat = 16, bold: Bool = true) {
        label.insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        label.backgroundColor = background
        label.textColor = ink
        label.font = bold ? .systemFont(ofSize: fontSize, weight: .semibold)
            : .systemFont(ofSize: fontSize)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.numberOfLines = 0
    }

    /// Deliberate two-part label: the text carries "\n", and the second line renders smaller and
    /// muted rather than wrapping mid-phrase.
    static func twoPart(_ text: String, primarySize: CGFloat, color: UIColor,
                        bold: Bool = true) -> NSAttributedString {
        let parts = text.components(separatedBy: "\n")
        let primaryFont: UIFont = bold ? .systemFont(ofSize: primarySize, weight: .semibold)
            : .systemFont(ofSize: primarySize)
        let result = NSMutableAttributedString(
            string: parts[0],
            attributes: [.font: primaryFont, .foregroundColor: color])
        guard parts.count > 1 else { return result }
        let secondary = parts.dropFirst().joined(separator: " ")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        result.addAttributes([.paragraphStyle: paragraph],
                             range: NSRange(location: 0, length: result.length))
        result.append(NSAttributedString(
            string: "\n" + secondary,
            attributes: [.font: UIFont.systemFont(ofSize: primarySize * 0.8),
                         .foregroundColor: color.withAlphaComponent(0.72),
                         .paragraphStyle: paragraph]))
        return result
    }

    /// Footer identity line: `name · core vX · app vY · battery`. The battery part disappears on a
    /// device that reports none, and a charging device is marked.
    static func versionLine(name: String, coreVersion: String, texts: Texts,
                            power: [String: Any]?) -> String {
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }
        parts.append("core v" + (coreVersion.isEmpty ? "-" : coreVersion))
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "-"
        parts.append("app v" + app)
        let percent = ConfigUtil.int(power, "battery_pct", -1)
        if percent >= 0 {
            var battery = "\(percent)%"
            if ConfigUtil.bool(power, "charging", false) {
                battery += " " + texts.t("power.charging")
            }
            parts.append(battery)
        }
        return parts.joined(separator: " · ")
    }

    static func coreVersion() -> String {
        guard let raw = db_core_version() else { return "" }
        return String(cString: raw)
    }
}
