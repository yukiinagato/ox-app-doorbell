#import "DBTexts.h"
#import "DBGeneratedStrings.h"

static NSString *DBCanonicalTextKey(NSString *key) {
  // Keep the pre-catalog key working for existing kiosk config overrides.
  if ([key isEqualToString:@"ring.open_door"]) return @"ring.unlock";
  return key;
}

@implementation DBTexts {
  NSDictionary *_config;
  NSDictionary *_overrides;
  NSDictionary *_builtin;
}

@synthesize lang = _lang;

+ (NSDictionary *)builtinFor:(NSString *)lang {
  return DBGeneratedStringsForLanguage(lang);
}

- (id)init {
  self = [super init];
  if (self) {
    _lang = @"ja";
    [self reload];
  }
  return self;
}

- (void)setConfig:(NSDictionary *)cfg {
  _config = cfg;
  [self reload];
}

- (void)setLang:(NSString *)lang {
  _lang = [lang length] == 0 ? @"ja" : lang;
  [self reload];
}

- (void)reload {
  id ov = [_config objectForKey:@"i18n_overrides"];
  id langOv = [ov isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)ov objectForKey:_lang] : nil;
  _overrides = [langOv isKindOfClass:[NSDictionary class]] ? langOv : nil;
  _builtin = [[self class] builtinFor:_lang];
}

- (NSString *)resolveFmt:(NSString *)key {
  id ov = [_overrides objectForKey:key];
  if ([ov isKindOfClass:[NSString class]] && [(NSString *)ov length] > 0) return ov;
  NSString *canonicalKey = DBCanonicalTextKey(key);
  if (![canonicalKey isEqualToString:key]) {
    ov = [_overrides objectForKey:canonicalKey];
    if ([ov isKindOfClass:[NSString class]] && [(NSString *)ov length] > 0) return ov;
  }
  NSString *b = [_builtin objectForKey:canonicalKey];
  return b ? b : key;
}

- (NSString *)fill:(NSString *)fmt args:(NSArray *)args {
  if ([args count] == 0) return fmt;
  NSMutableString *out = [NSMutableString stringWithString:fmt];
  NSError *err = nil;
  NSRegularExpression *re =
      [NSRegularExpression regularExpressionWithPattern:@"\\{[A-Za-z_][A-Za-z0-9_]*\\}"
                                                options:0
                                                  error:&err];
  if (re == nil) return fmt;
  NSUInteger i = 0;
  while (i < [args count]) {
    NSTextCheckingResult *m =
        [re firstMatchInString:out options:0 range:NSMakeRange(0, [out length])];
    if (m == nil) break;
    [out replaceCharactersInRange:m.range withString:[args objectAtIndex:i]];
    i++;
  }
  return out;
}

- (NSString *)ts:(NSString *)key {
  return [self resolveFmt:key];
}

- (NSString *)t:(NSString *)key, ... {
  NSString *fmt = [self resolveFmt:key];
  NSMutableArray *args = [NSMutableArray array];
  va_list ap;
  va_start(ap, key);
  id a;
  while ((a = va_arg(ap, id)) != nil) {
    [args addObject:[a isKindOfClass:[NSString class]] ? a : [NSString stringWithFormat:@"%@", a]];
  }
  va_end(ap);
  return [self fill:fmt args:args];
}

+ (NSString *)langDisplayName:(NSString *)lang {
  NSDictionary *names = DBGeneratedStringsForLanguage(@"en");
  if ([lang isEqualToString:@"ja"]) return [names objectForKey:@"language.name_ja"];
  if ([lang isEqualToString:@"en"]) return @"English";
  if ([lang isEqualToString:@"zh"]) return [names objectForKey:@"language.name_zh"];
  return lang;
}

@end
