import Foundation

/// Resolved visitor-flow document walker (docs/en/visitor-flow-contract.md, section 5). It only
/// consumes the resolved document Core publishes; it never reads raw `visitor_flow` configuration
/// and never invents text. Foundation only: no UI, no Core calls.
enum VisitorFlowCall: Equatable {
    case press(String)
    case notify(String)
}

struct VisitorFlowImage: Equatable {
    let asset: String
    let path: String?
    let alt: String
    let place: String
}

struct VisitorFlowOption: Equatable {
    let id: String
    let semanticId: String
    let label: String
    let icon: String
    let isPrimary: Bool
    let purpose: String
}

/// What the screen shows for the current page or end step, in the walker's language.
struct VisitorFlowPage: Equatable {
    let id: String
    let kind: String
    let title: String
    let body: String
    let images: [VisitorFlowImage]
    let options: [VisitorFlowOption]
    let canGoBack: Bool
    let showsDone: Bool
}

/// The comparable view the conformance fixtures check (`walk[].expect`).
struct VisitorFlowSnapshot: Equatable {
    struct Option: Equatable {
        let id: String
        let semanticId: String
        let label: String
    }
    let mode: String
    let page: String?
    let title: String?
    let options: [Option]
    let back: Bool
    let done: Bool
    let notice: String?
    let reply: Bool
}

enum VisitorFlowText {
    /// The language, then Japanese, then whatever the document carries.
    static func text(_ labels: Any?, lang: String) -> String? {
        guard let map = labels as? [String: Any] else { return nil }
        for key in [lang, "ja"] {
            if let value = map[key] as? String, !value.isEmpty { return value }
        }
        for key in map.keys.sorted() {
            if let value = map[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

final class VisitorFlowWalker {
    static let noAnswerNotice = "calling.no_answer"
    static let pressFailedNotice = "flow.call_failed"
    static let pendingFailedNotice = "flow.pending_failed"
    static let maxSteps = 34
    static let defaultIdleS = 45
    static let defaultReturnS = 8

    enum Mode: String { case page, calling, end, legacy }

    private(set) var flow: [String: Any] = [:]
    private(set) var mode = Mode.legacy
    private(set) var stack: [String] = []
    private(set) var activeStep: String?
    private(set) var notice: String?
    private(set) var reply = false
    private(set) var lang: String
    /// True from a tap on a notify or call option until the shell reports the result, so a second
    /// tap cannot start a second call.
    private(set) var pendingCall = false
    /// The option whose tap is waiting on the shell; the screen shows its activity indicator.
    private(set) var pendingOptionId: String?
    private var pendingStep: String?

    init(flow: [String: Any], lang: String = "ja") {
        self.lang = lang
        load(flow)
        goHome()
    }

    // MARK: Document access

    private func load(_ document: [String: Any]) {
        let steps = document["steps"] as? [String: Any] ?? [:]
        flow = steps.count > VisitorFlowWalker.maxSteps ? [:] : document
    }

    var revision: String { return flow["revision"] as? String ?? "" }

    var isEnabled: Bool {
        return flow["enabled"] as? Bool == true && kind(of: flow["start"]) == "page"
    }

    var startId: String { return flow["start"] as? String ?? "" }

    var idleSeconds: Int {
        let value = (flow["idle_s"] as? NSNumber)?.intValue ?? VisitorFlowWalker.defaultIdleS
        return min(300, max(15, value))
    }

    var endReturnSeconds: Int {
        let value = (step(activeStep)["return_s"] as? NSNumber)?.intValue
            ?? VisitorFlowWalker.defaultReturnS
        return min(60, max(3, value))
    }

    private func step(_ id: Any?) -> [String: Any] {
        guard let id = id as? String, let steps = flow["steps"] as? [String: Any] else { return [:] }
        return steps[id] as? [String: Any] ?? [:]
    }

    private func kind(of id: Any?) -> String {
        return step(id)["kind"] as? String ?? ""
    }

    private func purpose(of id: Any?) -> String {
        return step(id)["purpose"] as? String ?? ""
    }

    private func goHome() {
        activeStep = nil
        pendingCall = false
        pendingStep = nil
        pendingOptionId = nil
        if isEnabled {
            mode = .page
            stack = [startId]
        } else {
            mode = .legacy
            stack = []
        }
    }

    // MARK: What is on screen

    var currentPageId: String? {
        switch mode {
        case .page: return stack.last
        case .end: return activeStep
        default: return nil
        }
    }

    var onStartPage: Bool { return mode == .page && stack.count <= 1 }

    var page: VisitorFlowPage? {
        guard let id = currentPageId else { return nil }
        let doc = step(id)
        var options: [VisitorFlowOption] = []
        if mode == .page {
            for case let option as [String: Any] in doc["options"] as? [Any] ?? [] {
                options.append(VisitorFlowOption(
                    id: option["id"] as? String ?? "",
                    semanticId: option["semantic_id"] as? String ?? "purpose.button",
                    label: VisitorFlowText.text(option["label"], lang: lang) ?? "",
                    icon: option["icon"] as? String ?? "",
                    isPrimary: option["style"] as? String == "primary",
                    purpose: option["purpose"] as? String ?? ""))
            }
        }
        var images: [VisitorFlowImage] = []
        for case let image as [String: Any] in doc["images"] as? [Any] ?? [] {
            images.append(VisitorFlowImage(
                asset: image["asset"] as? String ?? "",
                path: image["path"] as? String,
                alt: VisitorFlowText.text(image["alt"], lang: lang) ?? "",
                place: image["place"] as? String == "below" ? "below" : "above"))
        }
        return VisitorFlowPage(id: id, kind: mode == .end ? "end" : "page",
                               title: VisitorFlowText.text(doc["title"], lang: lang) ?? "",
                               body: VisitorFlowText.text(doc["body"], lang: lang) ?? "",
                               images: images, options: options,
                               canGoBack: mode == .page && stack.count > 1,
                               showsDone: mode == .end)
    }

    func snapshot() -> VisitorFlowSnapshot {
        let id = currentPageId
        let doc = step(id)
        var options: [VisitorFlowSnapshot.Option] = []
        if mode == .page {
            for case let option as [String: Any] in doc["options"] as? [Any] ?? [] {
                options.append(.init(id: option["id"] as? String ?? "",
                                     semanticId: option["semantic_id"] as? String ?? "",
                                     label: VisitorFlowText.text(option["label"], lang: lang) ?? ""))
            }
        }
        return VisitorFlowSnapshot(
            mode: mode.rawValue, page: id,
            title: id == nil ? nil : VisitorFlowText.text(doc["title"], lang: lang),
            options: options, back: mode == .page && stack.count > 1, done: mode == .end,
            notice: notice, reply: reply)
    }

    // MARK: Input

    func setReply(_ visible: Bool) { reply = visible }

    func setLanguage(_ code: String) { lang = code }

    /// Result of a tap: the page changed, or the shell must now call Core.
    enum Intent: Equatable {
        case none
        case call(VisitorFlowCall)
    }

    /// What tapping the option leads to (`page`, `call`, `notify`, `end`), empty when unknown.
    func targetKind(ofOption optionId: String) -> String {
        guard mode == .page, let current = stack.last else { return "" }
        for case let option as [String: Any] in step(current)["options"] as? [Any] ?? [] {
            if option["id"] as? String == optionId { return kind(of: option["to"]) }
        }
        return ""
    }

    func tap(_ optionId: String) -> Intent {
        guard mode == .page, !pendingCall, let current = stack.last else { return .none }
        var chosen: [String: Any]?
        for case let option as [String: Any] in step(current)["options"] as? [Any] ?? [] {
            if option["id"] as? String == optionId { chosen = option }
        }
        guard let option = chosen else { return .none }
        notice = nil
        let target = option["to"] as? String
        switch kind(of: target) {
        case "page":
            guard let target = target else { return .none }
            if let index = stack.firstIndex(of: target) {
                stack.removeSubrange((index + 1)...)
            } else {
                stack.append(target)
            }
            return .none
        case "call":
            activeStep = target
            pendingOptionId = optionId
            return beginCall(purpose(of: target))
        case "notify":
            guard let target = target else { return .none }
            pendingCall = true
            pendingStep = target
            pendingOptionId = optionId
            return .call(.notify(target))
        case "end":
            mode = .end
            activeStep = target
            return .none
        default:
            activeStep = nil
            pendingOptionId = optionId
            return beginCall("")
        }
    }

    private func beginCall(_ purpose: String) -> Intent {
        pendingCall = true
        pendingStep = nil
        return .call(.press(purpose))
    }

    /// The notify call returned. `ok:true` (also when throttled) shows the step's end page;
    /// anything else rings instead so a visitor is never left without a result.
    func notifyFinished(ok: Bool) -> Intent {
        guard pendingCall, let target = pendingStep else { return .none }
        pendingStep = nil
        let after = step(target)["to"]
        if ok, kind(of: after) == "end" {
            pendingCall = false
            pendingOptionId = nil
            mode = .end
            activeStep = after as? String
            return .none
        }
        activeStep = nil
        return beginCall(purpose(of: target))
    }

    /// The press returned. Without a call id the visitor stays on the page with a notice.
    func pressFinished(success: Bool) {
        guard pendingCall else { return }
        pendingCall = false
        pendingOptionId = nil
        if success {
            mode = .calling
        } else {
            notice = VisitorFlowWalker.pressFailedNotice
        }
    }

    /// No result arrived in time: the options come back with a retry notice. A result that
    /// arrives later finds nothing pending and is ignored.
    func abandonPending() {
        guard pendingCall else { return }
        pendingCall = false
        pendingStep = nil
        pendingOptionId = nil
        notice = VisitorFlowWalker.pendingFailedNotice
    }

    /// An external call began (the call button of the classic screen, a remote press): the walker
    /// follows the shell's state without issuing anything.
    func callStartedElsewhere() {
        guard mode == .page || mode == .end else { return }
        pendingCall = false
        pendingStep = nil
        pendingOptionId = nil
        mode = .calling
    }

    @discardableResult
    func back() -> Bool {
        guard mode == .page, stack.count > 1, !pendingCall else { return false }
        stack.removeLast()
        notice = nil
        return true
    }

    func idleTimeout() {
        guard mode == .page, !pendingCall else { return }
        stack = Array(stack.prefix(1))
        notice = nil
    }

    func done() {
        if mode == .end { goHome() }
    }

    func callEnded(reason: String) {
        guard mode == .calling else { return }
        let unanswered = step(activeStep)["on_unanswered"]
        goHome()
        guard reason == "timeout", mode == .page else { return }
        if kind(of: unanswered) == "page", let target = unanswered as? String {
            if target != stack[0] { stack.append(target) }
        } else {
            notice = VisitorFlowWalker.noAnswerNotice
        }
    }

    /// Puts a page or end step on screen directly (the screenshot hook). A page opens as a child
    /// of the start page so Back is shown.
    func show(step id: String) {
        guard isEnabled, mode != .calling else { return }
        pendingCall = false
        pendingOptionId = nil
        switch kind(of: id) {
        case "page":
            mode = .page
            activeStep = nil
            stack = id == startId ? [startId] : [startId, id]
        case "end":
            mode = .end
            activeStep = id
        default:
            break
        }
    }

    /// A call that ended while no flow walk was calling (the shell cancelled it, for example).
    func returnToStart() {
        goHome()
    }

    func replace(flow document: [String: Any]) {
        let previousMode = mode
        let previousStack = stack
        load(document)
        if !isEnabled {
            if previousMode != .calling { goHome() } else { mode = .calling }
            return
        }
        if previousMode == .calling { return }
        if previousMode == .end, kind(of: activeStep) == "end" { return }
        let keep = previousMode == .page && previousStack.first == startId &&
            previousStack.allSatisfy { kind(of: $0) == "page" }
        goHome()
        if keep { stack = previousStack }
    }
}
