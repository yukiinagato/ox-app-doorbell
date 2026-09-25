import UIKit
import XCTest

@testable import Doorbell

/// The door-station screen's geometry in both orientations. The device can only be photographed
/// in the orientation it happens to be in, so landscape is held here instead.
final class VisitorScreenLayoutTests: XCTestCase {

    private let portrait = CGSize(width: 1536 / 2, height: 2048 / 2)
    private let landscape = CGSize(width: 2048 / 2, height: 1536 / 2)

    private struct Screen {
        let window: UIWindow
        let host: UIView
        let view: VisitorScreenView
        let langBar: UIStackView
        let sos: SosSlideControl
        let purposeHint: UILabel
        let purposeButtons: [UIButton]
        let purposeSection: UIStackView
        let callButton: UIButton
    }

    /// Builds the screen with the controls `MainViewController` would hand it, laid out at `size`
    /// inside a host of that size — the same shape as the real hierarchy.
    private func makeScreen(_ size: CGSize) -> Screen {
        let texts = Texts()
        let langBar = UIStackView()
        langBar.axis = .horizontal
        langBar.spacing = 12
        langBar.alignment = .fill
        langBar.distribution = .fillEqually
        for name in ["日本語", "English", "中文"] {
            let chip = UIButton(type: .system)
            chip.setTitle(name, for: .normal)
            chip.setTitleColor(UIColor(white: 0.9, alpha: 1), for: .normal)
            chip.titleLabel?.font = .systemFont(ofSize: 17)
            chip.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            langBar.addArrangedSubview(chip)
        }

        let purposeHint = UILabel()
        purposeHint.text = texts.t("idle.choose_purpose")
        purposeHint.isHidden = true

        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 12
        grid.alignment = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false
        var buttons: [UIButton] = []
        let columns = VisitorScreenView.purposeColumnCount(for: size)
        let purposeIDs = ["p_visit", "p_delivery", "p_mail", "p_sales", "p_work", "p_other"]
        let purposeNames = ["Visit", "Delivery", "Mail", "Business", "Maintenance", "Other"]
        for index in 0..<6 {
            if index % columns == 0 {
                let row = UIStackView()
                row.axis = .horizontal
                row.spacing = 12
                row.distribution = .fillEqually
                grid.addArrangedSubview(row)
            }
            let button = PurposeButton(type: .system)
            button.setTitle(purposeNames[index], for: .normal)
            button.setImage(TablerIcon.purpose(purposeIDs[index]), for: .normal)
            button.tintColor = UIColor(white: 0.94, alpha: 1)
            button.setTitleColor(UIColor(white: 0.94, alpha: 1), for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 16)
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.textAlignment = .center
            button.layer.cornerRadius = 14
            button.backgroundColor = UIColor(white: 1, alpha: 0.08)
            let minimum = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
            minimum.priority = UILayoutPriority(999)
            minimum.isActive = true
            button.heightAnchor.constraint(equalToConstant: 88).isActive = true
            (grid.arrangedSubviews.last as? UIStackView)?.addArrangedSubview(button)
            buttons.append(button)
        }
        let gridWidth = grid.widthAnchor.constraint(equalToConstant: 552)
        gridWidth.priority = UILayoutPriority(750)
        gridWidth.isActive = true

        let purposeSection = UIStackView(arrangedSubviews: [purposeHint, grid])
        purposeSection.axis = .vertical
        purposeSection.alignment = .center
        grid.widthAnchor.constraint(lessThanOrEqualTo: purposeSection.widthAnchor).isActive = true

        let sos = SosSlideControl(texts: texts)
        let callButton = UIButton(type: .system)
        callButton.setTitle(texts.t("idle.call_button_verb"), for: .normal)
        callButton.titleLabel?.font = .systemFont(ofSize: 40, weight: .bold)
        callButton.layer.cornerRadius = 18
        let view = VisitorScreenView(texts: texts, callButton: callButton,
                                     langBar: langBar, purposeSection: purposeSection,
                                     sosControl: sos)
        let host = UIView(frame: CGRect(origin: .zero, size: size))
        let window = UIWindow(frame: host.frame)
        window.addSubview(host)
        window.isHidden = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        view.applyLayout(for: size)
        host.layoutIfNeeded()
        return Screen(window: window, host: host, view: view, langBar: langBar, sos: sos, purposeHint: purposeHint,
                      purposeButtons: buttons, purposeSection: purposeSection, callButton: callButton)
    }

    func testCameraWarningSurvivesRotationWithoutANotice() {
        let screen = makeScreen(portrait)
        screen.view.updateNotice(nil)
        screen.view.updateCameraWarning(Texts().t("door.camera_denied"))
        for size in [portrait, landscape, portrait] {
            screen.host.frame.size = size
            screen.view.applyLayout(for: size)
            screen.host.layoutIfNeeded()
            screen.view.layoutIfNeeded()
            let warning = visibleLabels(in: screen.view).first {
                $0.accessibilityIdentifier == "visitor_camera_warning"
            }
            XCTAssertNotNil(warning, "camera refusal remains visible independently of notices")
            XCTAssertGreaterThan(warning?.bounds.height ?? 0, 0)
        }
    }

    func testPhonePurposesUseTwoColumnsAndTabletPurposesUseThree() {
        for size in [CGSize(width: 320, height: 480), CGSize(width: 390, height: 844),
                     CGSize(width: 844, height: 390)] {
            XCTAssertEqual(VisitorScreenView.purposeColumnCount(for: size), 2)
        }
        for size in [portrait, landscape] {
            XCTAssertEqual(VisitorScreenView.purposeColumnCount(for: size), 3)
        }
    }

    func testCompactScreensScrollContentAboveThePinnedFooter() {
        let animations = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animations) }
        for size in [CGSize(width: 320, height: 480), CGSize(width: 390, height: 844),
                     CGSize(width: 844, height: 350), portrait, landscape] {
            let screen = makeScreen(size)
            screen.view.backgroundColor = UIColor(red: 0.063, green: 0.078, blue: 0.094, alpha: 1)
            screen.view.apply(skin: .plain(.dark))
            screen.view.updateClock(DoorbellClock.Reading(hour: 14, minute: 32, second: 8,
                date: "2026-09-22", weekday: "tue", tz: "Asia/Tokyo", known: true,
                wallMs: 0, raw: [:]), lang: "en")
            screen.view.setCallFlow("purpose_first", hasPurposes: true)
            screen.view.updateFooter("Doorbell · app v0.1.35 (36)")
            screen.host.layoutIfNeeded()
            screen.view.layoutIfNeeded()
            screen.callButton.layoutIfNeeded()
            XCTAssertGreaterThan(screen.callButton.titleLabel?.bounds.height ?? 0, 0)
            XCTAssertEqual(screen.callButton.titleLabel?.alpha ?? 0, 1)
            for label in visibleLabels(in: screen.view) {
                XCTAssertGreaterThan(label.bounds.height, 0, label.accessibilityIdentifier ?? label.text ?? "label")
            }
            let scroll = screen.view.subviews.compactMap { $0 as? UIScrollView }.first!
            let footerFrame = screen.sos.convert(screen.sos.bounds, to: screen.view)
            XCTAssertLessThan(scroll.frame.maxY, footerFrame.minY)
            XCTAssertGreaterThanOrEqual(screen.callButton.bounds.height, 56)
            XCTAssertGreaterThan(scroll.bounds.height, 0)
            XCTAssertLessThanOrEqual(screen.callButton.bounds.width, scroll.bounds.width)
            if size.height < 500 { XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height) }
            for button in screen.purposeButtons {
                let rect = button.convert(button.bounds, to: scroll)
                XCTAssertGreaterThanOrEqual(rect.minX, -1)
                XCTAssertLessThanOrEqual(rect.maxX, scroll.bounds.width + 1)
            }
            UIGraphicsBeginImageContextWithOptions(size, true, 1)
            screen.view.layer.render(in: UIGraphicsGetCurrentContext()!)
            let image = UIGraphicsGetImageFromCurrentImageContext()!
            UIGraphicsEndImageContext()
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("visitor-\(Int(size.width))-\(Int(size.height)).png")
            try? image.pngData()?.write(to: url)
            print("VISITOR_SCREENSHOT " + url.path)
        }
    }

    func testCallFlowSwitchRemovesHomePurposesAcrossLayoutsAndOrientations() {
        for size in [portrait, landscape] {
            let screen = makeScreen(size)
            for style in ["standard", "left", "right", "edges"] {
                screen.view.setLayoutStyle(style)
                for mode in ["purpose_first", "ring_then_purpose", "purpose_first"] {
                    screen.view.setCallFlow(mode, hasPurposes: true)
                    screen.view.superview?.layoutIfNeeded()
                    XCTAssertEqual(screen.purposeSection.isHidden, mode == "ring_then_purpose")
                    XCTAssertEqual(screen.callButton.title(for: .normal), Texts().t(
                        mode == "purpose_first" ? "door.call_direct" : "idle.call_button_verb"))
                    XCTAssertGreaterThan(screen.callButton.bounds.width, 100)
                    XCTAssertFalse(screen.langBar.isHidden)
                    XCTAssertFalse(screen.callButton.isHidden)
                }
            }
        }
    }

    func testEmptyPurposesUseTheDirectCallHomeInEitherMode() {
        let screen = makeScreen(portrait)
        for mode in ["purpose_first", "ring_then_purpose"] {
            screen.view.setCallFlow(mode, hasPurposes: false)
            screen.view.superview?.layoutIfNeeded()
            XCTAssertTrue(screen.purposeSection.isHidden)
            XCTAssertEqual(screen.callButton.title(for: .normal), Texts().t("idle.call_button_verb"))
            XCTAssertFalse(screen.callButton.isHidden)
        }
    }

    func testLayoutChoiceCanSwitchRepeatedlyWithoutLosingControls() {
        let screen = makeScreen(landscape)
        for style in ["left", "right", "edges", "standard", "left"] {
            screen.view.setLayoutStyle(style)
            screen.view.superview?.layoutIfNeeded()
            XCTAssertNotNil(screen.callButton.window ?? screen.callButton.superview)
            XCTAssertGreaterThan(screen.callButton.bounds.width, 0)
            XCTAssertFalse(screen.langBar.isHidden)
            XCTAssertEqual(screen.sos.convert(screen.sos.bounds, to: screen.view).maxY, landscape.height, accuracy: 1)
        }
    }

    // MARK: - The SOS bar is a bar

    /// It took a third of the iPad's height on the device: inside a filling stack it had no
    /// height of its own to defend.
    func testTheSosBarStaysACompactBandInBothOrientations() {
        for (name, size) in [("portrait", portrait), ("landscape", landscape)] {
            let screen = makeScreen(size)
            let height = screen.sos.bounds.height
            XCTAssertGreaterThanOrEqual(height, 72, "\(name): tall enough to hit")
            XCTAssertLessThanOrEqual(height, 88, "\(name): and no taller than a band")
            XCTAssertLessThan(height, size.height / 4,
                              "\(name): it is a bar, not a third of the screen")
        }
    }

    func testTheSosBarSpansTheFullWidth() {
        for (name, size) in [("portrait", portrait), ("landscape", landscape)] {
            let screen = makeScreen(size)
            XCTAssertEqual(screen.sos.bounds.width, size.width, accuracy: 1,
                           "\(name): the band runs the whole width")
        }
    }

    /// Nothing sits below it: it is the last thing on the screen.
    func testTheSosBarIsAnchoredToTheBottom() {
        for (name, size) in [("portrait", portrait), ("landscape", landscape)] {
            let screen = makeScreen(size)
            XCTAssertEqual(screen.sos.convert(screen.sos.bounds, to: screen.view).maxY, size.height, accuracy: 1, "\(name)")
        }
    }

    // MARK: - Language chips

    /// The selected chip stretched to the whole row on the device while the other two stayed
    /// small, because a filling stack grows whichever child hugs least.
    func testTheLanguageChipsAreEqualWidth() {
        for (name, size) in [("portrait", portrait), ("landscape", landscape)] {
            let screen = makeScreen(size)
            let widths = screen.langBar.arrangedSubviews.map { $0.bounds.width }
            XCTAssertEqual(widths.count, 3)
            guard let first = widths.first else { return XCTFail("\(name): no chips") }
            XCTAssertGreaterThan(first, 0, "\(name): the chips have a width at all")
            for width in widths {
                XCTAssertEqual(width, first, accuracy: 1,
                               "\(name): every chip is the same width")
            }
        }
    }

    // MARK: - The purpose grid fits its column

    /// The third column was cut off at the right edge in landscape: the buttons had a fixed
    /// width and three of them were wider than the column they sat in.
    func testEveryPurposeButtonLiesInsideTheScreen() {
        for (name, size) in [("portrait", portrait), ("landscape", landscape)] {
            let screen = makeScreen(size)
            let bounds = CGRect(origin: .zero, size: size)
            for (index, button) in screen.purposeButtons.enumerated() {
                let frame = button.convert(button.bounds, to: screen.view)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(name): button \(index) left")
                XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 0.5,
                                         "\(name): button \(index) is cut off at the right")
                XCTAssertGreaterThan(frame.width, 0, "\(name): button \(index) has a width")
            }
        }
    }

    /// Every column is the same width, so the grid reads as a grid.
    func testThePurposeColumnsAreEqualWidth() {
        for (name, size) in [("portrait", portrait), ("landscape", landscape)] {
            let screen = makeScreen(size)
            let widths = screen.purposeButtons.map { $0.bounds.width }
            guard let first = widths.first else { return XCTFail("\(name): no buttons") }
            for width in widths {
                XCTAssertEqual(width, first, accuracy: 1, "\(name): equal columns")
            }
        }
    }

    // MARK: - The call button

    /// The call verb is two characters in Japanese, and a button that hugs it is barely wider than
    /// a finger. It is the one control a visitor has to find, so it takes a share of its column.
    func testTheCallButtonIsAtLeastSixtyPercentOfItsColumn() {
        for (name, size) in [("portrait", portrait), ("landscape", landscape)] {
            let screen = makeScreen(size)
            let button = screen.callButton
            guard let column = button.superview else { return XCTFail("\(name): no column") }
            XCTAssertGreaterThanOrEqual(button.bounds.width, column.bounds.width * 0.6 - 1,
                                        "\(name): the call button takes its share of the column")
            XCTAssertLessThanOrEqual(button.bounds.width, column.bounds.width + 1,
                                     "\(name): and never overflows it")
            XCTAssertGreaterThan(button.bounds.height, 0, "\(name): it keeps a height")
        }
    }

    // MARK: - One hint sentence

    /// §5.3 gives the door station one hint sentence, and the visitor screen spends it on
    /// `door.hint_call`. The purpose grid's own caption is the second one that was showing.
    func testOnlyOneHintSentenceIsVisible() {
        for (name, size) in [("portrait", portrait), ("landscape", landscape)] {
            let screen = makeScreen(size)
            screen.view.updateHint(Texts().t("door.hint_call"))
            XCTAssertTrue(screen.purposeHint.isHidden,
                          "\(name): the purpose caption is not a second hint")
            let hints = visibleLabels(in: screen.view).filter {
                ($0.text ?? "").contains("呼び出します") || ($0.text ?? "").contains("お選びください")
            }
            XCTAssertEqual(hints.count, 1, "\(name): exactly one hint sentence on screen")
        }
    }

    private func visibleLabels(in root: UIView) -> [UILabel] {
        var found: [UILabel] = []
        for child in root.subviews where !child.isHidden {
            if let label = child as? UILabel, !(label.text ?? "").isEmpty { found.append(label) }
            found += visibleLabels(in: child)
        }
        return found
    }
}

final class PurposeChoiceLayoutTests: XCTestCase {
    private func screen(_ size: CGSize, count: Int = 6) -> PurposeChoiceViewController {
        let labels = ["Visit resident", "Parcel delivery", "Mail", "Business visit", "Maintenance", "Other purpose"]
        let items = (0..<count).map {
            PurposeChoiceViewController.Item(id: "item\($0)", title: labels[$0 % labels.count],
                                             image: TablerIcon.purpose(["p_visit", "p_delivery", "p_mail", "p_sales", "p_work", "p_other"][$0 % 6]))
        }
        XCTAssertTrue(items.allSatisfy { $0.image != nil })
        let screen = PurposeChoiceViewController(items: items, palette: .light,
                                                afterRing: true, texts: Texts())
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(origin: .zero, size: size)
        screen.view.setNeedsLayout()
        screen.view.layoutIfNeeded()
        return screen
    }

    private func descendants(_ view: UIView) -> [UIView] {
        return view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testPortraitAndLandscapeKeepLargeAlignedTargets() {
        for size in [CGSize(width: 768, height: 1024), CGSize(width: 1024, height: 768)] {
            let controller = screen(size)
            let all = descendants(controller.view)
            let cards = all.filter { ($0.accessibilityIdentifier ?? "").hasPrefix("purpose_choice_item") }
            XCTAssertEqual(cards.count, 6)
            XCTAssertGreaterThanOrEqual(cards[0].bounds.width, 200)
            XCTAssertGreaterThanOrEqual(cards[0].bounds.height, 150)
            for (index, card) in cards.enumerated() {
                XCTAssertEqual(card.bounds.size, cards[0].bounds.size)
                for other in cards.dropFirst(index + 1) { XCTAssertFalse(card.frame.intersects(other.frame)) }
            }
            let cancel = all.first { $0.accessibilityIdentifier == "purpose_choice_cancel" }!
            let scroll = all.compactMap { $0 as? UIScrollView }.first!
            XCTAssertGreaterThanOrEqual(cancel.bounds.height, 64)
            XCTAssertLessThan(scroll.frame.maxY, cancel.convert(cancel.bounds, to: controller.view).minY)
            UIGraphicsBeginImageContextWithOptions(size, true, 1)
            controller.view.layer.render(in: UIGraphicsGetCurrentContext()!)
            let image = UIGraphicsGetImageFromCurrentImageContext()!
            UIGraphicsEndImageContext()
            let path = NSTemporaryDirectory() + "purpose-choice-\(Int(size.width)).png"
            try? image.pngData()?.write(to: URL(fileURLWithPath: path))
            print("PURPOSE_SCREENSHOT " + path)
        }
    }

    func testManyOptionsScrollWithoutShrinkingTargets() {
        let controller = screen(CGSize(width: 390, height: 844), count: 20)
        let all = descendants(controller.view)
        let scroll = all.compactMap { $0 as? UIScrollView }.first!
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        let cards = all.filter { ($0.accessibilityIdentifier ?? "").hasPrefix("purpose_choice_item") }
        XCTAssertEqual(cards.count, 20)
        XCTAssertTrue(cards.allSatisfy { $0.bounds.height >= 150 })
    }

    func testLongPurposeLabelsAndLargeTextKeepCancelVisibleInBothOrientations() {
        for language in ["en", "zh"] {
            for size in [CGSize(width: 320, height: 480), CGSize(width: 844, height: 390),
                         CGSize(width: 768, height: 1024), CGSize(width: 1024, height: 768)] {
                let texts = Texts()
                texts.setLang(language)
                let title = language == "en" ? "Scheduled delivery and building maintenance visit" :
                    "预约配送与大楼设备维护来访，请联系住户确认"
                let controller = PurposeChoiceViewController(items: [
                    .init(id: "long", title: title, image: nil)], palette: .light,
                    afterRing: true, texts: texts)
                let host = UIViewController()
                host.addChild(controller)
                host.setOverrideTraitCollection(UITraitCollection(
                    preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge), forChild: controller)
                host.view.addSubview(controller.view)
                controller.didMove(toParent: host)
                controller.view.frame = CGRect(origin: .zero, size: size)
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                let all = descendants(controller.view)
                let cancel = all.first { $0.accessibilityIdentifier == "purpose_choice_cancel" }!
                let skip = all.first { $0.accessibilityIdentifier == "purpose_choice_skip" }!
                let scroll = all.compactMap { $0 as? UIScrollView }.first!
                let cancelFrame = cancel.convert(cancel.bounds, to: controller.view)
                XCTAssertGreaterThanOrEqual(cancelFrame.minY, 0)
                XCTAssertLessThanOrEqual(cancelFrame.maxY, size.height)
                XCTAssertGreaterThan(scroll.bounds.height, 0)
                XCTAssertLessThan(scroll.frame.maxY, cancelFrame.minY)
                XCTAssertGreaterThanOrEqual(cancel.bounds.height, 64)
                XCTAssertNotEqual(cancel.accessibilityIdentifier, skip.accessibilityIdentifier)
                let card = all.first { $0.accessibilityIdentifier == "purpose_choice_long" }!
                card.layoutIfNeeded()
                let label = descendants(card).compactMap { $0 as? UILabel }.first!
                XCTAssertGreaterThan(label.font.pointSize, 26)
                XCTAssertLessThanOrEqual(label.sizeThatFits(CGSize(width: label.bounds.width,
                    height: .greatestFiniteMagnitude)).height, label.bounds.height + 1)
            }
        }
    }

    func testRemoteReplyInvalidatesPendingChoice() {
        let controller = screen(CGSize(width: 768, height: 1024))
        controller.onSelect = { _ in XCTFail("A resolved call must not submit a purpose") }
        controller.onCancel = { XCTFail("A resolved call must not cancel a later call") }
        controller.invalidate()
        XCTAssertNil(controller.onSelect)
        XCTAssertNil(controller.onCancel)
        XCTAssertFalse(controller.view.isUserInteractionEnabled)
        for button in descendants(controller.view).compactMap({ $0 as? UIButton }) {
            button.sendActions(for: .touchUpInside)
        }
    }
}

final class VisitorActionContractTests: XCTestCase {
    private var bridges: [CoreBridge] = []
    private var directories: [URL] = []
    private var windows: [UIWindow] = []
    private var controllers: [MainViewController] = []

    func testPendingAnswerCanEndBeforeCoreConfirmsAnswer() {
        var lifecycle = IncomingCallLifecycleState()
        XCTAssertFalse(lifecycle.recordAnswer(.pending))
        XCTAssertTrue(lifecycle.mayReportEnd)

        lifecycle.recordEnd(.pending)
        XCTAssertTrue(lifecycle.ended)
        XCTAssertTrue(lifecycle.confirmAnswer(ownerIsLocal: true) == false)
        XCTAssertEqual(lifecycle.answer, .accepted)
        XCTAssertTrue(lifecycle.ended)
    }

    func testPendingAnswerLosesOwnershipWithoutReportingEnd() {
        var lifecycle = IncomingCallLifecycleState()
        XCTAssertFalse(lifecycle.recordAnswer(.pending))
        XCTAssertTrue(lifecycle.confirmAnswer(ownerIsLocal: false))
        XCTAssertFalse(lifecycle.mayReportEnd)
        XCTAssertTrue(lifecycle.ended)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        return view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func button(_ id: String, in controller: UIViewController) throws -> UIButton {
        return try XCTUnwrap(descendants(controller.view).first {
            $0.accessibilityIdentifier == id
        } as? UIButton, id)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath,
                            line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func calls(_ core: CoreBridge) -> [[String: Any]] {
        return core.callTimingSnapshot()?.document["active_calls"] as? [[String: Any]] ?? []
    }

    private func configure(_ core: CoreBridge, _ key: String, _ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: ["ops": [
            ["op": "set", "key": key, "value": value]]])
        let result = try XCTUnwrap(core.applyConfigBatch(String(decoding: data, as: UTF8.self),
                                                       operations: []))
        XCTAssertTrue(result.ok, result.error)
    }

    private func screen(mode: String = "purpose_first", size: CGSize = CGSize(width: 390, height: 844),
                        category: UIContentSizeCategory = .large) throws -> (CoreBridge, MainViewController) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("doorbell-t35-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let core = CoreBridge()
        bridges.append(core)
        XCTAssertTrue(core.start(dataDir: directory.path, bootJson:
            "{\"name\":\"T35 UIKit\",\"role\":\"door_station\",\"door\":\"front\",\"listen_port\":0,\"http_port\":0}"))
        core.setCapabilities(["features": ["platform_v2": true, "call_flow_v2": true,
            "call_cancel_v2": true, "call_lifecycle_v2": true, "ui_manifest_v1": true]])
        core.setUiManifest(["schema_version": 1, "units": "pt",
            "viewport": ["minimum_touch": 44, "scale_min": 0.75, "scale_max": 2.0],
            "elements": ["purpose.button": ["properties": ["scale"], "defaults": ["scale": 1], "safety_critical": false],
                         "cancel.call": ["properties": ["scale"], "defaults": ["scale": 1], "safety_critical": true]]])
        try configure(core, "ui.call_flow", mode)
        try configure(core, "ui.call_sound", "")
        var boot = BootConfig()
        boot.door = "front"
        boot.uiLang = "en"
        let controller = MainViewController(core: core, boot: boot, runtime: nil)
        controller.suppressVisitorMediaForTesting = true
        controllers.append(controller)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        windows.append(window)
        window.isHidden = false
        host.addChild(controller)
        host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: controller)
        controller.view.frame = CGRect(origin: .zero, size: size)
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        controller.refreshVisitorForTesting()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return (core, controller)
    }

    override func tearDown() {
        for controller in controllers {
            controller.suspendCallTimingForTesting()
            controller.dismiss(animated: false)
        }
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        controllers.removeAll()
        windows.removeAll()
        let stopped = expectation(description: "T35 real Core instances stopped")
        stopped.expectedFulfillmentCount = max(1, bridges.count)
        if bridges.isEmpty { stopped.fulfill() }
        for core in bridges { core.stop { stopped.fulfill() } }
        wait(for: [stopped], timeout: 15)
        bridges.removeAll()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    func testPurposeFirstButtonSendsPurposeAndCancelEndsOnlyThatCall() throws {
        let (core, screen) = try screen()
        let purpose = try XCTUnwrap(descendants(screen.view).compactMap { $0 as? PurposeButton }.first)
        let purposeID = String(try XCTUnwrap(purpose.accessibilityIdentifier).dropFirst("purpose_".count))
        purpose.sendActions(for: .touchUpInside)
        eventually { self.calls(core).count == 1 }
        XCTAssertEqual(calls(core).first?["purpose"] as? String, purposeID)
        XCTAssertEqual(calls(core).first?["call_flow"] as? String, "purpose_first")
        let callID = screen.visibleCallForTimingTest
        XCTAssertFalse(callID.isEmpty)
        try button("incall_end", in: screen).sendActions(for: .touchUpInside)
        XCTAssertEqual(screen.visibleCallForTimingTest, callID, "a hidden end action cannot end ringing")
        try button("calling_cancel", in: screen).sendActions(for: .touchUpInside)
        eventually { self.calls(core).isEmpty }
        XCTAssertTrue(screen.visibleCallForTimingTest.isEmpty)
    }

    func testRingThenPurposeSkipPreservesCallAndCancelRemainsSeparate() throws {
        let (core, screen) = try screen(mode: "ring_then_purpose")
        try button("call_primary", in: screen).sendActions(for: .touchUpInside)
        eventually { screen.presentedViewController is PurposeChoiceViewController }
        let choice = try XCTUnwrap(screen.presentedViewController as? PurposeChoiceViewController)
        eventually { self.calls(core).count == 1 }
        let callID = screen.visibleCallForTimingTest
        XCTAssertEqual(calls(core).first?["call_flow"] as? String, "ring_then_purpose")
        try button("purpose_choice_skip", in: choice).sendActions(for: .touchUpInside)
        eventually { screen.presentedViewController == nil }
        XCTAssertEqual(screen.visibleCallForTimingTest, callID)
        XCTAssertEqual(calls(core).first?["call_id"] as? String, callID)
        try button("calling_cancel", in: screen).sendActions(for: .touchUpInside)
        eventually { self.calls(core).isEmpty }

        try button("call_primary", in: screen).sendActions(for: .touchUpInside)
        eventually { screen.presentedViewController is PurposeChoiceViewController }
        let second = try XCTUnwrap(screen.presentedViewController as? PurposeChoiceViewController)
        try button("purpose_choice_cancel", in: second).sendActions(for: .touchUpInside)
        eventually { self.calls(core).isEmpty && screen.visibleCallForTimingTest.isEmpty }
    }

    func testAnsweredCoreRejectsQueuedVisitorCancelBeforeSIPUIArrives() throws {
        let (core, screen) = try screen()
        try button("call_primary", in: screen).sendActions(for: .touchUpInside)
        let callID = screen.visibleCallForTimingTest
        XCTAssertFalse(callID.isEmpty)
        eventually { self.calls(core).first?["call_id"] as? String == callID }
        let revision = (calls(core).first?["stage_revision"] as? NSNumber)?.intValue ?? -1
        XCTAssertTrue(core.reportCallAnswered(door: "front", callId: callID, stageRevision: revision))
        try button("calling_cancel", in: screen).sendActions(for: .touchUpInside)
        XCTAssertEqual(screen.visibleCallForTimingTest, callID,
                       "the real Core rejection cannot be rendered as idle")
        eventually { self.calls(core).first?["state"] as? String == "in_call" }
        // The SIP callback is a controlled UI input; the call itself is already answered in Core.
        screen.visitorEventForTesting(["t": "state", "state": "in_call", "call_id": callID])
        try button("calling_cancel", in: screen).sendActions(for: .touchUpInside)
        XCTAssertEqual(screen.visibleCallForTimingTest, callID)
        XCTAssertEqual(calls(core).first?["state"] as? String, "in_call")
    }

    func testCancelAndEndKeepTheSamePositionAcrossProfilesAndLargeText() throws {
        let profiles = [CGSize(width: 320, height: 480), CGSize(width: 844, height: 390),
                        CGSize(width: 768, height: 1024), CGSize(width: 1024, height: 768)]
        for size in profiles {
            let (_, screen) = try screen(size: size, category: .accessibilityExtraExtraExtraLarge)
            let cancel = try button("calling_cancel", in: screen)
            let end = try button("incall_end", in: screen)
            cancel.setTitle(size.width < size.height ? "Cancel this call" : "取消此次呼叫", for: .normal)
            end.setTitle(size.width < size.height ? "End this call" : "结束此次通话", for: .normal)
            screen.view.setNeedsLayout()
            screen.view.layoutIfNeeded()
            screen.view.layoutIfNeeded()
            let cancelFrame = cancel.convert(cancel.bounds, to: screen.view)
            let endFrame = end.convert(end.bounds, to: screen.view)
            XCTAssertEqual(cancelFrame.minY, endFrame.minY, accuracy: 1)
            XCTAssertEqual(cancelFrame.maxY, endFrame.maxY, accuracy: 1)
            XCTAssertGreaterThanOrEqual(cancelFrame.minY, 0)
            XCTAssertLessThanOrEqual(cancelFrame.maxY, size.height)
            XCTAssertGreaterThanOrEqual(cancelFrame.height, 56)
            XCTAssertGreaterThan(cancel.titleLabel?.font.pointSize ?? 0, 24)
            XCTAssertLessThanOrEqual(cancel.titleLabel?.sizeThatFits(CGSize(
                width: cancel.bounds.width - cancel.contentEdgeInsets.left - cancel.contentEdgeInsets.right,
                height: .greatestFiniteMagnitude)).height ?? 0, cancel.bounds.height)
        }
    }

    func testInCallStatusScrollNeverCoversEndAtLargestTextAcrossProfiles() throws {
        let profiles = [CGSize(width: 320, height: 480), CGSize(width: 480, height: 320),
                        CGSize(width: 844, height: 390), CGSize(width: 768, height: 1024),
                        CGSize(width: 1024, height: 768)]
        for size in profiles {
            let (_, screen) = try screen(size: size, category: .accessibilityExtraExtraExtraLarge)
            let title = try XCTUnwrap(descendants(screen.view).first {
                $0.accessibilityIdentifier == "incall_status"
            } as? UILabel)
            let scroll = try XCTUnwrap(descendants(screen.view).first {
                $0.accessibilityIdentifier == "incall_status_scroll"
            } as? UIScrollView)
            let end = try button("incall_end", in: screen)
            // This is a controlled SIP UI input; media remains disabled by the real screen fixture.
            screen.visitorEventForTesting(["t": "state", "state": "in_call", "call_id": "layout-call"])
            title.text = "Connected to the resident at the main entrance. 已接通主入口住户，请继续通话。"
            end.setTitle(size.width < size.height ? "End this call" : "结束通话", for: .normal)
            screen.view.setNeedsLayout()
            screen.view.layoutIfNeeded()
            screen.view.layoutIfNeeded()
            let actionFrame = end.convert(end.bounds, to: screen.view)
            let scrollFrame = scroll.convert(scroll.bounds, to: screen.view)
            XCTAssertGreaterThan(scrollFrame.height, 0)
            XCTAssertLessThanOrEqual(scrollFrame.maxY + 19, actionFrame.minY)
            XCTAssertTrue(scroll.clipsToBounds)
            XCTAssertFalse(end.isHidden)
            XCTAssertGreaterThanOrEqual(actionFrame.minY, 0)
            XCTAssertLessThanOrEqual(actionFrame.maxY, size.height)
            XCTAssertGreaterThanOrEqual(actionFrame.height, 56)
            XCTAssertEqual(title.bounds.width, scroll.bounds.width, accuracy: 1)
            for offset in [CGFloat(0), max(0, scroll.contentSize.height - scroll.bounds.height)] {
                scroll.contentOffset = CGPoint(x: 0, y: offset)
                let visibleTitle = title.convert(title.bounds, to: screen.view).intersection(scrollFrame)
                XCTAssertFalse(visibleTitle.isNull)
                XCTAssertFalse(visibleTitle.intersects(actionFrame),
                               "Visible title must not overlap the fixed end action at \(size)")
            }
            if size.height == 320 {
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height,
                                     "The short landscape must expose overflowing status by scrolling")
            }
        }
    }

    func testOfflineAndSosAreDifferentLayersWithoutClearingCoreEmergency() throws {
        let (_, screen) = try screen()
        let offline = try XCTUnwrap(descendants(screen.view).first {
            $0.accessibilityIdentifier == "visitor_offline_status"
        })
        let sos = try XCTUnwrap(descendants(screen.view).first {
            $0.accessibilityIdentifier == "visitor_sos_screen"
        })
        XCTAssertTrue(sos.isHidden)
        screen.visitorEventForTesting(["t": "emergency", "active": true,
            "channels": ["in_app"], "visual": true, "alarm_sound": ""])
        XCTAssertFalse(sos.isHidden)
        XCTAssertNotEqual(sos.backgroundColor, screen.view.backgroundColor)
        XCTAssertTrue(offline.accessibilityTraits.contains(.header))
        XCTAssertGreaterThanOrEqual(try button("visitor_sos_clear", in: screen).bounds.height, 44)
        screen.visitorEventForTesting(["t": "emergency", "active": false])
        XCTAssertTrue(sos.isHidden)
    }
}

final class VisitorAccessibleActionTests: XCTestCase {
    func testSosAccessibleActivationRequiresReviewAndCanCancelTheSameCountdown() throws {
        let texts = Texts()
        texts.setLang("en")
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let control = SosSlideControl(texts: texts)
        control.frame = CGRect(x: 0, y: 200, width: 390, height: 78)
        host.view.addSubview(control)
        host.view.layoutIfNeeded()
        var triggers = 0
        control.onTriggered = { triggers += 1 }
        XCTAssertTrue(control.accessibilityActivate())
        XCTAssertFalse(control.isCountingDown, "VoiceOver activation opens review before countdown")
        let review = try XCTUnwrap(host.presentedViewController as? UIAlertController)
        XCTAssertEqual(review.actions.count, 2)
        XCTAssertEqual(review.actions.filter { $0.style == .destructive }.count, 1)
        XCTAssertEqual(review.title, texts.t("sos.accessibility_confirm"))
        XCTAssertEqual(triggers, 0)
        control.cancelCountdown()
        control.startCountdown()
        XCTAssertTrue(control.isCountingDown)
        XCTAssertTrue(control.accessibilityActivate())
        XCTAssertFalse(control.isCountingDown)
        XCTAssertEqual(triggers, 0)
        control.isEnabled = false
        XCTAssertFalse(control.accessibilityActivate())
        XCTAssertFalse(control.keyCommands?.isEmpty ?? true)
    }

    func testResponsiveReparentingKeepsTheExistingCancellableCountdown() {
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        let control = SosSlideControl(texts: Texts())
        host.view.addSubview(control)
        control.startCountdown()
        control.removeFromSuperview()
        host.view.addSubview(control)
        let layout = expectation(description: "same-pass responsive reparenting")
        DispatchQueue.main.async { layout.fulfill() }
        wait(for: [layout], timeout: 2)
        XCTAssertTrue(control.isCountingDown)
        control.cancelCountdown()
        window.isHidden = true
        window.rootViewController = nil
    }

    func testDetachedSosCannotActivateAndLosesPendingCountdown() {
        let control = SosSlideControl(texts: Texts())
        XCTAssertFalse(control.accessibilityActivate())
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        host.view.addSubview(control)
        control.startCountdown()
        control.removeFromSuperview()
        let detached = expectation(description: "detached SOS retirement")
        DispatchQueue.main.async { detached.fulfill() }
        wait(for: [detached], timeout: 2)
        XCTAssertFalse(control.isCountingDown)
        XCTAssertFalse(control.accessibilityActivate())
        window.isHidden = true
        window.rootViewController = nil
    }
}
