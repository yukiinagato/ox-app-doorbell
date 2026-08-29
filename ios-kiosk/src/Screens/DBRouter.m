#import "DBRouter.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBTexts.h"
#import "DBHomeScreen.h"
#import "DBIncomingScreen.h"
#import "DBInfoScreen.h"
#import "DBPairingScreen.h"
#import "DBPinOverlay.h"
#import "DBScreen.h"

@implementation DBRouter {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  UIView *_container;
  DBScreen *_current;
  DBHomeScreen *_home;
  DBIncomingScreen *_incoming;
  DBInfoScreen *_info;
  DBPairingScreen *_pairing;
  DBPinOverlay *_pin;
  DBSipSession *_sip;
}

@synthesize core = _core;
@synthesize boot = _boot;
@synthesize texts = _texts;

- (id)initWithBridge:(DBCoreBridge *)core boot:(DBBootConfig *)boot {
  self = [super init];
  if (self) {
    _core = core;
    _boot = boot;
    _texts = [[DBTexts alloc] init];
    [_texts setLang:_boot.uiLang];
    _container = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _container.backgroundColor = [UIColor blackColor];
  }
  return self;
}

#pragma mark - 画面の遅延生成

- (DBHomeScreen *)home {
  if (!_home) _home = [[DBHomeScreen alloc] initWithRouter:self];
  return _home;
}

- (DBIncomingScreen *)incoming {
  if (!_incoming) _incoming = [[DBIncomingScreen alloc] initWithRouter:self];
  return _incoming;
}

- (DBInfoScreen *)info {
  if (!_info) _info = [[DBInfoScreen alloc] initWithRouter:self];
  return _info;
}

- (DBPairingScreen *)pairing {
  if (!_pairing) _pairing = [[DBPairingScreen alloc] initWithRouter:self];
  return _pairing;
}

#pragma mark - 遷移

- (void)start {
  [self showHomeAnimated:NO];
}

- (void)transitionTo:(DBScreen *)next animated:(BOOL)animated {
  if (_current == next) {
    [next setNeedsLayout];
    return;
  }
  next.frame = _container.bounds;
  next.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  DBScreen *old = _current;
  _current = next;
  [old onScreenWillDisappear];
  [next onScreenWillAppear];
  if (animated) {
    next.alpha = 0.0;
    [_container addSubview:next];
    [UIView animateWithDuration:0.25
        animations:^{ next.alpha = 1.0; }
        completion:^(BOOL finished) { [old removeFromSuperview]; }];
  } else {
    [_container addSubview:next];
    [old removeFromSuperview];
  }
}

- (void)showHomeAnimated:(BOOL)animated {
  [self transitionTo:self.home animated:animated];
  [self checkPairingDeferred];
}

// 未配対 (全ゼロ PSK) なら配対引導を出す (home が見えてから少し待つ)。
// pairingInfo の取得も main で行わない (core のロックを main で触らない原則)。
- (void)checkPairingDeferred {
  __weak DBRouter *wself = self;
  DBCoreBridge *core = _core;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    DBRouter *s = wself;
    if (!s || s->_current != s->_home || !s->_home) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      NSDictionary *p = [core pairingInfo];
      dispatch_async(dispatch_get_main_queue(), ^{
        DBRouter *s2 = wself;
        if (!s2 || s2->_current != s2->_home) return;
        if (![p isKindOfClass:[NSDictionary class]]) return;  // core 未起動等 → 触らない
        if ([[p objectForKey:@"paired"] boolValue]) return;   // 配対済み
        [s2 showPairing];
      });
    });
  });
}

- (void)showIncoming:(NSString *)door purpose:(NSString *)purpose lang:(NSString *)lang {
  [[self incoming] prepareWithDoor:door purpose:purpose lang:lang];
  [self transitionTo:_incoming animated:YES];
}

- (void)closeIncomingAnimated:(BOOL)animated {
  if (_current == _incoming) [self showHomeAnimated:animated];
}

- (void)showInfo {
  [[self info] reload];
  [self transitionTo:_info animated:YES];
}

- (void)closeInfoAnimated:(BOOL)animated {
  if (_current == _info) [self showHomeAnimated:animated];
}

- (void)showPairing {
  [[self pairing] startPolling];
  [self transitionTo:_pairing animated:YES];
}

- (void)closePairingAnimated:(BOOL)animated {
  if (_current != _pairing) return;
  [_pairing stopPolling];
  [self showHomeAnimated:animated];
}

- (NSString *)currentScreenName {
  if (_pin && _pin.superview) return [NSString stringWithFormat:@"pin+%@", [_current screenName]];
  return [_current screenName];
}
#pragma mark - PIN 覆盖层

- (void)requestPinThen:(void (^)(void))action {
  if (!_pin) _pin = [[DBPinOverlay alloc] initWithRouter:self];
  [_pin presentInView:_container then:action];
}

- (void)dismissPinOverlay {
  [_pin dismiss];
}

#pragma mark - SIP (単一セッション)

- (void)sipStart:(NSString *)host port:(int)port mode:(NSString *)mode {
  [self sipHangup];
  if ([host length] == 0) return;
  _sip = [[DBSipSession alloc] initWithHost:host port:port mode:mode micEnabled:_boot.micEnabled];
  _sip.delegate = self;
  [_sip start];
}

- (void)sipHangup {
  if (!_sip) return;
  _sip.delegate = nil;  // 後発の状態配送を捨てる
  [_sip hangup];
  _sip = nil;
}

- (void)sipSendDtmf:(NSString *)digits {
  [_sip sendDtmf:digits];
}

// main スレッドで届く (DBSipSession が marshal 済み)
- (void)miniSipStateChanged:(DBMiniSipState)state {
  if (_current == _incoming) [_incoming sipStateChanged:state];
}

#pragma mark - core イベント (main スレッド)

- (void)onCoreEvent:(NSDictionary *)ev {
  NSString *t = [DBConfigUtil evStr:ev key:@"t"];

  if ([t isEqualToString:@"event"]) {
    NSString *type = [DBConfigUtil evStr:ev key:@"type"];
    // 来客 (press の複製) → 来鈴画面。門口機自身 (door_station) は出さない。
    if ([type isEqualToString:@"press"] && ![_boot.role isEqualToString:@"door_station"]) {
      [self showIncoming:[DBConfigUtil evStr:ev key:@"door"]
                 purpose:[DBConfigUtil evStr:ev key:@"purpose"]
                    lang:[DBConfigUtil evStr:ev key:@"visitor_lang"]];
      return;
    }
    [_home appendEvent:ev];
  } else if ([t isEqualToString:@"chime"]) {
    [_home playChime:ev];
  } else if ([t isEqualToString:@"reply"]) {
    if (_current == _incoming) {
      [_incoming handleReplyEvent:ev];
    } else {
      [_home showReplyBanner:ev];
    }
  } else if ([t isEqualToString:@"visitor_lang"]) {
    if (_current == _incoming) [_incoming handleVisitorLangEvent:ev];
  } else if ([t isEqualToString:@"display"]) {
    [_home applyDisplayEvent:ev];
  } else if ([t isEqualToString:@"emergency"]) {
    if ([DBConfigUtil evBool:ev key:@"active"]) {
      [self closeIncomingAnimated:NO];  // 緊急が優先
      [_home showEmergencyEvent:ev];
    } else {
      [_home hideEmergencyEvent:ev];
    }
  } else if ([t isEqualToString:@"paired"]) {
    [self onPaired:ev];
  } else if ([t isEqualToString:@"join_result"]) {
    if (_current == _pairing) [_pairing handleJoinResult:ev];
  } else if ([t isEqualToString:@"peers_changed"] || [t isEqualToString:@"config_changed"] ||
             [t isEqualToString:@"asset_ready"]) {
    if (_current == _home) [_home refreshFromCore];
    if (_current == _pairing) [_pairing reload];
  }
}

// 配対成功 (INVITE 受理 / PIN 参加)。boot.json に PSK/seeds を永続化する。
// 現行プロセスは取得済み PSK で seed 直結・gossip 済み (再起動不要)。次回起動で beacon 再鍵。
- (void)onPaired:(NSDictionary *)ev {
  NSString *pskHex = [DBConfigUtil evStr:ev key:@"psk_hex"];
  id sids = [ev objectForKey:@"seeds"];
  NSArray *seeds = [sids isKindOfClass:[NSArray class]] ? sids : nil;
  NSString *js = [DBBootConfig persistPsk:pskHex seeds:seeds];
  if ([js length] > 0) {
    _boot.rawJson = js;  // 次回 load 用にメモリ側も更新
    NSLog(@"[doorbell] paired: boot.json に PSK/seeds を保存しました");
  }
  [self closePairingAnimated:YES];  // フィードバックは引導画面が自動で閉じることで伝える
}

@end

