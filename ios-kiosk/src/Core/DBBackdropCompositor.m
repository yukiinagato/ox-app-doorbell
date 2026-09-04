#import "DBBackdropCompositor.h"

#import "DBUiTheme.h"

@implementation DBBackdropCompositor

// Spec 5.1 wants the picture, not a wash, and still wants the cards and text
// over it to read. Just over 60 % black is where both hold on the wallpapers
// this cluster ships.
+ (CGFloat)darkeningAlpha { return 0.62; }

+ (CGFloat)maximumLongSide { return 1024; }

+ (CGSize)preparedSizeForViewSize:(CGSize)size {
  CGFloat longSide = MAX(size.width, size.height);
  if (longSide <= 0 || longSide <= [self maximumLongSide]) return size;
  CGFloat scale = [self maximumLongSide] / longSide;
  return CGSizeMake(MAX(1, floor(size.width * scale)), MAX(1, floor(size.height * scale)));
}

// One source of truth with the ink sampler: it measures the region this rect
// puts on screen, so the two must not drift apart.
+ (CGRect)aspectFillRectForContentSize:(CGSize)contentSize viewSize:(CGSize)viewSize {
  NSArray *rect = [DBUiTheme aspectFillDrawRectForImageWidth:contentSize.width
                                                 imageHeight:contentSize.height
                                                   viewWidth:viewSize.width
                                                  viewHeight:viewSize.height];
  return CGRectMake((CGFloat)[[rect objectAtIndex:0] doubleValue],
                    (CGFloat)[[rect objectAtIndex:1] doubleValue],
                    (CGFloat)[[rect objectAtIndex:2] doubleValue],
                    (CGFloat)[[rect objectAtIndex:3] doubleValue]);
}

+ (BOOL)overlay:(NSDictionary *)overlay
       intoRed:(CGFloat *)red green:(CGFloat *)green blue:(CGFloat *)blue
         alpha:(CGFloat *)alpha {
  CGFloat r = 0, g = 0, b = 0, a = [self darkeningAlpha];
  if ([overlay isKindOfClass:[NSDictionary class]]) {
    id enabled = [overlay objectForKey:@"enabled"];
    if ([enabled isKindOfClass:[NSNumber class]] && ![(NSNumber *)enabled boolValue])
      return NO;
    id opacity = [overlay objectForKey:@"opacity"];
    if ([opacity isKindOfClass:[NSNumber class]]) {
      double percent = [(NSNumber *)opacity doubleValue];
      a = (CGFloat)(percent < 0 ? 0 : (percent > 100 ? 1 : percent / 100.0));
    }
    DBRgb rgb;
    id color = [overlay objectForKey:@"color"];
    if ([color isKindOfClass:[NSString class]] && [DBUiTheme parseHex:color into:&rgb]) {
      r = (CGFloat)rgb.r;
      g = (CGFloat)rgb.g;
      b = (CGFloat)rgb.b;
    }
  }
  // A zero-opacity overlay is the same as no overlay; drawing it would cost a
  // full-bitmap fill for nothing.
  if (a <= 0) return NO;
  if (red) *red = r;
  if (green) *green = g;
  if (blue) *blue = b;
  if (alpha) *alpha = a;
  return YES;
}

+ (CGImageRef)newBackdropFromImage:(CGImageRef)source viewSize:(CGSize)viewSize {
  return [self newBackdropFromImage:source viewSize:viewSize overlay:nil];
}

+ (CGImageRef)newBackdropFromImage:(CGImageRef)source
                          viewSize:(CGSize)viewSize
                           overlay:(NSDictionary *)overlay {
  if (source == NULL || viewSize.width <= 0 || viewSize.height <= 0) return NULL;
  CGSize prepared = [self preparedSizeForViewSize:viewSize];
  size_t width = (size_t)prepared.width;
  size_t height = (size_t)prepared.height;
  if (width == 0 || height == 0) return NULL;

  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  // Opaque: the picture covers the whole bitmap and nothing behind it shows.
  CGContextRef ctx = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                           (CGBitmapInfo)kCGImageAlphaNoneSkipFirst);
  CGColorSpaceRelease(space);
  if (ctx == NULL) return NULL;

  CGSize sourceSize = CGSizeMake((CGFloat)CGImageGetWidth(source),
                                 (CGFloat)CGImageGetHeight(source));
  CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
  CGContextDrawImage(ctx, [self aspectFillRectForContentSize:sourceSize viewSize:prepared],
                     source);
  // The scrim goes over the picture, in the same context, before the bitmap is
  // read back: an alpha-blended fill, never a copy, or it would paint flat
  // colour over everything instead of tinting it. An overlay an administrator
  // turned off is simply not drawn.
  CGFloat red = 0, green = 0, blue = 0, alpha = 0;
  if ([self overlay:overlay intoRed:&red green:&green blue:&blue alpha:&alpha]) {
    CGContextSetBlendMode(ctx, kCGBlendModeNormal);
    CGContextSetRGBFillColor(ctx, red, green, blue, alpha);
    CGContextFillRect(ctx, CGRectMake(0, 0, prepared.width, prepared.height));
  }

  CGImageRef out = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  return out;
}

+ (CGFloat)meanLuminanceOfImage:(CGImageRef)image {
  if (image == NULL) return 0;
  size_t width = CGImageGetWidth(image);
  size_t height = CGImageGetHeight(image);
  if (width == 0 || height == 0) return 0;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  size_t stride = width * 4;
  unsigned char *pixels = (unsigned char *)calloc(height * stride, 1);
  if (pixels == NULL) {
    CGColorSpaceRelease(space);
    return 0;
  }
  CGContextRef ctx = CGBitmapContextCreate(pixels, width, height, 8, stride, space,
                                           (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
  CGColorSpaceRelease(space);
  if (ctx == NULL) {
    free(pixels);
    return 0;
  }
  CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);
  CGContextRelease(ctx);
  double total = 0;
  for (size_t y = 0; y < height; y++) {
    const unsigned char *row = pixels + y * stride;
    for (size_t x = 0; x < width; x++) {
      const unsigned char *p = row + x * 4;
      total += (0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]) / 255.0;
    }
  }
  free(pixels);
  return (CGFloat)(total / (double)(width * height));
}

@end
