#import "DBIncomingScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBTexts.h"
#import "../Media/DBH264Player.h"
#import "../Net/DBMjpegClient.h"
#import "../Support/DBAppDelegate.h"
#import "DBRouter.h"

static const NSTimeInterval kAutoCloseS = 30;
static const NSTimeInterval kCancelledCloseS = 15;

@implementation DBIncomingScreen {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  NSString *_door;
  NSString *_purpose;
  NSString *_visitorLang;

  NSDictionary *_cfg;
  DBMjpegClient *_streamer;
  DBH264Player *_h264;         // H.264 fMP4 (/stream.mp4) 再生 — 成功時はこちら優先
  NSString *_incomingStreamUrl;
  NSString *_incomingStreamMp4Url;
  NSString *_peerHost;
  NSInteger _directPort;
  NSString *_sipMode;  // "" | "monitor" | "answer"
  BOOL _inCall;
  BOOL _cancelled;
  NSTimer *_autoCloseTimer;
  NSInteger _snapshotGen;  // 背景収集の世代 (古い結果破棄)

  // UI
  UIImageView *_liveView;
  UILabel *_noVideoLabel;
  UILabel *_titleLabel;
  UILabel *_purposeBadge;
  UILabel *_langBadge;
  UILabel *_statusLabel;
  UILabel *_hintLabel;
  UIView *_replyStack;
  NSMutableArray *_replyButtons;
  UIButton *_answerButton;
  UIButton *_monitorButton;
  UIButton *_openButton;
  UIButton *_ignoreButton;
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _router = router;
    _core = router.core;
    _boot = router.boot;
    _texts = router.texts;
    _door = @"";
    _purpose = @"";
    _visitorLang = @"";
    _incomingStreamUrl = @"";
    _incomingStreamMp4Url = @"";
    _sipMode = @"";
    _directPort = 47190;
    _replyButtons = [[NSMutableArray alloc] init];
    [self buildUi];
  }
  return self;
}

- (NSString *)screenName {
  return @"incoming";
}

#pragma mark - UI

- (UIButton *)makeButton:(BOOL)primary {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];  // iOS5: System は白背景回避
  b.titleLabel.font = [UIFont boldSystemFontOfSize:22];
  b.titleLabel.adjustsFontSizeToFitWidth = YES;
  b.titleLabel.minimumFontSize = 13;  // iOS5: minimumScaleFactor は 6+
  [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  b.backgroundColor = primary ? [UIColor colorWithRed:0.13 green:0.55 blue:0.28 alpha:1]
                              : [UIColor colorWithWhite:1 alpha:0.12];
  b.layer.cornerRadius = 12;
  [b setBackgroundImage:nil forState:UIControlStateNormal];
  return b;
}

- (void)buildUi {
  self.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1];

  _liveView = [[UIImageView alloc] init];
  _liveView.contentMode = UIViewContentModeScaleAspectFit;
  _liveView.backgroundColor = [UIColor blackColor];
  [self addSubview:_liveView];

  _noVideoLabel = [[UILabel alloc] init];
  _noVideoLabel.font = [UIFont systemFontOfSize:22];
  _noVideoLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
  _noVideoLabel.textAlignment = NSTextAlignmentCenter;
  [self addSubview:_noVideoLabel];

  _titleLabel = [[UILabel alloc] init];
  _titleLabel.font = [UIFont boldSystemFontOfSize:30];
  _titleLabel.textColor = [UIColor whiteColor];
  _titleLabel.adjustsFontSizeToFitWidth = YES;
  _titleLabel.minimumFontSize = 15;  // iOS5: minimumScaleFactor は 6+
  [self addSubview:_titleLabel];

  _purposeBadge = [[UILabel alloc] init];
  _purposeBadge.font = [UIFont boldSystemFontOfSize:20];
  _purposeBadge.textColor = [UIColor blackColor];
  _purposeBadge.backgroundColor = [UIColor colorWithRed:1.0 green:0.80 blue:0.25 alpha:1];
  _purposeBadge.textAlignment = NSTextAlignmentCenter;
  _purposeBadge.layer.cornerRadius = 8;
  _purposeBadge.clipsToBounds = YES;
  _purposeBadge.hidden = YES;
  [self addSubview:_purposeBadge];

  _langBadge = [[UILabel alloc] init];
  _langBadge.font = [UIFont boldSystemFontOfSize:20];
  _langBadge.textColor = [UIColor blackColor];
  _langBadge.backgroundColor = [UIColor colorWithRed:0.45 green:0.75 blue:1.0 alpha:1];
  _langBadge.textAlignment = NSTextAlignmentCenter;
  _langBadge.layer.cornerRadius = 8;
  _langBadge.clipsToBounds = YES;
  _langBadge.hidden = YES;
  [self addSubview:_langBadge];

  _statusLabel = [[UILabel alloc] init];
  _statusLabel.font = [UIFont systemFontOfSize:20];
  _statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
  [self addSubview:_statusLabel];

  _hintLabel = [[UILabel alloc] init];
  _hintLabel.font = [UIFont systemFontOfSize:20];
  _hintLabel.textColor = [UIColor colorWithRed:0.55 green:0.9 blue:0.55 alpha:1];
  _hintLabel.numberOfLines = 0;
  _hintLabel.hidden = YES;
  [self addSubview:_hintLabel];

  _replyStack = [[UIView alloc] init];
  [self addSubview:_replyStack];

  _answerButton = [self makeButton:YES];
  [_answerButton addTarget:self action:@selector(onAnswer) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_answerButton];

  _monitorButton = [self makeButton:NO];
  [_monitorButton addTarget:self action:@selector(onMonitor)
           forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_monitorButton];

  _openButton = [self makeButton:NO];
  [_openButton addTarget:self action:@selector(onOpenDoor)
        forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_openButton];

  _ignoreButton = [self makeButton:NO];
  [_ignoreButton addTarget:self action:@selector(onIgnore)
          forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_ignoreButton];

  [self clearLabelBackgrounds:self];
}
#pragma mark - 準備 / 表示内容

- (void)prepareWithDoor:(NSString *)door purpose:(NSString *)purpose lang:(NSString *)lang {
  _door = [door copy];
  _purpose = [purpose copy];
  _visitorLang = [lang copy];
  _inCall = NO;
  _cancelled = NO;
  _statusLabel.font = [UIFont systemFontOfSize:20];
  _statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
  _statusLabel.backgroundColor = [UIColor clearColor];
  _statusLabel.textAlignment = NSTextAlignmentLeft;
  _statusLabel.layer.cornerRadius = 0;
  _peerHost = nil;
  _incomingStreamUrl = @"";
  _incomingStreamMp4Url = @"";
  _answerButton.enabled = NO;
  _monitorButton.enabled = NO;
  _noVideoLabel.hidden = NO;
  _liveView.image = nil;
  [self startVideo:nil];  // 前のストリーム停止
  // 最後に取得成功した config があれば即時表示 (来鈴直後でも返信ボタンが出る)。
  NSDictionary *cached = [_core lastConfig];
  if (cached) {
    _cfg = cached;
    [_texts setConfig:_cfg];
    [_texts setLang:_boot.uiLang];
  }
  [self applyContent];
  [self restartAutoClose];
  [self fetchAndApplyCoreSnapshot];
}

- (void)refreshPurpose:(NSString *)purpose lang:(NSString *)lang {
  _purpose = [purpose copy];
  _visitorLang = [lang copy];
  [self applyContent];
  if (!_inCall) [self restartAutoClose];
  [self fetchAndApplyCoreSnapshot];
}

// core JSON は main で取らない。背景収集 → main で peer 解決と反映。
- (void)fetchAndApplyCoreSnapshot {
  NSInteger gen = ++_snapshotGen;
  DBCoreBridge *core = _core;
  __weak DBIncomingScreen *wself = self;
  NSLog(@"[doorbell][DBG] incoming: fetch start gen=%ld", (long)gen);
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *cfg = [core config];
    NSDictionary *st = [core status];
    NSLog(@"[doorbell][DBG] incoming: fetch done gen=%ld cfg=%@ st=%@",
          (long)gen, cfg ? @"ok" : @"nil", st ? @"ok" : @"nil");
    dispatch_async(dispatch_get_main_queue(), ^{
      DBIncomingScreen *s = wself;
      if (!s || s->_snapshotGen != gen || !s.superview) {
        NSLog(@"[doorbell][DBG] incoming: fetch DISCARDED (gen/superview)");
        return;
      }
      s->_cfg = cfg;
      [s->_texts setConfig:cfg];
      [s->_texts setLang:s->_boot.uiLang];
      s->_directPort = [DBConfigUtil intVal:cfg path:@"sip.direct_port" def:47190];
      if (s->_boot.directPort > 0) s->_directPort = s->_boot.directPort;

      // 門口機 peer 解決 (映像 URL + 直呼宛先 host)。boot.door_host 優先。
      NSDictionary *peer = [DBConfigUtil findDoorPeer:st door:s->_door];
      s->_peerHost = ([s->_boot.doorHost length] > 0)
                         ? s->_boot.doorHost
                         : [DBConfigUtil peerHost:peer];
      NSString *url = peer ? [DBConfigUtil str:peer path:@"stream"] : nil;
      s->_incomingStreamUrl = url ?: @"";
      NSString *mp4 = peer ? [DBConfigUtil str:peer path:@"stream_mp4"] : nil;
      s->_incomingStreamMp4Url = mp4 ?: @"";
      NSDictionary *replies = [DBConfigUtil dig:cfg path:@"quick_replies"];
      NSLog(@"[doorbell][DBG] incoming: peer=%@ stream=%@ replies=%lu",
            s->_peerHost ?: @"-", s->_incomingStreamUrl,
            (unsigned long)[replies count]);
      s->_answerButton.enabled = (s->_peerHost != nil);
      s->_monitorButton.enabled = (s->_peerHost != nil);
      [s startVideo:s->_incomingStreamUrl];
      [s applyContent];
      [s restartAutoClose];
    });
  });
}

- (void)applyContent {
  NSDictionary *doorEntry = [DBConfigUtil dig:_cfg path:[NSString stringWithFormat:@"doors.%@", _door]];
  NSString *label = [DBConfigUtil labelOf:doorEntry lang:_boot.uiLang fallback:_door];
  _titleLabel.text = [_texts t:@"ring.incoming", label, nil];
  _noVideoLabel.text = [_texts ts:@"ring.no_video"];
  _statusLabel.text = [_texts ts:(_cancelled ? @"ring.cancelled" : @"reply.choose")];
  [_answerButton setTitle:(_inCall ? [_texts ts:@"incall.end"] : [_texts ts:@"ring.answer"])
                 forState:UIControlStateNormal];
  [_monitorButton setTitle:[_texts ts:@"ring.monitor"] forState:UIControlStateNormal];
  [_openButton setTitle:[_texts ts:@"ring.open_door"] forState:UIControlStateNormal];
  [_ignoreButton setTitle:[_texts ts:@"ring.ignore"] forState:UIControlStateNormal];
  [self updateBadges];
  [self buildReplyButtons];
}

- (void)updateBadges {
  if ([_purpose length] == 0) {
    _purposeBadge.hidden = YES;
  } else {
    NSDictionary *entry =
        [DBConfigUtil dig:_cfg path:[NSString stringWithFormat:@"visit_purposes.%@", _purpose]];
    NSString *label = [DBConfigUtil labelOf:entry lang:_boot.uiLang fallback:_purpose];
    NSString *icon = [entry objectForKey:@"icon"];
    if (![icon isKindOfClass:[NSString class]]) icon = @"";
    NSString *purposeText = [_texts t:@"ring.purpose_badge", label, nil];
    _purposeBadge.text = [icon length] == 0
                             ? purposeText
                             : [NSString stringWithFormat:@" %@  %@ ", icon, purposeText];
    _purposeBadge.backgroundColor = [UIColor colorWithRed:1.0 green:0.80 blue:0.25 alpha:1];
    _purposeBadge.hidden = NO;
  }
  if ([_visitorLang length] == 0 || [_visitorLang isEqualToString:@"ja"]) {
    _langBadge.hidden = YES;
  } else {
    _langBadge.text = [NSString stringWithFormat:@" 🌐 %@ ", [_visitorLang uppercaseString]];
    _langBadge.hidden = NO;
  }
}

- (void)buildReplyButtons {
  for (UIButton *b in _replyButtons) [b removeFromSuperview];
  [_replyButtons removeAllObjects];
  NSDictionary *replies = [DBConfigUtil dig:_cfg path:@"quick_replies"];
  if (![replies isKindOfClass:[NSDictionary class]] || [replies count] == 0) return;
  NSString *lang = [_visitorLang length] == 0 ? @"ja" : _visitorLang;
  for (NSString *rid in [DBConfigUtil sortedByOrder:replies]) {
    NSDictionary *entry = [replies objectForKey:rid];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];  // iOS5: System=白背景回避
    [b setTitle:[DBConfigUtil labelOf:entry lang:lang fallback:rid] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:22];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumFontSize = 13;
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    b.layer.cornerRadius = 12;
    b.accessibilityIdentifier = rid;
    [b addTarget:self action:@selector(onReply:) forControlEvents:UIControlEventTouchUpInside];
    [_replyStack addSubview:b];
    [_replyButtons addObject:b];
  }
  [self setNeedsLayout];
}

#pragma mark - 映像

/* 二股方式 (実機検証に基づく):
 *  - MJPEG を**即時**開始 (A5 の软件解码だが 8fps なら軽い — ユーザは即座に映像が見える)
 *  - 同時に H.264 (/stream.mp4 → ローカル HLS → HW デコード) を立上げ
 *  - H.264 が PLAYING になったら MJPEG を止めて切替 (HW 解码で滑らか+省電力)
 *  - H.264 失敗時は MJPEG 継続 (黒画面にはならない) */
- (void)startVideo:(NSString *)mjpegUrl {
  [self stopVideoPlayers];
  _noVideoLabel.hidden = NO;
  _liveView.image = nil;
  NSLog(@"[doorbell][DBG] incoming: startVideo mp4=%@ mjpeg=%@",
        _incomingStreamMp4Url, mjpegUrl ?: @"(null)");

  /* 1) MJPEG 即時開始 (H.264 の準備中の表示) */
  [self startMjpegOnly:mjpegUrl];

  /* 2) H.264 を後追いで立上げ (就緒したら切替) */
  if ([_incomingStreamMp4Url length] > 0) {
    __weak DBIncomingScreen *wself = self;
    _h264 = [[DBH264Player alloc] initWithURL:_incomingStreamMp4Url
                                    container:_liveView
                                      onState:^(DBH264PlayerState st) {
      DBIncomingScreen *s = wself;
      if (!s || !s.superview) return;
      if (st == DBH264PlayerPlaying) {
        /* HW 解码に切替 — MJPEG は停止 (受信停止のみ, 画像は player が覆う) */
        [s->_streamer stop];
        s->_streamer = nil;
        s->_noVideoLabel.hidden = YES;
        NSLog(@"[doorbell] incoming: switched to H.264 live");
      } else if (st == DBH264PlayerFailed) {
        /* MJPEG 継続 (既に動いている) — H.264 view だけ下ろす */
        [s->_h264 stop];
        s->_h264 = nil;
        NSLog(@"[doorbell] incoming: H.264 NG → MJPEG 継続");
        if (!s->_streamer) [s startMjpegOnly:s->_incomingStreamUrl];
        if (!s->_streamer) s->_noVideoLabel.hidden = NO;
      }
    }];
    [_h264 start];
  }
}

/* MJPEG のみ開始 (H.264 非対応 door / H.264 失敗後の再開)。
 * 既に動いている冪等呼びは何もしない。 */
- (void)startMjpegOnly:(NSString *)url {
  if (_streamer) return;
  if ([url length] == 0) return;
  __weak DBIncomingScreen *wself = self;
  _streamer = [[DBMjpegClient alloc] initWithURLString:url
                                              onFrame:^(UIImage *img) {
    // main スレッド。すでに解码済みなので blit のみ (重くない)。
    DBIncomingScreen *s = wself;
    if (!s) return;
    s->_noVideoLabel.hidden = YES;
    s->_liveView.image = img;
  }];
  [_streamer start];
}

- (void)stopVideoPlayers {
  [_streamer stop];
  _streamer = nil;
  [_h264 stop];
  _h264 = nil;
}

#pragma mark - タイマ

- (void)restartAutoClose {
  [_autoCloseTimer invalidate];
  _autoCloseTimer =
      [NSTimer scheduledTimerWithTimeInterval:(_cancelled ? kCancelledCloseS : kAutoCloseS)
                                       target:self
                                     selector:@selector(closeSelf)
                                     userInfo:nil repeats:NO];
}

- (void)handleCallCancelled:(NSDictionary *)ev {
  NSString *door = [DBConfigUtil evStr:ev key:@"door"];
  if ([door length] > 0 && [_door length] > 0 && ![door isEqualToString:_door]) return;
  if (_inCall) return;
  _cancelled = YES;
  _statusLabel.text = [_texts ts:@"ring.cancelled"];
  _statusLabel.font = [UIFont boldSystemFontOfSize:24];
  _statusLabel.textColor = [UIColor whiteColor];
  _statusLabel.backgroundColor = [UIColor colorWithRed:0.78 green:0.14 blue:0.12 alpha:1];
  _statusLabel.textAlignment = NSTextAlignmentCenter;
  _statusLabel.layer.cornerRadius = 8;
  _statusLabel.clipsToBounds = YES;
  [self setNeedsLayout];
  [self restartAutoClose];
  NSLog(@"[doorbell] call cancelled: chime stopped; incoming remains for %.0fs",
        kCancelledCloseS);
}

- (void)handlePurposeSelected:(NSDictionary *)ev {
  NSString *door = [DBConfigUtil evStr:ev key:@"door"];
  if ([door length] > 0 && [_door length] > 0 && ![door isEqualToString:_door]) return;
  NSString *purpose = [DBConfigUtil evStr:ev key:@"purpose"];
  if ([purpose length] == 0) return;
  _purpose = [purpose copy];
  [self updateBadges];
  [self setNeedsLayout];
}

- (void)closeSelf {
  [_autoCloseTimer invalidate];
  _autoCloseTimer = nil;
  [_router closeIncomingAnimated:YES];
}

- (void)onScreenWillAppear {
  // 黒画面/表示異常の調査: 来鈴画面が出て 4 秒後の実体を Documents に吐く
  __weak DBIncomingScreen *wself = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    DBIncomingScreen *s = wself;
    if (s && s.superview) {
      DBAppDelegate *ad = (DBAppDelegate *)[UIApplication sharedApplication].delegate;
      [ad diagDump];
    }
  });
}

- (void)onScreenWillDisappear {
  [_autoCloseTimer invalidate];
  _autoCloseTimer = nil;
  [self stopVideoPlayers];
  if ([_sipMode length] > 0) {
    [_router sipHangup];
    _sipMode = @"";
    _inCall = NO;
  }
}
#pragma mark - 操作

- (void)onAnswer {
  if (_peerHost == nil) return;
  if (_inCall) {  // 「終了」
    [_router sipHangup];
    _sipMode = @"";
    [self closeSelf];
    return;
  }
  _answerButton.enabled = NO;   // 二重発呼防止
  [_autoCloseTimer invalidate]; // 応答操作中は自動クローズしない
  if ([_sipMode isEqualToString:@"monitor"]) {
    // 監聴 → 応答への切替: 旧セッション停止を待ってから新発呼 (AudioUnit 入替の競合回避)
    [_router sipHangup];
    _sipMode = @"";
    __weak DBIncomingScreen *wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      [wself placeAnswerCall];
    });
    return;
  }
  [self placeAnswerCall];
}

- (void)placeAnswerCall {
  _sipMode = @"answer";
  [self startSip:@"answer"];
}

- (void)onMonitor {
  if (_peerHost == nil || [_sipMode length] > 0) return;
  _sipMode = @"monitor";
  [self startSip:@"monitor"];
  _hintLabel.text = [_texts ts:@"ring.monitoring"];
  _hintLabel.hidden = NO;
}

- (void)startSip:(NSString *)mode {
  // セッション所有は router。画面は自分の表示状態を渡すだけ。
  [_router sipStart:_peerHost port:(int)_directPort mode:mode];
  _openButton.enabled = YES;
}

- (void)onOpenDoor {
  [_router sipSendDtmf:@"*1"];  // 開錠 (門口機の dtmf_actions で *1 = 開門)
  _hintLabel.text = [_texts ts:@"ring.open_door"];
  _hintLabel.hidden = NO;
}

- (void)onIgnore {
  [self closeSelf];
}

- (void)onReply:(UIButton *)sender {
  NSString *rid = sender.accessibilityIdentifier;
  [_core quickReply:rid door:_door];
  _hintLabel.text = [_texts t:@"reply.sent", (sender.currentTitle ?: @""), nil];
  _hintLabel.hidden = NO;
  if (!_inCall) [self restartAutoClose];
}

#pragma mark - SIP 状態 / core イベント

- (void)sipStateChanged:(DBMiniSipState)state {
  if (!self.superview) return;  // 画面外の後着状態は無視
  if (state == DBMiniSipInCall) {
    if (![_sipMode isEqualToString:@"answer"]) return;  // monitor は来鈴画面のまま
    _inCall = YES;
    [_autoCloseTimer invalidate];
    _answerButton.enabled = YES;
    [_answerButton setTitle:[_texts ts:@"incall.end"] forState:UIControlStateNormal];
    _statusLabel.text = [_texts ts:@"incall.title"];
    _hintLabel.hidden = YES;
  } else if (state == DBMiniSipEnded) {
    BOOL wasAnswer = [_sipMode isEqualToString:@"answer"];
    _inCall = NO;
    if (wasAnswer) [self closeSelf];
  }
}

- (void)handleReplyEvent:(NSDictionary *)ev {
  // 面板へ返信が届いた (visitor 側で返信処理済み) → 応答中表示中は閉じない
  if (!_inCall) [self closeSelf];
}

- (void)handleVisitorLangEvent:(NSDictionary *)ev {
  NSString *d = [DBConfigUtil evStr:ev key:@"door"];
  if ([d length] == 0 || [d isEqualToString:_door]) {
    _visitorLang = [DBConfigUtil evStr:ev key:@"lang"];
    [self updateBadges];
    [self buildReplyButtons];
  }
}

#pragma mark - layout

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize sz = self.bounds.size;
  BOOL portrait = sz.height > sz.width;
  CGFloat m = 24;
  // バッジ列
  _titleLabel.frame = CGRectMake(m, 18, sz.width - 2 * m - 310, 40);
  _purposeBadge.frame = CGRectMake(sz.width - m - 310, 18, 220, 40);
  _langBadge.frame = CGRectMake(sz.width - m - 80, 18, 80, 40);

  CGFloat topY = 72;
  CGFloat videoW, videoH, rightX, rightY, rightW;
  if (portrait) {
    videoW = sz.width - 2 * m;
    videoH = sz.height * 0.38;
    _liveView.frame = CGRectMake(m, topY, videoW, videoH);
    rightX = m;
    rightY = topY + videoH + 16;
    rightW = sz.width - 2 * m;
  } else {
    videoW = sz.width * 0.58;
    videoH = sz.height - topY - 18;
    _liveView.frame = CGRectMake(m, topY, videoW, videoH);
    rightX = m + videoW + m;
    rightY = topY;
    rightW = sz.width - rightX - m;
  }
  _noVideoLabel.frame = _liveView.frame;

  CGFloat y = rightY;
  CGFloat statusH = _cancelled ? 52 : 28;
  _statusLabel.frame = CGRectMake(rightX, y, rightW, statusH);
  y += statusH + 8;
  // reply ボタン群
  CGFloat ry = 0;
  for (UIButton *b in _replyButtons) {
    b.frame = CGRectMake(0, ry, rightW, 56);
    ry += 56 + 12;
  }
  _replyStack.frame = CGRectMake(rightX, y, rightW, ry);
  y += ry + 4;
  _hintLabel.frame = CGRectMake(rightX, y, rightW, 50);

  // 操作行 (下部): 応答 / 聞く / 開錠 / 無視
  CGFloat rowH = 60, gap = 12;
  CGFloat bottom = sz.height - 18 - rowH;
  CGFloat bw = (rightW - 3 * gap) / 4;
  _answerButton.frame = CGRectMake(rightX + 0 * (bw + gap), bottom, bw, rowH);
  _monitorButton.frame = CGRectMake(rightX + 1 * (bw + gap), bottom, bw, rowH);
  _openButton.frame = CGRectMake(rightX + 2 * (bw + gap), bottom, bw, rowH);
  _ignoreButton.frame = CGRectMake(rightX + 3 * (bw + gap), bottom, bw, rowH);
}

@end
