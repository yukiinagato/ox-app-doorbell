#import "DBHlsServer.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <stdio.h>
#import <sys/socket.h>
#import <string.h>
#import <unistd.h>

static BOOL sendAll(int fd, const void *bytes, size_t length) {
  const uint8_t *p = (const uint8_t *)bytes;
  size_t sent = 0;
  while (sent < length) {
    ssize_t n = send(fd, p + sent, length - sent, 0);
    if (n <= 0) return NO;
    sent += (size_t)n;
  }
  return YES;
}

@interface DBHlsServer ()
- (void)acceptLoop;
- (void)handleConn:(NSNumber *)fdNum;
@end

@implementation DBHlsServer {
  int _listenFd;
  NSInteger _port;
  NSMutableArray *_segs;      // NSData (TS)
  NSMutableArray *_durs;      // NSNumber ms
  uint64_t _firstSeq;         // _segs[0] の通し番号 (0 始まり)
  NSLock *_lock;
  volatile BOOL _running;
}

- (id)init {
  self = [super init];
  if (self) {
    _listenFd = -1;
    _segs = [[NSMutableArray alloc] init];
    _durs = [[NSMutableArray alloc] init];
    _lock = [[NSLock alloc] init];
    _firstSeq = 0;
  }
  return self;
}

- (void)dealloc { [self stop]; }

- (NSInteger)port { return _port; }

- (BOOL)start {
  if (_running) return YES;
  _listenFd = socket(AF_INET, SOCK_STREAM, 0);
  if (_listenFd < 0) return NO;
  int one = 1;
  setsockopt(_listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in a;
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  a.sin_port = 0;
  if (bind(_listenFd, (struct sockaddr *)&a, sizeof(a)) < 0) {
    close(_listenFd);
    _listenFd = -1;
    return NO;
  }
  if (listen(_listenFd, 8) < 0) {
    close(_listenFd);
    _listenFd = -1;
    return NO;
  }
  socklen_t al = sizeof(a);
  getsockname(_listenFd, (struct sockaddr *)&a, &al);
  _port = ntohs(a.sin_port);
  _running = YES;
  NSThread *t = [[NSThread alloc] initWithTarget:self
                                        selector:@selector(acceptLoop)
                                          object:nil];
  [t start];
  return YES;
}

- (void)stop {
  _running = NO;
  int fd = _listenFd;
  _listenFd = -1;
  if (fd >= 0) {
    shutdown(fd, SHUT_RDWR);
    close(fd);
  }
  [_lock lock];
  [_segs removeAllObjects];
  [_durs removeAllObjects];
  _firstSeq = 0;
  [_lock unlock];
}

- (NSString *)playlistUrl {
  return [NSString stringWithFormat:@"http://127.0.0.1:%ld/live.m3u8", (long)_port];
}

- (void)acceptLoop {
  @autoreleasepool {
    while (_running) {
      struct sockaddr_in ca;
      socklen_t cl = sizeof(ca);
      int cfd = accept(_listenFd, (struct sockaddr *)&ca, &cl);
      if (cfd < 0) {
        if (!_running) break;
        continue;
      }
      struct timeval tv = {10, 0};
      setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
      int one = 1;
      setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
      [NSThread detachNewThreadSelector:@selector(handleConn:)
                               toTarget:self
                             withObject:[NSNumber numberWithInt:cfd]];
    }
  }
}

- (void)handleConn:(NSNumber *)fdNum {
  @autoreleasepool {
    int fd = [fdNum intValue];
    char req[2048];
    size_t got = 0;
    while (got < sizeof(req) - 1) {
      char b;
      ssize_t n = recv(fd, &b, 1, 0);
      if (n <= 0) break;
      req[got++] = b;
      if (got >= 4 && req[got-1]=='\n' && req[got-2]=='\r' &&
          req[got-3]=='\n' && req[got-4]=='\r') break;
    }
    req[got] = 0;
    char method[8] = {0};
    char requestPath[1024] = {0};
    if (sscanf(req, "%7s %1023s", method, requestPath) != 2 ||
        strcmp(method, "GET") != 0) requestPath[0] = 0;
    NSString *path = [NSString stringWithUTF8String:requestPath] ?: @"";

    NSData *body = nil;
    NSString *ctype = nil;
    if ([path isEqualToString:@"/live.m3u8"]) {
      body = [self playlist];
      ctype = @"application/vnd.apple.mpegurl";
    } else if ([path hasPrefix:@"/seg"]) {
      uint64_t seq = 0;
      for (NSUInteger i = 4; i < [path length]; i++) {
        unichar c = [path characterAtIndex:i];
        if (c < '0' || c > '9') break;
        seq = seq * 10 + (uint64_t)(c - '0');
      }
      body = [self segmentAt:seq];
      ctype = @"video/mp2t";
    }
    NSMutableString *resp = [NSMutableString string];
    if (body) {
      [resp appendFormat:@"HTTP/1.1 200 OK\r\nContent-Type: %@\r\n"
                          @"Content-Length: %lu\r\nConnection: close\r\n"
                          @"Cache-Control: no-store\r\n\r\n",
                          ctype, (unsigned long)[body length]];
      NSData *h = [resp dataUsingEncoding:NSUTF8StringEncoding];
      if (sendAll(fd, [h bytes], [h length]))
        sendAll(fd, [body bytes], [body length]);
    } else {
      [resp appendString:@"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n"
                          @"Connection: close\r\n\r\n"];
      NSData *h = [resp dataUsingEncoding:NSUTF8StringEncoding];
      sendAll(fd, [h bytes], [h length]);
    }
    close(fd);
  }
}

- (NSData *)playlist {
  [_lock lock];
  NSMutableData *out = [NSMutableData data];
  NSMutableString *s = [NSMutableString string];
  int64_t maxDurationMs = 1000;
  for (NSNumber *duration in _durs)
    if ([duration longLongValue] > maxDurationMs) maxDurationMs = [duration longLongValue];
  long long targetDuration = (maxDurationMs + 999) / 1000;
  if (targetDuration < 2) targetDuration = 2;
  [s appendFormat:@"#EXTM3U\r\n#EXT-X-VERSION:3\r\n#EXT-X-TARGETDURATION:%lld\r\n",
                  targetDuration];
  [s appendFormat:@"#EXT-X-MEDIA-SEQUENCE:%llu\r\n", (unsigned long long)_firstSeq];
  for (NSUInteger i = 0; i < [_segs count]; i++) {
    double d = [[_durs objectAtIndex:i] doubleValue] / 1000.0;
    if (d < 0.1) d = 0.1;
    [s appendFormat:@"#EXTINF:%.3f,\r\n/seg%llu.ts\r\n", d,
                    (unsigned long long)(_firstSeq + i)];
  }
  [_lock unlock];
  [out setData:[s dataUsingEncoding:NSUTF8StringEncoding]];
  return out;
}

- (NSData *)segmentAt:(uint64_t)seq {
  [_lock lock];
  NSData *d = nil;
  if (seq >= _firstSeq && seq < _firstSeq + [_segs count])
    d = [_segs objectAtIndex:(NSUInteger)(seq - _firstSeq)];
  [_lock unlock];
  return d;
}

- (NSUInteger)segmentCount {
  [_lock lock];
  NSUInteger c = [_segs count];
  [_lock unlock];
  return c;
}

- (void)addSegment:(NSData *)ts durationMs:(int64_t)durationMs {
  if (![ts length]) return;
  [_lock lock];
  [_segs addObject:ts];
  [_durs addObject:[NSNumber numberWithDouble:(double)durationMs]];
  while ([_segs count] > 5) {
    [_segs removeObjectAtIndex:0];
    [_durs removeObjectAtIndex:0];
    _firstSeq++;
  }
  [_lock unlock];
}

@end
