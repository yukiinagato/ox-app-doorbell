// Thread-safe hybrid logical clock with wall-clock correction from observed remote timestamps.



#pragma once

#include <cstdint>
#include <mutex>
#include <string>

#include "util/clock.h"

namespace db {

class HlcClock {
 public:

  HlcClock(IClock& clock, std::string node8);


  std::string tick();

  void observe(const std::string& remote_hlc);



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
};

}  // namespace db
