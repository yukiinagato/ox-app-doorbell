// Core invokes platform and UI callbacks on Core-owned threads. UI JSON is borrowed only for the
// callback duration, so it is copied before dispatching to the main queue. HTTPS callbacks are
// synchronous. Buffers returned through db_platform_v2 output pointers are malloc-owned and
// released through release_buffer.
import AVFoundation
import Darwin
import Foundation
import UIKit

typealias UiEventHandler = ([String: Any]) -> Void

private final class CoreUiCallbackRegistration {
    weak var bridge: CoreBridge?
    let generation: UInt64

    init(bridge: CoreBridge, generation: UInt64) {
        self.bridge = bridge
        self.generation = generation
    }
}

final class CoreBridge {

    private enum Lifecycle { case stopped, starting, running, stopping }
    private let lifecycle = NSCondition()
    private let teardownQueue = DispatchQueue(label: "jp.ox.doorbell.core.teardown")
    private var phase = Lifecycle.stopped
    private var core: OpaquePointer?
    private var starting = false
    private var inFlight = 0
    private var generation: UInt64 = 0
    private var stopCompletions: [() -> Void] = []
    private let synth = AVSpeechSynthesizer()
    private let deviceInfoCacheLock = NSLock()
    private var deviceInfoCacheJSON =
        "{\"schema_version\":1,\"platform\":\"apple\",\"battery_state\":\"unknown\"}"
    private let powerStateCacheLock = NSLock()
    private var powerStateCacheJSON = CoreBridge.noBatteryPowerJSON
    private let uiEventDispatchGate = CoreEventDispatchGate()
    private var uiCallbackRegistration: CoreUiCallbackRegistration?

    private let handlerLock = NSLock()
    private var handlers: [String: UiEventHandler] = [:]

    deinit {
        uiEventDispatchGate.invalidate()
        // A lease, start, or queued teardown retains the bridge. With no callers left, move the
        // last handle and its borrowed callback context to the teardown queue without retaining self.
        let handle = core
        let registration = uiCallbackRegistration
        if let handle = handle {
            teardownQueue.async {
                db_core_set_ui_callback(handle, nil, nil)
                db_core_stop(handle)
                db_core_destroy(handle)
                withExtendedLifetime(registration) {}
            }
        }
    }

    var runningGeneration: UInt64? {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        return phase == .running ? generation : nil
    }

    var isRunning: Bool { return runningGeneration != nil }

    // The lease covers the complete C call and copying/freeing its result. The lifecycle lock
    // never surrounds C code, which may synchronously call back into the platform.
    @discardableResult
    private func withCore<T>(generation expectedGeneration: UInt64? = nil,
                             _ body: (OpaquePointer) -> T) -> T? {
        lifecycle.lock()
        guard phase == .running, let handle = core,
              expectedGeneration == nil || expectedGeneration == generation else {
            lifecycle.unlock()
            return nil
        }
        inFlight += 1
        #if DEBUG
        let acquired = testHooks.afterAcquire
        #endif
        lifecycle.unlock()
        defer {
            lifecycle.lock()
            inFlight -= 1
            if inFlight == 0 { lifecycle.broadcast() }
            lifecycle.unlock()
        }
        #if DEBUG
        acquired?()
        #endif
        return body(handle)
    }

    #if DEBUG
    struct LifecycleTestHooks {
        var afterAcquire: (() -> Void)?
        var beforeStart: (() -> Void)?
        var beforeDestroy: (() -> Void)?
        var afterDestroy: (() -> Void)?
        var uiCallback: (() -> Void)?
        var uiDelivery: ((UInt64, Bool) -> Void)?
        var enqueueUi: ((@escaping () -> Void) -> Void)?
    }
    private var testHooks = LifecycleTestHooks()

    func setLifecycleTestHooks(_ hooks: LifecycleTestHooks) {
        lifecycle.lock()
        testHooks = hooks
        lifecycle.unlock()
    }

    private func lifecycleTestHooks() -> LifecycleTestHooks {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        return testHooks
    }

    var lifecycleTestSnapshot: (stopping: Bool, inFlight: Int) {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        return (phase == .stopping, inFlight)
    }
    #endif

    private func enqueueUiDelivery(_ body: @escaping () -> Void) {
        #if DEBUG
        if let enqueue = lifecycleTestHooks().enqueueUi {
            enqueue(body)
            return
        }
        #endif
        DispatchQueue.main.async(execute: body)
    }


    func start(dataDir: String, bootJson: String) -> Bool {
        lifecycle.lock()
        if phase == .running { lifecycle.unlock(); return true }
        guard phase == .stopped else { lifecycle.unlock(); return false }
        phase = .starting
        starting = true
        generation &+= 1
        if generation == 0 { generation = 1 }
        let registration = CoreUiCallbackRegistration(
            bridge: self, generation: uiEventDispatchGate.begin())
        uiCallbackRegistration = registration
        lifecycle.unlock()
        refreshDeviceInfoCache()
        refreshPowerStateCache()
        let user = Unmanaged.passUnretained(registration).toOpaque()
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
            let registration = Unmanaged<CoreUiCallbackRegistration>
                .fromOpaque(user).takeUnretainedValue()
            guard let me = registration.bridge else { return }
            let t = String(cString: text)
            let l = lang != nil ? String(cString: lang!) : "ja"
            me.enqueueUiDelivery {
                guard me.uiEventDispatchGate.isCurrent(registration.generation) else { return }
                me.speak(text: t, lang: l)
            }
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
            let registration = Unmanaged<CoreUiCallbackRegistration>
                .fromOpaque(user).takeUnretainedValue()
            guard let me = registration.bridge else { return -1 }
            let json = me.cachedDeviceInfoJSON()
            valueOut.pointee = strdup(json)
            return valueOut.pointee == nil ? -1 : 0
        }
        plat.release_buffer = { _, buffer in free(buffer) }
        // Battery and mains state. Core polls this about once a minute from a worker thread, so
        // the UIDevice reading is sampled on main and handed over as an immutable snapshot.
        plat.power_state = { user, valueOut in
            guard let user = user, let valueOut = valueOut else { return -1 }
            let registration = Unmanaged<CoreUiCallbackRegistration>
                .fromOpaque(user).takeUnretainedValue()
            guard let me = registration.bridge else { return -1 }
            me.schedulePowerStateRefresh()
            valueOut.pointee = strdup(me.cachedPowerStateJSON())
            return valueOut.pointee == nil ? -1 : 0
        }

        guard let c = db_core_create_v2(&plat, dataDir, bootJson) else {
            finishStarting(handle: nil, succeeded: false)
            return false
        }
        db_core_set_ui_callback(c, { user, evJson in
            guard let user = user, let evJson = evJson else { return }
            let registration = Unmanaged<CoreUiCallbackRegistration>
                .fromOpaque(user).takeUnretainedValue()
            guard let me = registration.bridge else { return }
            #if DEBUG
            me.lifecycleTestHooks().uiCallback?()
            #endif
            let data = Data(bytes: UnsafeRawPointer(evJson), count: strlen(evJson))
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }
            me.enqueueUiDelivery { [weak me] in
                guard let me = me else { return }
                let current = me.uiEventDispatchGate.isCurrent(registration.generation)
                #if DEBUG
                me.lifecycleTestHooks().uiDelivery?(registration.generation, current)
                #endif
                guard current else { return }
                me.dispatch(obj)
            }
        }, Unmanaged.passUnretained(registration).toOpaque())
        #if DEBUG
        lifecycleTestHooks().beforeStart?()
        #endif
        return finishStarting(handle: c, succeeded: db_core_start(c) == 0)
    }

    @discardableResult
    private func finishStarting(handle: OpaquePointer?, succeeded: Bool) -> Bool {
        lifecycle.lock()
        core = handle
        starting = false
        let accepted = succeeded && phase == .starting
        if accepted { phase = .running }
        let needsStop = !succeeded && phase == .starting
        lifecycle.broadcast()
        lifecycle.unlock()
        if needsStop { stop() }
        return accepted
    }

    // Closing admission is synchronous. Waiting, callback draining and destruction never block
    // the main queue; reset/restart callers continue only through the main-queue completion.
    func stop(completion: (() -> Void)? = nil) {
        lifecycle.lock()
        if phase == .stopped {
            lifecycle.unlock()
            if let completion = completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        if let completion = completion { stopCompletions.append(completion) }
        guard phase != .stopping else { lifecycle.unlock(); return }
        phase = .stopping
        uiEventDispatchGate.invalidate()
        lifecycle.unlock()
        teardownQueue.async { self.finishStop() }
    }

    private func finishStop() {
        lifecycle.lock()
        while starting || inFlight != 0 { lifecycle.wait() }
        let handle = core
        let registration = uiCallbackRegistration
        core = nil
        lifecycle.unlock()
        if let handle = handle {
            db_core_set_ui_callback(handle, nil, nil)
            db_core_stop(handle)
            #if DEBUG
            lifecycleTestHooks().beforeDestroy?()
            #endif
            db_core_destroy(handle)
            #if DEBUG
            lifecycleTestHooks().afterDestroy?()
            #endif
        }
        withExtendedLifetime(registration) {}
        lifecycle.lock()
        uiCallbackRegistration = nil
        phase = .stopped
        let completions = stopCompletions
        stopCompletions.removeAll()
        lifecycle.unlock()
        for completion in completions { DispatchQueue.main.async(execute: completion) }
    }


    func addHandler(_ key: String, _ handler: @escaping UiEventHandler) {
        handlerLock.lock()
        handlers[key] = handler
        handlerLock.unlock()
    }

    func removeHandler(_ key: String) {
        handlerLock.lock()
        handlers.removeValue(forKey: key)
        handlerLock.unlock()
    }

    private func dispatch(_ ev: [String: Any]) {
        handlerLock.lock()
        let snapshot = Array(handlers.values)
        handlerLock.unlock()
        for handler in snapshot { handler(ev) }
    }


    func press(door: String) {
        withCore { c in db_core_press(c, door) }
    }

    func pressPurpose(door: String, purpose: String) {
        withCore { c in db_core_press_purpose(c, door, purpose) }
    }

    /// Start or reuse a versioned call and return its stable identifier.
    func pressV2(door: String, purpose: String = "") -> String? {
        return withCore { c -> String? in
            guard let p = db_core_press_v2(c, door, purpose) else { return nil }
            defer { db_free(p) }
            let id = String(cString: p)
            return id.isEmpty ? nil : id
        } ?? nil
    }

    func selectPurpose(door: String, callId: String, purpose: String) -> Bool {
        return withCore { c -> Bool in
            guard !callId.isEmpty else { return false }
            return db_core_select_purpose_v2(c, door, callId, purpose) == 0
        } ?? false
    }

    func cancelCall(door: String, callId: String, reason: String = "visitor") -> Bool {
        return withCore { c -> Bool in
            guard !callId.isEmpty else { return false }
            return db_core_cancel_call_v2(c, door, callId, reason) == 0
        } ?? false
    }

    func reportCallRecovery(callId: String, restored: Bool, coreGeneration: UInt64? = nil) {
        withCore(generation: coreGeneration) { c -> Void in
            guard !callId.isEmpty else { return }
            db_core_report_call_recovery(c, callId, restored ? 1 : 0)
        }
    }

    @discardableResult
    func reportCallAnswered(door: String, callId: String, stageRevision: Int) -> Bool {
        return withCore { c -> Bool in
            guard !door.isEmpty, !callId.isEmpty else { return false }
            return db_core_report_call_answered_v2(c, door, callId, Int32(stageRevision)) == 0
        } ?? false
    }

    @discardableResult
    func reportCallEnded(door: String, callId: String, stageRevision: Int,
                         reason: String = "sip_ended") -> Bool {
        return withCore { c -> Bool in
            guard !door.isEmpty, !callId.isEmpty else { return false }
            return db_core_report_call_ended_v2(c, door, callId, Int32(stageRevision), reason) == 0
        } ?? false
    }

    func setVisitorLang(door: String, lang: String) {
        withCore { c in db_core_set_visitor_lang(c, door, lang) }
    }

    func quickReply(replyId: String, door: String) {
        if !replyId.isEmpty { withCore { c in db_core_quick_reply(c, replyId, door) } }
    }

    func quickReplyV2(replyId: String, door: String, callId: String,
                      stageRevision: Int) -> Bool {
        return withCore { c -> Bool in
            guard !replyId.isEmpty, !callId.isEmpty, stageRevision >= 0 else { return false }
            return db_core_quick_reply_v2(c, replyId, door, callId, Int32(stageRevision)) == 0
        } ?? false
    }

    @discardableResult
    func emergency(_ active: Bool) -> Bool {
        return withCore { c -> Bool in
            return db_core_emergency_v2(c, active ? 1 : 0) != 0
        } ?? false
    }

    /// Starts a SIP call to an extension or direct `sip:host:port` target.
    /// tvOS publishes a real backend but invokes only the listen-only `monitor` mode.
    func sipCall(target: String, mode: String) {
        if !target.isEmpty { withCore { c in db_core_sip_call(c, target, mode) } }
    }

    func sipHangup() {
        withCore { c in db_core_sip_hangup(c) }
    }

    @discardableResult
    func sipSendDtmf(_ digits: String) -> Bool {
        return withCore { c -> Bool in
            guard !digits.isEmpty else { return false }
            return db_core_sip_send_dtmf(c, digits) == 0
        } ?? false
    }

    var sipBackend: String {
        guard let p = db_core_sip_backend() else { return "unknown" }
        return String(cString: p)
    }

    func status() -> [String: Any]? { return withCore { takeJson(db_core_status_json($0)) } ?? nil }

    func callTimingSnapshot() -> CallTiming.Snapshot? {
        guard let generation = runningGeneration else { return nil }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        guard let document = withCore(generation: generation, {
            takeJson(db_core_status_json($0))
        }) ?? nil, runningGeneration == generation else { return nil }
        return CallTiming.Snapshot(document: document, coreGeneration: generation,
                                   requestedAt: requestedAt)
    }

    func debugInfo() -> [String: Any]? {
        return withCore { takeJson(db_core_debug_json($0)) } ?? nil
    }

    func config() -> [String: Any]? { return withCore { takeJson(db_core_config_json($0)) } ?? nil }

    func capabilities() -> [String: Any]? {
        withCore { takeJson(db_core_capabilities_json($0)) } ?? nil
    }

    func pairing() -> [String: Any]? {
        withCore { takeJson(db_core_pairing_json($0)) } ?? nil
    }

    /// Core's own reading of a scanned `doorbell://pair` code, so every shell accepts and refuses
    /// exactly the same invitations. Core checks the expiry against corrected cluster time when it
    /// is running, which a shell cannot do. Nil when Core is not up yet — a code can be scanned
    /// before it is — and the caller falls back to its own parse.
    func parsePairUri(_ uri: String) -> [String: Any]? {
        return withCore { c -> [String: Any]? in
            guard !uri.isEmpty else { return nil }
            return takeJson(db_core_parse_pair_uri_json(c, uri))
        } ?? nil
    }

    func joinCluster(host: String, pin: String) {
        withCore { c -> Void in
            guard !host.isEmpty, !pin.isEmpty else { return }
            db_core_join_cluster(c, host, pin)
        }
    }

    @discardableResult
    func createCluster() -> Bool {
        return withCore { c -> Bool in
            return db_core_found_cluster(c) != 0
        } ?? false
    }

    func pairingMode(seconds: Int32) {
        withCore { c in db_core_pairing_mode(c, max(0, seconds)) }
    }

    /// Opens the bulk-add window *and* mints a PIN. It backs the explicit 「まとめて追加」 control
    /// only; the Pairing-PIN card uses `mintJoinToken` so showing a PIN never starts auto-adding.
    func startPairing(seconds: Int32 = 600) -> [String: Any]? {
        return withCore { c -> [String: Any]? in
            return takeJson(db_core_start_pairing_json(c, max(1, seconds)))
        } ?? nil
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
        return withCore { c -> [String: Any]? in
            guard let fn = CoreBridge.mintJoinTokenFn else { return nil }
            return takeJson(fn(c, max(1, seconds)))
        } ?? nil
    }

    func removeDevice(_ id: String) {
        if !id.isEmpty { withCore { c in db_core_remove_device(c, id) } }
    }

    func inviteDevice(_ id: String) {
        if !id.isEmpty { withCore { c in db_core_invite_device(c, id) } }
    }

    /// Invite an address/id/public-key triple straight from a scanned Add QR, bypassing discovery.
    func inviteDirect(addr: String, id: String, pk: String) {
        withCore { c -> Void in
            guard !addr.isEmpty, !id.isEmpty, !pk.isEmpty else { return }
            db_core_invite_direct(c, addr, id, pk)
        }
    }

    /// Drop one pending device and ignore its announcements for a while.
    func denyDevice(_ id: String) {
        if !id.isEmpty { withCore { c in db_core_deny_device(c, id) } }
    }

    /// Re-run the secure-store write after state `persist_error`. Core emits `pairing_state`
    /// either way, so the caller renders the event rather than this return value alone.
    @discardableResult
    func retryPairingPersistence() -> Bool {
        return withCore { c -> Bool in
            return db_core_retry_pairing_persistence(c) != 0
        } ?? false
    }

    /// Leave the cluster: Core zeroes the PSK, deletes the stored secret and reports `unpaired`.
    func unpair() {
        withCore { c in db_core_unpair(c) }
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
            withCore { c in db_core_set_capabilities_json(c, json) }
        }
    }

    func setRuntimeStatus(_ value: [String: Any]) {
        withJson(value) { json in
            withCore { c in db_core_set_runtime_status_json(c, json) }
        }
    }

    func setUiManifest(_ value: [String: Any]) {
        withJson(value) { json in
            withCore { c in db_core_set_ui_manifest_json(c, json) }
        }
    }

    func onCameraFrame(_ data: UnsafePointer<UInt8>, format: Int32, width: Int32, height: Int32,
                       stride: Int32, tsMs: Int64, coreGeneration: UInt64) {
        withCore(generation: coreGeneration) { c in
            db_core_on_camera_frame(c, data, format, width, height, stride, tsMs)
        }
    }

    /// Door-station orientation; Core gives an administrator-fixed angle precedence.
    func setVideoSensorRotation(_ degrees: Int32) {
        withCore { c in db_core_set_video_sensor_rotation(c, degrees) }
    }

    func onEncodedFrame(_ annexb: Data, isKeyframe: Bool, tsMs: Int64, coreGeneration: UInt64) {
        withCore(generation: coreGeneration) { c -> Void in
            annexb.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                guard let base = p.baseAddress else { return }
                db_core_on_encoded_frame(c, base.assumingMemoryBound(to: UInt8.self), p.count,
                                         isKeyframe ? 1 : 0, tsMs)
            }
        }
    }

    func videoEncoderWanted() -> Bool {
        return withCore { c -> Bool in
            return db_core_video_encoder_wanted(c) != 0
        } ?? false
    }

    func takeVideoKeyframeRequest() -> Bool {
        return withCore { c -> Bool in
            return db_core_take_video_keyframe_request(c) != 0
        } ?? false
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
        return withCore { c -> [String: Any]? in
            return takeJson(db_core_local_time_json(c, wallMs))
        } ?? nil
    }

    /// Start one immediate SNTP round. Returns false when NTP is off or Core is not started.
    @discardableResult
    func timeSyncNow() -> Bool {
        return withCore { c -> Bool in
            return db_core_time_sync_now(c) != 0
        } ?? false
    }

    /// Effective call/sos/idle volumes for one device; empty selects this node.
    func audioVolumes(deviceId: String = "") -> [String: Any]? {
        return withCore { c -> [String: Any]? in
            return takeJson(db_core_audio_json(c, deviceId))
        } ?? nil
    }

    /// Publish a replicated announcement. `expiresMs` of zero means "until cleared".
    @discardableResult
    func setDoorNotice(door: String, text: String, expiresMs: Int64) -> Bool {
        return withCore { c -> Bool in
            guard !door.isEmpty, !text.isEmpty else { return false }
            return db_core_set_door_notice(c, door, text, expiresMs) == 0
        } ?? false
    }

    /// Trigger the configured unlock action. 0 queued the action, -3 means nothing is configured
    /// anywhere, and the shell must say so rather than reporting a silent success.
    func openDoor(_ door: String) -> Int32 {
        return withCore { c -> Int32 in
            guard !door.isEmpty else { return -1 }
            return db_core_open_door(c, door)
        } ?? -1
    }

    @discardableResult
    func clearDoorNotice(door: String) -> Bool {
        return withCore { c -> Bool in
            guard !door.isEmpty else { return false }
            return db_core_clear_door_notice(c, door) == 0
        } ?? false
    }

    /// Call history newest first. `sinceMs` is an inclusive lower bound; paging backwards uses
    /// the oldest row already shown as the next `beforeMs` and filters locally, because the ABI
    /// exposes only a lower bound.
    func callLog(sinceMs: Int64 = 0, limit: Int = 50) -> [String: Any]? {
        return withCore { c -> [String: Any]? in
            return takeJson(db_core_call_log_json(c, sinceMs, Int32(limit)))
        } ?? nil
    }

    /// Paged history. Core's v2 entry point takes the upper bound the 「さらに読み込む」 button
    /// needs; without it the caller trims a wider window itself.
    private typealias CallLogV2Fn = @convention(c) (OpaquePointer?, Int64, Int64, Int32)
        -> UnsafeMutablePointer<CChar>?
    private static let callLogV2Fn: CallLogV2Fn? = symbol("db_core_call_log_json_v2")
        .map { unsafeBitCast($0, to: CallLogV2Fn.self) }

    var supportsCallLogPaging: Bool { return CoreBridge.callLogV2Fn != nil }

    func callLogPage(sinceMs: Int64, beforeMs: Int64, limit: Int) -> [String: Any]? {
        return withCore { c -> [String: Any]? in
            guard let fn = CoreBridge.callLogV2Fn else { return nil }
            return takeJson(fn(c, sinceMs, beforeMs, Int32(limit)))
        } ?? nil
    }

    @discardableResult
    func markCallLogSeen(upToHlc: String = "") -> Bool {
        return withCore { c -> Bool in
            return db_core_call_log_mark_seen(c, upToHlc.isEmpty ? nil : upToHlc) == 0
        } ?? false
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
        return withCore { c -> Bool in
            guard let fn = CoreBridge.sipMicMute else { return false }
            return fn(c, muted ? 1 : 0) == 0
        } ?? false
    }

    // MARK: - Configuration writes

    /// Programmatic configuration writes. Core validates them exactly as the web admin's
    /// `/api/config/batch` does, which is why the shells are allowed to use them directly. The
    /// three entry points are resolved at runtime: a Core that does not export them yet leaves
    /// `supportsConfigWrite` false and the settings screens fall back to the HTTP endpoint.
    private typealias SetConfigKeyFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?,
                                                       UnsafePointer<CChar>?) -> Int32
    private typealias DeleteConfigKeyFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?)
        -> Int32
    private typealias ConfigBatchFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?)
        -> UnsafeMutablePointer<CChar>?
    private typealias WriteWarningsFn = @convention(c) (OpaquePointer?)
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
    private static let writeWarningsFn: WriteWarningsFn? =
        symbol("db_core_last_write_warnings_json")
            .map { unsafeBitCast($0, to: WriteWarningsFn.self) }

    /// True when Core can apply a whole batch, or at least every single key, without HTTP.
    var supportsConfigWrite: Bool {
        return CoreBridge.configBatchFn != nil ||
            (CoreBridge.setConfigKeyFn != nil && CoreBridge.deleteConfigKeyFn != nil)
    }

    /// What Core said about a write: whether it committed, why not, and the readability warnings
    /// it produced. A warning never means failure — §5.2 is explicit that a colour an
    /// administrator typed is saved and only commented on.
    struct WriteOutcome {
        let ok: Bool
        let error: String
        /// Each entry is {"key","property","contrast","message_key"}.
        let warnings: [[String: Any]]
    }

    /// Applies the batch through Core. Returns nil only when no local write capability exists.
    func applyConfigBatch(_ opsJson: String,
                          operations: [(key: String, value: String?)]) -> WriteOutcome? {
        return withCore { c -> WriteOutcome? in
            if let batch = CoreBridge.configBatchFn {
                guard let raw = batch(c, opsJson) else {
                    return WriteOutcome(ok: false, error: "config_persistence_failed", warnings: [])
                }
                defer { db_free(raw) }
                let data = Data(bytes: UnsafeRawPointer(raw), count: strlen(raw))
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                return WriteOutcome(ok: ConfigUtil.bool(object, "ok", false),
                                    error: ConfigUtil.str(object, "err") ?? "",
                                    warnings: (object?["warnings"] as? [[String: Any]]) ?? [])
            }
            guard let set = CoreBridge.setConfigKeyFn,
                  let remove = CoreBridge.deleteConfigKeyFn else { return nil }
            guard ConfigBatchFallbackPolicy.allowsLegacyWrite(operationCount: operations.count) else {
                return WriteOutcome(ok: false, error: "batch_unavailable", warnings: [])
            }
            // This is intentionally one operation only. Multi-key changes must use Core's atomic
            // batch entry point; a client-side compensating write cannot undo a replicated update.
            for operation in operations {
                let code = operation.value.map { set(c, operation.key, $0) }
                    ?? remove(c, operation.key)
                guard code == 0 else {
                    return WriteOutcome(ok: false, error: "config_persistence_failed",
                                        warnings: lastWriteWarnings(c))
                }
            }
            return WriteOutcome(ok: true, error: "", warnings: lastWriteWarnings(c))
        } ?? nil
    }

    /// The readability warnings the last single-key write produced. The batch form embeds its own.
    private func lastWriteWarnings(_ c: OpaquePointer) -> [[String: Any]] {
        guard let fn = CoreBridge.writeWarningsFn, let raw = fn(c) else { return [] }
        defer { db_free(raw) }
        let data = Data(bytes: UnsafeRawPointer(raw), count: strlen(raw))
        return ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
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

    /// Core's answer, not a boolean: a wrong password and a cluster that has no password yet are
    /// different situations, and treating either as "accepted" would open the settings screen.
    enum AdminPasswordResult {
        case accepted
        case wrong
        case lockedOut
        /// No cluster password exists. The shell offers to set one instead of refusing entry.
        case unset
        /// Core cannot answer; the caller may fall back to the legacy per-node digest.
        case unavailable
    }

    func verifyAdminPassword(_ password: String) -> AdminPasswordResult {
        return withCore { c -> AdminPasswordResult in
            guard let verify = CoreBridge.adminVerifyFn else { return .unavailable }
            switch verify(c, password) {
            case let code where code > 0: return .accepted
            case 0: return .wrong
            case -1: return .lockedOut
            case -2: return .unset
            default: return .unavailable
            }
        } ?? .unavailable
    }

    /// Whether the cluster has a password at all, without spending a verification attempt.
    var adminPasswordIsSet: Bool {
        guard let emergency = status()?["emergency"] as? [String: Any] else { return true }
        return ConfigUtil.bool(emergency, "admin_password_set", true)
    }

    /// Clearing a running SOS alarm is never gated on a password the cluster does not have. Core
    /// folds both halves into one flag; `emergency.cancel_requires_pin` alone would lock a
    /// household out of its own alarm.
    var sosCancelRequiresPassword: Bool {
        guard let emergency = status()?["emergency"] as? [String: Any],
              emergency["cancel_requires_password"] != nil else { return false }
        return ConfigUtil.bool(emergency, "cancel_requires_password", false)
    }

    var supportsAdminPasswordChange: Bool { return CoreBridge.adminSetFn != nil }

    enum AdminPasswordChange {
        case ok
        case wrongCurrent
        case lockedOut
        case failed
    }

    /// `current` is empty only while the cluster has no password — the trust-on-first-use path
    /// the first web login already takes.
    @discardableResult
    func setAdminPassword(current: String, new: String) -> AdminPasswordChange {
        return withCore { c -> AdminPasswordChange in
            guard let set = CoreBridge.adminSetFn, !new.isEmpty else { return .failed }
            switch set(c, current, new) {
            case 0: return .ok
            case -2: return .wrongCurrent
            case -3: return .lockedOut
            default: return .failed
            }
        } ?? .failed
    }

    // MARK: - House-wide announcement

    /// There is no separate global-announcement entry point: the door id `"*"` is the cluster-wide
    /// announcement, stored at `notice.global`, and a door-specific one still wins over it.
    static let globalNoticeDoor = "*"

    @discardableResult
    func setGlobalNotice(text: String, expiresMs: Int64) -> Bool {
        return setDoorNotice(door: CoreBridge.globalNoticeDoor, text: text, expiresMs: expiresMs)
    }

    @discardableResult
    func clearGlobalNotice() -> Bool {
        return clearDoorNotice(door: CoreBridge.globalNoticeDoor)
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

    // ProcessInfo.hostName resolves the name through NSHost, which blocks the calling
    // thread on the resolver; on a device whose local-network consent is still pending
    // that outlasts the scene-create watchdog. gethostname(3) reads the same kernel
    // value without touching DNS or mDNS.
    private static func localHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "" }
        return String(cString: buffer)
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
            "machine": boundedDeviceInfoString(localHostName(), limit: 128),
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
