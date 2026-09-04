#ifndef DB_PIXEL_ROWS_H
#define DB_PIXEL_ROWS_H

#include <stddef.h>

// Bottom-up RGBA buffers need this conversion before CGImage pixel providers
// interpret scanline zero as the top row.
static inline void DBFlipPixelRows(unsigned char *pixels, size_t width, size_t height) {
  if (pixels == NULL || width == 0 || height < 2) return;
  size_t rowBytes = width * 4;
  for (size_t top = 0, bottom = height - 1; top < bottom; top++, bottom--) {
    unsigned char *topRow = pixels + top * rowBytes;
    unsigned char *bottomRow = pixels + bottom * rowBytes;
    for (size_t byte = 0; byte < rowBytes; byte++) {
      unsigned char value = topRow[byte];
      topRow[byte] = bottomRow[byte];
      bottomRow[byte] = value;
    }
  }
}

#endif
