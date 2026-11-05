// Thread-safe hybrid logical clock. Remote timestamps affect ordering, never physical time.



#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>

#include "util/clock.h"

namespace db {

class HlcClock {
 public:

  HlcClock(IClock& clock, std::string node8);


  std::string tick();

  // Advances the logical clock past a remote timestamp. A timestamp whose physical part is more
  // than kMaxObserveAheadMs ahead of local wall time is ignored and counted, so one peer with a
  // wrong clock cannot drag every replica's HLC into the future. Returns whether it was applied.
  bool observe(const std::string& remote_hlc);
  static constexpr int64_t kMaxObserveAheadMs = 5 * 60 * 1000;
  // Unbounded variant for this replica's own persisted history. A device whose wall clock has
  // gone backwards must still order new writes after what it already wrote.
  void observePersisted(const std::string& persisted_hlc);
  uint64_t rejectedAhead() const { return rejected_ahead_.load(); }



  // Physical time with the time-service correction, independent of the logical ordering floor.
  int64_t correctedWallMs();


  static bool parse(const std::string& hlc, int64_t* physical_ms, int* counter,
                    std::string* node8);
  static std::string format(int64_t physical_ms, int counter, const std::string& node8);

 private:
  IClock& clock_;
  std::string node8_;
  std::mutex mu_;
  int64_t last_ms_ = 0;
  int counter_ = 0;
  std::atomic<uint64_t> rejected_ahead_{0};
};

}  // namespace db
