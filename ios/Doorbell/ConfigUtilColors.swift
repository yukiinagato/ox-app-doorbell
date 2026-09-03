import UIKit

// The colour half of ConfigUtil. It lives apart from the parsing half because the parsing half is
// compiled for the host by the kiosk's test suite, where UIKit does not exist — putting one
// UIColor in the same file silently turned a Swift contract test into a skip. Nothing here reads
// configuration in a new way; it only turns values ConfigUtil already parsed into colours.
extension ConfigUtil {

    static func emergencyPalette(_ event: [String: Any]) ->
        (background: UIColor, foreground: UIColor, accent: UIColor, limitation: String) {
        let defaults = (background: UIColor(red: 0.55, green: 0.05, blue: 0.04, alpha: 1),
                        foreground: UIColor.white, accent: UIColor.white,
                        limitation: "")
        let backgroundValue = evStr(event, "background")
        let foregroundValue = evStr(event, "foreground")
        let accentValue = evStr(event, "accent")
        if backgroundValue.isEmpty && foregroundValue.isEmpty && accentValue.isEmpty {
            return defaults
        }
        guard let background = exactPresentationColor(backgroundValue,
                fallback: defaults.background),
              let foreground = exactPresentationColor(foregroundValue,
                fallback: defaults.foreground),
              let accent = exactPresentationColor(accentValue, fallback: defaults.accent),
              contrast(foreground, background) >= 4.5,
              contrast(accent, background) >= 3.0 else {
            return (defaults.background, defaults.foreground, defaults.accent,
                    "invalid_emergency_presentation_colors")
        }
        return (background, foreground, accent, "")
    }

    static func readableTextColor(on background: UIColor) -> UIColor {
        return contrast(.black, background) >= 4.5 ? .black : .white
    }

    private static func exactPresentationColor(_ value: String, fallback: UIColor) -> UIColor? {
        if value.isEmpty { return fallback }
        guard value.count == 7, value.hasPrefix("#"),
              let rgb = parseHexColor(value) else { return nil }
        return UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

    private static func contrast(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        func linear(_ value: CGFloat) -> CGFloat {
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
