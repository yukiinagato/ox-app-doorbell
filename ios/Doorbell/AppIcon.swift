import UIKit

/// Every glyph the shell shows. iOS 13 and tvOS use the system's SF Symbols; iOS 9 to 12 have
/// none, so each icon also names a bundled Framework7 Icons template (MIT, drawn in the SF style),
/// generated into `Assets.xcassets` by `tools/gen_icons.py` from `assets/icons/framework7/`.
enum AppIconName: String, CaseIterable {
    case home, parcel, mail, sales, work, settings, info, bell, bellOff, videoOff, door, warning
    case shield, clock, copy, phone, hangUp, reply, volume, unlock, mic, micOff, tablet, palette
    case note, cluster, link, close, check, reload, chevronDown, chevronsRight, plus, eye

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
        "p_sales": .sales, "p_work": .work, "p_other": .info]

    static func purpose(_ id: String) -> UIImage? {
        guard let name = purposeIcons[id] else { return nil }
        return image(name)
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
