import UIKit
import XCTest

@testable import Doorbell

/// The door-station screen's geometry in both orientations. The device can only be photographed
/// in the orientation it happens to be in, so landscape is held here instead.
final class VisitorScreenLayoutTests: XCTestCase {

    private let portrait = CGSize(width: 1536 / 2, height: 2048 / 2)
    private let landscape = CGSize(width: 2048 / 2, height: 1536 / 2)

    private struct Screen {
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
            langBar.addArrangedSubview(chip)
        }

        let purposeHint = UILabel()
        purposeHint.text = texts.t("idle.choose_purpose")
        purposeHint.isHidden = true

        // Six purposes in two rows of three, the shape the door station actually shows.
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 12
        grid.alignment = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false
        var buttons: [UIButton] = []
        for index in 0..<6 {
            if index % 3 == 0 {
                let row = UIStackView()
                row.axis = .horizontal
                row.spacing = 12
                row.distribution = .fillEqually
                grid.addArrangedSubview(row)
            }
            let button = UIButton(type: .system)
            button.setTitle("purpose \(index)", for: .normal)
            let minimum = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
            minimum.priority = UILayoutPriority(999)
            minimum.isActive = true
            button.heightAnchor.constraint(equalToConstant: 92).isActive = true
            (grid.arrangedSubviews.last as? UIStackView)?.addArrangedSubview(button)
            buttons.append(button)
        }
        let gridWidth = grid.widthAnchor.constraint(equalToConstant: 552)
        gridWidth.priority = UILayoutPriority(750)
        gridWidth.isActive = true

        let purposeSection = UIStackView(arrangedSubviews: [purposeHint, grid])
        purposeSection.axis = .vertical
        purposeSection.alignment = .center

        let sos = SosSlideControl(texts: texts)
        let callButton = UIButton(type: .system)
        callButton.setTitle(texts.t("idle.call_button_verb"), for: .normal)
        callButton.titleLabel?.font = .systemFont(ofSize: 40, weight: .bold)
        let view = VisitorScreenView(texts: texts, callButton: callButton,
                                     langBar: langBar, purposeSection: purposeSection,
                                     sosControl: sos)
        let host = UIView(frame: CGRect(origin: .zero, size: size))
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        view.applyLayout(for: size)
        host.layoutIfNeeded()
        return Screen(view: view, langBar: langBar, sos: sos, purposeHint: purposeHint,
                      purposeButtons: buttons, purposeSection: purposeSection, callButton: callButton)
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
            XCTAssertEqual(screen.sos.frame.maxY, landscape.height, accuracy: 1)
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
            XCTAssertEqual(screen.sos.frame.maxY, size.height, accuracy: 1, "\(name)")
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
