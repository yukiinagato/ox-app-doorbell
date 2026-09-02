import Foundation

/// Native settings write exactly the keys the web admin writes, and Core validates them with the
/// same rules either way. There are two transports and the shell never invents a third: Core's
/// programmatic entry point when this build exports it, and otherwise the admin's own
/// `POST /api/config/batch`. The HTTP route needs an administrator session, so on a Core without
/// the programmatic entry point a write is refused rather than half-applied.
final class ConfigWriter {

    struct Operation {
        let key: String
        let value: Any?

        static func set(_ key: String, _ value: Any) -> Operation {
            return Operation(key: key, value: value)
        }

        static func delete(_ key: String) -> Operation {
            return Operation(key: key, value: nil)
        }
    }

    enum Result {
        case ok
        case failed(String)

        var isOk: Bool { if case .ok = self { return true }; return false }
    }

    private let core: CoreBridge?
    private let httpPort: Int
    private let session: URLSession

    init(core: CoreBridge? = nil, httpPort: Int) {
        self.core = core
        self.httpPort = httpPort
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// Applies every operation or none. `completion` runs on the main queue with a message key
    /// the caller renders; an empty message means success.
    func apply(_ operations: [Operation], completion: @escaping (Result) -> Void) {
        guard !operations.isEmpty else {
            DispatchQueue.main.async { completion(.ok) }
            return
        }
        var ops: [[String: Any]] = []
        for operation in operations {
            if let value = operation.value {
                ops.append(["op": "set", "key": operation.key, "value": value])
            } else {
                ops.append(["op": "delete", "key": operation.key])
            }
        }
        let body: [String: Any] = ["ops": ops]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let opsJson = String(data: data, encoding: .utf8),
              let url = URL(string: "http://127.0.0.1:\(httpPort)/api/config/batch") else {
            DispatchQueue.main.async { completion(.failed("invalid_request")) }
            return
        }

        // Preferred transport: Core applies and validates the batch in process, with no session.
        if let core = core, core.supportsConfigWrite {
            let pairs = operations.map { operation -> (key: String, value: String?) in
                guard let value = operation.value,
                      let encoded = ConfigWriter.encode(value) else {
                    return (operation.key, nil)
                }
                return (operation.key, encoded)
            }
            if let applied = core.applyConfigBatch(opsJson, operations: pairs) {
                DispatchQueue.main.async {
                    completion(applied ? .ok : .failed("config_persistence_failed"))
                }
                return
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        session.dataTask(with: request) { responseData, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var payload: [String: Any] = [:]
            if let responseData = responseData,
               let object = (try? JSONSerialization.jsonObject(with: responseData))
                as? [String: Any] {
                payload = object
            }
            let ok = status == 200 && ConfigUtil.bool(payload, "ok", false)
            // 401 means this Core has neither the programmatic entry point nor an administrator
            // session for the shell; both read as "this node cannot apply the write".
            let error = ConfigUtil.str(payload, "err")
                ?? (status == 404 || status == 401 ? "batch_unavailable" : "request_failed")
            DispatchQueue.main.async { completion(ok ? .ok : .failed(error)) }
        }.resume()
    }

    /// JSON encoding of one value, as Core's single-key entry point expects it.
    private static func encode(_ value: Any) -> String? {
        if let text = value as? String {
            guard let data = try? JSONSerialization.data(withJSONObject: [text]),
                  let wrapped = String(data: data, encoding: .utf8) else { return nil }
            return String(wrapped.dropFirst().dropLast())
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return "\(number)"
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Message for a failed write. `batch_unavailable` keeps the existing wording that names the
    /// endpoint, because that failure means the node is too old for atomic writes.
    static func message(_ texts: Texts, _ result: Result) -> String {
        switch result {
        case .ok:
            return texts.t("settings.saved")
        case .failed(let code):
            if code == "batch_unavailable" { return texts.t("admin.atomic_batch_unavailable") }
            return texts.t("settings.save_failed")
        }
    }
}
