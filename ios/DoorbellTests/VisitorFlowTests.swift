import XCTest

@testable import Doorbell

final class VisitorFlowTests: XCTestCase {

    static func fixtureURL() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("tools/conformance/fixtures/visitor-flow-v1.json")
    }

    static func loadSuite() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL())
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func flows(_ suite: [String: Any]) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for case let item as [String: Any] in suite["resolve"] as? [Any] ?? [] {
            if let name = item["name"] as? String, let expect = item["expect"] as? [String: Any] {
                out[name] = expect
            }
        }
        return out
    }

    private func snapshot(from dict: [String: Any]) -> VisitorFlowSnapshot {
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

    /// Applies one fixture event and returns the Core calls it caused, the way the shell would
    /// perform them: a notify result feeds back into the walker, then a press result.
    private func apply(_ event: [String: Any], to walker: VisitorFlowWalker,
                       flows: [String: [String: Any]]) throws -> [[String: String]] {
        var calls: [[String: String]] = []
        if let reply = event["reply"] as? Bool {
            walker.setReply(reply)
        } else if let lang = event["lang"] as? String {
            walker.setLanguage(lang)
        } else if let name = event["flow_changed"] as? String {
            walker.replace(flow: try XCTUnwrap(flows[name]))
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
            XCTFail("unknown walk event \(event)")
        }
        return calls
    }

    func testEveryWalkCaseMatchesTheReferenceWalker() throws {
        let suite = try Self.loadSuite()
        let flows = Self.flows(suite)
        let cases = suite["walk"] as? [[String: Any]] ?? []
        XCTAssertEqual(cases.count, 21)
        for item in cases {
            let name = item["name"] as? String ?? "?"
            let walker = VisitorFlowWalker(flow: try XCTUnwrap(flows[item["flow"] as? String ?? ""]),
                                           lang: item["lang"] as? String ?? "ja")
            if let start = item["start"] as? [String: Any] {
                XCTAssertEqual(walker.snapshot(), snapshot(from: start), "\(name): start")
            }
            for (index, entry) in (item["steps"] as? [[String: Any]] ?? []).enumerated() {
                let event = entry["event"] as? [String: Any] ?? [:]
                let calls = try apply(event, to: walker, flows: flows)
                let expectedCalls = (entry["calls"] as? [[String: Any]] ?? []).map { call in
                    call.mapValues { $0 as? String ?? "" }
                }
                XCTAssertEqual(calls, expectedCalls, "\(name)[\(index)]: calls")
                XCTAssertEqual(walker.snapshot(), snapshot(from: entry["expect"] as? [String: Any] ?? [:]),
                               "\(name)[\(index)]: snapshot")
            }
        }
    }

    func testUnknownKindsAndMissingDocumentsDegradeToLegacy() {
        let walker = VisitorFlowWalker(flow: ["schema_version": 1, "enabled": false,
                                              "reason": "disabled"])
        XCTAssertEqual(walker.mode, .legacy)
        XCTAssertNil(walker.page)
        let broken = VisitorFlowWalker(flow: [:])
        XCTAssertFalse(broken.isEnabled)
    }

    func testBodyAndImagesComeFromTheDocument() {
        let doc: [String: Any] = [
            "schema_version": 1, "enabled": true, "start": "s", "idle_s": 20,
            "steps": [
                "s": ["kind": "page", "title": ["ja": "T", "en": "Title"],
                      "body": ["ja": "B", "en": "Line one\n\nLine two"],
                      "images": [["asset": "a", "path": NSNull(), "place": "below",
                                  "alt": ["ja": "A", "en": "Alt"]]],
                      "options": [["id": "o", "semantic_id": "call.primary", "style": "primary",
                                   "label": ["ja": "J", "en": "Go"], "icon": "", "to": "c"]]],
                "c": ["kind": "call"],
            ],
        ]
        let walker = VisitorFlowWalker(flow: doc, lang: "en")
        let page = walker.page
        XCTAssertEqual(page?.title, "Title")
        XCTAssertEqual(page?.body, "Line one\n\nLine two")
        XCTAssertEqual(page?.images.first?.alt, "Alt")
        XCTAssertEqual(page?.images.first?.place, "below")
        XCTAssertNil(page?.images.first?.path)
        XCTAssertEqual(page?.options.first?.isPrimary, true)
        XCTAssertEqual(walker.idleSeconds, 20)
    }

    func testSecondTapWhileACallIsPendingIsIgnored() {
        let doc: [String: Any] = [
            "enabled": true, "start": "s",
            "steps": [
                "s": ["kind": "page", "options": [["id": "o", "semantic_id": "call.primary",
                                                   "style": "primary", "label": ["ja": "x"], "to": "c"]]],
                "c": ["kind": "call", "purpose": "p"],
            ],
        ]
        let walker = VisitorFlowWalker(flow: doc)
        XCTAssertEqual(walker.tap("o"), .call(.press("p")))
        XCTAssertEqual(walker.tap("o"), .none)
        walker.pressFinished(success: true)
        XCTAssertEqual(walker.mode, .calling)
    }

    // MARK: Layout of the page renderer

    private func page(options: Int, body: String = "") -> VisitorFlowPage {
        let list = (0..<options).map { index in
            VisitorFlowOption(id: "o\(index)", semanticId: index == 0 ? "call.primary" : "purpose.button",
                              label: "Option number \(index)", icon: "", isPrimary: index == 0, purpose: "")
        }
        return VisitorFlowPage(id: "s", kind: "page", title: "Title", body: body, images: [],
                               options: list, canGoBack: true, showsDone: false)
    }

    private func laidOut(width: CGFloat, height: CGFloat, page: VisitorFlowPage) -> VisitorFlowView {
        let view = VisitorFlowView(texts: Texts())
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.viewportHeight = height
        view.render(page, notice: nil)
        for _ in 0..<3 {
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
        return view
    }

    func testOptionsUseOneColumnOnAPhoneAndTwoOnAWideScreen() {
        let phone = laidOut(width: 390, height: 700, page: page(options: 3))
        XCTAssertEqual(phone.columnsForTesting, 1)
        let buttons = phone.optionButtonsForTesting
        XCTAssertEqual(Set(buttons.map { $0.convert($0.bounds, to: phone).minX }).count, 1)
        let wide = laidOut(width: 820, height: 1000, page: page(options: 3))
        XCTAssertEqual(wide.columnsForTesting, 2)
        let secondRow = wide.optionButtonsForTesting.dropFirst().map { $0.convert($0.bounds, to: wide).minY }
        XCTAssertEqual(Set(secondRow).count, 1, "the two normal options share a row")
    }

    func testEveryOptionIsAtLeastTheVisitorTouchMinimum() {
        let view = laidOut(width: 390, height: 700, page: page(options: 4))
        for button in view.optionButtonsForTesting {
            XCTAssertGreaterThanOrEqual(button.bounds.height, 72)
        }
    }

    func testOptionZoneNeverExceedsHalfTheViewportAndScrollsInternally() {
        let view = laidOut(width: 390, height: 700, page: page(options: 12))
        let zone = view.optionZoneForTesting
        XCTAssertLessThanOrEqual(zone.bounds.height, 350.5)
        XCTAssertTrue(zone.isScrollEnabled)
        XCTAssertGreaterThan(zone.contentSize.height, zone.bounds.height)
        let frame = zone.convert(zone.bounds, to: view)
        XCTAssertLessThanOrEqual(frame.maxY, view.bounds.height + 0.5)
    }

    func testOptionZoneStaysAtTheBottomWhileTheContentScrolls() {
        let long = (0..<60).map { "Line \($0)" }.joined(separator: "\n")
        let view = laidOut(width: 390, height: 700, page: page(options: 2, body: long))
        let zone = view.optionZoneForTesting
        let content = view.contentZoneForTesting
        XCTAssertGreaterThan(content.contentSize.height, content.bounds.height)
        XCTAssertFalse(zone.isScrollEnabled)
        XCTAssertLessThanOrEqual(zone.convert(zone.bounds, to: view).maxY, view.bounds.height + 0.5)
        XCTAssertGreaterThan(zone.convert(zone.bounds, to: view).minY, content.convert(content.bounds, to: view).minY)
    }

    func testTapOnAnOptionReportsItsId() {
        let view = laidOut(width: 390, height: 700, page: page(options: 2))
        var tapped = ""
        view.onOption = { tapped = $0 }
        view.optionButtonsForTesting[1].sendActions(for: .touchUpInside)
        XCTAssertEqual(tapped, "o1")
    }
}
