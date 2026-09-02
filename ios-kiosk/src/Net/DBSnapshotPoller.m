#import "DBSnapshotPoller.h"

#import <ImageIO/ImageIO.h>

static const NSUInteger DBSnapshotMaximumBytes = 4 * 1024 * 1024;
static const CGFloat DBSnapshotMaximumPixel = 640;
static const NSTimeInterval DBSnapshotInterval = 1.0;
static const CGFloat DBSnapshotLowResourceMaximumPixel = 320;
static const NSTimeInterval DBSnapshotLowResourceInterval = 2.0;

@interface DBSnapshotPoller () <NSURLConnectionDataDelegate>
- (void)threadMain;
@end

@implementation DBSnapshotPoller {
  NSString *_urlString;
  DBHTTPMediaCredentialProvider _credentialProvider;
  DBSnapshotStateHandler _stateHandler;
  DBSnapshotFrameHandler _onFrame;
  volatile BOOL _running;
  NSURLConnection *_connection;
  NSLock *_bodyLock;
  NSMutableData *_body;
  volatile BOOL _attemptFinished;
  BOOL _attemptSucceeded;
  NSString *_attemptReason;
  BOOL _lowResourceMode;
}

@synthesize lowResourceMode = _lowResourceMode;

- (id)initWithURLString:(NSString *)urlString onFrame:(DBSnapshotFrameHandler)onFrame {
  return [self initWithURLString:urlString credentialProvider:nil stateHandler:nil
                        onFrame:onFrame];
}

- (id)initWithURLString:(NSString *)urlString
     credentialProvider:(DBHTTPMediaCredentialProvider)credentialProvider
            stateHandler:(DBSnapshotStateHandler)stateHandler
                 onFrame:(DBSnapshotFrameHandler)onFrame {
  self = [super init];
  if (self) {
    _urlString = [[DBHTTPMediaSupport safeURLString:urlString] copy];
    if (![_urlString length]) return nil;
    _credentialProvider = [credentialProvider copy];
    _stateHandler = [stateHandler copy];
    _onFrame = [onFrame copy];
    _bodyLock = [[NSLock alloc] init];
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (void)emitState:(NSString *)state reason:(NSString *)reason {
  if (!_stateHandler) return;
  __weak DBSnapshotPoller *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    DBSnapshotPoller *poller = weakSelf;
    if (poller && poller->_stateHandler)
      poller->_stateHandler(state ?: @"unknown", reason ?: @"");
  });
}

- (void)start {
  if (_running || ![_urlString length]) return;
  _running = YES;
  [NSThread detachNewThreadSelector:@selector(threadMain) toTarget:self withObject:nil];
}

- (void)stop {
  _running = NO;
}

- (void)threadMain {
  @autoreleasepool {
    NSUInteger reconnectAttempt = 0;
    while (_running) {
      [self emitState:@"connecting" reason:@""];
      NSMutableURLRequest *request = [DBHTTPMediaSupport
          requestWithURLString:_urlString credentialProvider:_credentialProvider
          accept:@"image/jpeg" timeout:5.0];
      if (!request) {
        [self emitState:@"stopped" reason:@"invalid_url"];
        break;
      }
      [request setValue:@"bytes=0-4194303" forHTTPHeaderField:@"Range"];
      _attemptFinished = NO;
      _attemptSucceeded = NO;
      _attemptReason = @"snapshot_eof";
      [_bodyLock lock];
      _body = [[NSMutableData alloc] init];
      [_bodyLock unlock];
      _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self
                                           startImmediately:NO];
      [_connection scheduleInRunLoop:[NSRunLoop currentRunLoop]
                             forMode:NSDefaultRunLoopMode];
      [_connection start];
      while (_running && !_attemptFinished) {
        @autoreleasepool {
          [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        }
      }
      [_connection cancel];
      _connection = nil;
      [_bodyLock lock];
      _body = nil;
      [_bodyLock unlock];
      if (!_running) break;

      NSTimeInterval delay = _lowResourceMode
          ? DBSnapshotLowResourceInterval : DBSnapshotInterval;
      if (_attemptSucceeded) {
        reconnectAttempt = 0;
      } else {
        delay = [DBHTTPMediaSupport reconnectDelayForAttempt:reconnectAttempt++];
        [self emitState:@"retry_wait" reason:_attemptReason];
      }
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
  if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
    _attemptReason = @"non_http_response";
    _attemptFinished = YES;
    [_connection cancel];
    return;
  }
  NSInteger status = [(NSHTTPURLResponse *)response statusCode];
  long long expected = [response expectedContentLength];
  if (status < 200 || status >= 300) {
    _attemptReason = [NSString stringWithFormat:@"http_status_%ld", (long)status];
    _attemptFinished = YES;
    [_connection cancel];
  } else if (expected > (long long)DBSnapshotMaximumBytes) {
    _attemptReason = @"snapshot_body_limit";
    _attemptFinished = YES;
    [_connection cancel];
  }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
  (void)connection;
  if (_attemptFinished || !_running || [data length] == 0) return;
  [_bodyLock lock];
  BOOL oversized = [data length] > DBSnapshotMaximumBytes ||
      [_body length] > DBSnapshotMaximumBytes - [data length];
  if (!oversized) [_body appendData:data];
  [_bodyLock unlock];
  if (oversized) {
    _attemptReason = @"snapshot_body_limit";
    _attemptFinished = YES;
    [_connection cancel];
  }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
  (void)connection;
  [_bodyLock lock];
  NSData *data = [_body copy];
  _body = nil;
  [_bodyLock unlock];
  UIImage *image = _running ? [self thumbnail:data] : nil;
  if (image && _running) {
    _attemptSucceeded = YES;
    [self emitState:@"ready" reason:@""];
    __weak DBSnapshotPoller *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      DBSnapshotPoller *poller = weakSelf;
      if (poller && poller->_running && poller->_onFrame) poller->_onFrame(image);
    });
  } else {
    _attemptReason = @"snapshot_jpeg_invalid";
  }
  _attemptFinished = YES;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
  (void)connection;
  (void)error;
  if (!_attemptFinished) _attemptReason = @"transport_error";
  _attemptFinished = YES;
}

- (UIImage *)thumbnail:(NSData *)data {
  if ([data length] == 0 || [data length] > DBSnapshotMaximumBytes) return nil;
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (source == NULL) return nil;
  CGFloat maximumPixel = _lowResourceMode
      ? DBSnapshotLowResourceMaximumPixel : DBSnapshotMaximumPixel;
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
