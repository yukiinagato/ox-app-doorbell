/* DBTsMux — H.264 AnnexB -> MPEG-TS (HLS, no external dependencies). */
#include "DBTsMux.h"

#include <stdlib.h>
#include <string.h>

namespace {

const uint16_t kPmtPid = 0x1000;
const uint16_t kVideoPid = 0x0101;
const size_t kMaxAccessUnitBytes = 4 * 1024 * 1024;

}  // namespace

struct DBTsMux {
  DBTsSink sink;
  void *ctx;
  uint8_t sps[256];
  size_t sps_len;
  uint8_t pps[128];
  size_t pps_len;
  uint8_t cc_pat, cc_pmt, cc_vid;
  int need_pmt;
  uint8_t *pes;
  size_t pes_cap;
};

static uint32_t crc32_mpeg(const uint8_t *d, size_t n) {
  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < n; i++) {
    crc ^= (uint32_t)d[i] << 24;
    for (int b = 0; b < 8; b++)
      crc = (crc & 0x80000000u) ? (crc << 1) ^ 0x04C11DB7u : (crc << 1);
  }
  return crc;
}

static void ts_hdr(uint8_t *p, uint16_t pid, int pusi, int adaptation,
                   uint8_t cc) {
  p[0] = 0x47;
  p[1] = (uint8_t)((pusi ? 0x40 : 0) | ((pid >> 8) & 0x1F));
  p[2] = (uint8_t)(pid & 0xFF);
  p[3] = (uint8_t)((adaptation ? 0x30 : 0x10) | (cc & 0x0F));
}

static void send_psi(DBTsMux *m, uint16_t pid, uint8_t *cc,
                     const uint8_t *sec, size_t sec_len) {
  uint8_t p[188];
  memset(p, 0xFF, sizeof(p));
  ts_hdr(p, pid, 1, 0, (*cc)++);
  p[4] = 0x00;  // pointer_field
  memcpy(p + 5, sec, sec_len);
  m->sink(m->ctx, p, sizeof(p));
}

static void send_pat(DBTsMux *m) {
  uint8_t s[16];
  memset(s, 0, sizeof(s));
  s[0] = 0x00;
  s[1] = 0xB0; s[2] = 0x0D;
  s[3] = 0x00; s[4] = 0x01;
  s[5] = 0xC1;
  s[8] = 0x00; s[9] = 0x01;
  s[10] = (uint8_t)(0xE0 | ((kPmtPid >> 8) & 0x1F));
  s[11] = (uint8_t)kPmtPid;
  uint32_t crc = crc32_mpeg(s, 12);
  s[12] = (uint8_t)(crc >> 24); s[13] = (uint8_t)(crc >> 16);
  s[14] = (uint8_t)(crc >> 8); s[15] = (uint8_t)crc;
  send_psi(m, 0x0000, &m->cc_pat, s, sizeof(s));
}

static void send_pmt(DBTsMux *m) {
  uint8_t s[21];
  memset(s, 0, sizeof(s));
  s[0] = 0x02;
  s[1] = 0xB0; s[2] = 0x12;
  s[3] = 0x00; s[4] = 0x01;
  s[5] = 0xC1;
  s[8] = (uint8_t)(0xE0 | ((kVideoPid >> 8) & 0x1F));
  s[9] = (uint8_t)kVideoPid;
  s[10] = 0xF0; s[11] = 0x00;
  s[12] = 0x1B;
  s[13] = (uint8_t)(0xE0 | ((kVideoPid >> 8) & 0x1F));
  s[14] = (uint8_t)kVideoPid;
  s[15] = 0xF0; s[16] = 0x00;
  uint32_t crc = crc32_mpeg(s, 17);
  s[17] = (uint8_t)(crc >> 24); s[18] = (uint8_t)(crc >> 16);
  s[19] = (uint8_t)(crc >> 8); s[20] = (uint8_t)crc;
  send_psi(m, kPmtPid, &m->cc_pmt, s, sizeof(s));
}

static void write_pts(uint8_t *p, uint8_t prefix, int64_t ms) {
  uint64_t v = (uint64_t)(ms * 90) & 0x1FFFFFFFFull;
  p[0] = (uint8_t)(prefix | ((v >> 29) & 0x0E) | 1);
  p[1] = (uint8_t)(v >> 22);
  p[2] = (uint8_t)(((v >> 14) & 0xFE) | 1);
  p[3] = (uint8_t)(v >> 7);
  p[4] = (uint8_t)((v << 1) | 1);
}

static int ensure_pes_capacity(DBTsMux *m, size_t need) {
  if (need <= m->pes_cap) return 1;
  size_t cap = m->pes_cap ? m->pes_cap : 64 * 1024;
  while (cap < need) cap *= 2;
  uint8_t *p = (uint8_t *)realloc(m->pes, cap);
  if (!p) return 0;
  m->pes = p;
  m->pes_cap = cap;
  return 1;
}

static void write_pcr(uint8_t *p, int64_t dts_ms) {
  uint64_t base = (uint64_t)(dts_ms * 90) & 0x1FFFFFFFFull;
  p[0] = (uint8_t)(base >> 25);
  p[1] = (uint8_t)(base >> 17);
  p[2] = (uint8_t)(base >> 9);
  p[3] = (uint8_t)(base >> 1);
  p[4] = (uint8_t)(((base & 1) << 7) | 0x7E);
  p[5] = 0x00;
}

extern "C" {

DBTsMux *dbtsmux_create(DBTsSink sink, void *ctx) {
  if (!sink) return NULL;
  DBTsMux *m = (DBTsMux *)calloc(1, sizeof(DBTsMux));
  if (!m) return NULL;
  m->sink = sink;
  m->ctx = ctx;
  m->need_pmt = 1;
  return m;
}

void dbtsmux_free(DBTsMux *m) {
  if (!m) return;
  free(m->pes);
  free(m);
}

void dbtsmux_set_sps_pps(DBTsMux *m, const uint8_t *sps, size_t sl,
                         const uint8_t *pps, size_t pl) {
  if (!m || !sps || !pps || sl == 0 || pl == 0 ||
      sl > sizeof(m->sps) || pl > sizeof(m->pps)) return;
  memcpy(m->sps, sps, sl);
  m->sps_len = sl;
  memcpy(m->pps, pps, pl);
  m->pps_len = pl;
}

void dbtsmux_begin_segment(DBTsMux *m) {
  if (m) m->need_pmt = 1;
}

void dbtsmux_feed_au(DBTsMux *m, const uint8_t *au, size_t len,
                     int64_t pts_ms, int64_t dts_ms, int key) {
  if (!m || !au || len == 0 || len > kMaxAccessUnitBytes) return;

  const size_t parameter_bytes =
      (key && m->sps_len && m->pps_len) ? m->sps_len + m->pps_len + 8 : 0;
  const int has_dts = dts_ms != pts_ms;
  const size_t optional_header = has_dts ? 10 : 5;
  const size_t pes_header = 9 + optional_header;
  const size_t es_len = parameter_bytes + len;
  const size_t total = pes_header + es_len;
  if (!ensure_pes_capacity(m, total)) return;

  uint8_t *p = m->pes;
  p[0] = 0x00; p[1] = 0x00; p[2] = 0x01; p[3] = 0xE0;
  const size_t packet_length = 3 + optional_header + es_len;
  if (packet_length <= 0xFFFF) {
    p[4] = (uint8_t)(packet_length >> 8);
    p[5] = (uint8_t)packet_length;
  } else {
    p[4] = 0x00; p[5] = 0x00;
  }
  p[6] = 0x84;
  p[7] = has_dts ? 0xC0 : 0x80;
  p[8] = (uint8_t)optional_header;
  if (has_dts) {
    write_pts(p + 9, 0x30, pts_ms);
    write_pts(p + 14, 0x10, dts_ms);
  } else {
    write_pts(p + 9, 0x20, pts_ms);
  }

  size_t off = pes_header;
  static const uint8_t sc[4] = {0, 0, 0, 1};
  if (parameter_bytes) {
    memcpy(p + off, sc, sizeof(sc)); off += sizeof(sc);
    memcpy(p + off, m->sps, m->sps_len); off += m->sps_len;
    memcpy(p + off, sc, sizeof(sc)); off += sizeof(sc);
    memcpy(p + off, m->pps, m->pps_len); off += m->pps_len;
  }
  memcpy(p + off, au, len);

  if (m->need_pmt) {
    send_pat(m);
    send_pmt(m);
    m->need_pmt = 0;
  }

  size_t sent = 0;
  int first = 1;
  while (sent < total) {
    uint8_t pkt[188];
    memset(pkt, 0xFF, sizeof(pkt));
    const size_t remaining = total - sent;
    size_t take;
    if (first) {
      take = remaining < 176 ? remaining : 176;
      const size_t adaptation_total = 184 - take;
      ts_hdr(pkt, kVideoPid, 1, 1, m->cc_vid++);
      pkt[4] = (uint8_t)(adaptation_total - 1);
      pkt[5] = (uint8_t)(0x10 | (key ? 0x40 : 0x00));
      write_pcr(pkt + 6, dts_ms);
      memcpy(pkt + 4 + adaptation_total, p + sent, take);
      first = 0;
    } else if (remaining >= 184) {
      take = 184;
      ts_hdr(pkt, kVideoPid, 0, 0, m->cc_vid++);
      memcpy(pkt + 4, p + sent, take);
    } else {
      take = remaining;
      const size_t adaptation_total = 184 - take;
      ts_hdr(pkt, kVideoPid, 0, 1, m->cc_vid++);
      pkt[4] = (uint8_t)(adaptation_total - 1);
      if (adaptation_total > 1) pkt[5] = 0x00;
      memcpy(pkt + 4 + adaptation_total, p + sent, take);
    }
    m->sink(m->ctx, pkt, sizeof(pkt));
    sent += take;
  }
}

}  // extern "C"
