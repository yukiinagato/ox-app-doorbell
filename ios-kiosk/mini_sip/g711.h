/* g711.h — G.711 μ-law (PCMU) コーデック。
 *
 * 門口機 (sipctl) は全経路 PCMU/8000 固定 (リサンプル回避)。本モジュールは
 * linear16 (ホスト PCM) ⇔ μ-law (RTP payload type 0) の変換のみを担う。
 * Sun Microsystems 由来の公有 (public domain) アルゴリズム。純 C89、依存なし。
 */
#ifndef MS_G711_H
#define MS_G711_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* linear PCM (16bit, ホストエンディアン) → μ-law 1 バイト */
uint8_t ms_linear2ulaw(int16_t pcm);

/* μ-law 1 バイト → linear PCM (16bit) */
int16_t ms_ulaw2linear(uint8_t ulaw);

/* 配列一括変換 (n サンプル)。in/out は別バッファ想定。 */
void ms_pcm_to_ulaw(const int16_t *pcm, uint8_t *ulaw, int n);
void ms_ulaw_to_pcm(const uint8_t *ulaw, int16_t *pcm, int n);

/* μ-law の無音値 (linear 0 に対応)。送信側に音源が無いとき用。 */
#define MS_ULAW_SILENCE 0xFFu

#ifdef __cplusplus
}
#endif

#endif /* MS_G711_H */
