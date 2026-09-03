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

/// A label that can carry §5's halo.
///
/// The outline is drawn by the label, not applied to it. Two other places were tried first and
/// both failed on the panel: `UILabel.shadowColor` has no blur at all, and a CALayer shadow set on
/// the label's own layer renders essentially nothing around glyphs — a rendered probe of it found
/// 39 lit pixels where a halo needs hundreds. Drawing it in `drawText` also means it survives the
/// label rewriting its own text, which the clock does once a second and which an attributed
/// `NSShadow` would not.
final class HaloLabel: UILabel {

    /// The halo colour, already carrying its opacity, or nil for none.
    var halo: UIColor? {
        didSet {
            guard halo != oldValue else { return }
            setNeedsDisplay()
        }
    }

    override func drawText(in rect: CGRect) {
        guard let halo = halo, let context = UIGraphicsGetCurrentContext() else {
            super.drawText(in: rect)
            return
        }
        // A soft blur on its own was measured at roughly a hundred lit pixels around a 64 pt
        // glyph — visible in a screenshot, not enough to read against a photograph. The halo is
        // therefore a stroked outline with the blur behind it: the stroke gives every glyph a
        // hard edge of its own, the blur settles that edge into the picture. The fill is drawn
        // afterwards so the ink itself is never touched by either.
        context.saveGState()
        context.setShadow(offset: .zero, blur: DoorbellTheme.outlineBlurRadius,
                          color: halo.cgColor)
        context.setLineWidth(DoorbellTheme.outlineStroke(forPointSize: font.pointSize))
        context.setLineJoin(.round)
        context.setStrokeColor(halo.cgColor)
        context.setTextDrawingMode(.stroke)
        super.drawText(in: rect)
        super.drawText(in: rect)
        context.restoreGState()
    }
}

/// Where one region's ink came from. Every batch-2 shell names the same four sources, so a panel
/// that came back with white text over a light picture is diagnosed the same way everywhere.
enum InkSource: String {
    /// An administrator pinned this colour for the region.
    case admin
    /// Core's per-region `auto_ink`, which is exact over a flat theme colour.
    case core
    /// Measured here, on the part of the theme picture this region actually covers.
    case localRegion = "local_region"
    /// The same contrast rule, against whatever ground the caller could name.
    case local
}

/// What the shell measured under one text region: the average colour, which chooses the ink, and
/// the darkest and lightest patch of the same ≤16x16 sample, which decide whether that ink still
/// needs its outline. A hint line crossing a pale wall and a dark jacket averages to something the
/// light ink clears comfortably and then vanishes over the jacket.
struct BackgroundSample {
    let average: UIColor
    let minLuminance: CGFloat
    let maxLuminance: CGFloat

    /// A ground with no variation in it: a flat theme colour, or the palette's own background.
    static func uniform(_ color: UIColor) -> BackgroundSample {
        let level = DoorbellTheme.luminance(color)
        return BackgroundSample(average: color, minLuminance: level, maxLuminance: level)
    }

    /// The worst contrast an ink reaches anywhere in the region. Contrast falls away on both
    /// sides of the ink's own luminance, so the worst patch is always one of the two extremes.
    func worstContrast(_ ink: UIColor) -> CGFloat {
        let level = DoorbellTheme.luminance(ink)
        return min(DoorbellTheme.ratio(level, minLuminance),
                   DoorbellTheme.ratio(level, maxLuminance))
    }
}

/// The ground one text region sits on, and how much this shell knows about it. The three cases
/// are §5's precedence: only a picture the shell drew and sampled under the region displaces
/// Core's published per-region ink.
enum InkGround {
    /// No theme decoration at all: the palette owns the screen.
    case palette(UIColor)
    /// A flat theme colour. Core measured exactly this, so its per-region ink is authoritative.
    case themeColor(UIColor)
    /// The theme picture this shell drew, measured under the region.
    case sampled(BackgroundSample)

    /// The colour the ink is chosen against.
    var color: UIColor {
        switch self {
        case .palette(let color), .themeColor(let color): return color
        case .sampled(let sample): return sample.average
        }
    }

    /// The worst contrast an ink reaches anywhere on this ground. A flat colour has only itself;
    /// a sampled picture answers for its darkest and lightest patch.
    func worstContrast(_ ink: UIColor) -> CGFloat {
        switch self {
        case .palette(let color), .themeColor(let color):
            return DoorbellTheme.contrast(ink, color)
        case .sampled(let sample):
            return sample.worstContrast(ink)
        }
    }
}

/// The ink one text region is drawn in, the ground it was measured against, and the outline it
/// still needs when even the better ink misses the 4.5:1 body-text target.
struct InkDecision {
    let ink: UIColor
    let background: UIColor
    let source: InkSource
    /// The 40 % opposite-ink shadow, or nil when the pair already reaches AA on its own.
    let shadow: UIColor?
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
    /// The colour a bare text region sits on when nothing narrower is known: the theme colour, or
    /// the average of the whole theme picture.
    let background: UIColor
    /// True while a configured theme colour or picture is painted under this screen. Core's
    /// automatic ink describes that background, so it is only meaningful when it is showing.
    let decorated: Bool
    /// Configuration and this device's identity, so an `ink_override` a Core that predates the
    /// display contract never republishes is still honoured.
    var config: [String: Any]?
    var nodeId: String = ""
    /// The view drawing the theme picture, while one is drawn. Core computes `auto_ink` from the
    /// whole picture because it has no layout geometry; this shell has it, which is why §5 leaves
    /// the per-region refinement here.
    weak var sampler: ThemeBackgroundView?

    /// A screen with no theme decoration: every region falls back to the palette.
    static func plain(_ palette: DoorbellPalette) -> DoorbellSkin {
        return DoorbellSkin(palette: palette, display: nil, background: palette.background,
                            decorated: false)
    }

    // MARK: - Text drawn straight on the background

    /// Ink for one of the semantic regions Core publishes (`clock`, `date`, `status_line`,
    /// `hint`, `tile_label`, `footer`, `notice`).
    func ink(_ region: String) -> UIColor {
        return decision(region, in: nil).ink
    }

    /// The full decision for one region. `rect`, in the background view's own coordinates, is the
    /// area the text covers; nil measures the whole ground.
    func decision(_ region: String, in rect: CGRect?) -> InkDecision {
        return decision(region, on: ground(in: rect))
    }

    private func decision(_ region: String, on ground: InkGround) -> InkDecision {
        return DoorbellTheme.decideInk(display: display, config: config, nodeId: nodeId,
                                       region: region, ground: ground, palette: palette)
    }

    /// A picture on screen is the ground, whatever Core managed to measure of it: Core holds one
    /// average for the whole picture, and on a picture it declined to sample it holds nothing
    /// that describes the screen at all.
    private func ground(in rect: CGRect?) -> InkGround {
        guard let sampler = sampler, sampler.drawsImage else {
            return decorated ? .themeColor(background) : .palette(background)
        }
        return .sampled(sampler.sample(in: rect) ?? .uniform(background))
    }

    /// The quiet variant of a region's ink. Over a decoration it is the same ink moved towards
    /// the background rather than made translucent, so it keeps a known contrast ratio.
    func muted(_ region: String) -> UIColor {
        return muted(region, in: nil)
    }

    func muted(_ region: String, in rect: CGRect?) -> UIColor {
        let ground = self.ground(in: rect)
        return muted(decision(region, on: ground), on: ground)
    }

    private func muted(_ decision: InkDecision, on ground: InkGround) -> UIColor {
        if case .palette = ground, decision.source != .admin {
            return palette.inkMuted
        }
        return DoorbellTheme.solid(decision.ink.withAlphaComponent(0.74),
                                   over: decision.background)
    }

    /// Paints one label and, over a theme picture, keeps painting it: a region's ink depends on
    /// the part of the picture the label ends up covering, which is not known until layout has
    /// settled and changes again when the picture or the viewport does.
    func apply(_ region: String, to label: UILabel, quiet: Bool = false) {
        sampler?.inkLater(label, region: region, quiet: quiet, skin: self)
        paint(region, to: label, quiet: quiet)
    }

    /// Paints one label from the geometry it has right now. The outline is decided against the
    /// colour actually painted, quiet variant included, and against the whole ground rather than
    /// its average.
    func paint(_ region: String, to label: UILabel, quiet: Bool) {
        let rect = sampler?.regionRect(of: label)
        let ground = self.ground(in: rect)
        let decision = self.decision(region, on: ground)
        DoorbellTheme.applyInk(quiet ? muted(decision, on: ground) : decision.ink, over: ground,
                               to: label)
        logSample(region, rect: rect, ground: ground, decision: decision)
    }

    /// What the region was actually measured on. Off unless `boot.json` asks for timings — this
    /// is the line that says whether a halo is missing because the sample was wrong or because
    /// the ink genuinely cleared 4.5:1.
    private func logSample(_ region: String, rect: CGRect?, ground: InkGround,
                           decision: InkDecision) {
        guard IOSAvailability.PerfProbe.enabled else { return }
        var detail = "ink." + region
        if let rect = rect {
            detail += String(format: " rect=%.0f,%.0f %.0fx%.0f", rect.minX, rect.minY,
                             rect.width, rect.height)
        } else {
            detail += " rect=none"
        }
        if case .sampled(let sample) = ground {
            detail += String(format: " y[min=%.3f max=%.3f avg=%.3f] worst=%.2f",
                             Double(sample.minLuminance), Double(sample.maxLuminance),
                             Double(DoorbellTheme.luminance(sample.average)),
                             Double(ground.worstContrast(decision.ink)))
        } else {
            detail += " flat"
        }
        detail += " ink=" + DoorbellTheme.hex(decision.ink)
            + " src=" + decision.source.rawValue
            + " halo=" + (decision.shadow == nil ? "no" : "yes")
        IOSAvailability.logDebug(detail)
    }

    // MARK: - Text on a card this shell painted

    /// A card is a palette surface, so the palette's own ink is the readable one there. An
    /// administrator's per-region override still wins, because it is a deliberate choice.
    func cardInk(_ region: String) -> UIColor {
        return DoorbellTheme.inkOverride(display: display, config: config, nodeId: nodeId,
                                         region: region) ?? palette.ink
    }

    func cardMuted(_ region: String) -> UIColor {
        guard let override = DoorbellTheme.inkOverride(display: display, config: config,
                                                       nodeId: nodeId, region: region) else {
            return palette.inkMuted
        }
        return DoorbellTheme.solid(override.withAlphaComponent(0.74), over: surface)
    }

    /// Card and chip fills. Opaque, so the theme picture never leaks through the text on them.
    var surface: UIColor { return palette.surfaceSolid }
    var surfaceStrong: UIColor { return palette.surfaceStrongSolid }
}

/// The darkening laid over the theme picture, as an administrator configured it.
///
/// A wallpaper behind text is unreadable however carefully the ink is chosen, so every shell lays
/// a scrim over the picture before anything is drawn on it. What that scrim is made of is now an
/// administrator's decision rather than a constant: Core resolves `display.theme.backdrop` for the
/// cluster with this device's `devices.<id>.local.theme.backdrop` override and republishes the
/// result, and the shell draws whatever comes back.
///
/// The defaults are the values the shells shipped with, so a Core that predates the contract — or
/// a cluster that has never touched the setting — looks exactly as it did.
struct BackdropStyle: Equatable {

    static let defaultColor = "#000000"
    /// Percent. The top of the 55-65 % the readability rule allows: the dashboard is the
    /// text-heaviest screen in the product, with a clock, a call list and two headings sitting
    /// straight on the picture rather than on a card.
    static let defaultOpacity = 62

    var enabled: Bool
    var color: String
    /// Percent, 0...100. Clamped on the way in, because a value out of range is a typo in an
    /// administrator's JSON, not a reason to draw nothing or to draw a wall of black.
    var opacity: Int
    /// Where Core says the resolved values came from. Advisory only: the shell draws what the
    /// numbers say, whatever produced them.
    var source: String

    /// What the shells drew before any of this was configurable.
    static let fallback = BackdropStyle(enabled: true, color: defaultColor,
                                        opacity: defaultOpacity, source: "default")

    /// No scrim at all: the picture as the loader produced it. What an administrator gets by
    /// switching the backdrop off, and what a test that means to measure the picture itself asks
    /// for rather than relying on the default.
    static let off = BackdropStyle(enabled: false, color: defaultColor, opacity: 0,
                                   source: "default")

    var alpha: CGFloat { return CGFloat(min(100, max(0, opacity))) / 100 }

    /// Whether anything is actually painted. A scrim that is off, or fully transparent, is not a
    /// scrim, and the view draws no overlay at all rather than an invisible one.
    var draws: Bool { return enabled && alpha > 0 }

    var uiColor: UIColor {
        let rgb = ConfigUtil.parseHexColor(color)
            ?? ConfigUtil.parseHexColor(BackdropStyle.defaultColor) ?? (r: 0, g: 0, b: 0)
        return UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }

    /// Core's resolved contract first, then this device's own override, then the cluster's, then
    /// the shipped default — the same ladder every other theme leaf is read down, one leaf at a
    /// time so a cluster colour and a device opacity can be set independently.
    static func resolve(display: [String: Any]?, config: [String: Any]?,
                        nodeId: String) -> BackdropStyle {
        var style = BackdropStyle.fallback
        if let raw = leaf("enabled", display: display, config: config, nodeId: nodeId) {
            if let number = raw as? NSNumber { style.enabled = number.boolValue }
        }
        // An unparseable colour keeps the default rather than painting something nobody chose.
        if let raw = leaf("color", display: display, config: config, nodeId: nodeId),
           let text = raw as? String, ConfigUtil.parseHexColor(text) != nil {
            style.color = text
        }
        if let raw = leaf("opacity", display: display, config: config, nodeId: nodeId) {
            let value = (raw as? NSNumber).map { $0.intValue } ?? Int("\(raw)")
            if let value = value { style.opacity = min(100, max(0, value)) }
        }
        if let raw = leaf("source", display: display, config: config, nodeId: nodeId),
           let text = raw as? String, !text.isEmpty {
            style.source = text
        }
        return style
    }

    private static func leaf(_ name: String, display: [String: Any]?, config: [String: Any]?,
                             nodeId: String) -> Any? {
        if let value = ConfigUtil.dig(display, "theme.backdrop.\(name)") { return value }
        if !nodeId.isEmpty,
           let value = ConfigUtil.dig(config, "devices.\(nodeId).local.theme.backdrop.\(name)") {
            return value
        }
        return ConfigUtil.dig(config, "display.theme.backdrop.\(name)")
    }
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

    /// One label registered for automatic re-inking, held weakly: a screen that goes away must
    /// not be kept alive by the background it used to wear.
    private struct InkedRegion {
        weak var label: UILabel?
        let region: String
        let quiet: Bool
    }

    private var inked: [InkedRegion] = []
    private var inkSkin: DoorbellSkin?
    private var inkPassScheduled = false
    private var inkedViewport: CGSize = .zero

    /// The darkening over the picture, as Core resolved it for this device.
    private(set) var backdrop = BackdropStyle.fallback
    /// The scrim itself. A plain view rather than pixels baked into the picture: the compositor
    /// draws it for free, and the picture underneath stays the one the loader produced, so
    /// changing the opacity costs no decode.
    private let scrim = UIView()

    /// The drawn picture reduced to view space, and the factor from view points to its pixels.
    private var proxyImage: CGImage?
    private var proxyKey: String?
    private var proxyScale: CGFloat = 1
    /// Longest side of that proxy. Large enough that a footer band still covers several rows of
    /// it, small enough that building it never touches the full-size photograph twice.
    private static let proxySide: CGFloat = 128

    init() {
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        isHidden = true
        scrim.isUserInteractionEnabled = false
        scrim.isHidden = true
        addSubview(scrim)
        applyBackdropToScrim()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// True while the theme picture is on screen. Core's whole-picture ink is advisory then, and
    /// the local per-region measurement decides.
    var drawsImage: Bool { return !isHidden && image != nil }

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
        setBackdrop(BackdropStyle.resolve(display: display, config: config, nodeId: nodeId))
        let hash = ThemeBackgroundView.value("bg_image", display: display, config: config,
                                             nodeId: nodeId) ?? ""
        if hash.isEmpty {
            loadedHash = nil
            setBackgroundImage(nil)
        } else if hash != loadedHash || image == nil {
            loadedHash = hash
            DoorbellTheme.loadBackgroundImage(
                hash: hash, path: ConfigUtil.str(display, "theme.bg_image_path"),
                httpPort: httpPort) { [weak self] picture in
                    guard let self = self, self.loadedHash == hash else { return }
                    self.setBackgroundImage(picture)
                    self.onImageLoaded?()
                }
        }
        return skin(display: display, config: config, nodeId: nodeId, palette: palette, host: host,
                    decorated: color != nil)
    }

    /// The picture has arrived, or gone. Everything measured from it — the sampling proxy and
    /// every region's ink — is stale from here, and a picture that arrives after the screen was
    /// laid out is exactly the case that leaves light ink over a light photograph if nothing
    /// re-decides. The loader, the theme change and the memory warning all come through here.
    func setBackgroundImage(_ picture: UIImage?) {
        image = picture
        isHidden = picture == nil
        proxyImage = nil
        proxyKey = nil
        applyBackdropToScrim()
        scheduleInkPass()
    }

    /// Takes the resolved darkening. Nothing is re-rendered unless the values actually moved: the
    /// administrator's settings screen republishes the whole display contract on every keystroke,
    /// and rebuilding the sampling proxy for an unchanged scrim would put a decode on the main
    /// thread for nothing.
    func setBackdrop(_ style: BackdropStyle) {
        guard style != backdrop else { return }
        backdrop = style
        proxyImage = nil
        proxyKey = nil
        applyBackdropToScrim()
        scheduleInkPass()
    }

    /// The scrim is drawn only over a picture. There is nothing to darken on a flat theme colour,
    /// and the palette already chose that colour to be readable.
    private func applyBackdropToScrim() {
        scrim.backgroundColor = backdrop.uiColor
        scrim.isHidden = !(backdrop.draws && image != nil)
    }

    /// Drops the picture under memory pressure. The colour stays: a screen still has to have one.
    func releaseImage() {
        loadedHash = nil
        setBackgroundImage(nil)
    }

    /// The ground the whole screen sits on. A picture that is actually drawn is measured here,
    /// whatever Core managed to make of it; Core's colour stands for a flat theme, and for a
    /// picture Core says it sampled.
    private func skin(display: [String: Any]?, config: [String: Any]?, nodeId: String,
                      palette: DoorbellPalette, host: UIView, decorated: Bool) -> DoorbellSkin {
        var background = host.backgroundColor ?? palette.background
        if drawsImage, let sampled = sample(in: nil) {
            background = sampled.average
        } else if let published = DoorbellTheme.publishedBackground(display: display),
                  DoorbellTheme.publishedBackgroundIsGround(display: display) {
            background = published
        }
        return DoorbellSkin(palette: palette, display: display, background: background,
                            decorated: decorated || drawsImage, config: config, nodeId: nodeId,
                            sampler: self)
    }

    // MARK: - Sampling the picture this view draws

    /// One view's rectangle in this view's own coordinates, or nil when there is no picture to
    /// measure it against or the view has no geometry yet.
    func regionRect(of view: UIView) -> CGRect? {
        guard drawsImage, superview != nil, view.superview != nil else { return nil }
        let rect = convert(view.bounds, from: view)
        return (rect.width > 0 && rect.height > 0) ? rect : nil
    }

    /// What lies behind one rectangle of this view, measured on the picture actually drawn.
    /// `rect` is in this view's coordinates; nil measures the whole picture. The area is reduced
    /// to at most 16x16 patches, as the cross-platform rule requires.
    func sample(in rect: CGRect?) -> BackgroundSample? {
        guard drawsImage, let proxy = proxy() else { return nil }
        let area = rect.map {
            CGRect(x: $0.minX * proxy.scale, y: $0.minY * proxy.scale,
                   width: $0.width * proxy.scale, height: $0.height * proxy.scale)
        }
        return DoorbellTheme.sample(of: proxy.image, in: area)
    }

    /// The drawn picture reduced to a small copy in view space: aspect-filled into the same
    /// viewport this view uses, so a rectangle on screen maps onto it by one scale factor and
    /// nothing else — no image orientation to undo, no crop to recompute. Building it once is
    /// what keeps every region sample off a full-size photograph.
    private func proxy() -> (image: CGImage, scale: CGFloat)? {
        guard let picture = image, bounds.width >= 1, bounds.height >= 1 else { return nil }
        // The picture, the viewport and the scrim: change any one of them and what is on screen
        // is different, so the prepared copy has to be built again. Change none of them and this
        // is a dictionary lookup.
        let key = "\(UInt(bitPattern: ObjectIdentifier(picture).hashValue))"
            + "|\(Int(bounds.width))x\(Int(bounds.height))"
            + "|\(backdrop.enabled ? 1 : 0)/\(backdrop.color)/\(backdrop.opacity)"
        if key == proxyKey, let cached = proxyImage { return (cached, proxyScale) }
        let scale = min(1, ThemeBackgroundView.proxySide / max(bounds.width, bounds.height))
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        defer { UIGraphicsEndImageContext() }
        picture.draw(in: DoorbellTheme.aspectFillRect(imageSize: picture.size, viewport: size))
        // The scrim goes into the sampled copy too. Ink is decided from these pixels, and the
        // pixels a resident is looking at are the darkened ones — measuring the bare photograph
        // would put light text over a picture the scrim has already made dark.
        if backdrop.draws {
            backdrop.uiColor.setFill()
            UIRectFillUsingBlendMode(CGRect(origin: .zero, size: size), .normal)
        }
        guard let rendered = UIGraphicsGetImageFromCurrentImageContext()?.cgImage else {
            return nil
        }
        proxyImage = rendered
        proxyKey = key
        proxyScale = scale
        return (rendered, scale)
    }

    // MARK: - Keeping the ink true to the layout

    /// Registers a label so its ink follows the picture under it. Screens hand their labels over
    /// while they are still being laid out, and a region's ink cannot be decided before the label
    /// has a frame.
    func inkLater(_ label: UILabel, region: String, quiet: Bool, skin: DoorbellSkin) {
        inkSkin = skin
        let entry = InkedRegion(label: label, region: region, quiet: quiet)
        if let index = inked.firstIndex(where: { $0.label === label }) {
            inked[index] = entry
        } else {
            inked.append(entry)
        }
        scheduleInkPass()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrim.frame != bounds { scrim.frame = bounds }
        guard bounds.size != inkedViewport else { return }
        inkedViewport = bounds.size
        proxyImage = nil
        proxyKey = nil
        scheduleInkPass()
    }

    /// Repaints on the next turn of the run loop, once the layout pass that prompted this has
    /// finished. Coalesced, so a screen that re-skins several labels still samples once each.
    private func scheduleInkPass() {
        guard !inkPassScheduled else { return }
        inkPassScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.inkPassScheduled = false
            self.repaintInk()
        }
    }

    private func repaintInk() {
        guard let skin = inkSkin else { return }
        // A label's frame is only true after the pending layout pass has run. Sampling before it
        // measures whatever rectangle the label happened to hold — often a pre-layout zero.
        (window ?? superview)?.layoutIfNeeded()
        inked = inked.filter { $0.label != nil }
        for entry in inked {
            guard let label = entry.label else { continue }
            skin.paint(entry.region, to: label, quiet: entry.quiet)
        }
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
            // `auto_system` needs a system dark mode to follow. iOS 12 and the tvOS and iOS 9
            // runtimes below it have none, so systemAppearance() answers nil and the schedule
            // decides -- which is why a panel on 12.5 wears the light palette at midday and the
            // dark one after 19:00. That is the designed degradation, not the wallpaper leaking
            // into the surfaces: cards and chips are palette colours composited over the
            // palette's own background, and the theme picture reaches only per-region ink.
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
        return luminance(red: r, green: g, blue: b)
    }

    /// WCAG 2.x relative luminance of an opaque sRGB triple. Taken per patch while sampling, so it
    /// works on raw components rather than only on a `UIColor`.
    static func luminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        func linear(_ v: CGFloat) -> CGFloat {
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
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
        return ratio(luminance(first), luminance(second))
    }

    /// WCAG contrast ratio between two relative luminances, for the patch extremes a region
    /// sample carries as numbers rather than colours.
    static func ratio(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// One region of an image reduced to at most 16x16 patches, as the cross-platform rule
    /// requires: the average that chooses the ink, and the darkest and lightest patch, which say
    /// whether that ink survives the whole region rather than only its average.
    static func sample(of image: CGImage, in rect: CGRect? = nil) -> BackgroundSample? {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let area = (rect.map { full.intersection($0) } ?? full).integral
        guard area.width >= 1, area.height >= 1,
              let cropped = image.cropping(to: area) else { return nil }
        // A band the width of a footer is sampled across its own shape rather than squared off.
        let width = min(16, Int(area.width)), height = min(16, Int(area.height))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        var r = 0, g = 0, b = 0
        var lowest = CGFloat.greatestFiniteMagnitude, highest = -CGFloat.greatestFiniteMagnitude
        for index in stride(from: 0, to: pixels.count, by: 4) {
            r += Int(pixels[index]); g += Int(pixels[index + 1]); b += Int(pixels[index + 2])
            let patch = luminance(red: CGFloat(pixels[index]) / 255,
                                  green: CGFloat(pixels[index + 1]) / 255,
                                  blue: CGFloat(pixels[index + 2]) / 255)
            lowest = min(lowest, patch)
            highest = max(highest, patch)
        }
        let count = CGFloat(width * height)
        let average = UIColor(red: CGFloat(r) / 255 / count, green: CGFloat(g) / 255 / count,
                              blue: CGFloat(b) / 255 / count, alpha: 1)
        guard lowest <= highest else { return .uniform(average) }
        return BackgroundSample(average: average, minLuminance: lowest, maxLuminance: highest)
    }

    /// The rectangle an aspect-fill picture occupies inside a viewport: scaled up until it covers,
    /// then centred, so the overflow is cropped equally on both sides. This is what
    /// `UIView.ContentMode.scaleAspectFill` does, written out so a region can be mapped onto the
    /// pixels the viewer is actually looking at.
    static func aspectFillRect(imageSize: CGSize, viewport: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: viewport)
        }
        let scale = max(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (viewport.width - size.width) / 2,
                      y: (viewport.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The colour an administrator pinned for one region, if any. Core republishes the overrides
    /// it validated, so the display contract is the first place to look; configuration is the
    /// fallback for a Core that predates it, and this device's own value beats the cluster's.
    static func inkOverride(display: [String: Any]?, config: [String: Any]? = nil,
                            nodeId: String = "", region: String) -> UIColor? {
        if let pinned = color(hex: ConfigUtil.str(display, "theme.ink_override.\(region)")) {
            return pinned
        }
        if !nodeId.isEmpty, let pinned = color(hex: ConfigUtil.str(
            config, "devices.\(nodeId).local.theme.ink_override.\(region)")) {
            return pinned
        }
        return color(hex: ConfigUtil.str(config, "display.theme.ink_override.\(region)"))
    }

    /// The ink for one text region, and where it came from.
    ///
    /// An administrator's override always wins. Below it the ground decides. Over a theme picture
    /// this shell drew, only the local sample under the region is trustworthy: Core measures the
    /// whole picture — or, on one it declined to sample, nothing that is on screen at all — and
    /// cannot know which corner a footer sits in. Over a flat theme colour Core's per-region value
    /// is exact and keeps every shell on one answer. With no decoration the palette owns the text.
    static func decideInk(display: [String: Any]?, config: [String: Any]?, nodeId: String,
                          region: String, ground: InkGround,
                          palette: DoorbellPalette) -> InkDecision {
        let background = ground.color
        if let override = inkOverride(display: display, config: config, nodeId: nodeId,
                                      region: region) {
            return decision(ink: override, ground: ground, source: .admin)
        }
        switch ground {
        case .palette:
            return decision(ink: palette.ink, ground: ground, source: .local)
        case .sampled:
            return decision(ink: automaticInk(on: background), ground: ground,
                            source: .localRegion)
        case .themeColor:
            switch ConfigUtil.str(display, "theme.auto_ink.\(region)") {
            case "dark"?:
                return decision(ink: DoorbellPalette.light.ink, ground: ground, source: .core)
            case "light"?:
                return decision(ink: DoorbellPalette.dark.ink, ground: ground, source: .core)
            default:
                return decision(ink: automaticInk(on: background), ground: ground, source: .local)
            }
        }
    }

    /// The better of the two inks against a measured ground: whichever reaches the higher WCAG
    /// contrast ratio, not whichever side of a luminance threshold the ground falls on. The
    /// threshold is wrong in the middle of the range — a wallpaper averaging #BBBBB4 sits at
    /// Y = 0.494 and would take the light ink at under 2:1, where the dark ink reads at over 9:1.
    /// The two agree everywhere except that middle, and cross over near Y = 0.179.
    static func automaticInk(on background: UIColor) -> UIColor {
        let dark = DoorbellPalette.light.ink, light = DoorbellPalette.dark.ink
        return contrast(dark, background) >= contrast(light, background) ? dark : light
    }

    /// The outline is added when the chosen ink misses the 4.5:1 body-text target against any
    /// patch of the region, not merely against its average: a hint line crossing a pale wall and
    /// a dark jacket averaged fine on the device and disappeared over the jacket. It is the
    /// opposite ink at 40 %.
    private static func decision(ink: UIColor, ground: InkGround,
                                 source: InkSource) -> InkDecision {
        let background = ground.color
        guard ground.worstContrast(ink) < 4.5 else {
            return InkDecision(ink: ink, background: background, source: source, shadow: nil)
        }
        let opposite = luminance(ink) >= 0.5 ? UIColor.black : UIColor.white
        return InkDecision(ink: ink, background: background, source: source, shadow: opposite)
    }

    /// How Core arrived at `auto_background.color`: `image` when it sampled the picture, `color`
    /// for a flat theme, and `image_unsampled` — which carries a `reason` — when the picture was
    /// beyond what it will decode. A value this build has never seen is a newer Core.
    enum BackgroundSource: String {
        case image
        case color
        case imageUnsampled = "image_unsampled"
    }

    static func backgroundSource(display: [String: Any]?) -> BackgroundSource? {
        guard let raw = ConfigUtil.str(display, "theme.auto_background.source") else { return nil }
        return BackgroundSource(rawValue: raw)
    }

    /// Whether Core's published colour describes what this screen is showing. It does for a flat
    /// theme and for a picture Core measured; it does not once Core reports it refused to sample
    /// the picture, and a source value this build has never seen is read the same cautious way.
    /// A contract with no `source` at all is an older Core, whose colour was always a measurement.
    static func publishedBackgroundIsGround(display: [String: Any]?) -> Bool {
        guard ConfigUtil.str(display, "theme.auto_background.source") != nil else { return true }
        guard let source = backgroundSource(display: display) else { return false }
        return source != .imageUnsampled
    }

    /// The background a text region sits on, as Core measured it (a picture is averaged there);
    /// nil when the contract is absent and the shell must measure locally.
    static func publishedBackground(display: [String: Any]?) -> UIColor? {
        return color(hex: ConfigUtil.str(display, "theme.auto_background.color"))
    }

    /// Blur of the halo drawn behind text that misses AA somewhere in its own region, and how
    /// solid it is. A flat 40 % at a one-point offset — which is what `UILabel.shadowColor` can
    /// express — is two device pixels of unblurred colour on a 2x panel, and the device showed it
    /// simply is not visible behind a busy photograph. A blurred halo at close to full opacity is.
    static let outlineBlurRadius: CGFloat = 3
    static let outlineOpacity: Float = 0.9
    /// Width of the stroked edge drawn around each glyph, in points, for a given text size. A
    /// single width cannot serve a 13 pt footer and a 108 pt clock: 4 pt read as a sticker outline
    /// around the small text on the panel. A fourteenth of the point size tracks the stroke
    /// weight of the glyphs themselves — footer ≈ 1 pt, hint ≈ 1.5 pt, date ≈ 1.7 pt — and the cap
    /// keeps the clock at the 4 pt that already reads well rather than growing to 8.
    static let outlineStrokeDivisor: CGFloat = 14
    static let outlineStrokeMin: CGFloat = 0.75
    static let outlineStrokeMax: CGFloat = 4

    static func outlineStroke(forPointSize pointSize: CGFloat) -> CGFloat {
        guard pointSize > 0 else { return outlineStrokeMin }
        return min(outlineStrokeMax, max(outlineStrokeMin, pointSize / outlineStrokeDivisor))
    }

    /// A halo is drawn when the chosen ink misses AA anywhere on the ground under the region.
    /// Only a `HaloLabel` can carry one; every region that sits straight on the theme background
    /// is one, and a label that is not simply takes the ink.
    static func applyInk(_ ink: UIColor, over ground: InkGround, to label: UILabel) {
        let decided = decision(ink: ink, ground: ground, source: .local)
        label.textColor = decided.ink
        label.shadowColor = nil
        label.shadowOffset = .zero
        guard let halo = label as? HaloLabel else { return }
        halo.halo = decided.shadow?.withAlphaComponent(CGFloat(outlineOpacity))
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
