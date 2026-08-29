#import "DBQrCode.h"
#import "qrcodegen.h"

@implementation DBQrCode

+ (UIImage *)imageForString:(NSString *)s targetPx:(CGFloat)px {
  if ([s length] == 0) return nil;
  const char *text = [s UTF8String];
  uint8_t qr[qrcodegen_BUFFER_LEN_MAX];
  uint8_t tmp[qrcodegen_BUFFER_LEN_MAX];
  bool ok = qrcodegen_encodeText(text, tmp, qr, qrcodegen_Ecc_MEDIUM,
                                 qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX,
                                 qrcodegen_Mask_AUTO, true);
  if (!ok) return nil;
  int size = qrcodegen_getSize(qr);
  int quiet = 3;
  int total = size + quiet * 2;
  int scale = (int)floor(px / total);
  if (scale < 1) scale = 1;
  size_t dim = (size_t)(total * scale);
  size_t bpr = dim * 4;
  void *buf = calloc(dim * bpr, 1);
  if (buf == NULL) return nil;
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(buf, dim, dim, 8, bpr, cs,
                                           (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  if (ctx == NULL) {
    free(buf);
    return nil;
  }
  CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
  CGContextFillRect(ctx, CGRectMake(0, 0, dim, dim));
  CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      if (qrcodegen_getModule(qr, x, y))
        CGContextFillRect(ctx, CGRectMake((x + quiet) * scale, (y + quiet) * scale, scale, scale));
    }
  }
  CGImageRef img = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  free(buf);
  if (img == NULL) return nil;
  UIImage *ui = [UIImage imageWithCGImage:img];
  CGImageRelease(img);
  return ui;
}

@end
