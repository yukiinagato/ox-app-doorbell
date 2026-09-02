
#ifndef DB_TS_MUX_H
#define DB_TS_MUX_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DBTsMux DBTsMux;

/* The sink consumes bytes synchronously and must not retain the pointer after it returns. */
typedef void (*DBTsSink)(void *ctx, const uint8_t *data, size_t len);

DBTsMux *dbtsmux_create(DBTsSink sink, void *ctx);
void dbtsmux_free(DBTsMux *m);


void dbtsmux_set_sps_pps(DBTsMux *m, const uint8_t *sps, size_t sps_len,
                         const uint8_t *pps, size_t pps_len);


void dbtsmux_feed_au(DBTsMux *m, const uint8_t *au, size_t len,
                     int64_t pts_ms, int64_t dts_ms, int key);


void dbtsmux_begin_segment(DBTsMux *m);

#ifdef __cplusplus
}
#endif

#endif /* DB_TS_MUX_H */
