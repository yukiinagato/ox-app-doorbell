#include "util/tz.h"

#include <cstdio>
#include <cstring>

namespace db {
namespace tz {
namespace {

// Daylight-saving rule families. Only the regimes currently in force are modelled.
enum Rule : uint8_t {
  kNone = 0,
  // European Union: last Sunday of March 01:00 UTC to last Sunday of October 01:00 UTC.
  kEu,
  // North America since 2007: second Sunday of March 02:00 local standard time to the first
  // Sunday of November 02:00 local daylight time.
  kNorthAmerica,
  // Southern Australia: first Sunday of October 02:00 local standard time to the first Sunday
  // of April 03:00 local daylight time.
  kAustralia,
  // New Zealand: last Sunday of September 02:00 local standard time to the first Sunday of
  // April 03:00 local daylight time.
  kNewZealand,
  // Chile: first Sunday of September 00:00 local standard time to the first Sunday of April
  // 00:00 local daylight time.
  kChile,
  // Israel: the Friday before the last Sunday of March 02:00 local standard time to the last
  // Sunday of October 02:00 local daylight time.
  kIsrael,
};

struct Zone {
  const char* id;
  int16_t std_offset_min;
  int16_t dst_offset_min;
  uint8_t rule;
};

// Ordered UTC first, then by region and by offset inside a region, so the settings UI can render
// the table in table order without sorting.
const Zone kZones[] = {
    {"UTC", 0, 0, kNone},

    {"Asia/Tokyo", 540, 540, kNone},
    {"Asia/Seoul", 540, 540, kNone},
    {"Asia/Shanghai", 480, 480, kNone},
    {"Asia/Hong_Kong", 480, 480, kNone},
    {"Asia/Macau", 480, 480, kNone},
    {"Asia/Taipei", 480, 480, kNone},
    {"Asia/Manila", 480, 480, kNone},
    {"Asia/Singapore", 480, 480, kNone},
    {"Asia/Kuala_Lumpur", 480, 480, kNone},
    {"Asia/Vladivostok", 600, 600, kNone},
    {"Asia/Bangkok", 420, 420, kNone},
    {"Asia/Jakarta", 420, 420, kNone},
    {"Asia/Ho_Chi_Minh", 420, 420, kNone},
    {"Asia/Yangon", 390, 390, kNone},
    {"Asia/Dhaka", 360, 360, kNone},
    {"Asia/Kathmandu", 345, 345, kNone},
    {"Asia/Kolkata", 330, 330, kNone},
    {"Asia/Colombo", 330, 330, kNone},
    {"Asia/Karachi", 300, 300, kNone},
    {"Asia/Tashkent", 300, 300, kNone},
    {"Asia/Almaty", 300, 300, kNone},
    {"Asia/Dubai", 240, 240, kNone},
    {"Asia/Baku", 240, 240, kNone},
    {"Asia/Tehran", 210, 210, kNone},
    {"Asia/Baghdad", 180, 180, kNone},
    {"Asia/Qatar", 180, 180, kNone},
    {"Asia/Riyadh", 180, 180, kNone},
    {"Asia/Jerusalem", 120, 180, kIsrael},

    {"Europe/London", 0, 60, kEu},
    {"Europe/Dublin", 0, 60, kEu},
    {"Europe/Lisbon", 0, 60, kEu},
    {"Europe/Madrid", 60, 120, kEu},
    {"Europe/Paris", 60, 120, kEu},
    {"Europe/Brussels", 60, 120, kEu},
    {"Europe/Amsterdam", 60, 120, kEu},
    {"Europe/Berlin", 60, 120, kEu},
    {"Europe/Zurich", 60, 120, kEu},
    {"Europe/Vienna", 60, 120, kEu},
    {"Europe/Rome", 60, 120, kEu},
    {"Europe/Prague", 60, 120, kEu},
    {"Europe/Warsaw", 60, 120, kEu},
    {"Europe/Budapest", 60, 120, kEu},
    {"Europe/Stockholm", 60, 120, kEu},
    {"Europe/Oslo", 60, 120, kEu},
    {"Europe/Copenhagen", 60, 120, kEu},
    {"Europe/Helsinki", 120, 180, kEu},
    {"Europe/Athens", 120, 180, kEu},
    {"Europe/Bucharest", 120, 180, kEu},
    {"Europe/Sofia", 120, 180, kEu},
    {"Europe/Kyiv", 120, 180, kEu},
    {"Europe/Riga", 120, 180, kEu},
    {"Europe/Tallinn", 120, 180, kEu},
    {"Europe/Vilnius", 120, 180, kEu},
    {"Europe/Istanbul", 180, 180, kNone},
    {"Europe/Minsk", 180, 180, kNone},
    {"Europe/Moscow", 180, 180, kNone},

    {"America/St_Johns", -210, -150, kNorthAmerica},
    {"America/Halifax", -240, -180, kNorthAmerica},
    {"America/New_York", -300, -240, kNorthAmerica},
    {"America/Toronto", -300, -240, kNorthAmerica},
    {"America/Panama", -300, -300, kNone},
    {"America/Bogota", -300, -300, kNone},
    {"America/Lima", -300, -300, kNone},
    {"America/Chicago", -360, -300, kNorthAmerica},
    {"America/Winnipeg", -360, -300, kNorthAmerica},
    {"America/Mexico_City", -360, -360, kNone},
    {"America/Denver", -420, -360, kNorthAmerica},
    {"America/Edmonton", -420, -360, kNorthAmerica},
    {"America/Phoenix", -420, -420, kNone},
    {"America/Los_Angeles", -480, -420, kNorthAmerica},
    {"America/Vancouver", -480, -420, kNorthAmerica},
    {"America/Anchorage", -540, -480, kNorthAmerica},
    {"America/Caracas", -240, -240, kNone},
    {"America/Santiago", -240, -180, kChile},
    {"America/Sao_Paulo", -180, -180, kNone},
    {"America/Montevideo", -180, -180, kNone},
    {"America/Argentina/Buenos_Aires", -180, -180, kNone},

    {"Australia/Perth", 480, 480, kNone},
    {"Australia/Darwin", 570, 570, kNone},
    {"Australia/Adelaide", 570, 630, kAustralia},
    {"Australia/Brisbane", 600, 600, kNone},
    {"Australia/Sydney", 600, 660, kAustralia},
    {"Australia/Melbourne", 600, 660, kAustralia},
    {"Australia/Hobart", 600, 660, kAustralia},
    {"Pacific/Port_Moresby", 600, 600, kNone},
    {"Pacific/Guam", 600, 600, kNone},
    {"Pacific/Auckland", 720, 780, kNewZealand},
    {"Pacific/Fiji", 720, 720, kNone},
    {"Pacific/Honolulu", -600, -600, kNone},

    {"Africa/Accra", 0, 0, kNone},
    {"Africa/Casablanca", 60, 60, kNone},
    {"Africa/Lagos", 60, 60, kNone},
    {"Africa/Johannesburg", 120, 120, kNone},
    {"Africa/Nairobi", 180, 180, kNone},
    {"Atlantic/Reykjavik", 0, 0, kNone},
    {"Atlantic/Azores", -60, 0, kEu},
};

constexpr int64_t kDayMs = 86'400'000LL;
constexpr int64_t kMinuteMs = 60'000LL;

int64_t floorDivI(int64_t a, int64_t b) {
  const int64_t q = a / b;
  return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

const Zone* findZone(const std::string& id) {
  for (const auto& zone : kZones) {
    if (id == zone.id) return &zone;
  }
  return nullptr;
}

// UTC milliseconds of the nth weekday of a month at a given local wall time. nth is 1-based;
// -1 selects the last such weekday of the month. offset_min converts local wall time to UTC.
int64_t weekdayTransitionMs(int year, int month, int weekday, int nth, int minute_of_day,
                            int offset_min) {
  int64_t day;
  if (nth > 0) {
    const int64_t first = daysFromCivil(year, month, 1);
    const int shift = (weekday - weekdayFromDays(first) + 7) % 7;
    day = first + shift + static_cast<int64_t>(nth - 1) * 7;
  } else {
    const int next_month = month == 12 ? 1 : month + 1;
    const int next_year = month == 12 ? year + 1 : year;
    const int64_t last = daysFromCivil(next_year, next_month, 1) - 1;
    const int shift = (weekdayFromDays(last) - weekday + 7) % 7;
    day = last - shift;
  }
  return day * kDayMs + static_cast<int64_t>(minute_of_day) * kMinuteMs -
         static_cast<int64_t>(offset_min) * kMinuteMs;
}

bool daylightActive(const Zone& zone, int64_t utc_ms) {
  if (zone.rule == kNone) return false;
  int year = 1970, month = 1, day = 1;
  civilFromDays(floorDivI(utc_ms, kDayMs), &year, &month, &day);
  const int std_off = zone.std_offset_min;
  const int dst_off = zone.dst_offset_min;
  switch (zone.rule) {
    case kEu: {
      const int64_t start = weekdayTransitionMs(year, 3, 0, -1, 60, 0);
      const int64_t end = weekdayTransitionMs(year, 10, 0, -1, 60, 0);
      return utc_ms >= start && utc_ms < end;
    }
    case kNorthAmerica: {
      const int64_t start = weekdayTransitionMs(year, 3, 0, 2, 120, std_off);
      const int64_t end = weekdayTransitionMs(year, 11, 0, 1, 120, dst_off);
      return utc_ms >= start && utc_ms < end;
    }
    case kIsrael: {
      // Two days before the last Sunday of March, i.e. the preceding Friday.
      const int64_t start = weekdayTransitionMs(year, 3, 0, -1, 120, std_off) - 2 * kDayMs;
      const int64_t end = weekdayTransitionMs(year, 10, 0, -1, 120, dst_off);
      return utc_ms >= start && utc_ms < end;
    }
    case kAustralia: {
      const int64_t start = weekdayTransitionMs(year, 10, 0, 1, 120, std_off);
      const int64_t end = weekdayTransitionMs(year, 4, 0, 1, 180, dst_off);
      return utc_ms >= start || utc_ms < end;
    }
    case kNewZealand: {
      const int64_t start = weekdayTransitionMs(year, 9, 0, -1, 120, std_off);
      const int64_t end = weekdayTransitionMs(year, 4, 0, 1, 180, dst_off);
      return utc_ms >= start || utc_ms < end;
    }
    case kChile: {
      const int64_t start = weekdayTransitionMs(year, 9, 0, 1, 0, std_off);
      const int64_t end = weekdayTransitionMs(year, 4, 0, 1, 0, dst_off);
      return utc_ms >= start || utc_ms < end;
    }
    default:
      return false;
  }
}

const char* const kDayNames[7] = {"sun", "mon", "tue", "wed", "thu", "fri", "sat"};

}  // namespace

size_t zoneCount() { return sizeof(kZones) / sizeof(kZones[0]); }

std::string zoneIdAt(size_t index) {
  if (index >= zoneCount()) return "";
  return kZones[index].id;
}

std::string regionOf(const std::string& zone_id) {
  const size_t slash = zone_id.find('/');
  return slash == std::string::npos ? zone_id : zone_id.substr(0, slash);
}

bool zoneKnown(const std::string& zone_id) { return findZone(zone_id) != nullptr; }

bool offsetMinAt(const std::string& zone_id, int64_t utc_ms, int* out_offset_min, bool* out_dst) {
  const Zone* zone = findZone(zone_id);
  if (!zone) return false;
  const bool dst = daylightActive(*zone, utc_ms);
  if (out_offset_min) *out_offset_min = dst ? zone->dst_offset_min : zone->std_offset_min;
  if (out_dst) *out_dst = dst;
  return true;
}

// Howard Hinnant's civil-calendar algorithms, shifted to an era starting on 0000-03-01.
int64_t daysFromCivil(int year, int month, int day) {
  int64_t y = year;
  y -= month <= 2;
  const int64_t era = (y >= 0 ? y : y - 399) / 400;
  const int64_t yoe = y - era * 400;
  const int64_t doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
  const int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe - 719468;
}

void civilFromDays(int64_t days, int* year, int* month, int* day) {
  days += 719468;
  const int64_t era = (days >= 0 ? days : days - 146096) / 146097;
  const int64_t doe = days - era * 146097;
  const int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  const int64_t y = yoe + era * 400;
  const int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  const int64_t mp = (5 * doy + 2) / 153;
  const int64_t d = doy - (153 * mp + 2) / 5 + 1;
  const int64_t m = mp + (mp < 10 ? 3 : -9);
  if (year) *year = static_cast<int>(y + (m <= 2 ? 1 : 0));
  if (month) *month = static_cast<int>(m);
  if (day) *day = static_cast<int>(d);
}

int weekdayFromDays(int64_t days) {
  // 1970-01-01 was a Thursday (4).
  return static_cast<int>(((days % 7) + 11) % 7);
}

std::string localTimeJson(const std::string& zone_id, int64_t wall_ms, int fallback_offset_min) {
  int offset_min = fallback_offset_min;
  bool dst = false;
  const bool known = offsetMinAt(zone_id, wall_ms, &offset_min, &dst);
  const int64_t local_ms = wall_ms + static_cast<int64_t>(offset_min) * kMinuteMs;
  const int64_t days = floorDivI(local_ms, kDayMs);
  const int64_t rem = local_ms - days * kDayMs;
  int year = 1970, month = 1, day = 1;
  civilFromDays(days, &year, &month, &day);
  const int hh = static_cast<int>(rem / 3'600'000LL);
  const int mm = static_cast<int>((rem / kMinuteMs) % 60);
  const int ss = static_cast<int>((rem / 1000) % 60);
  const int abs_offset = offset_min < 0 ? -offset_min : offset_min;
  char buffer[256];
  std::snprintf(buffer, sizeof(buffer),
                "{\"iso\":\"%04d-%02d-%02dT%02d:%02d:%02d%c%02d:%02d\","
                "\"date\":\"%04d-%02d-%02d\",\"hh\":%d,\"mm\":%d,\"ss\":%d,"
                "\"weekday\":\"%s\",\"weekday_num\":%d,\"offset_min\":%d,"
                "\"dst\":%s,\"known\":%s,\"wall_ms\":%lld,\"tz\":\"",
                year, month, day, hh, mm, ss, offset_min < 0 ? '-' : '+', abs_offset / 60,
                abs_offset % 60, year, month, day, hh, mm, ss,
                kDayNames[weekdayFromDays(days)], weekdayFromDays(days), offset_min,
                dst ? "true" : "false", known ? "true" : "false",
                static_cast<long long>(wall_ms));
  std::string out = buffer;
  // Zone identifiers come from the bundled table or from validated configuration; escape the
  // few characters JSON forbids anyway so a hand-written identifier cannot break the document.
  for (char c : zone_id) {
    if (c == '"' || c == '\\') out.push_back('\\');
    if (static_cast<unsigned char>(c) < 0x20) continue;
    out.push_back(c);
  }
  out += "\"}";
  return out;
}

}  // namespace tz
}  // namespace db
