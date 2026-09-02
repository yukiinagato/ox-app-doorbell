#import "DBWidgets.h"

#import "../Core/DBTexts.h"
#import "../Core/DBUiTheme.h"
#import "../Media/DBQrCode.h"

UIColor *DBColorFromHex(NSString *hex, UIColor *fallback) {
  DBRgb rgb;
  if (![DBUiTheme parseHex:hex into:&rgb]) return fallback;
  return [UIColor colorWithRed:(CGFloat)rgb.r green:(CGFloat)rgb.g blue:(CGFloat)rgb.b alpha:1];
}

// Where an aspect-filled picture lands in a view of the given size.
static CGRect DBAspectFitRectForFill(CGSize contentSize, CGSize viewSize) {
  NSArray *rect = [DBUiTheme aspectFillDrawRectForImageWidth:contentSize.width
                                                imageHeight:contentSize.height
                                                  viewWidth:viewSize.width
                                                 viewHeight:viewSize.height];
  return CGRectMake((CGFloat)[[rect objectAtIndex:0] doubleValue],
                    (CGFloat)[[rect objectAtIndex:1] doubleValue],
                    (CGFloat)[[rect objectAtIndex:2] doubleValue],
                    (CGFloat)[[rect objectAtIndex:3] doubleValue]);
}

CGRect DBAspectFitRect(CGRect available, CGSize contentSize) {
  NSArray *rect = [DBUiTheme aspectFitRectForContentWidth:contentSize.width
                                            contentHeight:contentSize.height
                                           availableWidth:available.size.width
                                          availableHeight:available.size.height];
  return CGRectMake(available.origin.x + (CGFloat)[[rect objectAtIndex:0] doubleValue],
                    available.origin.y + (CGFloat)[[rect objectAtIndex:1] doubleValue],
                    (CGFloat)[[rect objectAtIndex:2] doubleValue],
                    (CGFloat)[[rect objectAtIndex:3] doubleValue]);
}

NSString *DBHexFromColor(UIColor *color) {
  if (color == nil) return nil;
  CGColorRef ref = color.CGColor;
  size_t count = CGColorGetNumberOfComponents(ref);
  const CGFloat *parts = CGColorGetComponents(ref);
  if (parts == NULL) return nil;
  DBRgb rgb;
  if (count >= 4) {
    rgb.r = parts[0];
    rgb.g = parts[1];
    rgb.b = parts[2];
  } else if (count >= 2) {
    rgb.r = rgb.g = rgb.b = parts[0];
  } else {
    return nil;
  }
  return [DBUiTheme hexFromRgb:rgb];
}

#pragma mark - theme backdrop

@implementation DBThemeBackdrop

+ (CGFloat)darkeningAlpha { return 0.45; }

+ (NSMutableDictionary *)cache {
  static NSMutableDictionary *cache = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [[NSMutableDictionary alloc] init]; });
  return cache;
}

+ (NSString *)cacheKeyForKey:(NSString *)key size:(CGSize)size {
  return [NSString stringWithFormat:@"%@@%.0fx%.0f", key ?: @"", size.width, size.height];
}

+ (UIImage *)cachedBackdropForKey:(NSString *)key size:(CGSize)size {
  @synchronized([self cache]) {
    return [[self cache] objectForKey:[self cacheKeyForKey:key size:size]];
  }
}

+ (UIImage *)backdropForData:(NSData *)data key:(NSString *)key size:(CGSize)size {
  if (size.width <= 0 || size.height <= 0) return nil;
  UIImage *cached = [self cachedBackdropForKey:key size:size];
  if (cached != nil) return cached;
  UIImage *source = data ? [UIImage imageWithData:data] : nil;
  if (source == nil || source.size.width <= 0 || source.size.height <= 0) return nil;

  // One draw at panel size, scale 1: the iPad 1 is not a Retina device and a
  // 2x context would quadruple the texture for nothing.
  UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
  CGRect fill = DBAspectFitRectForFill(source.size, size);
  [source drawInRect:fill];
  [[UIColor colorWithWhite:0 alpha:[self darkeningAlpha]] set];
  UIRectFillUsingBlendMode(CGRectMake(0, 0, size.width, size.height), kCGBlendModeNormal);
  UIImage *prepared = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  if (prepared == nil) return nil;
  @synchronized([self cache]) {
    NSMutableDictionary *cache = [self cache];
    // A panel has one picture and at most two orientations; anything more is a
    // leak, not a cache.
    if ([cache count] > 4) [cache removeAllObjects];
    [cache setObject:prepared forKey:[self cacheKeyForKey:key size:size]];
  }
  return prepared;
}

@end

#pragma mark - background sampler

// 64 square is enough resolution for a caption-sized region to land on several
// pixels while staying a 16 KB buffer, which an SGX535 can build once per theme
// image without anyone noticing.
static const NSInteger kProxyEdge = 64;

@implementation DBBackgroundSampler {
  NSData *_pixels;   // RGBA, kProxyEdge x kProxyEdge, view-space.
  CGSize _viewSize;
}

@synthesize viewSize = _viewSize;

+ (DBBackgroundSampler *)samplerWithImage:(UIImage *)image viewSize:(CGSize)viewSize {
  if (image == nil || image.CGImage == NULL) return nil;
  if (viewSize.width <= 0 || viewSize.height <= 0) return nil;
  size_t edge = (size_t)kProxyEdge;
  size_t bytesPerRow = edge * 4;
  void *buffer = calloc(edge * bytesPerRow, 1);
  if (buffer == NULL) return nil;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(buffer, edge, edge, 8, bytesPerRow, space,
                                           (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);
  if (ctx == NULL) {
    free(buffer);
    return nil;
  }
  // The proxy is the view, not the image: the image is placed into it with the
  // same aspect-fill mapping the theme image view uses, so proxy coordinates
  // and view coordinates are the same space up to a constant scale.
  NSArray *draw = [DBUiTheme aspectFillDrawRectForImageWidth:image.size.width
                                                 imageHeight:image.size.height
                                                   viewWidth:viewSize.width
                                                  viewHeight:viewSize.height];
  double scaleX = (double)edge / viewSize.width;
  double scaleY = (double)edge / viewSize.height;
  CGRect target = CGRectMake((CGFloat)([[draw objectAtIndex:0] doubleValue] * scaleX),
                             (CGFloat)([[draw objectAtIndex:1] doubleValue] * scaleY),
                             (CGFloat)([[draw objectAtIndex:2] doubleValue] * scaleX),
                             (CGFloat)([[draw objectAtIndex:3] doubleValue] * scaleY));
  // CoreGraphics draws bottom-up; flip so proxy rows match view rows.
  CGContextTranslateCTM(ctx, 0, (CGFloat)edge);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextDrawImage(ctx, target, image.CGImage);
  CGContextRelease(ctx);

  DBBackgroundSampler *sampler = [[DBBackgroundSampler alloc] init];
  sampler->_pixels = [NSData dataWithBytesNoCopy:buffer length:edge * bytesPerRow
                                    freeWhenDone:YES];
  sampler->_viewSize = viewSize;
  return sampler;
}

- (NSDictionary *)sampleInViewRect:(CGRect)rect {
  if (_pixels == nil) return nil;
  NSArray *box = [DBUiTheme samplePixelRectForViewX:rect.origin.x
                                                  y:rect.origin.y
                                              width:rect.size.width
                                             height:rect.size.height
                                          viewWidth:_viewSize.width
                                         viewHeight:_viewSize.height
                                         proxyWidth:kProxyEdge
                                        proxyHeight:kProxyEdge];
  NSInteger x = [[box objectAtIndex:0] integerValue];
  NSInteger y = [[box objectAtIndex:1] integerValue];
  NSInteger width = [[box objectAtIndex:2] integerValue];
  NSInteger height = [[box objectAtIndex:3] integerValue];
  if (width <= 0 || height <= 0) return nil;

  // The covered area is reduced to at most 16x16 samples, as the contrast rule
  // specifies, by striding rather than by allocating another bitmap.
  NSInteger maxEdge = [DBUiTheme maximumSampleEdge];
  NSInteger strideX = (width + maxEdge - 1) / maxEdge;
  NSInteger strideY = (height + maxEdge - 1) / maxEdge;
  if (strideX < 1) strideX = 1;
  if (strideY < 1) strideY = 1;

  const unsigned char *pixels = (const unsigned char *)[_pixels bytes];
  double red = 0, green = 0, blue = 0;
  NSInteger samples = 0;
  double darkestLuminance = 2.0, lightestLuminance = -1.0;
  DBRgb darkest, lightest;
  darkest.r = darkest.g = darkest.b = 0;
  lightest.r = lightest.g = lightest.b = 0;
  for (NSInteger row = y; row < y + height; row += strideY) {
    for (NSInteger column = x; column < x + width; column += strideX) {
      const unsigned char *pixel = pixels + (row * kProxyEdge + column) * 4;
      red += pixel[0];
      green += pixel[1];
      blue += pixel[2];
      samples++;
      DBRgb patch;
      patch.r = pixel[0] / 255.0;
      patch.g = pixel[1] / 255.0;
      patch.b = pixel[2] / 255.0;
      // The extremes are tracked here, in the one pass that already reads
      // every patch, so the shadow test costs nothing extra.
      double luminance = [DBUiTheme relativeLuminance:patch];
      if (luminance < darkestLuminance) {
        darkestLuminance = luminance;
        darkest = patch;
      }
      if (luminance > lightestLuminance) {
        lightestLuminance = luminance;
        lightest = patch;
      }
    }
  }
  if (samples == 0) return nil;
  DBRgb average;
  average.r = red / (samples * 255.0);
  average.g = green / (samples * 255.0);
  average.b = blue / (samples * 255.0);
  return [NSDictionary dictionaryWithObjectsAndKeys:
      [DBUiTheme hexFromRgb:average], @"average",
      [DBUiTheme hexFromRgb:darkest], @"darkest",
      [DBUiTheme hexFromRgb:lightest], @"lightest", nil];
}

- (NSString *)averageHexInViewRect:(CGRect)rect {
  return [[self sampleInViewRect:rect] objectForKey:@"average"];
}

- (NSString *)averageHex {
  return [self averageHexInViewRect:CGRectMake(0, 0, _viewSize.width, _viewSize.height)];
}

@end

#pragma mark - palette

@implementation DBUiPalette {
  NSDictionary *_config;
  NSDictionary *_display;
  NSString *_deviceId;
  NSString *_mode;
  NSString *_surfaceHex;
  DBBackgroundSampler *_sampler;
  BOOL _usesThemeBackground;
  NSString *_requestedBackgroundHex;  // What the caller said its ground is.
}

@synthesize mode = _mode;
@synthesize surfaceHex = _surfaceHex;

+ (DBUiPalette *)paletteForConfig:(NSDictionary *)config
                         deviceId:(NSString *)deviceId
                          display:(NSDictionary *)display
                    backgroundHex:(NSString *)backgroundHex
                      minuteOfDay:(NSInteger)minuteOfDay {
  DBUiPalette *palette = [[DBUiPalette alloc] init];
  palette->_usesThemeBackground = YES;
  palette->_config = config;
  palette->_display = display;
  palette->_deviceId = [deviceId copy] ?: @"";
  palette->_mode = [[DBUiTheme appearanceModeForConfig:config deviceId:deviceId
                                               display:display
                                           minuteOfDay:minuteOfDay] copy];
  // Core measured the effective background, including averaging a theme image;
  // a caller's own sample is only used when core published none.
  NSString *effective = [DBUiTheme autoBackgroundHexInDisplay:display];
  DBRgb probe;
  palette->_requestedBackgroundHex = [DBUiTheme parseHex:backgroundHex into:&probe]
      ? [backgroundHex copy] : nil;
  if ([effective length] > 0)
    palette->_surfaceHex = [effective copy];
  else
    palette->_surfaceHex = palette->_requestedBackgroundHex
        ?: [[DBUiTheme surfaceHexForMode:palette->_mode] copy];
  return palette;
}

// Whether the panel's own chrome sits on a light ground. This follows the
// measured surface, not the configured appearance: with a light theme picture
// behind them, chips drawn as "white at 8 %" and muted grey text disappear,
// which is exactly what the first backdrop build showed on the device. The
// appearance schedule still decides the tokens when there is no picture,
// because then the surface is that mode's own colour.
- (BOOL)isLight {
  return [[DBUiTheme inkModeForBackgroundHex:_surfaceHex fallbackMode:_mode]
      isEqualToString:@"dark"];
}

// The mode the chrome should use, as a token name.
- (NSString *)chromeMode {
  return [self isLight] ? @"light" : @"dark";
}

- (UIColor *)surface {
  return DBColorFromHex(_surfaceHex, [UIColor blackColor]);
}

- (UIColor *)elevated {
  return [self isLight] ? [UIColor colorWithWhite:1 alpha:0.72]
                        : [UIColor colorWithWhite:0 alpha:0.42];
}

- (UIColor *)separator {
  return [self isLight] ? [UIColor colorWithWhite:0 alpha:0.14]
                        : [UIColor colorWithWhite:1 alpha:0.16];
}

- (UIColor *)ink {
  return DBColorFromHex([DBUiTheme inkHexForMode:[self chromeMode]], [UIColor whiteColor]);
}

- (UIColor *)mutedInk {
  return DBColorFromHex([DBUiTheme mutedInkHexForMode:[self chromeMode]],
                        [UIColor colorWithWhite:0.6 alpha:1]);
}

- (UIColor *)accent {
  NSString *hex = [DBUiTheme callButtonHexForConfig:_config deviceId:_deviceId
                                            display:_display backgroundHex:_surfaceHex];
  return DBColorFromHex(hex, [UIColor colorWithRed:0.12 green:0.44 blue:0.70 alpha:1]);
}

- (UIColor *)accentInk {
  return DBColorFromHex([DBUiTheme callButtonInkHexForConfig:_config deviceId:_deviceId
                                                     display:_display
                                               backgroundHex:_surfaceHex],
                        [UIColor whiteColor]);
}

- (UIColor *)danger {
  return [UIColor colorWithRed:0.78 green:0.08 blue:0.06 alpha:1];
}

- (UIColor *)dangerInk {
  return [UIColor whiteColor];
}

- (UIColor *)notice {
  return [self isLight] ? [UIColor colorWithRed:0.98 green:0.86 blue:0.55 alpha:1]
                        : [UIColor colorWithRed:0.62 green:0.47 blue:0.10 alpha:1];
}

// A chip needs a real plate over a picture: an 8 % wash vanishes on a light
// wallpaper and reads as nothing at all.
- (UIColor *)chipPlate {
  return [self isLight] ? [UIColor colorWithWhite:1 alpha:0.82]
                        : [UIColor colorWithWhite:0 alpha:0.55];
}

- (UIColor *)noticeInk {
  return [self isLight] ? [UIColor colorWithRed:0.20 green:0.14 blue:0.02 alpha:1]
                        : [UIColor whiteColor];
}

- (void)setBackgroundSampler:(DBBackgroundSampler *)sampler {
  _sampler = sampler;
}

- (void)setUsesThemeBackground:(BOOL)usesThemeBackground {
  _usesThemeBackground = usesThemeBackground;
  // Core's measured theme background describes the wallpaper, not this
  // screen's own chrome. A screen that paints its own ground says so, and its
  // colour is then what everything is measured against -- otherwise the
  // incoming page inherited a light wallpaper's dark ink onto black video
  // chrome, which is exactly how the call title came out unreadable.
  if (!usesThemeBackground) {
    _surfaceHex = _requestedBackgroundHex
        ?: [[DBUiTheme surfaceHexForMode:_mode] copy];
  }
}

// A sampler built for a different view size maps region frames onto the wrong
// pixels, which is exactly what a rotation produces for one layout pass. It is
// ignored until the rebuild for the new size arrives.
- (DBBackgroundSampler *)samplerForViewSize:(CGSize)viewSize {
  if (_sampler == nil) return nil;
  if (viewSize.width <= 0 || viewSize.height <= 0) return _sampler;
  return CGSizeEqualToSize(_sampler.viewSize, viewSize) ? _sampler : nil;
}

- (NSString *)inkHexForRegion:(NSString *)region {
  if (!_usesThemeBackground) {
    // This screen's ground is its own chrome, so only an administrator's
    // override outranks the measurement of that colour.
    NSString *override = [DBUiTheme adminInkOverrideHexForRegion:region config:_config
                                                        deviceId:_deviceId display:_display];
    if ([override length] > 0) return override;
    DBRgb rgb;
    if ([DBUiTheme parseHex:_surfaceHex into:&rgb])
      return [DBUiTheme inkHexForSampledLuminance:[DBUiTheme relativeLuminance:rgb]];
    return [DBUiTheme inkHexForMode:_mode];
  }
  return [DBUiTheme inkHexForRegion:region config:_config deviceId:_deviceId
                            display:_display backgroundHex:_surfaceHex appearanceMode:_mode];
}

- (UIColor *)inkForRegion:(NSString *)region {
  return DBColorFromHex([self inkHexForRegion:region], [self ink]);
}

- (BOOL)needsShadowForRegion:(NSString *)region {
  return [DBUiTheme needsInkShadowForInk:[self inkHexForRegion:region]
                              background:_surfaceHex];
}

// The pixels actually behind one region, or the flat background when there is
// no theme image to sample.
// The region's measured background: its average plus the extremes of the same
// sample. Without a sampler the flat surface is all three.
- (NSDictionary *)backgroundSampleForRegion:(NSString *)region frame:(CGRect)frame
                                   viewSize:(CGSize)viewSize {
  (void)region;
  DBBackgroundSampler *sampler = [self samplerForViewSize:viewSize];
  NSDictionary *sample = sampler ? [sampler sampleInViewRect:frame] : nil;
  if ([[sample objectForKey:@"average"] length] > 0) return sample;
  return [NSDictionary dictionaryWithObjectsAndKeys:
      _surfaceHex ?: @"", @"average", _surfaceHex ?: @"", @"darkest",
      _surfaceHex ?: @"", @"lightest", nil];
}

- (NSString *)backgroundHexForRegion:(NSString *)region frame:(CGRect)frame
                            viewSize:(CGSize)viewSize {
  return [[self backgroundSampleForRegion:region frame:frame viewSize:viewSize]
      objectForKey:@"average"];
}

- (NSString *)inkHexForRegion:(NSString *)region frame:(CGRect)frame
                     viewSize:(CGSize)viewSize {
  // 1. An administrator's override, device before cluster, always wins.
  NSString *override = [DBUiTheme adminInkOverrideHexForRegion:region config:_config
                                                      deviceId:_deviceId display:_display];
  if ([override length] > 0) return override;
  // 2. Over a theme image, refine locally: core averaged the whole picture and
  //    says so, which is how a caption over a light corner came back white.
  DBBackgroundSampler *sampler = [self samplerForViewSize:viewSize];
  if (sampler != nil) {
    NSString *background = [sampler averageHexInViewRect:frame];
    DBRgb rgb;
    if ([background length] > 0 && [DBUiTheme parseHex:background into:&rgb])
      return [DBUiTheme inkHexForSampledLuminance:[DBUiTheme relativeLuminance:rgb]];
  }
  // 3. Otherwise core's published decision, which is exact for a flat colour.
  return [self inkHexForRegion:region];
}

- (NSString *)inkHexForRegion:(NSString *)region frame:(CGRect)frame {
  return [self inkHexForRegion:region frame:frame viewSize:CGSizeZero];
}

- (UIColor *)inkForRegion:(NSString *)region frame:(CGRect)frame {
  return DBColorFromHex([self inkHexForRegion:region frame:frame], [self ink]);
}

- (BOOL)needsShadowForRegion:(NSString *)region frame:(CGRect)frame {
  NSDictionary *sample = [self backgroundSampleForRegion:region frame:frame
                                                viewSize:CGSizeZero];
  return [DBUiTheme needsInkShadowForInk:[self inkHexForRegion:region frame:frame]
                              background:[sample objectForKey:@"average"]
                                 darkest:[sample objectForKey:@"darkest"]
                                lightest:[sample objectForKey:@"lightest"]];
}

// One call per label: the ink measured behind its own frame, plus the 40 %
// opposite-ink shadow only when the pair is still under the AA threshold.
- (void)applyInkToLabel:(UILabel *)label region:(NSString *)region {
  if (label == nil) return;
  CGRect frame = label.frame;
  // The sampler is keyed to the view size it was built for, so a rotation that
  // has not been resampled yet falls back instead of reading the wrong pixels.
  CGSize viewSize = label.superview ? label.superview.bounds.size : CGSizeZero;
  NSString *ink = [self inkHexForRegion:region frame:frame viewSize:viewSize];
  label.textColor = DBColorFromHex(ink, [self ink]);
  NSDictionary *sample = [self backgroundSampleForRegion:region frame:frame viewSize:viewSize];
  // The ink follows the average; the shadow follows the worst patch, so a line
  // crossing a pale wall and a dark jacket keeps its outline over the jacket.
  if (![DBUiTheme needsInkShadowForInk:ink
                            background:[sample objectForKey:@"average"]
                               darkest:[sample objectForKey:@"darkest"]
                              lightest:[sample objectForKey:@"lightest"]]) {
    label.shadowColor = nil;
    label.shadowOffset = CGSizeZero;
    return;
  }
  DBRgb rgb;
  BOOL inkIsDark = [DBUiTheme parseHex:ink into:&rgb] &&
      [DBUiTheme relativeLuminance:rgb] < 0.5;
  label.shadowColor = [(inkIsDark ? [UIColor whiteColor] : [UIColor blackColor])
      colorWithAlphaComponent:(CGFloat)[DBUiTheme inkShadowAlpha]];
  label.shadowOffset = CGSizeMake(0, 1);
}

+ (NSString *)averageHexForImage:(UIImage *)image {
  if (image == nil || image.CGImage == NULL) return nil;
  // 16x16 is the sampling budget the spec allows; anything larger is wasted
  // work on an SGX535 and the average is identical to two decimal places.
  const size_t side = 16;
  size_t bpr = side * 4;
  void *buffer = calloc(side * bpr, 1);
  if (buffer == NULL) return nil;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(buffer, side, side, 8, bpr, space,
                                           (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);
  if (ctx == NULL) {
    free(buffer);
    return nil;
  }
  CGContextDrawImage(ctx, CGRectMake(0, 0, side, side), image.CGImage);
  CGContextRelease(ctx);
  unsigned char *pixels = (unsigned char *)buffer;
  double r = 0, g = 0, b = 0;
  for (size_t i = 0; i < side * side; i++) {
    r += pixels[i * 4 + 0];
    g += pixels[i * 4 + 1];
    b += pixels[i * 4 + 2];
  }
  free(buffer);
  double count = (double)(side * side) * 255.0;
  DBRgb average;
  average.r = r / count;
  average.g = g / count;
  average.b = b / count;
  return [DBUiTheme hexFromRgb:average];
}

@end

#pragma mark - padded label

@implementation DBFleetCounter {
  NSString *_value;
  UIColor *_ink;
  UIColor *_fill;
}

@synthesize glyph = _glyph, value = _value, ink = _ink, fill = _fill;

static const CGFloat kFleetGlyphSide = 20;
static const CGFloat kFleetGlyphGap = 6;
static const CGFloat kFleetPadX = 9;

- (id)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.layer.cornerRadius = 10;
    self.isAccessibilityElement = YES;
    _value = @"";
    _ink = [UIColor blackColor];
    _fill = [UIColor clearColor];
  }
  return self;
}

- (UIFont *)valueFont {
  return [UIFont boldSystemFontOfSize:18];
}

- (void)setGlyph:(DBFleetGlyph)glyph {
  if (_glyph == glyph) return;
  _glyph = glyph;
  [self setNeedsDisplay];
}

- (void)setValue:(NSString *)value {
  NSString *next = value ?: @"";
  if ([_value isEqualToString:next]) return;
  _value = [next copy];
  [self setNeedsDisplay];
}

- (void)setInk:(UIColor *)ink {
  _ink = ink;
  [self setNeedsDisplay];
}

- (void)setFill:(UIColor *)fill {
  _fill = fill;
  self.backgroundColor = fill;
}

- (CGFloat)widthThatFits {
  CGSize text = [_value sizeWithFont:[self valueFont]];
  return kFleetPadX * 2 + kFleetGlyphSide + kFleetGlyphGap + ceilf((float)text.width);
}

// Three glyphs, all drawn on a 20x20 box in the current ink so they follow the
// palette exactly like the text beside them.
- (void)drawGlyphInRect:(CGRect)box {
  CGFloat unit = box.size.width / 20.0;
  CGFloat line = MAX((CGFloat)1.5, 1.6f * unit);
  [_ink setStroke];
  [_ink setFill];
  if (_glyph == DBFleetGlyphCluster) {
    // Three nodes joined by links: the cluster as a whole.
    CGFloat radius = 2.8f * unit;
    CGPoint nodes[3] = {
      CGPointMake(box.origin.x + 10 * unit, box.origin.y + 4 * unit),
      CGPointMake(box.origin.x + 4 * unit, box.origin.y + 15 * unit),
      CGPointMake(box.origin.x + 16 * unit, box.origin.y + 15 * unit),
    };
    UIBezierPath *links = [UIBezierPath bezierPath];
    for (int i = 0; i < 3; i++) {
      [links moveToPoint:nodes[i]];
      [links addLineToPoint:nodes[(i + 1) % 3]];
    }
    links.lineWidth = line;
    [links stroke];
    for (int i = 0; i < 3; i++) {
      UIBezierPath *node = [UIBezierPath bezierPathWithOvalInRect:
          CGRectMake(nodes[i].x - radius, nodes[i].y - radius, radius * 2, radius * 2)];
      [node fill];
    }
    return;
  }
  if (_glyph == DBFleetGlyphDoorStation) {
    // A doorway with a call button: the outdoor station.
    UIBezierPath *door = [UIBezierPath bezierPathWithRoundedRect:
        CGRectMake(box.origin.x + 4 * unit, box.origin.y + 2 * unit, 12 * unit, 16 * unit)
                                                   cornerRadius:2 * unit];
    door.lineWidth = line;
    [door stroke];
    UIBezierPath *button = [UIBezierPath bezierPathWithOvalInRect:
        CGRectMake(box.origin.x + 11.4f * unit, box.origin.y + 8.4f * unit,
                   3.2f * unit, 3.2f * unit)];
    [button fill];
    return;
  }
  // A wall panel: a screen with a speaker slot under it.
  UIBezierPath *panel = [UIBezierPath bezierPathWithRoundedRect:
      CGRectMake(box.origin.x + 2 * unit, box.origin.y + 4 * unit, 16 * unit, 12 * unit)
                                                  cornerRadius:2 * unit];
  panel.lineWidth = line;
  [panel stroke];
  UIBezierPath *slot = [UIBezierPath bezierPathWithRoundedRect:
      CGRectMake(box.origin.x + 6.5f * unit, box.origin.y + 12 * unit, 7 * unit, 1.8f * unit)
                                                 cornerRadius:0.9f * unit];
  [slot fill];
}

- (void)drawRect:(CGRect)rect {
  (void)rect;
  CGSize size = self.bounds.size;
  CGFloat glyphY = floorf((float)((size.height - kFleetGlyphSide) / 2));
  [self drawGlyphInRect:CGRectMake(kFleetPadX, glyphY, kFleetGlyphSide, kFleetGlyphSide)];
  UIFont *font = [self valueFont];
  CGSize text = [_value sizeWithFont:font];
  [_ink set];
  [_value drawAtPoint:CGPointMake(kFleetPadX + kFleetGlyphSide + kFleetGlyphGap,
                                  floorf((float)((size.height - text.height) / 2)))
             withFont:font];
}

@end

@implementation DBPillLabel

@synthesize contentInsets = _contentInsets;

- (id)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _contentInsets = UIEdgeInsetsMake((CGFloat)[DBUiTheme pillPaddingVertical],
                                      (CGFloat)[DBUiTheme pillPaddingHorizontal],
                                      (CGFloat)[DBUiTheme pillPaddingVertical],
                                      (CGFloat)[DBUiTheme pillPaddingHorizontal]);
    self.layer.cornerRadius = (CGFloat)[DBUiTheme pillRadius];
    self.clipsToBounds = YES;
  }
  return self;
}

- (void)drawTextInRect:(CGRect)rect {
  [super drawTextInRect:UIEdgeInsetsInsetRect(rect, _contentInsets)];
}

- (CGSize)sizeThatFits:(CGSize)size {
  CGFloat horizontal = _contentInsets.left + _contentInsets.right;
  CGFloat vertical = _contentInsets.top + _contentInsets.bottom;
  CGSize inner = [super sizeThatFits:CGSizeMake(MAX(0, size.width - horizontal),
                                                MAX(0, size.height - vertical))];
  return CGSizeMake(inner.width + horizontal, inner.height + vertical);
}

@end

#pragma mark - two-part button

@implementation DBTwoPartButton {
  UILabel *_secondary;
  CGFloat _secondaryHeight;
}

- (id)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    _secondary = [[UILabel alloc] init];
    _secondary.backgroundColor = [UIColor clearColor];
    _secondary.textAlignment = NSTextAlignmentCenter;
    _secondary.hidden = YES;
    [self addSubview:_secondary];
  }
  return self;
}

- (void)setTwoPartTitle:(NSString *)title {
  NSArray *parts = [DBUiTheme labelPartsFor:title];
  [self setTitle:[parts objectAtIndex:0] forState:UIControlStateNormal];
  NSString *secondary = [parts objectAtIndex:1];
  _secondary.text = secondary;
  _secondary.hidden = ([secondary length] == 0);
  [self setNeedsLayout];
}

- (void)setPrimaryColor:(UIColor *)primary secondaryColor:(UIColor *)secondary {
  [self setTitleColor:primary forState:UIControlStateNormal];
  _secondary.textColor = secondary;
}

- (void)layoutSubviews {
  CGFloat primarySize = self.titleLabel.font.pointSize;
  CGFloat secondarySize = MAX(11, primarySize * (CGFloat)[DBUiTheme secondaryFontScale]);
  _secondary.font = [UIFont systemFontOfSize:secondarySize];
  _secondaryHeight = _secondary.hidden ? 0 : secondarySize + 4;
  // The primary title is lifted by exactly the second line's height so the
  // pair reads as one centred block instead of overlapping.
  self.titleEdgeInsets = UIEdgeInsetsMake(-_secondaryHeight, 0, _secondaryHeight, 0);
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  _secondary.frame = CGRectMake(4, size.height / 2 + (primarySize / 2) - 2,
                                MAX(0, size.width - 8), _secondaryHeight);
}

@end

#pragma mark - SOS slider

@implementation DBSosSlider {
  DBSosSlideModel *_model;
  DBTexts *_texts;
  UIView *_track;
  UIView *_fill;
  UIView *_thumb;
  UILabel *_thumbChevron;
  UILabel *_hint;
  UILabel *_hintSecondary;
  UILabel *_countdown;
  UILabel *_cancelHint;
  NSTimer *_timer;
  CGFloat _thumbSide;
  UIColor *_danger;
  UIColor *_dangerInk;
  UIColor *_trackColor;
  UIColor *_trackInk;
}

- (id)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _model = [[DBSosSlideModel alloc] init];
    _thumbSide = 56;
    _danger = [UIColor colorWithRed:0.78 green:0.08 blue:0.06 alpha:1];
    _dangerInk = [UIColor whiteColor];
    _trackColor = [UIColor colorWithWhite:1 alpha:0.14];
    _trackInk = [UIColor whiteColor];

    _track = [[UIView alloc] init];
    _track.layer.cornerRadius = 14;
    _track.clipsToBounds = YES;
    [self addSubview:_track];

    _fill = [[UIView alloc] init];
    [_track addSubview:_fill];

    _hint = [[UILabel alloc] init];
    _hint.backgroundColor = [UIColor clearColor];
    _hint.textAlignment = NSTextAlignmentCenter;
    _hint.font = [UIFont boldSystemFontOfSize:22];
    _hint.numberOfLines = 1;
    [_track addSubview:_hint];

    // The sub-line is the deliberate second part of the label, smaller and
    // muted, exactly as on Android and the Swift shell.
    _hintSecondary = [[UILabel alloc] init];
    _hintSecondary.backgroundColor = [UIColor clearColor];
    _hintSecondary.textAlignment = NSTextAlignmentCenter;
    _hintSecondary.font = [UIFont systemFontOfSize:16];
    _hintSecondary.numberOfLines = 1;
    [_track addSubview:_hintSecondary];

    _countdown = [[UILabel alloc] init];
    _countdown.backgroundColor = [UIColor clearColor];
    _countdown.textAlignment = NSTextAlignmentCenter;
    _countdown.font = [UIFont boldSystemFontOfSize:26];
    _countdown.hidden = YES;
    [self addSubview:_countdown];

    _cancelHint = [[UILabel alloc] init];
    _cancelHint.backgroundColor = [UIColor clearColor];
    _cancelHint.textAlignment = NSTextAlignmentCenter;
    _cancelHint.font = [UIFont boldSystemFontOfSize:18];
    _cancelHint.hidden = YES;
    [self addSubview:_cancelHint];

    [self applyState];
  }
  return self;
}

- (void)dealloc {
  [_timer invalidate];
}

- (DBSosPhase)phase {
  return _model.phase;
}

- (void)applyConfig:(NSDictionary *)config texts:(DBTexts *)texts {
  [_model configureFromConfig:config];
  _texts = texts;
  [self applyState];
}

- (void)applyPalette:(DBUiPalette *)palette {
  _danger = palette.danger;
  _dangerInk = palette.dangerInk;
  _trackColor = palette.chipPlate;
  _trackInk = palette.ink;
  [self applyState];
}

- (void)reset {
  [_timer invalidate];
  _timer = nil;
  [_model reset];
  [self applyState];
}

- (void)applyState {
  BOOL counting = (_model.phase == DBSosPhaseCountdown);
  _track.backgroundColor = _trackColor;
  _fill.backgroundColor = [_danger colorWithAlphaComponent:0.55];
  _thumb.backgroundColor = _danger;
  // The label is drawn on the track; the chevron is drawn on the red knob.
  _hint.textColor = _trackInk;
  _thumbChevron.textColor = _dangerInk;
  _hintSecondary.textColor = [_trackInk colorWithAlphaComponent:0.75];
  _countdown.textColor = _dangerInk;
  _cancelHint.textColor = [_dangerInk colorWithAlphaComponent:0.85];

  // The same two-part label every shell shows: the action, then what happens.
  _hint.text = [_texts ts:@"sos.slide_label"];
  _hintSecondary.text = [_texts t:@"sos.slide_sub",
      [NSString stringWithFormat:@"%ld", (long)_model.countdownSeconds], nil];
  _hintSecondary.hidden = counting;
  _hint.hidden = counting;
  _thumb.hidden = counting;
  _countdown.hidden = !counting;
  _cancelHint.hidden = !counting;
  if (counting) {
    _track.backgroundColor = _danger;
    _countdown.text = [_texts t:@"sos.countdown",
        [NSString stringWithFormat:@"%ld", (long)_model.remainingSeconds], nil];
    _cancelHint.text = [_texts ts:@"sos.countdown_cancel"];
  }
  [self setNeedsLayout];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  _track.frame = self.bounds;
  CGFloat radius = MIN(16, size.height / 2);
  _track.layer.cornerRadius = radius;
  CGFloat inset = 5;
  CGFloat knob = MAX(40, size.height - inset * 2);
  _thumbSide = knob;
  CGFloat travel = MAX(0, size.width - knob - inset * 2);
  CGFloat x = inset + travel * (CGFloat)_model.fraction;
  _thumb.frame = CGRectMake(x, inset, knob, knob);
  _thumb.layer.cornerRadius = knob / 2;
  _thumbChevron.frame = _thumb.bounds;
  _fill.frame = CGRectMake(0, 0, x + knob / 2, size.height);

  CGFloat textX = inset + knob + 10;
  CGFloat textW = MAX(0, size.width - textX - 12);
  if (_hintSecondary.hidden || [_hintSecondary.text length] == 0) {
    _hint.frame = CGRectMake(textX, 0, textW, size.height);
  } else {
    CGFloat primary = ceilf((float)_hint.font.lineHeight) + 2;
    CGFloat secondary = ceilf((float)_hintSecondary.font.lineHeight) + 2;
    CGFloat top = MAX(2, (size.height - primary - secondary) / 2);
    _hint.frame = CGRectMake(textX, top, textW, primary);
    _hintSecondary.frame = CGRectMake(textX, top + primary, textW, secondary);
  }
  _countdown.frame = CGRectMake(8, 4, MAX(0, size.width - 16), size.height / 2);
  _cancelHint.frame = CGRectMake(8, size.height / 2, MAX(0, size.width - 16),
                                 size.height / 2 - 4);
}

- (double)fractionForTouch:(UITouch *)touch {
  CGPoint point = [touch locationInView:self];
  CGFloat travel = MAX(1, self.bounds.size.width - _thumbSide - 8);
  return (point.x - 4 - _thumbSide / 2) / travel;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
  (void)event;
  if (_model.phase == DBSosPhaseCountdown) {
    // A tap anywhere on the control cancels the countdown; core is never told.
    [_timer invalidate];
    _timer = nil;
    if ([_model cancel]) [self.delegate sosSliderDidCancel:self];
    [self applyState];
    return;
  }
  [_model beginTouch];
  [_model updateFraction:[self fractionForTouch:[touches anyObject]]];
  [self applyState];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
  (void)event;
  [_model updateFraction:[self fractionForTouch:[touches anyObject]]];
  [self setNeedsLayout];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
  (void)touches;
  (void)event;
  if (![_model endTouch]) {
    [self applyState];
    return;
  }
  if (_model.phase == DBSosPhaseFired) {
    [self applyState];
    [self.delegate sosSliderDidFire:self];
    [self reset];
    return;
  }
  [self applyState];
  [self.delegate sosSliderDidArm:self];
  [_timer invalidate];
  _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                          selector:@selector(onCountdownTick:)
                                          userInfo:nil repeats:YES];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
  (void)touches;
  (void)event;
  if (_model.phase == DBSosPhaseSliding) [_model reset];
  [self applyState];
}

- (void)onCountdownTick:(NSTimer *)timer {
  (void)timer;
  BOOL fired = [_model tick];
  [self applyState];
  if (!fired) return;
  [_timer invalidate];
  _timer = nil;
  [self.delegate sosSliderDidFire:self];
  [self reset];
}

- (void)willMoveToSuperview:(UIView *)newSuperview {
  [super willMoveToSuperview:newSuperview];
  // A screen transition must never leave a live one-second timer behind.
  if (newSuperview == nil) [self reset];
}

@end

#pragma mark - admin QR

@implementation DBAdminQrView {
  UIImageView *_image;
  UILabel *_urlLabel;
  UILabel *_caption;
  NSString *_url;
  NSInteger _generation;
}

@synthesize url = _url;

- (id)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _url = @"";
    _image = [[UIImageView alloc] init];
    _image.backgroundColor = [UIColor whiteColor];
    _image.contentMode = UIViewContentModeScaleAspectFit;
    _image.layer.cornerRadius = 6;
    _image.clipsToBounds = YES;
    _image.accessibilityIdentifier = @"admin_page_qr";
    [self addSubview:_image];

    _caption = [[UILabel alloc] init];
    _caption.backgroundColor = [UIColor clearColor];
    _caption.font = [UIFont systemFontOfSize:15];
    _caption.numberOfLines = 2;
    [self addSubview:_caption];

    _urlLabel = [[UILabel alloc] init];
    _urlLabel.backgroundColor = [UIColor clearColor];
    _urlLabel.font = [UIFont systemFontOfSize:15];
    _urlLabel.numberOfLines = 2;
    _urlLabel.lineBreakMode = NSLineBreakByCharWrapping;
    [self addSubview:_urlLabel];
  }
  return self;
}

- (void)applyPalette:(DBUiPalette *)palette {
  _caption.textColor = palette.mutedInk;
  _urlLabel.textColor = palette.ink;
}

- (void)setUrl:(NSString *)url caption:(NSString *)caption {
  _caption.text = caption ?: @"";
  if ([url length] == 0) {
    _url = @"";
    _image.image = nil;
    _urlLabel.text = @"";
    return;
  }
  _urlLabel.text = url;
  if ([_url isEqualToString:url] && _image.image != nil) return;
  _url = [url copy];
  NSInteger generation = ++_generation;
  NSString *want = [url copy];
  __weak DBAdminQrView *weakSelf = self;
  // QR generation is pure CPU work and must never run on the main thread of an
  // A4 device that is also decoding video.
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
    UIImage *code = [DBQrCode imageForString:want targetPx:160];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBAdminQrView *view = weakSelf;
      if (!view || view->_generation != generation) return;
      view->_image.image = code;
    });
  });
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  CGFloat side = MIN(size.height, MAX(56, size.width * 0.42));
  _image.frame = CGRectMake(0, (size.height - side) / 2, side, side);
  CGFloat textX = side + 10;
  CGFloat textW = MAX(0, size.width - textX);
  _caption.frame = CGRectMake(textX, (size.height - side) / 2, textW, 26);
  // The address gets the whole remaining width on one line.
  _urlLabel.frame = CGRectMake(textX, (size.height - side) / 2 + 28, textW, 24);
}

@end

#pragma mark - notice chip

@implementation DBNoticeChip {
  UIView *_dot;
}

- (id)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.layer.cornerRadius = (CGFloat)[DBUiTheme pillRadius];
    self.clipsToBounds = YES;
    self.contentEdgeInsets = UIEdgeInsetsMake((CGFloat)[DBUiTheme pillPaddingVertical],
                                              (CGFloat)[DBUiTheme pillPaddingHorizontal] + 14,
                                              (CGFloat)[DBUiTheme pillPaddingVertical],
                                              (CGFloat)[DBUiTheme pillPaddingHorizontal]);
    _dot = [[UIView alloc] init];
    _dot.layer.cornerRadius = 4;
    _dot.hidden = YES;
    _dot.userInteractionEnabled = NO;
    [self addSubview:_dot];
  }
  return self;
}

- (void)setChipTitle:(NSString *)title active:(BOOL)active {
  [self setTitle:title forState:UIControlStateNormal];
  _dot.hidden = !active;
  [self setNeedsLayout];
}

- (void)applyPalette:(DBUiPalette *)palette {
  self.backgroundColor = palette.elevated;
  [self setTitleColor:palette.ink forState:UIControlStateNormal];
  _dot.backgroundColor = palette.notice;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  _dot.frame = CGRectMake(10, (self.bounds.size.height - 8) / 2, 8, 8);
  [self bringSubviewToFront:_dot];
}

@end
