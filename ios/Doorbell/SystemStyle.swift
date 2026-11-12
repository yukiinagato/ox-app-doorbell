import UIKit

/// The platform's own look with the household's accent (docs/en/ui-guidelines.md, principle 7).
///
/// Surfaces, text colours, materials and light/dark come from UIKit. Core contributes the
/// effective appearance and the accent; `positive` and `negative` stay fixed semantic roles.
/// iOS 13 and later use the dynamic system colours, so a screen only has to name a role. iOS 9
/// through 12 have no dark mode and no semantic colours, so the same roles resolve to the static
/// values of the matching system palette for the appearance Core chose.
enum SystemStyle {

    /// Posted after the appearance or accent moved. Screens that painted static colours
    /// (iOS 9 through 12) repaint from it; on iOS 13 and later the trait system already did.
    static let changed = Notification.Name("DoorbellSystemStyleChanged")

    private(set) static var appearance: DoorbellAppearance = .light
    private(set) static var followsSystem = true
    private(set) static var accent: UIColor?

    static var isDark: Bool { return appearance == .dark }

    /// True where UIKit resolves colours per trait collection by itself.
    static var hasDynamicColors: Bool {
        if #available(iOS 13.0, tvOS 13.0, *) { return true }
        return false
    }

    // MARK: - Adopting Core's appearance and accent

    /// Takes the appearance Core resolved for this device and applies it to every window. With
    /// `followsSystem` the windows keep the operating system's own setting.
    static func adopt(_ resolved: DoorbellAppearance, followsSystem follows: Bool,
                      accent newAccent: UIColor?) {
        let moved = resolved != appearance || follows != followsSystem ||
            !sameColor(newAccent, accent)
        appearance = resolved
        followsSystem = follows
        accent = newAccent
        for window in UIApplication.shared.windows { apply(to: window) }
        guard moved else { return }
        applyLegacyBarAppearance()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Resolves the display contract into the appearance, the follow-system flag and the accent,
    /// adopts them, and returns the palette that matches.
    @discardableResult
    static func adopt(display: [String: Any]?, config: [String: Any]?, nodeId: String,
                      localTime: [String: Any]?) -> DoorbellPalette {
        let resolved = DoorbellTheme.appearance(display: display, config: config, nodeId: nodeId,
                                                localTime: localTime)
        adopt(resolved,
              followsSystem: followsSystem(display: display, config: config, nodeId: nodeId),
              accent: householdAccent(display: display, config: config, nodeId: nodeId,
                                      appearance: resolved))
        return DoorbellPalette.of(resolved)
    }

    static func apply(to window: UIWindow) {
        if #available(iOS 13.0, tvOS 13.0, *) {
            let style: UIUserInterfaceStyle = followsSystem ? .unspecified
                : (appearance == .dark ? .dark : .light)
            if window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
        }
        #if os(iOS)
        if !sameColor(window.tintColor, accent ?? defaultTint) {
            window.tintColor = accent ?? defaultTint
        }
        #endif
    }

    /// Whether Core leaves light/dark to the operating system on this device.
    static func followsSystem(display: [String: Any]?, config: [String: Any]?,
                              nodeId: String) -> Bool {
        guard hasDynamicColors else { return false }
        if ConfigUtil.str(display, "appearance.effective") != nil {
            return ConfigUtil.bool(display, "appearance.follow_system", false)
        }
        var mode = ConfigUtil.str(config, "display.appearance") ?? "auto_system"
        if !nodeId.isEmpty,
           let override = ConfigUtil.str(config, "devices.\(nodeId).local.display.appearance") {
            mode = override
        }
        return mode == "auto_system"
    }

    /// Core's accent as the UIKit tint: the call-button colour an administrator chose
    /// (`theme.call_button_bg` where it differs from Core's automatic one), used while it stays
    /// legible as a control colour on the system background. The automatic colour is derived to
    /// stand out against the wallpaper, not against system surfaces, so it is not used here and
    /// the system blue stays.
    static func householdAccent(display: [String: Any]?, config: [String: Any]?, nodeId: String,
                                appearance: DoorbellAppearance) -> UIColor? {
        guard let value = ConfigUtil.str(display, "theme.call_button_bg"),
              let published = DoorbellTheme.color(hex: value) else { return nil }
        let automatic = ConfigUtil.str(display, "theme.auto_accent.call_button")
        guard automatic == nil || automatic?.lowercased() != value.lowercased() else { return nil }
        let ground: UIColor = appearance == .dark ? .black : .white
        return DoorbellTheme.contrast(published, ground) >= 3 ? published : nil
    }

    private static func sameColor(_ first: UIColor?, _ second: UIColor?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case let (a?, b?): return a.isEqual(b)
        default: return false
        }
    }

    /// iOS 9 through 12 only: bars have no semantic colours there, so the bar style carries the
    /// appearance. Later systems resolve bars from the window's interface style.
    private static func applyLegacyBarAppearance() {
        #if os(iOS)
        guard !hasDynamicColors else { return }
        let style: UIBarStyle = isDark ? .black : .default
        UINavigationBar.appearance().barStyle = style
        UITabBar.appearance().barStyle = style
        UIToolbar.appearance().barStyle = style
        UISearchBar.appearance().barStyle = style
        UITextField.appearance().keyboardAppearance = isDark ? .dark : .default
        #endif
    }

    // MARK: - Colour roles

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                       green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A colour that has no system name on this OS: the given light and dark values, resolved per
    /// trait collection where UIKit can and from Core's appearance where it cannot.
    private static func pair(light: UIColor, dark: UIColor) -> UIColor {
        if #available(iOS 13.0, tvOS 13.0, *) {
            return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        }
        return isDark ? dark : light
    }

    static var defaultTint: UIColor {
        if #available(iOS 13.0, tvOS 13.0, *) { return .systemBlue }
        return isDark ? rgb(0x0A84FF) : rgb(0x007AFF)
    }

    /// The control colour: Core's accent when it publishes one, the system blue otherwise.
    static var tint: UIColor { return accent ?? defaultTint }

    static var background: UIColor {
        #if os(iOS)
        if #available(iOS 13.0, *) { return .systemBackground }
        #endif
        return pair(light: .white, dark: .black)
    }

    static var groupedBackground: UIColor {
        #if os(iOS)
        if #available(iOS 13.0, *) { return .systemGroupedBackground }
        #endif
        return pair(light: rgb(0xF2F2F7), dark: .black)
    }

    /// A row or card on the grouped background.
    static var cellBackground: UIColor {
        #if os(iOS)
        if #available(iOS 13.0, *) { return .secondarySystemGroupedBackground }
        #endif
        return pair(light: .white, dark: rgb(0x1C1C1E))
    }

    static var fill: UIColor {
        #if os(iOS)
        if #available(iOS 13.0, *) { return .tertiarySystemFill }
        #endif
        return pair(light: rgb(0x767680, alpha: 0.12), dark: rgb(0x767680, alpha: 0.24))
    }

    static var label: UIColor {
        if #available(iOS 13.0, tvOS 13.0, *) { return .label }
        return isDark ? .white : .black
    }

    static var secondaryLabel: UIColor {
        if #available(iOS 13.0, tvOS 13.0, *) { return .secondaryLabel }
        return isDark ? rgb(0xEBEBF5, alpha: 0.6) : rgb(0x3C3C43, alpha: 0.6)
    }

    static var tertiaryLabel: UIColor {
        if #available(iOS 13.0, tvOS 13.0, *) { return .tertiaryLabel }
        return isDark ? rgb(0xEBEBF5, alpha: 0.3) : rgb(0x3C3C43, alpha: 0.3)
    }

    static var separator: UIColor {
        if #available(iOS 13.0, tvOS 13.0, *) { return .separator }
        return isDark ? rgb(0x545458, alpha: 0.6) : rgb(0x3C3C43, alpha: 0.29)
    }

    /// Answer and connected.
    static var positive: UIColor {
        if #available(iOS 13.0, tvOS 13.0, *) { return .systemGreen }
        return isDark ? rgb(0x30D158) : rgb(0x34C759)
    }

    /// Hang up, SOS and errors.
    static var negative: UIColor {
        if #available(iOS 13.0, tvOS 13.0, *) { return .systemRed }
        return isDark ? rgb(0xFF453A) : rgb(0xFF3B30)
    }

    static var warning: UIColor {
        if #available(iOS 13.0, tvOS 13.0, *) { return .systemOrange }
        return isDark ? rgb(0xFF9F0A) : rgb(0xFF9500)
    }

    // MARK: - Type

    /// A Dynamic Type text style, optionally at another weight.
    static func font(_ style: UIFont.TextStyle, weight: UIFont.Weight? = nil) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        guard let weight = weight else { return base }
        return UIFont.systemFont(ofSize: base.pointSize, weight: weight)
    }

    /// The platform's largest display style: the dashboard clock and the door-station call label.
    static var displayStyle: UIFont.TextStyle {
        #if os(iOS)
        if #available(iOS 11.0, *) { return .largeTitle }
        #endif
        return .title1
    }

    /// Digits that do not shift as they change, scaled with Dynamic Type from `size`.
    static func digits(size: CGFloat, weight: UIFont.Weight = .light,
                       traits: UITraitCollection? = nil) -> UIFont {
        let base = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        #if os(iOS)
        if #available(iOS 11.0, *) {
            return UIFontMetrics(forTextStyle: displayStyle)
                .scaledFont(for: base, maximumPointSize: size * 1.6, compatibleWith: traits)
        }
        #endif
        return base
    }

    static func followContentSize(_ label: UILabel?) {
        if #available(iOS 10.0, tvOS 10.0, *) { label?.adjustsFontForContentSizeCategory = true }
    }

    static func label(_ style: UIFont.TextStyle, weight: UIFont.Weight? = nil,
                      color: UIColor? = nil, lines: Int = 0) -> UILabel {
        let view = UILabel()
        view.font = font(style, weight: weight)
        view.textColor = color ?? label
        view.numberOfLines = lines
        followContentSize(view)
        return view
    }

    // MARK: - Tables and bars

    static func tableStyle() -> UITableView.Style {
        #if os(iOS)
        if #available(iOS 13.0, *) { return .insetGrouped }
        #endif
        return .grouped
    }

    /// Tables keep their stock appearance. Only the systems without semantic colours need the
    /// grouped background and separator spelled out.
    static func style(_ table: UITableView) {
        table.estimatedRowHeight = 52
        table.rowHeight = UITableView.automaticDimension
        table.cellLayoutMarginsFollowReadableWidth = true
        #if os(iOS)
        guard !hasDynamicColors else { return }
        table.backgroundView = nil
        table.backgroundColor = groupedBackground
        table.separatorColor = separator
        #endif
    }

    static func style(_ cell: UITableViewCell) {
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        #if os(iOS)
        guard !hasDynamicColors else { return }
        cell.backgroundColor = cellBackground
        cell.textLabel?.textColor = label
        cell.detailTextLabel?.textColor = secondaryLabel
        #endif
    }

    static func style(headerFooter view: UIView) {
        #if os(iOS)
        guard !hasDynamicColors, let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.textColor = secondaryLabel
        #endif
    }

    /// A navigation controller with the stock bar. Large titles where the OS has them.
    static func navigation(_ root: UIViewController, largeTitles: Bool = true)
        -> UINavigationController {
        let nav = UINavigationController(rootViewController: root)
        style(nav, largeTitles: largeTitles)
        return nav
    }

    static func style(_ nav: UINavigationController, largeTitles: Bool = true) {
        #if os(iOS)
        if #available(iOS 11.0, *) { nav.navigationBar.prefersLargeTitles = largeTitles }
        if !hasDynamicColors {
            nav.navigationBar.barStyle = isDark ? .black : .default
            nav.toolbar.barStyle = isDark ? .black : .default
        }
        #endif
    }

    /// A bar button that carries a vendored Tabler icon, with the label for assistive use.
    static func barItem(icon: String, label: String, target: Any?, action: Selector,
                        identifier: String) -> UIBarButtonItem {
        let item: UIBarButtonItem
        if let image = TablerIcon.image(icon) {
            item = UIBarButtonItem(image: image, style: .plain, target: target, action: action)
        } else {
            item = UIBarButtonItem(title: label, style: .plain, target: target, action: action)
        }
        item.accessibilityLabel = label
        item.accessibilityIdentifier = identifier
        return item
    }

    // MARK: - Buttons

    enum ButtonKind {
        /// The primary action of a screen.
        case filled
        /// A secondary action on a quiet fill.
        case gray
        /// A text-only action.
        case plain
        /// Hang up, remove, reset.
        case destructive
        /// Answer.
        case positive
    }

    /// A system button. iOS 15 and later use `UIButton.Configuration`; earlier systems get the
    /// same shapes from a plain system button. `classic` keeps the plain path on every OS for the
    /// controls an administrator may restyle by semantic ID, because that contract is applied
    /// through the button's own colours, radius and title font.
    static func button(_ kind: ButtonKind, title: String = "", icon: String? = nil,
                       large: Bool = false, classic: Bool = false) -> UIButton {
        let button = UIButton(type: .system)
        style(button, kind: kind, title: title, icon: icon, large: large, classic: classic)
        return button
    }

    static func style(_ button: UIButton, kind: ButtonKind, title: String? = nil,
                      icon: String? = nil, large: Bool = false, classic: Bool = false) {
        let image = icon.flatMap { TablerIcon.image($0) }
        #if os(tvOS)
        if let title = title { button.setTitle(title, for: .normal) }
        if let image = image { button.setImage(image, for: .normal) }
        if kind == .destructive { button.setTitleColor(negative, for: .normal) }
        #else
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        if #available(iOS 15.0, *), !classic {
            var configuration: UIButton.Configuration
            switch kind {
            case .filled, .destructive, .positive: configuration = .filled()
            case .gray: configuration = .gray()
            case .plain: configuration = .plain()
            }
            if kind == .destructive { configuration.baseBackgroundColor = negative }
            if kind == .positive { configuration.baseBackgroundColor = positive }
            configuration.buttonSize = large ? .large : .medium
            configuration.title = title ?? button.configuration?.title
                ?? button.title(for: .normal)
            configuration.image = image ?? button.configuration?.image
            configuration.imagePadding = 8
            configuration.titleAlignment = .center
            let weight: UIFont.Weight = kind == .plain ? .regular : .semibold
            let textStyle: UIFont.TextStyle = large ? .title3 : .body
            configuration.titleTextAttributesTransformer =
                UIConfigurationTextAttributesTransformer { incoming in
                    var outgoing = incoming
                    outgoing.font = SystemStyle.font(textStyle, weight: weight)
                    return outgoing
                }
            button.configuration = configuration
            return
        }
        if let title = title { button.setTitle(title, for: .normal) }
        if let image = image { button.setImage(image, for: .normal) }
        button.titleLabel?.font = font(large ? .title3 : .body,
                                       weight: kind == .plain ? .regular : .semibold)
        followContentSize(button.titleLabel)
        button.layer.cornerRadius = large ? 14 : 10
        let vertical: CGFloat = large ? 14 : 8
        let horizontal: CGFloat = large ? 20 : 14
        button.contentEdgeInsets = UIEdgeInsets(top: vertical, left: horizontal,
                                                bottom: vertical, right: horizontal)
        paintClassic(button, kind: kind)
        #endif
    }

    /// The colours of a classic button. Called again when the static palette moves.
    static func paintClassic(_ button: UIButton, kind: ButtonKind) {
        #if !os(tvOS)
        switch kind {
        case .filled:
            button.backgroundColor = tint
            button.setTitleColor(DoorbellTheme.readableInk(on: tint), for: .normal)
            button.tintColor = DoorbellTheme.readableInk(on: tint)
        case .positive:
            button.backgroundColor = positive
            button.setTitleColor(.white, for: .normal)
            button.tintColor = .white
        case .destructive:
            button.backgroundColor = negative
            button.setTitleColor(.white, for: .normal)
            button.tintColor = .white
        case .gray:
            button.backgroundColor = fill
            button.setTitleColor(tint, for: .normal)
            button.tintColor = tint
        case .plain:
            button.backgroundColor = .clear
            button.setTitleColor(tint, for: .normal)
            button.tintColor = tint
        }
        #endif
    }

    // MARK: - Materials

    /// Content laid over the household wallpaper sits on the system material where the OS has
    /// one (iOS 13 and later, tvOS) and on the grouped cell colour before that.
    static func materialEffect() -> UIVisualEffect? {
        #if os(tvOS)
        return UIBlurEffect(style: .regular)
        #else
        if #available(iOS 13.0, *) { return UIBlurEffect(style: .systemMaterial) }
        return nil
        #endif
    }
}

/// A rounded card on the system material (see `SystemStyle.materialEffect`). Subviews go in
/// `contentView`.
final class MaterialCardView: UIView {
    private let effectView = UIVisualEffectView(effect: SystemStyle.materialEffect())
    var contentView: UIView { return effectView.contentView }

    init(cornerRadius: CGFloat = 12) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = cornerRadius
        if #available(iOS 13.0, tvOS 13.0, *) { layer.cornerCurve = .continuous }
        clipsToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Repaints the solid fallback fill; a no-op where the material is drawn.
    func refresh() {
        if effectView.effect == nil { effectView.backgroundColor = SystemStyle.cellBackground }
    }
}
