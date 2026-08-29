#import "DBHomeScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBTexts.h"
#import "../Media/DBSiren.h"
#import "DBRouter.h"
#import <AudioToolbox/AudioToolbox.h>

static UIColor *DBBg(void) { return [UIColor colorWithRed:0.063 green:0.078 blue:0.094 alpha:1]; }
static UIColor *DBFg(void) { return [UIColor colorWithWhite:0.94 alpha:1]; }
static UIColor *DBDim(void) { return [UIColor colorWithWhite:0.62 alpha:1]; }
static UIColor *DBNightClk(void) { return [UIColor colorWithRed:0.545 green:0.141 blue:0.110 alpha:1]; }

@implementation DBHomeScreen {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  DBSiren *_audio;

  NSDictionary *_cfg;
  NSString *_nodeId;
  NSString *_panelToken;
  NSString *_themeHash;
  NSMutableArray *_events;  // 直近イベント文字列 (最大 8)

  // 表示制御
  NSInteger _brightness;
  BOOL _night;
  BOOL _redTint;

  // SOS
  BOOL _emergencyActive;
  double _sosHoldS;
  BOOL _cancelRequiresPin;
  NSDate *_sosDownAt;
  BOOL _sosHolding;
  NSTimer *_sosTimer;

  NSTimer *_clockTimer;
  NSTimer *_replyTimer;

  // 隠し管理入口
  NSInteger _secretTaps;
  NSDate *_secretFirst;

  // core スナップショットの非同期収集 (main を塞がない)
  dispatch_queue_t _refreshQueue;
  BOOL _refreshBusy;   // _refreshQueue 実行中
  BOOL _refreshDirty;  // 実行中に再要求が来た

  // UI
  UIImageView *_themeBg;
  UILabel *_clockLabel;
  UILabel *_dateLabel;
  UILabel *_statusLabel;
  UILabel *_eventsLabel;
  UILabel *_nodeInfo;
  UIButton *_sosButton;
  UIProgressView *_sosProgress;
  UIView *_nightTint;
  UIView *_replyBanner;
  UILabel *_replyCaption;
  UILabel *_replyText;
  UIView *_offlineView;
  UILabel *_offlineTitle;
  UILabel *_offlineBody;
  UIView *_emergencyView;
  UILabel *_emergencyTitle;
  UILabel *_emergencyNote;
  UIButton *_emergencyCancel;
  UIButton *_secretCorner;
  UIButton *_infoButton;
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _router = router;
    _core = router.core;
    _boot = router.boot;
    _texts = router.texts;
    _audio = [[DBSiren alloc] init];
    _events = [[NSMutableArray alloc] init];
    _nodeId = @"";
    _panelToken = @"";
    _brightness = 70;
    _sosHoldS = 3.0;
    _cancelRequiresPin = YES;
    _sosDownAt = [NSDate distantPast];
    _secretFirst = [NSDate distantPast];
    _refreshQueue = dispatch_queue_create("doorbell.home.refresh", DISPATCH_QUEUE_SERIAL);
    [self buildUi];
  }
  return self;
}

- (NSString *)screenName {
  return @"home";
}
#pragma mark - UI 構築

- (UIButton *)buttonWithTitle:(NSString *)title font:(CGFloat)size
                        color:(UIColor *)color bg:(UIColor *)bg {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];  // iOS5: System は白背景回避
  [b setTitle:title forState:UIControlStateNormal];
  b.titleLabel.font = [UIFont boldSystemFontOfSize:size];
  [b setTitleColor:color forState:UIControlStateNormal];
  b.backgroundColor = bg;
  return b;
}

- (void)buildUi {
  self.backgroundColor = DBBg();

  _themeBg = [[UIImageView alloc] init];
  _themeBg.contentMode = UIViewContentModeScaleAspectFill;
  _themeBg.clipsToBounds = YES;
  _themeBg.hidden = YES;
  [self addSubview:_themeBg];

  _clockLabel = [[UILabel alloc] init];
  _clockLabel.font = [UIFont systemFontOfSize:84];
  _clockLabel.textColor = DBFg();
  _clockLabel.textAlignment = NSTextAlignmentCenter;
  [self addSubview:_clockLabel];

  _dateLabel = [[UILabel alloc] init];
  _dateLabel.font = [UIFont systemFontOfSize:24];
  _dateLabel.textColor = DBDim();
  _dateLabel.textAlignment = NSTextAlignmentCenter;
  [self addSubview:_dateLabel];

  _statusLabel = [[UILabel alloc] init];
  _statusLabel.font = [UIFont systemFontOfSize:20];
  _statusLabel.textColor = DBDim();
  _statusLabel.textAlignment = NSTextAlignmentCenter;
  [self addSubview:_statusLabel];

  _eventsLabel = [[UILabel alloc] init];
  _eventsLabel.font = [UIFont systemFontOfSize:17];
  _eventsLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
  _eventsLabel.textAlignment = NSTextAlignmentCenter;
  _eventsLabel.numberOfLines = 0;
  [self addSubview:_eventsLabel];

  _nodeInfo = [[UILabel alloc] init];
  _nodeInfo.font = [UIFont systemFontOfSize:14];
  _nodeInfo.textColor = [UIColor colorWithWhite:1 alpha:0.35];
  [self addSubview:_nodeInfo];

  _sosButton = [self buttonWithTitle:@"SOS" font:24 color:[UIColor whiteColor]
                                  bg:[UIColor colorWithRed:0.78 green:0.08 blue:0.06 alpha:1]];
  _sosButton.layer.cornerRadius = 14;
  UILongPressGestureRecognizer *lp =
      [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onSosHold:)];
  lp.minimumPressDuration = 0.05;
  [_sosButton addGestureRecognizer:lp];
  [self addSubview:_sosButton];

  _sosProgress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
  _sosProgress.progressTintColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.2 alpha:1];
  _sosProgress.progress = 0;
  [self addSubview:_sosProgress];

  _nightTint = [[UIView alloc] init];
  _nightTint.backgroundColor = [UIColor colorWithRed:0.55 green:0.0 blue:0.0 alpha:0.35];
  _nightTint.userInteractionEnabled = NO;
  _nightTint.hidden = YES;
  [self addSubview:_nightTint];

  [self buildReplyBanner];
  [self buildOfflineView];
  [self buildEmergencyView];

  _secretCorner = [UIButton buttonWithType:UIButtonTypeCustom];
  _secretCorner.backgroundColor = [UIColor clearColor];
  [_secretCorner addTarget:self action:@selector(onSecretCorner)
          forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_secretCorner];

  _infoButton = [UIButton buttonWithType:UIButtonTypeCustom];
  [_infoButton setTitle:@"ⓘ" forState:UIControlStateNormal];
  _infoButton.titleLabel.font = [UIFont systemFontOfSize:22];
  [_infoButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.4] forState:UIControlStateNormal];
  [_infoButton addTarget:self action:@selector(onInfo) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_infoButton];

  [self clearLabelBackgrounds:self];
}

- (void)buildReplyBanner {
  _replyBanner = [[UIView alloc] init];
  _replyBanner.backgroundColor = [UIColor colorWithRed:0.11 green:0.30 blue:0.16 alpha:0.97];
  _replyBanner.layer.cornerRadius = 16;
  _replyBanner.hidden = YES;
  [self addSubview:_replyBanner];

  _replyCaption = [[UILabel alloc] init];
  _replyCaption.font = [UIFont systemFontOfSize:18];
  _replyCaption.textColor = [UIColor colorWithWhite:1 alpha:0.7];
  _replyCaption.textAlignment = NSTextAlignmentCenter;
  [_replyBanner addSubview:_replyCaption];

  _replyText = [[UILabel alloc] init];
  _replyText.font = [UIFont boldSystemFontOfSize:34];
  _replyText.textColor = [UIColor whiteColor];
  _replyText.numberOfLines = 0;
  _replyText.textAlignment = NSTextAlignmentCenter;
  [_replyBanner addSubview:_replyText];
}
- (void)buildOfflineView {
  _offlineView = [[UIView alloc] init];
  _offlineView.backgroundColor = DBBg();
  _offlineView.hidden = YES;
  [self addSubview:_offlineView];
  _offlineTitle = [[UILabel alloc] init];
  _offlineTitle.font = [UIFont boldSystemFontOfSize:34];
  _offlineTitle.textColor = DBFg();
  _offlineTitle.textAlignment = NSTextAlignmentCenter;
  [_offlineView addSubview:_offlineTitle];
  _offlineBody = [[UILabel alloc] init];
  _offlineBody.font = [UIFont systemFontOfSize:22];
  _offlineBody.textColor = DBDim();
  _offlineBody.textAlignment = NSTextAlignmentCenter;
  _offlineBody.numberOfLines = 0;
  [_offlineView addSubview:_offlineBody];
}

- (void)buildEmergencyView {
  _emergencyView = [[UIView alloc] init];
  _emergencyView.backgroundColor = [UIColor colorWithRed:0.55 green:0.05 blue:0.04 alpha:1];
  _emergencyView.hidden = YES;
  [self addSubview:_emergencyView];
  _emergencyTitle = [[UILabel alloc] init];
  _emergencyTitle.font = [UIFont boldSystemFontOfSize:64];
  _emergencyTitle.textColor = [UIColor whiteColor];
  _emergencyTitle.textAlignment = NSTextAlignmentCenter;
  [_emergencyView addSubview:_emergencyTitle];
  _emergencyNote = [[UILabel alloc] init];
  _emergencyNote.font = [UIFont systemFontOfSize:26];
  _emergencyNote.textColor = [UIColor colorWithWhite:1 alpha:0.85];
  _emergencyNote.textAlignment = NSTextAlignmentCenter;
  _emergencyNote.numberOfLines = 0;
  [_emergencyView addSubview:_emergencyNote];
  _emergencyCancel = [UIButton buttonWithType:UIButtonTypeCustom];
  _emergencyCancel.titleLabel.font = [UIFont boldSystemFontOfSize:26];
  [_emergencyCancel setTitleColor:[UIColor colorWithRed:0.55 green:0.05 blue:0.04 alpha:1]
                         forState:UIControlStateNormal];
  _emergencyCancel.backgroundColor = [UIColor whiteColor];
  _emergencyCancel.layer.cornerRadius = 14;
  [_emergencyCancel addTarget:self action:@selector(onEmergencyCancel)
             forControlEvents:UIControlEventTouchUpInside];
  [_emergencyView addSubview:_emergencyCancel];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize sz = self.bounds.size;
  _themeBg.frame = self.bounds;
  _nightTint.frame = self.bounds;
  _offlineView.frame = self.bounds;
  _emergencyView.frame = self.bounds;

  CGFloat cy = sz.height * 0.34;
  _clockLabel.frame = CGRectMake(0, cy - 60, sz.width, 100);
  _dateLabel.frame = CGRectMake(0, cy + 44, sz.width, 30);
  _statusLabel.frame = CGRectMake(0, cy + 88, sz.width, 26);
  _eventsLabel.frame = CGRectMake(20, cy + 130, sz.width - 40, 180);

  _infoButton.frame = CGRectMake(14, sz.height - 42, 34, 34);
  _nodeInfo.frame = CGRectMake(54, sz.height - 30, sz.width * 0.6, 20);
  CGFloat sosW = 150, sosH = 62;
  _sosButton.frame = CGRectMake(sz.width - sosW - 20, sz.height - sosH - 20, sosW, sosH);
  _sosProgress.frame = CGRectMake(sz.width - sosW - 20, sz.height - sosH - 30, sosW, 4);
  _secretCorner.frame = CGRectMake(sz.width - 120, 0, 120, 120);

  // reply banner (上部中央)
  CGFloat rbW = MIN(sz.width - 40, 560), rbH = 96;
  _replyBanner.frame = CGRectMake((sz.width - rbW) / 2, 20, rbW, rbH);
  _replyCaption.frame = CGRectMake(20, 12, rbW - 40, 24);
  _replyText.frame = CGRectMake(20, 40, rbW - 40, 44);

  // offline
  _offlineTitle.frame = CGRectMake(0, sz.height / 2 - 50, sz.width, 40);
  _offlineBody.frame = CGRectMake(20, sz.height / 2, sz.width - 40, 60);
  // emergency
  _emergencyTitle.frame = CGRectMake(0, sz.height / 2 - 120, sz.width, 80);
  _emergencyNote.frame = CGRectMake(20, sz.height / 2 - 20, sz.width - 40, 40);
  _emergencyCancel.frame = CGRectMake(sz.width / 2 - 110, sz.height / 2 + 50, 220, 64);
}

- (void)onScreenWillAppear {
  if (!_clockTimer) {
    _clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                   target:self
                                                 selector:@selector(updateClock)
                                                 userInfo:nil
                                                  repeats:YES];
  }
  [self updateClock];
  [self refreshFromCore];
}

- (void)onScreenWillDisappear {
  // 緊急/警報は画面を離れても継続 (home は根なので基本無い)。時計は継続。
}
#pragma mark - 文言 / 時計

- (void)applyStrings {
  _replyCaption.text = [_texts ts:@"reply.banner"];
  _offlineTitle.text = [_texts ts:@"offline.title"];
  _offlineBody.text = [_texts ts:@"offline.body"];
  [_sosButton setTitle:[_texts ts:@"emergency.button"] forState:UIControlStateNormal];
  _emergencyTitle.text = [_texts ts:@"emergency.title"];
  _emergencyNote.text = [_texts ts:@"emergency.notified"];
  [_emergencyCancel setTitle:[_texts ts:@"emergency.cancel"] forState:UIControlStateNormal];
}

- (void)updateClock {
  NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
  NSDateComponents *c =
      [cal components:(NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit |
                       NSHourCalendarUnit | NSMinuteCalendarUnit | NSWeekdayCalendarUnit)
             fromDate:[NSDate date]];
  _clockLabel.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)c.hour, (long)c.minute];
  NSArray *yobi = @[@"日", @"月", @"火", @"水", @"木", @"金", @"土"];
  _dateLabel.text = [NSString stringWithFormat:@"%ld年%ld月%ld日 (%@)", (long)c.year, (long)c.month,
                     (long)c.day, [yobi objectAtIndex:((c.weekday - 1) % 7)]];
}

#pragma mark - core 反映

- (NSString *)firstPanelToken {
  id toks = [DBConfigUtil dig:_cfg path:@"panel.tokens"];
  if ([toks isKindOfClass:[NSArray class]]) {
    for (id t in (NSArray *)toks) {
      if ([t isKindOfClass:[NSString class]] && [(NSString *)t length] > 0) return t;
    }
  }
  return @"";
}

- (void)refreshFromCore {
  // main スレッドでは重い core 呼び出しをしない (起動直後のイベント storm で
  // core 内部ロックにより main が詰まり UI 無反応になるため — 実機で観測)。
  // 背景の直列 queue で JSON を収集し、main で反映する。実行中の再要求は dirty 合併。
  @synchronized(self) {
    if (_refreshBusy) {
      _refreshDirty = YES;
      return;
    }
    _refreshBusy = YES;
  }
  DBCoreBridge *core = _core;
  __weak DBHomeScreen *wself = self;
  dispatch_async(_refreshQueue, ^{
    NSDictionary *cfg = [core config];
    NSDictionary *st = [core status];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBHomeScreen *s = wself;
      if (!s) return;
      BOOL dirty = NO;
      @synchronized(s) {
        dirty = s->_refreshDirty;
        s->_refreshDirty = NO;
        if (!dirty) s->_refreshBusy = NO;
      }
      [s applyCoreSnapshotWithConfig:cfg status:st];
      if (dirty) [s refreshFromCore];
    });
  });
}

// main スレッド。背景で収集済みのスナップショットを UI へ反映。
- (void)applyCoreSnapshotWithConfig:(NSDictionary *)cfg status:(NSDictionary *)st {
  if (cfg) {
    _cfg = cfg;
    [_texts setConfig:_cfg];
    [_texts setLang:_boot.uiLang];
    _panelToken = [self firstPanelToken];
  }

  if (st) {
    NSDictionary *node = [st objectForKey:@"node"];
    if ([node isKindOfClass:[NSDictionary class]]) {
      _nodeId = [DBConfigUtil evStr:node key:@"id"];
    }
    NSInteger peers = 0;
    id ps = [st objectForKey:@"peers"];
    if ([ps isKindOfClass:[NSArray class]]) peers = [(NSArray *)ps count];
    _statusLabel.text = [NSString stringWithFormat:@"%@ · peers %ld",
                         [DBConfigUtil evStr:node key:@"name"], (long)peers];
    NSDictionary *disp = [st objectForKey:@"display"];
    if ([disp isKindOfClass:[NSDictionary class]]) [self applyDisplayEvent:disp];
    NSDictionary *em = [st objectForKey:@"emergency"];
    if ([em isKindOfClass:[NSDictionary class]]) {
      if ([DBConfigUtil evBool:em key:@"active"]) {
        [self showEmergencyEvent:em];
      } else {
        [self hideEmergencyEvent:em];
      }
    }
  }
  [self refreshSosConfig];
  [self applyTheme];
  [self applyStrings];
  _nodeInfo.text = [NSString stringWithFormat:@"%@ · %@", _boot.name, _nodeId];
  _offlineView.hidden = _core.isRunning;
}

- (void)refreshSosConfig {
  BOOL show = [_boot.role isEqualToString:@"indoor_panel"];
  id roles = [DBConfigUtil dig:_cfg path:@"emergency.button_on_roles"];
  if ([roles isKindOfClass:[NSArray class]]) {
    show = NO;
    for (id r in (NSArray *)roles) {
      if ([r isKindOfClass:[NSString class]] && [(NSString *)r isEqualToString:_boot.role])
        show = YES;
    }
  }
  _sosButton.hidden = !show;
  _sosProgress.hidden = !show;
  _sosHoldS = [DBConfigUtil doubleVal:_cfg path:@"emergency.hold_to_trigger_s" def:3];
  if (_sosHoldS <= 0) _sosHoldS = 3;
  _cancelRequiresPin = [DBConfigUtil boolVal:_cfg path:@"emergency.cancel_requires_pin" def:YES];
}

- (void)appendEvent:(NSDictionary *)ev {
  NSString *type = [DBConfigUtil evStr:ev key:@"type"];
  NSString *door = [DBConfigUtil evStr:ev key:@"door"];
  NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
  NSDateComponents *c =
      [cal components:(NSHourCalendarUnit | NSMinuteCalendarUnit) fromDate:[NSDate date]];
  NSString *line = [NSString stringWithFormat:@"%02ld:%02ld  %@ %@", (long)c.hour, (long)c.minute,
                    type, door];
  [_events insertObject:line atIndex:0];
  while ([_events count] > 8) [_events removeLastObject];
  _eventsLabel.text = [_events componentsJoinedByString:@"\n"];
}
#pragma mark - テーマ / 表示制御

- (NSString *)themeValue:(NSString *)leaf {
  if ([_nodeId length] > 0) {
    NSString *v =
        [DBConfigUtil str:_cfg path:[NSString stringWithFormat:@"devices.%@.local.theme.%@", _nodeId, leaf]];
    if (v) return v;
  }
  return [DBConfigUtil str:_cfg path:[NSString stringWithFormat:@"display.theme.%@", leaf]];
}

- (void)applyTheme {
  NSString *color = [self themeValue:@"bg_color"];
  UIColor *c = color ? [DBConfigUtil parseHexColor:color] : nil;
  self.backgroundColor = c ? c : DBBg();
  NSString *hash = [self themeValue:@"bg_image"];
  if ([hash length] == 0) {
    _themeHash = nil;
    _themeBg.image = nil;
    _themeBg.hidden = YES;
    return;
  }
  if ([_themeHash isEqualToString:hash] && _themeBg.image != nil) return;
  _themeHash = hash;
  [self loadThemeImage:hash];
}

// 主題背景は非同期取得 (解码も global で実施 → main は blit のみ)。
- (void)loadThemeImage:(NSString *)hash {
  NSMutableString *urlStr =
      [NSMutableString stringWithFormat:@"http://127.0.0.1:%ld/asset/%@", (long)_boot.httpPort, hash];
  if ([_panelToken length] > 0) [urlStr appendFormat:@"?k=%@", _panelToken];
  NSURL *url = [NSURL URLWithString:urlStr];
  if (url == nil) return;
  NSString *want = [hash copy];
  __weak DBHomeScreen *wself = self;
  NSURLRequest *req = [NSURLRequest requestWithURL:url];
  [NSURLConnection sendAsynchronousRequest:req
                                     queue:[NSOperationQueue mainQueue]
                         completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
    DBHomeScreen *s = wself;
    if (!s) return;
    if (data == nil) return;
    if (![resp isKindOfClass:[NSHTTPURLResponse class]] ||
        [(NSHTTPURLResponse *)resp statusCode] != 200) return;
    if (![s->_themeHash isEqualToString:want]) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      UIImage *img = [UIImage imageWithData:data];
      dispatch_async(dispatch_get_main_queue(), ^{
        DBHomeScreen *s2 = wself;
        if (!s2 || ![s2->_themeHash isEqualToString:want]) return;
        s2->_themeBg.image = img;
        s2->_themeBg.hidden = (img == nil);
      });
    });
  }];
}

- (void)applyDisplayEvent:(NSDictionary *)d {
  _brightness = [DBConfigUtil intVal:d path:@"brightness" def:_brightness];
  _night = [DBConfigUtil evBool:d key:@"night"];
  _redTint = [DBConfigUtil evBool:d key:@"red_tint"];
  [self applyDisplay];
}

- (void)applyDisplay {
  _nightTint.hidden = !(_night && _redTint);
  _clockLabel.textColor = _night ? DBNightClk() : DBFg();
  _dateLabel.textColor = _night ? DBNightClk() : DBDim();
  if (!_emergencyActive) [self setBrightness:_brightness];
}

- (void)setBrightness:(NSInteger)percent {
  [UIScreen mainScreen].brightness = (CGFloat)MAX(0, MIN(100, percent)) / 100.0;
}
#pragma mark - SOS

- (void)onSosHold:(UILongPressGestureRecognizer *)g {
  if (g.state == UIGestureRecognizerStateBegan) {
    _sosDownAt = [NSDate date];
    _sosHolding = YES;
    _sosProgress.progress = 0;
    [_sosTimer invalidate];
    _sosTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                 target:self
                                               selector:@selector(onSosTick)
                                               userInfo:nil
                                                repeats:YES];
  } else if (g.state == UIGestureRecognizerStateEnded ||
             g.state == UIGestureRecognizerStateCancelled ||
             g.state == UIGestureRecognizerStateFailed) {
    [self resetSosHold];
  }
}

- (void)onSosTick {
  if (!_sosHolding) {
    [_sosTimer invalidate];
    _sosTimer = nil;
    return;
  }
  NSTimeInterval held = [[NSDate date] timeIntervalSinceDate:_sosDownAt];
  _sosProgress.progress = (float)MIN(1.0, held / _sosHoldS);
  if (held >= _sosHoldS) {
    [self resetSosHold];
    [_core emergency:YES];
  }
}

- (void)resetSosHold {
  _sosHolding = NO;
  [_sosTimer invalidate];
  _sosTimer = nil;
  _sosProgress.progress = 0;
}

#pragma mark - 緊急

- (void)showEmergencyEvent:(NSDictionary *)ev {
  if (_emergencyActive) return;
  _emergencyActive = YES;
  _replyBanner.hidden = YES;
  _emergencyView.hidden = NO;
  [self setBrightness:100];
  if (ev) {
    [_audio startSiren:[DBConfigUtil evStr:ev key:@"audio_path"]
                volume:[DBConfigUtil intVal:ev path:@"alarm_volume" def:100]];
  } else {
    [_audio startSiren:@"" volume:[DBConfigUtil intVal:_cfg path:@"emergency.alarm_volume" def:100]];
  }
}

- (void)hideEmergencyEvent:(NSDictionary *)ev {
  if (!_emergencyActive) return;
  _emergencyActive = NO;
  [_audio stop];
  _emergencyView.hidden = YES;
  [self applyDisplay];
}

- (void)onEmergencyCancel {
  __weak DBHomeScreen *wself = self;
  if (_cancelRequiresPin) {
    [_router requestPinThen:^{
      [wself cancelEmergencyConfirmed];
    }];
    return;
  }
  [self cancelEmergencyConfirmed];
}

- (void)cancelEmergencyConfirmed {
  [_core emergency:NO];
  [self hideEmergencyEvent:nil];
}

#pragma mark - 音声イベント

- (void)playChime:(NSDictionary *)ev {
  NSString *path = [DBConfigUtil evStr:ev key:@"audio_path"];
  NSString *sound = [DBConfigUtil evStr:ev key:@"sound"];
  [_audio playChimeSound:([sound length] ? sound : @"ding1") assetPath:path];
}

- (void)stopChime {
  [_audio stop];
}

- (void)showReplyBanner:(NSDictionary *)ev {
  NSString *path = [DBConfigUtil evStr:ev key:@"audio_path"];
  if ([path length] > 0) {
    if (![_audio playAssetPath:path]) AudioServicesPlaySystemSound((SystemSoundID)1013);
  }
  _replyText.text = [DBConfigUtil evStr:ev key:@"text"];
  _replyBanner.hidden = NO;
  double ttl = [DBConfigUtil doubleVal:ev path:@"ttl_s" def:30];
  if (ttl <= 0) ttl = 30;
  [_replyTimer invalidate];
  _replyTimer = [NSTimer scheduledTimerWithTimeInterval:ttl
                                                 target:self
                                               selector:@selector(hideReplyBanner)
                                               userInfo:nil
                                                repeats:NO];
}

- (void)hideReplyBanner {
  _replyBanner.hidden = YES;
}

#pragma mark - 隠し管理入口 / 情報

- (void)onSecretCorner {
  NSDate *now = [NSDate date];
  if ([now timeIntervalSinceDate:_secretFirst] > 5) {
    _secretFirst = now;
    _secretTaps = 0;
  }
  _secretTaps++;
  if (_secretTaps < 7) return;
  _secretTaps = 0;
  __weak DBHomeScreen *wself = self;
  [_router requestPinThen:^{
    DBHomeScreen *s = wself;
    if (!s) return;
    [s.router showInfo];
  }];
}

- (void)onInfo {
  __weak DBHomeScreen *wself = self;
  [_router requestPinThen:^{
    DBHomeScreen *s = wself;
    if (!s) return;
    [s.router showInfo];
  }];
}

@end



