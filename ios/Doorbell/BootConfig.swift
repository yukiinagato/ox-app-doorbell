// boot.json — 端末ローカルの起動設定 (WPF/Android の BootConfig と同形式)。
// fleet 設定は core が CRDT で持つ。無ければ既定を書き出す (管理者が編集できるように)。
// iOS: Documents/boot.json (Files app / Ad Hoc 配布時は Finder 経由で編集可能)。
// tvOS: ローカル保存は Caches のみ (OS が随時掃除する) — boot.json の内容は
//       UserDefaults (tvOS の恒久 500KB 枠) に持ち、data_dir は Caches を使う。
//       CRDT 設定は mesh から自動復元されるため Caches 消滅は自愈する。
import Foundation

struct BootConfig {
    var rawJson = "{}"
    var name = "doorbell"
    var role = "door_station"
    var door = ""
    var uiLang = "ja"
    var kiosk = true
    var httpPort = 47180  // 自機 httpd (資産取得 /asset/<hash> に使う)

    #if os(tvOS)
    private static let defaultJson =
        "{ \"name\": \"doorbell-tv\", \"role\": \"indoor_panel\", \"door\": \"\", " +
        "\"listen_port\": 47172, \"http_port\": 47180, \"ui_lang\": \"ja\", \"kiosk\": false }"
    private static let defaultsKey = "boot_json"
    #else
    private static let defaultJson =
        "{ \"name\": \"doorbell-ios\", \"role\": \"door_station\", \"door\": \"\", " +
        "\"listen_port\": 47172, \"http_port\": 47180, \"ui_lang\": \"ja\", \"kiosk\": false }"
    #endif

    /// core の data_dir (iOS: Documents / tvOS: Caches — ヘッダコメント参照)。
    static func dataDir() -> String {
        #if os(tvOS)
        let dir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
        #else
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        #endif
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load() -> BootConfig {
        var c = BootConfig()
        #if os(tvOS)
        if let s = UserDefaults.standard.string(forKey: defaultsKey), !s.isEmpty {
            c.rawJson = s
        } else {
            c.rawJson = defaultJson
            UserDefaults.standard.set(defaultJson, forKey: defaultsKey)
        }
        #else
        let path = (dataDir() as NSString).appendingPathComponent("boot.json")
        if let s = try? String(contentsOfFile: path, encoding: .utf8), !s.isEmpty {
            c.rawJson = s
        } else {
            c.rawJson = defaultJson
            try? defaultJson.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #endif
        if let data = c.rawJson.data(using: .utf8),
           let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            c.name = d["name"] as? String ?? c.name
            c.role = d["role"] as? String ?? c.role
            c.door = d["door"] as? String ?? c.door
            c.uiLang = d["ui_lang"] as? String ?? c.uiLang
            c.kiosk = d["kiosk"] as? Bool ?? c.kiosk
            if let p = d["http_port"] as? Int, p > 0 { c.httpPort = p }
        }
        return c
    }
}
