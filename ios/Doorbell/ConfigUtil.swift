import Foundation
import UIKit

enum ConfigUtil {

    static func dig(_ root: [String: Any]?, _ dotpath: String) -> Any? {
        var cur: Any? = root
        for part in dotpath.split(separator: ".") {
            guard let d = cur as? [String: Any] else { return nil }
            cur = d[String(part)]
            if cur == nil { return nil }
        }
        if cur is NSNull { return nil }
        return cur
    }

    static func str(_ root: [String: Any]?, _ dotpath: String) -> String? {
        guard let v = dig(root, dotpath) else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : s }
        return "\(v)"
    }

    static func int(_ root: [String: Any]?, _ dotpath: String, _ def: Int) -> Int {
        guard let v = dig(root, dotpath) else { return def }
        if let n = v as? NSNumber { return n.intValue }
        return Int("\(v)") ?? def
    }

    static func double(_ root: [String: Any]?, _ dotpath: String, _ def: Double) -> Double {
        guard let v = dig(root, dotpath) else { return def }
        if let n = v as? NSNumber { return n.doubleValue }
        return Double("\(v)") ?? def
    }

    static func bool(_ root: [String: Any]?, _ dotpath: String, _ def: Bool) -> Bool {
        guard let v = dig(root, dotpath) else { return def }
        if let n = v as? NSNumber { return n.boolValue }
        return def
    }

    static func sortedByOrder(_ map: [String: Any]) -> [String] {
        func orderOf(_ id: String) -> Int {
            guard let e = map[id] as? [String: Any],
                  let v = e["order"] as? NSNumber else { return 999 }
            return v.intValue
        }
        return map.keys.sorted { a, b in
            let (oa, ob) = (orderOf(a), orderOf(b))
            return oa != ob ? oa < ob : a < b
        }
    }

    static func labelOf(_ entry: [String: Any]?, _ lang: String, _ fallback: String) -> String {
        guard let label = entry?["label"] as? [String: Any] else { return fallback }
        if let s = label[lang] as? String, !s.isEmpty { return s }
        if let s = label["ja"] as? String, !s.isEmpty { return s }
        return fallback
    }

    static func evStr(_ ev: [String: Any], _ key: String) -> String {
        if let s = ev[key] as? String { return s }
        if let v = ev[key], !(v is NSNull) { return "\(v)" }
        return ""
    }

    static func evBool(_ ev: [String: Any], _ key: String) -> Bool {
        if let b = ev[key] as? Bool { return b }
        if let n = ev[key] as? NSNumber { return n.boolValue }
        return false
    }

    /// A legacy device-alert without an explicit channel remains an in-app alert. New events
    /// always carry the rule-selected channel list, which clients must not collapse together.
    static func eventChannels(_ ev: [String: Any]) -> Set<String> {
        guard let raw = ev["channels"] as? [Any] else { return ["in_app"] }
        return Set(raw.compactMap { $0 as? String })
    }

    static func eventUsesChannel(_ ev: [String: Any], _ channel: String) -> Bool {
        return eventChannels(ev).contains(channel)
    }

    static func findDoorPeer(_ st: [String: Any]?, door: String) -> [String: Any]? {
        guard let peers = st?["peers"] as? [[String: Any]] else { return nil }
        for p in peers {
            if (p["self"] as? Bool) == true { continue }
            if evStr(p, "role") != "door_station" { continue }
            if !door.isEmpty && evStr(p, "door") != door { continue }
            if evStr(p, "status") == "dead" { continue }
            return p
        }
        return nil
    }

    static func peerHost(_ peer: [String: Any]?) -> String? {
        guard let addrs = peer?["addrs"] as? [Any] else { return nil }
        for a in addrs {
            guard let s = a as? String, !s.isEmpty else { continue }
            if let i = s.range(of: ":", options: .backwards) {
                let host = String(s[s.startIndex..<i.lowerBound])
                return host.isEmpty ? nil : host
            }
            return s
        }
        return nil
    }

    static func parseHexColor(_ s: String) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        var hex = s
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return (CGFloat((v >> 16) & 0xFF) / 255.0,
                CGFloat((v >> 8) & 0xFF) / 255.0,
                CGFloat(v & 0xFF) / 255.0)
    }

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
