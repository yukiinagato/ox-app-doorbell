#import "DBIconAsset.h"

@implementation DBIconAsset

+ (NSMutableDictionary *)cache {
  static NSMutableDictionary *cache = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [[NSMutableDictionary alloc] init]; });
  return cache;
}

// The bundle keeps the icons flat beside the other resources; the icons/
// sub-path is tried too so a future packaging change does not silently drop
// every glyph.
+ (NSString *)pathForName:(NSString *)name suffix:(NSString *)suffix {
  NSString *base = [NSString stringWithFormat:@"ic_tabler_%@%@", name, suffix];
  NSString *path = [[NSBundle mainBundle] pathForResource:base ofType:@"png"];
  if (path == nil)
    path = [[NSBundle mainBundle] pathForResource:base ofType:@"png" inDirectory:@"icons"];
  return path;
}

+ (UIImage *)imageNamed:(NSString *)name {
  if ([name length] == 0) return nil;
  CGFloat screenScale = 1;
  if ([[UIScreen mainScreen] respondsToSelector:@selector(scale)])
    screenScale = [[UIScreen mainScreen] scale];
  // Prefer the scale this screen actually is, then accept the other rather
  // than showing nothing.
  NSArray *order = screenScale >= 2 ? @[ @"@2x", @"@1x" ] : @[ @"@1x", @"@2x" ];
  for (NSString *suffix in order) {
    NSString *path = [self pathForName:name suffix:suffix];
    if (path == nil) continue;
    UIImage *raw = [UIImage imageWithContentsOfFile:path];
    if (raw == nil || raw.CGImage == NULL) continue;
    CGFloat scale = [suffix isEqualToString:@"@2x"] ? 2 : 1;
    if (scale == 1) return raw;
    return [UIImage imageWithCGImage:raw.CGImage scale:scale
                         orientation:UIImageOrientationUp];
  }
  return nil;
}

+ (UIImage *)tintedImageNamed:(NSString *)name color:(UIColor *)ink size:(CGSize)size {
  if ([name length] == 0 || ink == nil || size.width <= 0 || size.height <= 0) return nil;
  NSString *key = [NSString stringWithFormat:@"%@|%@|%.0fx%.0f", name,
                   [ink description] ?: @"", size.width, size.height];
  @synchronized([self cache]) {
    UIImage *hit = [[self cache] objectForKey:key];
    if (hit != nil) return hit;
  }
  UIImage *icon = [self imageNamed:name];
  if (icon == nil || icon.CGImage == NULL) return nil;

  UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  if (ctx == NULL) {
    UIGraphicsEndImageContext();
    return nil;
  }
  CGRect rect = CGRectMake(0, 0, size.width, size.height);
  // CGContextClipToMask reads the image bottom-up, so the space is flipped for
  // the clip and the fill together.
  CGContextTranslateCTM(ctx, 0, size.height);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextClipToMask(ctx, rect, icon.CGImage);
  CGContextSetFillColorWithColor(ctx, ink.CGColor);
  CGContextFillRect(ctx, rect);
  UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  if (out == nil) return nil;
  @synchronized([self cache]) {
    NSMutableDictionary *cache = [self cache];
    // A handful of icons in a handful of inks; more than that is a leak.
    if ([cache count] > 24) [cache removeAllObjects];
    [cache setObject:out forKey:key];
  }
  return out;
}

@end
