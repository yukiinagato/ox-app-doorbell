import Foundation

// The device-side settings are data first. A catalog turns the replicated configuration into
// categories, pages, sections and items; every item names its control and how a new value maps to
// Core configuration keys. The UIKit layer only renders and commits, so the mapping and the
// validation are testable without a screen, and the iOS, iPadOS and tvOS layouts share them.

struct SettingOption: Equatable {
    let value: String
    let title: String
}

enum SettingValue: Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case strings([String])

    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    var intValue: Int? { if case .int(let v) = self { return v }; return nil }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var stringsValue: [String]? { if case .strings(let v) = self { return v }; return nil }
}

/// What committing a value does.
enum SettingEffect {
    /// One atomic Core configuration batch.
    case write([ConfigWriter.Operation])
    /// The value was rejected before reaching Core; the string is a message key.
    case invalid(String)
    /// A shell action the controller performs itself (identity in boot.json, a password change,
    /// a sound preview, opening another screen). The committed value travels with it.
    case local(String)
    case none
}

struct SettingIcon: Equatable {
    /// A short glyph drawn on a rounded tile; no image assets, so every OS draws the same icon.
    let glyph: String
    /// 0xRRGGBB tile colour.
    let tint: UInt32
}

indirect enum SettingControl {
    case toggle(Bool)
    case slider(value: Int, minimum: Int, maximum: Int, step: Int)
    case stepper(value: Int, minimum: Int, maximum: Int, step: Int, unit: String)
    case segmented(value: String, options: [SettingOption])
    case choice(value: String, options: [SettingOption], searchable: Bool)
    /// `ordered` lists are reorderable; at least `minimumCount` entries stay selected.
    case multiChoice(values: [String], options: [SettingOption], ordered: Bool, minimumCount: Int)
    /// "HH:mm", 24-hour.
    case time(String)
    case text(value: String, placeholder: String, numeric: Bool)
    /// Never pre-filled and never echoed.
    case secret
    case info(String)
    case action(destructive: Bool)
    case page(() -> SettingsPage)
    case list(() -> SettingsListModel)
    /// Opens a screen the shell owns (call history, add device, an announcement editor).
    case shell(String)
}

struct SettingItem {
    /// Stable identifier: the accessibility identifier, and the path component for drill-down.
    let id: String
    let title: String
    var detail: String = ""
    let control: SettingControl
    var commit: ((SettingValue) -> SettingEffect)?

    init(_ id: String, _ title: String, detail: String = "", _ control: SettingControl,
         commit: ((SettingValue) -> SettingEffect)? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.control = control
        self.commit = commit
    }
}

struct SettingSection {
    var header: String
    var footer: String
    var items: [SettingItem]

    init(_ header: String = "", footer: String = "", _ items: [SettingItem]) {
        self.header = header
        self.footer = footer
        self.items = items
    }

    /// Header-less section: `SettingSection([items])`.
    init(_ items: [SettingItem]) {
        self.init("", footer: "", items)
    }
}

struct SettingsPage {
    let id: String
    let title: String
    var sections: [SettingSection]

    func item(_ id: String) -> SettingItem? {
        for section in sections {
            if let match = section.items.first(where: { $0.id == id }) { return match }
        }
        return nil
    }
}

struct SettingsCategory {
    let id: String
    let title: String
    let icon: SettingIcon
    let summary: String
    let page: () -> SettingsPage
}

/// One row of a list editor.
struct SettingsListRow {
    let id: String
    let title: String
    var detail: String = ""
    /// A row-level switch (for example "offered to visitors"), committed on change.
    var enabled: Bool?
    var toggle: ((Bool) -> SettingEffect)?
    var edit: (() -> SettingsPage)?
}

/// A list with optional reorder, delete and add, like the iOS Settings "Edit" lists.
struct SettingsListModel {
    let id: String
    let title: String
    var footer: String = ""
    var rows: [SettingsListRow]
    var reorder: (([String]) -> SettingEffect)?
    var delete: ((String) -> SettingEffect)?
    var addTitle: String = ""
    var add: (() -> SettingEffect)?
    /// A new row needs a value typed first (an NTP server, a preset text).
    var addPrompt: String = ""
    var addWithText: ((String) -> SettingEffect)?
    /// Long lists (the wording overrides) get a search field.
    var searchable = false
}

// MARK: - Validation shared by every target

enum SettingValidation {
    /// "H:mm" or "HH:mm" → "HH:mm"; nil when it is not a clock time.
    static func clock(_ raw: String) -> String? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, parts[0].count <= 2, parts[1].count == 2,
              let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0...23).contains(hours), (0...59).contains(minutes) else { return nil }
        return String(format: "%02d:%02d", hours, minutes)
    }

    static func minutes(ofClock clock: String) -> Int? {
        guard let value = self.clock(clock) else { return nil }
        let parts = value.split(separator: ":")
        return Int(parts[0])! * 60 + Int(parts[1])!
    }

    /// Door IDs: 1–64 characters, a leading ASCII letter or digit, then letters, digits, _ or -.
    static func doorId(_ raw: String) -> Bool {
        let scalars = Array(raw.unicodeScalars)
        guard (1...64).contains(scalars.count) else { return false }
        func alnum(_ s: Unicode.Scalar) -> Bool {
            return (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9")
        }
        guard alnum(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { alnum($0) || $0 == "_" || $0 == "-" }
    }

    /// "#RGB" or "#RRGGBB" (the # is optional) → "#RRGGBB", upper case.
    static func hexColor(_ raw: String) -> String? {
        var hex = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.allSatisfy({ "0123456789ABCDEF".contains($0) }) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        return hex.count == 6 ? "#" + hex : nil
    }

    /// "host" or "host:port", 1–255 characters, no spaces or scheme.
    static func ntpServer(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard (1...255).contains(value.count), !value.contains(" "), !value.contains("/")
        else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard !parts[0].isEmpty, let port = Int(parts[1]), (1...65535).contains(port)
            else { return nil }
        } else if parts.count > 2 {
            return nil
        }
        return value
    }

    static func port(_ raw: String) -> Int? {
        guard let value = Int(raw.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(value) else { return nil }
        return value
    }

    static func clamp(_ value: Int, _ minimum: Int, _ maximum: Int) -> Int {
        return max(minimum, min(maximum, value))
    }

    /// Snaps to `step` from `minimum` and clamps.
    static func snap(_ value: Int, minimum: Int, maximum: Int, step: Int) -> Int {
        let stride = max(1, step)
        let snapped = minimum + Int((Double(value - minimum) / Double(stride)).rounded()) * stride
        return clamp(snapped, minimum, maximum)
    }

    /// Writes `order` 1…n for the given ids in this order, the shape every ordered map uses.
    static func orderOperations(prefix: String, ids: [String]) -> [ConfigWriter.Operation] {
        return ids.enumerated().map { index, id in .set("\(prefix).\(id).order", index + 1) }
    }

    /// A fresh map key such as `qr_3fa1c09e`.
    static func newId(_ prefix: String) -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return prefix + "_" + String(hex.prefix(8))
    }

    /// Visible text with no control characters, 1...limit characters after trimming.
    static func label(_ raw: String, limit: Int) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= limit,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }
}
