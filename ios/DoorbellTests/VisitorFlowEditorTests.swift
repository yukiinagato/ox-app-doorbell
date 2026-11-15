import XCTest

@testable import Doorbell

/// The visitor-flow editor writes whole steps and scalar leaves, never a container and never a
/// key below a step, and one edit is one batch (docs/en/visitor-flow-contract.md, section 8).
final class VisitorFlowEditorTests: XCTestCase {

    private func flowConfig() -> [String: Any] {
        return [
            "ui": ["languages": ["ja", "en"]],
            "visit_purposes": ["p_delivery": ["label": ["ja": "宅配便", "en": "Delivery"], "icon": "📦", "order": 1]],
            "media_sources": [
                "porch": ["streams": ["snapshot": ["url": "http://192.0.2.10/s.jpg"]]],
                "video_only": ["streams": ["mjpeg": ["url": "http://192.0.2.11/v"]]],
            ],
            "doors": ["d_front": ["label": ["ja": "玄関", "en": "Front"]]],
            "visitor_flow": [
                "enabled": true, "start": "s_home", "idle_s": 45, "require_call": true,
                "steps": [
                    "s_home": ["kind": "page", "title": ["ja": "ご用件", "en": "How can we help?"],
                               "options": [
                                   ["id": "o_call", "label": ["en": "Call"], "style": "primary", "to": "c_any"],
                                   ["id": "o_parcel", "purpose": "p_delivery", "to": "s_parcel"]]],
                    "s_parcel": ["kind": "page", "title": ["en": "Leave it?"],
                                 "options": [["id": "o_leave", "label": ["en": "Leave"], "to": "n_left"],
                                             ["id": "o_hand", "label": ["en": "Hand"], "to": "c_any"]]],
                    "c_any": ["kind": "call"],
                    "n_left": ["kind": "notify", "message": ["en": "Left"], "to": "e_thanks"],
                    "e_thanks": ["kind": "end", "title": ["en": "Thanks"], "return_s": 8],
                ],
            ],
        ]
    }

    private func catalog(_ config: [String: Any]) -> SettingsCatalog {
        let ctx = SettingsContext(config: config, status: [:], nodeId: "node1", name: "door",
                                  role: "door_station", door: "d_front", uiLang: "en", isTV: false)
        return SettingsCatalog(ctx, texts: Texts())
    }

    private func pages(_ config: [String: Any]) -> VisitorFlowPages {
        let ctx = SettingsContext(config: config, status: [:], nodeId: "node1", name: "door",
                                  role: "door_station", door: "d_front", uiLang: "en", isTV: false)
        return VisitorFlowPages(ctx, texts: Texts())
    }

    private func ops(_ effect: SettingEffect?) -> [ConfigWriter.Operation] {
        guard case .write(let ops)? = effect else { return [] }
        return ops
    }

    private func isInvalid(_ effect: SettingEffect?, _ key: String? = nil) -> Bool {
        if case .invalid(let found)? = effect { return key == nil || key == found }
        return false
    }

    // MARK: Reading

    func testStepsAreListedStartFirstThenInReachedOrder() {
        let editor = VisitorFlowEditor(config: flowConfig(), languages: ["ja", "en"])
        XCTAssertEqual(editor.orderedStepIds(), ["s_home", "c_any", "s_parcel", "n_left", "e_thanks"])
        XCTAssertFalse(editor.isBuiltIn)
        XCTAssertEqual(editor.referencers(of: "c_any"), ["s_home", "s_parcel"])
        XCTAssertEqual(editor.referencers(of: "s_home"), ["start"])
        XCTAssertEqual(editor.snapshotCameras(), ["porch"])
        XCTAssertTrue(VisitorFlowEditor(config: [:], languages: []).isBuiltIn)
    }

    // MARK: Whole-step writes

    func testTextEditWritesTheWholeStepNotALeafBelowIt() throws {
        let item = try XCTUnwrap(pages(flowConfig()).stepPage("s_parcel").item("s_parcel_title_en"))
        let written = ops(item.commit?(.string("Can you leave it?")))
        XCTAssertEqual(written.map { $0.key }, ["visitor_flow.steps.s_parcel"])
        let step = try XCTUnwrap(written.first?.value as? [String: Any])
        XCTAssertEqual((step["title"] as? [String: Any])?["en"] as? String, "Can you leave it?")
        XCTAssertEqual((step["options"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(step["kind"] as? String, "page")
    }

    func testClearingATextRemovesTheLanguageAndThenTheMember() throws {
        let item = try XCTUnwrap(pages(flowConfig()).stepPage("s_parcel").item("s_parcel_title_en"))
        let step = try XCTUnwrap(ops(item.commit?(.string(""))).first?.value as? [String: Any])
        XCTAssertNil(step["title"])
    }

    func testTextLimitsAreCheckedBeforeCore() throws {
        let page = pages(flowConfig()).stepPage("s_parcel")
        XCTAssertTrue(isInvalid(page.item("s_parcel_title_en")?.commit?(.string(String(repeating: "a", count: 61))),
                                "visitor_flow.bad_text"))
        let body = try XCTUnwrap(page.item("s_parcel_body_en"))
        XCTAssertTrue(isInvalid(body.commit?(.string(String(repeating: "x", count: 601)))))
        let paragraphs = (1...9).map { "p\($0)" }.joined(separator: "\n\n")
        XCTAssertTrue(isInvalid(body.commit?(.string(paragraphs))))
        XCTAssertFalse(isInvalid(body.commit?(.string("Line one\n\nLine two"))))
    }

    func testOnlyOneOptionOfAPageCanBePrimary() throws {
        let item = try XCTUnwrap(pages(flowConfig()).optionPageItem("s_home", "o_parcel", "primary"))
        let step = try XCTUnwrap(ops(item.commit?(.bool(true))).first?.value as? [String: Any])
        let options = try XCTUnwrap(step["options"] as? [[String: Any]])
        XCTAssertEqual(options.filter { $0["style"] as? String == "primary" }.compactMap { $0["id"] as? String },
                       ["o_parcel"])
    }

    func testOptionTargetPurposeAndReorder() throws {
        let editor = VisitorFlowEditor(config: flowConfig(), languages: ["en"])
        let moved = try XCTUnwrap(editor.moveOption("s_parcel", option: "o_leave", by: 1).first?.value as? [String: Any])
        XCTAssertEqual((moved["options"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["o_hand", "o_leave"])
        XCTAssertTrue(editor.moveOption("s_parcel", option: "o_hand", by: -1).first.map { _ in true } ?? false)
        let retarget = pages(flowConfig()).optionPageItem("s_home", "o_call", "target")
        let step = ops(retarget?.commit?(.string("s_parcel"))).first?.value as? [String: Any]
        XCTAssertEqual((step?["options"] as? [[String: Any]])?.first?["to"] as? String, "s_parcel")
    }

    func testAnOptionNeedsALabelOrAPurpose() {
        let label = pages(flowConfig()).optionPageItem("s_home", "o_call", "label_en")
        XCTAssertTrue(isInvalid(label?.commit?(.string("")), "visitor_flow.option_needs_label"))
        let purposeOnly = pages(flowConfig()).optionPageItem("s_home", "o_parcel", "purpose")
        XCTAssertTrue(isInvalid(purposeOnly?.commit?(.string("")), "visitor_flow.option_needs_label"))
    }

    func testCallNotifyAndEndFields() throws {
        let p = pages(flowConfig())
        let call = ops(p.stepPage("c_any").item("c_any_on_unanswered")?.commit?(.string("s_parcel")))
        XCTAssertEqual((call.first?.value as? [String: Any])?["on_unanswered"] as? String, "s_parcel")
        let cleared = ops(p.stepPage("c_any").item("c_any_on_unanswered")?.commit?(.string("")))
        XCTAssertNil((cleared.first?.value as? [String: Any])?["on_unanswered"])
        let snapshot = ops(p.stepPage("n_left").item("n_left_snapshot")?.commit?(.string("camera:porch")))
        let notify = try XCTUnwrap(snapshot.first?.value as? [String: Any])
        XCTAssertEqual((notify["snapshot"] as? [String: Any])?["id"] as? String, "porch")
        XCTAssertEqual((notify["snapshot"] as? [String: Any])?["source"] as? String, "media_source")
        let own = ops(p.stepPage("n_left").item("n_left_snapshot")?.commit?(.string("door_station")))
        XCTAssertEqual(((own.first?.value as? [String: Any])?["snapshot"] as? [String: Any])?["source"] as? String,
                       "door_station")
        let none = ops(p.stepPage("n_left").item("n_left_snapshot")?.commit?(.string("none")))
        XCTAssertNil((none.first?.value as? [String: Any])?["snapshot"])
        let seconds = ops(p.stepPage("e_thanks").item("e_thanks_return_s")?.commit?(.int(500)))
        XCTAssertEqual((seconds.first?.value as? [String: Any])?["return_s"] as? Int, 60)
    }

    func testSnapshotPickerListsOnlyCamerasWithAStill() throws {
        let item = try XCTUnwrap(pages(flowConfig()).stepPage("n_left").item("n_left_snapshot"))
        guard case .choice(_, let options, _) = item.control else { return XCTFail("choice expected") }
        XCTAssertEqual(options.map { $0.value }, ["none", "camera:porch", "door_station"])
    }

    // MARK: Step list

    func testNewPageBringsACallToLeadTo() throws {
        let editor = VisitorFlowEditor(config: [:], languages: ["en"])
        let made = editor.newStep(kind: "page") { _ in ["en": "x"] }
        XCTAssertEqual(made.ops.count, 2)
        let page = try XCTUnwrap(made.ops[0].value as? [String: Any])
        let call = try XCTUnwrap(made.ops[1].value as? [String: Any])
        XCTAssertEqual(call["kind"] as? String, "call")
        let option = try XCTUnwrap((page["options"] as? [[String: Any]])?.first)
        XCTAssertEqual(made.ops[1].key, "visitor_flow.steps." + (option["to"] as? String ?? ""))
        XCTAssertTrue(made.ops.allSatisfy { $0.key.hasPrefix("visitor_flow.steps.") })
    }

    func testNewNotifyReusesAnExistingEndPage() throws {
        let editor = VisitorFlowEditor(config: flowConfig(), languages: ["en"])
        let made = editor.newStep(kind: "notify") { _ in ["en": "x"] }
        XCTAssertEqual(made.ops.count, 1)
        XCTAssertEqual((made.ops[0].value as? [String: Any])?["to"] as? String, "e_thanks")
    }

    func testStepInUseCannotBeDeletedAndAFreeOneIsASingleDelete() {
        let editor = VisitorFlowEditor(config: flowConfig(), languages: ["en"])
        XCTAssertNil(editor.delete("c_any"))
        XCTAssertNil(editor.delete("s_home"))
        var config = flowConfig()
        var flow = config["visitor_flow"] as! [String: Any]
        var steps = flow["steps"] as! [String: Any]
        steps["s_orphan"] = ["kind": "end"]
        flow["steps"] = steps
        config["visitor_flow"] = flow
        let free = VisitorFlowEditor(config: config, languages: ["en"]).delete("s_orphan")
        XCTAssertEqual(free?.map { $0.key }, ["visitor_flow.steps.s_orphan"])
        XCTAssertNil(free?.first?.value)
    }

    func testDuplicateWritesAFreshIdWithTheSameBody() throws {
        let editor = VisitorFlowEditor(config: flowConfig(), languages: ["en"])
        let copy = try XCTUnwrap(editor.duplicate("s_parcel"))
        XCTAssertNotEqual(copy.id, "s_parcel")
        XCTAssertEqual(copy.ops.map { $0.key }, ["visitor_flow.steps." + copy.id])
        XCTAssertEqual((copy.ops.first?.value as? [String: Any])?["kind"] as? String, "page")
    }

    func testStartPageDoorStartAndSwitchesAreLeaves() throws {
        let page = pages(flowConfig()).page()
        XCTAssertEqual(ops(page.item("flow_start")?.commit?(.string("s_parcel"))).map { $0.key },
                       ["visitor_flow.start"])
        XCTAssertEqual(ops(page.item("flow_idle")?.commit?(.int(999))).first?.value as? Int, 300)
        XCTAssertEqual(ops(page.item("flow_require_call")?.commit?(.bool(false))).map { $0.key },
                       ["visitor_flow.require_call"])
        XCTAssertEqual(ops(page.item("flow_enabled")?.commit?(.bool(false))).first?.value as? Bool, false)
        let inherit = ops(page.item("flow_door_start_d_front")?.commit?(.string("")))
        XCTAssertEqual(inherit.map { $0.key }, ["doors.d_front.visitor_flow.start"])
        XCTAssertNil(inherit.first?.value)
        XCTAssertEqual(ops(page.item("flow_door_start_d_front")?.commit?(.string("s_parcel"))).first?.value as? String,
                       "s_parcel")
    }

    func testNoWriteTargetsAContainerOrAKeyBelowAStep() throws {
        let p = pages(flowConfig())
        var all: [ConfigWriter.Operation] = []
        for id in VisitorFlowEditor(config: flowConfig(), languages: ["en"]).orderedStepIds() {
            for section in p.stepPage(id).sections {
                for item in section.items where item.commit != nil {
                    switch item.control {
                    case .toggle: all += ops(item.commit?(.bool(true)))
                    case .text, .longText: all += ops(item.commit?(.string("a")))
                    default: break
                    }
                }
            }
        }
        XCTAssertFalse(all.isEmpty)
        for op in all {
            XCTAssertNotEqual(op.key, "visitor_flow")
            XCTAssertNotEqual(op.key, "visitor_flow.steps")
            XCTAssertEqual(op.key.split(separator: ".").count, 3, op.key)
        }
    }

    // MARK: Templates and the built-in wizard

    func testTemplateReplacesStepsAndDeletesTheOnesItDoesNotHave() {
        let editor = VisitorFlowEditor(config: flowConfig(), languages: ["en"])
        let template: [String: Any] = [
            "enabled": true, "start": "s_home", "idle_s": 30, "require_call": true,
            "steps": ["s_home": ["kind": "page", "options": []], "c_any": ["kind": "call"]],
        ]
        let keys = editor.templateOperations(template).map { $0.key }
        XCTAssertEqual(Array(keys.prefix(4)), ["visitor_flow.enabled", "visitor_flow.start",
                                              "visitor_flow.idle_s", "visitor_flow.require_call"])
        XCTAssertTrue(keys.contains("visitor_flow.steps.s_home"))
        let deletes = editor.templateOperations(template).filter { $0.value == nil }.map { $0.key }
        XCTAssertEqual(deletes, ["visitor_flow.steps.e_thanks", "visitor_flow.steps.n_left", "visitor_flow.steps.s_parcel"])
    }

    func testBuiltInWizardOffersCustomizeNotStepEditing() {
        let page = pages([:]).page()
        XCTAssertNotNil(page.item("flow_customize"))
        XCTAssertNil(page.item("flow_steps"))
        XCTAssertNil(page.item("flow_start"))
        XCTAssertNotNil(page.item("flow_template_delivery"))
        XCTAssertNil(page.item("flow_reset"))
        let explicit = pages(flowConfig()).page()
        XCTAssertNotNil(explicit.item("flow_reset"))
        XCTAssertNotNil(explicit.item("flow_steps"))
    }

    func testResetIsOneDeleteOfTheWholeFlow() {
        XCTAssertEqual(VisitorFlowEditor.resetOperations.map { $0.key }, ["visitor_flow"])
        XCTAssertNil(VisitorFlowEditor.resetOperations.first?.value)
    }

    // MARK: Navigation and the Calls page

    func testCallsPageHostsTheEditorAndGreysTheLegacySelect() throws {
        let c = catalog(flowConfig())
        let entry = try XCTUnwrap(c.page(path: ["calls"])?.item("visitor_flow"))
        guard case .page = entry.control else { return XCTFail("page expected") }
        XCTAssertNotNil(c.page(path: ["calls", "visitor_flow", "flow_steps", "step_s_parcel", "s_parcel_opt_o_leave"]))
        guard case .info? = c.page(path: ["calls"])?.item("call_flow")?.control else {
            return XCTFail("the legacy select is greyed while steps exist")
        }
        guard case .segmented? = catalog([:]).page(path: ["calls"])?.item("call_flow")?.control else {
            return XCTFail("the select stays while the built-in wizard is in use")
        }
    }

    // MARK: Errors

    func testCoreRefusalsMapToLocalisedTextNextToTheField() {
        let texts = Texts()
        texts.setLang("en")
        XCTAssertEqual(VisitorFlowEditor.errorKey("visitor_flow.unknown_target: s_home.o_call")?.key,
                       "visitor_flow.unknown_target")
        XCTAssertEqual(VisitorFlowEditor.errorKey("visitor_flow.unknown_target: s_home.o_call")?.detail, "s_home.o_call")
        XCTAssertNil(VisitorFlowEditor.errorKey("config_persistence_failed"))
        let message = ConfigWriter.message(texts, .failed("visitor_flow.unknown_target: s_home.o_call"))
        XCTAssertTrue(message.contains("s_home.o_call"))
        XCTAssertNotEqual(message, "visitor_flow.unknown_target")
        let unknown = ConfigWriter.message(texts, .failed("visitor_flow.something_new: s_x"))
        XCTAssertTrue(unknown.contains("something_new"))
        XCTAssertEqual(ConfigWriter.message(texts, .failed("unresolved_config_conflict")),
                       texts.t("flow_editor.conflict"))
        let warned = ConfigWriter.message(texts, .ok(contrasts: [], notes: ["visitor_flow.no_call"]))
        XCTAssertTrue(warned.contains(texts.t("visitor_flow.no_call")))
    }
}

private extension VisitorFlowPages {
    func optionPageItem(_ step: String, _ option: String, _ suffix: String) -> SettingItem? {
        let page = stepPage(step)
        guard let entry = page.item("\(step)_opt_\(option)"), case .page(let build) = entry.control else { return nil }
        return build().item("\(step)_\(option)_\(suffix)")
    }
}
