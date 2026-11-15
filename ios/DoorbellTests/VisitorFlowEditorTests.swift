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

    // MARK: Order

    private func orderedConfig(_ orders: [String: Int]) -> [String: Any] {
        var config = flowConfig()
        var flow = config["visitor_flow"] as! [String: Any]
        var steps = flow["steps"] as! [String: Any]
        for (id, order) in orders {
            var step = steps[id] as! [String: Any]
            step["order"] = order
            steps[id] = step
        }
        flow["steps"] = steps
        config["visitor_flow"] = flow
        return config
    }

    func testListFollowsCoresStepOrderRules() {
        let all = Dictionary(uniqueKeysWithValues: ["s_home", "c_any", "s_parcel", "n_left", "e_thanks"].map { ($0, [String: Any]()) })
        var steps = all
        steps["e_thanks"] = ["order": 0]
        steps["c_any"] = ["order": 1]
        steps["n_left"] = ["order": 1]
        steps["s_parcel"] = ["order": 10000]
        steps["s_home"] = ["order": -3]
        let reading = ["s_home", "c_any", "s_parcel", "n_left", "e_thanks"]
        XCTAssertEqual(VisitorFlowEditor.listOrder(reading: reading, steps: steps),
                       ["e_thanks", "c_any", "n_left", "s_home", "s_parcel"],
                       "orders first, ties in reading order, unusable values after")
        let editor = VisitorFlowEditor(config: orderedConfig(["e_thanks": 0, "s_home": 1, "c_any": 2]), languages: ["en"])
        XCTAssertEqual(editor.orderedStepIds(), ["e_thanks", "s_home", "c_any", "s_parcel", "n_left"])
    }

    func testMovingAStepRewritesOnlyTheStepsWhoseOrderChanged() throws {
        let config = orderedConfig(["s_home": 0, "c_any": 1, "s_parcel": 2, "n_left": 3, "e_thanks": 4])
        let editor = VisitorFlowEditor(config: config, languages: ["en"])
        let sequence = VisitorFlowEditor.moving(editor.orderedStepIds(), "s_parcel", by: -1)
        XCTAssertEqual(sequence, ["s_home", "s_parcel", "c_any", "n_left", "e_thanks"])
        let written = editor.reorderOperations(sequence)
        XCTAssertEqual(written.map { $0.key }, ["visitor_flow.steps.s_parcel", "visitor_flow.steps.c_any"])
        let parcel = try XCTUnwrap(written[0].value as? [String: Any])
        XCTAssertEqual(parcel["order"] as? Int, 1)
        XCTAssertEqual(parcel["kind"] as? String, "page", "a whole step, not a leaf below it")
        XCTAssertNotNil(parcel["options"])
        XCTAssertEqual((written[1].value as? [String: Any])?["order"] as? Int, 2)
        XCTAssertTrue(editor.reorderOperations(editor.orderedStepIds()).isEmpty, "no change, no writes")
    }

    func testReorderingAnUnorderedFlowNumbersEveryStep() {
        let editor = VisitorFlowEditor(config: flowConfig(), languages: ["en"])
        let written = editor.reorderOperations(VisitorFlowEditor.moving(editor.orderedStepIds(), "e_thanks", by: -4))
        XCTAssertEqual(written.count, 5)
        XCTAssertEqual(written.map { ($0.value as? [String: Any])?["order"] as? Int }, [0, 1, 2, 3, 4])
        XCTAssertEqual(written.first?.key, "visitor_flow.steps.e_thanks")
    }

    func testEditsKeepTheStepsOrder() throws {
        let item = try XCTUnwrap(pages(orderedConfig(["s_parcel": 7])).stepPage("s_parcel").item("s_parcel_title_en"))
        let step = try XCTUnwrap(ops(item.commit?(.string("New title"))).first?.value as? [String: Any])
        XCTAssertEqual(step["order"] as? Int, 7)
    }

    func testStepOrderListUsesTheReorderControl() throws {
        let page = pages(orderedConfig(["e_thanks": 0])).stepsPage()
        guard case .list(let build)? = page.item("flow_step_order")?.control else { return XCTFail("list expected") }
        let model = build()
        XCTAssertEqual(model.rows.first?.id, "e_thanks")
        let written = ops(model.reorder?(["s_home", "e_thanks", "c_any", "s_parcel", "n_left"]))
        XCTAssertEqual(written.count, 5)
        XCTAssertTrue(written.allSatisfy { $0.key.split(separator: ".").count == 3 })
    }

    func testAddOptionCreatesCallWithTheNextOrderInTheSameBatch() throws {
        var config = orderedConfig(["s_home": 0, "s_parcel": 1, "n_left": 2, "e_thanks": 3])
        var flow = config["visitor_flow"] as! [String: Any]
        var steps = flow["steps"] as! [String: Any]
        steps.removeValue(forKey: "c_any")
        for id in ["s_home", "s_parcel"] {
            var step = steps[id] as! [String: Any]
            step["options"] = (step["options"] as! [[String: Any]]).map { option -> [String: Any] in
                var option = option
                if option["to"] as? String == "c_any" { option["to"] = "n_left" }
                return option
            }
            steps[id] = step
        }
        flow["steps"] = steps
        config["visitor_flow"] = flow
        let item = try XCTUnwrap(pages(config).stepPage("s_parcel").item("s_parcel_add_option"))
        let batch = ops(item.commit?(.string("")))
        XCTAssertEqual(Set(batch.map { $0.key }).count, batch.count, "one write per step")
        let call = try XCTUnwrap(batch.first { ($0.value as? [String: Any])?["kind"] as? String == "call" }?.value as? [String: Any])
        XCTAssertEqual(call["order"] as? Int, 4, "the new call step goes to the end")
        let parcel = try XCTUnwrap(batch.first { $0.key.hasSuffix("s_parcel") }?.value as? [String: Any])
        XCTAssertEqual(parcel["order"] as? Int, 1, "the rewritten page keeps its order")
        XCTAssertEqual((parcel["options"] as? [[String: Any]])?.count, 3)
    }

    func testIconPickerOffersTheVendoredSetAndKeepsAnUnknownValue() throws {
        var config = flowConfig()
        var flow = config["visitor_flow"] as! [String: Any]
        var steps = flow["steps"] as! [String: Any]
        var parcel = steps["s_parcel"] as! [String: Any]
        var options = parcel["options"] as! [[String: Any]]
        options[0]["icon"] = "\u{1F9FF}"
        parcel["options"] = options
        steps["s_parcel"] = parcel
        flow["steps"] = steps
        config["visitor_flow"] = flow
        guard case .page(let buildOption)? = pages(config).stepPage("s_parcel").item("s_parcel_opt_o_leave")?.control else {
            return XCTFail("option page expected")
        }
        let item = try XCTUnwrap(buildOption().item("s_parcel_o_leave_icon"))
        guard case .choice(let value, let choices, _) = item.control else { return XCTFail("choice expected") }
        XCTAssertEqual(value, "\u{1F9FF}")
        XCTAssertEqual(choices.count, 1 + AppIcon.flowChoices.count + 1)
        let picked = ops(item.commit?(.string(AppIcon.flowChoices[1].emoji)))
        let written = try XCTUnwrap(picked.first?.value as? [String: Any])
        XCTAssertEqual((written["options"] as? [[String: Any]])?.first?["icon"] as? String, "\u{1F4E6}")
        let cleared = ops(item.commit?(.string("")))
        XCTAssertNil(((cleared.first?.value as? [String: Any])?["options"] as? [[String: Any]])?.first?["icon"])
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
        let notify = try XCTUnwrap(made.ops.first { $0.key == "visitor_flow.steps." + made.id }?.value as? [String: Any])
        XCTAssertEqual(notify["to"] as? String, "e_thanks")
        XCTAssertEqual(notify["order"] as? Int, 5, "the new step goes to the end of the list")
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
        XCTAssertTrue(copy.ops.contains { $0.key == "visitor_flow.steps." + copy.id })
        let written = try XCTUnwrap(copy.ops.first { $0.key == "visitor_flow.steps." + copy.id }?.value as? [String: Any])
        XCTAssertEqual(written["kind"] as? String, "page")
        XCTAssertEqual(written["order"] as? Int, 3, "right after the original")
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
