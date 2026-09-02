#import "DBHTTPMediaSupport.h"

static const NSUInteger DBHTTPMediaMaximumURLBytes = 4096;
static const NSUInteger DBHTTPMediaMaximumSecretBytes = 1024;
static const NSUInteger DBMJPEGMaximumHeaderBytes = 16 * 1024;
static const NSUInteger DBMJPEGMaximumFrameBytes = 4 * 1024 * 1024;

static NSString *DBHTTPBase64(NSData *data) {
  static const char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const uint8_t *bytes = [data bytes];
  NSUInteger length = [data length];
  if (length == 0 || length > 2048) return nil;
  NSMutableString *out = [NSMutableString stringWithCapacity:((length + 2) / 3) * 4];
  for (NSUInteger index = 0; index < length; index += 3) {
    NSUInteger remaining = length - index;
    uint32_t block = (uint32_t)bytes[index] << 16;
    if (remaining > 1) block |= (uint32_t)bytes[index + 1] << 8;
    if (remaining > 2) block |= bytes[index + 2];
    [out appendFormat:@"%c%c%c%c", alphabet[(block >> 18) & 63],
                      alphabet[(block >> 12) & 63],
                      remaining > 1 ? alphabet[(block >> 6) & 63] : '=',
                      remaining > 2 ? alphabet[block & 63] : '='];
  }
  return out;
}

static BOOL DBHTTPHeaderValueSafe(NSString *value, NSUInteger maximumLength) {
  if (![value isKindOfClass:[NSString class]] || [value length] == 0 ||
      [value length] > maximumLength) return NO;
  return [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location ==
      NSNotFound;
}

static int DBHTTPHexNibble(uint8_t value) {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  if (value >= 'A' && value <= 'F') return value - 'A' + 10;
  return -1;
}

static NSString *DBHTTPDecodedQueryName(NSString *raw) {
  NSData *encoded = [raw dataUsingEncoding:NSUTF8StringEncoding];
  const uint8_t *bytes = [encoded bytes];
  NSMutableData *decoded = [NSMutableData dataWithCapacity:[encoded length]];
  for (NSUInteger index = 0; index < [encoded length]; index++) {
    uint8_t value = bytes[index];
    if (value == '%' && index + 2 < [encoded length]) {
      int high = DBHTTPHexNibble(bytes[index + 1]);
      int low = DBHTTPHexNibble(bytes[index + 2]);
      if (high >= 0 && low >= 0) {
        value = (uint8_t)((high << 4) | low);
        index += 2;
      }
    } else if (value == '+') {
      value = ' ';
    }
    [decoded appendBytes:&value length:1];
  }
  NSString *name = [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding];
  return [name lowercaseString] ?: @"";
}

static BOOL DBHTTPURLQueryContainsCredential(NSURL *url) {
  if ([[url fragment] length] > 0) return YES;
  NSString *query = [url query];
  if (![query length]) return NO;
  NSSet *sensitive = [NSSet setWithObjects:@"token", @"key", @"k", @"api_key",
      @"apikey", @"password", @"pass", @"passwd", @"secret", @"credential",
      @"auth", @"authorization", @"access_token", @"bearer", @"signature", @"sig", nil];
  for (NSString *component in [query componentsSeparatedByCharactersInSet:
      [NSCharacterSet characterSetWithCharactersInString:@"&;"]]) {
    NSString *name = [[component componentsSeparatedByString:@"="] objectAtIndex:0];
    for (NSUInteger pass = 0; pass < 8; pass++) {
      NSString *decoded = DBHTTPDecodedQueryName(name);
      if ([decoded isEqualToString:name]) break;
      name = decoded;
    }
    if ([name rangeOfString:@"%"].location != NSNotFound) return YES;
    if ([sensitive containsObject:name] || [name hasSuffix:@"_token"] ||
        [name hasSuffix:@"_secret"] || [name hasSuffix:@"_signature"]) return YES;
  }
  return NO;
}

@implementation DBHTTPMediaSupport

+ (NSString *)safeURLString:(NSString *)raw {
  if (![raw isKindOfClass:[NSString class]] || [raw length] == 0 ||
      [raw lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > DBHTTPMediaMaximumURLBytes)
    return nil;
  NSString *value = [raw stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([value rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location !=
      NSNotFound) return nil;
  NSURL *url = [NSURL URLWithString:value];
  NSString *scheme = [[url scheme] lowercaseString];
  if ((! [scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) ||
      [[url host] length] == 0 || [[url user] length] > 0 || [[url password] length] > 0 ||
      DBHTTPURLQueryContainsCredential(url))
    return nil;
  return [url absoluteString];
}

+ (NSDictionary *)authorizationHeadersForSecret:(NSString *)secret {
  if (![secret isKindOfClass:[NSString class]] || [secret length] == 0 ||
      [secret lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
          DBHTTPMediaMaximumSecretBytes) return nil;

  NSString *username = nil;
  NSString *password = nil;
  NSString *bearer = nil;
  NSData *jsonData = [secret dataUsingEncoding:NSUTF8StringEncoding];
  id json = jsonData
      ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:NULL] : nil;
  if ([json isKindOfClass:[NSDictionary class]]) {
    id rawUsername = [json objectForKey:@"username"];
    id rawPassword = [json objectForKey:@"password"];
    id rawBearer = [json objectForKey:@"bearer_token"];
    if ([rawUsername isKindOfClass:[NSString class]] &&
        [rawPassword isKindOfClass:[NSString class]]) {
      username = rawUsername;
      password = rawPassword;
    } else if ([rawBearer isKindOfClass:[NSString class]]) {
      bearer = rawBearer;
    }
  } else if (![[secret stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]] hasPrefix:@"{"]) {
    NSRange colon = [secret rangeOfString:@":"];
    if (colon.location != NSNotFound) {
      username = [secret substringToIndex:colon.location];
      password = [secret substringFromIndex:colon.location + 1];
    }
  }

  NSString *authorization = nil;
  if (username != nil || password != nil) {
    if (!DBHTTPHeaderValueSafe(username, 256) || ![password isKindOfClass:[NSString class]] ||
        [password length] > 512 ||
        [password rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location !=
            NSNotFound) return nil;
    NSString *joined = [NSString stringWithFormat:@"%@:%@", username, password];
    NSString *encoded = DBHTTPBase64([joined dataUsingEncoding:NSUTF8StringEncoding]);
    if ([encoded length]) authorization = [@"Basic " stringByAppendingString:encoded];
  } else if (bearer != nil) {
    if (!DBHTTPHeaderValueSafe(bearer, 768)) return nil;
    authorization = [@"Bearer " stringByAppendingString:bearer];
  }
  return [authorization length] ? @{ @"Authorization" : authorization } : nil;
}

+ (NSMutableURLRequest *)requestWithURLString:(NSString *)urlString
                            credentialProvider:(DBHTTPMediaCredentialProvider)provider
                                        accept:(NSString *)accept
                                       timeout:(NSTimeInterval)timeout {
  NSString *safe = [self safeURLString:urlString];
  if (![safe length]) return nil;
  NSURL *url = [NSURL URLWithString:safe];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
      timeoutInterval:MAX(1.0, MIN(timeout, 30.0))];
  [request setHTTPShouldHandleCookies:NO];
  [request setValue:([accept length] ? accept : @"*/*") forHTTPHeaderField:@"Accept"];
  [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
  NSString *secret = provider ? provider() : nil;
  NSDictionary *headers = [self authorizationHeadersForSecret:secret];
  for (NSString *name in headers)
    [request setValue:[headers objectForKey:name] forHTTPHeaderField:name];
  return request;
}

+ (NSTimeInterval)reconnectDelayForAttempt:(NSUInteger)attempt {
  static const NSTimeInterval delays[] = {2, 5, 10, 30, 60};
  return delays[MIN(attempt, (NSUInteger)4)];
}

@end

@interface DBMJPEGMultipartParser ()
@property(nonatomic, readwrite, copy) NSString *errorReason;
@property(nonatomic, readwrite) int64_t lastCaptureTimeMs;
@property(nonatomic, readwrite) int64_t lastServerTimeMs;
@end

@implementation DBMJPEGMultipartParser {
  NSMutableData *_buffer;
  NSInteger _expectedBodyBytes;
  BOOL _markerDelimitedBody;
  int64_t _partCaptureTimeMs;
  int64_t _partServerTimeMs;
  DBMJPEGDataHandler _handler;
}

- (id)initWithFrameHandler:(DBMJPEGDataHandler)handler {
  self = [super init];
  if (self) {
    _buffer = [[NSMutableData alloc] init];
    _expectedBodyBytes = -1;
    _markerDelimitedBody = NO;
    _handler = [handler copy];
    _errorReason = @"";
  }
  return self;
}

- (NSUInteger)bufferedBytes {
  return [_buffer length];
}

- (void)reset {
  [_buffer setLength:0];
  _expectedBodyBytes = -1;
  _markerDelimitedBody = NO;
  _partCaptureTimeMs = 0;
  _partServerTimeMs = 0;
  self.lastCaptureTimeMs = 0;
  self.lastServerTimeMs = 0;
  self.errorReason = @"";
}

- (BOOL)fail:(NSString *)reason {
  self.errorReason = reason ?: @"multipart_invalid";
  [_buffer setLength:0];
  _expectedBodyBytes = -1;
  _markerDelimitedBody = NO;
  return NO;
}

- (NSRange)headerDelimiter {
  static const uint8_t crlf[] = {'\r', '\n', '\r', '\n'};
  NSRange range = [_buffer rangeOfData:[NSData dataWithBytes:crlf length:sizeof(crlf)]
                               options:0 range:NSMakeRange(0, [_buffer length])];
  if (range.location != NSNotFound) return NSMakeRange(range.location, sizeof(crlf));
  static const uint8_t lf[] = {'\n', '\n'};
  range = [_buffer rangeOfData:[NSData dataWithBytes:lf length:sizeof(lf)]
                       options:0 range:NSMakeRange(0, [_buffer length])];
  return range.location == NSNotFound ? range : NSMakeRange(range.location, sizeof(lf));
}

- (NSInteger)contentLengthInHeader:(NSData *)header {
  NSString *text = [[NSString alloc] initWithData:header encoding:NSISOLatin1StringEncoding];
  if (![text length]) return -1;
  for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:
      [NSCharacterSet newlineCharacterSet]]) {
    NSString *line = [rawLine stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) continue;
    NSString *name = [[[line substringToIndex:colon.location]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
        lowercaseString];
    if (![name isEqualToString:@"content-length"]) continue;
    NSString *rawValue = [[line substringFromIndex:colon.location + 1]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSScanner *scanner = [NSScanner scannerWithString:rawValue];
    long long value = 0;
    if (![scanner scanLongLong:&value] || ![scanner isAtEnd] || value <= 0 ||
        value > (long long)DBMJPEGMaximumFrameBytes) return -2;
    return (NSInteger)value;
  }
  return -1;
}

- (int64_t)longLongHeader:(NSString *)wanted inHeader:(NSData *)header {
  NSString *text = [[NSString alloc] initWithData:header encoding:NSISOLatin1StringEncoding];
  for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:
      [NSCharacterSet newlineCharacterSet]]) {
    NSString *line = [rawLine stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) continue;
    NSString *name = [[[line substringToIndex:colon.location]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
        lowercaseString];
    if (![name isEqualToString:wanted]) continue;
    NSString *rawValue = [[line substringFromIndex:colon.location + 1]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSScanner *scanner = [NSScanner scannerWithString:rawValue];
    long long value = 0;
    return [scanner scanLongLong:&value] && [scanner isAtEnd] && value > 0 ? value : 0;
  }
  return 0;
}

- (BOOL)emitJPEG:(NSData *)jpeg {
  if ([jpeg length] < 4 || [jpeg length] > DBMJPEGMaximumFrameBytes) return NO;
  const uint8_t *bytes = [jpeg bytes];
  if (bytes[0] != 0xff || bytes[1] != 0xd8 ||
      bytes[[jpeg length] - 2] != 0xff || bytes[[jpeg length] - 1] != 0xd9) return NO;
  self.lastCaptureTimeMs = _partCaptureTimeMs;
  self.lastServerTimeMs = _partServerTimeMs;
  if (_handler) _handler(jpeg);
  return YES;
}

- (BOOL)extractMarkerDelimitedJPEG:(BOOL *)needsMoreData {
  static const uint8_t soi[] = {0xff, 0xd8};
  static const uint8_t eoi[] = {0xff, 0xd9};
  NSRange start = [_buffer rangeOfData:[NSData dataWithBytes:soi length:sizeof(soi)]
                                options:0 range:NSMakeRange(0, [_buffer length])];
  if (start.location == NSNotFound) {
    if ([_buffer length] > DBMJPEGMaximumHeaderBytes) return NO;
    *needsMoreData = YES;
    return YES;
  }
  if (start.location > 0)
    [_buffer replaceBytesInRange:NSMakeRange(0, start.location) withBytes:NULL length:0];
  NSRange end = [_buffer rangeOfData:[NSData dataWithBytes:eoi length:sizeof(eoi)]
                              options:0
                                range:NSMakeRange(sizeof(soi), [_buffer length] - sizeof(soi))];
  if (end.location == NSNotFound) {
    if ([_buffer length] > DBMJPEGMaximumFrameBytes) return NO;
    *needsMoreData = YES;
    return YES;
  }
  NSUInteger frameLength = end.location + sizeof(eoi);
  NSData *jpeg = [_buffer subdataWithRange:NSMakeRange(0, frameLength)];
  [_buffer replaceBytesInRange:NSMakeRange(0, frameLength) withBytes:NULL length:0];
  if (![self emitJPEG:jpeg]) return NO;
  _expectedBodyBytes = -1;
  _markerDelimitedBody = NO;
  *needsMoreData = NO;
  return YES;
}

- (BOOL)appendData:(NSData *)data {
  if (![data isKindOfClass:[NSData class]] || [data length] == 0) return YES;
  NSUInteger maximumBuffered = DBMJPEGMaximumFrameBytes + DBMJPEGMaximumHeaderBytes;
  if ([data length] > maximumBuffered || [_buffer length] > maximumBuffered - [data length])
    return [self fail:@"multipart_buffer_limit"];
  [_buffer appendData:data];

  while ([_buffer length] > 0) {
    if (_markerDelimitedBody) {
      BOOL needsMore = NO;
      if (![self extractMarkerDelimitedJPEG:&needsMore])
        return [self fail:@"multipart_jpeg_invalid"];
      if (needsMore) return YES;
      continue;
    }
    if (_expectedBodyBytes < 0) {
      NSRange delimiter = [self headerDelimiter];
      if (delimiter.location == NSNotFound) {
        if ([_buffer length] > DBMJPEGMaximumHeaderBytes)
          return [self fail:@"multipart_header_limit"];
        return YES;
      }
      NSData *header = [_buffer subdataWithRange:NSMakeRange(0, delimiter.location)];
      NSInteger length = [self contentLengthInHeader:header];
      _partCaptureTimeMs = [self longLongHeader:@"x-doorbell-capture-time-ms"
                                      inHeader:header];
      _partServerTimeMs = [self longLongHeader:@"x-doorbell-server-time-ms"
                                     inHeader:header];
      if (length == -2) return [self fail:@"multipart_content_length_invalid"];
      [_buffer replaceBytesInRange:NSMakeRange(0, NSMaxRange(delimiter))
                         withBytes:NULL length:0];
      _expectedBodyBytes = length;
      if (_expectedBodyBytes < 0) {
        _markerDelimitedBody = YES;
        BOOL needsMore = NO;
        if (![self extractMarkerDelimitedJPEG:&needsMore])
          return [self fail:@"multipart_jpeg_invalid"];
        if (needsMore) return YES;
        continue;
      }
    }

    if ([_buffer length] < (NSUInteger)_expectedBodyBytes) return YES;
    NSData *jpeg = [_buffer subdataWithRange:NSMakeRange(0, (NSUInteger)_expectedBodyBytes)];
    [_buffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)_expectedBodyBytes)
                       withBytes:NULL length:0];
    _expectedBodyBytes = -1;
    if (![self emitJPEG:jpeg]) return [self fail:@"multipart_jpeg_invalid"];
  }
  return YES;
}

@end
