#import "DBFmp4Demux.h"
void DBH264Dbg(NSString *fmt, ...);
#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

static const NSUInteger kMaxBufferBytes = 8 * 1024 * 1024;
#define DB_MAX_SAMPLES_PER_MOOF 512
static void *kFmp4QueueKey = &kFmp4QueueKey;

// ---- BE 読み ----
static uint32_t rd32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static uint64_t rd64(const uint8_t *p) {
  return ((uint64_t)rd32(p) << 32) | rd32(p + 4);
}

// trun の一時表 (各 demux インスタンスの cbQueue からのみ触る)
typedef struct {
  uint32_t dur, size, flg;
} DbTrunSample;
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

@implementation DBFmp4Demux {
  NSString *_url;
  __weak id<DBFmp4DemuxDelegate> _delegate;
  volatile BOOL _running;
  int _sock;

  // 解析状態 (_cbQueue 専属)
  dispatch_queue_t _cbQueue;
  NSMutableData *_pending;  // 未消化バイト
  NSData *_sps, *_pps;
  BOOL _readySent, _failSent;
  uint32_t _lastDurMs;  // trun duration の引き継ぎ (flags 無し時)
  uint64_t _outDtsMs;   // 出力 sample の走査 DTS (ms)
  DbTrunSample _trun[DB_MAX_SAMPLES_PER_MOOF];
  uint32_t _trunCount;
  uint32_t _firstFlags;
  BOOL _firstFlagsSet;
}

- (id)initWithURLString:(NSString *)url delegate:(id<DBFmp4DemuxDelegate>)delegate {
  self = [super init];
  if (self) {
    _url = [url copy];
    _delegate = delegate;
    _sock = -1;
    _cbQueue = dispatch_queue_create("doorbell.fmp4", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_cbQueue, kFmp4QueueKey, kFmp4QueueKey, NULL);
    _pending = [[NSMutableData alloc] init];
    _lastDurMs = 40;  // 25fps 初期値 (trun duration が来れば上書き)
  }
  return self;
}

- (void)dealloc { [self stop]; }

- (void)start {
  if (_running) return;
  _running = YES;
  [NSThread detachNewThreadSelector:@selector(threadMain) toTarget:self withObject:nil];
}

- (void)stop {
  _running = NO;
  int s = _sock;
  if (s >= 0) shutdown(s, SHUT_RDWR);
  // DBH264Player frees its mux immediately after this returns. Drain callbacks
  // first so an in-flight sample cannot append into freed state.
  if (dispatch_get_specific(kFmp4QueueKey) != kFmp4QueueKey)
    dispatch_sync(_cbQueue, ^{});
}

- (void)threadMain {
  @autoreleasepool {
    [self streamOnce];
    BOOL unexpectedEnd = _running;
    _running = NO;
    if (unexpectedEnd) dispatch_sync(_cbQueue, ^{ [self failLocked]; });
  }
}

// 1 接続 (HTTP GET → 受信ループ)。YES = EOF まで正常。
- (BOOL)streamOnce {
  int fd = -1;
  if (![self connectSock:&fd]) return NO;
  _sock = fd;
  uint8_t chunk[16 * 1024];
  uint64_t total = 0;
  while (_running) {
    ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
    if (n <= 0) {
      DBH264Dbg(@"[fmp4] recv end n=%ld total=%llu", (long)n,
            (unsigned long long)total);
      break;
    }
    total += (uint64_t)n;
    NSData *piece = [NSData dataWithBytes:chunk length:(NSUInteger)n];
    dispatch_sync(_cbQueue, ^{
      if (!_running) return;
      [_pending appendData:piece];
      if ([_pending length] > kMaxBufferBytes) {
        [self failLocked];
        _running = NO;
        return;
      }
      [self pumpLocked];
    });
  }
  close(fd);
  _sock = -1;
  return YES;
}

- (BOOL)connectSock:(int *)fd {
  NSURL *u = [NSURL URLWithString:_url];
  if (u == nil) return NO;
  NSString *host = [u host];
  NSInteger port = [u port] ? [[u port] integerValue] : 80;
  NSString *path = [u path] ?: @"/";
  if ([path length] == 0) path = @"/";
  if ([[u query] length] > 0)
    path = [path stringByAppendingFormat:@"?%@", [u query]];
  struct addrinfo hints, *res = NULL;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo([host UTF8String], NULL, &hints, &res) != 0 || res == NULL) return NO;
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) { freeaddrinfo(res); return NO; }
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
  struct timeval tv = {10, 0};
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  struct sockaddr_in a;
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_port = htons((uint16_t)port);
  a.sin_addr = ((struct sockaddr_in *)res->ai_addr)->sin_addr;
  freeaddrinfo(res);
  if (connect(s, (struct sockaddr *)&a, sizeof(a)) < 0) { close(s); return NO; }
  NSMutableString *req = [NSMutableString stringWithFormat:
      @"GET %@ HTTP/1.1\r\nHost: %@:%ld\r\nUser-Agent: doorbell-kiosk\r\n"
       "Accept: video/mp4\r\nConnection: close\r\n\r\n", path, host, (long)port];
  NSData *rd = [req dataUsingEncoding:NSUTF8StringEncoding];
  if (!sendAll(s, [rd bytes], [rd length])) { close(s); return NO; }
  // HTTP 応答ヘッダを読み捨て (CRLFCRLF まで)
  NSMutableData *hdr = [NSMutableData data];
  while (_running) {
    uint8_t b = 0;
    ssize_t n = recv(s, (void *)&b, (size_t)1, 0);
    if (n <= 0) { close(s); return NO; }
    [hdr appendBytes:(const void *)&b length:1];
    NSUInteger L = [hdr length];
    const uint8_t *hb = (const uint8_t *)[hdr bytes];
    if (L >= 4 && hb[L-1]=='\n' && hb[L-2]=='\r' && hb[L-3]=='\n' && hb[L-4]=='\r') break;
    if (L > 16 * 1024) { close(s); return NO; }
  }
  NSString *head = [[NSString alloc] initWithData:hdr encoding:NSISOLatin1StringEncoding];
  if (![head hasPrefix:@"HTTP/1.1 200 "] && ![head hasPrefix:@"HTTP/1.0 200 "]) {
    DBH264Dbg(@"[fmp4] HTTP rejected: %@", [[head componentsSeparatedByString:@"\r\n"] objectAtIndex:0]);
    close(s);
    return NO;
  }
  DBH264Dbg(@"[fmp4] %@", [[head componentsSeparatedByString:@"\r\n"] objectAtIndex:0]);
  *fd = s;
  return YES;
}

// ---- box 解析 (_cbQueue 上、_pending を消化) ----
- (void)pumpLocked {
  const uint8_t *p = (const uint8_t *)[_pending bytes];
  NSUInteger len = [_pending length];
  NSUInteger consumed = 0;
  while (_running && len - consumed >= 8) {
    const uint8_t *b = p + consumed;
    uint64_t size = rd32(b);
    uint32_t type = rd32(b + 4);
    uint64_t hdr = 8;
    if (size == 1) {
      if (len - consumed < 16) break;
      size = rd64(b + 8);
      hdr = 16;
    } else if (size == 0) {
      break;
    }
    if (size < hdr || len - consumed < size) break;  // 未着
    const uint8_t *body = b + hdr;
    uint64_t bodyLen = size - hdr;

    static int boxLog = 0;
    if (boxLog < 14 && (type == 'moof' || type == 'mdat' || type == 'moov' || type == 'free')) {
      boxLog++;
      DBH264Dbg(@"[fmp4] box %c%c%c%c size=%llu trun=%d", (char)((type >> 24) & 0xFF),
                (char)((type >> 16) & 0xFF), (char)((type >> 8) & 0xFF),
                (char)(type & 0xFF), (unsigned long long)size, _trunCount);
    }
    if (type == 'moov' && !_readySent) {
      [self parseInitLocked:body len:bodyLen];
      static int moovLog = 0;
      if (!moovLog) { moovLog = 1; DBH264Dbg(@"[fmp4] moov parsed (ready=%d)", _readySent); }
    } else if (type == 'moof') {
      if (!_readySent) { [self failLocked]; return; }
      if (![self parseMoofLocked:body len:bodyLen]) { [self failLocked]; return; }
    } else if (type == 'mdat' && _trunCount > 0) {
      if (![self emitSamplesLocked:body len:bodyLen]) { [self failLocked]; return; }
    }
    consumed += (NSUInteger)size;
  }
  if (consumed > 0)
    [_pending replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
}

- (void)failLocked {
  if (_failSent) return;
  _failSent = YES;
  id<DBFmp4DemuxDelegate> d = _delegate;
  if (d) [d fmp4DemuxFailed:self];
}

// moov を再帰下降で走査し avcC を探す (trak→mdia→minf→stbl→stsd→avc1→avcC)。
- (void)parseInitLocked:(const uint8_t *)p len:(uint64_t)len {
  if ([self scanInitLocked:p len:len]) {
    _readySent = YES;
    _outDtsMs = 0;
    id<DBFmp4DemuxDelegate> d = _delegate;
    NSData *s1 = _sps, *s2 = _pps;
    if (d) [d fmp4DemuxReady:self sps:s1 pps:s2];
  }
}

// YES = avcC 発見済み (_sps/_pps 設定済み)
- (BOOL)scanInitLocked:(const uint8_t *)p len:(uint64_t)len {
  while (len >= 8) {
    uint64_t size = rd32(p);
    uint32_t type = rd32(p + 4);
    uint64_t hdr = 8;
    if (size == 1) {
      if (len < 16) return NO;
      size = rd64(p + 8);
      hdr = 16;
    }
    if (size < hdr || size > len) return NO;  // 壊れ or 未完成
    const uint8_t *body = p + hdr;
    uint64_t bodyLen = size - hdr;
    if (type == 'avcC') {
      return [self extractAvcC:body len:bodyLen];
    }
    if (type == 'stsd' && bodyLen > 8) {
      // [version/flags(4) entry_count(4)] の後が sample entry
      if ([self scanInitLocked:body + 8 len:bodyLen - 8]) return YES;
    } else if ((type == 'avc1' || type == 'avc2' || type == 'encv') && bodyLen > 78) {
      // VisualSampleEntry 固定 78 バイトの後が子 box
      if ([self scanInitLocked:body + 78 len:bodyLen - 78]) return YES;
    } else if (type == 'moov' || type == 'trak' || type == 'mdia' || type == 'minf' ||
               type == 'stbl' || type == 'mvex' || type == 'edts') {
      if ([self scanInitLocked:body len:bodyLen]) return YES;
    }
    p += size;
    len -= size;
  }
  return NO;
}

- (BOOL)extractAvcC:(const uint8_t *)c len:(uint64_t)clen {
  if (clen < 11) return NO;
  // configurationVersion(1) profile(1) compat(1) level(1) 0xFF(1) 0xE1(1) spsLen(2)
  NSUInteger spsLen = ((NSUInteger)c[6] << 8) | c[7];
  if ((uint64_t)8 + spsLen + 3 > clen) return NO;
  const uint8_t *sps = c + 8;
  const uint8_t *q = sps + spsLen;
  NSUInteger ppsLen = ((NSUInteger)q[1] << 8) | q[2];
  if ((uint64_t)(q + 3 + ppsLen - c) > clen) return NO;
  _sps = [NSData dataWithBytes:sps length:spsLen];
  _pps = [NSData dataWithBytes:q + 3 length:ppsLen];
  DBH264Dbg(@"[fmp4] avcC ok: sps=%lu pps=%lu", (unsigned long)spsLen,
        (unsigned long)ppsLen);
  return YES;
}

// moof → traf 内の trun の sample 表を作る (flags 0x701: data_offset +
// per-sample duration/size/flags — core buildFragment と対)。
- (BOOL)parseMoofLocked:(const uint8_t *)p len:(uint64_t)len {
  const uint8_t *end = p + len;
  BOOL found = NO;
  while (end - p >= 8) {
    uint64_t size = rd32(p);
    uint32_t type = rd32(p + 4);
    uint64_t header = 8;
    if (size == 1) {
      if (end - p < 16) return NO;
      size = rd64(p + 8);
      header = 16;
    }
    if (size < header || (uint64_t)(end - p) < size) return NO;
    if (type == 'traf') {
      // traf 内部の trun を走査
      const uint8_t *q = p + header;
      const uint8_t *qEnd = p + size;
      while (qEnd - q >= 8) {
        uint64_t qsize = rd32(q);
        uint32_t qtype = rd32(q + 4);
        uint64_t qheader = 8;
        if (qsize == 1) {
          if (qEnd - q < 16) return NO;
          qsize = rd64(q + 8);
          qheader = 16;
        }
        if (qsize < qheader || (uint64_t)(qEnd - q) < qsize) return NO;
        if (qtype == 'trun') {
          if (![self parseTrunLocked:q size:qsize]) return NO;
          found = YES;
        }
        q += qsize;
      }
    }
    p += size;
  }
  return found;
}

- (BOOL)parseTrunLocked:(const uint8_t *)p size:(uint64_t)size {
  if (size < 16) return NO;
  const uint8_t *end = p + size;
  uint32_t flags = rd32(p + 8) & 0x00FFFFFF;
  uint32_t count = rd32(p + 12);
  const uint8_t *t = p + 16;
  if (count > DB_MAX_SAMPLES_PER_MOOF) return NO;
  int64_t dataOffset = 0;
  uint32_t firstFlags = 0;
  if (flags & 0x000001) {
    if (end - t < 4) return NO;
    dataOffset = (int32_t)rd32(t); t += 4;
  }
  if (flags & 0x000004) {
    if (end - t < 4) return NO;
    firstFlags = rd32(t); t += 4;
  }
  BOOL hasDur = (flags & 0x000100) != 0;
  BOOL hasSize = (flags & 0x000200) != 0;
  BOOL hasFlg = (flags & 0x000400) != 0;
  if (!hasSize) return NO;  // core の buildFragment は必ず size を書く
  size_t fieldsPerSample = (hasDur ? 4 : 0) + 4 + (hasFlg ? 4 : 0);
  if ((uint64_t)(end - t) < (uint64_t)count * fieldsPerSample) return NO;
  for (uint32_t i = 0; i < count; i++) {
    _trun[i].dur = hasDur ? rd32(t) : _lastDurMs;
    if (hasDur) t += 4;
    _trun[i].size = rd32(t);
    t += 4;
    _trun[i].flg = hasFlg ? rd32(t) : 0;
    if (hasFlg) t += 4;
    if (_trun[i].dur > 0) _lastDurMs = _trun[i].dur;
  }
  _trunCount = count;
  _firstFlagsSet = (flags & 0x000004) != 0;
  _firstFlags = firstFlags;
  static int tlog = 0;
  if (!tlog) {
    tlog = 1;
    DBH264Dbg(@"[fmp4] trun flags=0x%06x count=%d first=%d dur0=%u size0=%u",
              flags, count, (int)_firstFlagsSet,
              count ? _trun[0].dur : 0, count ? _trun[0].size : 0);
  }
  (void)dataOffset;
  return YES;
}

// mdat payload を trun 表に従って切り出し AVCC sample として delegate へ。
// sample_flags bit16-17 (sample_depends_on) == 2 が I 帧。
- (BOOL)emitSamplesLocked:(const uint8_t *)p len:(uint64_t)len {
  static int elog = 0;
  if (!elog) {
    elog = 1;
    DBH264Dbg(@"[fmp4] emit: mdatLen=%llu count=%u s0=%u s1=%u dts=%llu",
              (unsigned long long)len, _trunCount, _trun[0].size,
              _trunCount > 1 ? _trun[1].size : 0,
              (unsigned long long)_outDtsMs);
  }
  uint64_t off = 0;
  uint64_t dts = _outDtsMs;
  id<DBFmp4DemuxDelegate> d = _delegate;
  for (uint32_t i = 0; i < _trunCount; i++) {
    uint64_t sz = _trun[i].size;
    if (off + sz > len) return NO;
    uint32_t flg = (i == 0 && _firstFlagsSet) ? _firstFlags : _trun[i].flg;
    BOOL key = ((flg >> 16) & 0x3) == 2;
    if (d) {
      NSData *s = [NSData dataWithBytes:p + off length:(NSUInteger)sz];
      /* cbQueue 上で直接配送 (main に積むと A5 で追いつかない) */
      [d fmp4Demux:self sample:s key:key dtsMs:(int64_t)dts durMs:(int64_t)_trun[i].dur];
    }
    off += sz;
    dts += _trun[i].dur;
  }
  _outDtsMs = dts;
  _trunCount = 0;
  return YES;
}

@end
