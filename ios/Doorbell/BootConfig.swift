import Foundation

struct BootConfig {
    var rawJson = "{}"
    var name = "doorbell"
    var role = "door_station"
    var door = ""
    var uiLang = "ja"
    var kiosk = true
    var httpPort = 47180
    var setupRequired = false
    var suggestedDoor = ""

    #if os(tvOS)
    private static let defaultJson =
        "{ \"name\": \"doorbell-tv\", \"role\": \"indoor_panel\", \"door\": \"\", " +
        "\"listen_port\": 47172, \"http_port\": 47180, \"ui_lang\": \"ja\", " +
        "\"kiosk\": false, \"setup_complete\": true }"
    private static let defaultsKey = "boot_json"
    #else
    private static let defaultJson =
        "{ \"name\": \"doorbell-ios\", \"role\": \"door_station\", \"door\": \"\", " +
        "\"listen_port\": 47172, \"http_port\": 47180, \"ui_lang\": \"ja\", " +
        "\"kiosk\": false, \"setup_complete\": false }"
    #endif

    static func dataDir() -> String {
        #if os(tvOS)
        let dir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
        #else
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        #endif
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func clearPersistedState() -> Bool {
        #if os(tvOS)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return UserDefaults.standard.synchronize()
        #else
        let dir = dataDir() as NSString
        let files = ["boot.json", "boot.json.bak", "doorbell.db", "doorbell.db-shm",
                     "doorbell.db-wal"]
        do {
            for file in files {
                let path = dir.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
            }
            return true
        } catch { return false }
        #endif
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
            c.rawJson = defaultJsonWithSuggestedDoor()
            try? c.rawJson.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #endif
        // A readable legacy profile is not proof that an operator confirmed
        // its local identity. Upgrades without the explicit marker must show
        // the setup UI once, just like a missing or invalid profile.
        var setupComplete = false
        if let data = c.rawJson.data(using: .utf8),
           let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            c.name = d["name"] as? String ?? c.name
            c.role = d["role"] as? String ?? c.role
            c.door = d["door"] as? String ?? c.door
            c.uiLang = d["ui_lang"] as? String ?? c.uiLang
            c.kiosk = d["kiosk"] as? Bool ?? c.kiosk
            if let p = d["http_port"] as? Int, p > 0 { c.httpPort = p }
            if let complete = d["setup_complete"] as? Bool { setupComplete = complete }
        }
        c.suggestedDoor = validDoor(c.door) ? c.door : suggestedDoorId()
        c.setupRequired = !setupComplete || !validRole(c.role) ||
            (c.role == "door_station" && !validDoor(c.door))
        return c
    }

    static func validRole(_ value: String) -> Bool {
        return value == "door_station" || value == "indoor_panel"
    }

    static func validDoor(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64,
              value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$",
                          options: .regularExpression) != nil else { return false }
        return true
    }

    static func suggestedDoorId() -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "door-" + String(token.prefix(8))
    }

    private static func defaultJsonWithSuggestedDoor() -> String {
        guard let data = defaultJson.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return defaultJson }
        object["door"] = suggestedDoorId()
        guard let output = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: output, encoding: .utf8) else { return defaultJson }
        return text
    }

    @discardableResult
    static func persistSetup(name: String, role: String, door: String) -> BootConfig? {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDoor = door.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validRole(normalizedRole),
              normalizedRole != "door_station" || validDoor(normalizedDoor) else { return nil }
        let normalizedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        #if os(tvOS)
        let source = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultJson
        #else
        let path = (dataDir() as NSString).appendingPathComponent("boot.json")
        let backup = (dataDir() as NSString).appendingPathComponent("boot.json.bak")
        let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? defaultJson
        #endif
        guard let data = source.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        object["name"] = normalizedName.isEmpty ? "doorbell" : normalizedName
        object["role"] = normalizedRole
        object["door"] = normalizedRole == "door_station" ? normalizedDoor : ""
        object["setup_complete"] = true
        guard JSONSerialization.isValidJSONObject(object),
              let output = try? IOSAvailability.jsonData(withJSONObject: object,
                                                         prettyPrinted: true),
              let text = String(data: output, encoding: .utf8) else { return nil }
        #if os(tvOS)
        UserDefaults.standard.set(text, forKey: defaultsKey)
        guard UserDefaults.standard.synchronize() else { return nil }
        #else
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: backup)
            try? FileManager.default.copyItem(atPath: path, toPath: backup)
        }
        do {
            try output.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            if FileManager.default.fileExists(atPath: backup) {
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.copyItem(atPath: backup, toPath: path)
            }
            return nil
        }
        #endif
        return load()
    }

    /// Move a legacy plaintext `psk_hex` out of boot.json and into the platform secure store,
    /// matching what the Android shell does. Must run before Core starts so the snapshot reports
    /// `psk_source: "secure_store"` rather than `boot_plaintext`.
    @discardableResult
    static func migrateLegacyPskIntoSecureStore() -> Bool {
        #if os(tvOS)
        let source = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultJson
        #else
        let path = (dataDir() as NSString).appendingPathComponent("boot.json")
        let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? defaultJson
        #endif
        guard let data = source.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let legacy = object["psk_hex"] as? String,
              legacy.count == 64,
              legacy.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
        else { return false }
        if Keychain.get("mesh.psk") != legacy, !Keychain.put("mesh.psk", legacy) { return false }
        let seeds = object["seed_peers"] as? [String] ?? []
        return persistPairing(secretRef: "secret:mesh.psk", seeds: seeds)
    }

    /// Drop the cluster references after `db_core_unpair`. Core owns the secret itself; the shell
    /// only clears `psk_ref` and the seed list so a restart does not rejoin. Local identity
    /// (name, role, door, setup marker) is deliberately kept: leaving a cluster is not a factory
    /// reset, unlike the administrator-initiated revocation path.
    @discardableResult
    static func clearPairing() -> Bool {
        #if os(tvOS)
        let source = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultJson
        #else
        let path = (dataDir() as NSString).appendingPathComponent("boot.json")
        let backup = (dataDir() as NSString).appendingPathComponent("boot.json.bak")
        let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? defaultJson
        #endif
        guard let data = source.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        object.removeValue(forKey: "psk_ref")
        object.removeValue(forKey: "psk_hex")
        object["seed_peers"] = [String]()
        guard JSONSerialization.isValidJSONObject(object),
              let output = try? IOSAvailability.jsonData(withJSONObject: object,
                                                         prettyPrinted: true)
        else { return false }
        #if os(tvOS)
        guard let text = String(data: output, encoding: .utf8) else { return false }
        UserDefaults.standard.set(text, forKey: defaultsKey)
        return UserDefaults.standard.synchronize()
        #else
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: backup)
            try? FileManager.default.copyItem(atPath: path, toPath: backup)
        }
        do {
            try output.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            if FileManager.default.fileExists(atPath: backup) {
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.copyItem(atPath: backup, toPath: path)
            }
            return false
        }
        #endif
    }

    /// Persist pairing without placing the mesh key in boot JSON. The caller must first store
    /// the key under `mesh.psk` using the platform secure-store callback.
    @discardableResult
    static func persistPairing(secretRef: String, seeds: [String]) -> Bool {
        var source: String
        #if os(tvOS)
        source = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultJson
        #else
        let sourcePath = (dataDir() as NSString).appendingPathComponent("boot.json")
        source = (try? String(contentsOfFile: sourcePath, encoding: .utf8)) ?? defaultJson
        #endif
        guard let data = source.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        object.removeValue(forKey: "psk_hex")
        object["psk_ref"] = secretRef
        var merged = Set(object["seed_peers"] as? [String] ?? [])
        for seed in seeds where !seed.isEmpty { merged.insert(seed) }
        object["seed_peers"] = merged.sorted()
        guard JSONSerialization.isValidJSONObject(object),
              let output = try? IOSAvailability.jsonData(withJSONObject: object,
                                                         prettyPrinted: true)
        else { return false }
        #if os(tvOS)
        guard let text = String(data: output, encoding: .utf8) else { return false }
        UserDefaults.standard.set(text, forKey: defaultsKey)
        return UserDefaults.standard.synchronize()
        #else
        let path = (dataDir() as NSString).appendingPathComponent("boot.json")
        let backup = (dataDir() as NSString).appendingPathComponent("boot.json.bak")
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: backup)
            try? FileManager.default.copyItem(atPath: path, toPath: backup)
        }
        do {
            try output.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            if FileManager.default.fileExists(atPath: backup) {
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.copyItem(atPath: backup, toPath: path)
            }
            return false
        }
        #endif
    }
}
