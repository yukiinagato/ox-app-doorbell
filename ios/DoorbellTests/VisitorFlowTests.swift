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

    // MARK: Pending taps

    func testPendingTapIsReportedUntilTheResultAndAbandonedWithARetryNotice() {
        let walker = VisitorFlowWalker(flow: pendingFlow(), lang: "en")
        XCTAssertEqual(walker.targetKind(ofOption: "o_notify"), "notify")
        XCTAssertEqual(walker.tap("o_notify"), .call(.notify("n")))
        XCTAssertTrue(walker.pendingCall)
        XCTAssertEqual(walker.pendingOptionId, "o_notify")
        XCTAssertEqual(walker.tap("o_other"), .none, "other options are ignored while pending")
        XCTAssertEqual(walker.pendingOptionId, "o_notify")
        walker.abandonPending()
        XCTAssertFalse(walker.pendingCall)
        XCTAssertNil(walker.pendingOptionId)
        XCTAssertEqual(walker.notice, VisitorFlowWalker.pendingFailedNotice)
        XCTAssertEqual(walker.notifyFinished(ok: true), .none, "a late result changes nothing")
        XCTAssertEqual(walker.mode, .page)
        XCTAssertEqual(walker.tap("o_notify"), .call(.notify("n")), "tapping again retries")
        XCTAssertNil(walker.notice)
        _ = walker.notifyFinished(ok: true)
        XCTAssertNil(walker.pendingOptionId)
        XCTAssertEqual(walker.mode, .end)
    }

    private func pendingFlow() -> [String: Any] {
        return ["enabled": true, "start": "s", "steps": [
            "s": ["kind": "page", "options": [
                ["id": "o_notify", "label": ["en": "Leave a message"], "to": "n"],
                ["id": "o_other", "label": ["en": "Other"], "to": "e"],
            ]],
            "n": ["kind": "notify", "message": ["en": "Hi"], "to": "e"],
            "e": ["kind": "end", "title": ["en": "Thanks"]],
        ]]
    }

    func testPendingOptionKeepsItsLabelShowsActivityAndDimsTheRest() {
        let view = laidOut(width: 390, height: 800, page: page(options: 3, primary: false))
        let buttons = view.optionButtonsForTesting
        let before = buttons.map { frame($0, in: view) }
        var taps: [String] = []
        view.onOption = { taps.append($0) }
        view.setPending(optionId: "o1")
        view.layoutIfNeeded()
        XCTAssertTrue(view.activityVisible(on: 1))
        XCTAssertFalse(view.activityVisible(on: 0))
        XCTAssertEqual(buttons[1].alpha, 1)
        XCTAssertEqual(buttons[1].title(for: .normal), "Option number 1")
        XCTAssertEqual(buttons[0].alpha, 0.45, accuracy: 0.01)
        XCTAssertEqual(view.backButtonForTesting.alpha, 0.45, accuracy: 0.01)
        XCTAssertTrue(buttons.allSatisfy { !$0.isUserInteractionEnabled })
        XCTAssertFalse(view.backButtonForTesting.isUserInteractionEnabled)
        XCTAssertNotNil(buttons[1].accessibilityValue)
        XCTAssertEqual(buttons.map { frame($0, in: view) }, before, "no layout shift")
        buttons[0].sendActions(for: .touchUpInside)
        XCTAssertEqual(taps, [], "a tap while pending is ignored")
        view.setPending(optionId: "o1", status: "Notifying")
        XCTAssertEqual(view.noticeForTesting.text, "Notifying")
        XCTAssertFalse(view.noticeForTesting.isHidden)
        view.setPending(optionId: nil)
        XCTAssertFalse(view.activityVisible(on: 1))
        XCTAssertTrue(buttons.allSatisfy { $0.isUserInteractionEnabled && $0.alpha == 1 })
        buttons[0].sendActions(for: .touchUpInside)
        XCTAssertEqual(taps, ["o0"])
    }

    // MARK: Layout of the page renderer

    private func page(options: Int, body: String = "", primary: Bool = true, purposes: Bool = false,
                      icon: String = "") -> VisitorFlowPage {
        let list = (0..<options).map { index in
            VisitorFlowOption(id: "o\(index)", semanticId: primary && index == 0 ? "call.primary" : "purpose.button",
                              label: "Option number \(index)", icon: icon, isPrimary: primary && index == 0,
                              purpose: purposes ? ["p_visit", "p_delivery", "p_mail", "p_sales", "p_work", "p_other"][index % 6] : "")
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

    private func frame(_ child: UIView, in view: UIView) -> CGRect {
        return child.convert(child.bounds, to: view)
    }

    func testOptionsAreEqualCardsInTwoColumnsOnAPhoneAndThreeOnAWideScreen() {
        let phone = laidOut(width: 390, height: 800, page: page(options: 6, primary: false, purposes: true))
        XCTAssertEqual(phone.columnsForTesting, 2)
        let phoneButtons = phone.optionButtonsForTesting
        XCTAssertEqual(Set(phoneButtons.map { frame($0, in: phone).minX }).count, 2)
        XCTAssertEqual(Set(phoneButtons.map { frame($0, in: phone).width.rounded() }).count, 1, "equal cards")
        let wide = laidOut(width: 820, height: 1000, page: page(options: 6, primary: false, purposes: true))
        XCTAssertEqual(wide.columnsForTesting, 3)
        XCTAssertEqual(Set(wide.optionButtonsForTesting.map { frame($0, in: wide).minY.rounded() }).count, 2)
    }

    func testAPrimaryOptionTakesTheFullRowAndTheRestShareRows() {
        let view = laidOut(width: 390, height: 800, page: page(options: 3))
        let buttons = view.optionButtonsForTesting
        XCTAssertGreaterThan(frame(buttons[0], in: view).width, frame(buttons[1], in: view).width * 1.8)
        XCTAssertEqual(frame(buttons[1], in: view).minY.rounded(), frame(buttons[2], in: view).minY.rounded())
    }

    func testEveryOptionIsAtLeastTheVisitorTouchMinimum() {
        let view = laidOut(width: 390, height: 700, page: page(options: 4))
        for button in view.optionButtonsForTesting {
            XCTAssertGreaterThanOrEqual(button.bounds.height, 72)
        }
    }

    func testTitleAndGridFormOneCentredBlockWithoutAFloatingTitle() {
        let view = laidOut(width: 390, height: 800, page: page(options: 4, primary: false, purposes: true))
        let title = frame(view.titleForTesting, in: view)
        let grid = frame(view.optionGridForTesting, in: view)
        XCTAssertLessThan(grid.minY - title.maxY, 40, "the options follow the title directly")
        let zone = frame(view.contentZoneForTesting, in: view)
        let top = title.minY - zone.minY, bottom = zone.maxY - grid.maxY
        XCTAssertEqual(top, bottom, accuracy: 24, "the block is centred above the fixed bottom zone")
        XCTAssertGreaterThan(top, 40, "and does not hug the top edge")
    }

    func testEveryNonPrimaryOptionOfAnIconPageGetsTheSameIconSize() {
        let view = laidOut(width: 390, height: 800, page: page(options: 4, primary: false, purposes: true))
        let sizes = view.optionButtonsForTesting.map { $0.imageView?.frame.size ?? .zero }
        XCTAssertEqual(Set(sizes.map { "\($0.width)x\($0.height)" }).count, 1)
        XCTAssertEqual(sizes[0].width, FlowOptionButton.iconSize)
        let unknown = laidOut(width: 390, height: 800, page: page(options: 2, primary: false, icon: "\u{1F9FF}"))
        XCTAssertTrue(unknown.optionButtonsForTesting.allSatisfy { $0.image(for: .normal) != nil },
                      "an unknown icon falls back to the person glyph")
        let plain = laidOut(width: 390, height: 800, page: page(options: 2, primary: false))
        XCTAssertTrue(plain.optionButtonsForTesting.allSatisfy { $0.image(for: .normal) == nil },
                      "an option with neither purpose nor icon stays text only")
    }

    func testLongPagesScrollAsAWholeWhileBackStaysFixed() {
        let long = (0..<60).map { "Line \($0)" }.joined(separator: "\n")
        let view = laidOut(width: 390, height: 700, page: page(options: 2, body: long))
        let content = view.contentZoneForTesting
        XCTAssertGreaterThan(content.contentSize.height, content.bounds.height)
        XCTAssertLessThanOrEqual(frame(content, in: view).maxY, view.bounds.height)
    }

    func testManyOptionsScrollInsideTheOneContentZone() {
        let view = laidOut(width: 390, height: 600, page: page(options: 12, primary: false, purposes: true))
        let content = view.contentZoneForTesting
        XCTAssertGreaterThan(content.contentSize.height, content.bounds.height)
    }

    func testTapOnAnOptionReportsItsId() {
        let view = laidOut(width: 390, height: 700, page: page(options: 2))
        var tapped = ""
        view.onOption = { tapped = $0 }
        view.optionButtonsForTesting[1].sendActions(for: .touchUpInside)
        XCTAssertEqual(tapped, "o1")
    }

    // MARK: Icons and preview

    func testPurposeIdsAndEmojiMapToTheVendoredSet() {
        XCTAssertEqual(AppIcon.flowGlyph(purpose: "p_visit", icon: ""), .home)
        XCTAssertEqual(AppIcon.flowGlyph(purpose: "p_delivery", icon: "\u{1F4E6}"), .parcel)
        XCTAssertEqual(AppIcon.flowGlyph(purpose: "p_mail", icon: ""), .mail)
        XCTAssertEqual(AppIcon.flowGlyph(purpose: "p_sales", icon: ""), .sales)
        XCTAssertEqual(AppIcon.flowGlyph(purpose: "p_work", icon: ""), .work)
        XCTAssertEqual(AppIcon.flowGlyph(purpose: "p_other", icon: ""), .ellipsis)
        XCTAssertEqual(AppIcon.flowGlyph(purpose: "p_custom", icon: "\u{2709}\u{FE0F}"), .mail)
        XCTAssertEqual(AppIcon.flowGlyph(purpose: "p_custom", icon: "\u{1F527}"), .work)
        XCTAssertEqual(AppIcon.flowGlyph(purpose: "p_custom", icon: "\u{2753}"), .ellipsis)
        XCTAssertEqual(AppIcon.flowGlyph(purpose: "", icon: "\u{1F9FF}"), .person)
        XCTAssertEqual(AppIcon.flowGlyph(purpose: "p_gardener", icon: ""), .person)
        for choice in AppIcon.flowChoices {
            XCTAssertEqual(AppIcon.flowGlyph(purpose: "", icon: choice.emoji), choice.icon)
            XCTAssertNotNil(AppIcon.image(choice.icon))
        }
    }

    func testPreviewReportsTheTerminalActionWithoutCallingAnything() {
        let doc: [String: Any] = [
            "enabled": true, "start": "s",
            "steps": [
                "s": ["kind": "page", "options": [
                    ["id": "o1", "semantic_id": "purpose.button", "label": ["en": "Parcel"], "to": "n"],
                    ["id": "o2", "semantic_id": "purpose.button", "label": ["en": "Ring"], "to": "c"]]],
                "n": ["kind": "notify", "to": "e"],
                "c": ["kind": "call", "purpose": "p_visit"],
                "e": ["kind": "end", "title": ["en": "Thanks"]],
            ],
        ]
        let config: [String: Any] = ["visitor_flow": ["steps": ["n": ["kind": "notify",
            "message": ["en": "Left at the door"], "to": "e"]]]]
        let editor = VisitorFlowEditor(config: config, languages: ["en"])
        let session = FlowPreviewSession(document: doc, editor: editor, texts: Texts(), lang: "en") { _ in "Visit" }
        session.tap("o1")
        XCTAssertEqual(session.walker.mode, .end)
        XCTAssertTrue(session.banner.contains("Left at the door") || session.banner.contains("住人"), session.banner)
        session.done()
        XCTAssertEqual(session.walker.mode, .page)
        session.tap("o2")
        XCTAssertEqual(session.walker.mode, .page, "a press stays on the page")
        XCTAssertFalse(session.banner.isEmpty)
        XCTAssertFalse(session.walker.pendingCall)
    }
}
