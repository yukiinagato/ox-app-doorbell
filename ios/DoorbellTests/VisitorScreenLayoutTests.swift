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
        let purposeSection = UIStackView(arrangedSubviews: [purposeHint])
        purposeSection.axis = .vertical

        let sos = SosSlideControl(texts: texts)
        let view = VisitorScreenView(texts: texts, callButton: UIButton(type: .system),
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
        return Screen(view: view, langBar: langBar, sos: sos, purposeHint: purposeHint)
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
