
#ifndef MS_G711_H
#define MS_G711_H

#include <stdint.h>

/* ITU-T G.711 mu-law conversion helpers for 8 kHz mono MiniSIP audio. */

#ifdef __cplusplus
extern "C" {
#endif


uint8_t ms_linear2ulaw(int16_t pcm);


int16_t ms_ulaw2linear(uint8_t ulaw);


void ms_pcm_to_ulaw(const int16_t *pcm, uint8_t *ulaw, int n);
void ms_ulaw_to_pcm(const uint8_t *ulaw, int16_t *pcm, int n);


#define MS_ULAW_SILENCE 0xFFu

#ifdef __cplusplus
}
#endif

#endif /* MS_G711_H */
