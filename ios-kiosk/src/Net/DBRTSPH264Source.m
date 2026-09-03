#import "DBRTSPH264Source.h"

#import "DBRTPH264Depacketizer.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netdb.h>
#import <netinet/in.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <unistd.h>

static const NSUInteger kDBRTSPMaxHeaderBytes = 32 * 1024;
static const NSUInteger kDBRTSPMaxBodyBytes = 64 * 1024;
static const NSUInteger kDBRTSPMaxBufferedBytes = 128 * 1024;
static const NSUInteger kDBRTSPMaxInterleavedFrameBytes = 32 * 1024;
static const NSUInteger kDBRTSPMaxRequestBytes = 16 * 1024;
static const NSTimeInterval kDBRTSPHandshakeTimeout = 12.0;

static NSRange DBFindHeaderEnd(NSData *data) {
  const uint8_t *bytes = [data bytes];
  NSUInteger length = [data length];
  if (length < 4) return NSMakeRange(NSNotFound, 0);
  for (NSUInteger i = 0; i + 3 < length; i++) {
    if (bytes[i] == '\r' && bytes[i + 1] == '\n' && bytes[i + 2] == '\r' &&
        bytes[i + 3] == '\n')
      return NSMakeRange(i, 4);
  }
  return NSMakeRange(NSNotFound, 0);
}

static NSDictionary *DBParseRTSPHeader(NSData *headerData, NSString **error) {
  if ([headerData length] == 0 || [headerData length] > kDBRTSPMaxHeaderBytes) {
    if (error) *error = @"rtsp_header_oversized";
    return nil;
  }
  NSString *header = [[NSString alloc] initWithData:headerData
                                           encoding:NSISOLatin1StringEncoding];
  NSArray *lines = [header componentsSeparatedByString:@"\r\n"];
  if ([lines count] == 0) {
    if (error) *error = @"rtsp_header_malformed";
    return nil;
  }
  NSString *statusLine = [lines objectAtIndex:0];
  NSArray *statusParts = [statusLine componentsSeparatedByCharactersInSet:
      [NSCharacterSet whitespaceCharacterSet]];
  NSMutableArray *compact = [NSMutableArray array];
  for (NSString *part in statusParts)
    if ([part length] > 0) [compact addObject:part];
  if ([compact count] < 2 || ![[compact objectAtIndex:0] isEqualToString:@"RTSP/1.0"]) {
    if (error) *error = @"rtsp_status_malformed";
    return nil;
  }
  NSString *rawStatus = [compact objectAtIndex:1];
  NSInteger status = [rawStatus integerValue];
  if ([rawStatus length] != 3 || [rawStatus rangeOfCharacterFromSet:
      [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound ||
      status < 100 || status > 999) {
    if (error) *error = @"rtsp_status_malformed";
    return nil;
  }
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  for (NSUInteger i = 1; i < [lines count]; i++) {
    NSString *line = [lines objectAtIndex:i];
    if ([line length] == 0) continue;
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound || colon.location == 0) {
      if (error) *error = @"rtsp_header_malformed";
      return nil;
    }
    NSString *name = [[[line substringToIndex:colon.location]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
    NSString *value = [[line substringFromIndex:colon.location + 1]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([name length] == 0 || [value rangeOfCharacterFromSet:
        [NSCharacterSet newlineCharacterSet]].location != NSNotFound) {
      if (error) *error = @"rtsp_header_malformed";
      return nil;
    }
    if ([headers objectForKey:name]) {
      if ([name isEqualToString:@"content-length"] || [name isEqualToString:@"cseq"]) {
        if (error) *error = @"rtsp_header_duplicate";
        return nil;
      }
      value = [NSString stringWithFormat:@"%@, %@", [headers objectForKey:name], value];
    }
    [headers setObject:value forKey:name];
  }
  return @{ @"status" : @(status), @"headers" : headers };
}

static BOOL DBParseContentLength(NSDictionary *headers, NSUInteger *length, NSString **error) {
  NSString *raw = [headers objectForKey:@"content-length"];
  if ([raw length] == 0) {
    if (length) *length = 0;
    return YES;
  }
  if ([raw length] > 10 || [raw rangeOfCharacterFromSet:
      [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) {
    if (error) *error = @"rtsp_content_length_malformed";
    return NO;
  }
  unsigned long long parsed = strtoull([raw UTF8String], NULL, 10);
  if (parsed > kDBRTSPMaxBodyBytes) {
    if (error) *error = @"rtsp_body_oversized";
    return NO;
  }
  if (length) *length = (NSUInteger)parsed;
  return YES;
}

@implementation DBRTSPResponseParser {
  NSMutableData *_buffer;
  NSString *_errorReason;
}

@synthesize errorReason = _errorReason;

- (id)init {
  self = [super init];
  if (self) _buffer = [[NSMutableData alloc] init];
  return self;
}

- (NSDictionary *)appendData:(NSData *)data {
  if (_errorReason || [data length] == 0) return nil;
  if ([_buffer length] + [data length] > kDBRTSPMaxBufferedBytes) {
    _errorReason = @"rtsp_response_oversized";
    return nil;
  }
  [_buffer appendData:data];
  NSRange headerEnd = DBFindHeaderEnd(_buffer);
  if (headerEnd.location == NSNotFound) {
    if ([_buffer length] > kDBRTSPMaxHeaderBytes)
      _errorReason = @"rtsp_header_oversized";
    return nil;
  }
  NSUInteger headerLength = NSMaxRange(headerEnd);
  NSString *parseError = nil;
  NSDictionary *parsed = DBParseRTSPHeader(
      [_buffer subdataWithRange:NSMakeRange(0, headerEnd.location)], &parseError);
  if (!parsed) {
    _errorReason = parseError ?: @"rtsp_header_malformed";
    return nil;
  }
  NSUInteger bodyLength = 0;
  if (!DBParseContentLength([parsed objectForKey:@"headers"], &bodyLength, &parseError)) {
    _errorReason = parseError;
    return nil;
  }
  NSUInteger total = headerLength + bodyLength;
  if ([_buffer length] < total) return nil;
  NSData *body = bodyLength > 0
      ? [_buffer subdataWithRange:NSMakeRange(headerLength, bodyLength)] : [NSData data];
  NSMutableDictionary *response = [parsed mutableCopy];
  [response setObject:body forKey:@"body"];
  [_buffer replaceBytesInRange:NSMakeRange(0, total) withBytes:NULL length:0];
  return response;
}

- (NSData *)drainRemainingData {
  NSData *remaining = [_buffer copy];
  [_buffer setLength:0];
  return remaining;
}

@end

@implementation DBRTSPInterleavedParser {
  NSMutableData *_buffer;
  DBRTSPInterleavedFrameHandler _handler;
  NSString *_errorReason;
}

@synthesize errorReason = _errorReason;

- (id)initWithFrameHandler:(DBRTSPInterleavedFrameHandler)handler {
  self = [super init];
  if (self) {
    _buffer = [[NSMutableData alloc] init];
    _handler = [handler copy];
  }
  return self;
}

- (BOOL)fail:(NSString *)reason {
  _errorReason = [reason copy];
  [_buffer setLength:0];
  return NO;
}

- (BOOL)appendData:(NSData *)data {
  if (_errorReason) return NO;
  if ([_buffer length] + [data length] > kDBRTSPMaxBufferedBytes)
    return [self fail:@"rtsp_stream_buffer_oversized"];
  [_buffer appendData:data];
  while ([_buffer length] > 0) {
    const uint8_t *bytes = [_buffer bytes];
    if (bytes[0] == '$') {
      if ([_buffer length] < 4) return YES;
      NSUInteger frameLength = ((NSUInteger)bytes[2] << 8) | bytes[3];
      if (frameLength == 0 || frameLength > kDBRTSPMaxInterleavedFrameBytes)
        return [self fail:@"rtsp_interleaved_frame_oversized"];
      if ([_buffer length] < frameLength + 4) return YES;
      uint8_t channel = bytes[1];
      NSData *frame = [_buffer subdataWithRange:NSMakeRange(4, frameLength)];
      [_buffer replaceBytesInRange:NSMakeRange(0, frameLength + 4) withBytes:NULL length:0];
      if (_handler && !_handler(channel, frame))
        return [self fail:@"rtp_packet_rejected"];
      continue;
    }
    NSRange headerEnd = DBFindHeaderEnd(_buffer);
    if (headerEnd.location == NSNotFound) {
      if ([_buffer length] > kDBRTSPMaxHeaderBytes)
        return [self fail:@"rtsp_keepalive_header_oversized"];
      return YES;
    }
    NSString *parseError = nil;
    NSDictionary *parsed = DBParseRTSPHeader(
        [_buffer subdataWithRange:NSMakeRange(0, headerEnd.location)], &parseError);
    if (!parsed) return [self fail:parseError ?: @"rtsp_keepalive_malformed"];
    NSUInteger bodyLength = 0;
    if (!DBParseContentLength([parsed objectForKey:@"headers"], &bodyLength, &parseError))
      return [self fail:parseError];
    NSUInteger total = NSMaxRange(headerEnd) + bodyLength;
    if ([_buffer length] < total) return YES;
    [_buffer replaceBytesInRange:NSMakeRange(0, total) withBytes:NULL length:0];
  }
  return YES;
}

@end

static int DBBase64Value(unichar c) {
  if (c >= 'A' && c <= 'Z') return (int)(c - 'A');
  if (c >= 'a' && c <= 'z') return (int)(c - 'a') + 26;
  if (c >= '0' && c <= '9') return (int)(c - '0') + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

static NSData *DBDecodeBase64(NSString *value) {
  if ([value length] == 0 || [value length] > 2048 || ([value length] % 4) != 0)
    return nil;
  NSMutableData *out = [NSMutableData dataWithCapacity:([value length] / 4) * 3];
  for (NSUInteger i = 0; i < [value length]; i += 4) {
    int a = DBBase64Value([value characterAtIndex:i]);
    int b = DBBase64Value([value characterAtIndex:i + 1]);
    unichar cch = [value characterAtIndex:i + 2];
    unichar dch = [value characterAtIndex:i + 3];
    int c = cch == '=' ? 0 : DBBase64Value(cch);
    int d = dch == '=' ? 0 : DBBase64Value(dch);
    if (a < 0 || b < 0 || c < 0 || d < 0 || (cch == '=' && dch != '=') ||
        (i + 4 != [value length] && (cch == '=' || dch == '='))) return nil;
    uint8_t bytes[3] = {(uint8_t)((a << 2) | (b >> 4)),
                        (uint8_t)((b << 4) | (c >> 2)),
                        (uint8_t)((c << 6) | d)};
    [out appendBytes:bytes length:cch == '=' ? 1 : (dch == '=' ? 2 : 3)];
  }
  return out;
}

static NSString *DBEncodeBase64(NSData *data) {
  static const char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const uint8_t *bytes = [data bytes];
  NSUInteger length = [data length];
  if (length == 0 || length > 2048) return nil;
  NSMutableString *out = [NSMutableString stringWithCapacity:((length + 2) / 3) * 4];
  for (NSUInteger i = 0; i < length; i += 3) {
    NSUInteger remaining = length - i;
    uint32_t block = (uint32_t)bytes[i] << 16;
    if (remaining > 1) block |= (uint32_t)bytes[i + 1] << 8;
    if (remaining > 2) block |= bytes[i + 2];
    [out appendFormat:@"%c%c%c%c", alphabet[(block >> 18) & 63],
                      alphabet[(block >> 12) & 63],
                      remaining > 1 ? alphabet[(block >> 6) & 63] : '=',
                      remaining > 2 ? alphabet[block & 63] : '='];
  }
  return out;
}

static NSString *DBSafeRTSPURL(NSString *raw) {
  if ([raw length] == 0 || [raw length] > 4096) return nil;
  NSURL *url = [NSURL URLWithString:raw];
  if (![[[url scheme] lowercaseString] isEqualToString:@"rtsp"] ||
      [[url host] length] == 0 || [[url user] length] > 0 || [[url password] length] > 0)
    return nil;
  if ([raw rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound)
    return nil;
  return [url absoluteString];
}

static NSString *DBResolveControlURL(NSString *control, NSString *contentBase,
                                     NSString *requestURL) {
  if ([control length] == 0) return nil;
  if ([control isEqualToString:@"*"]) return DBSafeRTSPURL(requestURL);
  NSURL *base = [NSURL URLWithString:([contentBase length] ? contentBase : requestURL)];
  NSURL *resolved = [NSURL URLWithString:control relativeToURL:base];
  return DBSafeRTSPURL([resolved absoluteString]);
}

@interface DBRTSPH264Source ()
- (void)runGeneration:(NSUInteger)generation;
@end

@implementation DBRTSPH264Source {
  NSString *_urlString;
  DBRTSPCredentialProvider _credentialProvider;
  DBRTSPH264FrameHandler _frameHandler;
  DBRTSPH264StateHandler _stateHandler;
  dispatch_queue_t _queue;
  NSLock *_socketLock;
  NSLock *_writeLock;
  int _socket;
  BOOL _stopped;
  NSUInteger _generation;
  NSUInteger _reconnectAttempt;
  NSString *_state;
  BOOL _forwardingMeasured;
  NSString *_authorization;
  NSInteger _cseq;
  NSString *_session;
  uint8_t _rtpChannel;
  uint8_t _payloadType;
  uint32_t _mediaSSRC;
  DBRTPH264Depacketizer *_depacketizer;
}

@synthesize state = _state;
@synthesize forwardingMeasured = _forwardingMeasured;

+ (NSTimeInterval)reconnectDelayForAttempt:(NSUInteger)attempt {
  static const NSTimeInterval delays[] = {2, 5, 10, 30, 60};
  return delays[MIN(attempt, (NSUInteger)4)];
}

+ (NSString *)basicAuthorizationForSecret:(NSString *)secret {
  if (![secret isKindOfClass:[NSString class]] || [secret length] == 0 ||
      [secret length] > 1024) return nil;
  NSString *username = nil;
  NSString *password = nil;
  NSData *jsonData = [secret dataUsingEncoding:NSUTF8StringEncoding];
  id json = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:NULL] : nil;
  if ([json isKindOfClass:[NSDictionary class]]) {
    id u = [json objectForKey:@"username"];
    id p = [json objectForKey:@"password"];
    if ([u isKindOfClass:[NSString class]] && [p isKindOfClass:[NSString class]]) {
      username = u;
      password = p;
    }
  } else {
    NSRange colon = [secret rangeOfString:@":"];
    if (colon.location != NSNotFound) {
      username = [secret substringToIndex:colon.location];
      password = [secret substringFromIndex:colon.location + 1];
    }
  }
  if ([username length] == 0 || [username length] > 256 || [password length] > 512)
    return nil;
  NSCharacterSet *unsafe = [NSCharacterSet controlCharacterSet];
  if ([username rangeOfCharacterFromSet:unsafe].location != NSNotFound ||
      [password rangeOfCharacterFromSet:unsafe].location != NSNotFound)
    return nil;
  NSString *joined = [NSString stringWithFormat:@"%@:%@", username, password];
  NSString *encoded = DBEncodeBase64([joined dataUsingEncoding:NSUTF8StringEncoding]);
  return [encoded length] ? [@"Basic " stringByAppendingString:encoded] : nil;
}

+ (NSDictionary *)parseH264SDP:(NSData *)data contentBase:(NSString *)contentBase
                    requestURL:(NSString *)requestURL error:(NSString **)error {
  if ([data length] == 0 || [data length] > kDBRTSPMaxBodyBytes) {
    if (error) *error = @"sdp_oversized_or_empty";
    return nil;
  }
  NSString *sdp = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!sdp) sdp = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
  if (!sdp) {
    if (error) *error = @"sdp_encoding_invalid";
    return nil;
  }
  NSArray *rawLines = [sdp componentsSeparatedByCharactersInSet:
      [NSCharacterSet newlineCharacterSet]];
  NSMutableArray *videoLines = nil;
  NSMutableArray *videoPayloads = nil;
  NSMutableArray *videoSections = [NSMutableArray array];
  for (NSString *rawLine in rawLines) {
    NSString *line = [rawLine stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([line hasPrefix:@"m="]) {
      if (videoLines && videoPayloads)
        [videoSections addObject:@{ @"lines" : videoLines, @"payloads" : videoPayloads }];
      videoLines = nil;
      videoPayloads = nil;
      NSArray *parts = [line componentsSeparatedByCharactersInSet:
          [NSCharacterSet whitespaceCharacterSet]];
      NSMutableArray *compact = [NSMutableArray array];
      for (NSString *part in parts) if ([part length]) [compact addObject:part];
      if ([compact count] >= 4 && [[compact objectAtIndex:0] isEqualToString:@"m=video"] &&
          ([[compact objectAtIndex:2] isEqualToString:@"RTP/AVP"] ||
           [[compact objectAtIndex:2] isEqualToString:@"RTP/AVP/TCP"])) {
        videoLines = [NSMutableArray array];
        videoPayloads = [NSMutableArray array];
        for (NSUInteger i = 3; i < [compact count]; i++) {
          NSInteger payload = [[compact objectAtIndex:i] integerValue];
          if (payload >= 0 && payload <= 127) [videoPayloads addObject:@(payload)];
        }
      }
    } else if (videoLines) {
      [videoLines addObject:line];
    }
    if (videoLines && [videoLines count] > 512) {
      if (error) *error = @"sdp_too_many_lines";
      return nil;
    }
  }
  if (videoLines && videoPayloads)
    [videoSections addObject:@{ @"lines" : videoLines, @"payloads" : videoPayloads }];
  if ([videoSections count] == 0) {
    if (error) *error = @"sdp_h264_video_missing";
    return nil;
  }
  NSInteger selected = -1;
  NSString *control = nil;
  NSMutableDictionary *fmtpByPayload = [NSMutableDictionary dictionary];
  for (NSDictionary *section in videoSections) {
    NSArray *sectionLines = [section objectForKey:@"lines"];
    NSArray *sectionPayloads = [section objectForKey:@"payloads"];
    NSString *sectionControl = nil;
    NSMutableDictionary *sectionFmtp = [NSMutableDictionary dictionary];
    NSInteger sectionSelected = -1;
    for (NSString *line in sectionLines) {
      if ([line hasPrefix:@"a=control:"]) sectionControl = [line substringFromIndex:10];
      if ([line hasPrefix:@"a=rtpmap:"]) {
        NSString *value = [line substringFromIndex:9];
        NSRange space = [value rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
        if (space.location == NSNotFound) continue;
        NSInteger payload = [[value substringToIndex:space.location] integerValue];
        NSString *codec = [[value substringFromIndex:space.location + 1] uppercaseString];
        if ([codec hasPrefix:@"H264/90000"] && [sectionPayloads containsObject:@(payload)])
          sectionSelected = payload;
      } else if ([line hasPrefix:@"a=fmtp:"]) {
        NSString *value = [line substringFromIndex:7];
        NSRange space = [value rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
        if (space.location == NSNotFound) continue;
        NSInteger payload = [[value substringToIndex:space.location] integerValue];
        [sectionFmtp setObject:[value substringFromIndex:space.location + 1]
                         forKey:@(payload)];
      }
    }
    if (sectionSelected >= 0) {
      selected = sectionSelected;
      control = sectionControl;
      fmtpByPayload = sectionFmtp;
      break;
    }
  }
  if (selected < 0 || [control length] == 0) {
    if (error) *error = @"sdp_h264_mapping_missing";
    return nil;
  }
  NSString *fmtp = [fmtpByPayload objectForKey:@(selected)] ?: @"";
  NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
  for (NSString *rawPart in [fmtp componentsSeparatedByString:@";"]) {
    NSString *part = [rawPart stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    NSRange equals = [part rangeOfString:@"="];
    if (equals.location == NSNotFound) continue;
    NSString *name = [[part substringToIndex:equals.location] lowercaseString];
    NSString *value = [part substringFromIndex:equals.location + 1];
    if ([name length] && [value length]) [parameters setObject:value forKey:name];
  }
  NSString *packetization = [parameters objectForKey:@"packetization-mode"];
  if ([packetization length] && ![packetization isEqualToString:@"1"]) {
    if (error) *error = @"sdp_packetization_mode_unsupported";
    return nil;
  }
  NSString *profile = [[parameters objectForKey:@"profile-level-id"] uppercaseString];
  if ([profile length] >= 2 && ![[profile substringToIndex:2] isEqualToString:@"42"]) {
    if (error) *error = @"sdp_profile_not_baseline";
    return nil;
  }
  NSString *controlURL = DBResolveControlURL(control, contentBase, requestURL);
  if (![controlURL length]) {
    if (error) *error = @"sdp_control_url_invalid";
    return nil;
  }
  NSMutableDictionary *result = [@{ @"payload_type" : @(selected),
                                     @"control_url" : controlURL } mutableCopy];
  NSString *sprop = [parameters objectForKey:@"sprop-parameter-sets"];
  NSArray *sets = [sprop componentsSeparatedByString:@","];
  if ([sets count] >= 2) {
    NSData *sps = DBDecodeBase64([sets objectAtIndex:0]);
    NSData *pps = DBDecodeBase64([sets objectAtIndex:1]);
    if (!sps || !pps || [sps length] < 2 || [pps length] < 2 ||
        ((((const uint8_t *)[sps bytes])[0] & 0x1f) != 7) ||
        ((((const uint8_t *)[pps bytes])[0] & 0x1f) != 8) ||
        ((const uint8_t *)[sps bytes])[1] != 66) {
      if (error) *error = @"sdp_parameter_sets_invalid";
      return nil;
    }
    [result setObject:sps forKey:@"sps"];
    [result setObject:pps forKey:@"pps"];
  }
  return result;
}

- (id)initWithURLString:(NSString *)urlString
     credentialProvider:(DBRTSPCredentialProvider)credentialProvider
            frameHandler:(DBRTSPH264FrameHandler)frameHandler
            stateHandler:(DBRTSPH264StateHandler)stateHandler {
  self = [super init];
  if (self) {
    _urlString = [DBSafeRTSPURL(urlString) copy];
    _credentialProvider = [credentialProvider copy];
    _frameHandler = [frameHandler copy];
    _stateHandler = [stateHandler copy];
    _queue = dispatch_queue_create("doorbell.rtsp.h264", DISPATCH_QUEUE_SERIAL);
    _socketLock = [[NSLock alloc] init];
    _writeLock = [[NSLock alloc] init];
    _socket = -1;
    _stopped = YES;
    _state = [_urlString length] ? @"idle" : @"invalid";
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (BOOL)isCurrentGeneration:(NSUInteger)generation {
  @synchronized(self) { return !_stopped && generation == _generation; }
}

- (void)publishState:(NSString *)state reason:(NSString *)reason measured:(BOOL)measured {
  _state = [state copy] ?: @"unknown";
  _forwardingMeasured = measured;
  if (_stateHandler) _stateHandler(_state, reason ?: @"", measured);
}

- (void)start {
  if (![_urlString length]) {
    [self publishState:@"degraded" reason:@"rtsp_url_invalid" measured:NO];
    return;
  }
  NSUInteger generation = 0;
  @synchronized(self) {
    if (!_stopped) return;
    _stopped = NO;
    _generation++;
    generation = _generation;
    _reconnectAttempt = 0;
  }
  [self publishState:@"starting" reason:@"" measured:NO];
  dispatch_async(_queue, ^{ [self runGeneration:generation]; });
}

- (void)closeSocket {
  [_writeLock lock];
  [_socketLock lock];
  int fd = _socket;
  _socket = -1;
  [_socketLock unlock];
  if (fd >= 0) {
    shutdown(fd, SHUT_RDWR);
    close(fd);
  }
  [_writeLock unlock];
}

- (void)stop {
  BOOL notify = NO;
  @synchronized(self) {
    notify = !_stopped || _forwardingMeasured;
    _stopped = YES;
    _generation++;
  }
  [self closeSocket];
  if (notify) [self publishState:@"stopped" reason:@"profile_or_memory_stop" measured:NO];
}

- (int)connectSocket:(NSString **)reason {
  NSURL *url = [NSURL URLWithString:_urlString];
  NSString *host = [url host];
  NSInteger port = [[url port] integerValue];
  if (port <= 0) port = 554;
  char portString[16];
  snprintf(portString, sizeof(portString), "%ld", (long)port);
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_family = AF_UNSPEC;
  struct addrinfo *addresses = NULL;
  int lookup = getaddrinfo([host UTF8String], portString, &hints, &addresses);
  if (lookup != 0 || !addresses) {
    if (reason) *reason = @"rtsp_dns_failed";
    return -1;
  }
  int connected = -1;
  NSUInteger candidateCount = 0;
  for (struct addrinfo *candidate = addresses; candidate && candidateCount < 4;
       candidate = candidate->ai_next, candidateCount++) {
    int fd = socket(candidate->ai_family, candidate->ai_socktype, candidate->ai_protocol);
    if (fd < 0) continue;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int result = connect(fd, candidate->ai_addr, candidate->ai_addrlen);
    if (result < 0 && errno == EINPROGRESS) {
      fd_set writes;
      FD_ZERO(&writes);
      FD_SET(fd, &writes);
      struct timeval timeout = {2, 0};
      result = select(fd + 1, NULL, &writes, NULL, &timeout);
      if (result > 0) {
        int socketError = 0;
        socklen_t errorLength = sizeof(socketError);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength);
        result = socketError == 0 ? 0 : -1;
      } else {
        result = -1;
      }
    }
    if (result == 0) {
      fcntl(fd, F_SETFL, flags);
      struct timeval ioTimeout = {5, 0};
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &ioTimeout, sizeof(ioTimeout));
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, sizeof(ioTimeout));
      connected = fd;
      break;
    }
    close(fd);
  }
  freeaddrinfo(addresses);
  if (connected < 0 && reason) *reason = @"rtsp_connect_failed";
  return connected;
}

- (BOOL)installSocket:(int)fd generation:(NSUInteger)generation {
  if (![self isCurrentGeneration:generation]) {
    close(fd);
    return NO;
  }
  [_socketLock lock];
  _socket = fd;
  [_socketLock unlock];
  return YES;
}

- (BOOL)sendBytesUnlocked:(NSData *)data socket:(int)fd {
  if ([data length] == 0 || [data length] > kDBRTSPMaxRequestBytes) return NO;
  const uint8_t *bytes = [data bytes];
  NSUInteger sent = 0;
  while (sent < [data length]) {
    ssize_t n = send(fd, bytes + sent, [data length] - sent, 0);
    if (n <= 0) {
      if (errno == EINTR) continue;
      return NO;
    }
    sent += (NSUInteger)n;
  }
  return YES;
}

- (BOOL)sendBytes:(NSData *)data socket:(int)fd {
  [_writeLock lock];
  BOOL sent = [self sendBytesUnlocked:data socket:fd];
  [_writeLock unlock];
  return sent;
}

- (BOOL)requestKeyFrame {
  [_writeLock lock];
  [_socketLock lock];
  int fd = _socket;
  uint8_t channel = (uint8_t)(_rtpChannel + 1);
  uint32_t mediaSSRC = _mediaSSRC;
  [_socketLock unlock];
  if (fd < 0 || mediaSSRC == 0) {
    [_writeLock unlock];
    return NO;
  }
  uint8_t packet[16] = {
    '$', channel, 0, 12,
    0x81, 206, 0, 2,
    0x44, 0x42, 0x4c, 0x4c,
    (uint8_t)(mediaSSRC >> 24), (uint8_t)(mediaSSRC >> 16),
    (uint8_t)(mediaSSRC >> 8), (uint8_t)mediaSSRC,
  };
  BOOL sent = [self sendBytesUnlocked:[NSData dataWithBytes:packet length:sizeof(packet)] socket:fd];
  [_writeLock unlock];
  return sent;
}

- (BOOL)sendMethod:(NSString *)method target:(NSString *)target headers:(NSDictionary *)headers
             socket:(int)fd {
  if ([method length] == 0 || [target length] == 0) return NO;
  NSMutableString *request = [NSMutableString stringWithFormat:@"%@ %@ RTSP/1.0\r\n",
                                                               method, target];
  [request appendFormat:@"CSeq: %ld\r\n", (long)++_cseq];
  [request appendString:@"User-Agent: Doorbell-iOSCompat/1\r\n"];
  if ([_authorization length]) [request appendFormat:@"Authorization: %@\r\n", _authorization];
  for (NSString *name in headers) {
    NSString *value = [headers objectForKey:name];
    if ([name rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound ||
        [value rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound)
      return NO;
    [request appendFormat:@"%@: %@\r\n", name, value];
  }
  [request appendString:@"\r\n"];
  return [self sendBytes:[request dataUsingEncoding:NSUTF8StringEncoding] socket:fd];
}

- (NSDictionary *)readResponse:(int)fd parser:(DBRTSPResponseParser *)parser
                         reason:(NSString **)reason {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kDBRTSPHandshakeTimeout];
  for (;;) {
    NSDictionary *ready = [parser appendData:[NSData data]];
    if (ready) return ready;
    if ([parser.errorReason length]) {
      if (reason) *reason = parser.errorReason;
      return nil;
    }
    if ([deadline timeIntervalSinceNow] <= 0) {
      if (reason) *reason = @"rtsp_handshake_timeout";
      return nil;
    }
    uint8_t buffer[8192];
    ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
    if (n > 0) {
      ready = [parser appendData:[NSData dataWithBytes:buffer length:(NSUInteger)n]];
      if (ready) return ready;
      continue;
    }
    if (n < 0 && (errno == EINTR)) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
    if (reason) *reason = @"rtsp_connection_closed";
    return nil;
  }
}

- (NSDictionary *)performMethod:(NSString *)method target:(NSString *)target
                         headers:(NSDictionary *)headers socket:(int)fd
                          parser:(DBRTSPResponseParser *)parser reason:(NSString **)reason {
  for (NSUInteger authAttempt = 0; authAttempt < 2; authAttempt++) {
    if (![self sendMethod:method target:target headers:headers socket:fd]) {
      if (reason) *reason = @"rtsp_send_failed";
      return nil;
    }
    NSDictionary *response = [self readResponse:fd parser:parser reason:reason];
    if (!response) return nil;
    NSString *responseCSeq = [[response objectForKey:@"headers"] objectForKey:@"cseq"];
    NSString *expectedCSeq = [NSString stringWithFormat:@"%ld", (long)_cseq];
    if (![responseCSeq isEqualToString:expectedCSeq]) {
      if (reason) *reason = @"rtsp_cseq_mismatch";
      return nil;
    }
    NSInteger status = [[response objectForKey:@"status"] integerValue];
    if (status != 401) return response;
    NSString *challenge = [[response objectForKey:@"headers"] objectForKey:@"www-authenticate"];
    NSString *trimmed = [challenge stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    if ([trimmed rangeOfString:@"Basic" options:NSCaseInsensitiveSearch].location != 0) {
      if (reason) *reason = @"rtsp_auth_scheme_unsupported";
      return nil;
    }
    NSString *secret = _credentialProvider ? _credentialProvider() : nil;
    _authorization = [[self class] basicAuthorizationForSecret:secret];
    secret = nil;
    if (![_authorization length]) {
      if (reason) *reason = @"rtsp_secret_unavailable";
      return nil;
    }
  }
  if (reason) *reason = @"rtsp_auth_failed";
  return nil;
}

- (NSString *)sessionFromResponse:(NSDictionary *)response {
  NSString *raw = [[response objectForKey:@"headers"] objectForKey:@"session"];
  NSString *session = [[raw componentsSeparatedByString:@";"] objectAtIndex:0];
  session = [session stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if ([session length] == 0 || [session length] > 256 ||
      [session rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound)
    return nil;
  return session;
}

- (BOOL)parseTransport:(NSDictionary *)response channel:(uint8_t *)channel {
  NSString *transport = [[response objectForKey:@"headers"] objectForKey:@"transport"];
  NSRange range = [transport rangeOfString:@"interleaved=" options:NSCaseInsensitiveSearch];
  if (range.location == NSNotFound) return NO;
  NSString *value = [transport substringFromIndex:NSMaxRange(range)];
  NSScanner *scanner = [NSScanner scannerWithString:value];
  NSInteger rtp = -1, rtcp = -1;
  if (![scanner scanInteger:&rtp] || ![scanner scanString:@"-" intoString:NULL] ||
      ![scanner scanInteger:&rtcp] || rtp < 0 || rtp > 255 || rtcp != rtp + 1 || rtcp > 255)
    return NO;
  if (channel) *channel = (uint8_t)rtp;
  return YES;
}

- (NSString *)streamSocket:(int)fd parser:(DBRTSPResponseParser *)responseParser
                  generation:(NSUInteger)generation {
  __block NSUInteger rejected = 0;
  __weak DBRTSPH264Source *weakSelf = self;
  DBRTSPInterleavedParser *interleaved = [[DBRTSPInterleavedParser alloc]
      initWithFrameHandler:^BOOL(uint8_t channel, NSData *frame) {
    DBRTSPH264Source *source = weakSelf;
    if (!source || channel != source->_rtpChannel) return YES;
    if ([frame length] >= 12) {
      const uint8_t *bytes = [frame bytes];
      uint32_t ssrc = ((uint32_t)bytes[8] << 24) | ((uint32_t)bytes[9] << 16) |
                      ((uint32_t)bytes[10] << 8) | bytes[11];
      [source->_socketLock lock];
      source->_mediaSSRC = ssrc;
      [source->_socketLock unlock];
    }
    BOOL ok = [source->_depacketizer consumeRTPPacket:frame
                                  expectedPayloadType:source->_payloadType];
    if (!ok) rejected++;
    else rejected = 0;
    return rejected < 16;
  }];
  NSData *remaining = [responseParser drainRemainingData];
  if ([remaining length] && ![interleaved appendData:remaining]) return interleaved.errorReason;
  NSUInteger idleTimeouts = 0;
  while ([self isCurrentGeneration:generation]) {
    uint8_t buffer[8192];
    ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
    if (n > 0) {
      idleTimeouts = 0;
      if (![interleaved appendData:[NSData dataWithBytes:buffer length:(NSUInteger)n]])
        return interleaved.errorReason;
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      if (++idleTimeouts >= 3) {
        idleTimeouts = 0;
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        if ([_session length]) [headers setObject:_session forKey:@"Session"];
        if (![self sendMethod:@"OPTIONS" target:_urlString headers:headers socket:fd])
          return @"rtsp_keepalive_failed";
      }
      continue;
    }
    return @"rtsp_connection_closed";
  }
  return @"stopped";
}

- (NSString *)connectAndStreamGeneration:(NSUInteger)generation {
  NSString *reason = nil;
  int fd = [self connectSocket:&reason];
  if (fd < 0) return reason ?: @"rtsp_connect_failed";
  if (![self installSocket:fd generation:generation]) return @"stopped";
  _authorization = nil;
  _session = nil;
  _cseq = 0;
  [self publishState:@"negotiating" reason:@"" measured:NO];
  DBRTSPResponseParser *parser = [[DBRTSPResponseParser alloc] init];
  NSDictionary *response = [self performMethod:@"OPTIONS" target:_urlString headers:@{}
                                         socket:fd parser:parser reason:&reason];
  if (!response || [[response objectForKey:@"status"] integerValue] / 100 != 2)
    return reason ?: @"rtsp_options_failed";
  response = [self performMethod:@"DESCRIBE" target:_urlString
                         headers:@{ @"Accept" : @"application/sdp" }
                          socket:fd parser:parser reason:&reason];
  if (!response || [[response objectForKey:@"status"] integerValue] != 200)
    return reason ?: @"rtsp_describe_failed";
  NSString *contentBase = [[response objectForKey:@"headers"] objectForKey:@"content-base"];
  NSDictionary *sdp = [[self class] parseH264SDP:[response objectForKey:@"body"]
                                     contentBase:contentBase requestURL:_urlString error:&reason];
  if (!sdp) return reason ?: @"sdp_invalid";
  _payloadType = (uint8_t)[[sdp objectForKey:@"payload_type"] integerValue];
  NSString *controlURL = [sdp objectForKey:@"control_url"];
  response = [self performMethod:@"SETUP" target:controlURL
                         headers:@{ @"Transport" : @"RTP/AVP/TCP;unicast;interleaved=0-1" }
                          socket:fd parser:parser reason:&reason];
  if (!response || [[response objectForKey:@"status"] integerValue] != 200)
    return reason ?: @"rtsp_setup_failed";
  _session = [self sessionFromResponse:response];
  if (![_session length] || ![self parseTransport:response channel:&_rtpChannel])
    return @"rtsp_setup_contract_invalid";
  response = [self performMethod:@"PLAY" target:_urlString
                         headers:@{ @"Session" : _session, @"Range" : @"npt=0.000-" }
                          socket:fd parser:parser reason:&reason];
  if (!response || [[response objectForKey:@"status"] integerValue] != 200)
    return reason ?: @"rtsp_play_failed";

  _forwardingMeasured = NO;
  [_socketLock lock];
  _mediaSSRC = 0;
  [_socketLock unlock];
  __weak DBRTSPH264Source *weakSelf = self;
  _depacketizer = [[DBRTPH264Depacketizer alloc]
      initWithAccessUnitHandler:^(NSData *annexB, BOOL keyframe, uint32_t rtpTimestamp) {
    (void)rtpTimestamp;
    DBRTSPH264Source *source = weakSelf;
    if (!source) return;
    int64_t nowMs = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
    BOOL accepted = source->_frameHandler
        ? source->_frameHandler(annexB, keyframe, nowMs) : NO;
    if (!accepted) {
      [source->_depacketizer markTransportLoss];
      [source publishState:@"degraded" reason:@"encoded_frame_queue_full" measured:NO];
    } else if (keyframe && !source->_forwardingMeasured) {
      source->_reconnectAttempt = 0;
      [source publishState:@"forwarding" reason:@"" measured:YES];
    }
  }];
  [_depacketizer seedSPS:[sdp objectForKey:@"sps"] pps:[sdp objectForKey:@"pps"]];
  [self publishState:@"waiting_for_idr" reason:@"" measured:NO];
  return [self streamSocket:fd parser:parser generation:generation];
}

- (void)runGeneration:(NSUInteger)generation {
  @autoreleasepool {
    NSString *reason = [self connectAndStreamGeneration:generation];
    [self closeSocket];
    _authorization = nil;
    _session = nil;
    [_depacketizer reset];
    _depacketizer = nil;
    if (![self isCurrentGeneration:generation]) return;
    NSTimeInterval delay = [[self class] reconnectDelayForAttempt:_reconnectAttempt++];
    [self publishState:@"reconnecting" reason:reason ?: @"rtsp_disconnected" measured:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   _queue, ^{ [self runGeneration:generation]; });
  }
}

@end
