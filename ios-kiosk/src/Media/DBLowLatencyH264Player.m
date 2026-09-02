#import "DBLowLatencyH264Player.h"

#import "DBLiveEdgeGate.h"
#import "DBVtVideoView.h"
#import "../Net/DBFmp4Demux.h"
#import <math.h>

void DBH264Dbg(NSString *fmt, ...);

@interface DBLowLatencyH264Player () <DBFmp4DemuxDelegate>
- (void)scheduleDisplayWatchdog:(NSUInteger)generation;
@end

@implementation DBLowLatencyH264Player {
  NSString *_url;
  UIView *_container;
  void (^_onState)(DBLowLatencyPlayerState);
  DBFmp4Demux *_demux;
  DBVtVideoView *_videoView;
  UIImageView *_compatOverlay;
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
  CFAbsoluteTime _lastDisplayedAt;
  CFAbsoluteTime _firstDisplayedAt;
  NSUInteger _displayedFrames;
}

@synthesize liveEdgeStartMs = _liveEdgeStartMs;
@synthesize liveEdgeFloorMs = _liveEdgeFloorMs;
@synthesize liveEdgeCeilingMs = _liveEdgeCeilingMs;

- (id)initWithURL:(NSString *)url container:(UIView *)container
           onState:(void (^)(DBLowLatencyPlayerState))onState {
  self = [super init];
  if (self) {
    _url = [url copy];
    _container = container;
    _onState = [onState copy];
    _liveEdgeStartMs = DB_LIVE_EDGE_DEFAULT_START_MS;
    _liveEdgeFloorMs = DB_LIVE_EDGE_DEFAULT_FLOOR_MS;
    _liveEdgeCeilingMs = DB_LIVE_EDGE_DEFAULT_CEILING_MS;
  }
  return self;
}

- (DBLowLatencyPlayerState)state { return _state; }

- (DBVideoStats)videoStats {
  return DBVideoStatsMake(_latencyCount > 0, (NSInteger)_currentLatencyMs,
                          (NSInteger)(_jitterMs + 0.5), (CGFloat)_framesPerSecond);
}

// Every displayed frame counts here, not only the ones with a usable capture
// timestamp, so the screen's stall watchdog sees the real display rate.
- (CFAbsoluteTime)lastFrameAt { return _lastDisplayedAt; }
- (NSUInteger)decodedFrames { return [_videoView decodedFrames]; }
- (NSUInteger)displayedFrames { return _displayedFrames; }
- (NSUInteger)droppedFrames { return [_videoView droppedFrames]; }
- (NSString *)presentationMode { return @"uikit_bgra_sibling"; }

- (void)setState:(DBLowLatencyPlayerState)state {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self setState:state]; });
    return;
  }
  if (_state == state) return;
  _state = state;
  if (_onState && (state == DBLowLatencyPlayerPlaying ||
                   state == DBLowLatencyPlayerFailed ||
                   state == DBLowLatencyPlayerStalled))
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
  _lastDisplayedAt = 0;
  _firstDisplayedAt = 0;
  _displayedFrames = 0;
  _waitingForKeyframe = YES;
  NSUInteger generation = _generation;
  // Keep GLKView attached so its draw callback can make the compatibility
  // UIImage, but do not let its legacy EAGL surface cover the availability
  // layer while H.264 is still probing. On iOS 5, an ostensibly transparent
  // GLK renderbuffer can still composite as black over a sibling MJPEG view.
  _videoView = [[DBVtVideoView alloc] initWithFrame:CGRectMake(-1, -1, 1, 1)];
  _videoView.autoresizingMask = UIViewAutoresizingNone;
  _videoView.hidden = NO;
  [_container addSubview:_videoView];
  // GLKView presents its renderbuffer directly on iOS 5. A UIKit image view
  // nested inside it can have valid decoded content yet still be overwritten
  // during presentation on the original iPad. Keep the compatibility BGRA
  // compositor as a sibling above GLKView so Core Animation owns final display.
  _compatOverlay = [[UIImageView alloc] initWithFrame:_container.bounds];
  _compatOverlay.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _compatOverlay.contentMode = UIViewContentModeScaleAspectFit;
  _compatOverlay.backgroundColor = [UIColor blackColor];
  _compatOverlay.opaque = YES;
  _compatOverlay.userInteractionEnabled = NO;
  _compatOverlay.hidden = YES;
  [_container addSubview:_compatOverlay];
  [_videoView setCompatibilityOutputView:_compatOverlay];
  __weak DBLowLatencyH264Player *weakSelf = self;
  _videoView.onDisplayedFrame = ^(int64_t captureMs) {
    DBLowLatencyH264Player *player = weakSelf;
    if (!player || player->_generation != generation) return;
    player->_displayedFrames++;
    CFAbsoluteTime displayedAt = CFAbsoluteTimeGetCurrent();
    player->_lastDisplayedAt = displayedAt;
    if (player->_firstDisplayedAt == 0) {
      player->_firstDisplayedAt = displayedAt;
      DBH264Dbg(@"[vt] first frame displayed");
    }
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
    // The compatibility overlay is opaque: bringing it to front hides the
    // MJPEG availability layer underneath. Do that only once H.264 has proved
    // it can sustain a real frame rate, so a decoder that manages one frame
    // and then stalls can never leave a frozen still where MJPEG was live.
    if (player->_state == DBLowLatencyPlayerLoading &&
        DBLiveEdgeSustained((uint32_t)player->_displayedFrames,
                            (double)(displayedAt - player->_firstDisplayedAt))) {
      player->_videoView.hidden = NO;
      player->_compatOverlay.hidden = NO;
      [player->_container bringSubviewToFront:player->_compatOverlay];
      DBH264Dbg(@"[vt] sustained %lu displayed frames; H.264 takes over from MJPEG",
                (unsigned long)player->_displayedFrames);
      [player setState:DBLowLatencyPlayerPlaying];
      [player scheduleDisplayWatchdog:generation];
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

// A decoder that stops delivering frames while the opaque compositor covers
// MJPEG is worse than no H.264 at all. Watch the display rate and hand the
// screen back to the availability layer when it collapses.
- (void)scheduleDisplayWatchdog:(NSUInteger)generation {
  __weak DBLowLatencyH264Player *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 2)),
                 dispatch_get_main_queue(), ^{
    DBLowLatencyH264Player *player = weakSelf;
    if (!player || player->_generation != generation) return;
    if (player->_state != DBLowLatencyPlayerPlaying) return;
    double idle = (double)(CFAbsoluteTimeGetCurrent() - player->_lastDisplayedAt);
    if (DBLiveEdgeCollapsed((uint32_t)player->_displayedFrames, idle)) {
      DBH264Dbg(@"[vt] display collapsed after %lu frames (%.2fs idle); back to MJPEG",
                (unsigned long)player->_displayedFrames, idle);
      player->_compatOverlay.hidden = YES;
      [player setState:DBLowLatencyPlayerStalled];
      return;
    }
    [player scheduleDisplayWatchdog:generation];
  });
}

- (void)fmp4DemuxReady:(DBFmp4Demux *)demux sps:(NSData *)sps pps:(NSData *)pps {
  _videoView.serverToClientOffsetMs = [demux serverToClientOffsetMs];
  // Adaptive live edge. It starts at the last known-good conservative value
  // and tightens only after this device's own baseline latency is measured;
  // DBLiveEdgeGate.h documents why the original iPad's SGX535 upload path
  // cannot meet a fixed sub-100ms glass-to-glass budget.
  [_videoView configureLiveEdgeStartMs:_liveEdgeStartMs
                               floorMs:_liveEdgeFloorMs
                             ceilingMs:_liveEdgeCeilingMs
                          clockTrusted:[demux clockOffsetTrusted]];
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
  [_compatOverlay removeFromSuperview];
  _compatOverlay = nil;
}

- (void)dealloc {
  [_demux stop];
  [_videoView shutdownDecoder];
}

@end
