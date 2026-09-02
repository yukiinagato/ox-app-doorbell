#import "DBSemanticStyle.h"

#import <math.h>

NSString *const DBSemanticStyleReportDidChangeNotification =
    @"DBSemanticStyleReportDidChangeNotification";

static NSMutableDictionary *DBSemanticOutcomes(void) {
  static NSMutableDictionary *outcomes = nil;
  @synchronized([DBSemanticStyle class]) {
    if (!outcomes) outcomes = [[NSMutableDictionary alloc] init];
  }
  return outcomes;
}

static NSTimeInterval DBSemanticUpdatedAtMs = 0;

static void DBSemanticRecord(NSString *semanticID, NSString *source, BOOL applied,
                             BOOL rejected, BOOL persisted, NSString *error) {
  if ([semanticID length] == 0) return;
  NSDictionary *outcome = @{
    @"source" : source ?: @"default",
    @"applied" : @(applied),
    @"rejected" : @(rejected),
    @"lkg_persisted" : @(persisted),
    @"error" : error ?: @"",
  };
  @synchronized([DBSemanticStyle class]) {
    [DBSemanticOutcomes() setObject:outcome forKey:semanticID];
    DBSemanticUpdatedAtMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
  }
  [[NSNotificationCenter defaultCenter]
      postNotificationName:DBSemanticStyleReportDidChangeNotification object:nil];
}

static NSDictionary *DBSemanticRawOverride(NSDictionary *config, NSString *deviceID,
                                            NSString *semanticID) {
  if (![config isKindOfClass:[NSDictionary class]] || [deviceID length] == 0 ||
      [semanticID length] == 0) return nil;
  id devices = [config objectForKey:@"devices"];
  id device = [devices isKindOfClass:[NSDictionary class]]
      ? [(NSDictionary *)devices objectForKey:deviceID] : nil;
  id local = [device isKindOfClass:[NSDictionary class]]
      ? [(NSDictionary *)device objectForKey:@"local"] : nil;
  id ui = [local isKindOfClass:[NSDictionary class]]
      ? [(NSDictionary *)local objectForKey:@"ui"] : nil;
  id elements = [ui isKindOfClass:[NSDictionary class]]
      ? [(NSDictionary *)ui objectForKey:@"elements"] : nil;
  if (![elements isKindOfClass:[NSDictionary class]]) return nil;
  id direct = [(NSDictionary *)elements objectForKey:semanticID];
  if ([direct isKindOfClass:[NSDictionary class]]) return direct;
  id nested = elements;
  for (NSString *part in [semanticID componentsSeparatedByString:@"."]) {
    if (![nested isKindOfClass:[NSDictionary class]]) return nil;
    nested = [(NSDictionary *)nested objectForKey:part];
  }
  return [nested isKindOfClass:[NSDictionary class]] ? nested : nil;
}

static UIColor *DBSemanticHexColor(id value) {
  if (![value isKindOfClass:[NSString class]]) return nil;
  NSString *text = (NSString *)value;
  if ([text length] != 7 || ![text hasPrefix:@"#"]) return nil;
  unsigned int raw = 0;
  NSScanner *scanner = [NSScanner scannerWithString:[text substringFromIndex:1]];
  if (![scanner scanHexInt:&raw] || ![scanner isAtEnd]) return nil;
  return [UIColor colorWithRed:((raw >> 16) & 0xff) / 255.0
                         green:((raw >> 8) & 0xff) / 255.0
                          blue:(raw & 0xff) / 255.0 alpha:1];
}

static double DBSemanticLuminance(UIColor *color) {
  if (!color) return -1;
  CGColorRef cg = color.CGColor;
  const CGFloat *components = CGColorGetComponents(cg);
  size_t count = CGColorGetNumberOfComponents(cg);
  double rgb[3];
  if (count == 2) {
    rgb[0] = rgb[1] = rgb[2] = components[0];
  } else if (count >= 4) {
    rgb[0] = components[0]; rgb[1] = components[1]; rgb[2] = components[2];
  } else {
    return -1;
  }
  for (int i = 0; i < 3; i++)
    rgb[i] = rgb[i] <= 0.03928 ? rgb[i] / 12.92 : pow((rgb[i] + 0.055) / 1.055, 2.4);
  return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
}

static double DBSemanticContrast(UIColor *first, UIColor *second) {
  double a = DBSemanticLuminance(first), b = DBSemanticLuminance(second);
  if (a < 0 || b < 0) return 0;
  return (MAX(a, b) + 0.05) / (MIN(a, b) + 0.05);
}

static BOOL DBSemanticStyleValid(NSDictionary *style, BOOL safetyCritical,
                                 UIColor *baseForeground, UIColor *baseBackground,
                                 UIColor *baseAccent, UIColor *baseBorder) {
  if (![style isKindOfClass:[NSDictionary class]]) return NO;
  NSSet *allowed = [NSSet setWithObjects:@"scale", @"font_scale", @"foreground",
      @"background", @"accent", @"border", @"radius", nil];
  for (NSString *key in style) {
    if (![allowed containsObject:key]) return NO;
    id value = [style objectForKey:key];
    if ([key isEqualToString:@"scale"] || [key isEqualToString:@"font_scale"]) {
      if (![value isKindOfClass:[NSNumber class]]) return NO;
      double number = [(NSNumber *)value doubleValue];
      if (!isfinite(number) || number < 0.75 || number > 2.0) return NO;
      if (safetyCritical && number < 1.0) return NO;
    } else if ([key isEqualToString:@"radius"]) {
      if (![value isKindOfClass:[NSNumber class]]) return NO;
      double number = [(NSNumber *)value doubleValue];
      if (!isfinite(number) || number < 0 || number > 44) return NO;
    } else if (!DBSemanticHexColor(value)) {
      return NO;
    }
  }
  UIColor *foreground = DBSemanticHexColor([style objectForKey:@"foreground"]) ?: baseForeground;
  UIColor *background = DBSemanticHexColor([style objectForKey:@"background"]) ?: baseBackground;
  UIColor *accent = DBSemanticHexColor([style objectForKey:@"accent"]) ?: baseAccent;
  UIColor *border = DBSemanticHexColor([style objectForKey:@"border"]) ?: baseBorder;
  if (([style objectForKey:@"foreground"] || [style objectForKey:@"background"]) &&
      DBSemanticContrast(foreground, background) < 4.5) return NO;
  if (([style objectForKey:@"accent"] || [style objectForKey:@"background"]) &&
      accent && DBSemanticContrast(accent, background) < 3.0) return NO;
  if (([style objectForKey:@"border"] ||
       ([style objectForKey:@"background"] && baseBorder)) &&
      border && DBSemanticContrast(border, background) < 3.0) return NO;
  return YES;
}

@implementation DBSemanticStyle

+ (NSDictionary *)styleForConfig:(NSDictionary *)config
                         deviceID:(NSString *)deviceID
                       semanticID:(NSString *)semanticID
                   safetyCritical:(BOOL)safetyCritical
               baselineForeground:(UIColor *)foreground
               baselineBackground:(UIColor *)background
                   baselineAccent:(UIColor *)accent
                   baselineBorder:(UIColor *)border {
  NSDictionary *proposed = DBSemanticRawOverride(config, deviceID, semanticID);
  if (!proposed) {
    DBSemanticRecord(semanticID, @"default", NO, NO, NO, @"");
    return nil;
  }
  NSString *key = [NSString stringWithFormat:@"ui.lkg.%@.%@", deviceID, semanticID];
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if (DBSemanticStyleValid(proposed, safetyCritical, foreground, background, accent, border)) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:proposed options:0 error:NULL];
    BOOL persisted = NO;
    if (data) {
      [defaults setObject:data forKey:key];
      persisted = [defaults synchronize];
    }
    DBSemanticRecord(semanticID, @"override", YES, NO, persisted,
                     persisted ? @"" : @"last_known_good_persist_failed");
    return proposed;
  }
  NSData *data = [defaults dataForKey:key];
  id saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  BOOL usesSaved = DBSemanticStyleValid(saved, safetyCritical, foreground, background,
                                        accent, border);
  DBSemanticRecord(semanticID, usesSaved ? @"last_known_good" : @"default",
                   usesSaved, YES, usesSaved, @"invalid_override");
  return usesSaved ? saved : nil;
}

+ (NSDictionary *)runtimeReport {
  @synchronized([DBSemanticStyle class]) {
    NSDictionary *elements = [NSDictionary dictionaryWithDictionary:DBSemanticOutcomes()];
    NSMutableArray *applied = [NSMutableArray array];
    NSMutableArray *rejected = [NSMutableArray array];
    NSMutableArray *used = [NSMutableArray array];
    NSMutableArray *persisted = [NSMutableArray array];
    NSString *lastError = @"";
    NSArray *keys = [[elements allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *semanticID in keys) {
      NSDictionary *outcome = [elements objectForKey:semanticID];
      if ([[outcome objectForKey:@"applied"] boolValue]) [applied addObject:semanticID];
      if ([[outcome objectForKey:@"rejected"] boolValue]) {
        NSString *reason = [outcome objectForKey:@"error"] ?: @"invalid_override";
        [rejected addObject:@{ @"semantic_id" : semanticID, @"reason" : reason }];
        lastError = [NSString stringWithFormat:@"%@:%@", semanticID, reason];
      }
      NSString *elementError = [outcome objectForKey:@"error"];
      if ([lastError length] == 0 && [elementError length] > 0)
        lastError = [NSString stringWithFormat:@"%@:%@", semanticID, elementError];
      if ([[outcome objectForKey:@"source"] isEqualToString:@"last_known_good"])
        [used addObject:semanticID];
      if ([[outcome objectForKey:@"lkg_persisted"] boolValue])
        [persisted addObject:semanticID];
    }
    return @{
      @"schema_version" : @1,
      @"applied" : applied,
      @"rejected" : rejected,
      @"last_known_good" : @{ @"used" : used, @"persisted" : persisted },
      @"last_error" : lastError,
      @"updated_at_ms" : @((long long)DBSemanticUpdatedAtMs),
      @"elements" : elements,
    };
  }
}

+ (CGFloat)numberInStyle:(NSDictionary *)style key:(NSString *)key
                fallback:(CGFloat)fallback minimum:(CGFloat)minimum maximum:(CGFloat)maximum {
  id value = [style objectForKey:key];
  if (![value isKindOfClass:[NSNumber class]]) return fallback;
  double number = [(NSNumber *)value doubleValue];
  return isfinite(number) && number >= minimum && number <= maximum ? (CGFloat)number : fallback;
}

+ (UIColor *)colorInStyle:(NSDictionary *)style key:(NSString *)key fallback:(UIColor *)fallback {
  return DBSemanticHexColor([style objectForKey:key]) ?: fallback;
}

+ (void)applyButton:(UIButton *)button style:(NSDictionary *)style
          foreground:(UIColor *)foreground background:(UIColor *)background
              border:(UIColor *)border radius:(CGFloat)radius fontSize:(CGFloat)fontSize {
  [button setTitleColor:[self colorInStyle:style key:@"foreground" fallback:foreground]
               forState:UIControlStateNormal];
  button.backgroundColor = [self colorInStyle:style key:@"background" fallback:background];
  UIColor *effectiveBorder = [self colorInStyle:style key:@"border" fallback:border];
  button.layer.borderColor = effectiveBorder ? effectiveBorder.CGColor : [UIColor clearColor].CGColor;
  button.layer.borderWidth = effectiveBorder ? 2.0 : 0.0;
  button.layer.cornerRadius = [self numberInStyle:style key:@"radius" fallback:radius
                                          minimum:0 maximum:44];
  CGFloat fontScale = [self numberInStyle:style key:@"font_scale" fallback:1
                                   minimum:0.75 maximum:2];
  button.titleLabel.font = [UIFont boldSystemFontOfSize:fontSize * fontScale];
}

+ (void)applyLabel:(UILabel *)label style:(NSDictionary *)style
          foreground:(UIColor *)foreground background:(UIColor *)background
            fontSize:(CGFloat)fontSize {
  label.textColor = [self colorInStyle:style key:@"foreground" fallback:foreground];
  label.backgroundColor = [self colorInStyle:style key:@"background" fallback:background];
  CGFloat fontScale = [self numberInStyle:style key:@"font_scale" fallback:1
                                   minimum:0.75 maximum:2];
  label.font = [UIFont boldSystemFontOfSize:fontSize * fontScale];
}

@end
