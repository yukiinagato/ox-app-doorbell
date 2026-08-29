#import "DBLowLatencyH264Player.h"

#import "DBVtVideoView.h"
#import "../Net/DBFmp4Demux.h"
#import <math.h>

void DBH264Dbg(NSString *fmt, ...);

@interface DBLowLatencyH264Player () <DBFmp4DemuxDelegate>
@end

@implementation DBLowLatencyH264Player {
  NSString *_url;
  UIView *_container;
  void (^_onState)(DBLowLatencyPlayerState);
  DBFmp4Demux *_demux;
  DBVtVideoView *_videoView;
  DBLowLatencyPlayerState _state;
  NSUInteger _generation;
  BOOL _waitingForKeyframe;
  int64_t _lastCaptureMs;
  NSUInteger _latencyCount;
  int64_t _latencySum;
  int64_t _latencyMax;
  int64_t _currentLatencyMs;
  int64_t _previousLatencyMs;
  double _jitterMs;
  double _framesPerSecond;
  CFAbsoluteTime _lastStatsFrameAt;
}

- (id)initWithURL:(NSString *)url container:(UIView *)container
           onState:(void (^)(DBLowLatencyPlayerState))onState {
  self = [super init];
  if (self) {
    _url = [url copy];
    _container = container;
    _onState = [onState copy];
  }
  return self;
}

- (DBLowLatencyPlayerState)state { return _state; }

- (DBVideoStats)videoStats {
  return DBVideoStatsMake(_latencyCount > 0, (NSInteger)_currentLatencyMs,
                          (NSInteger)(_jitterMs + 0.5), (CGFloat)_framesPerSecond);
}

- (void)setState:(DBLowLatencyPlayerState)state {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self setState:state]; });
    return;
  }
  if (_state == state) return;
  _state = state;
  if (_onState && (state == DBLowLatencyPlayerPlaying || state == DBLowLatencyPlayerFailed))
    _onState(state);
}

- (void)start {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
    return;
  }
  if (_demux || _state != DBLowLatencyPlayerIdle || ![_url length] || !_container) return;
  _generation++;
  _lastCaptureMs = 0;
  _latencyCount = 0;
  _latencySum = 0;
  _latencyMax = 0;
  _currentLatencyMs = 0;
  _previousLatencyMs = 0;
  _jitterMs = 0;
  _framesPerSecond = 0;
  _lastStatsFrameAt = 0;
  _waitingForKeyframe = YES;
  NSUInteger generation = _generation;
  _videoView = [[DBVtVideoView alloc] initWithFrame:_container.bounds];
  _videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _videoView.hidden = YES;
  [_container addSubview:_videoView];
  __weak DBLowLatencyH264Player *weakSelf = self;
  _videoView.onDisplayedFrame = ^(int64_t captureMs) {
    DBLowLatencyH264Player *player = weakSelf;
    if (!player || player->_generation != generation) return;
    if (captureMs > 0 && captureMs != player->_lastCaptureMs) {
      player->_lastCaptureMs = captureMs;
      int64_t nowMs = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
      int64_t latency = nowMs - captureMs - [player->_demux serverToClientOffsetMs];
      if (latency >= 0 && latency < 10000) {
        CFAbsoluteTime frameAt = CFAbsoluteTimeGetCurrent();
        if (player->_latencyCount > 0) {
          double variation = fabs((double)(latency - player->_previousLatencyMs));
          player->_jitterMs += (variation - player->_jitterMs) / 8.0;
          CFAbsoluteTime dt = frameAt - player->_lastStatsFrameAt;
          if (dt > 0.005 && dt < 2.0) {
            double instantFps = 1.0 / dt;
            player->_framesPerSecond = player->_framesPerSecond > 0
                ? player->_framesPerSecond * 0.8 + instantFps * 0.2 : instantFps;
          }
        }
        player->_currentLatencyMs = latency;
        player->_previousLatencyMs = latency;
        player->_lastStatsFrameAt = frameAt;
        player->_latencyCount++;
        player->_latencySum += latency;
        if (latency > player->_latencyMax) player->_latencyMax = latency;
        DBH264Dbg(@"[latency] frame=%lu e2e=%lldms avg=%lldms max=%lldms",
                  (unsigned long)player->_latencyCount, (long long)latency,
                  (long long)(player->_latencySum / player->_latencyCount),
                  (long long)player->_latencyMax);
      }
    }
    if (player->_state == DBLowLatencyPlayerLoading) {
      player->_videoView.hidden = NO;
      DBH264Dbg(@"[vt] first frame displayed");
      [player setState:DBLowLatencyPlayerPlaying];
    }
  };
  _state = DBLowLatencyPlayerLoading;
  DBH264Dbg(@"[vt] start fMP4 direct decode: %@", _url);
  _demux = [[DBFmp4Demux alloc] initWithURLString:_url delegate:self];
  [_demux start];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
    DBLowLatencyH264Player *player = weakSelf;
    if (player && player->_generation == generation &&
        player->_state == DBLowLatencyPlayerLoading) {
      DBH264Dbg(@"[vt] startup timeout");
      [player setState:DBLowLatencyPlayerFailed];
    }
  });
}

- (void)fmp4DemuxReady:(DBFmp4Demux *)demux sps:(NSData *)sps pps:(NSData *)pps {
  _videoView.serverToClientOffsetMs = [demux serverToClientOffsetMs];
  // Hard live edge: leave ~30ms for the 640x360 BGRA upload and never display
  // a frame which can no longer meet the 100ms glass-to-glass budget.
  _videoView.maxQueueAgeMs = 70;
  if (![_videoView startWithSps:sps pps:pps]) {
    DBH264Dbg(@"[vt] decoder start failed");
    [self setState:DBLowLatencyPlayerFailed];
  }
}

- (void)fmp4Demux:(DBFmp4Demux *)demux sample:(NSData *)avcc key:(BOOL)key
         captureMs:(int64_t)captureMs dtsMs:(int64_t)dtsMs durMs:(int64_t)durMs {
  (void)demux;
  // A live fMP4 connection commonly begins between GOPs.  Feeding P/B frames
  // before the first IDR makes the iOS 5 hardware decoder enter its synchronous
  // error callback path.  Join only at a random-access point.
  if (_waitingForKeyframe) {
    if (!key) return;
    _waitingForKeyframe = NO;
    DBH264Dbg(@"[vt] first keyframe received");
  }
  [_videoView pushSample:avcc captureMs:captureMs dtsMs:dtsMs durMs:durMs];
}

- (void)fmp4DemuxFailed:(DBFmp4Demux *)demux {
  (void)demux;
  [self setState:DBLowLatencyPlayerFailed];
}

- (void)stop {
  if (![NSThread isMainThread]) {
    dispatch_sync(dispatch_get_main_queue(), ^{ [self stop]; });
    return;
  }
  _generation++;
  _state = DBLowLatencyPlayerIdle;
  _waitingForKeyframe = YES;
  DBFmp4Demux *demux = _demux;
  _demux = nil;
  [demux stop];
  [_videoView shutdownDecoder];
  [_videoView removeFromSuperview];
  _videoView = nil;
}

- (void)dealloc {
  [_demux stop];
  [_videoView shutdownDecoder];
}

@end
