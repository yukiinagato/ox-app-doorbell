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

    /// The administrator's list, the same order as Core's `step_order`: steps with a usable
    /// `order` first by ascending value, then ties and the rest in reading order.
    func orderedStepIds() -> [String] {
        return VisitorFlowEditor.listOrder(reading: readingOrder(), steps: steps)
    }

    static let maxOrder = 9999

    static func usableOrder(_ step: [String: Any]?) -> Int? {
        guard let number = step?["order"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value == value.rounded(), value >= 0, value <= Double(maxOrder) else { return nil }
        return Int(value)
    }

    static func listOrder(reading: [String], steps: [String: [String: Any]]) -> [String] {
        let ranked = reading.enumerated().map { rank, id in
            (id: id, order: usableOrder(steps[id]) ?? maxOrder + 1, rank: rank)
        }
        return ranked.sorted { ($0.order, $0.rank) < ($1.order, $1.rank) }.map { $0.id }
    }

    /// The start page, then breadth-first through option targets, notify `to` and `on_unanswered`,
    /// then whatever is unreachable by id.
    func readingOrder() -> [String] {
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

    /// `sequence` with `id` moved `offset` places, clamped to the list.
    static func moving(_ sequence: [String], _ id: String, by offset: Int) -> [String] {
        guard let index = sequence.firstIndex(of: id) else { return sequence }
        var result = sequence
        result.remove(at: index)
        result.insert(id, at: max(0, min(result.count, index + offset)))
        return result
    }

    /// Consecutive `order` values 0, 1, 2, ... for `sequence`, as whole-step writes for every step
    /// whose value changes and for every id in `forced` (a step that is being written anyway).
    /// `steps` already holds the new and modified steps; members other than `order` are untouched.
    static func sequenceOperations(_ sequence: [String], steps: [String: [String: Any]],
                                   forced: Set<String> = []) -> [ConfigWriter.Operation] {
        var ops: [ConfigWriter.Operation] = []
        for (index, id) in sequence.enumerated() {
            guard var step = steps[id] else { continue }
            guard usableOrder(step) != index || forced.contains(id) else { continue }
            step["order"] = index
            ops.append(write(id, step))
        }
        return ops
    }

    /// The writes for a new sequence of all steps after the administrator moved one.
    func reorderOperations(_ sequence: [String]) -> [ConfigWriter.Operation] {
        let known = Set(steps.keys)
        let all = sequence.filter { known.contains($0) }
        let missing = orderedStepIds().filter { !all.contains($0) }
        return VisitorFlowEditor.sequenceOperations(all + missing, steps: steps)
    }

    /// Writes that add `created` steps (each at the end of the list, or right after `anchor`) and
    /// rewrite `modified` steps, with every changed `order` in the same batch. A modified step
    /// keeps its order unless the new sequence moves it.
    func writes(creating created: [(id: String, step: [String: Any])],
                modifying modified: [(id: String, step: [String: Any])] = [],
                after anchor: String? = nil) -> [ConfigWriter.Operation] {
        var sequence = orderedStepIds()
        let newIds = created.map { $0.id }
        if let anchor = anchor, let index = sequence.firstIndex(of: anchor) {
            sequence.insert(contentsOf: newIds, at: index + 1)
        } else {
            sequence.append(contentsOf: newIds)
        }
        var all = steps
        for entry in created + modified { all[entry.id] = entry.step }
        return VisitorFlowEditor.sequenceOperations(sequence, steps: all,
                                                    forced: Set(newIds + modified.map { $0.id }))
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
    /// a notify with the end step it needs, so the batch is valid on its own. The new steps go to
    /// the end of the list.
    func newStep(kind: String, defaults: (_ key: String) -> [String: Any]) -> (id: String, ops: [ConfigWriter.Operation]) {
        let id = newStepId()
        var created: [(id: String, step: [String: Any])] = []
        let existingCall = ids(ofKind: "call").first
        let existingEnd = ids(ofKind: "end").first
        func companion(_ kind: String, _ existing: String?, _ make: () -> [String: Any]) -> String {
            if let existing = existing { return existing }
            let extra = SettingValidation.newId(kind == "call" ? "c" : "e")
            created.append((extra, make()))
            return extra
        }
        var main: [String: Any]
        switch kind {
        case "page":
            let call = companion("call", existingCall) { ["kind": "call"] }
            main = ["kind": "page", "title": defaults("flow_editor.new_page_title"),
                    "options": [["id": SettingValidation.newId("o"), "label": defaults("flow_editor.new_option_label"),
                                 "style": "primary", "to": call]]]
        case "call":
            main = ["kind": "call"]
        case "notify":
            let end = companion("end", existingEnd) {
                ["kind": "end", "title": defaults("core.flow.thanks_title"), "return_s": 8]
            }
            main = ["kind": "notify", "message": defaults("flow_editor.new_message"), "to": end]
        default:
            main = ["kind": "end", "title": defaults("core.flow.thanks_title"), "return_s": 8]
        }
        created.insert((id, main), at: 0)
        return (id, writes(creating: created))
    }

    /// The copy goes right after the original and the sequence is renumbered in the same batch.
    func duplicate(_ id: String) -> (id: String, ops: [ConfigWriter.Operation])? {
        guard let step = steps[id], steps.count < VisitorFlowEditor.maxSteps else { return nil }
        let copy = newStepId()
        return (copy, writes(creating: [(copy, step)], after: id))
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

    /// The i18n key and detail for a Core refusal: `visitor_flow.<code>[: <location>]`.
    static func errorKey(_ code: String) -> (key: String, detail: String)? {
        guard let issue = FlowIssue.parse(code, detail: [:]) else { return nil }
        return ("visitor_flow." + issue.code, issue.location)
    }
}

/// One refusal or warning of a visitor-flow write: `visitor_flow.<code>[: <location>]` plus the
/// numbers Core attaches in `detail` (docs/en/visitor-flow-contract.md, section 8.1). Pure value;
/// the settings host decides where it is shown.
struct FlowIssue: Equatable {
    let code: String
    let location: String
    let detail: [String: String]
    let isWarning: Bool

    static let placeholderOrder = ["lang", "limit", "value", "min", "max"]

    init(code: String, location: String = "", detail: [String: String] = [:], isWarning: Bool = false) {
        self.code = code
        self.location = location
        self.detail = detail
        self.isWarning = isWarning
    }

    static func parse(_ err: String, detail: [String: String]) -> FlowIssue? {
        guard err.hasPrefix("visitor_flow.") else { return nil }
        let body = err.dropFirst("visitor_flow.".count)
        let parts = body.components(separatedBy: ": ")
        let code = parts[0]
        guard !code.isEmpty, !code.contains(" ") else { return nil }
        return FlowIssue(code: code, location: parts.count > 1 ? parts[1...].joined(separator: ": ") : "",
                         detail: detail)
    }

    /// A warning of a successful write: the key is `visitor_flow.steps.<location>`.
    static func warning(key: String, messageKey: String) -> FlowIssue? {
        guard messageKey.hasPrefix("visitor_flow.") else { return nil }
        let location = key.hasPrefix("visitor_flow.steps.") ? String(key.dropFirst("visitor_flow.steps.".count)) : ""
        return FlowIssue(code: String(messageKey.dropFirst("visitor_flow.".count)), location: location,
                         isWarning: true)
    }

    var rawCode: String { return "visitor_flow." + code + (location.isEmpty ? "" : ": " + location) }

    private var catalogKey: String { return "flow_error." + code }

    func isKnown(_ texts: Texts) -> Bool { return texts.t(catalogKey) != catalogKey }

    /// The localized message with the placeholders filled in the order the catalog uses them; a
    /// code the catalog does not know falls back to the generic message.
    func message(_ texts: Texts) -> String {
        guard isKnown(texts) else { return texts.t("visitor_flow.invalid", code) }
        let args: [CVarArg] = FlowIssue.placeholderOrder.compactMap { name in
            guard let value = detail[name] else { return nil }
            return name == "lang" ? Texts.langDisplayName(value) : value
        }
        return args.isEmpty ? texts.t(catalogKey) : texts.t(catalogKey, list: args)
    }

    /// Secondary text under an unknown code: the raw code, so a newer Core stays diagnosable.
    func secondary(_ texts: Texts) -> String { return isKnown(texts) ? "" : rawCode }

    /// Row ids of the editor pages that show the located control, most specific first. A page
    /// uses the first one it has; none means the banner at the top of that page.
    var candidateItemIds: [String] {
        if location == "start" { return ["flow_start"] }
        let parts = location.components(separatedBy: ".")
        if parts.count == 3, parts[0] == "doors", parts[2] == "start" { return ["flow_door_start_" + parts[1]] }
        guard let step = parts.first, !step.isEmpty else { return [] }
        let rest = Array(parts.dropFirst())
        var ids: [String] = []
        func field(_ name: String) { ids.append("\(step)_\(name)") }
        if let first = rest.first {
            switch first {
            case "title", "body", "message":
                if rest.count > 1 { field("\(first)_\(rest[1])") }
                if first == "message" { field("to") }
            case "images":
                break
            default:
                if first.hasPrefix("images[") {
                    let index = first.dropFirst("images[".count).dropLast()
                    if rest.count > 2, rest[1] == "alt" { field("img\(index)_alt_\(rest[2])") }
                    field("img\(index)_asset")
                    field("img_\(index)")
                } else {
                    let option = first
                    if rest.count > 2, rest[1] == "label" { ids.append("\(step)_\(option)_label_\(rest[2])") }
                    if let name = FlowIssue.optionField[code] { ids.append("\(step)_\(option)_\(name)") }
                    ids.append("\(step)_opt_\(option)")
                }
            }
        } else if let name = FlowIssue.stepField[code] {
            field(name)
        }
        ids.append("\(step)_kind")
        ids.append("step_\(step)")
        return ids
    }

    private static let optionField = [
        "missing_target": "target", "bad_target": "target", "unknown_target": "target",
        "bad_icon": "icon", "bad_style": "primary", "bad_enabled": "enabled",
        "bad_purpose": "purpose", "unknown_purpose": "purpose", "disabled_purpose": "purpose",
        "option_needs_label": "purpose", "no_options": "delete",
    ]

    private static let stepField = [
        "bad_return_s": "return_s", "bad_purpose": "purpose", "unknown_purpose": "purpose",
        "disabled_purpose": "purpose", "missing_target": "to", "bad_target": "to", "unknown_target": "to",
        "bad_target_kind": "to", "bad_snapshot": "snapshot", "bad_snapshot_source": "snapshot",
        "bad_snapshot_camera": "snapshot", "unknown_camera": "snapshot",
    ]
}
