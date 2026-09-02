// Core invokes platform and UI callbacks on Core-owned threads. UI JSON is borrowed only for the
// callback duration, so it is copied before dispatching to the main queue. HTTPS callbacks are
// synchronous. Buffers returned through db_platform_v2 output pointers are malloc-owned and
// released through release_buffer.
import AVFoundation
import Foundation
import UIKit

typealias UiEventHandler = ([String: Any]) -> Void

final class CoreBridge {

    private var core: OpaquePointer?
    private let synth = AVSpeechSynthesizer()
    private let deviceInfoCacheLock = NSLock()
    private var deviceInfoCacheJSON =
        "{\"schema_version\":1,\"platform\":\"apple\",\"battery_state\":\"unknown\"}"

    private var handlers: [String: UiEventHandler] = [:]

    var isRunning: Bool { return core != nil }


    func start(dataDir: String, bootJson: String) -> Bool {
        if core != nil { return true }
        refreshDeviceInfoCache()
        let user = Unmanaged.passUnretained(self).toOpaque()
        var plat = db_platform_v2()
        plat.struct_size = UInt32(MemoryLayout<db_platform_v2>.size)
        plat.version = UInt32(DB_PLATFORM_V2_VERSION)
        plat.user = user
        plat.log_line = { user, level, line in
            guard user != nil, let line = line else { return }
            IOSAvailability.logCore(level: level, message: String(cString: line))
        }
        plat.tts_speak = { user, text, lang in
            guard let user = user, let text = text else { return }
            let me = Unmanaged<CoreBridge>.fromOpaque(user).takeUnretainedValue()
            let t = String(cString: text)
            let l = lang != nil ? String(cString: lang!) : "ja"
            DispatchQueue.main.async { me.speak(text: t, lang: l) }
        }
        plat.https_request = { user, method, url, headersJson, body, bodyLen, respOut, statusOut in
            guard let method = method, let url = url else { return -1 }
            return CoreBridge.httpsRequestSync(
                method: String(cString: method), url: String(cString: url),
                headersJson: headersJson != nil ? String(cString: headersJson!) : "{}",
                body: body != nil && bodyLen > 0 ? Data(bytes: body!, count: bodyLen) : Data(),
                respOut: respOut, statusOut: statusOut)
        }
        plat.secure_get = { _, key, valueOut in
            guard let key = key, let valueOut = valueOut else { return -1 }
            guard let v = Keychain.get(String(cString: key)) else { return -1 }
            valueOut.pointee = strdup(v)
            return 0
        }
        plat.secure_put = { _, key, value in
            guard let key = key, let value = value else { return -1 }
            return Keychain.put(String(cString: key), String(cString: value)) ? 0 : -1
        }
        plat.device_info = { user, valueOut in
            guard let user = user, let valueOut = valueOut else { return -1 }
            let me = Unmanaged<CoreBridge>.fromOpaque(user).takeUnretainedValue()
            let json = me.cachedDeviceInfoJSON()
            valueOut.pointee = strdup(json)
            return valueOut.pointee == nil ? -1 : 0
        }
        plat.release_buffer = { _, buffer in free(buffer) }

        core = db_core_create_v2(&plat, dataDir, bootJson)
        guard let c = core else { return false }
        db_core_set_ui_callback(c, { user, evJson in
            guard let user = user, let evJson = evJson else { return }
            let me = Unmanaged<CoreBridge>.fromOpaque(user).takeUnretainedValue()
            let data = Data(bytes: UnsafeRawPointer(evJson), count: strlen(evJson))
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }
            DispatchQueue.main.async { me.dispatch(obj) }
        }, user)
        if db_core_start(c) != 0 {
            db_core_destroy(c)
            core = nil
            return false
        }
        return true
    }

    func stop() {
        guard let c = core else { return }
        db_core_set_ui_callback(c, nil, nil)
        db_core_stop(c)
        db_core_destroy(c)
        core = nil
    }


    func addHandler(_ key: String, _ handler: @escaping UiEventHandler) {
        handlers[key] = handler
    }

    func removeHandler(_ key: String) {
        handlers.removeValue(forKey: key)
    }

    private func dispatch(_ ev: [String: Any]) {
        for h in Array(handlers.values) { h(ev) }
    }


    func press(door: String) {
        if let c = core { db_core_press(c, door) }
    }

    func pressPurpose(door: String, purpose: String) {
        if let c = core { db_core_press_purpose(c, door, purpose) }
    }

    /// Start or reuse a versioned call and return its stable identifier.
    func pressV2(door: String, purpose: String = "") -> String? {
        guard let c = core, let p = db_core_press_v2(c, door, purpose) else { return nil }
        defer { db_free(p) }
        let id = String(cString: p)
        return id.isEmpty ? nil : id
    }

    func selectPurpose(door: String, callId: String, purpose: String) -> Bool {
        guard let c = core, !callId.isEmpty else { return false }
        return db_core_select_purpose_v2(c, door, callId, purpose) == 0
    }

    func cancelCall(door: String, callId: String, reason: String = "visitor") -> Bool {
        guard let c = core, !callId.isEmpty else { return false }
        return db_core_cancel_call_v2(c, door, callId, reason) == 0
    }

    func reportCallRecovery(callId: String, restored: Bool) {
        guard let c = core, !callId.isEmpty else { return }
        db_core_report_call_recovery(c, callId, restored ? 1 : 0)
    }

    @discardableResult
    func reportCallAnswered(door: String, callId: String, stageRevision: Int) -> Bool {
        guard let c = core, !door.isEmpty, !callId.isEmpty else { return false }
        return db_core_report_call_answered_v2(c, door, callId, Int32(stageRevision)) == 0
    }

    @discardableResult
    func reportCallEnded(door: String, callId: String, stageRevision: Int,
                         reason: String = "sip_ended") -> Bool {
        guard let c = core, !door.isEmpty, !callId.isEmpty else { return false }
        return db_core_report_call_ended_v2(c, door, callId, Int32(stageRevision), reason) == 0
    }

    func setVisitorLang(door: String, lang: String) {
        if let c = core { db_core_set_visitor_lang(c, door, lang) }
    }

    func quickReply(replyId: String, door: String) {
        if let c = core, !replyId.isEmpty { db_core_quick_reply(c, replyId, door) }
    }

    func quickReplyV2(replyId: String, door: String, callId: String,
                      stageRevision: Int) -> Bool {
        guard let c = core, !replyId.isEmpty, !callId.isEmpty, stageRevision >= 0 else {
            return false
        }
        return db_core_quick_reply_v2(c, replyId, door, callId, Int32(stageRevision)) == 0
    }

    @discardableResult
    func emergency(_ active: Bool) -> Bool {
        guard let c = core else { return false }
        return db_core_emergency_v2(c, active ? 1 : 0) != 0
    }

    /// Starts a SIP call to an extension or direct `sip:host:port` target.
    /// tvOS publishes a real backend but invokes only the listen-only `monitor` mode.
    func sipCall(target: String, mode: String) {
        if let c = core, !target.isEmpty { db_core_sip_call(c, target, mode) }
    }

    func sipHangup() {
        if let c = core { db_core_sip_hangup(c) }
    }

    @discardableResult
    func sipSendDtmf(_ digits: String) -> Bool {
        guard let c = core, !digits.isEmpty else { return false }
        return db_core_sip_send_dtmf(c, digits) == 0
    }

    var sipBackend: String {
        guard let p = db_core_sip_backend() else { return "unknown" }
        return String(cString: p)
    }

    func status() -> [String: Any]? { return takeJson(core.map { db_core_status_json($0) } ?? nil) }

    func debugInfo() -> [String: Any]? {
        return takeJson(core.map { db_core_debug_json($0) } ?? nil)
    }

    func config() -> [String: Any]? { return takeJson(core.map { db_core_config_json($0) } ?? nil) }

    func capabilities() -> [String: Any]? {
        takeJson(core.map { db_core_capabilities_json($0) } ?? nil)
    }

    func pairing() -> [String: Any]? {
        takeJson(core.map { db_core_pairing_json($0) } ?? nil)
    }

    func joinCluster(host: String, pin: String) {
        guard let c = core, !host.isEmpty, !pin.isEmpty else { return }
        db_core_join_cluster(c, host, pin)
    }

    @discardableResult
    func createCluster() -> Bool {
        guard let c = core else { return false }
        return db_core_found_cluster(c) != 0
    }

    func pairingMode(seconds: Int32) {
        if let c = core { db_core_pairing_mode(c, max(0, seconds)) }
    }

    func startPairing(seconds: Int32 = 600) -> [String: Any]? {
        guard let c = core else { return nil }
        return takeJson(db_core_start_pairing_json(c, max(1, seconds)))
    }

    func removeDevice(_ id: String) {
        if let c = core, !id.isEmpty { db_core_remove_device(c, id) }
    }

    func inviteDevice(_ id: String) {
        if let c = core, !id.isEmpty { db_core_invite_device(c, id) }
    }

    /// Invite an address/id/public-key triple straight from a scanned Add QR, bypassing discovery.
    func inviteDirect(addr: String, id: String, pk: String) {
        guard let c = core, !addr.isEmpty, !id.isEmpty, !pk.isEmpty else { return }
        db_core_invite_direct(c, addr, id, pk)
    }

    /// Drop one pending device and ignore its announcements for a while.
    func denyDevice(_ id: String) {
        if let c = core, !id.isEmpty { db_core_deny_device(c, id) }
    }

    /// Re-run the secure-store write after state `persist_error`. Core emits `pairing_state`
    /// either way, so the caller renders the event rather than this return value alone.
    @discardableResult
    func retryPairingPersistence() -> Bool {
        guard let c = core else { return false }
        return db_core_retry_pairing_persistence(c) != 0
    }

    /// Leave the cluster: Core zeroes the PSK, deletes the stored secret and reports `unpaired`.
    func unpair() {
        if let c = core { db_core_unpair(c) }
    }

    /// Encode a QR payload as `size` * `size` row-major modules where a non-zero byte is dark.
    func qrEncode(_ text: String) -> (bytes: [UInt8], size: Int)? {
        guard !text.isEmpty else { return nil }
        var size: Int32 = 0
        guard let raw = db_core_qr_encode(text, &size), size > 0 else { return nil }
        defer { db_free(UnsafeMutableRawPointer(raw).assumingMemoryBound(to: CChar.self)) }
        let count = Int(size) * Int(size)
        return (Array(UnsafeBufferPointer(start: raw, count: count)), Int(size))
    }

    func setCapabilities(_ value: [String: Any]) {
        withJson(value) { json in
            if let c = core { db_core_set_capabilities_json(c, json) }
        }
    }

    func setRuntimeStatus(_ value: [String: Any]) {
        withJson(value) { json in
            if let c = core { db_core_set_runtime_status_json(c, json) }
        }
    }

    func setUiManifest(_ value: [String: Any]) {
        withJson(value) { json in
            if let c = core { db_core_set_ui_manifest_json(c, json) }
        }
    }

    func onCameraFrame(_ data: UnsafePointer<UInt8>, format: Int32, width: Int32, height: Int32,
                       stride: Int32, tsMs: Int64) {
        if let c = core { db_core_on_camera_frame(c, data, format, width, height, stride, tsMs) }
    }

    /// Door-station orientation; Core gives an administrator-fixed angle precedence.
    func setVideoSensorRotation(_ degrees: Int32) {
        if let c = core { db_core_set_video_sensor_rotation(c, degrees) }
    }

    func onEncodedFrame(_ annexb: Data, isKeyframe: Bool, tsMs: Int64) {
        guard let c = core else { return }
        annexb.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            guard let base = p.baseAddress else { return }
            db_core_on_encoded_frame(c, base.assumingMemoryBound(to: UInt8.self), p.count,
                                     isKeyframe ? 1 : 0, tsMs)
        }
    }

    func videoEncoderWanted() -> Bool {
        guard let c = core else { return false }
        return db_core_video_encoder_wanted(c) != 0
    }


    func speak(text: String, lang: String) {
        guard !text.isEmpty else { return }
        let utt = AVSpeechUtterance(string: text)
        let code: String
        switch lang {
        case "en": code = "en-US"
        case "zh": code = "zh-CN"
        default: code = "ja-JP"
        }
        utt.voice = AVSpeechSynthesisVoice(language: code)
        synth.stopSpeaking(at: .immediate)
        synth.speak(utt)
    }


    private func takeJson(_ p: UnsafeMutablePointer<CChar>?) -> [String: Any]? {
        guard let p = p else { return nil }
        defer { db_free(p) }
        let data = Data(bytes: UnsafeRawPointer(p), count: strlen(p))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func withJson(_ value: [String: Any], _ body: (String) -> Void) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else { return }
        body(json)
    }

    // UIKit-backed device state is sampled only on main. Core callbacks copy this immutable
    // bounded snapshot under a lock and never call UIDevice from a Core-owned worker thread.
    func refreshDeviceInfoCache() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshDeviceInfoCache() }
            return
        }
        guard let json = CoreBridge.makeDeviceInfoJSONOnMainThread() else { return }
        deviceInfoCacheLock.lock()
        deviceInfoCacheJSON = json
        deviceInfoCacheLock.unlock()
    }

    private func cachedDeviceInfoJSON() -> String {
        deviceInfoCacheLock.lock()
        let snapshot = deviceInfoCacheJSON
        deviceInfoCacheLock.unlock()
        return snapshot
    }

    private static func boundedDeviceInfoString(_ value: String, limit: Int) -> String {
        String(value.prefix(limit))
    }

    private static func makeDeviceInfoJSONOnMainThread() -> String? {
        guard Thread.isMainThread else { return nil }
        #if os(tvOS)
        let batteryState = "mains"
        let batteryPercent: Any = NSNull()
        #else
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryState: String
        switch UIDevice.current.batteryState {
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        case .unplugged: batteryState = "unplugged"
        default: batteryState = "unknown"
        }
        let battery = UIDevice.current.batteryLevel
        let batteryPercent: Any = battery < 0 ? NSNull() : Int(battery * 100)
        #endif
        let obj: [String: Any] = [
            "schema_version": 1,
            "platform": "apple",
            "system": boundedDeviceInfoString(UIDevice.current.systemName, limit: 64),
            "system_version": boundedDeviceInfoString(UIDevice.current.systemVersion, limit: 64),
            "model": boundedDeviceInfoString(UIDevice.current.model, limit: 128),
            "machine": boundedDeviceInfoString(ProcessInfo.processInfo.hostName, limit: 128),
            "battery_state": batteryState,
            "battery_percent": batteryPercent,
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "physical_memory": ProcessInfo.processInfo.physicalMemory,
            "uptime_s": Int(ProcessInfo.processInfo.systemUptime),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              data.count <= 4_096 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func httpsRequestSync(
        method: String, url: String, headersJson: String, body: Data,
        respOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        statusOut: UnsafeMutablePointer<Int32>?) -> Int32 {
        guard let u = URL(string: url) else { return -1 }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 40)
        req.httpMethod = method
        if let hd = headersJson.data(using: .utf8),
           let headers = (try? JSONSerialization.jsonObject(with: hd)) as? [String: Any] {
            for (k, v) in headers { req.setValue("\(v)", forHTTPHeaderField: k) }
        }
        if !body.isEmpty { req.httpBody = body }

        var respData: Data?
        var httpStatus: Int32 = 0
        var transportOk = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse {
                transportOk = true
                httpStatus = Int32(http.statusCode)
                respData = data
            }
            sem.signal()
        }.resume()
        sem.wait()
        guard transportOk else { return -1 }
        statusOut?.pointee = httpStatus
        if let out = respOut {
            let d = respData ?? Data()
            guard let raw = malloc(d.count + 1) else { return -1 }
            let buf = raw.assumingMemoryBound(to: CChar.self)
            if !d.isEmpty {
                _ = d.withUnsafeBytes { p in memcpy(buf, p.baseAddress!, d.count) }
            }
            buf[d.count] = 0
            out.pointee = buf
        }
        return 0
    }
}


enum Keychain {
    private static let service = "jp.keihan.doorbell.secure"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            // The cluster key is device-bound: it must never ride iCloud Keychain to another
            // device, which would silently clone cluster membership.
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func put(_ key: String, _ value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
        let data = value.data(using: .utf8) ?? Data()
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // An item written by an older build may carry a weaker accessibility class, so the
            // update re-applies it instead of only replacing the bytes.
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            return SecItemUpdate(base as CFDictionary,
                                 attributes as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func removeAll() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
