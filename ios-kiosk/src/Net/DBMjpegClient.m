#import "DBMjpegClient.h"
void DBH264Dbg(NSString *fmt, ...);
#import <ImageIO/ImageIO.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <math.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

static const NSUInteger kMaxFrame = 4 * 1024 * 1024;   // JPEG 1 枚の上限
static const NSUInteger kMaxHeader = 16 * 1024;        // multipart part ヘッダの上限
static const CFAbsoluteTime kFrameInterval = 0.12;     // ~8fps 上限
static const CGFloat kMaxPixel = 640;                  // 解码後の一辺上限 (iPad1 画面で十分)

@implementation DBMjpegClient {
  NSURL *_url;
  DBMjpegFrameHandler _onFrame;
  volatile BOOL _running;      // stop() は main から、読みは socket スレッド
  int _sock;                   // socket スレッドが設定。stop() から shutdown のみ
  dispatch_queue_t _decodeQueue;
  NSLock *_frameLock;
  NSData *_pendingJpeg;        // _frameLock 保護
  int64_t _pendingCaptureMs;   // _pendingJpeg と対
  BOOL _decodeBusy;            // _frameLock 保護
  CFAbsoluteTime _lastFrameAt; // decode queue 専用
  int64_t _serverToClientOffsetMs;
  NSUInteger _latencyFrame;
  int64_t _currentLatencyMs;
  int64_t _previousLatencyMs;
  double _jitterMs;
  double _framesPerSecond;
  CFAbsoluteTime _lastStatsFrameAt;
}

- (id)initWithURLString:(NSString *)urlString onFrame:(DBMjpegFrameHandler)onFrame {
  self = [super init];
  if (self) {
    _url = [NSURL URLWithString:urlString];
    if (_url == nil) return nil;
    _onFrame = [onFrame copy];
    _sock = -1;
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

- (void)start {
  if (_running) return;
  _latencyFrame = 0;
  _currentLatencyMs = 0;
  _previousLatencyMs = 0;
  _jitterMs = 0;
  _framesPerSecond = 0;
  _lastStatsFrameAt = 0;
  _running = YES;
  [NSThread detachNewThreadSelector:@selector(threadMain) toTarget:self withObject:nil];
}

- (void)stop {
  if (!_running) return;
  _running = NO;
  int s = _sock;
  if (s >= 0) shutdown(s, SHUT_RDWR);  // recv のブロックを即解除してスレッドを終了させる
}

#pragma mark - socket スレッド

- (void)threadMain {
  @autoreleasepool {
    while (_running) {
      if ([self streamOnce]) continue;      // 正常終了 (server 側 close) → 即再接続
      if (!_running) break;
      [NSThread sleepForTimeInterval:2.0];  // 失敗 → 2 秒待って再接続
    }
  }
}

// 1 接続分の受信。成功(EOF 含む) YES / トランスポート失敗 NO。
- (BOOL)streamOnce {
  int fd = -1;
  NSMutableData *buf = [NSMutableData data];
  NSInteger expecting = -1;
  int64_t expectingCaptureMs = 0;
  if (![self connect:&fd]) return NO;
  _sock = fd;
  if (!_running) {
    [self closeSock:&fd];
    return NO;
  }

  uint8_t chunk[16 * 1024];
  while (_running) {
    ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
    if (n < 0) break;                       // error / shutdown
    if (n == 0) {                           // EOF (server 側 close)
      [self closeSock:&fd];
      _sock = -1;
      return YES;
    }
    [buf appendBytes:chunk length:(NSUInteger)n];
    if ([buf length] > kMaxFrame + kMaxHeader) {  // パース不能ガード
      [buf setLength:0];
      expecting = -1;
    }
    if (![self extractFramesFrom:buf expecting:&expecting capture:&expectingCaptureMs]) break;
  }

  [self closeSock:&fd];
  _sock = -1;
  return NO;
}

- (void)closeSock:(int *)fd {
  if (*fd >= 0) {
    close(*fd);
    *fd = -1;
  }
}

// バッファから multipart part を取り出せた分だけ offerFrame へ。
// 戻り NO = 致命的 (プロトコル崩れ) → 再接続。
- (BOOL)extractFramesFrom:(NSMutableData *)buf expecting:(NSInteger *)expecting
                  capture:(int64_t *)expectingCapture {
  while (YES) {
    if (*expecting < 0) {
      NSUInteger headerLen = 0, consumed = 0;
      if (![self findHeaderEnd:buf headerLen:&headerLen consumed:&consumed]) return YES;
      NSInteger len = [self contentLengthOf:buf headerLen:headerLen];
      int64_t serverMs = [self longHeader:@"x-doorbell-server-time-ms"
                                   inData:buf headerLen:headerLen];
      if (serverMs > 0) {
        int64_t nowMs = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
        _serverToClientOffsetMs = nowMs - serverMs;
      }
      *expectingCapture = [self longHeader:@"x-doorbell-capture-time-ms"
                                    inData:buf headerLen:headerLen];
      [buf replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
      if (len > 0 && (NSUInteger)len <= kMaxFrame) {
        *expecting = len;
      } else {
        // content-length 無し/異常 → マーカ走査で 1 枚拾う (server 実装差の許容)
        NSData *jpeg = [self scanOneJpeg:buf];
        if (jpeg) [self offerFrame:jpeg captureMs:*expectingCapture];
        else if ([buf length] > kMaxFrame) [buf setLength:0];
      }
      continue;
    }
    if ([buf length] < (NSUInteger)*expecting) return YES;  // 本文待ち
    NSData *jpeg = [buf subdataWithRange:NSMakeRange(0, (NSUInteger)*expecting)];
    [buf replaceBytesInRange:NSMakeRange(0, (NSUInteger)*expecting) withBytes:NULL length:0];
    *expecting = -1;
    [self offerFrame:jpeg captureMs:*expectingCapture];
    *expectingCapture = 0;
  }
}
#pragma mark - 接続

// 非阻塞 connect + select (5 秒タイムアウト)。成功時 *fd に確立済み socket。
- (BOOL)connect:(int *)fd {
  NSString *host = _url.host;
  if ([host length] == 0) return NO;
  NSInteger port = _url.port ? [_url.port integerValue] : 80;
  if (port <= 0 || port > 65535) port = 80;
  NSString *path = _url.path;
  if ([path length] == 0) path = @"/";
  if ([_url query]) path = [NSString stringWithFormat:@"%@?%@", path, [_url query]];
  NSLog(@"[doorbell][DBG] mjpeg: connect %@:%ld%@", host, (long)port, path);

  struct addrinfo hints, *res = NULL;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo([host UTF8String], [[NSString stringWithFormat:@"%ld", (long)port] UTF8String],
                  &hints, &res) != 0 || res == NULL)
    return NO;

  int s = -1;
  for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
    s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (s < 0) continue;
    // 非阻塞で connect → select で 5 秒待つ
    int fl = fcntl(s, F_GETFL, 0);
    if (fl >= 0) fcntl(s, F_SETFL, fl | O_NONBLOCK);
    int cr = connect(s, ai->ai_addr, ai->ai_addrlen);
    if (cr != 0 && errno != EINPROGRESS) {
      close(s);
      s = -1;
      continue;
    }
    if (cr != 0) {
      fd_set wset;
      FD_ZERO(&wset);
      FD_SET(s, &wset);
      struct timeval tv = {5, 0};
      if (select(s + 1, NULL, &wset, NULL, &tv) <= 0) {
        close(s);
        s = -1;
        continue;
      }
      int err = 0;
      socklen_t elen = sizeof(err);
      getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &elen);
      if (err != 0) {
        close(s);
        s = -1;
        continue;
      }
    }
    // 受信タイムアウト (10s)。ブロック読みに戻す。
    int fl2 = fcntl(s, F_GETFL, 0);
    if (fl2 >= 0) fcntl(s, F_SETFL, fl2 & ~O_NONBLOCK);
    struct timeval rcv = {10, 0};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &rcv, sizeof(rcv));
    break;
  }
  freeaddrinfo(res);
  if (s < 0) {
    NSLog(@"[doorbell][DBG] mjpeg: connect FAILED (errno=%d)", errno);
    return NO;
  }

  NSMutableString *req = [NSMutableString string];
  [req appendFormat:@"GET %@ HTTP/1.0\r\n", path];
  [req appendFormat:@"Host: %@:%ld\r\n", host, (long)port];
  [req appendString:@"Accept: multipart/x-mixed-replace, image/jpeg\r\n"];
  [req appendString:@"Connection: close\r\n\r\n"];
  NSData *rd = [req dataUsingEncoding:NSUTF8StringEncoding];
  if (send(s, [rd bytes], [rd length], 0) != (ssize_t)[rd length]) {
    close(s);
    return NO;
  }
  *fd = s;
  return YES;
}
#pragma mark - パース

// 空行 (\r\n\r\n or \n\n) までをヘッダとして探す。
- (BOOL)findHeaderEnd:(NSMutableData *)buf headerLen:(NSUInteger *)headerLen consumed:(NSUInteger *)consumed {
  const char crlf[4] = {0x0D, 0x0A, 0x0D, 0x0A};
  NSRange r = [buf rangeOfData:[NSData dataWithBytes:crlf length:4]
                       options:0
                         range:NSMakeRange(0, [buf length])];
  if (r.location != NSNotFound) {
    *headerLen = r.location;
    *consumed = r.location + 4;
    return YES;
  }
  const char lflf[2] = {0x0A, 0x0A};
  r = [buf rangeOfData:[NSData dataWithBytes:lflf length:2]
               options:0
                 range:NSMakeRange(0, [buf length])];
  if (r.location != NSNotFound) {
    *headerLen = r.location;
    *consumed = r.location + 2;
    return YES;
  }
  if ([buf length] > kMaxHeader) [buf setLength:0];  // ヘッダ異常 → 捨てる
  return NO;
}

- (NSInteger)contentLengthOf:(NSMutableData *)buf headerLen:(NSUInteger)headerLen {
  NSData *hd = [buf subdataWithRange:NSMakeRange(0, headerLen)];
  NSString *header = [[NSString alloc] initWithData:hd encoding:NSASCIIStringEncoding];
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
  return len;
}

- (int64_t)longHeader:(NSString *)wanted inData:(NSMutableData *)buf
             headerLen:(NSUInteger)headerLen {
  NSData *hd = [buf subdataWithRange:NSMakeRange(0, headerLen)];
  NSString *header = [[NSString alloc] initWithData:hd encoding:NSASCIIStringEncoding];
  for (NSString *rawLine in [header componentsSeparatedByString:@"\n"]) {
    NSString *line = [rawLine stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) continue;
    NSString *key = [[[line substringToIndex:colon.location]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
    if ([key isEqualToString:wanted]) {
      return [[[line substringFromIndex:colon.location + 1]
          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] longLongValue];
    }
  }
  return 0;
}
// content-length 無し server 用: SOI(FFD8) から EOI(FFD9) までを 1 枚として拾う。
- (NSData *)scanOneJpeg:(NSMutableData *)buf {
  const uint8_t soi[2] = {0xFF, 0xD8};
  const uint8_t eoi[2] = {0xFF, 0xD9};
  NSRange s = [buf rangeOfData:[NSData dataWithBytes:soi length:2]
                       options:0
                         range:NSMakeRange(0, [buf length])];
  if (s.location == NSNotFound) return nil;
  NSRange tail = NSMakeRange(s.location, [buf length] - s.location);
  NSRange e = [buf rangeOfData:[NSData dataWithBytes:eoi length:2] options:0 range:tail];
  if (e.location == NSNotFound) return nil;
  NSUInteger len = e.location - s.location + 2;
  if (len > kMaxFrame) {
    [buf replaceBytesInRange:NSMakeRange(0, s.location + 2) withBytes:NULL length:0];
    return nil;
  }
  NSData *jpeg = [buf subdataWithRange:NSMakeRange(s.location, len)];
  [buf replaceBytesInRange:NSMakeRange(0, s.location + len) withBytes:NULL length:0];
  return jpeg;
}

#pragma mark - デコード (最新フレーム優先)

- (void)offerFrame:(NSData *)jpeg captureMs:(int64_t)captureMs {
  if (!_running) return;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (now - _lastFrameAt < kFrameInterval) return;  // fps 上限
  [_frameLock lock];
  _pendingJpeg = [jpeg copy];
  _pendingCaptureMs = captureMs;
  BOOL busy = _decodeBusy;
  _decodeBusy = YES;
  [_frameLock unlock];
  if (busy) return;  // 解码中 → 新しい pending は完走後の drain が拾う
  dispatch_async(_decodeQueue, ^{ [self drainDecode]; });
}

- (void)drainDecode {
  static dispatch_once_t firstFrameLog;
  dispatch_once(&firstFrameLog, ^{
    NSLog(@"[doorbell][DBG] mjpeg: first frame decoded+delivered");
  });
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
    _lastFrameAt = CFAbsoluteTimeGetCurrent();
    UIImage *img = [self decodeJpeg:jpeg];
    if (img && _running) {
      DBMjpegClient *__weak wself = self;
      dispatch_async(dispatch_get_main_queue(), ^{
        DBMjpegClient *s = wself;
        if (s && s->_running && s->_onFrame) {
          CFAbsoluteTime frameAt = CFAbsoluteTimeGetCurrent();
          if (s->_lastStatsFrameAt > 0) {
            CFAbsoluteTime dt = frameAt - s->_lastStatsFrameAt;
            if (dt > 0.005 && dt < 2.0) {
              double instantFps = 1.0 / dt;
              s->_framesPerSecond = s->_framesPerSecond > 0
                  ? s->_framesPerSecond * 0.8 + instantFps * 0.2 : instantFps;
            }
          }
          s->_lastStatsFrameAt = frameAt;
          if (captureMs > 0) {
            int64_t nowMs = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
            int64_t latency = nowMs - captureMs - s->_serverToClientOffsetMs;
            if (latency >= 0 && latency < 10000) {
              if (s->_latencyFrame > 0) {
                double variation = fabs((double)(latency - s->_previousLatencyMs));
                s->_jitterMs += (variation - s->_jitterMs) / 8.0;
              }
              s->_currentLatencyMs = latency;
              s->_previousLatencyMs = latency;
              DBH264Dbg(@"[mjpeg-latency] frame=%lu e2e=%lldms",
                        (unsigned long)++s->_latencyFrame, (long long)latency);
            }
          }
          s->_onFrame(img);
        }
      });
    }
  }
}

// ImageIO サムネイル = JPEG DCT スケーリングで直接縮小解码 (フル解码より遥かに軽い)。
- (UIImage *)decodeJpeg:(NSData *)jpeg {
  CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
  if (src == NULL) return nil;
  NSDictionary *opts = @{
    (id)kCGImageSourceCreateThumbnailFromImageAlways : (__bridge id)kCFBooleanTrue,
    (id)kCGImageSourceThumbnailMaxPixelSize : [NSNumber numberWithFloat:kMaxPixel],
    (id)kCGImageSourceCreateThumbnailWithTransform : (__bridge id)kCFBooleanTrue,
    (id)kCGImageSourceShouldCache : (__bridge id)kCFBooleanFalse,
  };
  CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
  CFRelease(src);
  if (cg == NULL) return nil;
  UIImage *img = [UIImage imageWithCGImage:cg];
  CGImageRelease(cg);
  return img;
}

@end
