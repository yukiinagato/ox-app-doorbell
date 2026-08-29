#import "DBSipSession.h"
#import "DBAudioIO.h"
#import <pthread.h>
#import "minisip.h"

@interface DBSipSession ()
- (void)deliverState:(NSNumber *)state;
@end

// ---- ミニ SIP コールバック (poll スレッド上で実行される。定義は @implementation の後) ----
static void DBSipRxAudio(const int16_t *pcm, int n, void *user);
static int DBSipPullTx(int16_t *pcm, int n, void *user);
static void DBSipOnState(ms_state st, void *user);

@implementation DBSipSession {
@public
  DBAudioIO *_audioForCb;  // コールバックから直接触るため @public
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
    _micEnabled = micEnabled;
    _pendingDtmf = [[NSMutableString alloc] init];
    pthread_mutex_init(&_dtmfLock, NULL);
    _audioForCb = [[DBAudioIO alloc] init];
    _audioForCb.micEnabled = micEnabled;
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
  [_audioForCb start];
  // NSThread は target をスレッド完走まで保持する (threadMain の最後まで self は生きる)。
  _thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil];
  [_thread start];
}

- (void)hangup {
  _stop = YES;  // poll スレッドが検知して ms_hangup + ms_free する
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
    if (_session == NULL) {  // 接続失敗
      [self performSelectorOnMainThread:@selector(deliverState:)
                             withObject:[NSNumber numberWithInt:DBMiniSipEnded]
                          waitUntilDone:NO];
      return;
    }

    while (!_stop) {
      int rc = ms_poll(_session, 20);
      // 積まれた DTMF を同スレッドで送る
      pthread_mutex_lock(&_dtmfLock);
      if ([_pendingDtmf length] > 0) {
        const char *d = [_pendingDtmf UTF8String];
        ms_send_dtmf(_session, d);
        [_pendingDtmf setString:@""];
      }
      pthread_mutex_unlock(&_dtmfLock);
      if (rc != 0) break;  // 終了 or 致命エラー
    }

    ms_hangup(_session);
    ms_free(_session);
    _session = NULL;
  }
  // ここで NSThread の target 参照が外れる → ARC の最後の release。以後 self には触れない。
}

- (void)deliverState:(NSNumber *)state {
  if (_delegate) [_delegate miniSipStateChanged:(DBMiniSipState)[state intValue]];
}

@end

// ---- ミニ SIP コールバック定義 (ivar 可視) ----
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
