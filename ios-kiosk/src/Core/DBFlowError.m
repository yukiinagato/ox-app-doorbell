#import "DBFlowError.h"

static NSString *const kPrefix = @"visitor_flow.";

@implementation DBFlowError {
  NSString *_code, *_location, *_stepID, *_optionID, *_field, *_lang, *_raw;
  NSInteger _imageIndex;
  NSDictionary *_detail;
}
@synthesize code = _code, location = _location, stepID = _stepID, optionID = _optionID;
@synthesize field = _field, lang = _lang, imageIndex = _imageIndex, detail = _detail, raw = _raw;

static BOOL IsTextField(NSString *name) {
  return [name isEqualToString:@"title"] || [name isEqualToString:@"body"] ||
         [name isEqualToString:@"message"];
}

// `images[n]` -> n, otherwise -1.
static NSInteger ImageIndexOf(NSString *token) {
  if (![token hasPrefix:@"images["] || ![token hasSuffix:@"]"]) return -1;
  NSString *digits = [token substringWithRange:NSMakeRange(7, [token length] - 8)];
  if ([digits length] == 0) return -1;
  for (NSUInteger i = 0; i < [digits length]; i++)
    if ([digits characterAtIndex:i] < '0' || [digits characterAtIndex:i] > '9') return -1;
  return [digits integerValue];
}

+ (DBFlowError *)errorFromResult:(NSDictionary *)result {
  if (![result isKindOfClass:[NSDictionary class]]) return nil;
  id err = [result objectForKey:@"err"];
  id detail = [result objectForKey:@"detail"];
  return [self errorFromString:[err isKindOfClass:[NSString class]] ? err : nil
                        detail:[detail isKindOfClass:[NSDictionary class]] ? detail : nil];
}

+ (DBFlowError *)errorFromString:(NSString *)err detail:(NSDictionary *)detail {
  if (![err hasPrefix:kPrefix]) return nil;
  NSRange split = [err rangeOfString:@": "];
  NSString *head = split.location == NSNotFound ? err : [err substringToIndex:split.location];
  NSString *location = split.location == NSNotFound ? @"" : [err substringFromIndex:NSMaxRange(split)];
  DBFlowError *error = [[DBFlowError alloc] init];
  error->_raw = [err copy];
  error->_code = [[head substringFromIndex:[kPrefix length]] copy];
  error->_location = [location copy];
  error->_detail = [detail copy] ?: @{};
  error->_imageIndex = -1;
  if ([error->_code length] == 0) return nil;
  NSArray *tokens = [location length] > 0 ? [location componentsSeparatedByString:@"."] : @[];
  if ([tokens count] == 0) return error;
  NSString *first = [tokens objectAtIndex:0];
  if ([first isEqualToString:@"start"] || [first isEqualToString:@"doors"] ||
      [first isEqualToString:@"visitor_flow"]) return error;
  error->_stepID = [first copy];
  NSUInteger next = 1;
  if ([tokens count] > 1) {
    NSString *token = [tokens objectAtIndex:1];
    NSInteger image = ImageIndexOf(token);
    next = 2;
    if (image >= 0) {
      error->_imageIndex = image;
      if ([tokens count] > 2 && [[tokens objectAtIndex:2] isEqualToString:@"alt"]) {
        error->_field = @"alt";
        next = 3;
      }
    } else if (IsTextField(token)) {
      error->_field = [token copy];
    } else {
      error->_optionID = [token copy];
      if ([tokens count] > 2 && [[tokens objectAtIndex:2] isEqualToString:@"label"]) {
        error->_field = @"label";
        next = 3;
      }
    }
  }
  if (error->_field != nil && [tokens count] > next)
    error->_lang = [[[tokens subarrayWithRange:NSMakeRange(next, [tokens count] - next)]
        componentsJoinedByString:@"."] copy];
  return error;
}

- (NSString *)messageKey {
  return [@"flow_error." stringByAppendingString:_code];
}

- (NSString *)messageFromTemplate:(NSString *)template
                         langName:(NSString *(^)(NSString *))langName {
  NSMutableString *text = [NSMutableString stringWithString:template ?: @""];
  for (NSString *name in @[ @"limit", @"value", @"min", @"max" ]) {
    id value = [_detail objectForKey:name];
    if (value == nil) continue;
    [text replaceOccurrencesOfString:[NSString stringWithFormat:@"{%@}", name]
                          withString:[NSString stringWithFormat:@"%@", value]
                             options:0 range:NSMakeRange(0, [text length])];
  }
  id lang = [_detail objectForKey:@"lang"];
  if ([lang isKindOfClass:[NSString class]]) {
    NSString *shown = langName ? langName(lang) : lang;
    [text replaceOccurrencesOfString:@"{lang}" withString:shown ?: lang options:0
                               range:NSMakeRange(0, [text length])];
  }
  return text;
}

- (NSArray *)anchors {
  NSMutableArray *anchors = [NSMutableArray array];
  NSString *current = _location;
  while ([current length] > 0) {
    [anchors addObject:current];
    NSRange dot = [current rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location == NSNotFound) break;
    current = [current substringToIndex:dot.location];
  }
  return anchors;
}

+ (NSString *)anchorForWarningKey:(NSString *)key {
  NSString *prefix = @"visitor_flow.steps.";
  if (![key hasPrefix:prefix] || [key length] == [prefix length]) return nil;
  return [key substringFromIndex:[prefix length]];
}

@end
