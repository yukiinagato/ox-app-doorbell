#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "media/fmp4.h"
#include "media/video_track.h"

int main(int argc, char** argv) {
  if (argc != 4) return 2;
  std::ifstream source(argv[1], std::ios::binary);
  const db::Bytes bytes{std::istreambuf_iterator<char>(source), std::istreambuf_iterator<char>()};
  std::vector<db::Bytes> units;
  for (const auto& nal : db::fmp4::splitAnnexB(bytes.data(), bytes.size())) {
    if (nal.type == 9) units.emplace_back();
    if (units.empty()) return 3;
    auto& unit = units.back();
    unit.insert(unit.end(), {0, 0, 0, 1});
    unit.insert(unit.end(), nal.p, nal.p + nal.n);
  }
  if (units.size() < 10) return 4;
  const bool reject = std::string(argv[3]) == "reject";
  db::VideoTrack track;
  track.setEnabled(true);
  auto reader = track.subscribe();
  std::ofstream output(argv[2], std::ios::binary);
  for (size_t index = 0; index < units.size(); ++index) {
    db::Bytes unit = units[index];
    if (reject && index == 1) unit.insert(unit.begin(), {0, 0, 0, 1, 0x68, 0x00});
    track.push(unit.data(), unit.size(), false, 1000 + static_cast<int64_t>(index) * 40);
    bool ended = false;
    for (;;) {
      auto fragment = reader->pull(0, &ended);
      if (ended) return 5;
      if (fragment.empty()) break;
      output.write(reinterpret_cast<const char*>(fragment.data()), fragment.size());
    }
  }
  return output.good() ? 0 : 6;
}
