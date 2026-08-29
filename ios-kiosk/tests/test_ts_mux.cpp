#include "../src/Media/DBTsMux.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <vector>

static void sink(void *ctx, const uint8_t *data, size_t len) {
  std::vector<uint8_t> *out = static_cast<std::vector<uint8_t> *>(ctx);
  out->insert(out->end(), data, data + len);
}

static uint16_t pid(const uint8_t *packet) {
  return (uint16_t)(((packet[1] & 0x1F) << 8) | packet[2]);
}

static size_t payloadOffset(const uint8_t *packet) {
  int control = (packet[3] >> 4) & 0x03;
  if (control == 1) return 4;
  if (control == 3) return 5 + packet[4];
  return 188;
}

int main() {
  std::vector<uint8_t> ts;
  DBTsMux *mux = dbtsmux_create(sink, &ts);
  assert(mux != NULL);

  const uint8_t sps[] = {0x67, 0x42, 0xC0, 0x1F, 0xDA, 0x01, 0x40, 0x16,
                         0xE8, 0x40, 0x00, 0x00, 0x03, 0x00, 0x40};
  const uint8_t pps[] = {0x68, 0xCE, 0x3C, 0x80};
  dbtsmux_set_sps_pps(mux, sps, sizeof(sps), pps, sizeof(pps));

  std::vector<uint8_t> au(700, 0x55);
  const uint8_t idrStart[] = {0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84};
  memcpy(&au[0], idrStart, sizeof(idrStart));
  dbtsmux_feed_au(mux, &au[0], au.size(), 1000, 1000, 1);
  dbtsmux_free(mux);

  assert(ts.size() % 188 == 0);
  assert(ts.size() >= 6 * 188);
  const size_t packetCount = ts.size() / 188;
  for (size_t i = 0; i < packetCount; i++) assert(ts[i * 188] == 0x47);

  const uint8_t *pat = &ts[0];
  assert(pid(pat) == 0x0000);
  assert((pat[1] & 0x40) != 0);
  const uint8_t *patSection = pat + 5;
  assert(patSection[0] == 0x00);
  assert((((patSection[10] & 0x1F) << 8) | patSection[11]) == 0x1000);

  const uint8_t *pmt = &ts[188];
  assert(pid(pmt) == 0x1000);
  const uint8_t *pmtSection = pmt + 5;
  assert(pmtSection[0] == 0x02);
  assert((((pmtSection[8] & 0x1F) << 8) | pmtSection[9]) == 0x0101);
  assert(pmtSection[12] == 0x1B);
  assert((((pmtSection[13] & 0x1F) << 8) | pmtSection[14]) == 0x0101);

  std::vector<uint8_t> pes;
  int expectedCc = -1;
  for (size_t i = 2; i < packetCount; i++) {
    const uint8_t *packet = &ts[i * 188];
    if (pid(packet) != 0x0101) continue;
    int cc = packet[3] & 0x0F;
    if (expectedCc >= 0) assert(cc == expectedCc);
    expectedCc = (cc + 1) & 0x0F;
    size_t off = payloadOffset(packet);
    assert(off <= 188);
    if (pes.empty()) {
      assert((packet[1] & 0x40) != 0);
      assert(((packet[3] >> 4) & 0x03) == 3);
      assert((packet[5] & 0x10) != 0);  // PCR
      assert((packet[5] & 0x40) != 0);  // random_access_indicator
    }
    pes.insert(pes.end(), packet + off, packet + 188);
  }

  assert(pes.size() > 14);
  assert(pes[0] == 0x00 && pes[1] == 0x00 && pes[2] == 0x01 && pes[3] == 0xE0);
  assert(pes[6] == 0x84);
  assert(pes[7] == 0x80);
  assert(pes[8] == 5);
  assert((pes[9] & 0xF0) == 0x20);

  const size_t es = 14;
  const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
  assert(memcmp(&pes[es], startCode, sizeof(startCode)) == 0);
  assert(pes[es + 4] == 0x09 && pes[es + 5] == 0xF0);  // AUD
  const size_t spsAt = es + 6;
  assert(memcmp(&pes[spsAt], startCode, sizeof(startCode)) == 0);
  assert(pes[spsAt + 4] == 0x67);
  const size_t ppsAt = spsAt + 4 + sizeof(sps);
  assert(memcmp(&pes[ppsAt], startCode, sizeof(startCode)) == 0);
  assert(pes[ppsAt + 4] == 0x68);
  const size_t auAt = ppsAt + 4 + sizeof(pps);
  assert(memcmp(&pes[auAt], idrStart, sizeof(idrStart)) == 0);

  puts("ok: DBTsMux PAT/PMT/PES/continuity");
  return 0;
}
