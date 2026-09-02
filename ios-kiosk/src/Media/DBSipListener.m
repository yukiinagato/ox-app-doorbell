#import "DBSipListener.h"

#import "DBAudioIO.h"
#import "minisip.h"
#import <string.h>

@interface DBSipListener ()
- (void)deliverStateInfo:(NSDictionary *)info;
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
        [self performSelectorOnMainThread:@selector(deliverStateInfo:)
                               withObject:@{ @"state" : @(DBMiniSipEnded),
                                             @"mode" : @"bind_failed" }
                            waitUntilDone:NO];
        [NSThread sleepForTimeInterval:2.0];
        continue;
      }
      NSLog(@"[doorbell][sip-uas] listening UDP %d", _port);
      // ms_listen has already created and bound the socket at this point. Do
      // not advertise a usable UAS before this concrete readiness boundary.
      [self performSelectorOnMainThread:@selector(deliverStateInfo:)
                             withObject:@{ @"state" : @(DBMiniSipListening),
                                           @"mode" : @"" }
                          waitUntilDone:NO];
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
      if (_session) {
        unsigned long tx = 0, rx = 0;
        ms_get_stats(_session, &tx, &rx);
        NSLog(@"[doorbell][sip-uas] dialog ended mode=%@ RTP tx=%lu rx=%lu", _mode, tx, rx);
        ms_free(_session);
        _session = NULL;
      }
      if (!_stopRequested) [NSThread sleepForTimeInterval:0.15];
    }
  }
  _thread = nil;
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
  NSDictionary *info = @{ @"state" : [NSNumber numberWithInt:(int)state], @"mode" : mode };
  [listener performSelectorOnMainThread:@selector(deliverStateInfo:)
                             withObject:info waitUntilDone:NO];
}
