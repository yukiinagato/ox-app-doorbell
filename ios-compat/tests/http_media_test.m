#import <Foundation/Foundation.h>

#import "DBHTTPMediaSupport.h"

static void Require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static NSData *Bytes(const uint8_t *bytes, NSUInteger length) {
  return [NSData dataWithBytes:bytes length:length];
}

int main(void) {
  @autoreleasepool {
    Require([[DBHTTPMediaSupport safeURLString:@"https://192.0.2.20/live.mjpeg"]
                isEqualToString:@"https://192.0.2.20/live.mjpeg"],
            @"HTTPS camera URL accepted");
    Require([DBHTTPMediaSupport safeURLString:
                @"http://camera-user:camera-password@192.0.2.20/live"] == nil,
            @"URL userinfo rejected");
    Require([DBHTTPMediaSupport safeURLString:
                @"https://192.0.2.20/live?access_token=plaintext"] == nil,
            @"credential query rejected");
    Require([DBHTTPMediaSupport safeURLString:
                @"https://192.0.2.20/live?access%255ftoken=plaintext"] == nil,
            @"nested percent-encoded credential query rejected");
    Require([DBHTTPMediaSupport safeURLString:@"file:///tmp/camera.jpg"] == nil,
            @"non-HTTP URL rejected");

    __block NSUInteger providerCalls = 0;
    NSMutableURLRequest *request = [DBHTTPMediaSupport
        requestWithURLString:@"https://192.0.2.20/live.mjpeg"
        credentialProvider:^NSString * {
      providerCalls++;
      return @"{\"username\":\"camera-user\",\"password\":\"camera-password\"}";
    } accept:@"multipart/x-mixed-replace" timeout:5];
    NSString *authorization = [request valueForHTTPHeaderField:@"Authorization"];
    Require(providerCalls == 1, @"secure-store provider read once per request");
    Require([authorization isEqualToString:
                @"Basic Y2FtZXJhLXVzZXI6Y2FtZXJhLXBhc3N3b3Jk"],
            @"Basic Authorization header derived from secure value");
    NSString *absolute = [[request URL] absoluteString];
    Require([absolute rangeOfString:@"camera-user"].location == NSNotFound &&
            [absolute rangeOfString:@"camera-password"].location == NSNotFound,
            @"credential bytes absent from request URL");
    NSDictionary *bearer = [DBHTTPMediaSupport authorizationHeadersForSecret:
        @"{\"bearer_token\":\"opaque-token\"}"];
    Require([[bearer objectForKey:@"Authorization"] isEqualToString:
                @"Bearer opaque-token"], @"bearer credential header");
    Require([DBHTTPMediaSupport authorizationHeadersForSecret:
                @"user\r\nInjected: yes:password"] == nil,
            @"header injection rejected");
    Require([DBHTTPMediaSupport authorizationHeadersForSecret:
                @"{\"username\":\"broken\""] == nil,
            @"malformed credential JSON fails closed");
    Require([DBHTTPMediaSupport reconnectDelayForAttempt:0] == 2 &&
            [DBHTTPMediaSupport reconnectDelayForAttempt:1] == 5 &&
            [DBHTTPMediaSupport reconnectDelayForAttempt:2] == 10 &&
            [DBHTTPMediaSupport reconnectDelayForAttempt:3] == 30 &&
            [DBHTTPMediaSupport reconnectDelayForAttempt:40] == 60,
            @"bounded reconnect schedule");

    uint8_t firstBytes[] = {0xff, 0xd8, 0x01, 0x02, 0xff, 0xd9};
    uint8_t secondBytes[] = {0xff, 0xd8, 0x03, 0xff, 0xd9};
    NSData *first = Bytes(firstBytes, sizeof(firstBytes));
    NSData *second = Bytes(secondBytes, sizeof(secondBytes));
    NSMutableData *stream = [NSMutableData data];
    [stream appendData:[@"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: 6\r\n"
                         "X-Doorbell-Server-Time-Ms: 1000\r\n"
                         "X-Doorbell-Capture-Time-Ms: 900\r\n\r\n"
        dataUsingEncoding:NSASCIIStringEncoding]];
    [stream appendData:first];
    [stream appendData:[@"\r\n--frame\r\nContent-Type: image/jpeg\r\n\r\n"
        dataUsingEncoding:NSASCIIStringEncoding]];
    [stream appendData:second];
    [stream appendData:[@"\r\n--frame\r\n" dataUsingEncoding:NSASCIIStringEncoding]];

    NSMutableArray *frames = [NSMutableArray array];
    NSMutableArray *captureTimes = [NSMutableArray array];
    NSMutableArray *serverTimes = [NSMutableArray array];
    __block DBMJPEGMultipartParser *parser = nil;
    parser = [[DBMJPEGMultipartParser alloc] initWithFrameHandler:^(NSData *jpeg) {
      [frames addObject:jpeg];
      [captureTimes addObject:@(parser.lastCaptureTimeMs)];
      [serverTimes addObject:@(parser.lastServerTimeMs)];
    }];
    const uint8_t *streamBytes = [stream bytes];
    for (NSUInteger index = 0; index < [stream length]; index++) {
      Require([parser appendData:Bytes(streamBytes + index, 1)],
              @"byte-fragmented multipart accepted");
    }
    Require([frames count] == 2 && [[frames objectAtIndex:0] isEqualToData:first] &&
            [[frames objectAtIndex:1] isEqualToData:second],
            @"Content-Length and marker-delimited frames emitted exactly");
    Require([[captureTimes objectAtIndex:0] longLongValue] == 900 &&
            [[serverTimes objectAtIndex:0] longLongValue] == 1000,
            @"fragmented timing headers remain associated with their frame");
    Require(parser.bufferedBytes < 64, @"multipart parser retains only boundary tail");
    parser = nil;

    NSMutableData *oversizedHeader = [NSMutableData dataWithLength:16 * 1024 + 1];
    memset([oversizedHeader mutableBytes], 'A', [oversizedHeader length]);
    DBMJPEGMultipartParser *bounded = [[DBMJPEGMultipartParser alloc]
        initWithFrameHandler:^(NSData *jpeg) { (void)jpeg; }];
    Require(![bounded appendData:oversizedHeader] &&
            [bounded.errorReason isEqualToString:@"multipart_header_limit"] &&
            bounded.bufferedBytes == 0, @"oversized header rejected and released");
    [bounded reset];
    NSData *badLength = [@"--f\r\nContent-Length: 4194305\r\n\r\n"
        dataUsingEncoding:NSASCIIStringEncoding];
    Require(![bounded appendData:badLength] &&
            [bounded.errorReason isEqualToString:@"multipart_content_length_invalid"],
            @"oversized JPEG part rejected before allocation");

    // CFNetwork strips the part headers of multipart/x-mixed-replace and announces
    // each part as its own response. The parser must therefore take bare JPEG
    // bodies: by their SOI when nothing was announced, and by the announced
    // Content-Length when the client forwards the per-part response.
    NSMutableArray *bareFrames = [NSMutableArray array];
    DBMJPEGMultipartParser *bare = [[DBMJPEGMultipartParser alloc]
        initWithFrameHandler:^(NSData *jpeg) { [bareFrames addObject:jpeg]; }];
    NSMutableData *bareStream = [NSMutableData data];
    [bareStream appendData:first];
    [bareStream appendData:second];
    const uint8_t *bareBytes = [bareStream bytes];
    for (NSUInteger index = 0; index < [bareStream length]; index++) {
      Require([bare appendData:Bytes(bareBytes + index, 1)],
              @"header-less JPEG bodies accepted byte by byte");
    }
    Require([bareFrames count] == 2 && [[bareFrames objectAtIndex:0] isEqualToData:first] &&
            [[bareFrames objectAtIndex:1] isEqualToData:second],
            @"bodies without part headers are split on JPEG markers");

    NSMutableArray *announcedFrames = [NSMutableArray array];
    NSMutableArray *announcedCapture = [NSMutableArray array];
    __block DBMJPEGMultipartParser *announced = nil;
    announced = [[DBMJPEGMultipartParser alloc] initWithFrameHandler:^(NSData *jpeg) {
      [announcedFrames addObject:jpeg];
      [announcedCapture addObject:@(announced.lastCaptureTimeMs)];
    }];
    [announced beginPartWithContentLength:(long long)[first length]
                            captureTimeMs:700 serverTimeMs:800];
    Require([announced appendData:first], @"announced Content-Length part accepted");
    // A marker-delimited part (no Content-Length) whose tail is flushed by the next
    // announcement, followed by an interrupted part that must be dropped.
    [announced beginPartWithContentLength:-1 captureTimeMs:900 serverTimeMs:1000];
    Require([announced appendData:[second subdataWithRange:NSMakeRange(0, 3)]],
            @"partial announced body held");
    Require([announced appendData:[second subdataWithRange:
                NSMakeRange(3, [second length] - 3)]], @"announced body completed");
    Require([announced appendData:[first subdataWithRange:NSMakeRange(0, 4)]],
            @"trailing junk after an announced frame is buffered, not rejected");
    [announced beginPartWithContentLength:(long long)[first length]
                            captureTimeMs:1100 serverTimeMs:1200];
    Require([announced appendData:first], @"part after an interrupted one accepted");
    Require([announcedFrames count] == 3 &&
            [[announcedFrames objectAtIndex:0] isEqualToData:first] &&
            [[announcedFrames objectAtIndex:1] isEqualToData:second] &&
            [[announcedFrames objectAtIndex:2] isEqualToData:first],
            @"announced parts emit exactly their JPEGs and drop the interrupted body");
    Require([[announcedCapture objectAtIndex:0] longLongValue] == 700 &&
            [[announcedCapture objectAtIndex:1] longLongValue] == 900 &&
            [[announcedCapture objectAtIndex:2] longLongValue] == 1100,
            @"per-part response timing is attached to the announced frames");
    Require(announced.partsAnnounced == 3, @"announcements counted");
    [announced beginPartWithContentLength:(4LL * 1024 * 1024) + 1
                            captureTimeMs:0 serverTimeMs:0];
    Require([announced appendData:first] && [announcedFrames count] == 4,
            @"an oversized announced length falls back to marker delimiting");

    puts("PASS: secure HTTP media requests and bounded multipart parsing");
  }
  return 0;
}
