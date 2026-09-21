#import <Foundation/Foundation.h>
#import "DBBackdropCompositor.h"
#import "DBUiTheme.h"

static void Require(BOOL condition, NSString *message) {
  if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

static void ReleasePixels(void *info, const void *data, size_t size) {
  (void)info; (void)size; free((void *)data);
}

// Raw provider scanlines fix the fixture's top row independently of CGContext transforms.
static CGImageRef NewQuadrants(void) CF_RETURNS_RETAINED {
  const size_t side = 64, rowBytes = side * 4;
  unsigned char *pixels = malloc(side * rowBytes);
  for (size_t y = 0; y < side; y++) {
    for (size_t x = 0; x < side; x++) {
      unsigned char level = y < 32 ? (x < 32 ? 0 : 64) : (x < 32 ? 128 : 255);
      unsigned char *p = pixels + y * rowBytes + x * 4;
      p[0] = p[1] = p[2] = level; p[3] = 255;
    }
  }
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, side * rowBytes,
                                                         ReleasePixels);
  CGImageRef image = CGImageCreate(side, side, 8, 32, rowBytes, space,
      kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast, provider, NULL, false,
      kCGRenderingIntentDefault);
  CGDataProviderRelease(provider); CGColorSpaceRelease(space);
  return image;
}

int main(void) {
  @autoreleasepool {
    CGImageRef image = NewQuadrants();
    CGSize views[] = { CGSizeMake(1024,768), CGSizeMake(768,1024), CGSizeMake(640,640) };
    for (NSUInteger v = 0; v < 3; v++) {
      NSData *proxy = [DBBackdropCompositor rgbaProxyForImage:image viewSize:views[v] edge:64];
      Require(proxy.length == 64 * 64 * 4, @"the proxy has bounded RGBA storage");
      const unsigned char *bytes = proxy.bytes;
      const NSUInteger positions[] = { 16 * 64 + 16, 16 * 64 + 48, 48 * 64 + 16, 48 * 64 + 48 };
      const int expected[] = { 0, 64, 128, 255 };
      for (NSUInteger q = 0; q < 4; q++) {
        const unsigned char *p = bytes + positions[q] * 4;
        Require(abs(p[0] - expected[q]) <= 1 && p[0] == p[1] && p[1] == p[2] && p[3] == 255,
            [NSString stringWithFormat:@"view %lu quadrant %lu must preserve the displayed scanline (got %u, wanted %d)",
             (unsigned long)v, (unsigned long)q, p[0], expected[q]]);
      }
      DBRgb top = { bytes[positions[0] * 4] / 255.0, 0, 0 };
      NSString *topInk = [DBUiTheme inkHexForSampledLuminance:[DBUiTheme relativeLuminance:top]];
      Require([topInk isEqual:[DBUiTheme lightInkHex]], @"a clock on the black top uses light ink");
      Require([[DBUiTheme inkHexForSampledLuminance:1.0] isEqual:[DBUiTheme darkInkHex]],
              @"the white bottom uses dark ink");
    }
    Require([DBBackdropCompositor rgbaProxyForImage:NULL viewSize:views[0] edge:64] == nil,
            @"a missing image has no proxy");
    Require([DBBackdropCompositor rgbaProxyForImage:image viewSize:CGSizeZero edge:64] == nil,
            @"an unlaid-out view has no proxy");
    Require([DBBackdropCompositor rgbaProxyForImage:image viewSize:views[0] edge:0] == nil,
            @"a zero edge has no proxy");
    Require([DBBackdropCompositor rgbaProxyForImage:image viewSize:views[0] edge:257] == nil,
            @"the sampling allocation is bounded");
    CGImageRelease(image);
    NSLog(@"background sampler: portrait, landscape, square and invalid inputs passed");
  }
  return 0;
}
