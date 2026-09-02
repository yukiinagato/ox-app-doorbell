#include "util/hlc.h"

#include <cstdio>
#include <cstring>

namespace db {

HlcClock::HlcClock(IClock& clock, std::string node8) : clock_(clock), node8_(std::move(node8)) {
  if (node8_.size() > 8) node8_.resize(8);
}

std::string HlcClock::format(int64_t physical_ms, int counter, const std::string& node8) {
  char buf[64];
  std::snprintf(buf, sizeof(buf), "%012llx-%04x-%s",
                static_cast<unsigned long long>(physical_ms & 0xffffffffffffLL),
                counter & 0xffff, node8.c_str());
  return std::string(buf);
}

bool HlcClock::parse(const std::string& hlc, int64_t* physical_ms, int* counter,
                     std::string* node8) {

  if (hlc.size() < 12 + 1 + 4 + 1 + 1) return false;
  if (hlc[12] != '-' || hlc[17] != '-') return false;
  unsigned long long ms = 0;
  unsigned int cnt = 0;
  if (std::sscanf(hlc.c_str(), "%12llx-%4x", &ms, &cnt) != 2) return false;
  if (physical_ms) *physical_ms = static_cast<int64_t>(ms);
  if (counter) *counter = static_cast<int>(cnt);
  if (node8) *node8 = hlc.substr(18);
  return true;
}

std::string HlcClock::tick() {
  std::lock_guard<std::mutex> lk(mu_);
  int64_t wall = clock_.wallMs();
  if (wall > last_ms_) {
    last_ms_ = wall;
    counter_ = 0;
  } else {
    counter_++;
    if (counter_ > 0xffff) {
      last_ms_++;
      counter_ = 0;
    }
  }
  return format(last_ms_, counter_, node8_);
}

void HlcClock::observe(const std::string& remote_hlc) {
  int64_t ms = 0;
  int cnt = 0;
  if (!parse(remote_hlc, &ms, &cnt, nullptr)) return;
  std::lock_guard<std::mutex> lk(mu_);
  if (ms > last_ms_) {
    last_ms_ = ms;
    counter_ = cnt;
  } else if (ms == last_ms_ && cnt > counter_) {
    counter_ = cnt;
  }
}

int64_t HlcClock::correctedWallMs() {
  int64_t wall = clock_.wallMs();
  std::lock_guard<std::mutex> lk(mu_);
  return wall > last_ms_ ? wall : last_ms_;
}

}  // namespace db
