#import "DBIncomingViewController.h"
#import "DBCoreBridge.h"
#import "DBBootConfig.h"
#import "DBTexts.h"
#import "DBConfigUtil.h"
#import "DBMjpegClient.h"
#import "DBMiniSip.h"

static const NSTimeInterval kAutoCloseS = 30;

@interface DBIncomingViewController () <DBMiniSipDelegate>
@end

@implementation DBIncomingViewController {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  NSString *_door;
  NSString *_purpose;
  NSString *_visitorLang;

  NSDictionary *_cfg;
  DBMjpegClient *_streamer;
  NSString *_incomingStreamUrl;
  NSString *_peerHost;
  int _directPort;
  NSString *_sipMode;   // "" | "monitor" | "answer"
  DBMiniSip *_sip;
  BOOL _inCall;
  NSTimer *_autoCloseTimer;

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

- (id)initWithCore:(DBCoreBridge *)core boot:(DBBootConfig *)boot door:(NSString *)door
           purpose:(NSString *)purpose visitorLang:(NSString *)visitorLang {
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    _core = [core retain];
    _boot = [boot retain];
    _texts = [[DBTexts alloc] init];
    _door = [door copy];
    _purpose = [purpose copy];
    _visitorLang = [visitorLang copy];
    _incomingStreamUrl = [@"" retain];
    _sipMode = [@"" retain];
    _directPort = 47190;
    _replyButtons = [[NSMutableArray alloc] init];
    self.modalPresentationStyle = UIModalPresentationFullScreen;
  }
  return self;
}

- (void)dealloc {
  [_autoCloseTimer invalidate];
  [_streamer stop];
  [_streamer release];
  [_sip release];
  [_core release];
  [_boot release];
  [_texts release];
  [_door release];
  [_purpose release];
  [_visitorLang release];
  [_cfg release];
  [_incomingStreamUrl release];
  [_peerHost release];
  [_sipMode release];
  [_replyButtons release];
  [_liveView release];
  [_noVideoLabel release];
  [_titleLabel release];
  [_purposeBadge release];
  [_langBadge release];
  [_statusLabel release];
  [_hintLabel release];
  [_replyStack release];
  [_answerButton release];
  [_monitorButton release];
  [_openButton release];
  [_ignoreButton release];
  [super dealloc];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1];
  NSDictionary *c = [[_core config] retain];
  [_cfg release];
  _cfg = c;
  [_texts setConfig:_cfg];
  [_texts setLang:_boot.uiLang];
  _directPort = (int)[DBConfigUtil intVal:_cfg path:@"sip.direct_port" def:47190];
  if (_boot.directPort > 0) _directPort = (int)_boot.directPort;
  [self buildUi];
  [self applyContent];

  // 門口機 peer 解決 (映像 URL + 直呼宛先 host)。boot.door_host 優先。
  NSDictionary *peer = [DBConfigUtil findDoorPeer:[_core status] door:_door];
  NSString *host = [_boot.doorHost length] > 0 ? _boot.doorHost : [DBConfigUtil peerHost:peer];
  [host retain];
  [_peerHost release];
  _peerHost = host;
  NSString *url = peer ? [DBConfigUtil str:peer path:@"stream"] : nil;
  [url retain];
  [_incomingStreamUrl release];
  _incomingStreamUrl = url ? url : [@"" retain];
  _answerButton.enabled = _peerHost != nil;
  _monitorButton.enabled = _peerHost != nil;
  [self startVideo:_incomingStreamUrl];

  DBIncomingViewController *__unsafe_unretained weakSelf = self;
  [_core addHandler:@"incoming" handler:^(NSDictionary *ev) { [weakSelf onUiEvent:ev]; }];
  [self restartAutoClose];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  [_core removeHandler:@"incoming"];
  [_autoCloseTimer invalidate];
  _autoCloseTimer = nil;
  [_streamer stop];
  if ([_sipMode length] > 0) {
    [_sip hangup];
    [_sipMode release];
    _sipMode = [@"" retain];
  }
}

- (void)refreshPurpose:(NSString *)purpose visitorLang:(NSString *)visitorLang {
  NSString *p = [purpose copy];
  [_purpose release];
  _purpose = p;
  NSString *v = [visitorLang copy];
  [_visitorLang release];
  _visitorLang = v;
  NSDictionary *c = [[_core config] retain];
  [_cfg release];
  _cfg = c;
  [self applyContent];
  if (!_inCall) [self restartAutoClose];
}

#pragma mark - UI

- (void)buildUi {
  _liveView = [[UIImageView alloc] init];
  _liveView.contentMode = UIViewContentModeScaleAspectFit;
  _liveView.backgroundColor = [UIColor blackColor];
  [self.view addSubview:_liveView];

  _noVideoLabel = [[UILabel alloc] init];
  _noVideoLabel.font = [UIFont systemFontOfSize:22];
  _noVideoLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
  _noVideoLabel.textAlignment = NSTextAlignmentCenter;
  [self.view addSubview:_noVideoLabel];

  _titleLabel = [[UILabel alloc] init];
  _titleLabel.font = [UIFont boldSystemFontOfSize:30];
  _titleLabel.textColor = [UIColor whiteColor];
  _titleLabel.adjustsFontSizeToFitWidth = YES;
  _titleLabel.minimumFontSize = 15;  // iOS5: minimumScaleFactor は 6+
  [self.view addSubview:_titleLabel];

  _purposeBadge = [[UILabel alloc] init];
  _purposeBadge.font = [UIFont boldSystemFontOfSize:20];
  _purposeBadge.textColor = [UIColor blackColor];
  _purposeBadge.backgroundColor = [UIColor colorWithRed:1.0 green:0.80 blue:0.25 alpha:1];
  _purposeBadge.textAlignment = NSTextAlignmentCenter;
  _purposeBadge.layer.cornerRadius = 8;
  _purposeBadge.clipsToBounds = YES;
  _purposeBadge.hidden = YES;
  [self.view addSubview:_purposeBadge];

  _langBadge = [[UILabel alloc] init];
  _langBadge.font = [UIFont boldSystemFontOfSize:20];
  _langBadge.textColor = [UIColor blackColor];
  _langBadge.backgroundColor = [UIColor colorWithRed:0.45 green:0.75 blue:1.0 alpha:1];
  _langBadge.textAlignment = NSTextAlignmentCenter;
  _langBadge.layer.cornerRadius = 8;
  _langBadge.clipsToBounds = YES;
  _langBadge.hidden = YES;
  [self.view addSubview:_langBadge];

  _statusLabel = [[UILabel alloc] init];
  _statusLabel.font = [UIFont systemFontOfSize:20];
  _statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
  [self.view addSubview:_statusLabel];

  _hintLabel = [[UILabel alloc] init];
  _hintLabel.font = [UIFont systemFontOfSize:20];
  _hintLabel.textColor = [UIColor colorWithRed:0.55 green:0.9 blue:0.55 alpha:1];
  _hintLabel.numberOfLines = 0;
  _hintLabel.hidden = YES;
  [self.view addSubview:_hintLabel];

  _replyStack = [[UIView alloc] init];
  [self.view addSubview:_replyStack];

  _answerButton = [[self makeButton:YES] retain];
  [_answerButton addTarget:self action:@selector(onAnswer) forControlEvents:UIControlEventTouchUpInside];
  _monitorButton = [[self makeButton:NO] retain];
  [_monitorButton addTarget:self action:@selector(onMonitor) forControlEvents:UIControlEventTouchUpInside];
  _openButton = [[self makeButton:NO] retain];
  [_openButton addTarget:self action:@selector(onOpenDoor) forControlEvents:UIControlEventTouchUpInside];
  _openButton.enabled = NO;
  _ignoreButton = [[self makeButton:NO] retain];
  [_ignoreButton addTarget:self action:@selector(onIgnore) forControlEvents:UIControlEventTouchUpInside];

  // iOS5: 背景色未指定の UILabel が不透明白で描画される個体対策 (バッジは温存)。
  [self clearLabelBackgrounds:self.view];
}

- (void)clearLabelBackgrounds:(UIView *)v {
  for (UIView *sub in v.subviews) {
    if ([sub isKindOfClass:[UILabel class]] && sub != _purposeBadge && sub != _langBadge)
      sub.backgroundColor = [UIColor clearColor];
    [self clearLabelBackgrounds:sub];
  }
}

- (UIButton *)makeButton:(BOOL)prominent {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
  b.titleLabel.font = [UIFont boldSystemFontOfSize:22];
  b.titleLabel.adjustsFontSizeToFitWidth = YES;
  b.titleLabel.minimumFontSize = 13;  // iOS5: minimumScaleFactor は 6+
  [b setTitleColor:(prominent ? [UIColor blackColor] : [UIColor whiteColor]) forState:UIControlStateNormal];
  b.backgroundColor = prominent ? [UIColor colorWithRed:0.35 green:0.78 blue:0.42 alpha:1]
                                : [UIColor colorWithWhite:1 alpha:0.14];
  b.layer.cornerRadius = 12;
  [self.view addSubview:b];
  return b;
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGSize sz = self.view.bounds.size;
  BOOL portrait = sz.height > sz.width;
  CGFloat m = 24;
  // バッジ列
  _titleLabel.frame = CGRectMake(m, 18, sz.width - 2 * m - 220, 40);
  _purposeBadge.frame = CGRectMake(sz.width - m - 220, 18, 130, 40);
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
  _statusLabel.frame = CGRectMake(rightX, y, rightW, 28);
  y += 36;
  // reply ボタン群
  _replyStack.frame = CGRectMake(rightX, y, rightW, 0);
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
  _answerButton.frame  = CGRectMake(rightX + 0 * (bw + gap), bottom, bw, rowH);
  _monitorButton.frame = CGRectMake(rightX + 1 * (bw + gap), bottom, bw, rowH);
  _openButton.frame    = CGRectMake(rightX + 2 * (bw + gap), bottom, bw, rowH);
  _ignoreButton.frame  = CGRectMake(rightX + 3 * (bw + gap), bottom, bw, rowH);
}

- (void)applyContent {
  NSDictionary *doorEntry = [DBConfigUtil dig:_cfg path:[NSString stringWithFormat:@"doors.%@", _door]];
  NSString *label = [DBConfigUtil labelOf:doorEntry lang:_boot.uiLang fallback:_door];
  _titleLabel.text = [_texts t:@"ring.incoming", label, nil];
  _noVideoLabel.text = [_texts ts:@"ring.no_video"];
  _statusLabel.text = [_texts ts:@"reply.choose"];
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
    NSDictionary *entry = [DBConfigUtil dig:_cfg path:[NSString stringWithFormat:@"visit_purposes.%@", _purpose]];
    NSString *label = [DBConfigUtil labelOf:entry lang:_boot.uiLang fallback:_purpose];
    NSString *icon = [entry objectForKey:@"icon"];
    if (![icon isKindOfClass:[NSString class]]) icon = @"";
    _purposeBadge.text = [icon length] == 0 ? label : [NSString stringWithFormat:@" %@ %@ ", icon, label];
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
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:[DBConfigUtil labelOf:entry lang:lang fallback:rid] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:22];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumFontSize = 13;  // iOS5: minimumScaleFactor は 6+
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    b.layer.cornerRadius = 12;
    b.accessibilityIdentifier = rid;
    [b addTarget:self action:@selector(onReply:) forControlEvents:UIControlEventTouchUpInside];
    [_replyStack addSubview:b];
    [_replyButtons addObject:b];
  }
  [self.view setNeedsLayout];
}

#pragma mark - 映像

- (void)startVideo:(NSString *)url {
  [_streamer stop];
  [_streamer release];
  _streamer = nil;
  _noVideoLabel.hidden = NO;
  _liveView.image = nil;
  if ([url length] == 0) return;
  DBIncomingViewController *__unsafe_unretained weakSelf = self;
  _streamer = [[DBMjpegClient alloc] initWithUrlString:url onFrame:^(UIImage *img) {
    weakSelf->_noVideoLabel.hidden = YES;
    weakSelf->_liveView.image = img;
  }];
  [_streamer start];
}

#pragma mark - タイマ

- (void)restartAutoClose {
  [_autoCloseTimer invalidate];
  _autoCloseTimer = [NSTimer scheduledTimerWithTimeInterval:kAutoCloseS target:self
                                                   selector:@selector(closeSelf)
                                                   userInfo:nil repeats:NO];
}

- (void)closeSelf {
  [_autoCloseTimer invalidate];
  _autoCloseTimer = nil;
  [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - 操作

- (void)onAnswer {
  if (_peerHost == nil) return;
  if (_inCall) {  // 「終了」
    [_sip hangup];
    [_sipMode release];
    _sipMode = [@"" retain];
    [self closeSelf];
    return;
  }
  _answerButton.enabled = NO;   // 二重発呼防止
  [_autoCloseTimer invalidate]; // 応答操作中は自動クローズしない
  if ([_sipMode isEqualToString:@"monitor"]) {
    [_sip hangup];
    [_sip release];
    _sip = nil;
    [self performSelector:@selector(placeAnswerCall) withObject:nil afterDelay:0.4];
    return;
  }
  [self placeAnswerCall];
}

- (void)placeAnswerCall {
  [_sipMode release];
  _sipMode = [@"answer" retain];
  [self startSip:@"answer"];
}

- (void)onMonitor {
  if (_peerHost == nil || [_sipMode length] > 0) return;
  [_sipMode release];
  _sipMode = [@"monitor" retain];
  [self startSip:@"monitor"];
  _hintLabel.text = [_texts ts:@"ring.monitoring"];
  _hintLabel.hidden = NO;
}

- (void)startSip:(NSString *)mode {
  [_sip release];
  _sip = [[DBMiniSip alloc] initWithHost:_peerHost port:_directPort mode:mode
                              micEnabled:_boot.micEnabled];
  _sip.delegate = self;
  [_sip start];
  _openButton.enabled = YES;
}

- (void)onOpenDoor {
  [_sip sendDtmf:@"*1"];  // 開錠 (門口機の dtmf_actions で *1 = 開門)
  _hintLabel.text = [_texts ts:@"ring.open_door"];
  _hintLabel.hidden = NO;
}

- (void)onIgnore {
  [self closeSelf];
}

- (void)onReply:(UIButton *)sender {
  NSString *rid = sender.accessibilityIdentifier;
  [_core quickReply:rid door:_door];
  _hintLabel.text = [_texts t:@"reply.sent", (sender.currentTitle ? sender.currentTitle : @""), nil];
  _hintLabel.hidden = NO;
  if (!_inCall) [self restartAutoClose];
}

#pragma mark - ミニ SIP delegate (main スレッド)

- (void)miniSipStateChanged:(DBMiniSipState)state {
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

#pragma mark - core イベント (main スレッド)

- (void)onUiEvent:(NSDictionary *)ev {
  NSString *t = [DBConfigUtil evStr:ev key:@"t"];
  if ([t isEqualToString:@"reply"]) {
    if (!_inCall) [self closeSelf];
  } else if ([t isEqualToString:@"visitor_lang"]) {
    NSString *d = [DBConfigUtil evStr:ev key:@"door"];
    if ([d length] == 0 || [d isEqualToString:_door]) {
      NSString *lang = [DBConfigUtil evStr:ev key:@"lang"];
      [lang retain];
      [_visitorLang release];
      _visitorLang = lang;
      [self updateBadges];
      [self buildReplyButtons];
    }
  } else if ([t isEqualToString:@"emergency"]) {
    if ([DBConfigUtil evBool:ev key:@"active"]) [self closeSelf];
  }
}

@end
