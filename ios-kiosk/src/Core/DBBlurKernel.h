#ifndef DB_BLUR_KERNEL_H
#define DB_BLUR_KERNEL_H

#include <stddef.h>
#include <stdlib.h>

// The five fixed GPU samples are visually dense through radius eight. Larger
// spacing creates separated lobes, so the one-time backdrop uses the dense
// sliding-window kernel instead.
#define DB_FROSTED_BLUR_MAXIMUM_GPU_RADIUS 8

static inline int DBFrostedBlurUsesGPUForRadius(size_t radius) {
  return radius <= DB_FROSTED_BLUR_MAXIMUM_GPU_RADIUS;
}

static inline size_t DBBlurClampedIndex(ptrdiff_t index, size_t length) {
  if (index < 0) return 0;
  if ((size_t)index >= length) return length - 1;
  return (size_t)index;
}

// Both passes are rolling sums, so runtime is linear in bitmap area rather
// than in radius. Input and output must not overlap.
static inline int DBBoxBlurRGBA(const unsigned char *input, unsigned char *output,
                                size_t width, size_t height, size_t radius) {
  if (input == NULL || output == NULL || width == 0 || height == 0) return 0;
  size_t count = width * height * 4;
  unsigned char *horizontal = (unsigned char *)malloc(count);
  if (horizontal == NULL) return 0;
  size_t span = radius * 2 + 1;
  for (size_t y = 0; y < height; y++) {
    size_t sums[4] = {0, 0, 0, 0};
    for (ptrdiff_t x = -(ptrdiff_t)radius; x <= (ptrdiff_t)radius; x++) {
      size_t column = DBBlurClampedIndex(x, width);
      for (size_t c = 0; c < 4; c++) sums[c] += input[(y * width + column) * 4 + c];
    }
    for (size_t x = 0; x < width; x++) {
      for (size_t c = 0; c < 4; c++) horizontal[(y * width + x) * 4 + c] = sums[c] / span;
      size_t remove = DBBlurClampedIndex((ptrdiff_t)x - (ptrdiff_t)radius, width);
      size_t add = DBBlurClampedIndex((ptrdiff_t)x + (ptrdiff_t)radius + 1, width);
      for (size_t c = 0; c < 4; c++) {
        sums[c] += input[(y * width + add) * 4 + c];
        sums[c] -= input[(y * width + remove) * 4 + c];
      }
    }
  }
  for (size_t x = 0; x < width; x++) {
    size_t sums[4] = {0, 0, 0, 0};
    for (ptrdiff_t y = -(ptrdiff_t)radius; y <= (ptrdiff_t)radius; y++) {
      size_t row = DBBlurClampedIndex(y, height);
      for (size_t c = 0; c < 4; c++) sums[c] += horizontal[(row * width + x) * 4 + c];
    }
    for (size_t y = 0; y < height; y++) {
      for (size_t c = 0; c < 4; c++) output[(y * width + x) * 4 + c] = sums[c] / span;
      size_t remove = DBBlurClampedIndex((ptrdiff_t)y - (ptrdiff_t)radius, height);
      size_t add = DBBlurClampedIndex((ptrdiff_t)y + (ptrdiff_t)radius + 1, height);
      for (size_t c = 0; c < 4; c++) {
        sums[c] += horizontal[(add * width + x) * 4 + c];
        sums[c] -= horizontal[(remove * width + x) * 4 + c];
      }
    }
  }
  free(horizontal);
  return 1;
}

#endif
