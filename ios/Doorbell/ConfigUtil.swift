import CoreGraphics
import Foundation

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

    /// Every visit purpose an administrator configured, offered or not, in the configured order.
    /// The settings list needs all of them: a purpose that is switched off is exactly the one a
    /// household wants to find and switch back on.
    static func allPurposeIds(_ config: [String: Any]?) -> [String] {
        guard let purposes = dig(config, "visit_purposes") as? [String: Any] else { return [] }
        return sortedByOrder(purposes)
    }

    /// The purposes a visitor is actually offered. `visit_purposes.<id>.enabled` is the single
    /// switch behind that, and a purpose that has never been switched off carries no such key —
    /// on a seeded cluster and on an older one alike — so an absent value means offered.
    static func enabledPurposeIds(_ config: [String: Any]?) -> [String] {
        guard let purposes = dig(config, "visit_purposes") as? [String: Any] else { return [] }
        return sortedByOrder(purposes).filter {
            purposeIsEnabled(purposes[$0] as? [String: Any])
        }
    }

    static func purposeIsEnabled(_ entry: [String: Any]?) -> Bool {
        return bool(entry, "enabled", true)
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

    /// Whether this device offers the SOS slider at all. Core's default is the indoor panel
    /// alone; a configured `emergency.button_on_roles` replaces that outright, an empty list
    /// included — that is how an administrator takes the slider off every screen.
    static func sosButtonVisible(config: [String: Any]?, role: String) -> Bool {
        guard let roles = dig(config, "emergency.button_on_roles") as? [Any] else {
            return role == "indoor_panel"
        }
        return roles.contains { ($0 as? String) == role }
    }

    static func parseHexColor(_ s: String) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        var hex = s
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return (CGFloat((v >> 16) & 0xFF) / 255.0,
                CGFloat((v >> 8) & 0xFF) / 255.0,
                CGFloat(v & 0xFF) / 255.0)
    }
}
