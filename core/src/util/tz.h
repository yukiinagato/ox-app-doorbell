// Compact IANA time-zone table.
//
// The fleet includes shells (iOS 5 iPad 1, legacy Android) whose operating system time-zone
// database is either absent, frozen, or unreachable from Core, so Core carries its own table.
// It is deliberately a snapshot of the *current* rules for the zones the settings UI offers:
// there is no historical data, so an instant from before the current DST regime may resolve to
// today's rule. Everything the product evaluates -- clocks, schedules, quiet hours, call history
// -- is at or near the present, which is what this table is sized for.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace db {
namespace tz {

// Number of zones in the bundled table.
size_t zoneCount();
// Zone identifier at index, or an empty string when index is out of range. Zones are listed in
// table order: UTC first, then grouped by region.
std::string zoneIdAt(size_t index);
// Region prefix of a zone identifier ("Asia/Tokyo" -> "Asia"; "UTC" -> "UTC").
std::string regionOf(const std::string& zone_id);

bool zoneKnown(const std::string& zone_id);

// Offset east of UTC in minutes for the given UTC instant, plus whether daylight saving applies.
// Returns false for an unknown zone and leaves the outputs untouched.
bool offsetMinAt(const std::string& zone_id, int64_t utc_ms, int* out_offset_min,
                 bool* out_dst = nullptr);

// Civil-calendar helpers shared with the local-time renderer (proleptic Gregorian).
int64_t daysFromCivil(int year, int month, int day);
void civilFromDays(int64_t days, int* year, int* month, int* day);
// 0 = Sunday .. 6 = Saturday.
int weekdayFromDays(int64_t days);

// {"iso","hh","mm","ss","date","weekday","weekday_num","tz","offset_min","dst","wall_ms"}
// where iso is "YYYY-MM-DDTHH:MM:SS+09:00" and weekday is the short lowercase name used by rule
// schedules ("mon"). When zone_id is unknown or empty, fallback_offset_min is used and "tz"
// reports the requested identifier unchanged so the caller can see what was asked for.
std::string localTimeJson(const std::string& zone_id, int64_t wall_ms, int fallback_offset_min);

}  // namespace tz
}  // namespace db
