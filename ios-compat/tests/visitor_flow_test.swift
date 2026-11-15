import Foundation

// Host check of the Swift visitor-flow walker against the shared conformance fixture. The
// walker is Foundation only, so the production file is compiled here unchanged.

@main
struct VisitorFlowWalkTest {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static func snapshot(_ dict: [String: Any]) -> VisitorFlowSnapshot {
        var options: [VisitorFlowSnapshot.Option] = []
        for case let option as [String: Any] in dict["options"] as? [Any] ?? [] {
            options.append(.init(id: option["id"] as? String ?? "",
                                 semanticId: option["semantic_id"] as? String ?? "",
                                 label: option["label"] as? String ?? ""))
        }
        return VisitorFlowSnapshot(
            mode: dict["mode"] as? String ?? "", page: dict["page"] as? String,
            title: dict["title"] as? String, options: options,
            back: dict["back"] as? Bool ?? false, done: dict["done"] as? Bool ?? false,
            notice: dict["notice"] as? String, reply: dict["reply"] as? Bool ?? false)
    }

    static func main() {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url.appendPathComponent("tools/conformance/fixtures/visitor-flow-v1.json")
        guard let data = try? Data(contentsOf: url),
              let suite = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail("cannot read \(url.path)")
        }
        var flows: [String: [String: Any]] = [:]
        for case let item as [String: Any] in suite["resolve"] as? [Any] ?? [] {
            if let name = item["name"] as? String, let expect = item["expect"] as? [String: Any] {
                flows[name] = expect
            }
        }
        var checked = 0
        for case let item as [String: Any] in suite["walk"] as? [Any] ?? [] {
            let name = item["name"] as? String ?? "?"
            guard let flow = flows[item["flow"] as? String ?? ""] else { fail("\(name): unknown flow") }
            let walker = VisitorFlowWalker(flow: flow, lang: item["lang"] as? String ?? "ja")
            if let start = item["start"] as? [String: Any], walker.snapshot() != snapshot(start) {
                fail("\(name): start snapshot differs")
            }
            for (index, entry) in (item["steps"] as? [[String: Any]] ?? []).enumerated() {
                let event = entry["event"] as? [String: Any] ?? [:]
                var calls: [[String: String]] = []
                if let reply = event["reply"] as? Bool {
                    walker.setReply(reply)
                } else if let lang = event["lang"] as? String {
                    walker.setLanguage(lang)
                } else if let changed = event["flow_changed"] as? String, let next = flows[changed] {
                    walker.replace(flow: next)
                } else if let option = event["tap"] as? String {
                    var intent = walker.tap(option)
                    while case .call(let call) = intent {
                        switch call {
                        case .press(let purpose):
                            calls.append(["press": purpose])
                            walker.pressFinished(success: event["press_result"] as? String != "failed")
                            intent = .none
                        case .notify(let step):
                            calls.append(["notify": step])
                            let result = event["notify_result"] as? [String: Any] ?? ["ok": true]
                            intent = walker.notifyFinished(ok: result["ok"] as? Bool == true)
                        }
                    }
                } else if event["back"] != nil {
                    walker.back()
                } else if event["idle_timeout"] != nil {
                    walker.idleTimeout()
                } else if event["done"] != nil || event["end_timeout"] != nil {
                    walker.done()
                } else if let reason = event["call_ended"] as? String {
                    walker.callEnded(reason: reason)
                } else {
                    fail("\(name)[\(index)]: unknown event \(event)")
                }
                let expectedCalls = (entry["calls"] as? [[String: Any]] ?? []).map { $0.mapValues { $0 as? String ?? "" } }
                if calls != expectedCalls { fail("\(name)[\(index)]: calls \(calls) != \(expectedCalls)") }
                let expected = snapshot(entry["expect"] as? [String: Any] ?? [:])
                if walker.snapshot() != expected { fail("\(name)[\(index)]: snapshot \(walker.snapshot()) != \(expected)") }
                checked += 1
            }
        }
        precondition(checked > 40, "the fixture should carry many steps")
        print("visitor flow walk tests passed (\(checked) steps)")
    }
}
