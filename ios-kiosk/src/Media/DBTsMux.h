/* DBTsMux — H.264 AnnexB → MPEG-TS 打包器 (HLS 用, 依存ゼロの純 C)。
 *
 * 設計 (iPad1 / iOS5 の MPMoviePlayer が確実に食べられる最小構成):
 *   - PAT + PMT を各セグメント先頭に書く (中間参加でも即デコード可)
 *   - 1 access unit = 1 PES packet。PES は複数 TS packet (188B) に分割
 *   - PCR は各 AU の先頭 TS packet の adaptation field に置く (HLS 推奨 ≤100ms 間隔)
 *   - segment = keyframe 開始の連続 AU 群 (呼び出し側が keyframe で区切る)
 *
 * 出力は呼び出し側が確保したバッファへ逐次追記する (コールバック方式)。
 */
#ifndef DB_TS_MUX_H
#define DB_TS_MUX_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DBTsMux DBTsMux;

/* 追記出力: len バイトを accept する (ユーザデータ ctx)。 */
typedef void (*DBTsSink)(void *ctx, const uint8_t *data, size_t len);

DBTsMux *dbtsmux_create(DBTsSink sink, void *ctx);
void dbtsmux_free(DBTsMux *m);

/* SPS/PPS NAL payload (start code なし) を記憶 — keyframe の直前に挿入する。 */
void dbtsmux_set_sps_pps(DBTsMux *m, const uint8_t *sps, size_t sps_len,
                         const uint8_t *pps, size_t pps_len);

/* access unit 1 枚 (AnnexB start code 付き, SPS/PPS 含まず) を TS 化して sink へ。
 * pts_ms/dts_ms: 表示/復号時刻 (ms)。key: IDR なら 1 (SPS/PPS を前に差し込む)。 */
void dbtsmux_feed_au(DBTsMux *m, const uint8_t *au, size_t len,
                     int64_t pts_ms, int64_t dts_ms, int key);

/* 新セグメント開始: PAT/PMT を次の feed_au で再送する */
void dbtsmux_begin_segment(DBTsMux *m);

#ifdef __cplusplus
}
#endif

#endif /* DB_TS_MUX_H */
