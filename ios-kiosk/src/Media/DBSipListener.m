#import "DBSipListener.h"

#import "../Core/DBSipChurnPolicy.h"
#import "DBAudioIO.h"
#import "minisip.h"
#import <string.h>

@interface DBSipListener ()
- (void)deliverStateInfo:(NSDictionary *)info;
- (void)deliverIfChanged:(DBMiniSipState)state mode:(NSString *)mode log:(NSString *)what;
@end

static void DBListenerRxAudio(const int16_t *pcm, int n, void *user);
static int DBListenerPullTx(int16_t *pcm, int n, void *user);
static void DBListenerOnState(ms_state state, void *user);

@implementation DBSipListener {
@public
  DBAudioIO *_audioForCallbacks;
  ms_session *_session;
@private
  int _port;
  BOOL _micEnabled;
  NSThread *_thread;
  volatile BOOL _stopRequested;
  volatile BOOL _hangupRequested;
  BOOL _audioStarted;
  NSString *_mode;
  DBSipChurnPolicy *_churn;
  // Duplicate state deliveries are what reached the main thread 1.5 times a
  // second on the device; only a change is worth a hop.
  DBMiniSipState _lastDeliveredState;
  NSString *_lastDeliveredMode;
  BOOL _hasDeliveredState;
}

@synthesize delegate = _delegate;

- (id)initWithPort:(int)port micEnabled:(BOOL)micEnabled {
  self = [super init];
  if (self) {
    _port = port;
    _micEnabled = micEnabled;
    _mode = @"";
    _audioForCallbacks = [[DBAudioIO alloc] init];
    _audioForCallbacks.micEnabled = micEnabled;
    _churn = [[DBSipChurnPolicy alloc] init];
    _lastDeliveredMode = @"";
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (void)start {
  if (_thread != nil) return;
  _stopRequested = NO;
  _hangupRequested = NO;
  _thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil];
  [_thread start];
}

- (void)hangupCurrentCall {
  _hangupRequested = YES;
}

- (void)stop {
  _stopRequested = YES;
  _hangupRequested = YES;
  [_audioForCallbacks stop];
}

- (void)threadMain {
  @autoreleasepool {
    ms_callbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.on_rx_audio = DBListenerRxAudio;
    callbacks.pull_tx_audio = DBListenerPullTx;
    callbacks.on_state = DBListenerOnState;
    callbacks.user = (__bridge void *)self;

    while (!_stopRequested) {
      _hangupRequested = NO;
      _audioStarted = NO;
      _mode = @"";
      _session = ms_listen(_port, &callbacks);
      if (_session == NULL) {
        NSLog(@"[doorbell][sip-uas] cannot bind UDP %d; retrying", _port);
        [self deliverIfChanged:DBMiniSipEnded mode:@"bind_failed" log:@""];
        [NSThread sleepForTimeInterval:2.0];
        continue;
      }
      // ms_listen has already created and bound the socket at this point. Do
      // not advertise a usable UAS before this concrete readiness boundary.
      // Only a state change crosses to the main thread; re-listening after an
      // empty dialog is not news.
      [self deliverIfChanged:DBMiniSipListening mode:@"" log:@"listening UDP"];
      NSTimeInterval dialogStartedAt = [NSDate timeIntervalSinceReferenceDate];
      while (!_stopRequested) {
        int result = ms_poll(_session, 20);
        ms_state state = ms_get_state(_session);
        if ((state == MS_STATE_RINGING || state == MS_STATE_IN_CALL) && !_audioStarted) {
          const char *modeValue = ms_get_mode(_session);
          _mode = [NSString stringWithUTF8String:(modeValue ? modeValue : "")];
          if ([_audioForCallbacks start]) {
            _audioStarted = YES;
          } else {
            NSLog(@"[doorbell][sip-uas] audio start failed");
            _hangupRequested = YES;
          }
        }
        if (_hangupRequested) {
          _hangupRequested = NO;
          ms_hangup(_session);
        }
        if (result != 0 || ms_get_state(_session) == MS_STATE_ENDED) break;
      }

      if (_session && ms_get_state(_session) != MS_STATE_ENDED) {
        ms_hangup(_session);
        NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 0.6;
        while (ms_get_state(_session) != MS_STATE_ENDED &&
               [NSDate timeIntervalSinceReferenceDate] < deadline)
          ms_poll(_session, 20);
      }
      [_audioForCallbacks stop];
      _audioStarted = NO;
      NSTimeInterval delay = [DBSipChurnPolicy delayForChurnCount:0];
      if (_session) {
        unsigned long tx = 0, rx = 0;
        ms_get_stats(_session, &tx, &rx);
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        delay = [_churn delayAfterDialogWithDuration:(now - dialogStartedAt)
                                          rtpPackets:(tx + rx)
                                                  at:now];
        // A dialog that carried audio is always worth a line; a flood of empty
        // ones is logged once, when the policy starts spacing them out.
        if ((tx + rx) > 0 || [_churn consumeChurnLogRequest]) {
          NSUInteger churn = [_churn churnCount];
          NSString *suffix = @"";
          if (churn >= 3) {
            suffix = [NSString stringWithFormat:@"; %lu empty dialogs, spacing to %.2fs",
                                                (unsigned long)churn, delay];
          }
          NSLog(@"[doorbell][sip-uas] dialog ended mode=%@ RTP tx=%lu rx=%lu%@",
                _mode, tx, rx, suffix);
        }
        ms_free(_session);
        _session = NULL;
      }
      if (!_stopRequested) [NSThread sleepForTimeInterval:delay];
    }
  }
  _thread = nil;
}

// Coalesces on the listener thread so an unchanged state never reaches the
// main thread at all.
- (void)deliverIfChanged:(DBMiniSipState)state mode:(NSString *)mode log:(NSString *)what {
  NSString *value = mode ?: @"";
  if (_hasDeliveredState && _lastDeliveredState == state &&
      [_lastDeliveredMode isEqualToString:value])
    return;
  _hasDeliveredState = YES;
  _lastDeliveredState = state;
  _lastDeliveredMode = [value copy];
  if ([what length] > 0) NSLog(@"[doorbell][sip-uas] %@ %d", what, _port);
  [self performSelectorOnMainThread:@selector(deliverStateInfo:)
                         withObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                        [NSNumber numberWithInt:(int)state], @"state",
                                        value, @"mode", nil]
                      waitUntilDone:NO];
}

- (void)deliverStateInfo:(NSDictionary *)info {
  DBMiniSipState state = (DBMiniSipState)[[info objectForKey:@"state"] intValue];
  NSString *mode = [info objectForKey:@"mode"];
  if (![mode isKindOfClass:[NSString class]]) mode = @"";
  if (_delegate) [_delegate miniSipListenerStateChanged:state mode:mode];
}

@end

static void DBListenerRxAudio(const int16_t *pcm, int n, void *user) {
  DBSipListener *listener = (__bridge DBSipListener *)user;
  [listener->_audioForCallbacks enqueueRx:(const short *)pcm count:n];
}

static int DBListenerPullTx(int16_t *pcm, int n, void *user) {
  DBSipListener *listener = (__bridge DBSipListener *)user;
  return [listener->_audioForCallbacks dequeueTx:(short *)pcm max:n];
}

static void DBListenerOnState(ms_state state, void *user) {
  DBSipListener *listener = (__bridge DBSipListener *)user;
  NSString *mode = @"";
  if (listener->_session) {
    const char *raw = ms_get_mode(listener->_session);
    if (raw) mode = [NSString stringWithUTF8String:raw];
  }
  // Through the same coalescing bookkeeping as the run loop's own deliveries,
  // so the main thread's view and the listener's record cannot diverge.
  [listener deliverIfChanged:(DBMiniSipState)state mode:mode log:@""];
}
