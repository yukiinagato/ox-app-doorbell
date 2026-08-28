#import "DBMjpegClient.h"

static const NSUInteger kMaxFrame = 4 * 1024 * 1024;   // JPEG 1 枚の上限
static const NSUInteger kMaxBuffer = 8 * 1024 * 1024;  // 受信バッファの上限

@interface DBMjpegClient () <NSURLConnectionDataDelegate>
@end

@implementation DBMjpegClient {
  NSURL *_url;
  DBMjpegFrameHandler _onFrame;
  NSURLConnection *_conn;
  NSMutableData *_buf;
  NSInteger _expecting;  // 現パートの Content-Length (-1 = ヘッダ読み中)
  BOOL _running;
}

- (id)initWithUrlString:(NSString *)urlString onFrame:(DBMjpegFrameHandler)onFrame {
  self = [super init];
  if (self) {
    _url = [[NSURL URLWithString:urlString] retain];
    if (_url == nil) {
      [self release];
      return nil;
    }
    _onFrame = [onFrame copy];
    _buf = [[NSMutableData alloc] init];
    _expecting = -1;
  }
  return self;
}

- (void)dealloc {
  [self stop];
  [_url release];
  [_onFrame release];
  [_buf release];
  [super dealloc];
}

- (void)start {
  if (_running) return;
  _running = YES;
  [self connect];
}

- (void)stop {
  _running = NO;
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(connect) object:nil];
  [_conn cancel];
  [_conn release];
  _conn = nil;
}

- (void)connect {
  if (!_running) return;
  [_buf setLength:0];
  _expecting = -1;
  NSMutableURLRequest *req =
      [NSMutableURLRequest requestWithURL:_url
                              cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                          timeoutInterval:10];
  [_conn cancel];
  [_conn release];
  _conn = [[NSURLConnection alloc] initWithRequest:req delegate:self startImmediately:YES];
}

#pragma mark - NSURLConnectionDataDelegate (main runloop)

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
  if (!_running) return;
  [_buf appendData:data];
  if ([_buf length] > kMaxBuffer) {  // パース不能 — 仕切り直し
    [_buf setLength:0];
    _expecting = -1;
    return;
  }
  [self parseLoop];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
  [self scheduleReconnect];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
  [self scheduleReconnect];
}

- (void)scheduleReconnect {
  if (!_running) return;
  [self performSelector:@selector(connect) withObject:nil afterDelay:2.0];
}

#pragma mark - 境界パース

- (void)parseLoop {
  while (YES) {
    if (_expecting < 0) {
      NSUInteger headerLen = 0, consumed = 0;
      if (![self findHeaderEnd:&headerLen consumed:&consumed]) return;  // ヘッダ未着
      NSData *headerData = [_buf subdataWithRange:NSMakeRange(0, headerLen)];
      NSString *header = [[[NSString alloc] initWithData:headerData
                                                encoding:NSASCIIStringEncoding] autorelease];
      [_buf replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
      NSInteger len = -1;
      for (NSString *rawLine in [header componentsSeparatedByString:@"\n"]) {
        NSString *line =
            [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *k = [[line substringToIndex:colon.location]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([[k lowercaseString] isEqualToString:@"content-length"]) {
          NSString *v = [[line substringFromIndex:colon.location + 1]
              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
          len = [v integerValue];
        }
      }
      if (len <= 0 || (NSUInteger)len > kMaxFrame) continue;  // 次の境界を探し直す
      _expecting = len;
    }
    if ([_buf length] < (NSUInteger)_expecting) return;  // 本文未着
    NSData *jpeg = [_buf subdataWithRange:NSMakeRange(0, _expecting)];
    [_buf replaceBytesInRange:NSMakeRange(0, _expecting) withBytes:NULL length:0];
    _expecting = -1;
    UIImage *img = [UIImage imageWithData:jpeg];
    if (img && _onFrame && _running) {
      _onFrame(img);
    }
  }
}

// 空行 (\r\n\r\n or \n\n) までをヘッダとして探す。
- (BOOL)findHeaderEnd:(NSUInteger *)headerLen consumed:(NSUInteger *)consumed {
  const char crlf[4] = {0x0D, 0x0A, 0x0D, 0x0A};
  NSRange r = [_buf rangeOfData:[NSData dataWithBytes:crlf length:4]
                        options:0
                          range:NSMakeRange(0, [_buf length])];
  if (r.location != NSNotFound) {
    *headerLen = r.location;
    *consumed = r.location + 4;
    return YES;
  }
  const char lflf[2] = {0x0A, 0x0A};
  r = [_buf rangeOfData:[NSData dataWithBytes:lflf length:2]
                options:0
                  range:NSMakeRange(0, [_buf length])];
  if (r.location != NSNotFound) {
    *headerLen = r.location;
    *consumed = r.location + 2;
    return YES;
  }
  return NO;
}

@end
