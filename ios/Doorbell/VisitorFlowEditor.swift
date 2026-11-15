import Foundation

/// Reads the raw `visitor_flow` configuration an editor shows and builds the writes that change
/// it (docs/en/visitor-flow-contract.md, section 8). Steps are written as one whole value per
/// key, the scalar members as leaves, and one edit is one batch. The editor never reads the
/// resolved document: that is what a door renders.
struct VisitorFlowEditor {

    static let maxSteps = 32
    static let maxOptions = 12
    static let maxImages = 2
    static let limits = (title: 60, body: 600, bodyParagraphs: 8, label: 40, message: 200, alt: 120)

    let config: [String: Any]?
    let languages: [String]

    init(config: [String: Any]?, languages: [String]) {
        self.config = config
        self.languages = languages.isEmpty ? ["ja"] : languages
    }

    // MARK: Reading

    var raw: [String: Any] { return ConfigUtil.dig(config, "visitor_flow") as? [String: Any] ?? [:] }

    var steps: [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for (id, value) in raw["steps"] as? [String: Any] ?? [:] {
            if let step = value as? [String: Any] { result[id] = step }
        }
        return result
    }

    /// While no step was ever written Core serves a built-in wizard and nothing is stored.
    var isBuiltIn: Bool { return steps.isEmpty }

    var enabled: Bool { return raw["enabled"] as? Bool ?? true }
    var start: String { return raw["start"] as? String ?? "" }
    var requireCall: Bool { return raw["require_call"] as? Bool ?? true }
    var idleSeconds: Int {
        return min(300, max(15, (raw["idle_s"] as? NSNumber)?.intValue ?? 45))
    }

    func doorStart(_ door: String) -> String {
        return ConfigUtil.str(config, "doors.\(door).visitor_flow.start") ?? ""
    }

    func kind(_ id: String) -> String { return steps[id]?["kind"] as? String ?? "" }

    func ids(ofKind kind: String) -> [String] {
        return orderedStepIds().filter { self.kind($0) == kind }
    }

    /// Steps are an unordered pool. They are listed start page first, then in the order they are
    /// reached, then whatever is left by id.
    func orderedStepIds() -> [String] {
        let all = steps
        var seen: [String] = []
        var queue = [start].filter { all[$0] != nil }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if seen.contains(id) { continue }
            seen.append(id)
            queue.append(contentsOf: VisitorFlowEditor.targets(of: all[id] ?? [:]).filter {
                all[$0] != nil && !seen.contains($0)
            })
        }
        return seen + all.keys.filter { !seen.contains($0) }.sorted()
    }

    static func targets(of step: [String: Any]) -> [String] {
        var out: [String] = []
        for case let option as [String: Any] in step["options"] as? [Any] ?? [] {
            if let to = option["to"] as? String { out.append(to) }
        }
        for key in ["to", "on_unanswered"] {
            if let to = step[key] as? String { out.append(to) }
        }
        return out
    }

    /// Steps (and the start settings) that point at `id`.
    func referencers(of id: String) -> [String] {
        var result = steps.filter { $0.key != id && VisitorFlowEditor.targets(of: $0.value).contains(id) }
            .map { $0.key }.sorted()
        if start == id { result.append("start") }
        if let doors = ConfigUtil.dig(config, "doors") as? [String: Any] {
            for door in doors.keys.sorted() where doorStart(door) == id { result.append("doors.\(door)") }
        }
        return result
    }

    /// First non-empty title in the language, then the first language that has one, then the id.
    func displayTitle(_ id: String, lang: String) -> String {
        guard let step = steps[id] else { return id }
        for source in [step["title"], step["message"]] {
            if let text = VisitorFlowText.text(source, lang: lang) { return text }
        }
        return id
    }

    /// The configured external cameras that can supply a still (`streams.snapshot.url`).
    func snapshotCameras() -> [String] {
        let sources = ConfigUtil.dig(config, "media_sources") as? [String: Any] ?? [:]
        return sources.keys.sorted().filter { id in
            let streams = (sources[id] as? [String: Any])?["streams"] as? [String: Any]
            return !(ConfigUtil.str(streams?["snapshot"] as? [String: Any], "url") ?? "").isEmpty
        }
    }

    // MARK: Text helpers

    /// `map` with `value` stored for `lang`; an empty value removes that language and an empty
    /// result is nil, so an optional text disappears from the step.
    static func setting(_ map: Any?, lang: String, to value: String) -> [String: Any]? {
        var result = map as? [String: Any] ?? [:]
        if value.isEmpty { result.removeValue(forKey: lang) } else { result[lang] = value }
        return result.isEmpty ? nil : result
    }

    static func paragraphCount(_ text: String) -> Int {
        return text.components(separatedBy: "\n\n").filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    // MARK: Ids

    func newStepId() -> String {
        var id = SettingValidation.newId("s")
        while steps[id] != nil { id = SettingValidation.newId("s") }
        return id
    }

    static func newOptionId(in options: [[String: Any]]) -> String {
        let used = Set(options.compactMap { $0["id"] as? String })
        var id = SettingValidation.newId("o")
        while used.contains(id) { id = SettingValidation.newId("o") }
        return id
    }

    // MARK: Writes

    static let prefix = "visitor_flow.steps."

    static func write(_ id: String, _ step: [String: Any]) -> ConfigWriter.Operation {
        return .set(prefix + id, step)
    }

    /// The step with `change` applied, as one whole-value write.
    func update(_ id: String, _ change: (inout [String: Any]) -> Void) -> [ConfigWriter.Operation] {
        guard var step = steps[id] else { return [] }
        change(&step)
        return [VisitorFlowEditor.write(id, step)]
    }

    func updateOption(_ id: String, option optionId: String,
                      _ change: (inout [String: Any]) -> Void) -> [ConfigWriter.Operation] {
        return update(id) { step in
            var options = step["options"] as? [[String: Any]] ?? []
            guard let index = options.firstIndex(where: { $0["id"] as? String == optionId }) else { return }
            change(&options[index])
            step["options"] = options
        }
    }

    /// Sets or clears the primary flag; at most one option of a page may be primary.
    func setPrimary(_ id: String, option optionId: String, on: Bool) -> [ConfigWriter.Operation] {
        return update(id) { step in
            var options = step["options"] as? [[String: Any]] ?? []
            for index in options.indices {
                if options[index]["id"] as? String == optionId {
                    if on { options[index]["style"] = "primary" } else { options[index].removeValue(forKey: "style") }
                } else if on {
                    options[index].removeValue(forKey: "style")
                }
            }
            step["options"] = options
        }
    }

    func moveOption(_ id: String, option optionId: String, by offset: Int) -> [ConfigWriter.Operation] {
        return update(id) { step in
            var options = step["options"] as? [[String: Any]] ?? []
            guard let index = options.firstIndex(where: { $0["id"] as? String == optionId }),
                  options.indices.contains(index + offset) else { return }
            options.swapAt(index, index + offset)
            step["options"] = options
        }
    }

    func deleteOption(_ id: String, option optionId: String) -> [ConfigWriter.Operation] {
        return update(id) { step in
            var options = step["options"] as? [[String: Any]] ?? []
            options.removeAll { $0["id"] as? String == optionId }
            step["options"] = options
        }
    }

    /// Writes for a new step of `kind`. A page arrives with one option leading to a call step, and
    /// a notify with the end step it needs, so the batch is valid on its own.
    func newStep(kind: String, defaults: (_ key: String) -> [String: Any]) -> (id: String, ops: [ConfigWriter.Operation]) {
        let id = newStepId()
        var ops: [ConfigWriter.Operation] = []
        let existingCall = ids(ofKind: "call").first
        let existingEnd = ids(ofKind: "end").first
        func companion(_ kind: String, _ existing: String?, _ make: () -> [String: Any]) -> String {
            if let existing = existing { return existing }
            let extra = SettingValidation.newId(kind == "call" ? "c" : "e")
            ops.append(VisitorFlowEditor.write(extra, make()))
            return extra
        }
        switch kind {
        case "page":
            let call = companion("call", existingCall) { ["kind": "call"] }
            ops.insert(VisitorFlowEditor.write(id, [
                "kind": "page", "title": defaults("flow_editor.new_page_title"),
                "options": [["id": SettingValidation.newId("o"), "label": defaults("flow_editor.new_option_label"),
                             "style": "primary", "to": call]],
            ]), at: 0)
        case "call":
            ops.append(VisitorFlowEditor.write(id, ["kind": "call"]))
        case "notify":
            let end = companion("end", existingEnd) {
                ["kind": "end", "title": defaults("core.flow.thanks_title"), "return_s": 8]
            }
            ops.insert(VisitorFlowEditor.write(id, ["kind": "notify",
                                                   "message": defaults("flow_editor.new_message"),
                                                   "to": end]), at: 0)
        default:
            ops.append(VisitorFlowEditor.write(id, ["kind": "end", "title": defaults("core.flow.thanks_title"),
                                                   "return_s": 8]))
        }
        return (id, ops)
    }

    func duplicate(_ id: String) -> (id: String, ops: [ConfigWriter.Operation])? {
        guard let step = steps[id], steps.count < VisitorFlowEditor.maxSteps else { return nil }
        let copy = newStepId()
        return (copy, [VisitorFlowEditor.write(copy, step)])
    }

    /// Nil while another step, the start page or a door still points here: the batch would not
    /// validate, so the editor names the referrers instead.
    func delete(_ id: String) -> [ConfigWriter.Operation]? {
        guard steps[id] != nil, referencers(of: id).isEmpty else { return nil }
        return [.delete(VisitorFlowEditor.prefix + id)]
    }

    /// Replaces the flow with a template's configuration-shaped `flow`: its scalar leaves, one
    /// whole step each, and a delete for every current step the template does not have.
    func templateOperations(_ flow: [String: Any]) -> [ConfigWriter.Operation] {
        var ops: [ConfigWriter.Operation] = []
        for key in ["enabled", "start", "idle_s", "require_call"] {
            if let value = flow[key] { ops.append(.set("visitor_flow." + key, value)) }
        }
        let templateSteps = flow["steps"] as? [String: Any] ?? [:]
        for id in templateSteps.keys.sorted() {
            ops.append(.set(VisitorFlowEditor.prefix + id, templateSteps[id] as Any))
        }
        for id in steps.keys.sorted() where templateSteps[id] == nil {
            ops.append(.delete(VisitorFlowEditor.prefix + id))
        }
        return ops
    }

    static let resetOperations: [ConfigWriter.Operation] = [.delete("visitor_flow")]

    // MARK: Errors

    /// The i18n key and detail for a Core refusal: `visitor_flow.<code>[: <step>[.<option>]]`.
    static func errorKey(_ code: String) -> (key: String, detail: String)? {
        guard code.hasPrefix("visitor_flow.") else { return nil }
        let parts = code.components(separatedBy: ": ")
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }
}
