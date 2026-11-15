import Foundation

/// Bursts of change events become one refresh.
struct SettingsRefreshCoalescer {
    static let delay: TimeInterval = 0.15

    private(set) var scheduled = false
    private(set) var forced = false

    /// True when the caller must schedule a refresh; false when one is already waiting.
    mutating func request(force: Bool = false) -> Bool {
        if force { forced = true }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    /// Starts the waiting refresh and returns whether any request in it asked for a full reload.
    mutating func fire() -> Bool {
        scheduled = false
        defer { forced = false }
        return forced
    }
}

/// Settings the user changed whose write has not finished. A refresh must not rewrite their rows
/// from Core's older value, or the control would flip back and forth.
struct SettingsPendingWrites {
    private var counts: [String: Int] = [:]

    var ids: Set<String> { return Set(counts.keys) }

    mutating func begin(_ id: String) { counts[id, default: 0] += 1 }

    mutating func finish(_ id: String) {
        guard let count = counts[id] else { return }
        if count <= 1 { counts.removeValue(forKey: id) } else { counts[id] = count - 1 }
    }

    func isPending(_ id: String) -> Bool { return counts[id] != nil }
}

/// What a refreshed page needs: nothing, a few rows, or a full reload.
enum SettingsRowDiff: Equatable {
    case same
    case rows([IndexPath])
    case structure

    /// `old` and `new` hold one (id, fingerprint) pair per row, grouped by section. Rows in
    /// `skip` keep what the user just set.
    static func compare(old: [[(id: String, print: String)]], new: [[(id: String, print: String)]],
                        skip: Set<String> = []) -> SettingsRowDiff {
        guard old.count == new.count else { return .structure }
        var changed: [IndexPath] = []
        for section in 0..<old.count {
            guard old[section].count == new[section].count else { return .structure }
            for row in 0..<old[section].count {
                let before = old[section][row], after = new[section][row]
                if before.id != after.id { return .structure }
                if before.print != after.print && !skip.contains(after.id) {
                    changed.append(IndexPath(row: row, section: section))
                }
            }
        }
        return changed.isEmpty ? .same : .rows(changed)
    }
}

extension SettingControl {
    /// A comparable description of what a row shows; navigation closures count by kind only.
    var fingerprint: String {
        switch self {
        case .page: return "page"
        case .list: return "list"
        default: return String(describing: self)
        }
    }
}

extension SettingItem {
    var fingerprint: String { return "\(title)|\(detail)|\(control.fingerprint)" }
}

extension SettingsPage {
    var rowPrints: [[(id: String, print: String)]] {
        return sections.map { $0.items.map { (id: $0.id, print: $0.fingerprint) } }
    }
}
