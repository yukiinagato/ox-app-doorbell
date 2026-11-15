#import "DBAirQualityModel.h"

#import <math.h>

#import "DBTexts.h"

@interface DBAirQualityModel ()
@property(nonatomic, readwrite) BOOL visible;
@property(nonatomic, readwrite) BOOL dimmed;
@property(nonatomic, readwrite, copy) NSString *state;
@property(nonatomic, readwrite, copy) NSString *text;
@property(nonatomic, readwrite, copy) NSString *accessibilityLabel;
@property(nonatomic, readwrite, copy) NSString *levelHex;
@end

@implementation DBAirQualityModel

@synthesize visible = _visible, dimmed = _dimmed, state = _state, text = _text,
            accessibilityLabel = _accessibilityLabel, levelHex = _levelHex;

+ (NSString *)hexForLevel:(NSString *)level {
  if (![level isKindOfClass:[NSString class]]) return nil;
  NSDictionary *colors = [NSDictionary dictionaryWithObjectsAndKeys:
      @"#00E400", @"good", @"#FFFF00", @"moderate", @"#FF7E00", @"sensitive",
      @"#FF0000", @"unhealthy", @"#8F3F97", @"very_unhealthy", @"#7E0023", @"hazardous", nil];
  return [colors objectForKey:level];
}

+ (NSString *)valueString:(NSNumber *)pm25 {
  if (![pm25 isKindOfClass:[NSNumber class]]) return nil;
  double value = [pm25 doubleValue];
  if (!isfinite(value) || value < 0) return nil;
  if (fabs(value - floor(value + 0.5)) < 0.05)
    return [NSString stringWithFormat:@"%.0f", floor(value + 0.5)];
  return [NSString stringWithFormat:@"%.1f", value];
}

+ (DBAirQualityModel *)modelWithDocument:(NSDictionary *)document texts:(DBTexts *)texts {
  DBAirQualityModel *model = [[DBAirQualityModel alloc] init];
  model.state = @"hidden";
  if (![document isKindOfClass:[NSDictionary class]] || texts == nil) return model;
  id show = [document objectForKey:@"show"];
  id state = [document objectForKey:@"state"];
  if (![state isKindOfClass:[NSString class]]) return model;
  if ([show isKindOfClass:[NSNumber class]] && ![show boolValue]) return model;
  model.state = state;

  NSString *label = [texts ts:@"air.pm25_label"];
  NSString *value = [self valueString:[document objectForKey:@"pm25"]];
  NSString *level = [document objectForKey:@"level"];
  NSString *levelText = [level isKindOfClass:[NSString class]]
      ? [texts ts:[@"air.level_" stringByAppendingString:level]] : nil;

  if ([state isEqualToString:@"ok"] || [state isEqualToString:@"stale"]) {
    BOOL stale = [state isEqualToString:@"stale"];
    if (value == nil) {
      // A stale document without a reading has nothing to dim; say so instead.
      NSString *placeholder = [texts ts:stale ? @"air.stale" : @"air.waiting"];
      model.visible = YES;
      model.dimmed = stale;
      model.text = [NSString stringWithFormat:@"%@  %@", label, placeholder];
      model.accessibilityLabel = [texts t:@"air.a11y_no_value", placeholder, nil];
      return model;
    }
    NSString *trailing = stale ? [texts ts:@"air.stale"] : (levelText ?: @"");
    model.visible = YES;
    model.dimmed = stale;
    model.levelHex = [self hexForLevel:level];
    NSString *reading = [NSString stringWithFormat:@"%@  %@ %@", label, value,
                                                   [texts ts:@"air.unit"]];
    model.text = [trailing length] > 0
        ? [NSString stringWithFormat:@"%@  %@", reading, trailing] : reading;
    model.accessibilityLabel = [texts t:@"air.a11y", value, [trailing length] > 0
        ? trailing : (levelText ?: @""), nil];
    return model;
  }
  if ([state isEqualToString:@"waiting"] || [state isEqualToString:@"unconfigured"]) {
    NSString *placeholder = [texts ts:[@"air." stringByAppendingString:state]];
    model.visible = YES;
    model.text = [NSString stringWithFormat:@"%@  %@", label, placeholder];
    model.accessibilityLabel = [texts t:@"air.a11y_no_value", placeholder, nil];
  }
  return model;
}

@end
