// core 設定 (config_json / status_json) の共通ヘルパ — WPF CoreClient.Dig /
// Android DoorbellCore.dig と同じ流儀。UI 側の型ゆるめの取り出しをここに集約する。
import Foundation

enum ConfigUtil {

    /// 設定ツリーをドットパスで辿る ("doors.d_front.label.ja" 等)。無ければ nil。
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

    /// 設定オブジェクト直下のキーを order 昇順 (同値は id 順) に並べる。
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

    /// ラベル多言語解決 (label.<lang> → label.ja → 既定)。
    static func labelOf(_ entry: [String: Any]?, _ lang: String, _ fallback: String) -> String {
        guard let label = entry?["label"] as? [String: Any] else { return fallback }
        if let s = label[lang] as? String, !s.isEmpty { return s }
        if let s = label["ja"] as? String, !s.isEmpty { return s }
        return fallback
    }

    /// イベント/設定の文字列取り出し ("" = 無し)。
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

    /// statusJson peers[] からこの door 担当の door_station (自分以外・生存) を返す。
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

    /// peer の addrs[0] "host:port" → host (mesh の実アドレス — Asterisk 非経由の直呼宛先)。
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

    /// "#RRGGBB" → UIColor 成分 (不正は nil)。
    static func parseHexColor(_ s: String) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        var hex = s
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return (CGFloat((v >> 16) & 0xFF) / 255.0,
                CGFloat((v >> 8) & 0xFF) / 255.0,
                CGFloat(v & 0xFF) / 255.0)
    }
}
