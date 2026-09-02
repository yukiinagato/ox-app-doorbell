#import "DBPairUri.h"

NSString *const DBPairUriErrorBadScheme = @"bad_scheme";
NSString *const DBPairUriErrorMissingPin = @"missing_pin";
NSString *const DBPairUriErrorMissingHost = @"missing_host";
NSString *const DBPairUriErrorExpired = @"expired";

// Percent decoding by hand: the iOS 5 API for it is deprecated on current SDKs
// and this is three lines of arithmetic.
static NSString *DBPercentDecode(NSString *value) {
  if ([value rangeOfString:@"%"].location == NSNotFound) return value;
  NSMutableData *bytes = [NSMutableData data];
  NSUInteger length = [value length];
  for (NSUInteger i = 0; i < length; i++) {
    unichar c = [value characterAtIndex:i];
    if (c == '%' && i + 2 < length) {
      unichar hi = [value characterAtIndex:i + 1];
      unichar lo = [value characterAtIndex:i + 2];
      int high = -1, low = -1;
      if (hi >= '0' && hi <= '9') high = hi - '0';
      else if (hi >= 'a' && hi <= 'f') high = hi - 'a' + 10;
      else if (hi >= 'A' && hi <= 'F') high = hi - 'A' + 10;
      if (lo >= '0' && lo <= '9') low = lo - '0';
      else if (lo >= 'a' && lo <= 'f') low = lo - 'a' + 10;
      else if (lo >= 'A' && lo <= 'F') low = lo - 'A' + 10;
      if (high >= 0 && low >= 0) {
        unsigned char byte = (unsigned char)(high * 16 + low);
        [bytes appendBytes:&byte length:1];
        i += 2;
        continue;
      }
    }
    if (c == '+') {  // A query encoder may use + for a space.
      unsigned char space = ' ';
      [bytes appendBytes:&space length:1];
      continue;
    }
    NSData *utf8 = [[NSString stringWithCharacters:&c length:1]
        dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8) [bytes appendData:utf8];
  }
  NSString *decoded = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
  return decoded ?: value;
}

static BOOL DBIsSixAsciiDigits(NSString *pin) {
  if ([pin length] != 6) return NO;
  for (NSUInteger i = 0; i < 6; i++) {
    unichar c = [pin characterAtIndex:i];
    if (c < '0' || c > '9') return NO;  // Full-width digits are a mis-scan.
  }
  return YES;
}

@implementation DBPairUri {
  NSString *_host;
  NSString *_pin;
  NSString *_cluster;
  long long _expiresAtS;
  NSString *_error;
}

@synthesize host = _host, pin = _pin, cluster = _cluster, expiresAtS = _expiresAtS,
            error = _error;

- (BOOL)isValid {
  return _error == nil;
}

+ (DBPairUri *)refusalWith:(NSString *)error {
  DBPairUri *result = [[DBPairUri alloc] init];
  result->_error = [error copy];
  result->_host = @"";
  result->_pin = @"";
  result->_cluster = @"";
  return result;
}

+ (DBPairUri *)parse:(NSString *)text nowS:(long long)nowS {
  if (![text isKindOfClass:[NSString class]])
    return [self refusalWith:DBPairUriErrorBadScheme];
  // A QR reader hands back exactly what was encoded, whitespace and all.
  NSString *trimmed = [text stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSRange query = [trimmed rangeOfString:@"?"];
  NSString *head = query.location == NSNotFound ? trimmed
                                                : [trimmed substringToIndex:query.location];
  // A QR encoder may upper-case the whole payload to save modules.
  if (![[head lowercaseString] isEqualToString:@"doorbell://pair"])
    return [self refusalWith:DBPairUriErrorBadScheme];

  NSString *host = @"", *pin = @"", *cluster = @"";
  long long expiresAtS = 0;
  BOOL sawExpiry = NO;
  if (query.location != NSNotFound) {
    NSString *rest = [trimmed substringFromIndex:query.location + 1];
    for (NSString *pair in [rest componentsSeparatedByString:@"&"]) {
      NSRange equals = [pair rangeOfString:@"="];
      if (equals.location == NSNotFound) continue;
      NSString *key = [[pair substringToIndex:equals.location] lowercaseString];
      NSString *value = DBPercentDecode([pair substringFromIndex:equals.location + 1]);
      if ([key isEqualToString:@"host"]) host = value;
      else if ([key isEqualToString:@"pin"]) pin = value;
      else if ([key isEqualToString:@"cluster"]) cluster = value;
      else if ([key isEqualToString:@"exp"]) {
        expiresAtS = [value longLongValue];
        sawExpiry = YES;
      }
    }
  }

  if ([host length] == 0) return [self refusalWith:DBPairUriErrorMissingHost];
  // Sending a mis-scanned PIN would burn one of a token's few attempts.
  if (!DBIsSixAsciiDigits(pin)) return [self refusalWith:DBPairUriErrorMissingPin];
  if (sawExpiry && expiresAtS > 0 && nowS >= expiresAtS)
    return [self refusalWith:DBPairUriErrorExpired];

  DBPairUri *result = [[DBPairUri alloc] init];
  result->_host = [host copy];
  result->_pin = [pin copy];
  result->_cluster = [cluster copy];
  result->_expiresAtS = sawExpiry ? expiresAtS : 0;
  result->_error = nil;
  return result;
}

+ (DBPairUri *)fromCoreDocument:(NSDictionary *)document {
  if (![document isKindOfClass:[NSDictionary class]]) return nil;
  id error = [document objectForKey:@"err"];
  if (![error isKindOfClass:[NSString class]]) error = [document objectForKey:@"error"];
  if ([error isKindOfClass:[NSString class]] && [(NSString *)error length] > 0)
    return [self refusalWith:(NSString *)error];
  id host = [document objectForKey:@"host"];
  id pin = [document objectForKey:@"pin"];
  if (![host isKindOfClass:[NSString class]] || ![pin isKindOfClass:[NSString class]])
    return nil;  // Not a document this shell understands; parse locally instead.
  DBPairUri *result = [[DBPairUri alloc] init];
  result->_host = [(NSString *)host copy];
  result->_pin = [(NSString *)pin copy];
  id cluster = [document objectForKey:@"cluster"];
  result->_cluster = [cluster isKindOfClass:[NSString class]] ? [cluster copy] : @"";
  id expires = [document objectForKey:@"exp"];
  if (![expires isKindOfClass:[NSNumber class]])
    expires = [document objectForKey:@"expires_at_s"];
  result->_expiresAtS = [expires isKindOfClass:[NSNumber class]]
      ? [(NSNumber *)expires longLongValue] : 0;
  result->_error = nil;
  return result;
}

+ (NSString *)invitationUriInPairingInfo:(NSDictionary *)pairingInfo {
  if (![pairingInfo isKindOfClass:[NSDictionary class]]) return @"";
  id token = [pairingInfo objectForKey:@"token"];
  id uri = [token isKindOfClass:[NSDictionary class]]
      ? [(NSDictionary *)token objectForKey:@"uri"] : nil;
  return [uri isKindOfClass:[NSString class]] ? (NSString *)uri : @"";
}

@end
