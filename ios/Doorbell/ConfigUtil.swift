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

    /// The label in `lang`, then the Japanese one, then the entry's own `name` (a device record
    /// has a name and no label), and only then the fallback, which is usually a raw id.
    static func labelOf(_ entry: [String: Any]?, _ lang: String, _ fallback: String) -> String {
        if let label = entry?["label"] as? [String: Any] {
            if let s = label[lang] as? String, !s.isEmpty { return s }
            if let s = label["ja"] as? String, !s.isEmpty { return s }
        }
        if let name = entry?["name"] as? String, !name.isEmpty { return name }
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

    /// The door station to bind a call to: an alive station first, then a suspect one. A dead
    /// station is never chosen. Within a rank the projection order is kept.
    static func findDoorPeer(_ st: [String: Any]?, door: String) -> [String: Any]? {
        guard let peers = st?["peers"] as? [[String: Any]] else { return nil }
        let candidates = peers.filter { p in
            (p["self"] as? Bool) != true && evStr(p, "role") == "door_station" &&
                (door.isEmpty || evStr(p, "door") == door) && evStr(p, "status") != "dead"
        }
        return candidates.first { evStr($0, "status") == "alive" } ?? candidates.first
    }

    static func onlineDoorPeer(_ status: [String: Any]?, door: String) -> [String: Any]? {
        guard let peers = status?["peers"] as? [[String: Any]] else { return nil }
        return peers.first {
            ($0["self"] as? Bool) != true && evStr($0, "role") == "door_station" &&
                evStr($0, "door") == door && evStr($0, "status") == "alive"
        }
    }

    /// Configured doors that no reachable station serves. A door whose station has a peer record
    /// is listed through that record; a configured door with no station record at all is listed
    /// as a synthetic entry (`id` empty, `status` "missing"), so it is visible somewhere instead
    /// of vanishing from both the dashboard and this list.
    static func offlineDoorPeers(config: [String: Any]?, status: [String: Any]?) -> [[String: Any]] {
        let peers = status?["peers"] as? [[String: Any]] ?? []
        let doorMap = dig(config, "doors") as? [String: Any] ?? [:]
        let configuredDoors = Set(doorMap.keys)
        let onlineDoors = Set(peers.filter {
            evStr($0, "role") == "door_station" && evStr($0, "status") == "alive"
        }.map { evStr($0, "door") })
        var listed = peers.filter {
            ($0["self"] as? Bool) != true && evStr($0, "role") == "door_station" &&
                evStr($0, "status") != "alive" && configuredDoors.contains(evStr($0, "door")) &&
                !onlineDoors.contains(evStr($0, "door"))
        }
        let recordedDoors = Set(peers.filter { evStr($0, "role") == "door_station" }
            .map { evStr($0, "door") })
        for door in configuredDoors.subtracting(recordedDoors).subtracting(onlineDoors) {
            listed.append(["id": "", "role": "door_station", "door": door,
                           "status": "missing", "name": ""])
        }
        return listed.sorted {
            let left = evStr($0, "name")
            let right = evStr($1, "name")
            return left == right ? evStr($0, "id") < evStr($1, "id") : left < right
        }
    }

    /// Whether a door station has a camera to watch. A peer that says nothing about it is
    /// assumed to have one: every door station shipped so far does, and hiding a tile because a
    /// field is missing would take a working camera off the dashboard.
    static func doorHasCamera(_ peer: [String: Any]?) -> Bool {
        guard let peer = peer else { return true }
        return bool(peer, "caps.camera", true)
    }

    /// Configured doors with an online camera station. Removed cluster members and offline peers
    /// are excluded; offline peers remain available from the secondary offline-device screen.
    static func doorsWithCamera(config: [String: Any]?, status: [String: Any]?) -> [String] {
        let doors = (dig(config, "doors") as? [String: Any]).map { sortedByOrder($0) } ?? []
        return doors.filter { door in
            guard let peer = onlineDoorPeer(status, door: door) else { return false }
            return doorHasCamera(peer)
        }
    }

    /// The host of a peer's first usable address. Addresses are `host:port`, `[v6]:port`, or a
    /// bare host; a bare IPv6 address contains colons and is returned whole.
    static func peerHost(_ peer: [String: Any]?) -> String? {
        guard let addrs = peer?["addrs"] as? [Any] else { return nil }
        for a in addrs {
            guard let s = a as? String, !s.isEmpty else { continue }
            if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
                let host = String(s[s.index(after: s.startIndex)..<close])
                if !host.isEmpty { return host }
                continue
            }
            let colons = s.filter { $0 == ":" }.count
            if colons > 1 { return s }
            if colons == 1, let i = s.firstIndex(of: ":") {
                let host = String(s[s.startIndex..<i])
                if !host.isEmpty { return host }
                continue
            }
            return s
        }
        return nil
    }

    /// Browsers reach a peer's Admin over its TLS listener (security protocol v3 §7). The stream
    /// URL is a loopback proxy on this device, so the address comes from the peer record.
    static let peerAdminHttpsPort = 47443

    static func peerAdminURL(_ peer: [String: Any]?) -> String? {
        guard let host = peerHost(peer) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = peerAdminHttpsPort
        components.path = "/admin/"
        return components.url?.absoluteString
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
