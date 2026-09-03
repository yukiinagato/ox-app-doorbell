#import "DBMjpegClient.h"

#import <ImageIO/ImageIO.h>
#import <math.h>

static const CFAbsoluteTime DBMjpegFrameInterval = 0.12;
static const CGFloat DBMjpegMaximumPixel = 640;
static const CFAbsoluteTime DBMjpegLowResourceFrameInterval = 0.5;
static const CGFloat DBMjpegLowResourceMaximumPixel = 320;
static const NSTimeInterval DBMjpegStallTimeout = 10.0;

static void DBMjpegTrace(NSString *stage, CFAbsoluteTime started) {
  long elapsed = (long)MAX(0, (CFAbsoluteTimeGetCurrent() - started) * 1000.0);
  NSString *line = [NSString stringWithFormat:@"%@ +%ldms\n", stage ?: @"unknown", elapsed];
  NSLog(@"[doorbell][video-startup] %@", [line stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]]);
  @synchronized([DBMjpegClient class]) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *path = [[paths lastObject] stringByAppendingPathComponent:@"video-startup.log"];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
      [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
  }
}

@interface DBMjpegClient () <NSURLConnectionDataDelegate>
- (void)threadMain;
@end

@implementation DBMjpegClient {
  NSString *_urlString;
  DBHTTPMediaCredentialProvider _credentialProvider;
  DBMjpegStateHandler _stateHandler;
  DBMjpegFrameHandler _onFrame;
  volatile BOOL _running;
  NSURLConnection *_connection;
  DBMJPEGMultipartParser *_parser;
  BOOL _attemptFinished;
  BOOL _attemptHadFrame;
  NSString *_attemptReason;
  CFAbsoluteTime _lastNetworkDataAt;

  dispatch_queue_t _decodeQueue;
  NSLock *_frameLock;
  NSData *_pendingJpeg;
  int64_t _pendingCaptureMs;
  BOOL _decodeBusy;
  CFAbsoluteTime _lastDecodeAt;
  int64_t _serverToClientOffsetMs;
  NSUInteger _latencyFrame;
  int64_t _currentLatencyMs;
  int64_t _previousLatencyMs;
  double _jitterMs;
  double _framesPerSecond;
  CFAbsoluteTime _lastStatsFrameAt;
  BOOL _lowResourceMode;
  CFAbsoluteTime _startupAt;
  BOOL _tracedResponse;
  BOOL _tracedData;
  BOOL _tracedPart;
  BOOL _tracedDecode;
  BOOL _tracedMain;
}

@synthesize lowResourceMode = _lowResourceMode;

- (id)initWithURLString:(NSString *)urlString onFrame:(DBMjpegFrameHandler)onFrame {
  return [self initWithURLString:urlString credentialProvider:nil stateHandler:nil
                        onFrame:onFrame];
}

- (id)initWithURLString:(NSString *)urlString
     credentialProvider:(DBHTTPMediaCredentialProvider)credentialProvider
            stateHandler:(DBMjpegStateHandler)stateHandler
                 onFrame:(DBMjpegFrameHandler)onFrame {
  self = [super init];
  if (self) {
    _urlString = [[DBHTTPMediaSupport safeURLString:urlString] copy];
    if (![_urlString length]) return nil;
    _credentialProvider = [credentialProvider copy];
    _stateHandler = [stateHandler copy];
    _onFrame = [onFrame copy];
    _frameLock = [[NSLock alloc] init];
    _decodeQueue = dispatch_queue_create("doorbell.mjpeg.decode", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (DBVideoStats)videoStats {
  return DBVideoStatsMake(_latencyFrame > 0, (NSInteger)_currentLatencyMs,
                          (NSInteger)(_jitterMs + 0.5), (CGFloat)_framesPerSecond);
}

- (CFAbsoluteTime)lastFrameAt {
  return _lastStatsFrameAt;
}

- (void)emitState:(NSString *)state reason:(NSString *)reason {
  if (!_stateHandler) return;
  __weak DBMjpegClient *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    DBMjpegClient *client = weakSelf;
    if (client && client->_stateHandler)
      client->_stateHandler(state ?: @"unknown", reason ?: @"");
  });
}

- (void)start {
  if (_running || ![_urlString length]) return;
  _latencyFrame = 0;
  _currentLatencyMs = 0;
  _previousLatencyMs = 0;
  _jitterMs = 0;
  _framesPerSecond = 0;
  _lastStatsFrameAt = 0;
  _startupAt = CFAbsoluteTimeGetCurrent();
  _tracedResponse = _tracedData = _tracedPart = _tracedDecode = _tracedMain = NO;
  DBMjpegTrace(@"request_start", _startupAt);
  _running = YES;
  [NSThread detachNewThreadSelector:@selector(threadMain) toTarget:self withObject:nil];
}

- (void)stop {
  _running = NO;
  [_frameLock lock];
  _pendingJpeg = nil;
  _pendingCaptureMs = 0;
  [_frameLock unlock];
}

- (void)threadMain {
  @autoreleasepool {
    NSUInteger reconnectAttempt = 0;
    while (_running) {
      [self emitState:@"connecting" reason:@""];
      NSMutableURLRequest *request = [DBHTTPMediaSupport
          requestWithURLString:_urlString credentialProvider:_credentialProvider
          accept:@"multipart/x-mixed-replace, image/jpeg" timeout:10.0];
      if (!request) {
        [self emitState:@"stopped" reason:@"invalid_url"];
        break;
      }

      _attemptFinished = NO;
      _attemptHadFrame = NO;
      _attemptReason = @"stream_eof";
      _lastNetworkDataAt = CFAbsoluteTimeGetCurrent();
      __weak DBMjpegClient *weakSelf = self;
      _parser = [[DBMJPEGMultipartParser alloc] initWithFrameHandler:^(NSData *jpeg) {
        DBMjpegClient *client = weakSelf;
        if (!client || !client->_running) return;
        BOOL firstFrame = !client->_attemptHadFrame;
        client->_attemptHadFrame = YES;
        if (!client->_tracedPart) {
          client->_tracedPart = YES;
          DBMjpegTrace(@"first_complete_multipart", client->_startupAt);
        }
        if (firstFrame) [client emitState:@"streaming" reason:@""];
        int64_t serverMs = client->_parser.lastServerTimeMs;
        if (serverMs > 0) {
          int64_t nowMs = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
          client->_serverToClientOffsetMs = nowMs - serverMs;
        }
        [client offerFrame:jpeg captureMs:client->_parser.lastCaptureTimeMs];
      }];
      _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self
                                           startImmediately:NO];
      [_connection scheduleInRunLoop:[NSRunLoop currentRunLoop]
                             forMode:NSDefaultRunLoopMode];
      [_connection start];
      while (_running && !_attemptFinished) {
        @autoreleasepool {
          [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
          if (CFAbsoluteTimeGetCurrent() - _lastNetworkDataAt > DBMjpegStallTimeout) {
            _attemptReason = @"stream_stalled";
            _attemptFinished = YES;
            [_connection cancel];
          }
        }
      }
      [_connection cancel];
      _connection = nil;
      _parser = nil;
      if (!_running) break;
      if (_attemptHadFrame) reconnectAttempt = 0;
      NSTimeInterval delay = [DBHTTPMediaSupport reconnectDelayForAttempt:reconnectAttempt++];
      [self emitState:@"retry_wait" reason:_attemptReason];
      while (_running && delay > 0) {
        NSTimeInterval slice = MIN(0.1, delay);
        [NSThread sleepForTimeInterval:slice];
        delay -= slice;
      }
    }
    [self emitState:@"stopped" reason:@""];
  }
}

- (NSURLRequest *)connection:(NSURLConnection *)connection
             willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)response {
  (void)connection;
  if (response == nil) return request;
  _attemptReason = @"redirect_rejected";
  _attemptFinished = YES;
  return nil;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
  (void)connection;
  _lastNetworkDataAt = CFAbsoluteTimeGetCurrent();
  if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
    _attemptReason = @"non_http_response";
    _attemptFinished = YES;
    [_connection cancel];
    return;
  }
  NSInteger status = [(NSHTTPURLResponse *)response statusCode];
  if (!_tracedResponse) {
    _tracedResponse = YES;
    DBMjpegTrace(@"http_response_headers", _startupAt);
  }
  if (status < 200 || status >= 300) {
    _attemptReason = [NSString stringWithFormat:@"http_status_%ld", (long)status];
    _attemptFinished = YES;
    [_connection cancel];
  }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
  (void)connection;
  if (_attemptFinished || !_running) return;
  if (!_tracedData) {
    _tracedData = YES;
    DBMjpegTrace(@"first_network_bytes", _startupAt);
  }
  _lastNetworkDataAt = CFAbsoluteTimeGetCurrent();
  if (![_parser appendData:data]) {
    _attemptReason = [_parser.errorReason length] ? _parser.errorReason : @"multipart_invalid";
    _attemptFinished = YES;
    [_connection cancel];
  }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
  (void)connection;
  _attemptFinished = YES;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
  (void)connection;
  (void)error;
  if (!_attemptFinished) _attemptReason = @"transport_error";
  _attemptFinished = YES;
}

- (void)offerFrame:(NSData *)jpeg captureMs:(int64_t)captureMs {
  if (!_running) return;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  CFAbsoluteTime minimumInterval = _lowResourceMode
      ? DBMjpegLowResourceFrameInterval : DBMjpegFrameInterval;
  if (now - _lastDecodeAt < minimumInterval) return;
  [_frameLock lock];
  _pendingJpeg = [jpeg copy];
  _pendingCaptureMs = captureMs;
  BOOL busy = _decodeBusy;
  _decodeBusy = YES;
  [_frameLock unlock];
  if (busy) return;
  dispatch_async(_decodeQueue, ^{ [self drainDecode]; });
}

- (void)drainDecode {
  while (YES) {
    [_frameLock lock];
    NSData *jpeg = _pendingJpeg;
    int64_t captureMs = _pendingCaptureMs;
    _pendingJpeg = nil;
    _pendingCaptureMs = 0;
    if (!jpeg) {
      _decodeBusy = NO;
      [_frameLock unlock];
      return;
    }
    [_frameLock unlock];
    _lastDecodeAt = CFAbsoluteTimeGetCurrent();
    UIImage *image = [self decodeJpeg:jpeg];
    if (!image || !_running) continue;
    if (!_tracedDecode) {
      _tracedDecode = YES;
      DBMjpegTrace(@"first_jpeg_decoded", _startupAt);
    }
    __weak DBMjpegClient *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      DBMjpegClient *client = weakSelf;
      if (!client || !client->_running || !client->_onFrame) return;
      if (!client->_tracedMain) {
        client->_tracedMain = YES;
        DBMjpegTrace(@"first_frame_on_main_thread", client->_startupAt);
      }
      CFAbsoluteTime frameAt = CFAbsoluteTimeGetCurrent();
      if (client->_lastStatsFrameAt > 0) {
        CFAbsoluteTime delta = frameAt - client->_lastStatsFrameAt;
        if (delta > 0.005 && delta < 2.0) {
          double instantaneous = 1.0 / delta;
          client->_framesPerSecond = client->_framesPerSecond > 0
              ? client->_framesPerSecond * 0.8 + instantaneous * 0.2 : instantaneous;
        }
      }
      client->_lastStatsFrameAt = frameAt;
      if (captureMs > 0) {
        int64_t nowMs = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
        int64_t latency = nowMs - captureMs - client->_serverToClientOffsetMs;
        if (latency >= 0 && latency < 10000) {
          if (client->_latencyFrame > 0) {
            double variation = fabs((double)(latency - client->_previousLatencyMs));
            client->_jitterMs += (variation - client->_jitterMs) / 8.0;
          }
          client->_currentLatencyMs = latency;
          client->_previousLatencyMs = latency;
          client->_latencyFrame++;
        }
      }
      client->_onFrame(image);
    });
  }
}

- (UIImage *)decodeJpeg:(NSData *)jpeg {
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
  if (source == NULL) return nil;
  CGFloat maximumPixel = _lowResourceMode
      ? DBMjpegLowResourceMaximumPixel : DBMjpegMaximumPixel;
  NSDictionary *options = @{
    (id)kCGImageSourceCreateThumbnailFromImageAlways : (__bridge id)kCFBooleanTrue,
    (id)kCGImageSourceThumbnailMaxPixelSize :
        [NSNumber numberWithFloat:maximumPixel],
    (id)kCGImageSourceCreateThumbnailWithTransform : (__bridge id)kCFBooleanTrue,
    (id)kCGImageSourceShouldCache : (__bridge id)kCFBooleanFalse,
  };
  CGImageRef decoded = CGImageSourceCreateThumbnailAtIndex(
      source, 0, (__bridge CFDictionaryRef)options);
  CFRelease(source);
  if (decoded == NULL) return nil;
  UIImage *image = [UIImage imageWithCGImage:decoded];
  CGImageRelease(decoded);
  return image;
}

@end
