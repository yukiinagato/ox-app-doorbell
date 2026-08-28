// doorbell-core C ABI の Swift ラッパ (WPF CoreClient / Android DoorbellCore と同役)。
// - コールバックは core 内部スレッドから届く → main queue へ marshal してから配送する。
// - db_platform:
//     log_line      → os_log
//     tts_speak     → AVSpeechSynthesizer (ja/en/zh の音声)
//     https_request → URLSession (同期契約 — core が専用スレッドから呼ぶので semaphore で待つ)
//     secure_get/put→ Keychain (kSecClassGenericPassword)
// - core が返す char* は db_free で解放。SPI が core へ渡す char* は malloc (core が free)。
import AVFoundation
import Foundation
import os.log

/// core → 殻 UI イベント (doorbell.h の JSON)。main queue で届く。
typealias UiEventHandler = ([String: Any]) -> Void

final class CoreBridge {

    private var core: OpaquePointer?
    private let synth = AVSpeechSynthesizer()
    private let log = OSLog(subsystem: "jp.keihan.doorbell", category: "core")

    /// UI イベント購読 (key → handler)。main queue で呼ばれる。
    private var handlers: [String: UiEventHandler] = [:]

    var isRunning: Bool { return core != nil }

    // MARK: - ライフサイクル

    /// core 生成 + 起動。失敗時 false (ログは os_log)。
    func start(dataDir: String, bootJson: String) -> Bool {
        if core != nil { return true }
        let user = Unmanaged.passUnretained(self).toOpaque()
        var plat = db_platform()
        plat.user = user
        plat.log_line = { user, level, line in
            guard let user = user, let line = line else { return }
            let me = Unmanaged<CoreBridge>.fromOpaque(user).takeUnretainedValue()
            let type: OSLogType = level >= 3 ? .error : (level >= 2 ? .default : .info)
            os_log("%{public}s", log: me.log, type: type, String(cString: line))
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
            valueOut.pointee = strdup(v)  // core が db_free (= free) する
            return 0
        }
        plat.secure_put = { _, key, value in
            guard let key = key, let value = value else { return -1 }
            return Keychain.put(String(cString: key), String(cString: value)) ? 0 : -1
        }

        core = db_core_create(&plat, dataDir, bootJson)
        guard let c = core else { return false }
        db_core_set_ui_callback(c, { user, evJson in
            guard let user = user, let evJson = evJson else { return }
            let me = Unmanaged<CoreBridge>.fromOpaque(user).takeUnretainedValue()
            // コールバック引数は借用 (解放しない)。このスレッドで Data へコピーしてから
            // main へ渡す (String bridging は避ける — takeJson のコメント参照)
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

    // MARK: - イベント購読

    /// UI イベントの購読 (main queue で届く)。key 重複は上書き。
    func addHandler(_ key: String, _ handler: @escaping UiEventHandler) {
        handlers[key] = handler
    }

    func removeHandler(_ key: String) {
        handlers.removeValue(forKey: key)
    }

    private func dispatch(_ ev: [String: Any]) {
        // ハンドラ内での add/remove (来鈴画面の出入り等) と衝突しないようコピーして回す
        for h in Array(handlers.values) { h(ev) }
    }

    // MARK: - 操作 API (doorbell.h)

    func press(door: String) {
        if let c = core { db_core_press(c, door) }
    }

    /// 用件ボタンからの按鈴 (config visit_purposes の id — press payload に載る)。
    func pressPurpose(door: String, purpose: String) {
        if let c = core { db_core_press_purpose(c, door, purpose) }
    }

    /// 訪客言語の切替 ("ja" で即時復帰)。全ノードへ複製され visitor_lang イベントが返る。
    func setVisitorLang(door: String, lang: String) {
        if let c = core { db_core_set_visitor_lang(c, door, lang) }
    }

    /// クイック返信の配送 (門口機の面板表示 + TTS)。door 空 = 最新 press の door。
    func quickReply(replyId: String, door: String) {
        if let c = core, !replyId.isEmpty { db_core_quick_reply(c, replyId, door) }
    }

    /// SOS 緊急モード。true=発報 / false=解除 (解除前の PIN 検証は呼び出し側)。
    func emergency(_ active: Bool) {
        if let c = core { db_core_emergency(c, active ? 1 : 0) }
    }

    /// SIP 発呼。target: 内線番号 or "sip:host:port" (直呼)。mode: ""/"monitor"/"answer"。
    /// PJSIP 無効ビルド (tvOS) では no-op。
    func sipCall(target: String, mode: String) {
        if let c = core, !target.isEmpty { db_core_sip_call(c, target, mode) }
    }

    func sipHangup() {
        if let c = core { db_core_sip_hangup(c) }
    }

    func status() -> [String: Any]? { return takeJson(core.map { db_core_status_json($0) } ?? nil) }

    func config() -> [String: Any]? { return takeJson(core.map { db_core_config_json($0) } ?? nil) }

    /// カメラフレーム push。format: 0=NV21, 1=NV12, 2=YUY2, 3=BGRA
    func onCameraFrame(_ data: UnsafePointer<UInt8>, format: Int32, width: Int32, height: Int32,
                       stride: Int32, tsMs: Int64) {
        if let c = core { db_core_on_camera_frame(c, data, format, width, height, stride, tsMs) }
    }

    /// 符号化済み H.264 (AnnexB) push — VideoEncoderVT から。core が fMP4 化して /stream.mp4 へ。
    func onEncodedFrame(_ annexb: Data, isKeyframe: Bool, tsMs: Int64) {
        guard let c = core else { return }
        annexb.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            guard let base = p.baseAddress else { return }
            db_core_on_encoded_frame(c, base.assumingMemoryBound(to: UInt8.self), p.count,
                                     isKeyframe ? 1 : 0, tsMs)
        }
    }

    /// エンコーダを回すべきか (codec=h264/auto かつ /stream.mp4 購読者あり)。5 秒毎に確認する。
    func videoEncoderWanted() -> Bool {
        guard let c = core else { return false }
        return db_core_video_encoder_wanted(c) != 0
    }

    // MARK: - TTS (クイック返信の読み上げ — カスタム音声再生失敗の回落先でも使う)

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

    // MARK: - 内部

    private func takeJson(_ p: UnsafeMutablePointer<CChar>?) -> [String: Any]? {
        guard let p = p else { return nil }
        defer { db_free(p) }
        // String 経由の bridging (data(using:)) は iOS 26 SDK でクラッシュを踏んだ —
        // C バッファから直接 Data を作る (コピー 1 回で済み速くもある)
        let data = Data(bytes: UnsafeRawPointer(p), count: strlen(p))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// SPI https_request の実装 (同期契約 — core の専用スレッドから呼ばれるのでブロック可。
    /// Telegram getUpdates 長輪詢は最大 ~30 秒)。戻り 0=成功 (4xx/5xx でも応答が取れれば 0)。
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
            // core は db_free (= free) する契約 — malloc + NUL 終端でコピー
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

// MARK: - Keychain (SPI secure_get/put — SIP パスワード等の保管)

private enum Keychain {
    private static let service = "jp.keihan.doorbell.secure"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
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
        ]
        let data = value.data(using: .utf8) ?? Data()
        var add = base
        add[kSecValueData as String] = data
        // 端末ロック中 (再起動直後の pre-first-unlock) でも core が読めるように
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(base as CFDictionary,
                                 [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
