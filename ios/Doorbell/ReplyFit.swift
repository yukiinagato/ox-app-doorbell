import UIKit

/// Sizing of a resident's quick reply on the door station: the largest type at which the whole
/// text fits the content area.
enum ReplyFit {
    static let floorSize: CGFloat = 28
    static let lineHeightMultiple: CGFloat = 1.15
    private static let resolution: CGFloat = 0.5

    struct Fit: Equatable {
        let size: CGFloat
        /// False only when even the floor does not fit; the caller then scrolls.
        let fits: Bool
    }

    /// Binary search between `floor` and the box height. `measure` returns the wrapped size of
    /// `text` at the given font size and maximum width, using the platform's own text layout.
    static func fit(text: String, width: CGFloat, height: CGFloat, floor: CGFloat = floorSize,
                    measure: (_ text: String, _ size: CGFloat, _ maxWidth: CGFloat) -> CGSize) -> Fit {
        guard width > 0, height > 0 else { return Fit(size: floor, fits: false) }
        func fits(_ size: CGFloat) -> Bool {
            let used = measure(text, size, width)
            return used.width <= width + 0.5 && used.height <= height
        }
        guard fits(floor) else { return Fit(size: floor, fits: false) }
        var low = floor
        var high = Swift.max(floor, height)
        if fits(high) { return Fit(size: high, fits: true) }
        while high - low > resolution {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        return Fit(size: low, fits: true)
    }

    static func font(size: CGFloat) -> UIFont {
        return .systemFont(ofSize: size, weight: .heavy)
    }

    static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        style.lineHeightMultiple = lineHeightMultiple
        return style
    }

    static func attributed(_ text: String, size: CGFloat, color: UIColor) -> NSAttributedString {
        return NSAttributedString(string: text, attributes: [
            .font: font(size: size), .foregroundColor: color,
            .paragraphStyle: paragraphStyle(),
        ])
    }

    /// UIKit wraps CJK per character and Latin per word at `.byWordWrapping`, and honours
    /// explicit newlines. The width is shaved by a point so the label never wraps differently.
    static func measure(_ text: String, size: CGFloat, maxWidth: CGFloat) -> CGSize {
        let rect = attributed(text, size: size, color: .white).boundingRect(
            with: CGSize(width: Swift.max(1, maxWidth - 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], context: nil)
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}

/// Two-step dismissal of the reply overlay. Inputs are times in seconds since the reply was
/// shown, so the rule is testable without a clock.
struct ReplyDismissGuard {
    static let lockout: TimeInterval = 3
    static let confirmWindow: TimeInterval = 3
    static let minimumGap: TimeInterval = 0.3

    enum Action: Equatable { case ignore, arm, close }
    enum Hint: Equatable { case none, first, confirm }

    private var armedAt: TimeInterval?

    mutating func tap(at time: TimeInterval) -> Action {
        guard time >= ReplyDismissGuard.lockout else { return .ignore }
        if let armed = armedAt, time - armed <= ReplyDismissGuard.confirmWindow {
            return time - armed >= ReplyDismissGuard.minimumGap ? .close : .ignore
        }
        armedAt = time
        return .arm
    }

    func hint(at time: TimeInterval) -> Hint {
        guard time >= ReplyDismissGuard.lockout else { return .none }
        if let armed = armedAt, time - armed <= ReplyDismissGuard.confirmWindow { return .confirm }
        return .first
    }
}

/// The reply as an opaque full-screen overlay. Its text box is the screen minus the safe area and
/// a margin, less one caption line at the bottom for the exit hint and the countdown. A tap
/// follows `ReplyDismissGuard`.
final class ReplyOverlayView: UIView {
    static let surface = UIColor(red: 0.11, green: 0.30, blue: 0.16, alpha: 1)
    static let ink = UIColor.white
    private static let secondaryInk = UIColor(white: 1, alpha: 0.85)

    let caption = UILabel()
    private let hint = UILabel()
    private let countdown = UILabel()
    private let scroll = UIScrollView()
    private let label = UILabel()
    private var laidOut: (text: String, size: CGSize)?
    private var guardState = ReplyDismissGuard()
    private var shownAt: CFTimeInterval = 0
    private var ttl: TimeInterval = 30
    private var ticker: Timer?

    var hintFirst = ""
    var hintConfirm = ""
    var onDismiss: (() -> Void)?
    var margin: CGFloat = 16 {
        didSet { laidOut = nil; setNeedsLayout() }
    }

    private(set) var text = ""
    private(set) var fittedSize: CGFloat = 0
    private(set) var scrolls = false

    override var isHidden: Bool {
        didSet { if isHidden { ticker?.invalidate(); ticker = nil } }
    }

    /// A newer reply replaces the older one and restarts the lockout and the countdown.
    func show(text newText: String, ttl seconds: TimeInterval) {
        text = newText
        ttl = seconds
        shownAt = CACurrentMediaTime()
        guardState = ReplyDismissGuard()
        laidOut = nil
        isHidden = false
        ticker?.invalidate()
        ticker = IOSAvailability.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in self?.refreshChrome()
        }
        refreshChrome()
        setNeedsLayout()
    }

    private func elapsed(_ now: CFTimeInterval = CACurrentMediaTime()) -> TimeInterval {
        return now - shownAt
    }

    func refreshChrome(now: CFTimeInterval = CACurrentMediaTime()) {
        let time = elapsed(now)
        countdown.text = "\(Int(Swift.max(0, ceil(ttl - time))))"
        switch guardState.hint(at: time) {
        case .none: hint.text = nil
        case .first:
            hint.text = hintFirst
            hint.font = .systemFont(ofSize: 18, weight: .semibold)
        case .confirm:
            hint.text = hintConfirm
            hint.font = .systemFont(ofSize: 18, weight: .heavy)
        }
        accessibilityValue = hint.text
    }

    func handleTap(now: CFTimeInterval = CACurrentMediaTime()) {
        let action = guardState.tap(at: elapsed(now))
        refreshChrome(now: now)
        if action == .close { onDismiss?() }
    }

    @objc private func tapped() { handleTap() }

    override func accessibilityActivate() -> Bool {
        handleTap()
        return true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ReplyOverlayView.surface
        isAccessibilityElement = true
        accessibilityTraits = .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        caption.font = .systemFont(ofSize: 18, weight: .semibold)
        caption.textColor = ReplyOverlayView.secondaryInk
        caption.textAlignment = .center
        hint.font = .systemFont(ofSize: 18, weight: .semibold)
        hint.textColor = ReplyOverlayView.ink
        hint.textAlignment = .center
        hint.adjustsFontSizeToFitWidth = true
        hint.minimumScaleFactor = 0.6
        countdown.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        countdown.textColor = ReplyOverlayView.secondaryInk
        countdown.textAlignment = .right
        label.numberOfLines = 0
        label.accessibilityIdentifier = "visitor_reply_text"
        scroll.showsVerticalScrollIndicator = true
        scroll.addSubview(label)
        for view in [caption, scroll, hint, countdown] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        var insets = UIEdgeInsets.zero
        if #available(iOS 11.0, *) { insets = safeAreaInsets }
        let box = CGRect(x: insets.left + margin, y: insets.top + margin,
                         width: Swift.max(0, bounds.width - insets.left - insets.right - margin * 2),
                         height: Swift.max(0, bounds.height - insets.top - insets.bottom - margin * 2))
        let line = ceil(caption.font.lineHeight)
        caption.frame = CGRect(x: box.minX, y: box.minY, width: box.width, height: line)
        let bottomY = box.maxY - line
        let side = Swift.min(80, box.width / 4)
        hint.frame = CGRect(x: box.minX + side, y: bottomY, width: Swift.max(0, box.width - side * 2),
                            height: line)
        countdown.frame = CGRect(x: box.maxX - side, y: bottomY, width: side, height: line)
        let top = line + 8
        let area = CGRect(x: box.minX, y: box.minY + top, width: box.width,
                          height: Swift.max(0, box.height - top - line - 8))
        scroll.frame = area
        if let last = laidOut, last.text == text, last.size == area.size { return }
        laidOut = (text, area.size)
        let result = ReplyFit.fit(text: text, width: area.width, height: area.height,
                                  measure: ReplyFit.measure)
        fittedSize = result.size
        scrolls = !result.fits
        label.attributedText = ReplyFit.attributed(text, size: result.size, color: ReplyOverlayView.ink)
        let used = ReplyFit.measure(text, size: result.size, maxWidth: area.width)
        let height = Swift.max(used.height, 0)
        label.frame = CGRect(x: 0, y: Swift.max(0, (area.height - height) / 2),
                             width: area.width, height: height)
        scroll.contentSize = CGSize(width: area.width, height: Swift.max(area.height, height))
        scroll.contentOffset = .zero
    }
}
