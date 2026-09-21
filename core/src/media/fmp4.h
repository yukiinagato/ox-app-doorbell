





// Dependency-free H.264 Annex-B to fragmented-MP4 muxing helpers. They package hardware-encoded
// access units only; core never software-encodes on legacy hardware.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "util/common.h"

namespace db {
namespace fmp4 {



struct NalView {
  const uint8_t* p = nullptr;
  size_t n = 0;
  int type = 0;
};
std::vector<NalView> splitAnnexB(const uint8_t* data, size_t len);



bool parseSpsDims(const uint8_t* sps, size_t len, int* w, int* h);

// Validate the small, bounded subset of H.264 parameter syntax needed to keep an avcC
// configuration coherent. The PPS must name the supplied SPS; malformed or out-of-range IDs
// are rejected rather than being published to a decoder.
bool validParameterSets(const Bytes& sps, const Bytes& pps);

// True only when this Annex-B access unit contains a syntactically valid IDR slice that names
// `pps`. This is the commit point for a pending parameter-set update.
bool idrReferencesPps(const uint8_t* annexb, size_t len, const Bytes& pps);


std::string codecString(const Bytes& sps);


struct Sample {
  Bytes data;
  bool key = false;
  int64_t ts_ms = 0;
  uint32_t dur = 0;
};



Sample toSample(const uint8_t* annexb, size_t len, Bytes* sps, Bytes* pps);

// Init segment (ftyp + moov), track 1, 1000-unit timescale.

Bytes buildInit(const Bytes& sps, const Bytes& pps);



Bytes buildFragment(uint32_t seq, uint64_t base_dt, const std::vector<Sample>& samples);

}  // namespace fmp4
}  // namespace db
