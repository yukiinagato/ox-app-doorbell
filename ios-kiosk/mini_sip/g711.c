
#include "g711.h"

#define MS_BIAS 0x84
#define MS_CLIP 8159
#define MS_SIGN_BIT 0x80
#define MS_QUANT_MASK 0x0F
#define MS_SEG_SHIFT 4
#define MS_SEG_MASK 0x70


static const int16_t kSegEnd[8] = {0x3F,  0x7F,  0xFF,  0x1FF,
                                   0x3FF, 0x7FF, 0xFFF, 0x1FFF};

static int seg_search(int val) {
  int i;
  for (i = 0; i < 8; i++) {
    if (val <= kSegEnd[i]) return i;
  }
  return 8;
}

uint8_t ms_linear2ulaw(int16_t pcm) {
  int val = pcm;
  int mask;
  int seg;
  uint8_t uval;


  val = val >> 2;
  if (val < 0) {
    val = -val;
    mask = 0x7F;
  } else {
    mask = 0xFF;
  }
  if (val > MS_CLIP) val = MS_CLIP;
  val += (MS_BIAS >> 2);

  seg = seg_search(val);
  if (seg >= 8) {
    return (uint8_t)(0x7F ^ mask);
  }
  uval = (uint8_t)((seg << 4) | ((val >> (seg + 1)) & 0x0F));
  return (uint8_t)(uval ^ mask);
}

int16_t ms_ulaw2linear(uint8_t ulaw) {
  int t;
  ulaw = (uint8_t)~ulaw;
  t = ((ulaw & MS_QUANT_MASK) << 3) + MS_BIAS;
  t <<= (ulaw & MS_SEG_MASK) >> MS_SEG_SHIFT;
  return (int16_t)((ulaw & MS_SIGN_BIT) ? (MS_BIAS - t) : (t - MS_BIAS));
}

void ms_pcm_to_ulaw(const int16_t *pcm, uint8_t *ulaw, int n) {
  int i;
  for (i = 0; i < n; i++) ulaw[i] = ms_linear2ulaw(pcm[i]);
}

void ms_ulaw_to_pcm(const uint8_t *ulaw, int16_t *pcm, int n) {
  int i;
  for (i = 0; i < n; i++) pcm[i] = ms_ulaw2linear(ulaw[i]);
}
