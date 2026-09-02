// Core invokes platform and UI callbacks on Core-owned threads. UI JSON is borrowed only for the
// callback duration, so it is copied before dispatching to the main queue. HTTPS callbacks are
// synchronous. Buffers returned through db_platform_v2 output pointers are malloc-owned and
// released through release_buffer.
import AVFoundation
import Darwin
import Foundation
import UIKit

typealias UiEventHandler = ([String: Any]) -> Void

final class CoreBridge {

    private var core: OpaquePointer?
    private let synth = AVSpeechSynthesizer()
    private let deviceInfoCacheLock = NSLock()
    private var deviceInfoCacheJSON =
        "{\"schema_version\":1,\"platform\":\"apple\",\"battery_state\":\"unknown\"}"
    private let powerStateCacheLock = NSLock()
    private var powerStateCacheJSON = CoreBridge.noBatteryPowerJSON

    private var handlers: [String: UiEventHandler] = [:]

    var isRunning: Bool { return core != nil }


    func start(dataDir: String, bootJson: String) -> Bool {
        if core != nil { return true }
        refreshDeviceInfoCache()
        refreshPowerStateCache()
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
        // Battery and mains state. Core polls this about once a minute from a worker thread, so
        // the UIDevice reading is sampled on main and handed over as an immutable snapshot.
        plat.power_state = { user, valueOut in
            guard let user = user, let valueOut = valueOut else { return -1 }
            let me = Unmanaged<CoreBridge>.fromOpaque(user).takeUnretainedValue()
            me.schedulePowerStateRefresh()
            valueOut.pointee = strdup(me.cachedPowerStateJSON())
            return valueOut.pointee == nil ? -1 : 0
        }

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

    /// Opens the bulk-add window *and* mints a PIN. It backs the explicit 「まとめて追加」 control
    /// only; the Pairing-PIN card uses `mintJoinToken` so showing a PIN never starts auto-adding.
    func startPairing(seconds: Int32 = 600) -> [String: Any]? {
        guard let c = core else { return nil }
        return takeJson(db_core_start_pairing_json(c, max(1, seconds)))
    }

    /// Mints or refreshes the join PIN without opening pairing mode. Core publishes this as
    /// `db_core_mint_join_token_json`; it is resolved at runtime so a shell built against an older
    /// Core still links, and `supportsMintJoinToken` tells the UI to say so rather than falling
    /// back to the bulk-add entry point.
    private typealias MintJoinTokenFn = @convention(c) (OpaquePointer?, Int32)
        -> UnsafeMutablePointer<CChar>?
    private static let mintJoinTokenFn: MintJoinTokenFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "db_core_mint_join_token_json") else { return nil }
        return unsafeBitCast(symbol, to: MintJoinTokenFn.self)
    }()

    var supportsMintJoinToken: Bool { return CoreBridge.mintJoinTokenFn != nil }

    func mintJoinToken(seconds: Int32 = 600) -> [String: Any]? {
        guard let c = core, let fn = CoreBridge.mintJoinTokenFn else { return nil }
        return takeJson(fn(c, max(1, seconds)))
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


    // MARK: - Time, audio and announcements

    /// Wall-clock instant rendered in the cluster's IANA zone. `wallMs` of zero means "now".
    /// Every clock in the shells goes through this so a device with a wrong OS clock, or one in
    /// another zone, still shows the household's time.
    func localTime(wallMs: Int64 = 0) -> [String: Any]? {
        guard let c = core else { return nil }
        return takeJson(db_core_local_time_json(c, wallMs))
    }

    /// Start one immediate SNTP round. Returns false when NTP is off or Core is not started.
    @discardableResult
    func timeSyncNow() -> Bool {
        guard let c = core else { return false }
        return db_core_time_sync_now(c) != 0
    }

    /// Effective call/sos/idle volumes for one device; empty selects this node.
    func audioVolumes(deviceId: String = "") -> [String: Any]? {
        guard let c = core else { return nil }
        return takeJson(db_core_audio_json(c, deviceId))
    }

    /// Publish a replicated announcement. `expiresMs` of zero means "until cleared".
    @discardableResult
    func setDoorNotice(door: String, text: String, expiresMs: Int64) -> Bool {
        guard let c = core, !door.isEmpty, !text.isEmpty else { return false }
        return db_core_set_door_notice(c, door, text, expiresMs) == 0
    }

    /// Trigger the configured unlock action. 0 queued the action, -3 means nothing is configured
    /// anywhere, and the shell must say so rather than reporting a silent success.
    func openDoor(_ door: String) -> Int32 {
        guard let c = core, !door.isEmpty else { return -1 }
        return db_core_open_door(c, door)
    }

    @discardableResult
    func clearDoorNotice(door: String) -> Bool {
        guard let c = core, !door.isEmpty else { return false }
        return db_core_clear_door_notice(c, door) == 0
    }

    /// Call history newest first. `sinceMs` is an inclusive lower bound; paging backwards uses
    /// the oldest row already shown as the next `beforeMs` and filters locally, because the ABI
    /// exposes only a lower bound.
    func callLog(sinceMs: Int64 = 0, limit: Int = 50) -> [String: Any]? {
        guard let c = core else { return nil }
        return takeJson(db_core_call_log_json(c, sinceMs, Int32(limit)))
    }

    /// Paged history. Core's v2 entry point takes the upper bound the 「さらに読み込む」 button
    /// needs; without it the caller trims a wider window itself.
    private typealias CallLogV2Fn = @convention(c) (OpaquePointer?, Int64, Int64, Int32)
        -> UnsafeMutablePointer<CChar>?
    private static let callLogV2Fn: CallLogV2Fn? = symbol("db_core_call_log_json_v2")
        .map { unsafeBitCast($0, to: CallLogV2Fn.self) }

    var supportsCallLogPaging: Bool { return CoreBridge.callLogV2Fn != nil }

    func callLogPage(sinceMs: Int64, beforeMs: Int64, limit: Int) -> [String: Any]? {
        guard let c = core, let fn = CoreBridge.callLogV2Fn else { return nil }
        return takeJson(fn(c, sinceMs, beforeMs, Int32(limit)))
    }

    @discardableResult
    func markCallLogSeen(upToHlc: String = "") -> Bool {
        guard let c = core else { return false }
        return db_core_call_log_mark_seen(c, upToHlc.isEmpty ? nil : upToHlc) == 0
    }

    /// Microphone mute during an established dialog. Core does not publish this entry point yet,
    /// so it is resolved at runtime: a build whose Core exports it mutes for real, and an older
    /// Core reports that the control is unavailable instead of silently doing nothing.
    private typealias SipMicMuteFn = @convention(c) (OpaquePointer?, Int32) -> Int32
    private static let sipMicMute: SipMicMuteFn? = symbol("db_core_sip_set_mic_muted")
        .map { unsafeBitCast($0, to: SipMicMuteFn.self) }

    var supportsMicMute: Bool { return CoreBridge.sipMicMute != nil }

    @discardableResult
    func setMicMuted(_ muted: Bool) -> Bool {
        guard let c = core, let fn = CoreBridge.sipMicMute else { return false }
        return fn(c, muted ? 1 : 0) == 0
    }

    // MARK: - Configuration writes

    /// Programmatic configuration writes. Core validates them exactly as the web admin's
    /// `/api/config/batch` does, which is why the shells are allowed to use them directly. The
    /// three entry points are resolved at runtime: a Core that does not export them yet leaves
    /// `supportsConfigWrite` false and the settings screens fall back to the HTTP endpoint.
    private typealias SetConfigKeyFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?,
                                                       UnsafePointer<CChar>?) -> Void
    private typealias DeleteConfigKeyFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?)
        -> Void
    private typealias ConfigBatchFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?)
        -> UnsafeMutablePointer<CChar>?

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    private static let setConfigKeyFn: SetConfigKeyFn? = symbol("db_core_set_config_json")
        .map { unsafeBitCast($0, to: SetConfigKeyFn.self) }
    private static let deleteConfigKeyFn: DeleteConfigKeyFn? = symbol("db_core_delete_config_key")
        .map { unsafeBitCast($0, to: DeleteConfigKeyFn.self) }
    private static let configBatchFn: ConfigBatchFn? = symbol("db_core_config_batch_json")
        .map { unsafeBitCast($0, to: ConfigBatchFn.self) }

    /// True when Core can apply a whole batch, or at least every single key, without HTTP.
    var supportsConfigWrite: Bool {
        return CoreBridge.configBatchFn != nil ||
            (CoreBridge.setConfigKeyFn != nil && CoreBridge.deleteConfigKeyFn != nil)
    }

    /// Applies the batch through Core. Returns nil when Core cannot do it, so the caller can fall
    /// back; the batch entry point is preferred because it is the only atomic one.
    func applyConfigBatch(_ opsJson: String, operations: [(key: String, value: String?)]) -> Bool? {
        guard let c = core else { return nil }
        if let batch = CoreBridge.configBatchFn {
            guard let raw = batch(c, opsJson) else { return false }
            defer { db_free(raw) }
            let data = Data(bytes: UnsafeRawPointer(raw), count: strlen(raw))
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return ConfigUtil.bool(object, "ok", false)
        }
        guard let set = CoreBridge.setConfigKeyFn,
              let remove = CoreBridge.deleteConfigKeyFn else { return nil }
        for operation in operations {
            if let value = operation.value {
                set(c, operation.key, value)
            } else {
                remove(c, operation.key)
            }
        }
        return true
    }

    // MARK: - Administrator password

    /// The device code and the web admin password are one cluster-wide secret, verified by Core
    /// against the replicated salted hash. Core rate-limits and locks out; the shell only asks.
    private typealias AdminVerifyFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?)
        -> Int32
    private typealias AdminSetFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?,
                                                   UnsafePointer<CChar>?) -> Int32
    private static let adminVerifyFn: AdminVerifyFn? = symbol("db_core_admin_password_verify")
        .map { unsafeBitCast($0, to: AdminVerifyFn.self) }
    private static let adminSetFn: AdminSetFn? = symbol("db_core_admin_password_set")
        .map { unsafeBitCast($0, to: AdminSetFn.self) }

    var supportsAdminPassword: Bool { return CoreBridge.adminVerifyFn != nil }

    /// nil when Core cannot answer, so the caller can fall back to the legacy local digest.
    func verifyAdminPassword(_ password: String) -> Bool? {
        guard let c = core, let verify = CoreBridge.adminVerifyFn else { return nil }
        return verify(c, password) == 0
    }

    var supportsAdminPasswordChange: Bool { return CoreBridge.adminSetFn != nil }

    /// `current` may be empty on an installation that has never set the password.
    @discardableResult
    func setAdminPassword(current: String, new: String) -> Bool {
        guard let c = core, let set = CoreBridge.adminSetFn, !new.isEmpty else { return false }
        return set(c, current, new) == 0
    }

    // MARK: - Global announcement

    private typealias SetGlobalNoticeFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?,
                                                          Int64) -> Int32
    private typealias ClearGlobalNoticeFn = @convention(c) (OpaquePointer?) -> Int32
    private static let setGlobalNoticeFn: SetGlobalNoticeFn? = symbol("db_core_set_global_notice")
        .map { unsafeBitCast($0, to: SetGlobalNoticeFn.self) }
    private static let clearGlobalNoticeFn: ClearGlobalNoticeFn? =
        symbol("db_core_clear_global_notice")
            .map { unsafeBitCast($0, to: ClearGlobalNoticeFn.self) }

    var supportsGlobalNotice: Bool { return CoreBridge.setGlobalNoticeFn != nil }

    /// nil when Core has no entry point yet, so the caller can write the key instead.
    func setGlobalNotice(text: String, expiresMs: Int64) -> Bool? {
        guard let c = core, let set = CoreBridge.setGlobalNoticeFn, !text.isEmpty else {
            return nil
        }
        return set(c, text, expiresMs) == 0
    }

    func clearGlobalNotice() -> Bool? {
        guard let c = core, let clear = CoreBridge.clearGlobalNoticeFn else { return nil }
        return clear(c) == 0
    }

    // MARK: - Power state

    private static let noBatteryPowerJSON =
        "{\"battery_pct\":-1,\"charging\":false,\"mains\":true}"

    private func cachedPowerStateJSON() -> String {
        powerStateCacheLock.lock()
        let snapshot = powerStateCacheJSON
        powerStateCacheLock.unlock()
        return snapshot
    }

    private func schedulePowerStateRefresh() {
        DispatchQueue.main.async { [weak self] in self?.refreshPowerStateCache() }
    }

    /// Samples UIDevice on the main thread. tvOS has no battery, so it reports mains power and a
    /// negative percentage, which Core renders as "no battery" rather than "unknown".
    func refreshPowerStateCache() {
        guard Thread.isMainThread else {
            schedulePowerStateRefresh()
            return
        }
        #if os(tvOS)
        let object: [String: Any] = ["battery_pct": -1, "charging": false, "mains": true]
        #else
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        let level = UIDevice.current.batteryLevel
        let charging = state == .charging
        let mains = state == .charging || state == .full
        let object: [String: Any] = [
            "battery_pct": level < 0 ? -1 : Int((level * 100).rounded()),
            "charging": charging,
            "mains": mains,
        ]
        #endif
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return }
        powerStateCacheLock.lock()
        powerStateCacheJSON = json
        powerStateCacheLock.unlock()
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
    private static let service = "jp.ox.doorbell.secure"

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
