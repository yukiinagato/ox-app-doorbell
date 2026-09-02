import Foundation

/// Every clock and every timestamp the shells draw comes from Core's `db_core_local_time_json`,
/// so a device whose own clock is wrong — or that sits in another zone — still shows the
/// household's time. The struct keeps the last successful reading so a momentary failure does not
/// blank the clock mid-second.
struct DoorbellClock {

    struct Reading {
        let hour: Int
        let minute: Int
        let second: Int
        let date: String
        let weekday: String
        let tz: String
        let known: Bool
        let wallMs: Int64
        let raw: [String: Any]

        var hhmmss: String { return String(format: "%02d:%02d:%02d", hour, minute, second) }
        var hhmm: String { return String(format: "%02d:%02d", hour, minute) }
    }

    private static let weekdayKeys = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    static func read(_ core: CoreBridge, wallMs: Int64 = 0) -> Reading? {
        guard let json = core.localTime(wallMs: wallMs) else { return nil }
        return Reading(hour: ConfigUtil.int(json, "hh", 0),
                       minute: ConfigUtil.int(json, "mm", 0),
                       second: ConfigUtil.int(json, "ss", 0),
                       date: ConfigUtil.str(json, "date") ?? "",
                       weekday: ConfigUtil.str(json, "weekday") ?? "",
                       tz: ConfigUtil.str(json, "tz") ?? "",
                       known: ConfigUtil.bool(json, "known", false),
                       wallMs: Int64(ConfigUtil.double(json, "wall_ms", 0)),
                       raw: json)
    }

    /// Long date for the big clocks: "2026年9月2日 (水)" in Japanese, a plain ISO-derived date
    /// elsewhere. Only Core's already-zone-corrected fields are used, never the OS calendar.
    static func longDate(_ reading: Reading, lang: String) -> String {
        let parts = reading.date.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
              let day = Int(parts[2]) else { return reading.date }
        let weekday = weekdayName(reading.weekday, lang: lang)
        switch lang {
        case "ja":
            return "\(year)年\(month)月\(day)日" + (weekday.isEmpty ? "" : " (\(weekday))")
        case "zh":
            return "\(year)年\(month)月\(day)日" + (weekday.isEmpty ? "" : " (\(weekday))")
        default:
            return String(format: "%04d-%02d-%02d", year, month, day)
                + (weekday.isEmpty ? "" : " (\(weekday))")
        }
    }

    static func weekdayName(_ key: String, lang: String) -> String {
        guard let index = weekdayKeys.firstIndex(of: key) else { return "" }
        switch lang {
        case "ja": return ["日", "月", "火", "水", "木", "金", "土"][index]
        case "zh": return ["日", "一", "二", "三", "四", "五", "六"][index]
        default: return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][index]
        }
    }

    /// Clock time of a recorded event, rendered in the cluster zone.
    static func timeOfDay(_ core: CoreBridge, wallMs: Int64) -> String {
        guard let reading = read(core, wallMs: wallMs) else { return "" }
        return reading.hhmm
    }

    /// Day bucket used to group the history: the ISO date in the cluster zone.
    static func dayKey(_ core: CoreBridge, wallMs: Int64) -> String {
        return read(core, wallMs: wallMs)?.date ?? ""
    }

    /// Header for one history day group: 今日 / 昨日 / the date itself.
    static func dayTitle(_ core: CoreBridge, texts: Texts, dayKey: String, lang: String) -> String {
        guard let now = read(core) else { return dayKey }
        if dayKey == now.date { return texts.t("history.today") }
        if dayKey == shiftedDate(now.date, byDays: -1) { return texts.t("history.yesterday") }
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else {
            return dayKey
        }
        switch lang {
        case "ja", "zh": return "\(month)月\(day)日"
        default: return String(format: "%02d-%02d", month, day)
        }
    }

    /// Calendar arithmetic on the zone-corrected date string, so it never consults the OS zone.
    static func shiftedDate(_ date: String, byDays days: Int) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
              let day = Int(parts[2]) else { return date }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let base = calendar.date(from: components),
              let moved = calendar.date(byAdding: .day, value: days, to: base) else { return date }
        let moveComponents = calendar.dateComponents([.year, .month, .day], from: moved)
        return String(format: "%04d-%02d-%02d", moveComponents.year ?? year,
                      moveComponents.month ?? month, moveComponents.day ?? day)
    }

    /// End of the current day in the cluster zone, as an absolute wall-clock deadline. Used by the
    /// announcement dialog's "end of today" preset.
    static func endOfTodayMs(_ core: CoreBridge) -> Int64 {
        guard let now = read(core) else { return 0 }
        let elapsed = Int64(now.hour * 3600 + now.minute * 60 + now.second) * 1000
        let dayMs: Int64 = 24 * 3600 * 1000
        return now.wallMs - elapsed + dayMs
    }

    static func nowMs(_ core: CoreBridge) -> Int64 {
        if let reading = read(core), reading.wallMs > 0 { return reading.wallMs }
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}
