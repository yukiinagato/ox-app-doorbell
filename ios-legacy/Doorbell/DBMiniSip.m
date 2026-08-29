#import "DBMiniSip.h"
#import "DBAudioIO.h"
#import <pthread.h>
#import "minisip.h"

@interface DBMiniSip ()
- (void)deliverState:(NSNumber *)state;
@end

// ---- ミニ SIP コールバック (poll スレッド上で実行される。定義は @implementation の後) ----
static void DBSipRxAudio(const int16_t *pcm, int n, void *user);
static int DBSipPullTx(int16_t *pcm, int n, void *user);
static void DBSipOnState(ms_state st, void *user);

@implementation DBMiniSip {
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
  [_host release];
  [_mode release];
  [_pendingDtmf release];
  [_audioForCb release];
  [_thread release];
  pthread_mutex_destroy(&_dtmfLock);
  [super dealloc];
}

- (void)start {
  if (_thread != nil) return;
  _stop = NO;
  [_audioForCb start];
  // スレッド生存期間中は自己保持する (dealloc が poll スレッド走行中に走るのを防ぐ)。
  // threadMain の最後で release する。これが無いと 2 回目の呼出時に解放済みオブジェクトへ
  // コールバックが飛び UI が凍結/破壊される (MRC)。
  [self retain];
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
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  ms_callbacks cbs;
  memset(&cbs, 0, sizeof(cbs));
  cbs.on_rx_audio = DBSipRxAudio;
  cbs.pull_tx_audio = DBSipPullTx;
  cbs.on_state = DBSipOnState;
  cbs.user = self;

  const char *modeC = [_mode length] > 0 ? [_mode UTF8String] : "";
  _session = ms_call([_host UTF8String], _port, modeC, &cbs);
  // ms_call が NULL の場合 (接続失敗):
  if (_session == NULL) {
    [self performSelectorOnMainThread:@selector(deliverState:)
                           withObject:[NSNumber numberWithInt:DBMiniSipEnded]
                        waitUntilDone:NO];
    [pool release];
    [self release];  // start() で retain した分
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
  [pool release];
  [self release];  // start() で retain した分 (これ以降 self には触れない)
}

- (void)deliverState:(NSNumber *)state {
  if (_delegate) [_delegate miniSipStateChanged:(DBMiniSipState)[state intValue]];
}

@end

// ---- ミニ SIP コールバック定義 (ivar 可視) ----
static void DBSipRxAudio(const int16_t *pcm, int n, void *user) {
  DBMiniSip *me = (DBMiniSip *)user;
  [me->_audioForCb enqueueRx:(const short *)pcm count:n];
}

static int DBSipPullTx(int16_t *pcm, int n, void *user) {
  DBMiniSip *me = (DBMiniSip *)user;
  return [me->_audioForCb dequeueTx:(short *)pcm max:n];
}

static void DBSipOnState(ms_state st, void *user) {
  DBMiniSip *me = (DBMiniSip *)user;
  [me performSelectorOnMainThread:@selector(deliverState:)
                       withObject:[NSNumber numberWithInt:(int)st]
                    waitUntilDone:NO];
}
