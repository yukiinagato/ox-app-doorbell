import UIKit

// Shared layout tokens from docs/en/ui-guidelines.md. Every screen picks its arrangement from the
// current window width (never the device model), uses the 4-point spacing grid and the minimum
// touch targets, scales its type with Dynamic Type, and skips motion when Reduce Motion is on.

enum LayoutClass: Equatable {
    case compact
    case medium
    case expanded

    /// < 600 compact, 600–899 medium, ≥ 900 expanded.
    static func of(width: CGFloat) -> LayoutClass {
        if width >= 900 { return .expanded }
        if width >= 600 { return .medium }
        return .compact
    }

    static func of(_ view: UIView) -> LayoutClass {
        return of(width: view.bounds.width)
    }

    /// Door tiles and purpose cards: 1 / 2 / 3–4 columns.
    func columns(maximum: Int = 4) -> Int {
        switch self {
        case .compact: return 1
        case .medium: return min(2, maximum)
        case .expanded: return min(maximum, 3)
        }
    }

    /// Video beside details only when the window is wide and not taller than it is wide.
    static func sideBySide(_ size: CGSize) -> Bool {
        return size.width >= 600 && size.width >= size.height
    }
}

enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}

enum TouchTarget {
    static let minimum: CGFloat = 44
    /// Door-station visitor controls are read and pressed from a standing distance.
    static let visitor: CGFloat = 72
    /// The primary action of a screen.
    static let primary: CGFloat = 64
}

enum Radius {
    static let card: CGFloat = 12
    static let sheet: CGFloat = 20
}

/// Type scale relative to the platform body size; every size follows Dynamic Type.
enum TypeRole {
    case caption, body, title, headline, display

    var factor: CGFloat {
        switch self {
        case .caption: return 0.8
        case .body: return 1.0
        case .title: return 1.25
        case .headline: return 1.6
        case .display: return 2.2
        }
    }

    func font(weight: UIFont.Weight = .regular, base: CGFloat = 17) -> UIFont {
        let style: UIFont.TextStyle
        switch self {
        case .caption: style = .footnote
        case .body: style = .body
        case .title: style = .title3
        case .headline: style = .title2
        case .display: style = .title1
        }
        return IOSAvailability.visitorFont(size: base * factor, weight: weight, style: style)
    }
}

enum Motion {
    static var reduced: Bool {
        #if os(iOS)
        return UIAccessibility.isReduceMotionEnabled
        #else
        return false
        #endif
    }

    /// 150–250 ms ease-out, or no animation at all with Reduce Motion.
    static func animate(_ duration: TimeInterval = 0.2, _ changes: @escaping () -> Void,
                        completion: ((Bool) -> Void)? = nil) {
        guard !reduced else {
            changes()
            completion?(true)
            return
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState],
                       animations: changes, completion: completion)
    }
}

/// Colour roles from the guidelines. Surfaces and inks come from Core's regions through the
/// palette and skin; positive and negative are the fixed answer/hang-up roles.
enum ColorRole {
    static let positive = UIColor(red: 0.20, green: 0.70, blue: 0.36, alpha: 1)

    static func negative(_ palette: DoorbellPalette) -> UIColor { return palette.danger }
    static func warning(_ palette: DoorbellPalette) -> UIColor { return palette.notice }
}

/// The fixed action zone: a bar pinned to the bottom (portrait) or right edge (landscape),
/// above the safe area. Content scrolls behind it; actions never move.
final class ActionZoneView: UIView {
    let primaryRow = UIStackView()
    let secondaryRow = UIStackView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for row in [primaryRow, secondaryRow] {
            row.axis = .horizontal
            row.spacing = Space.xs
            row.distribution = .fill
            row.alignment = .fill
        }
        stack.axis = .vertical
        stack.spacing = Space.xs
        stack.addArrangedSubview(primaryRow)
        stack.addArrangedSubview(secondaryRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// `primary` buttons share the first row with the first one twice as wide; `secondary`
    /// buttons share the second row equally. Hidden buttons simply leave the row.
    func setActions(primary: [UIButton], secondary: [UIButton]) {
        for row in [primaryRow, secondaryRow] {
            for view in row.arrangedSubviews {
                row.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
        for (index, button) in primary.enumerated() {
            primaryRow.addArrangedSubview(button)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant:
                index == 0 ? TouchTarget.primary : TouchTarget.minimum + 12).isActive = true
            if index > 0 {
                let wide = primary[0].widthAnchor.constraint(equalTo: button.widthAnchor, multiplier: 2)
                wide.priority = UILayoutPriority(250)
                wide.isActive = true
            }
        }
        secondaryRow.distribution = .fillEqually
        for button in secondary {
            secondaryRow.addArrangedSubview(button)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchTarget.minimum + 4).isActive = true
        }
    }
}

/// A bottom sheet on compact windows and a popover beside its source on wider ones. The
/// presenting screen stays underneath and alive.
final class ActionSheetController: UIViewController {
    struct Choice {
        let id: String
        let title: String
    }

    private let titleText: String
    private let choices: [Choice]
    private let palette: DoorbellPalette
    private let onChoose: (Choice) -> Void
    private let card = UIView()
    private let usesPopover: Bool

    init(title: String, choices: [Choice], palette: DoorbellPalette, source: UIView,
         onChoose: @escaping (Choice) -> Void) {
        self.titleText = title
        self.choices = choices
        self.palette = palette
        self.onChoose = onChoose
        #if os(iOS)
        usesPopover = LayoutClass.of(width: source.window?.bounds.width ?? 0) != .compact
        #else
        usesPopover = false
        #endif
        super.init(nibName: nil, bundle: nil)
        #if os(iOS)
        if usesPopover {
            modalPresentationStyle = .popover
            popoverPresentationController?.sourceView = source
            popoverPresentationController?.sourceRect = source.bounds
            popoverPresentationController?.backgroundColor = palette.surfaceSolid
            preferredContentSize = CGSize(width: 380,
                                          height: min(560, CGFloat(choices.count) * 64 + 72))
        } else {
            modalPresentationStyle = .overFullScreen
            modalTransitionStyle = .crossDissolve
        }
        #else
        modalPresentationStyle = .overFullScreen
        #endif
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = UILabel()
        title.text = titleText
        title.font = TypeRole.title.font(weight: .semibold)
        title.textColor = palette.ink
        title.numberOfLines = 0
        let list = UIStackView(arrangedSubviews: [title])
        list.axis = .vertical
        list.spacing = Space.xs
        for (index, choice) in choices.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(choice.title, for: .normal)
            button.titleLabel?.font = TypeRole.body.font(weight: .medium, base: 20)
            button.titleLabel?.numberOfLines = 0
            button.contentHorizontalAlignment = .left
            button.tag = index
            button.accessibilityIdentifier = "sheet_\(choice.id)"
            #if os(iOS)
            button.setTitleColor(palette.ink, for: .normal)
            button.backgroundColor = palette.surfaceStrongSolid
            button.layer.cornerRadius = Radius.card
            button.contentEdgeInsets = UIEdgeInsets(top: Space.s, left: Space.m,
                                                    bottom: Space.s, right: Space.m)
            #endif
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchTarget.minimum + 8)
                .isActive = true
            button.addTarget(self, action: #selector(chose(_:)), for: .primaryActionTriggered)
            list.addArrangedSubview(button)
        }
        let scroll = UIScrollView()
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(list)
        card.addSubview(scroll)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = palette.surfaceSolid
        view.addSubview(card)
        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: Space.m),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Space.m),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Space.m),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Space.m),
            list.topAnchor.constraint(equalTo: scroll.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            list.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        let fit = scroll.heightAnchor.constraint(equalTo: list.heightAnchor)
        fit.priority = UILayoutPriority(750)
        fit.isActive = true
        if usesPopover {
            view.backgroundColor = palette.surfaceSolid
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: guide.topAnchor),
                card.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
                card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        } else {
            view.backgroundColor = UIColor(white: 0, alpha: 0.45)
            card.layer.cornerRadius = Radius.sheet
            NSLayoutConstraint.activate([
                card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                card.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                card.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: Space.xxl),
                scroll.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -Space.m),
            ])
            let tap = UITapGestureRecognizer(target: self, action: #selector(cancel(_:)))
            tap.cancelsTouchesInView = false
            view.addGestureRecognizer(tap)
        }
    }

    @objc private func chose(_ sender: UIButton) {
        guard sender.tag < choices.count else { return }
        let choice = choices[sender.tag]
        dismiss(animated: !Motion.reduced) { [onChoose] in onChoose(choice) }
    }

    @objc private func cancel(_ recognizer: UITapGestureRecognizer) {
        guard !card.frame.contains(recognizer.location(in: view)) else { return }
        dismiss(animated: !Motion.reduced)
    }
}
