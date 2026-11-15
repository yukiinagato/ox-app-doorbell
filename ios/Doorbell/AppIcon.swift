import UIKit

/// Every glyph the shell shows. iOS 13 and tvOS use the system's SF Symbols; iOS 9 to 12 have
/// none, so each icon also names a bundled Framework7 Icons template (MIT, drawn in the SF style),
/// generated into `Assets.xcassets` by `tools/gen_icons.py` from `assets/icons/framework7/`.
enum AppIconName: String, CaseIterable {
    case home, parcel, mail, sales, work, settings, info, bell, bellOff, videoOff, door, warning
    case shield, clock, copy, phone, hangUp, reply, volume, unlock, mic, micOff, tablet, palette
    case note, cluster, link, close, check, reload, chevronDown, chevronsRight, plus, eye
    case person, ellipsis

    /// The SF Symbol name, and the bundled imageset that stands in where the symbol is missing.
    var names: (symbol: String, fallback: String) {
        switch self {
        case .home: return ("house.fill", "F7HouseFill")
        case .parcel: return ("shippingbox.fill", "F7ShippingboxFill")
        case .mail: return ("envelope.fill", "F7EnvelopeFill")
        case .sales: return ("bag.fill", "F7BagFill")
        case .work: return ("hammer.fill", "F7HammerFill")
        case .settings: return ("gearshape.fill", "F7GearAltFill")
        case .info: return ("info.circle.fill", "F7InfoCircleFill")
        case .bell: return ("bell.fill", "F7BellFill")
        case .bellOff: return ("bell.slash.fill", "F7BellSlashFill")
        case .videoOff: return ("video.slash.fill", "F7EyeSlashFill")
        case .door: return ("door.left.hand.closed", "F7LockFill")
        case .warning: return ("exclamationmark.triangle.fill", "F7ExclamationmarkTriangleFill")
        case .shield: return ("lock.shield.fill", "F7LockShieldFill")
        case .clock: return ("clock.fill", "F7ClockFill")
        case .copy: return ("doc.on.doc", "F7DocOnDoc")
        case .phone: return ("phone.fill", "F7PhoneFill")
        case .hangUp: return ("phone.down.fill", "F7PhoneDownFill")
        case .reply: return ("arrowshape.turn.up.left.fill", "F7ArrowshapeTurnUpLeftFill")
        case .volume: return ("speaker.wave.2.fill", "F7Speaker2Fill")
        case .unlock: return ("lock.open.fill", "F7LockOpenFill")
        case .mic: return ("mic.fill", "F7MicFill")
        case .micOff: return ("mic.slash.fill", "F7MicSlashFill")
        case .tablet: return ("ipad", "F7DeviceTabletPortrait")
        case .palette: return ("paintbrush.fill", "F7PaintbrushFill")
        case .note: return ("doc.text.fill", "F7DocTextFill")
        case .cluster: return ("network", "F7AntennaRadiowavesLeftRight")
        case .link: return ("link", "F7Link")
        case .close: return ("xmark", "F7Xmark")
        case .check: return ("checkmark", "F7Checkmark")
        case .reload: return ("arrow.clockwise", "F7ArrowClockwise")
        case .chevronDown: return ("chevron.down", "F7ChevronDown")
        case .chevronsRight: return ("chevron.right.2", "F7ChevronRight2")
        case .plus: return ("plus", "F7Plus")
        case .eye: return ("eye.fill", "F7EyeFill")
        case .person: return ("person.fill", "F7PersonFill")
        case .ellipsis: return ("ellipsis.circle.fill", "F7EllipsisCircleFill")
        }
    }

    var symbol: String { return names.symbol }
    var fallback: String { return names.fallback }
}

/// Icons are never drawn in Swift. Each one is a template image, so it takes the ink of the
/// region it sits in.
enum AppIcon {

    /// Core's seeded purpose ids and the icon each one wears. A purpose an administrator invented
    /// has no icon of its own; the shell falls back to whatever text they configured.
    static let purposeIcons: [String: AppIconName] = [
        "p_visit": .home, "p_delivery": .parcel, "p_mail": .mail,
        "p_sales": .sales, "p_work": .work, "p_other": .ellipsis]

    static func purpose(_ id: String) -> UIImage? {
        guard let name = purposeIcons[id] else { return nil }
        return image(name)
    }

    /// What the visitor flow's picker offers and stores: one canonical emoji per icon, the value
    /// every shell and Core already understand. The emoji is configuration data and is never drawn.
    static let flowChoices: [(icon: AppIconName, emoji: String, titleKey: String)] = [
        (.home, "\u{1F3E0}", "flow_editor.icon_home"),
        (.parcel, "\u{1F4E6}", "flow_editor.icon_parcel"),
        (.mail, "\u{2709}\u{FE0F}", "flow_editor.icon_mail"),
        (.sales, "\u{1F4BC}", "flow_editor.icon_sales"),
        (.work, "\u{1F527}", "flow_editor.icon_work"),
        (.ellipsis, "\u{2753}", "flow_editor.icon_other"),
        (.person, "\u{1F464}", "flow_editor.icon_person"),
    ]

    private static let flowEmoji: [String: AppIconName] = [
        "\u{1F3E0}": .home, "\u{1F3E1}": .home, "\u{1F3E2}": .home,
        "\u{1F4E6}": .parcel, "\u{1F69A}": .parcel, "\u{1F4EB}": .parcel,
        "\u{2709}": .mail, "\u{1F4E7}": .mail, "\u{1F4E8}": .mail, "\u{1F4EE}": .mail,
        "\u{1F48C}": .mail,
        "\u{1F4BC}": .sales, "\u{1F6CD}": .sales, "\u{1F6D2}": .sales, "\u{1F4B0}": .sales,
        "\u{1F454}": .sales,
        "\u{1F527}": .work, "\u{1F528}": .work, "\u{1F6E0}": .work, "\u{2692}": .work,
        "\u{1F9F0}": .work, "\u{26A1}": .work,
        "\u{2753}": .ellipsis, "\u{2754}": .ellipsis, "\u{2026}": .ellipsis, "\u{22EF}": .ellipsis,
        "\u{2795}": .ellipsis,
        "\u{270D}": .note, "\u{1F4DD}": .note,
        "\u{1F464}": .person, "\u{1F9D1}": .person, "\u{1F642}": .person,
    ]

    /// The glyph for a flow option: its purpose first (the seeded ids and their plain names), then
    /// the emoji Core inlined from the purpose or the administrator typed, then the person glyph
    /// for anything unknown. Variation selectors are ignored.
    static func flowGlyph(purpose: String, icon: String) -> AppIconName {
        if let known = purposeIcons[purpose] { return known }
        let plain = ["visit": AppIconName.home, "delivery": .parcel, "mail": .mail, "sales": .sales,
                     "work": .work, "utility": .work, "other": .ellipsis]
        if let known = plain[purpose.hasPrefix("p_") ? String(purpose.dropFirst(2)) : purpose] { return known }
        let stripped = String(String.UnicodeScalarView(icon.unicodeScalars.filter { $0.value != 0xFE0F }))
        if let known = flowEmoji[stripped] { return known }
        return .person
    }

    /// The picker value that selects the glyph `icon` maps to, or nil for something unknown.
    static func flowChoiceValue(for icon: String) -> String? {
        guard !icon.isEmpty else { return nil }
        let stripped = String(String.UnicodeScalarView(icon.unicodeScalars.filter { $0.value != 0xFE0F }))
        guard let glyph = flowEmoji[stripped] else { return nil }
        return flowChoices.first { $0.icon == glyph }?.emoji
    }

    /// A template image. A symbol this OS release does not ship (some are newer than iOS 13)
    /// falls back to the bundled copy, so the icon is never missing.
    static func image(_ name: AppIconName) -> UIImage? {
        if #available(iOS 13.0, tvOS 13.0, *), let symbol = UIImage(systemName: name.symbol) {
            return symbol.withRenderingMode(.alwaysTemplate)
        }
        return UIImage(named: name.fallback)?.withRenderingMode(.alwaysTemplate)
    }
}
