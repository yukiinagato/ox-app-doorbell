#import "DBUiTheme.h"
#import <math.h>

NSString *const DBUiRegionClock = @"clock";
NSString *const DBUiRegionDate = @"date";
NSString *const DBUiRegionStatusLine = @"status_line";
NSString *const DBUiRegionHint = @"hint";
NSString *const DBUiRegionTileLabel = @"tile_label";

static NSString *const kLightInk = @"#101418";
static NSString *const kDarkInk = @"#F2F5F8";
static NSString *const kLightSurface = @"#F4F6F8";
static NSString *const kDarkSurface = @"#101418";
static NSString *const kLightMuted = @"#4A525C";
static NSString *const kDarkMuted = @"#9AA4B0";
static NSString *const kFallbackAccent = @"#1F6FB2";

// Foundation-only dotted lookup so this class stays host-testable.
static id DBThemeDig(NSDictionary *root, NSString *path) {
  if (![root isKindOfClass:[NSDictionary class]] || [path length] == 0) return nil;
  id node = root;
  for (NSString *part in [path componentsSeparatedByString:@"."]) {
    if (![node isKindOfClass:[NSDictionary class]]) return nil;
    node = [(NSDictionary *)node objectForKey:part];
    if (node == nil) return nil;
  }
  return node;
}

static NSString *DBThemeString(NSDictionary *root, NSString *path) {
  id value = DBThemeDig(root, path);
  if (![value isKindOfClass:[NSString class]]) return nil;
  return [(NSString *)value length] > 0 ? (NSString *)value : nil;
}

static double DBClamp01(double v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

static double DBLinearise(double channel) {
  return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4);
}

static void DBRgbToHsl(DBRgb rgb, double *h, double *s, double *l) {
  double maxV = MAX(rgb.r, MAX(rgb.g, rgb.b));
  double minV = MIN(rgb.r, MIN(rgb.g, rgb.b));
  double delta = maxV - minV;
  double lightness = (maxV + minV) / 2.0;
  double hue = 0, saturation = 0;
  if (delta > 1e-9) {
    saturation = lightness > 0.5 ? delta / (2.0 - maxV - minV) : delta / (maxV + minV);
    if (maxV == rgb.r)
      hue = fmod((rgb.g - rgb.b) / delta, 6.0);
    else if (maxV == rgb.g)
      hue = (rgb.b - rgb.r) / delta + 2.0;
    else
      hue = (rgb.r - rgb.g) / delta + 4.0;
    hue /= 6.0;
    if (hue < 0) hue += 1.0;
  }
  *h = hue;
  *s = saturation;
  *l = lightness;
}

static double DBHueChannel(double p, double q, double t) {
  if (t < 0) t += 1;
  if (t > 1) t -= 1;
  if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
  if (t < 1.0 / 2.0) return q;
  if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
  return p;
}

static DBRgb DBHslToRgb(double h, double s, double l) {
  DBRgb out;
  if (s <= 1e-9) {
    out.r = out.g = out.b = l;
    return out;
  }
  double q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
  double p = 2.0 * l - q;
  out.r = DBHueChannel(p, q, h + 1.0 / 3.0);
  out.g = DBHueChannel(p, q, h);
  out.b = DBHueChannel(p, q, h - 1.0 / 3.0);
  return out;
}

@implementation DBUiTheme

+ (BOOL)parseHex:(NSString *)hex into:(DBRgb *)out {
  if (out == NULL || ![hex isKindOfClass:[NSString class]]) return NO;
  NSString *s = [hex stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
  if ([s length] == 3) {
    NSMutableString *expanded = [NSMutableString stringWithCapacity:6];
    for (NSUInteger i = 0; i < 3; i++) {
      unichar c = [s characterAtIndex:i];
      [expanded appendFormat:@"%C%C", c, c];
    }
    s = expanded;
  }
  if ([s length] != 6) return NO;
  unsigned int value = 0;
  NSScanner *scanner = [NSScanner scannerWithString:s];
  if (![scanner scanHexInt:&value] || ![scanner isAtEnd]) return NO;
  out->r = ((value >> 16) & 0xFF) / 255.0;
  out->g = ((value >> 8) & 0xFF) / 255.0;
  out->b = (value & 0xFF) / 255.0;
  return YES;
}

+ (NSString *)hexFromRgb:(DBRgb)rgb {
  int r = (int)lround(DBClamp01(rgb.r) * 255.0);
  int g = (int)lround(DBClamp01(rgb.g) * 255.0);
  int b = (int)lround(DBClamp01(rgb.b) * 255.0);
  return [NSString stringWithFormat:@"#%02X%02X%02X", r, g, b];
}

+ (double)relativeLuminance:(DBRgb)rgb {
  return 0.2126 * DBLinearise(DBClamp01(rgb.r)) + 0.7152 * DBLinearise(DBClamp01(rgb.g)) +
         0.0722 * DBLinearise(DBClamp01(rgb.b));
}

+ (double)contrastBetween:(DBRgb)a and:(DBRgb)b {
  double la = [self relativeLuminance:a];
  double lb = [self relativeLuminance:b];
  double hi = MAX(la, lb), lo = MIN(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

+ (double)contrastBetweenHex:(NSString *)a andHex:(NSString *)b {
  DBRgb ra, rb;
  if (![self parseHex:a into:&ra] || ![self parseHex:b into:&rb]) return 0;
  return [self contrastBetween:ra and:rb];
}

+ (double)minimumContrastForLargeText:(BOOL)large {
  return large ? 3.0 : 4.5;
}

+ (BOOL)contrastWarnsForForeground:(NSString *)fg background:(NSString *)bg large:(BOOL)large {
  double ratio = [self contrastBetweenHex:fg andHex:bg];
  if (ratio <= 0) return NO;  // Unparsable input is not a contrast finding.
  return ratio < [self minimumContrastForLargeText:large];
}

#pragma mark - appearance

+ (NSString *)normalizedAppearance:(NSString *)appearance {
  if ([appearance isEqualToString:@"light"] || [appearance isEqualToString:@"dark"] ||
      [appearance isEqualToString:@"auto_schedule"])
    return appearance;
  // iOS 5 has no system dark mode, so auto_system degrades to the schedule.
  return @"auto_schedule";
}

+ (NSInteger)minuteOfDayFromClock:(NSString *)hhmm fallback:(NSInteger)fallback {
  if (![hhmm isKindOfClass:[NSString class]]) return fallback;
  NSArray *parts = [hhmm componentsSeparatedByString:@":"];
  if ([parts count] != 2) return fallback;
  NSString *h = [parts objectAtIndex:0], *m = [parts objectAtIndex:1];
  if ([h length] == 0 || [h length] > 2 || [m length] != 2) return fallback;
  NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
  for (NSString *part in parts) {
    for (NSUInteger i = 0; i < [part length]; i++)
      if (![digits characterIsMember:[part characterAtIndex:i]]) return fallback;
  }
  NSInteger hour = [h integerValue], minute = [m integerValue];
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return fallback;
  return hour * 60 + minute;
}

+ (NSString *)appearanceModeForConfig:(NSDictionary *)config
                             deviceId:(NSString *)deviceId
                          minuteOfDay:(NSInteger)minuteOfDay {
  NSString *raw = nil;
  if ([deviceId length] > 0)
    raw = DBThemeString(config, [NSString stringWithFormat:
        @"devices.%@.local.display.appearance", deviceId]);
  if (raw == nil) raw = DBThemeString(config, @"display.appearance");
  NSString *appearance = [self normalizedAppearance:raw];
  if ([appearance isEqualToString:@"light"] || [appearance isEqualToString:@"dark"])
    return appearance;

  NSInteger darkFrom = [self minuteOfDayFromClock:
      DBThemeString(config, @"display.appearance_schedule.dark_from") fallback:19 * 60];
  NSInteger lightFrom = [self minuteOfDayFromClock:
      DBThemeString(config, @"display.appearance_schedule.light_from") fallback:6 * 60 + 30];
  NSInteger now = minuteOfDay;
  while (now < 0) now += 24 * 60;
  now = now % (24 * 60);
  if (darkFrom == lightFrom) return @"dark";
  if (darkFrom < lightFrom)
    return (now >= darkFrom && now < lightFrom) ? @"dark" : @"light";
  // The dark window wraps midnight, which is the normal 19:00 -> 06:30 case.
  return (now >= darkFrom || now < lightFrom) ? @"dark" : @"light";
}

+ (NSString *)lightInkHex { return kDarkInk; }
+ (NSString *)darkInkHex { return kLightInk; }

+ (NSString *)surfaceHexForMode:(NSString *)mode {
  return [mode isEqualToString:@"light"] ? kLightSurface : kDarkSurface;
}

+ (NSString *)inkHexForMode:(NSString *)mode {
  return [mode isEqualToString:@"light"] ? kLightInk : kDarkInk;
}

+ (NSString *)mutedInkHexForMode:(NSString *)mode {
  return [mode isEqualToString:@"light"] ? kLightMuted : kDarkMuted;
}

#pragma mark - automatic ink

+ (NSString *)inkModeForLuminance:(double)luminance {
  return luminance >= 0.5 ? @"dark" : @"light";
}

+ (NSString *)inkModeForBackgroundHex:(NSString *)hex fallbackMode:(NSString *)fallbackMode {
  DBRgb rgb;
  if (![self parseHex:hex into:&rgb])
    return [fallbackMode isEqualToString:@"light"] ? @"dark" : @"light";
  return [self inkModeForLuminance:[self relativeLuminance:rgb]];
}

+ (NSString *)inkHexForRegion:(NSString *)region
                       config:(NSDictionary *)config
                     deviceId:(NSString *)deviceId
                backgroundHex:(NSString *)backgroundHex
               appearanceMode:(NSString *)appearanceMode {
  if ([region length] == 0) region = DBUiRegionStatusLine;
  DBRgb probe;
  if ([deviceId length] > 0) {
    NSString *override = DBThemeString(config, [NSString stringWithFormat:
        @"devices.%@.local.theme.ink_override.%@", deviceId, region]);
    if (override && [self parseHex:override into:&probe]) return override;
  }
  NSString *clusterOverride = DBThemeString(config, [NSString stringWithFormat:
      @"display.theme.ink_override.%@", region]);
  if (clusterOverride && [self parseHex:clusterOverride into:&probe]) return clusterOverride;

  // Core publishes the agreed decision so every shell renders the same ink.
  NSString *published = DBThemeString(config, [NSString stringWithFormat:
      @"display.theme.auto_ink.%@", region]);
  if ([published isEqualToString:@"light"]) return kDarkInk;
  if ([published isEqualToString:@"dark"]) return kLightInk;

  NSString *mode = [self inkModeForBackgroundHex:backgroundHex fallbackMode:appearanceMode];
  return [mode isEqualToString:@"dark"] ? kLightInk : kDarkInk;
}

+ (BOOL)needsInkShadowForInk:(NSString *)inkHex background:(NSString *)backgroundHex {
  double ratio = [self contrastBetweenHex:inkHex andHex:backgroundHex];
  if (ratio <= 0) return NO;
  return ratio < 4.5;
}

#pragma mark - computed accent

+ (NSString *)autoAccentForBackgroundHex:(NSString *)backgroundHex {
  DBRgb bg;
  if (![self parseHex:backgroundHex into:&bg]) return kFallbackAccent;
  double h, s, l;
  DBRgbToHsl(bg, &h, &s, &l);
  double rotated = fmod(h + 0.5, 1.0);
  double saturation = MAX(0.45, MIN(0.9, s < 0.2 ? 0.55 : s));
  BOOL backgroundIsLight = [self relativeLuminance:bg] >= 0.5;

  // Prefer the dark direction on light backgrounds, then try the other way.
  double directions[2] = { backgroundIsLight ? -1.0 : 1.0, backgroundIsLight ? 1.0 : -1.0 };
  for (NSUInteger d = 0; d < 2; d++) {
    for (double step = 0; step <= 1.0; step += 0.02) {
      double lightness = l + directions[d] * step;
      if (lightness < 0.04 || lightness > 0.96) continue;
      DBRgb candidate = DBHslToRgb(rotated, saturation, lightness);
      if ([self contrastBetween:candidate and:bg] < 3.0) continue;
      NSString *hex = [self hexFromRgb:candidate];
      NSString *text = [self accentTextHexForAccentHex:hex];
      if ([self contrastBetweenHex:text andHex:hex] < 4.5) continue;
      return hex;
    }
  }
  return kFallbackAccent;
}

+ (NSString *)accentTextHexForAccentHex:(NSString *)accentHex {
  DBRgb accent;
  if (![self parseHex:accentHex into:&accent]) return kDarkInk;
  double white = [self contrastBetweenHex:kDarkInk andHex:accentHex];
  double black = [self contrastBetweenHex:kLightInk andHex:accentHex];
  return white >= black ? kDarkInk : kLightInk;
}

+ (NSString *)callButtonHexForConfig:(NSDictionary *)config
                            deviceId:(NSString *)deviceId
                       backgroundHex:(NSString *)backgroundHex {
  DBRgb probe;
  if ([deviceId length] > 0) {
    NSString *override = DBThemeString(config, [NSString stringWithFormat:
        @"devices.%@.local.theme.call_button_bg", deviceId]);
    if (override && [self parseHex:override into:&probe]) return override;
  }
  NSString *clusterOverride = DBThemeString(config, @"display.theme.call_button_bg");
  if (clusterOverride && [self parseHex:clusterOverride into:&probe]) return clusterOverride;
  NSString *published = DBThemeString(config, @"display.theme.auto_accent");
  if (published && [self parseHex:published into:&probe]) return published;
  return [self autoAccentForBackgroundHex:backgroundHex];
}

#pragma mark - labels

+ (NSArray *)labelPartsFor:(NSString *)text {
  if (![text isKindOfClass:[NSString class]] || [text length] == 0)
    return [NSArray arrayWithObjects:@"", @"", nil];
  NSRange br = [text rangeOfString:@"\n"];
  if (br.location == NSNotFound)
    return [NSArray arrayWithObjects:text, @"", nil];
  NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  NSString *primary = [[text substringToIndex:br.location] stringByTrimmingCharactersInSet:ws];
  NSString *rest = [[text substringFromIndex:br.location + br.length]
      stringByTrimmingCharactersInSet:ws];
  // Only the first authored break splits the label; later ones stay in part two.
  rest = [rest stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
  return [NSArray arrayWithObjects:primary, rest, nil];
}

+ (double)secondaryFontScale { return 0.8; }
+ (double)pillPaddingVertical { return 6.0; }
+ (double)pillPaddingHorizontal { return 12.0; }
+ (double)pillRadius { return 8.0; }

+ (NSArray *)aspectFitRectForContentWidth:(double)contentWidth
                            contentHeight:(double)contentHeight
                           availableWidth:(double)availableWidth
                          availableHeight:(double)availableHeight {
  if (availableWidth <= 0 || availableHeight <= 0)
    return [NSArray arrayWithObjects:@0, @0, @0, @0, nil];
  if (contentWidth <= 0 || contentHeight <= 0) {
    // An unknown aspect fills the slot rather than collapsing it.
    return [NSArray arrayWithObjects:@0, @0,
        [NSNumber numberWithDouble:availableWidth],
        [NSNumber numberWithDouble:availableHeight], nil];
  }
  double scale = MIN(availableWidth / contentWidth, availableHeight / contentHeight);
  double width = contentWidth * scale;
  double height = contentHeight * scale;
  return [NSArray arrayWithObjects:
      [NSNumber numberWithDouble:(availableWidth - width) / 2.0],
      [NSNumber numberWithDouble:(availableHeight - height) / 2.0],
      [NSNumber numberWithDouble:width],
      [NSNumber numberWithDouble:height], nil];
}

+ (NSString *)versionLineForName:(NSString *)name
                     coreVersion:(NSString *)coreVersion
                      appVersion:(NSString *)appVersion
                      batteryPct:(NSInteger)batteryPct
                        charging:(BOOL)charging {
  NSMutableArray *parts = [NSMutableArray array];
  if ([name length] > 0) [parts addObject:name];
  [parts addObject:[NSString stringWithFormat:@"core v%@",
      [coreVersion length] > 0 ? coreVersion : @"?"]];
  [parts addObject:[NSString stringWithFormat:@"app v%@",
      [appVersion length] > 0 ? appVersion : @"?"]];
  // A device without a battery reports -1 and shows nothing at all.
  if (batteryPct >= 0) {
    [parts addObject:charging
        ? [NSString stringWithFormat:@"%ld%% ⚡", (long)batteryPct]
        : [NSString stringWithFormat:@"%ld%%", (long)batteryPct]];
  }
  return [parts componentsJoinedByString:@" · "];
}

@end
