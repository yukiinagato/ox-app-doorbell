import XCTest

@testable import Doorbell

/// The settings model: each native control maps to the documented Core key, values are validated
/// before they reach Core, and target differences (tvOS, door station) are data, not UI code.
final class SettingsCatalogTests: XCTestCase {

    private let node = "node1"

    private func catalog(_ config: [String: Any] = [:], role: String = "indoor_panel",
                         isTV: Bool = false) -> SettingsCatalog {
        let ctx = SettingsContext(config: config, status: [:], nodeId: node, name: "panel",
                                  role: role, door: role == "door_station" ? "d_front" : "",
                                  uiLang: "en", isTV: isTV)
        return SettingsCatalog(ctx, texts: Texts())
    }

    private func item(_ catalog: SettingsCatalog, _ path: [String], _ id: String) -> SettingItem? {
        return catalog.page(path: path)?.item(id)
    }

    private func operations(_ effect: SettingEffect?) -> [(String, String)] {
        guard case .write(let ops)? = effect else { return [] }
        return ops.map { ($0.key, $0.value.map { "\($0)" } ?? "<delete>") }
    }

    private func isInvalid(_ effect: SettingEffect?) -> Bool {
        if case .invalid? = effect { return true }
        return false
    }

    // MARK: Validation

    func testClockValidationNormalisesAndRejects() {
        XCTAssertEqual(SettingValidation.clock("7:05"), "07:05")
        XCTAssertEqual(SettingValidation.clock("23:59"), "23:59")
        XCTAssertNil(SettingValidation.clock("24:00"))
        XCTAssertNil(SettingValidation.clock("12:5"))
        XCTAssertNil(SettingValidation.clock("noon"))
        XCTAssertEqual(SettingValidation.minutes(ofClock: "01:30"), 90)
    }

    func testDoorIdFollowsTheSetupRule() {
        XCTAssertTrue(SettingValidation.doorId("door-a3f29c10"))
        XCTAssertTrue(SettingValidation.doorId("d_front"))
        XCTAssertFalse(SettingValidation.doorId("-front"))
        XCTAssertFalse(SettingValidation.doorId("front door"))
        XCTAssertFalse(SettingValidation.doorId(String(repeating: "a", count: 65)))
    }

    func testColourServerPortAndSnap() {
        XCTAssertEqual(SettingValidation.hexColor("#abc"), "#AABBCC")
        XCTAssertEqual(SettingValidation.hexColor("101418"), "#101418")
        XCTAssertNil(SettingValidation.hexColor("#12345"))
        XCTAssertEqual(SettingValidation.ntpServer("ntp.nict.jp:123"), "ntp.nict.jp:123")
        XCTAssertNil(SettingValidation.ntpServer("http://x"))
        XCTAssertNil(SettingValidation.ntpServer("host:70000"))
        XCTAssertNil(SettingValidation.port("0"))
        XCTAssertEqual(SettingValidation.snap(63, minimum: 10, maximum: 95, step: 5), 65)
        XCTAssertEqual(SettingValidation.snap(200, minimum: 10, maximum: 95, step: 5), 95)
    }

    func testOrderOperationsNumberFromOne() {
        let ops = SettingValidation.orderOperations(prefix: "quick_replies", ids: ["b", "a"])
        XCTAssertEqual(ops.map { $0.key }, ["quick_replies.b.order", "quick_replies.a.order"])
        XCTAssertEqual(ops.map { $0.value as? Int }, [1, 2])
    }

    // MARK: Key mapping

    func testCallFlowAndTtlMapToUiKeys() {
        let c = catalog()
        let flow = item(c, ["calls"], "call_flow")
        XCTAssertEqual(operations(flow?.commit?(.string("ring_then_purpose"))).first?.0, "ui.call_flow")
        let ttl = item(c, ["calls"], "call_ttl")
        XCTAssertEqual(operations(ttl?.commit?(.int(90))).first?.0, "ui.call_ttl_s")
        XCTAssertTrue(isInvalid(ttl?.commit?(.int(5))), "below Core's 10 s floor")
        XCTAssertTrue(isInvalid(item(c, ["calls"], "visitor_languages")?.commit?(.strings([]))))
    }

    func testVolumeWritesTheClusterDefaultUntilTheDeviceOverrides() {
        let inheriting = catalog(["audio": ["volume": ["call": 70]]])
        XCTAssertEqual(operations(item(inheriting, ["sounds"], "volume_call")?.commit?(.int(40))).first?.0,
                       "audio.volume.call")
        let overriding = catalog(["devices": [node: ["local": ["audio": ["volume": ["call": 30]]]]]])
        XCTAssertEqual(operations(item(overriding, ["sounds"], "volume_call")?.commit?(.int(40))).first?.0,
                       "devices.\(node).local.audio.volume.call")
        XCTAssertEqual(operations(item(overriding, ["sounds"], "volume_inherit")?.commit?(.bool(true))).first?.1,
                       "<delete>")
    }

    func testIntervalStepperStoresSeconds() {
        let ops = operations(item(catalog(), ["time"], "time_interval")?.commit?(.int(6)))
        XCTAssertEqual(ops.first?.0, "time.ntp.interval_s")
        XCTAssertEqual(ops.first?.1, "21600")
    }

    func testColourIsNormalisedBeforeItIsWritten() {
        let colour = item(catalog(), ["display"], "theme_bg_color")
        XCTAssertEqual(operations(colour?.commit?(.string("#fff"))).first?.1, "#FFFFFF")
        XCTAssertTrue(isInvalid(colour?.commit?(.string("white"))))
    }

    func testQuickReplyListReordersDeletesAndAdds() {
        let config: [String: Any] = ["quick_replies": [
            "qr_a": ["label": ["ja": "A"], "order": 1], "qr_b": ["label": ["ja": "B"], "order": 2]]]
        let list = catalog(config).list(path: ["calls", "quick_replies"])
        XCTAssertEqual(list?.rows.map { $0.id }, ["qr_a", "qr_b"])
        XCTAssertEqual(operations(list?.reorder?(["qr_b", "qr_a"])).map { $0.0 },
                       ["quick_replies.qr_b.order", "quick_replies.qr_a.order"])
        XCTAssertEqual(operations(list?.delete?("qr_a")).first?.0, "quick_replies.qr_a")
        let added = operations(list?.addWithText?("Leave it at the door"))
        XCTAssertTrue(added.first?.0.hasPrefix("quick_replies.qr_") ?? false)
        XCTAssertTrue(isInvalid(list?.addWithText?("   ")))
        XCTAssertNotNil(catalog(config).page(path: ["calls", "quick_replies", "qr_b"]),
                        "a row's edit page resolves by path")
    }

    func testPurposeRowsCarryTheirEnabledSwitch() {
        let config: [String: Any] = ["visit_purposes": ["p_mail": ["label": ["ja": "郵便"], "order": 1,
                                                                    "enabled": false]]]
        let list = catalog(config).list(path: ["calls", "visit_purposes"])
        XCTAssertEqual(list?.rows.first?.enabled, false)
        XCTAssertEqual(operations(list?.rows.first?.toggle?(true)).first?.0, "visit_purposes.p_mail.enabled")
    }

    func testNtpServersKeepAtLeastOne() {
        let list = catalog(["time": ["ntp": ["servers": ["ntp.nict.jp"]]]]).list(path: ["time", "time_servers"])
        XCTAssertTrue(isInvalid(list?.delete?("ntp.nict.jp")))
        XCTAssertEqual(operations(list?.addWithText?("time.google.com")).first?.0, "time.ntp.servers")
    }

    func testSosCountdownRangeAndRoles() {
        let c = catalog()
        XCTAssertTrue(isInvalid(item(c, ["sos"], "sos_countdown")?.commit?(.int(11))))
        XCTAssertEqual(operations(item(c, ["sos"], "sos_roles")?.commit?(.strings([]))).first?.0,
                       "emergency.button_on_roles")
    }

    // MARK: Target differences

    func testTvShowsItsFixedRoleAndHasNoRoleFormAndNoSip() {
        let tv = catalog(isTV: true)
        XCTAssertNotNil(item(tv, ["device"], "device_role"), "the role is shown read-only")
        XCTAssertNil(item(tv, ["device"], "change_role"), "an Apple TV is always an indoor panel")
        XCTAssertFalse(tv.categories().contains { $0.id == "sip" })
        guard case .shell("change_role")? = item(catalog(), ["device"], "change_role")?.control
        else { return XCTFail("the role is changed in its own form") }
        XCTAssertNil(item(catalog(), ["device"], "device_role")?.commit,
                     "the role row itself writes nothing")
    }

    func testDoorStationGetsCameraAndTheRoleFormValidatesItsDoorId() {
        let door = catalog(role: "door_station")
        XCTAssertNotNil(door.page(path: ["device", "camera"]))
        XCTAssertNotNil(item(door, ["device"], "change_role"),
                        "a door station can change back to an indoor panel")
        XCTAssertNil(catalog().page(path: ["device", "camera"]))

        var plan = RoleChangePlan(role: "door_station", door: "", newDoor: "bad id")
        XCTAssertFalse(plan.isValid)
        plan.newDoor = " door-front "
        XCTAssertTrue(plan.isValid)
        XCTAssertEqual(plan.resolvedDoor, "door-front")
        plan.door = "gate"
        XCTAssertEqual(plan.resolvedDoor, "gate", "a picked door wins over the new-door field")
        plan.role = "indoor_panel"
        XCTAssertTrue(plan.isValid)
        XCTAssertEqual(plan.resolvedDoor, "", "an indoor panel serves no door")
        XCTAssertTrue(plan.changes(role: "door_station", door: "gate"))
        XCTAssertFalse(plan.changes(role: "indoor_panel", door: ""))
        XCTAssertFalse(RoleChangePlan(role: "monitor", door: "", newDoor: "").isValid)
    }

    func testTheRoleFormOffersUnservedDoorsAndWaitsForCallsAndSos() {
        let config: [String: Any] = [
            "doors": ["front": ["order": 1], "back": ["order": 2], "gate": ["order": 3]],
            "devices": ["other": ["role": "door_station", "door": "gate", "name": "Gate unit"]],
        ]
        let status: [String: Any] = ["peers": [
            ["id": "p1", "role": "door_station", "door": "front", "status": "alive"],
        ]]
        XCTAssertEqual(RoleChangePlan.offeredDoors(config: config, status: status, ownDoor: ""),
                       ["back", "gate"], "a door a live station serves is not offered")
        XCTAssertEqual(RoleChangePlan.offeredDoors(config: config, status: status,
                                                   ownDoor: "front"),
                       ["front", "back", "gate"], "this device's own door always is")
        let plan = RoleChangePlan(role: "door_station", door: "gate", newDoor: "")
        XCTAssertEqual(plan.conflictingDevice(config: config, nodeId: "self", lang: "en"),
                       "Gate unit")
        XCTAssertNil(plan.conflictingDevice(config: config, nodeId: "other", lang: "en"))

        XCTAssertFalse(RoleChangePlan.isBusy(status: [:], pairing: .ready))
        XCTAssertTrue(RoleChangePlan.isBusy(status: ["active_calls": [["call_id": "c"]]],
                                            pairing: .ready))
        XCTAssertTrue(RoleChangePlan.isBusy(status: ["emergency": ["active": true]],
                                            pairing: .ready))
        XCTAssertTrue(RoleChangePlan.isBusy(status: [:], pairing: .joining))
    }

    func testBlurRadiusIsSystemManagedWithoutAnOwnRenderer() {
        guard case .info? = item(catalog(), ["display"], "glass_blur")?.control else {
            return XCTFail("UIBlurEffect has no public radius")
        }
    }

    func testFormerlyWebOnlyItemsAreNative() {
        guard case .shell("panels")? = item(catalog(), ["cluster"], "panels")?.control else {
            return XCTFail("panel identities open the native panel editor")
        }
        guard case .list? = item(catalog(), ["notifications"], "rule_edit")?.control else {
            return XCTFail("rules are edited natively")
        }
        guard case .secret? = item(catalog(), ["sip"], "sip_password")?.control else {
            return XCTFail("the SIP password is a native secret field")
        }
        guard case .local(let action)? = item(catalog(), ["sip"], "sip_password")?.commit?(.string("pw")),
              action.hasPrefix("secret|") else {
            return XCTFail("a typed secret goes to the Keychain, never into configuration")
        }
    }
}
