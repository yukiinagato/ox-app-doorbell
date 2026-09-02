import UIKit
import XCTest

@testable import Doorbell

/// Which screens offer the SOS slider. The mini 3 showed it on a door station with the key absent,
/// where core's default is the indoor panel alone and the kiosk shell correctly hid it.
final class SosVisibilityTests: XCTestCase {

    private func config(_ roles: [Any]?) -> [String: Any] {
        guard let roles = roles else { return ["emergency": ["trigger": ["countdown_s": 3]]] }
        return ["emergency": ["button_on_roles": roles]]
    }

    // MARK: - With the key absent, core's default stands

    func testWithoutTheKeyOnlyTheIndoorPanelOffersIt() {
        XCTAssertFalse(ConfigUtil.sosButtonVisible(config: config(nil), role: "door_station"),
                       "a door station shows no slider until an administrator asks for one")
        XCTAssertTrue(ConfigUtil.sosButtonVisible(config: config(nil), role: "indoor_panel"))
    }

    func testAnEmptyConfigurationIsTheSameAsAnAbsentKey() {
        XCTAssertFalse(ConfigUtil.sosButtonVisible(config: nil, role: "door_station"))
        XCTAssertTrue(ConfigUtil.sosButtonVisible(config: nil, role: "indoor_panel"))
        XCTAssertFalse(ConfigUtil.sosButtonVisible(config: [:], role: "door_station"))
        XCTAssertTrue(ConfigUtil.sosButtonVisible(config: [:], role: "indoor_panel"))
    }

    // MARK: - With the key present, it replaces the default outright

    func testTheConfiguredListDecides() {
        let doorOnly = config(["door_station"])
        XCTAssertTrue(ConfigUtil.sosButtonVisible(config: doorOnly, role: "door_station"))
        XCTAssertFalse(ConfigUtil.sosButtonVisible(config: doorOnly, role: "indoor_panel"),
                       "the list replaces the default rather than adding to it")

        let both = config(["indoor_panel", "door_station"])
        XCTAssertTrue(ConfigUtil.sosButtonVisible(config: both, role: "door_station"))
        XCTAssertTrue(ConfigUtil.sosButtonVisible(config: both, role: "indoor_panel"))
    }

    /// An empty list is how an administrator takes the slider off every screen.
    func testAnEmptyListHidesItEverywhere() {
        let none = config([])
        XCTAssertFalse(ConfigUtil.sosButtonVisible(config: none, role: "door_station"))
        XCTAssertFalse(ConfigUtil.sosButtonVisible(config: none, role: "indoor_panel"))
    }

    /// A malformed entry is not a role, and an unknown role is not on any list.
    func testMalformedEntriesAndUnknownRolesAreRefused() {
        let messy = config(["door_station", 7, NSNull()])
        XCTAssertTrue(ConfigUtil.sosButtonVisible(config: messy, role: "door_station"))
        XCTAssertFalse(ConfigUtil.sosButtonVisible(config: messy, role: "indoor_panel"))
        XCTAssertFalse(ConfigUtil.sosButtonVisible(config: config(nil), role: "kiosk"))
    }

    // MARK: - The screen keeps the answer

    /// `applyLayout` takes the whole stack apart and puts it back, which is the path that could
    /// otherwise put the slider back on a door station after a rotation.
    func testTheVisitorScreenKeepsTheSliderHiddenAcrossARotation() {
        let texts = Texts()
        let sos = SosSlideControl(texts: texts)
        let view = VisitorScreenView(texts: texts, callButton: UIButton(type: .system),
                                     langBar: UIStackView(),
                                     purposeSection: UIStackView(), sosControl: sos)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])

        view.setSosVisible(false)
        XCTAssertTrue(sos.isHidden)

        view.applyLayout(for: CGSize(width: 1024, height: 768))
        host.layoutIfNeeded()
        XCTAssertTrue(sos.isHidden, "a rotation does not hand the door station a slider")

        view.applyLayout(for: CGSize(width: 768, height: 1024))
        host.layoutIfNeeded()
        XCTAssertTrue(sos.isHidden)

        // And an indoor panel keeps its slider through the same rebuild.
        view.setSosVisible(true)
        view.applyLayout(for: CGSize(width: 1024, height: 768))
        host.layoutIfNeeded()
        XCTAssertFalse(sos.isHidden)
    }
}
