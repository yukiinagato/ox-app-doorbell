#import "DBSipSession.h"
#import "DBAudioIO.h"
#import <pthread.h>
#import "minisip.h"

@interface DBSipSession ()
- (void)deliverState:(NSNumber *)state;
@end


static void DBSipRxAudio(const int16_t *pcm, int n, void *user);
static int DBSipPullTx(int16_t *pcm, int n, void *user);
static void DBSipOnState(ms_state st, void *user);

@implementation DBSipSession {
@public
  DBAudioIO *_audioForCb;
@private
  NSString *_host;
  int _port;
  NSString *_mode;
  BOOL _micEnabled;
  NSThread *_thread;
  volatile BOOL _stop;
  ms_session *_session;
  pthread_mutex_t _dtmfLock;
  NSMutableString *_pendingDtmf;
}

@synthesize delegate = _delegate;

- (id)initWithHost:(NSString *)host port:(int)port mode:(NSString *)mode micEnabled:(BOOL)micEnabled {
  self = [super init];
  if (self) {
    _host = [host copy];
    _port = port;
    _mode = [mode copy];
    // Monitor is receive-only. Keeping the recording path closed prevents old
    // iOS versions from reverting output to the receiver and avoids echo.
    _micEnabled = micEnabled && ![mode isEqualToString:@"monitor"];
    _pendingDtmf = [[NSMutableString alloc] init];
    pthread_mutex_init(&_dtmfLock, NULL);
    _audioForCb = [[DBAudioIO alloc] init];
    _audioForCb.micEnabled = _micEnabled;
  }
  return self;
}

- (void)dealloc {
  [self hangup];
  _audioForCb = nil;
  _thread = nil;
  pthread_mutex_destroy(&_dtmfLock);
}

- (void)start {
  if (_thread != nil) return;
  _stop = NO;
  if (![_audioForCb start]) {
    [self performSelectorOnMainThread:@selector(deliverState:)
                           withObject:[NSNumber numberWithInt:DBMiniSipEnded]
                        waitUntilDone:NO];
    return;
  }

  _thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil];
  [_thread start];
}

- (void)hangup {
  _stop = YES;
  [_audioForCb stop];
}

- (void)sendDtmf:(NSString *)digits {
  if ([digits length] == 0) return;
  pthread_mutex_lock(&_dtmfLock);
  [_pendingDtmf appendString:digits];
  pthread_mutex_unlock(&_dtmfLock);
}

- (void)threadMain {
  @autoreleasepool {
    ms_callbacks cbs;
    memset(&cbs, 0, sizeof(cbs));
    cbs.on_rx_audio = DBSipRxAudio;
    cbs.pull_tx_audio = DBSipPullTx;
    cbs.on_state = DBSipOnState;
    cbs.user = (__bridge void *)self;

    const char *modeC = [_mode length] > 0 ? [_mode UTF8String] : "";
    _session = ms_call([_host UTF8String], _port, modeC, &cbs);
    if (_session == NULL) {
      [self performSelectorOnMainThread:@selector(deliverState:)
                             withObject:[NSNumber numberWithInt:DBMiniSipEnded]
                          waitUntilDone:NO];
      return;
    }

    NSTimeInterval nextStatsLog = 0;
    while (!_stop) {
      int rc = ms_poll(_session, 20);
      if (ms_get_state(_session) == MS_STATE_IN_CALL) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now >= nextStatsLog) {
          unsigned long tx = 0, rx = 0;
          ms_get_stats(_session, &tx, &rx);
          NSLog(@"[doorbell][sip] mode=%@ RTP tx=%lu rx=%lu remote=%s",
                _mode, tx, rx, ms_get_remote_rtp(_session));
          nextStatsLog = now + 2.0;
        }
      }

      pthread_mutex_lock(&_dtmfLock);
      if ([_pendingDtmf length] > 0) {
        const char *d = [_pendingDtmf UTF8String];
        ms_send_dtmf(_session, d);
        [_pendingDtmf setString:@""];
      }
      pthread_mutex_unlock(&_dtmfLock);
      if (rc != 0) break;
    }

    unsigned long finalTx = 0, finalRx = 0;
    ms_get_stats(_session, &finalTx, &finalRx);
    NSLog(@"[doorbell][sip] mode=%@ ended RTP tx=%lu rx=%lu", _mode, finalTx, finalRx);
    ms_hangup(_session);
    ms_free(_session);
    _session = NULL;
  }

}

- (void)deliverState:(NSNumber *)state {
  if (_delegate) [_delegate miniSipStateChanged:(DBMiniSipState)[state intValue]];
}

@end


static void DBSipRxAudio(const int16_t *pcm, int n, void *user) {
  DBSipSession *me = (__bridge DBSipSession *)user;
  [me->_audioForCb enqueueRx:(const short *)pcm count:n];
}

static int DBSipPullTx(int16_t *pcm, int n, void *user) {
  DBSipSession *me = (__bridge DBSipSession *)user;
  return [me->_audioForCb dequeueTx:(short *)pcm max:n];
}

static void DBSipOnState(ms_state st, void *user) {
  DBSipSession *me = (__bridge DBSipSession *)user;
  [me performSelectorOnMainThread:@selector(deliverState:)
                       withObject:[NSNumber numberWithInt:(int)st]
                    waitUntilDone:NO];
}
