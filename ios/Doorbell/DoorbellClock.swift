import Foundation

/// What a clock needs from Core: whether Core is up, and one zone-corrected reading. `CoreBridge`
/// is the only production conformer; the protocol exists so a test can watch, and refuse, the
/// calls a clock makes.
protocol DoorbellClockCore: AnyObject {
    /// False until `db_core_start` has returned successfully. A reading taken before that runs
    /// inline on the caller's thread, beside Core building itself on its own.
    var isRunning: Bool { get }
    func localTime(wallMs: Int64) -> [String: Any]?
}

extension CoreBridge: DoorbellClockCore {}

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

    /// Nothing is read from a Core that has not finished starting: before that the export runs on
    /// the caller's thread instead of Core's, which on a background queue puts a second thread
    /// inside the node while `db_core_start` is still assembling it.
    static func read(_ core: DoorbellClockCore, wallMs: Int64 = 0) -> Reading? {
        guard core.isRunning else { return nil }
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

    /// Advances a reading by whole seconds without asking Core again. Everything Core returns is
    /// already zone-corrected, so moving it forward is plain arithmetic on the same fields.
    static func advance(_ reading: Reading, bySeconds seconds: Int) -> Reading {
        guard seconds > 0 else { return reading }
        let total = reading.hour * 3600 + reading.minute * 60 + reading.second + seconds
        let days = total / 86400
        let rest = total % 86400
        var date = reading.date
        var weekday = reading.weekday
        if days > 0 {
            date = addDays(days, to: reading.date)
            if let index = weekdayKeys.firstIndex(of: reading.weekday) {
                weekday = weekdayKeys[(index + days) % 7]
            }
        }
        return Reading(hour: rest / 3600, minute: (rest % 3600) / 60, second: rest % 60,
                       date: date, weekday: weekday, tz: reading.tz, known: reading.known,
                       wallMs: reading.wallMs + Int64(seconds) * 1000, raw: reading.raw)
    }

    /// Civil-date arithmetic on Core's `YYYY-MM-DD`, so a clock that crosses midnight between two
    /// refreshes shows tomorrow's date rather than yesterday's for up to half a minute.
    static func addDays(_ days: Int, to date: String) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3, var year = Int(parts[0]), var month = Int(parts[1]),
              var day = Int(parts[2]), days > 0 else { return date }
        for _ in 0..<days {
            day += 1
            if day > daysIn(month: month, year: year) {
                day = 1
                month += 1
                if month > 12 {
                    month = 1
                    year += 1
                }
            }
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        }
    }

    static func nowMs(_ core: CoreBridge) -> Int64 {
        if let reading = read(core), reading.wallMs > 0 { return reading.wallMs }
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// A clock disciplined by Core rather than read from it every second.
///
/// `db_core_local_time_json` is a synchronous call into Core, and Core does not answer while it is
/// mid-SNTP or building a status document. Calling it once a second on the main thread — twice, in
/// fact, because the dashboard asked as well — is what made the panel's seconds advance in threes.
/// The base is now taken off the main thread every half minute and whenever Core says the time
/// changed, and each tick is arithmetic on that base against the monotonic clock.
final class DoorbellClockSource {

    /// How often the base is re-taken from Core.
    static let refreshIntervalS: TimeInterval = 30

    private var base: DoorbellClock.Reading?
    private var baseUptime: TimeInterval = 0
    private var refreshing = false

    var hasReading: Bool { return base != nil }

    /// The time to draw. No Core call, no lock: safe at 1 Hz on the main thread.
    func reading() -> DoorbellClock.Reading? {
        guard let base = base else { return nil }
        let elapsed = ProcessInfo.processInfo.systemUptime - baseUptime
        guard elapsed >= 1 else { return base }
        return DoorbellClock.advance(base, bySeconds: Int(elapsed))
    }

    /// Whether the last attempt was turned away because Core had not started. The screens poll
    /// this so the first reading is taken as soon as Core is up rather than at the next half
    /// minute.
    private(set) var waitingForCore = false

    /// Re-takes the base from Core off the main thread. `completion` receives how long Core took,
    /// which is the number worth watching: it is the stall this indirection exists to keep off
    /// the run loop.
    func refresh(_ core: DoorbellClockCore, completion: ((TimeInterval) -> Void)? = nil) {
        guard !refreshing else { return }
        // The one rule this indirection exists to keep: never a loop-backed export off the main
        // thread while Core is still starting. `db_core_local_time_json` is synchronous into
        // Core's run loop, and before that loop is Running it executes the body on the calling
        // thread — here a utility queue, beside `db_core_start` building the node.
        guard core.isRunning else {
            waitingForCore = true
            return
        }
        waitingForCore = false
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            let fresh = DoorbellClock.read(core)
            let finished = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refreshing = false
                if let fresh = fresh {
                    self.base = fresh
                    // The reading describes the moment Core answered, so the base is timed to the
                    // middle of the call rather than to either end of it.
                    self.baseUptime = (started + finished) / 2
                }
                completion?(finished - started)
            }
        }
    }
}
