import UIKit

/// Light/dark appearance, the ink and accent colours that go with it, and the small shared
/// drawing rules every batch-2 surface follows: padded coloured labels, deliberate two-part
/// labels, and one version/battery footer line.
///
/// Core publishes `display.theme.auto_ink` and `display.theme.auto_accent` so every shell agrees
/// on the same computed colours. When those fields are absent — an older Core, or a background
/// the node has not measured yet — the same arithmetic runs locally, which is why the maths lives
/// here rather than behind a Core call.
enum DoorbellAppearance: String {
    case light
    case dark
}

struct DoorbellPalette {
    let appearance: DoorbellAppearance
    let background: UIColor
    let surface: UIColor
    let surfaceStrong: UIColor
    let ink: UIColor
    let inkMuted: UIColor
    let accent: UIColor
    let onAccent: UIColor
    let notice: UIColor
    let danger: UIColor
    let separator: UIColor

    static let dark = DoorbellPalette(
        appearance: .dark,
        background: UIColor(red: 0.063, green: 0.078, blue: 0.094, alpha: 1),
        surface: UIColor(white: 1, alpha: 0.10),
        surfaceStrong: UIColor(white: 1, alpha: 0.16),
        ink: UIColor(white: 0.94, alpha: 1),
        inkMuted: UIColor(white: 0.66, alpha: 1),
        accent: UIColor(red: 1.0, green: 0.80, blue: 0.25, alpha: 1),
        onAccent: .black,
        notice: UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1),
        danger: UIColor(red: 0.88, green: 0.36, blue: 0.30, alpha: 1),
        separator: UIColor(white: 1, alpha: 0.12))

    static let light = DoorbellPalette(
        appearance: .light,
        background: UIColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1),
        surface: UIColor(white: 0, alpha: 0.06),
        surfaceStrong: UIColor(white: 0, alpha: 0.10),
        ink: UIColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1),
        inkMuted: UIColor(red: 0.36, green: 0.38, blue: 0.41, alpha: 1),
        accent: UIColor(red: 0.16, green: 0.33, blue: 0.72, alpha: 1),
        onAccent: .white,
        notice: UIColor(red: 0.13, green: 0.36, blue: 0.60, alpha: 1),
        danger: UIColor(red: 0.72, green: 0.16, blue: 0.13, alpha: 1),
        separator: UIColor(white: 0, alpha: 0.14))

    static func of(_ appearance: DoorbellAppearance) -> DoorbellPalette {
        return appearance == .light ? .light : .dark
    }

    /// `surface` and `surfaceStrong` are translucent so a card tints whatever it lies on. That is
    /// only correct while the screen behind them is this palette's own background. A card on the
    /// theme picture has to be opaque, or the picture shows through and the palette ink the card
    /// carries stops being the readable one. Compositing the overlay over the palette background
    /// gives exactly the colour a panel without a theme picture already shows.
    var surfaceSolid: UIColor { return DoorbellTheme.solid(surface, over: background) }
    var surfaceStrongSolid: UIColor {
        return DoorbellTheme.solid(surfaceStrong, over: background)
    }
}

/// Everything one screen needs to paint itself: the palette that owns every surface the shell
/// draws, and the background the shell has painted under it.
///
/// The split matters because the two can disagree. `display.theme` is a cluster-wide decoration —
/// the owner's picture or colour — while light/dark is a per-device appearance. A dark picture
/// under a light palette is normal, and §5's automatic contrast is what keeps the bare text
/// (clock, date, hint, footer) readable on it. Cards, chips, sheets and dialogs are layered on top
/// and stay in the palette, because the shell painted them and knows what is behind their text.
struct DoorbellSkin {

    let palette: DoorbellPalette
    let display: [String: Any]?
    /// The colour a bare text region actually sits on: the theme colour, or the average of the
    /// theme picture. Core measures it once for the cluster; the shell measures locally when the
    /// contract is absent.
    let background: UIColor
    /// True while a configured theme colour or picture is painted under this screen. Core's
    /// automatic ink describes that background, so it is only meaningful when it is showing.
    let decorated: Bool

    /// A screen with no theme decoration: every region falls back to the palette.
    static func plain(_ palette: DoorbellPalette) -> DoorbellSkin {
        return DoorbellSkin(palette: palette, display: nil, background: palette.background,
                            decorated: false)
    }

    // MARK: - Text drawn straight on the background

    /// Ink for one of the semantic regions Core publishes (`clock`, `date`, `status_line`,
    /// `hint`, `tile_label`, `footer`, `notice`).
    func ink(_ region: String) -> UIColor {
        if let override = DoorbellTheme.inkOverride(display: display, region: region) {
            return override
        }
        guard decorated else { return palette.ink }
        return DoorbellTheme.ink(display: display, region: region, background: background,
                                 palette: palette)
    }

    /// The quiet variant of a region's ink. Over a decoration it is the same ink moved towards
    /// the background rather than made translucent, so it keeps a known contrast ratio.
    func muted(_ region: String) -> UIColor {
        guard decorated else {
            return DoorbellTheme.inkOverride(display: display, region: region)
                .map { DoorbellTheme.solid($0.withAlphaComponent(0.74), over: background) }
                ?? palette.inkMuted
        }
        return DoorbellTheme.solid(ink(region).withAlphaComponent(0.74), over: background)
    }

    func apply(_ region: String, to label: UILabel, quiet: Bool = false) {
        DoorbellTheme.applyInk(quiet ? muted(region) : ink(region), over: background, to: label)
    }

    // MARK: - Text on a card this shell painted

    /// A card is a palette surface, so the palette's own ink is the readable one there. An
    /// administrator's per-region override still wins, because it is a deliberate choice.
    func cardInk(_ region: String) -> UIColor {
        return DoorbellTheme.inkOverride(display: display, region: region) ?? palette.ink
    }

    func cardMuted(_ region: String) -> UIColor {
        guard let override = DoorbellTheme.inkOverride(display: display, region: region) else {
            return palette.inkMuted
        }
        return DoorbellTheme.solid(override.withAlphaComponent(0.74), over: surface)
    }

    /// Card and chip fills. Opaque, so the theme picture never leaks through the text on them.
    var surface: UIColor { return palette.surfaceSolid }
    var surfaceStrong: UIColor { return palette.surfaceStrongSolid }
}

/// The household's theme background as one screen paints it: a colour on the host view with the
/// configured picture over it, plus the skin that says what text drawn on that ought to look like.
///
/// Every full-screen surface owns one — both home screens, the incoming screen, the monitor page —
/// so no two of them can end up disagreeing about what is behind their text.
final class ThemeBackgroundView: UIImageView {

    /// Called once a picture has arrived, so the screen can repaint text against it.
    var onImageLoaded: (() -> Void)?

    private var loadedHash: String?
    private var paintedColor: String?

    init() {
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Core resolves `display.theme` with this device's own override and republishes the result,
    /// so the contract is the first place to look; configuration is the fallback for a Core that
    /// predates it.
    private static func value(_ leaf: String, display: [String: Any]?, config: [String: Any]?,
                              nodeId: String) -> String? {
        if let v = ConfigUtil.str(display, "theme.\(leaf)"), !v.isEmpty { return v }
        if !nodeId.isEmpty,
           let v = ConfigUtil.str(config, "devices.\(nodeId).local.theme.\(leaf)"), !v.isEmpty {
            return v
        }
        let v = ConfigUtil.str(config, "display.theme.\(leaf)")
        return (v?.isEmpty == false) ? v : nil
    }

    @discardableResult
    func apply(display: [String: Any]?, config: [String: Any]?, nodeId: String,
               palette: DoorbellPalette, httpPort: Int, host: UIView) -> DoorbellSkin {
        let color = ThemeBackgroundView.value("bg_color", display: display, config: config,
                                              nodeId: nodeId)
        let key = (color ?? "") + "/" + palette.appearance.rawValue
        if key != paintedColor {
            paintedColor = key
            if let color = color, let rgb = ConfigUtil.parseHexColor(color) {
                host.backgroundColor = UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
            } else {
                host.backgroundColor = palette.background
            }
        }
        let hash = ThemeBackgroundView.value("bg_image", display: display, config: config,
                                             nodeId: nodeId) ?? ""
        if hash.isEmpty {
            loadedHash = nil
            image = nil
            isHidden = true
        } else if hash != loadedHash || image == nil {
            loadedHash = hash
            DoorbellTheme.loadBackgroundImage(
                hash: hash, path: ConfigUtil.str(display, "theme.bg_image_path"),
                httpPort: httpPort) { [weak self] picture in
                    guard let self = self, self.loadedHash == hash else { return }
                    self.image = picture
                    self.isHidden = false
                    self.onImageLoaded?()
                }
        }
        return skin(display: display, palette: palette, host: host, decorated: color != nil)
    }

    /// Drops the picture under memory pressure. The colour stays: a screen still has to have one.
    func releaseImage() {
        loadedHash = nil
        image = nil
        isHidden = true
    }

    private func skin(display: [String: Any]?, palette: DoorbellPalette, host: UIView,
                      decorated: Bool) -> DoorbellSkin {
        var background = host.backgroundColor ?? palette.background
        // Core measures the served theme, image included, so every shell agrees on one answer.
        if let published = DoorbellTheme.publishedBackground(display: display) {
            background = published
        } else if !isHidden, let picture = image,
                  let average = DoorbellTheme.averageColor(of: picture) {
            background = average
        }
        return DoorbellSkin(palette: palette, display: display, background: background,
                            decorated: decorated || !isHidden)
    }
}

enum DoorbellTheme {

    static let changed = Notification.Name("DoorbellThemeChanged")

    // MARK: - Appearance resolution

    /// Core resolves the appearance for the whole cluster and publishes it in the display
    /// contract; the shell only decides whether to follow the operating system when Core says it
    /// may. The configuration path below is the fallback for a Core that predates the contract.
    static func appearance(display: [String: Any]?, config: [String: Any]?, nodeId: String,
                           localTime: [String: Any]?) -> DoorbellAppearance {
        if let effective = ConfigUtil.str(display, "appearance.effective") {
            let resolved: DoorbellAppearance = effective == "light" ? .light : .dark
            guard ConfigUtil.bool(display, "appearance.follow_system", false) else {
                return resolved
            }
            return systemAppearance() ?? resolved
        }
        return appearance(config: config, nodeId: nodeId, localTime: localTime)
    }

    /// The operating system's own light/dark setting, or nil on a runtime that has none.
    static func systemAppearance() -> DoorbellAppearance? {
        if #available(iOS 13.0, tvOS 13.0, *) {
            let style = UITraitCollection.current.userInterfaceStyle
            if style == .dark { return .dark }
            if style == .light { return .light }
        }
        return nil
    }

    /// Resolves `display.appearance` (with the per-device override) into a concrete appearance.
    /// `auto_system` needs a system dark mode; on a runtime that has none it degrades to the
    /// schedule, exactly like the iPad 1 kiosk and old Android shells do.
    static func appearance(config: [String: Any]?, nodeId: String,
                           localTime: [String: Any]?) -> DoorbellAppearance {
        var mode = ConfigUtil.str(config, "display.appearance") ?? "auto_system"
        if !nodeId.isEmpty,
           let override = ConfigUtil.str(config, "devices.\(nodeId).local.display.appearance") {
            mode = override
        }
        switch mode {
        case "light": return .light
        case "dark": return .dark
        case "auto_schedule": return scheduled(config: config, localTime: localTime)
        default:
            return systemAppearance() ?? scheduled(config: config, localTime: localTime)
        }
    }

    private static func scheduled(config: [String: Any]?,
                                  localTime: [String: Any]?) -> DoorbellAppearance {
        let darkFrom = minutes(ConfigUtil.str(config, "display.appearance_schedule.dark_from")
            ?? "19:00") ?? 19 * 60
        let lightFrom = minutes(ConfigUtil.str(config, "display.appearance_schedule.light_from")
            ?? "06:30") ?? 6 * 60 + 30
        let hh = ConfigUtil.int(localTime, "hh", -1)
        guard hh >= 0 else { return .dark }
        let now = hh * 60 + ConfigUtil.int(localTime, "mm", 0)
        if darkFrom == lightFrom { return .dark }
        if darkFrom < lightFrom {
            return (now >= darkFrom && now < lightFrom) ? .dark : .light
        }
        return (now >= darkFrom || now < lightFrom) ? .dark : .light
    }

    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    // MARK: - Colour arithmetic (WCAG 2.x relative luminance)

    static func color(hex: String?) -> UIColor? {
        guard let hex = hex, let rgb = ConfigUtil.parseHexColor(hex) else { return nil }
        return UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

    static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
        let clamp = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", clamp(r), clamp(g), clamp(b))
    }

    static func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        func linear(_ v: CGFloat) -> CGFloat {
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// Flattens a translucent colour onto an opaque one. Used wherever a surface that used to
    /// tint the screen behind it now has to be a colour of its own.
    static func solid(_ overlay: UIColor, over base: UIColor) -> UIColor {
        var or: CGFloat = 0, og: CGFloat = 0, ob: CGFloat = 0, oa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        guard overlay.getRed(&or, green: &og, blue: &ob, alpha: &oa),
              base.getRed(&br, green: &bg, blue: &bb, alpha: &ba) else { return overlay }
        return UIColor(red: or * oa + br * (1 - oa), green: og * oa + bg * (1 - oa),
                       blue: ob * oa + bb * (1 - oa), alpha: 1)
    }

    static func contrast(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Average colour of an image region, used when the theme background is a picture. The area is
    /// reduced to at most 16x16 before averaging, as the cross-platform rule requires.
    static func averageColor(of image: UIImage, in rect: CGRect? = nil) -> UIColor? {
        guard let cg = image.cgImage else { return nil }
        let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let area = (rect.map { full.intersection($0) } ?? full).integral
        guard area.width >= 1, area.height >= 1,
              let cropped = cg.cropping(to: area) else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0, g = 0, b = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            r += Int(pixels[index]); g += Int(pixels[index + 1]); b += Int(pixels[index + 2])
        }
        let count = CGFloat(side * side)
        return UIColor(red: CGFloat(r) / 255 / count, green: CGFloat(g) / 255 / count,
                       blue: CGFloat(b) / 255 / count, alpha: 1)
    }

    /// Ink for one semantic text region. Core publishes the administrator's overrides and the
    /// automatic decision in the display contract; without them the same luminance rule runs
    /// locally, so an older Core still produces legible text.
    /// The colour an administrator pinned for one region, if any. Core republishes the overrides
    /// it validated, so the shell reads them from the display contract rather than configuration.
    static func inkOverride(display: [String: Any]?, region: String) -> UIColor? {
        return color(hex: ConfigUtil.str(display, "theme.ink_override.\(region)"))
    }

    static func ink(display: [String: Any]?, region: String, background: UIColor,
                    palette: DoorbellPalette) -> UIColor {
        if let override = inkOverride(display: display, region: region) {
            return override
        }
        if let published = ConfigUtil.str(display, "theme.auto_ink.\(region)") {
            if published == "dark" { return DoorbellPalette.light.ink }
            if published == "light" { return DoorbellPalette.dark.ink }
        }
        return luminance(background) >= 0.5 ? DoorbellPalette.light.ink : DoorbellPalette.dark.ink
    }

    /// The background a text region actually sits on, as Core measured it (an image is averaged
    /// there); nil when the contract is absent and the shell must measure locally.
    static func publishedBackground(display: [String: Any]?) -> UIColor? {
        return color(hex: ConfigUtil.str(display, "theme.auto_background.color"))
    }

    /// A one-pixel outline is added only when the chosen ink still misses AA against the region
    /// background; it uses the opposite ink at 40 %.
    static func applyInk(_ ink: UIColor, over background: UIColor, to label: UILabel) {
        label.textColor = ink
        guard contrast(ink, background) < 4.5 else {
            label.shadowColor = nil
            label.shadowOffset = .zero
            return
        }
        let opposite = luminance(ink) >= 0.5 ? UIColor.black : UIColor.white
        label.shadowColor = opposite.withAlphaComponent(0.4)
        label.shadowOffset = CGSize(width: 0, height: 1)
    }

    /// Call-button colour for a door station: the complement of the effective background, moved in
    /// lightness until the button separates from the background (3:1) and its text is readable
    /// (4.5:1). Dark directions are tried first on a light background.
    static func autoAccent(on background: UIColor) -> (fill: UIColor, ink: UIColor) {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        if !background.getHue(&hue, saturation: &saturation, brightness: &brightness,
                              alpha: &alpha) {
            return (DoorbellPalette.dark.accent, .black)
        }
        let rotated = hue + 0.5 > 1 ? hue - 0.5 : hue + 0.5
        let saturated = max(0.45, min(1, saturation + 0.25))
        let backgroundIsLight = luminance(background) >= 0.5
        let order: [CGFloat] = backgroundIsLight
            ? [0.18, 0.24, 0.30, 0.38, 0.46, 0.60, 0.74, 0.88]
            : [0.88, 0.80, 0.72, 0.62, 0.52, 0.40, 0.30, 0.20]
        var best = UIColor(hue: rotated, saturation: saturated, brightness: order[0], alpha: 1)
        var bestScore: CGFloat = -1
        for level in order {
            let candidate = UIColor(hue: rotated, saturation: saturated, brightness: level,
                                    alpha: 1)
            let ink = readableInk(on: candidate)
            let separation = contrast(candidate, background)
            let legibility = contrast(ink, candidate)
            if separation >= 3 && legibility >= 4.5 {
                return (candidate, ink)
            }
            let score = min(separation / 3, 1) + min(legibility / 4.5, 1)
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return (best, readableInk(on: best))
    }

    static func readableInk(on background: UIColor) -> UIColor {
        return contrast(.black, background) >= contrast(.white, background) ? .black : .white
    }

    /// The call button as Core resolved it: `call_button_bg` already has the administrator's
    /// override applied, and the text colour must come from `call_button_ink` — on a mid-luminance
    /// background no colour both separates and carries white text, and Core returns the best
    /// compromise rather than an unreadable button. Without the contract the same arithmetic runs
    /// locally.
    static func callButtonColors(display: [String: Any]?,
                                 background: UIColor) -> (fill: UIColor, ink: UIColor) {
        if let fill = color(hex: ConfigUtil.str(display, "theme.call_button_bg")) {
            let published = ConfigUtil.str(display, "theme.call_button_ink")
                ?? ConfigUtil.str(display, "theme.auto_accent.call_button_ink")
            if let published = published {
                return (fill, published == "dark" ? DoorbellPalette.light.ink
                    : DoorbellPalette.dark.ink)
            }
            return (fill, readableInk(on: fill))
        }
        return autoAccent(on: background)
    }

    /// Soft WCAG advice for a colour an administrator typed. Nil means the pair passes; the string
    /// is the localized warning, and the value is never rejected.
    static func contrastWarning(_ texts: Texts, foreground: UIColor, background: UIColor,
                                largeText: Bool = false) -> String? {
        let ratio = contrast(foreground, background)
        let needed: CGFloat = largeText ? 3.0 : 4.5
        guard ratio < needed else { return nil }
        return texts.t("theme.contrast_warning", String(format: "%.1f", Double(ratio)))
    }

    // MARK: - Shared drawing rules

    /// Every coloured-background text gets 6pt vertical / 12pt horizontal padding and a radius.
    static func pill(_ label: PaddedLabel, background: UIColor, ink: UIColor,
                     fontSize: CGFloat = 16, bold: Bool = true) {
        label.insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        label.backgroundColor = background
        label.textColor = ink
        label.font = bold ? .systemFont(ofSize: fontSize, weight: .semibold)
            : .systemFont(ofSize: fontSize)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.numberOfLines = 0
    }

    /// Deliberate two-part label: the text carries "\n", and the second line renders smaller and
    /// muted rather than wrapping mid-phrase.
    static func twoPart(_ text: String, primarySize: CGFloat, color: UIColor,
                        bold: Bool = true) -> NSAttributedString {
        let parts = text.components(separatedBy: "\n")
        let primaryFont: UIFont = bold ? .systemFont(ofSize: primarySize, weight: .semibold)
            : .systemFont(ofSize: primarySize)
        let result = NSMutableAttributedString(
            string: parts[0],
            attributes: [.font: primaryFont, .foregroundColor: color])
        guard parts.count > 1 else { return result }
        let secondary = parts.dropFirst().joined(separator: " ")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        result.addAttributes([.paragraphStyle: paragraph],
                             range: NSRange(location: 0, length: result.length))
        result.append(NSAttributedString(
            string: "\n" + secondary,
            attributes: [.font: UIFont.systemFont(ofSize: primarySize * 0.8),
                         .foregroundColor: color.withAlphaComponent(0.72),
                         .paragraphStyle: paragraph]))
        return result
    }

    /// Loads the theme picture Core named. Core publishes the cached file's path next to the
    /// hash, so a panel that already holds the asset never goes near the network; the node's own
    /// asset endpoint is the fallback while the file is still arriving. `completion` runs on the
    /// main queue, and only with an image.
    static func loadBackgroundImage(hash: String, path: String?, httpPort: Int,
                                    completion: @escaping (UIImage) -> Void) {
        if let path = path, !path.isEmpty, let image = UIImage(contentsOfFile: path) {
            completion(image)
            return
        }
        guard let url = URL(string: "http://127.0.0.1:\(httpPort)/asset/\(hash)") else { return }
        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let data = data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { return }
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }

    /// Renders an authored two-part label on a button. The break in the string is the only place
    /// the text ever wraps, and the second line is smaller and quieter — a label that carries one
    /// part renders as that one part. Every control that can outgrow its box goes through here
    /// instead of shrinking a phrase to fit, which is what the deliberate-line-break rule asks
    /// for. tvOS gets the same attributed title for the focused state, because the focus engine
    /// would otherwise repaint a plain title and lose the split.
    static func twoPartTitle(_ text: String, on button: UIButton, primarySize: CGFloat,
                             color: UIColor, focusColor: UIColor? = nil, bold: Bool = true) {
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.titleLabel?.adjustsFontSizeToFitWidth = false
        // Assigning an identical title would still invalidate the button's intrinsic size, and
        // this runs from `viewDidLayoutSubviews` on the incoming screen; comparing first keeps a
        // re-render from starting another layout pass.
        let attributed = twoPart(text, primarySize: primarySize, color: color, bold: bold)
        if button.attributedTitle(for: .normal)?.isEqual(to: attributed) != true {
            button.setTitle(nil, for: .normal)
            button.setAttributedTitle(attributed, for: .normal)
        }
        #if os(tvOS)
        let focused = twoPart(text, primarySize: primarySize, color: focusColor ?? color,
                              bold: bold)
        if button.attributedTitle(for: .focused)?.isEqual(to: focused) != true {
            button.setAttributedTitle(focused, for: .focused)
        }
        #endif
        button.accessibilityLabel = text.replacingOccurrences(of: "\n", with: " ")
    }

    /// Footer identity line: `name · core vX · app vY · battery`. The battery part disappears on a
    /// device that reports none, and a charging device is marked.
    static func versionLine(name: String, coreVersion: String, texts: Texts,
                            power: [String: Any]?) -> String {
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }
        parts.append("core v" + (coreVersion.isEmpty ? "-" : coreVersion))
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "-"
        parts.append("app v" + app)
        let percent = ConfigUtil.int(power, "battery_pct", -1)
        if percent >= 0 {
            var battery = "\(percent)%"
            if ConfigUtil.bool(power, "charging", false) {
                battery += " " + texts.t("power.charging")
            }
            parts.append(battery)
        }
        return parts.joined(separator: " · ")
    }

    static func coreVersion() -> String {
        guard let raw = db_core_version() else { return "" }
        return String(cString: raw)
    }
}
