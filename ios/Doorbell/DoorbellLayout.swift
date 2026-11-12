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
    static var positive: UIColor { return SystemStyle.positive }

    static func negative(_ palette: DoorbellPalette) -> UIColor { return SystemStyle.negative }
    static func warning(_ palette: DoorbellPalette) -> UIColor { return palette.notice }
}

/// One call action: a circular button with a caption under it, as on the system call screen.
/// The disc carries the role colour (positive, negative, or a quiet fill) and a vendored icon;
/// the caption is the button's own title, so two-part titles and semantic style overrides keep
/// working through the ordinary `UIButton` API. `backgroundColor` is the disc's colour.
final class CallActionButton: UIButton {
    private let disc = UIView()
    private let glyph = UIImageView()
    private var discColor: UIColor?

    var diameter: CGFloat = 60 {
        didSet { invalidateIntrinsicContentSize(); setNeedsLayout() }
    }

    var icon: String = "" {
        didSet { if icon != oldValue { glyph.image = TablerIcon.image(icon) } }
    }

    /// The icon's colour on the disc.
    var glyphColor: UIColor = .white {
        didSet { glyph.tintColor = glyphColor }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        disc.isUserInteractionEnabled = false
        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = glyphColor
        disc.addSubview(glyph)
        insertSubview(disc, at: 0)
        titleLabel?.numberOfLines = 0
        titleLabel?.textAlignment = .center
        titleLabel?.font = SystemStyle.font(.footnote)
        SystemStyle.followContentSize(titleLabel)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var backgroundColor: UIColor? {
        get { return discColor }
        set {
            discColor = newValue
            disc.backgroundColor = newValue
        }
    }

    private func captionSize(width: CGFloat) -> CGSize {
        guard let label = titleLabel, !(label.text ?? "").isEmpty
            || label.attributedText?.length ?? 0 > 0 else { return .zero }
        return label.sizeThatFits(CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
    }

    override var intrinsicContentSize: CGSize {
        let width = max(diameter + 16, bounds.width > 0 ? bounds.width : diameter + 32)
        let caption = captionSize(width: width)
        return CGSize(width: max(diameter + 16, min(caption.width, 160)),
                      height: diameter + (caption.height > 0 ? 6 + ceil(caption.height) : 0))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        disc.frame = CGRect(x: (bounds.width - diameter) / 2, y: 0, width: diameter,
                            height: diameter)
        disc.layer.cornerRadius = diameter / 2
        let side = diameter * 0.46
        glyph.frame = CGRect(x: (diameter - side) / 2, y: (diameter - side) / 2, width: side,
                             height: side)
        let caption = captionSize(width: bounds.width)
        titleLabel?.frame = CGRect(x: 0, y: diameter + 6, width: bounds.width,
                                   height: ceil(caption.height))
        imageView?.isHidden = true
        if abs(intrinsicContentSize.height - bounds.height) > 0.5 {
            invalidateIntrinsicContentSize()
        }
    }

    override var isHighlighted: Bool {
        didSet { disc.alpha = isHighlighted ? 0.6 : 1 }
    }

    /// False for a filled semantic action (Answer, End), which keeps its full-strength fill and
    /// ink while it is unavailable.
    var dimsWhenDisabled = true {
        didSet { alpha = isEnabled || !dimsWhenDisabled ? 1 : 0.4 }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled || !dimsWhenDisabled ? 1 : 0.4 }
    }

    #if os(tvOS)
    override var canBecomeFocused: Bool { return isEnabled && !isHidden }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({ [weak self] in
            self?.disc.transform = focused ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
            self?.disc.layer.shadowOpacity = focused ? 0.4 : 0
            self?.disc.layer.shadowRadius = 12
            self?.disc.layer.shadowOffset = CGSize(width: 0, height: 8)
        }, completion: nil)
    }
    #endif
}

/// The fixed action zone: call actions in a fixed order, pinned to the bottom (portrait) or the
/// trailing column (landscape) inside the safe area. Content scrolls; actions never move. A
/// hidden action leaves its row, and the others keep their order.
final class ActionZoneView: UIView {
    let primaryRow = UIStackView()
    let secondaryRow = UIStackView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for row in [primaryRow, secondaryRow] {
            row.axis = .horizontal
            row.spacing = Space.xs
            row.distribution = .fillEqually
            row.alignment = .top
        }
        stack.axis = .vertical
        stack.spacing = Space.m
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

    /// `primary` is Answer (or End), Reply, Ignore in that order, with the first one the
    /// largest; `secondary` is Monitor, Unlock and the in-call microphone.
    func setActions(primary: [CallActionButton], secondary: [CallActionButton]) {
        for row in [primaryRow, secondaryRow] {
            for view in row.arrangedSubviews {
                row.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
        for (index, button) in primary.enumerated() {
            button.diameter = index == 0 ? TouchTarget.visitor : TouchTarget.primary
            primaryRow.addArrangedSubview(button)
        }
        for button in secondary {
            button.diameter = TouchTarget.minimum + 8
            secondaryRow.addArrangedSubview(button)
        }
    }

    /// The second row disappears with its last action so it leaves no gap.
    func refreshRows() {
        secondaryRow.isHidden = secondaryRow.arrangedSubviews.allSatisfy { $0.isHidden }
        primaryRow.isHidden = primaryRow.arrangedSubviews.allSatisfy { $0.isHidden }
    }
}

/// A list of one-tap choices in a system sheet: a medium-detent sheet on iOS 15 and later, a
/// form sheet before that, and a popover beside its source on wider windows. The presenting
/// screen stays underneath and alive.
final class ActionSheetController: UINavigationController {
    struct Choice {
        let id: String
        let title: String
    }

    init(title: String, choices: [Choice], source: UIView,
         onChoose: @escaping (Choice) -> Void) {
        let list = ActionSheetListController(choices: choices, onChoose: onChoose)
        list.title = title
        super.init(rootViewController: list)
        #if os(iOS)
        if LayoutClass.of(width: source.window?.bounds.width ?? 0) != .compact {
            modalPresentationStyle = .popover
            popoverPresentationController?.sourceView = source
            popoverPresentationController?.sourceRect = source.bounds
            preferredContentSize = CGSize(width: 380,
                                          height: min(560, CGFloat(choices.count) * 52 + 64))
        } else if #available(iOS 15.0, *) {
            modalPresentationStyle = .pageSheet
            sheetPresentationController?.detents = [.medium(), .large()]
            sheetPresentationController?.prefersGrabberVisible = true
        } else {
            modalPresentationStyle = .formSheet
        }
        #else
        modalPresentationStyle = .overFullScreen
        #endif
    }

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

private final class ActionSheetListController: UITableViewController {
    private let choices: [ActionSheetController.Choice]
    private let onChoose: (ActionSheetController.Choice) -> Void

    init(choices: [ActionSheetController.Choice],
         onChoose: @escaping (ActionSheetController.Choice) -> Void) {
        self.choices = choices
        self.onChoose = onChoose
        super.init(style: SystemStyle.tableStyle())
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        SystemStyle.style(tableView)
        tableView.accessibilityIdentifier = "action_sheet"
        #if os(iOS)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        #endif
    }

    @objc private func cancel() { dismiss(animated: !Motion.reduced) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return choices.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        SystemStyle.style(cell)
        cell.textLabel?.text = choices[indexPath.row].title
        cell.textLabel?.numberOfLines = 0
        cell.accessibilityIdentifier = "sheet_\(choices[indexPath.row].id)"
        cell.accessibilityTraits = .button
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let choice = choices[indexPath.row]
        dismiss(animated: !Motion.reduced) { [onChoose] in onChoose(choice) }
    }
}
