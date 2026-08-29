#import "DBH264Player.h"
#import "DBTsMux.h"
#import "../Net/DBFmp4Demux.h"
#import "../Net/DBHlsServer.h"
#import <MediaPlayer/MediaPlayer.h>
#import <math.h>

void DBH264Dbg(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void DBH264Dbg(NSString *fmt, ...) {
  static NSLock *lock = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
  [lock lock];
  va_list ap;
  va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  FILE *f = fopen("/var/mobile/Documents/h264-dbg.log", "a");
  if (f) {
    fprintf(f, "%s\n", [line UTF8String]);
    fclose(f);
  }
  NSLog(@"%@", line);
  [lock unlock];
}

@interface DBH264Player () <DBFmp4DemuxDelegate>
- (void)startMovieOnMain;
- (void)failOnMain:(NSString *)reason;
@end

static BOOL AvccHasIdr(NSData *avcc) {
  const uint8_t *p = (const uint8_t *)[avcc bytes];
  NSUInteger len = [avcc length], off = 0;
  while (off + 4 <= len) {
    uint32_t n = ((uint32_t)p[off] << 24) | ((uint32_t)p[off + 1] << 16) |
                 ((uint32_t)p[off + 2] << 8) | p[off + 3];
    off += 4;
    if (n == 0 || off + n > len) return NO;
    if ((p[off] & 0x1F) == 5) return YES;
    off += n;
  }
  return NO;
}

static void SegSink(void *ctx, const uint8_t *data, size_t len);

@implementation DBH264Player {
  NSString *_url;
  UIView *_container;
  void (^_onState)(DBH264PlayerState);
  DBFmp4Demux *_demux;
  DBHlsServer *_server;
  MPMoviePlayerController *_player;
  DBTsMux *_mux;
  uint64_t _segSeq;
  NSMutableData *_seg;
  int64_t _segStartMs;
  NSData *_sps, *_pps;
  DBH264PlayerState _state;
  BOOL _movieStartScheduled;
  NSUInteger _generation;
  NSLock *_statsLock;
  int64_t _statsBaseDtsMs;
  int64_t _statsLatestDtsMs;
  int64_t _statsLatestCaptureMs;
  double _statsFramesPerSecond;
  NSUInteger _reportedLatencyCount;
  int64_t _reportedLatencyMs;
  double _reportedJitterMs;
}

static void SegSink(void *ctx, const uint8_t *data, size_t len) {
  DBH264Player *player = (__bridge DBH264Player *)ctx;
  [player->_seg appendBytes:data length:len];
}

+ (BOOL)hardwareSupported { return YES; }

- (id)initWithURL:(NSString *)url container:(UIView *)container
          onState:(void (^)(DBH264PlayerState))onState {
  self = [super init];
  if (self) {
    _url = [url copy];
    _container = container;
    _onState = [onState copy];
    _state = DBH264PlayerIdle;
    _statsLock = [[NSLock alloc] init];
    _statsBaseDtsMs = -1;
  }
  return self;
}

- (DBH264PlayerState)state { return _state; }

- (DBVideoStats)videoStats {
  NSAssert([NSThread isMainThread], @"HLS stats must be read on main");
  [_statsLock lock];
  int64_t baseDts = _statsBaseDtsMs;
  int64_t latestDts = _statsLatestDtsMs;
  int64_t latestCapture = _statsLatestCaptureMs;
  double fps = _statsFramesPerSecond;
  [_statsLock unlock];
  if (_state != DBH264PlayerPlaying || !_player || baseDts < 0 ||
      latestCapture <= 0) return DBVideoStatsMake(NO, 0, 0, (CGFloat)fps);

  NSTimeInterval playbackS = _player.currentPlaybackTime;
  if (!isfinite(playbackS) || playbackS < 0) return DBVideoStatsMake(NO, 0, 0, (CGFloat)fps);
  int64_t displayedDts = baseDts + (int64_t)(playbackS * 1000.0);
  int64_t behindLiveMs = latestDts > displayedDts ? latestDts - displayedDts : 0;
  int64_t nowMs = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
  int64_t latency = nowMs - latestCapture - [_demux serverToClientOffsetMs] + behindLiveMs;
  if (latency < 0 || latency >= 120000)
    return DBVideoStatsMake(NO, 0, 0, (CGFloat)fps);
  if (_reportedLatencyCount > 0) {
    double variation = fabs((double)(latency - _reportedLatencyMs));
    _reportedJitterMs += (variation - _reportedJitterMs) / 8.0;
  }
  _reportedLatencyMs = latency;
  _reportedLatencyCount++;
  return DBVideoStatsMake(YES, (NSInteger)latency,
                          (NSInteger)(_reportedJitterMs + 0.5), (CGFloat)fps);
}

- (void)setStateOnMain:(DBH264PlayerState)state {
  NSAssert([NSThread isMainThread], @"H.264 state/UI must stay on main");
  if (_state == state) return;
  _state = state;
  if (_onState && (state == DBH264PlayerPlaying || state == DBH264PlayerFailed))
    _onState(state);
}

- (void)start {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
    return;
  }
  if (_demux || _state != DBH264PlayerIdle) return;
  if ([_url length] == 0 || !_container) {
    [self setStateOnMain:DBH264PlayerFailed];
    return;
  }

  _generation++;
  const NSUInteger generation = _generation;
  [_statsLock lock];
  _statsBaseDtsMs = -1;
  _statsLatestDtsMs = 0;
  _statsLatestCaptureMs = 0;
  _statsFramesPerSecond = 0;
  [_statsLock unlock];
  _reportedLatencyCount = 0;
  _reportedLatencyMs = 0;
  _reportedJitterMs = 0;
  _mux = dbtsmux_create(SegSink, (__bridge void *)self);
  if (!_mux) {
    [self setStateOnMain:DBH264PlayerFailed];
    return;
  }
  _server = [[DBHlsServer alloc] init];
  if (![_server start]) {
    dbtsmux_free(_mux);
    _mux = NULL;
    [self setStateOnMain:DBH264PlayerFailed];
    return;
  }

  [self setStateOnMain:DBH264PlayerLoading];
  DBH264Dbg(@"[h264] start fMP4 -> HLS: %@", _url);
  _demux = [[DBFmp4Demux alloc] initWithURLString:_url delegate:self];
  [_demux start];

  __weak DBH264Player *weakSelf = self;
  // Encoder startup is demand-driven and the first three IDR-aligned HLS
  // segments can legitimately take more than 15 seconds on the door station.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    DBH264Player *player = weakSelf;
    if (player && player->_generation == generation &&
        player->_state == DBH264PlayerLoading)
      [player failOnMain:@"startup timeout"];
  });
}

- (NSData *)annexbFromAvcc:(NSData *)avcc {
  NSMutableData *out = [NSMutableData dataWithCapacity:[avcc length] + 32];
  static const uint8_t sc[4] = {0, 0, 0, 1};
  const uint8_t *p = (const uint8_t *)[avcc bytes];
  NSUInteger len = [avcc length], off = 0;
  while (off + 4 <= len) {
    uint32_t n = ((uint32_t)p[off] << 24) | ((uint32_t)p[off + 1] << 16) |
                 ((uint32_t)p[off + 2] << 8) | p[off + 3];
    off += 4;
    if (n == 0 || off + n > len) return nil;
    [out appendBytes:sc length:sizeof(sc)];
    [out appendBytes:p + off length:n];
    off += n;
  }
  return off == len ? out : nil;
}

- (void)fmp4DemuxReady:(DBFmp4Demux *)demux sps:(NSData *)sps pps:(NSData *)pps {
  (void)demux;
  if (!_mux) return;
  _sps = [sps copy];
  _pps = [pps copy];
  dbtsmux_set_sps_pps(_mux, (const uint8_t *)[_sps bytes], [_sps length],
                      (const uint8_t *)[_pps bytes], [_pps length]);
  DBH264Dbg(@"[h264] demux ready sps=%lu pps=%lu",
            (unsigned long)[sps length], (unsigned long)[pps length]);
}

- (void)finishSegmentAt:(int64_t)nextStartMs {
  if (![_seg length]) return;
  int64_t duration = nextStartMs - _segStartMs;
  if (duration <= 0) return;
  [_server addSegment:[_seg copy] durationMs:duration];
  _segSeq++;
  DBH264Dbg(@"[h264] segment %llu (%lu bytes, %lld ms)",
            (unsigned long long)_segSeq, (unsigned long)[_seg length],
            (long long)duration);
  _seg = nil;

  // A live HLS playlist needs enough media for the iOS 5 player to choose a
  // stable start point; two segments frequently leaves it probing an entry
  // that rolls out before the first media request.
  if (!_movieStartScheduled && [_server segmentCount] >= 3) {
    _movieStartScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [self startMovieOnMain]; });
  }
}

- (void)fmp4Demux:(DBFmp4Demux *)demux sample:(NSData *)avcc key:(BOOL)key
         captureMs:(int64_t)captureMs dtsMs:(int64_t)dtsMs durMs:(int64_t)durMs {
  (void)demux;
  if (!_mux || !_sps || !_pps) return;
  BOOL isKey = key || AvccHasIdr(avcc);

  [_statsLock lock];
  if (captureMs > 0) {
    _statsLatestCaptureMs = captureMs;
    _statsLatestDtsMs = dtsMs;
  }
  if (durMs > 0) {
    double instantFps = 1000.0 / (double)durMs;
    _statsFramesPerSecond = _statsFramesPerSecond > 0
        ? _statsFramesPerSecond * 0.9 + instantFps * 0.1 : instantFps;
  }
  [_statsLock unlock];

  // Every HLS segment must start with an IDR. Close the old segment before
  // feeding the keyframe that starts the next segment.
  if (!_seg) {
    if (!isKey) return;
    _seg = [[NSMutableData alloc] init];
    _segStartMs = dtsMs;
    [_statsLock lock];
    if (_statsBaseDtsMs < 0) _statsBaseDtsMs = dtsMs;
    [_statsLock unlock];
    dbtsmux_begin_segment(_mux);
  } else if (isKey && dtsMs - _segStartMs >= 1500) {
    [self finishSegmentAt:dtsMs];
    _seg = [[NSMutableData alloc] init];
    _segStartMs = dtsMs;
    dbtsmux_begin_segment(_mux);
  }

  NSData *annexb = [self annexbFromAvcc:avcc];
  if (![annexb length]) return;
  dbtsmux_feed_au(_mux, (const uint8_t *)[annexb bytes], [annexb length],
                  dtsMs, dtsMs, isKey);
}

- (void)startMovieOnMain {
  NSAssert([NSThread isMainThread], @"MPMoviePlayer must start on main");
  if (_state != DBH264PlayerLoading || _player) return;

  _player = [[MPMoviePlayerController alloc]
      initWithContentURL:[NSURL URLWithString:[_server playlistUrl]]];
  _player.controlStyle = MPMovieControlStyleNone;
  _player.movieSourceType = MPMovieSourceTypeStreaming;
  _player.scalingMode = MPMovieScalingModeAspectFit;
  _player.shouldAutoplay = YES;
  _player.view.backgroundColor = [UIColor blackColor];
  _player.view.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _player.view.frame = _container.bounds;
  _player.view.hidden = YES;  // Keep MJPEG visible until playback really begins.
  [_container addSubview:_player.view];

  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  [nc addObserver:self selector:@selector(onMpLoadState:)
             name:MPMoviePlayerLoadStateDidChangeNotification object:_player];
  [nc addObserver:self selector:@selector(onMpPlaybackState:)
             name:MPMoviePlayerPlaybackStateDidChangeNotification object:_player];
  [nc addObserver:self selector:@selector(onMpFinish:)
             name:MPMoviePlayerPlaybackDidFinishNotification object:_player];
  [_player prepareToPlay];
  [_player play];
  DBH264Dbg(@"[h264] movie start: %@", [_server playlistUrl]);
}

- (void)promoteMovieIfPlaying {
  if (_state != DBH264PlayerLoading || !_player) return;
  if (_player.playbackState != MPMoviePlaybackStatePlaying) return;
  _player.view.hidden = NO;
  [self setStateOnMain:DBH264PlayerPlaying];
}

- (void)onMpLoadState:(NSNotification *)note {
  (void)note;
  DBH264Dbg(@"[h264] load=%ld playback=%ld", (long)_player.loadState,
            (long)_player.playbackState);
  [self promoteMovieIfPlaying];
}

- (void)onMpPlaybackState:(NSNotification *)note {
  (void)note;
  [self promoteMovieIfPlaying];
}

- (void)onMpFinish:(NSNotification *)note {
  NSNumber *reason = [[note userInfo]
      objectForKey:MPMoviePlayerPlaybackDidFinishReasonUserInfoKey];
  DBH264Dbg(@"[h264] movie finished reason=%@", reason ?: @"unknown");
  if (_state != DBH264PlayerIdle) [self failOnMain:@"movie playback ended"];
}

- (void)fmp4DemuxFailed:(DBFmp4Demux *)demux {
  (void)demux;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_state != DBH264PlayerIdle) [self failOnMain:@"fMP4 stream failed"];
  });
}

- (void)failOnMain:(NSString *)reason {
  NSAssert([NSThread isMainThread], @"H.264 failure must be delivered on main");
  if (_state == DBH264PlayerIdle || _state == DBH264PlayerFailed) return;
  DBH264Dbg(@"[h264] failed: %@", reason);
  if (_player) _player.view.hidden = YES;
  [self setStateOnMain:DBH264PlayerFailed];
}

- (void)stop {
  if (![NSThread isMainThread]) {
    dispatch_sync(dispatch_get_main_queue(), ^{ [self stop]; });
    return;
  }
  _generation++;
  _state = DBH264PlayerIdle;

  DBFmp4Demux *demux = _demux;
  _demux = nil;
  [demux stop];  // waits until any in-flight delegate callback has returned

  if (_player) {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:_player];
    [_player stop];
    [_player.view removeFromSuperview];
    _player = nil;
  }
  if (_mux) {
    dbtsmux_free(_mux);
    _mux = NULL;
  }
  [_server stop];
  _server = nil;
  _seg = nil;
  _sps = nil;
  _pps = nil;
  _movieStartScheduled = NO;
  _segSeq = 0;
  [_statsLock lock];
  _statsBaseDtsMs = -1;
  _statsLatestDtsMs = 0;
  _statsLatestCaptureMs = 0;
  _statsFramesPerSecond = 0;
  [_statsLock unlock];
  _reportedLatencyCount = 0;
  _reportedLatencyMs = 0;
  _reportedJitterMs = 0;
}

- (void)dealloc {
  [_demux stop];
  if (_mux) dbtsmux_free(_mux);
  if (_player) {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:_player];
    [_player stop];
  }
  [_server stop];
}

@end
