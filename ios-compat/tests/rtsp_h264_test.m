#import <Foundation/Foundation.h>

#import "DBRTPH264Depacketizer.h"
#import "DBRTSPH264Source.h"
#import <arpa/inet.h>
#import <pthread.h>
#import <sys/socket.h>
#import <unistd.h>

static void Check(BOOL condition, NSString *message) {
  if (condition) return;
  NSLog(@"FAIL: %@", message);
  exit(1);
}

static NSData *RTPPacket(uint16_t sequence, uint32_t timestamp, BOOL marker,
                         const uint8_t *payload, NSUInteger payloadLength) {
  NSMutableData *packet = [NSMutableData dataWithLength:12];
  uint8_t *header = [packet mutableBytes];
  header[0] = 0x80;
  header[1] = (marker ? 0x80 : 0) | 96;
  header[2] = (uint8_t)(sequence >> 8);
  header[3] = (uint8_t)sequence;
  header[4] = (uint8_t)(timestamp >> 24);
  header[5] = (uint8_t)(timestamp >> 16);
  header[6] = (uint8_t)(timestamp >> 8);
  header[7] = (uint8_t)timestamp;
  [packet appendBytes:payload length:payloadLength];
  return packet;
}

static NSData *Interleaved(uint8_t channel, NSData *frame) {
  uint8_t header[] = {'$', channel, (uint8_t)([frame length] >> 8), (uint8_t)[frame length]};
  NSMutableData *data = [NSMutableData dataWithBytes:header length:sizeof(header)];
  [data appendData:frame];
  return data;
}

typedef struct {
  int listener;
  int passed;
} FakeRTSPServer;

static BOOL SendAll(int fd, NSData *data) {
  const uint8_t *bytes = [data bytes];
  NSUInteger sent = 0;
  while (sent < [data length]) {
    ssize_t n = send(fd, bytes + sent, [data length] - sent, 0);
    if (n <= 0) return NO;
    sent += (NSUInteger)n;
  }
  return YES;
}

static NSString *ReadRequest(int fd) {
  NSMutableData *data = [NSMutableData data];
  while ([data length] < 16 * 1024) {
    uint8_t byte = 0;
    if (recv(fd, &byte, 1, 0) != 1) return nil;
    [data appendBytes:&byte length:1];
    NSUInteger length = [data length];
    if (length >= 4) {
      const uint8_t *bytes = [data bytes];
      if (bytes[length - 4] == '\r' && bytes[length - 3] == '\n' &&
          bytes[length - 2] == '\r' && bytes[length - 1] == '\n')
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
  }
  return nil;
}

static NSString *RequestCSeq(NSString *request) {
  for (NSString *line in [request componentsSeparatedByString:@"\r\n"]) {
    if ([[line lowercaseString] hasPrefix:@"cseq:"])
      return [[line substringFromIndex:5]
          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  }
  return nil;
}

static BOOL SendStatusResponse(int fd, NSString *request, NSInteger status,
                               NSString *statusText, NSArray *headers, NSData *body,
                               NSData *trailing) {
  NSString *cseq = RequestCSeq(request);
  if (![cseq length]) return NO;
  NSMutableString *wire = [NSMutableString stringWithFormat:
      @"RTSP/1.0 %ld %@\r\nCSeq: %@\r\n", (long)status, statusText, cseq];
  for (NSString *header in headers) [wire appendFormat:@"%@\r\n", header];
  if (body) [wire appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[body length]];
  [wire appendString:@"\r\n"];
  NSMutableData *data = [[wire dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  if (body) [data appendData:body];
  if (trailing) [data appendData:trailing];
  return SendAll(fd, data);
}

static BOOL SendResponse(int fd, NSString *request, NSArray *headers, NSData *body,
                         NSData *trailing) {
  return SendStatusResponse(fd, request, 200, @"OK", headers, body, trailing);
}

static void *RunFakeRTSPServer(void *context) {
  @autoreleasepool {
    FakeRTSPServer *server = context;
    int fd = accept(server->listener, NULL, NULL);
    if (fd < 0) return NULL;
    int yes = 1;
    NSString *request = nil;
    NSString *sdp = nil;
    NSData *sdpData = nil;
    NSData *rtp = nil;
    NSString *expectedAuthorization = nil;
    NSString *authorizationLine = nil;
    const uint8_t idr[] = {0x65, 0x88, 0x99, 0xaa};
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    request = ReadRequest(fd);
    if (![request hasPrefix:@"OPTIONS rtsp://"] ||
        [request rangeOfString:@"camera-user"].location != NSNotFound ||
        !SendStatusResponse(fd, request, 401, @"Unauthorized",
                            @[@"WWW-Authenticate: Basic realm=\"camera\""], nil, nil)) goto done;

    request = ReadRequest(fd);
    expectedAuthorization = [DBRTSPH264Source basicAuthorizationForSecret:
        @"{\"username\":\"camera-user\",\"password\":\"camera-password\"}"];
    authorizationLine = [NSString stringWithFormat:@"Authorization: %@", expectedAuthorization];
    if (![request hasPrefix:@"OPTIONS rtsp://"] ||
        [request rangeOfString:authorizationLine].location == NSNotFound ||
        !SendResponse(fd, request, @[], nil, nil)) goto done;

    request = ReadRequest(fd);
    sdp =
        @"v=0\r\n"
         "m=video 0 RTP/AVP 96\r\n"
         "a=rtpmap:96 H264/90000\r\n"
         "a=fmtp:96 packetization-mode=1;profile-level-id=42C01F;"
         "sprop-parameter-sets=Z0IAH5WoFAFuQA==,aM4G4g==\r\n"
         "a=control:trackID=1\r\n";
    sdpData = [sdp dataUsingEncoding:NSUTF8StringEncoding];
    if (![request hasPrefix:@"DESCRIBE rtsp://"] ||
        [request rangeOfString:@"Accept: application/sdp"].location == NSNotFound ||
        !SendResponse(fd, request,
                      @[@"Content-Type: application/sdp",
                        @"Content-Base: rtsp://127.0.0.1/live/"], sdpData, nil)) goto done;

    request = ReadRequest(fd);
    if (![request hasPrefix:@"SETUP rtsp://127.0.0.1/live/trackID=1"] ||
        [request rangeOfString:@"interleaved=0-1"].location == NSNotFound ||
        !SendResponse(fd, request,
                      @[@"Session: test-session;timeout=30",
                        @"Transport: RTP/AVP/TCP;unicast;interleaved=0-1"], nil, nil)) goto done;

    request = ReadRequest(fd);
    rtp = RTPPacket(1, 90000, YES, idr, sizeof(idr));
    if (![request hasPrefix:@"PLAY rtsp://"] ||
        [request rangeOfString:@"Session: test-session"].location == NSNotFound ||
        !SendResponse(fd, request, @[@"Session: test-session"], nil,
                      Interleaved(0, rtp))) goto done;
    server->passed = 1;
    usleep(100000);
  done:
    shutdown(fd, SHUT_RDWR);
    close(fd);
    close(server->listener);
  }
  return NULL;
}

static void TestRTSPResponseParser(void) {
  NSString *wire = @"RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: 4\r\n\r\ntest";
  NSMutableData *input = [[wire dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  uint8_t extra[] = {'$', 1, 0, 1, 0xff};
  [input appendBytes:extra length:sizeof(extra)];
  DBRTSPResponseParser *parser = [[DBRTSPResponseParser alloc] init];
  NSDictionary *response = nil;
  const uint8_t *bytes = [input bytes];
  for (NSUInteger i = 0; i < [input length]; i++) {
    NSDictionary *next = [parser appendData:[NSData dataWithBytes:bytes + i length:1]];
    if (next) response = next;
  }
  Check([[response objectForKey:@"status"] integerValue] == 200,
        @"fragmented RTSP status");
  Check([[[NSString alloc] initWithData:[response objectForKey:@"body"]
                                encoding:NSUTF8StringEncoding] isEqualToString:@"test"],
        @"fragmented RTSP body");
  Check([[parser drainRemainingData] length] == sizeof(extra),
        @"bytes after a response are retained for interleaved RTP");

  parser = [[DBRTSPResponseParser alloc] init];
  NSMutableData *oversized = [NSMutableData dataWithLength:33 * 1024];
  memset([oversized mutableBytes], 'x', [oversized length]);
  Check([parser appendData:oversized] == nil &&
        [parser.errorReason isEqualToString:@"rtsp_header_oversized"],
        @"oversized response header is rejected");

  parser = [[DBRTSPResponseParser alloc] init];
  NSData *duplicate = [@"RTSP/1.0 200 OK\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  Check([parser appendData:duplicate] == nil && [parser.errorReason length] > 0,
        @"duplicate framing headers are rejected");

  parser = [[DBRTSPResponseParser alloc] init];
  NSData *largeBody = [@"RTSP/1.0 200 OK\r\nContent-Length: 65537\r\n\r\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  Check([parser appendData:largeBody] == nil &&
        [parser.errorReason isEqualToString:@"rtsp_body_oversized"],
        @"oversized response body is rejected before allocation");
}

static void TestSDPAndCredentials(void) {
  NSString *sdpText =
      @"v=0\r\n"
       "m=video 0 RTP/AVP 96\r\n"
       "a=rtpmap:96 H264/90000\r\n"
       "a=fmtp:96 packetization-mode=1;profile-level-id=42C01F;"
       "sprop-parameter-sets=Z0IAH5WoFAFuQA==,aM4G4g==\r\n"
       "a=control:trackID=1\r\n"
       "m=audio 0 RTP/AVP 0\r\n";
  NSString *error = nil;
  NSDictionary *sdp = [DBRTSPH264Source
      parseH264SDP:[sdpText dataUsingEncoding:NSUTF8StringEncoding]
        contentBase:@"rtsp://192.0.2.20/live/" requestURL:@"rtsp://192.0.2.20/live"
             error:&error];
  Check(sdp != nil && [[sdp objectForKey:@"payload_type"] integerValue] == 96,
        [NSString stringWithFormat:@"H.264 SDP payload mapping: %@", error]);
  Check([[sdp objectForKey:@"control_url"] isEqualToString:
             @"rtsp://192.0.2.20/live/trackID=1"], @"relative media control URL");
  Check([[sdp objectForKey:@"sps"] length] > 0 && [[sdp objectForKey:@"pps"] length] > 0,
        @"SDP parameter sets decode");

  NSString *authorization = [DBRTSPH264Source basicAuthorizationForSecret:
      @"{\"username\":\"camera-user\",\"password\":\"camera-password\"}"];
  Check([authorization hasPrefix:@"Basic "], @"Keychain secret becomes Basic authorization");
  Check([authorization rangeOfString:@"camera-user"].location == NSNotFound &&
        [authorization rangeOfString:@"camera-password"].location == NSNotFound,
        @"authorization output does not expose raw credentials");
  Check([DBRTSPH264Source basicAuthorizationForSecret:@"user\r\nInjected: yes:password"] == nil,
        @"credential header injection is rejected");
  DBRTSPH264Source *unsafeURL = [[DBRTSPH264Source alloc]
      initWithURLString:@"rtsp://camera-user:camera-password@192.0.2.20/live"
      credentialProvider:nil frameHandler:nil stateHandler:nil];
  Check([unsafeURL.state isEqualToString:@"invalid"],
        @"credential-bearing RTSP URLs are rejected instead of logged or emitted");
  Check([DBRTSPH264Source reconnectDelayForAttempt:0] == 2 &&
        [DBRTSPH264Source reconnectDelayForAttempt:1] == 5 &&
        [DBRTSPH264Source reconnectDelayForAttempt:2] == 10 &&
        [DBRTSPH264Source reconnectDelayForAttempt:3] == 30 &&
        [DBRTSPH264Source reconnectDelayForAttempt:20] == 60,
        @"reconnect schedule is bounded and deterministic");
}

static void TestRTPDepacketizer(void) {
  __block NSMutableArray *frames = [NSMutableArray array];
  __block NSMutableArray *keyframes = [NSMutableArray array];
  DBRTPH264Depacketizer *depacketizer = [[DBRTPH264Depacketizer alloc]
      initWithAccessUnitHandler:^(NSData *annexB, BOOL keyframe, uint32_t timestamp) {
    (void)timestamp;
    [frames addObject:annexB];
    [keyframes addObject:@(keyframe)];
  }];
  const uint8_t spsBytes[] = {0x67, 0x42, 0xc0, 0x1f, 0x80};
  const uint8_t ppsBytes[] = {0x68, 0xce, 0x06, 0xe2};
  [depacketizer seedSPS:[NSData dataWithBytes:spsBytes length:sizeof(spsBytes)]
                    pps:[NSData dataWithBytes:ppsBytes length:sizeof(ppsBytes)]];

  const uint8_t fuStart[] = {0x7c, 0x85, 0x88, 0x99};
  const uint8_t fuEnd[] = {0x7c, 0x45, 0xaa, 0xbb};
  Check([depacketizer consumeRTPPacket:RTPPacket(1, 9000, NO, fuStart, sizeof(fuStart))
                    expectedPayloadType:96], @"FU-A start");
  Check([depacketizer consumeRTPPacket:RTPPacket(2, 9000, YES, fuEnd, sizeof(fuEnd))
                    expectedPayloadType:96], @"FU-A end");
  Check([frames count] == 1 && [[keyframes objectAtIndex:0] boolValue],
        @"fragmented IDR emits one keyframe access unit");
  const uint8_t *first = [[frames objectAtIndex:0] bytes];
  Check([[frames objectAtIndex:0] length] > 20 && first[4] == 0x67,
        @"IDR output is prefixed with SPS and PPS in Annex-B");

  const uint8_t pFrame[] = {0x61, 0x10, 0x20};
  Check([depacketizer consumeRTPPacket:RTPPacket(3, 12000, YES, pFrame, sizeof(pFrame))
                    expectedPayloadType:96], @"single NAL P-frame");
  Check([frames count] == 2 && ![[keyframes objectAtIndex:1] boolValue],
        @"single NAL access unit after recovery");

  Check([depacketizer consumeRTPPacket:RTPPacket(5, 15000, YES, pFrame, sizeof(pFrame))
                    expectedPayloadType:96], @"packet after a sequence gap is parsed");
  Check([frames count] == 2 && depacketizer.waitingForIDR,
        @"sequence loss suppresses delta frames until IDR");
  const uint8_t idr[] = {0x65, 0x44, 0x55};
  Check([depacketizer consumeRTPPacket:RTPPacket(6, 18000, YES, idr, sizeof(idr))
                    expectedPayloadType:96], @"single NAL IDR recovery");
  Check([frames count] == 3 && [[keyframes lastObject] boolValue] &&
        !depacketizer.waitingForIDR, @"next complete IDR recovers after loss");

  const uint8_t malformedSTAP[] = {0x78, 0, 8, 0x67};
  Check(![depacketizer consumeRTPPacket:RTPPacket(7, 21000, YES, malformedSTAP,
                                                  sizeof(malformedSTAP))
                     expectedPayloadType:96], @"truncated STAP-A is rejected");

  NSMutableData *stap = [NSMutableData dataWithBytes:(uint8_t[]){0x78} length:1];
  uint8_t spsLength[] = {0, sizeof(spsBytes)};
  uint8_t ppsLength[] = {0, sizeof(ppsBytes)};
  uint8_t idrLength[] = {0, sizeof(idr)};
  [stap appendBytes:spsLength length:2];
  [stap appendBytes:spsBytes length:sizeof(spsBytes)];
  [stap appendBytes:ppsLength length:2];
  [stap appendBytes:ppsBytes length:sizeof(ppsBytes)];
  [stap appendBytes:idrLength length:2];
  [stap appendBytes:idr length:sizeof(idr)];
  Check([depacketizer consumeRTPPacket:RTPPacket(8, 24000, YES, [stap bytes], [stap length])
                    expectedPayloadType:96] && [[keyframes lastObject] boolValue],
        @"valid STAP-A emits a recovered IDR access unit");
  NSMutableData *oversizedRTP = [NSMutableData dataWithLength:33 * 1024];
  Check(![depacketizer consumeRTPPacket:oversizedRTP expectedPayloadType:96],
        @"oversized RTP packet is rejected");
}

static void TestInterleavedFragmentation(void) {
  __block NSUInteger accepted = 0;
  DBRTSPInterleavedParser *parser = [[DBRTSPInterleavedParser alloc]
      initWithFrameHandler:^BOOL(uint8_t channel, NSData *frame) {
    Check(channel == 0 && [frame length] > 12, @"interleaved RTP channel and frame");
    accepted++;
    return YES;
  }];
  const uint8_t idr[] = {0x65, 1, 2, 3};
  NSData *wire = Interleaved(0, RTPPacket(1, 1, YES, idr, sizeof(idr)));
  const uint8_t *bytes = [wire bytes];
  for (NSUInteger i = 0; i < [wire length]; i++)
    Check([parser appendData:[NSData dataWithBytes:bytes + i length:1]],
          @"fragmented interleaved input");
  Check(accepted == 1, @"one interleaved frame emitted");

  uint8_t oversizedHeader[] = {'$', 0, 0x80, 0x01};
  Check(![parser appendData:[NSData dataWithBytes:oversizedHeader
                                           length:sizeof(oversizedHeader)]] &&
        [parser.errorReason isEqualToString:@"rtsp_interleaved_frame_oversized"],
        @"oversized interleaved frame is rejected before allocation");
}

static void TestLoopbackHandshakeAndReconnectState(void) {
  int listener = socket(AF_INET, SOCK_STREAM, 0);
  Check(listener >= 0, @"create fake RTSP listener");
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  Check(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0 &&
        listen(listener, 1) == 0, @"bind fake RTSP listener");
  socklen_t addressLength = sizeof(address);
  Check(getsockname(listener, (struct sockaddr *)&address, &addressLength) == 0,
        @"resolve fake RTSP port");
  FakeRTSPServer server = {listener, 0};
  pthread_t thread;
  Check(pthread_create(&thread, NULL, RunFakeRTSPServer, &server) == 0,
        @"start fake RTSP server");

  dispatch_semaphore_t forwarding = dispatch_semaphore_create(0);
  dispatch_semaphore_t reconnecting = dispatch_semaphore_create(0);
  __block BOOL frameAccepted = NO;
  __block BOOL measured = NO;
  NSString *url = [NSString stringWithFormat:@"rtsp://127.0.0.1:%u/live",
                    (unsigned)ntohs(address.sin_port)];
  DBRTSPH264Source *source = [[DBRTSPH264Source alloc]
      initWithURLString:url credentialProvider:^NSString * {
        return @"{\"username\":\"camera-user\",\"password\":\"camera-password\"}";
      }
      frameHandler:^BOOL(NSData *annexB, BOOL keyframe, int64_t timestampMs) {
        frameAccepted = keyframe && [annexB length] > 20 && timestampMs > 0;
        return frameAccepted;
      }
      stateHandler:^(NSString *state, NSString *reason, BOOL forwardingMeasured) {
        (void)reason;
        if (forwardingMeasured) {
          measured = YES;
          dispatch_semaphore_signal(forwarding);
        } else if (measured && [state isEqualToString:@"reconnecting"]) {
          dispatch_semaphore_signal(reconnecting);
        }
      }];
  [source start];
  Check(dispatch_semaphore_wait(forwarding,
          dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
        @"OPTIONS/DESCRIBE/SETUP/PLAY gates capability on an accepted IDR");
  Check(dispatch_semaphore_wait(reconnecting,
          dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
        @"closed RTSP session enters bounded reconnect state");
  [source stop];
  pthread_join(thread, NULL);
  Check(server.passed && frameAccepted && measured,
        @"loopback RTSP handshake and Annex-B forwarding completed");
}

int main(void) {
  @autoreleasepool {
    TestRTSPResponseParser();
    TestSDPAndCredentials();
    TestRTPDepacketizer();
    TestInterleavedFragmentation();
    TestLoopbackHandshakeAndReconnectState();
  }
  puts("rtsp h264 test passed");
  return 0;
}
