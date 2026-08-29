#import "DBMainViewController.h"
#import "DBCoreBridge.h"
#import "DBBootConfig.h"
#import "DBTexts.h"
#import "DBConfigUtil.h"
#import "DBSirenPlayer.h"
#import "DBAdminPinViewController.h"
#import "DBInfoViewController.h"
#import "DBPairingViewController.h"
#import <AudioToolbox/AudioToolbox.h>

@interface DBMainViewController () <UIAlertViewDelegate>
@end

static UIColor *DBBg(void)     { return [UIColor colorWithRed:0.063 green:0.078 blue:0.094 alpha:1]; }
static UIColor *DBFg(void)     { return [UIColor colorWithWhite:0.94 alpha:1]; }
static UIColor *DBDim(void)    { return [UIColor colorWithWhite:0.62 alpha:1]; }
static UIColor *DBNightClk(void) { return [UIColor colorWithRed:0.545 green:0.141 blue:0.110 alpha:1]; }

@implementation DBMainViewController {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  DBSirenPlayer *_audio;

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
  NSDate *_lastActivity;

  // 隠し管理入口
  NSInteger _secretTaps;
  NSDate *_secretFirst;

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
  UIButton *_infoButton;  // 角の ⓘ → 本機情報/デバッグ
}

- (id)initWithCore:(DBCoreBridge *)core boot:(DBBootConfig *)boot {
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    _core = [core retain];
    _boot = [boot retain];
    _texts = [[DBTexts alloc] init];
    _audio = [[DBSirenPlayer alloc] init];
    _events = [[NSMutableArray alloc] init];
    _nodeId = [@"" retain];
    _panelToken = [@"" retain];
    _brightness = 70;
    _sosHoldS = 3.0;
    _cancelRequiresPin = YES;
    _lastActivity = [[NSDate date] retain];
    _sosDownAt = [[NSDate distantPast] retain];
    _secretFirst = [[NSDate distantPast] retain];
  }
  return self;
}

- (void)dealloc {
  [_clockTimer invalidate];
  [_replyTimer invalidate];
  [_sosTimer invalidate];
  [_core release];
  [_boot release];
  [_texts release];
  [_audio release];
  [_events release];
  [_nodeId release];
  [_panelToken release];
  [_themeHash release];
  [_sosDownAt release];
  [_lastActivity release];
  [_secretFirst release];
  [_themeBg release];
  [_clockLabel release];
  [_dateLabel release];
  [_statusLabel release];
  [_eventsLabel release];
  [_nodeInfo release];
  [_sosButton release];
  [_sosProgress release];
  [_nightTint release];
  [_replyBanner release];
  [_replyCaption release];
  [_replyText release];
  [_offlineView release];
  [_offlineTitle release];
  [_offlineBody release];
  [_emergencyView release];
  [_emergencyTitle release];
  [_emergencyNote release];
  [_emergencyCancel release];
  [_secretCorner release];
  [_infoButton release];
  [super dealloc];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = DBBg();
  [_texts setLang:_boot.uiLang];
  [self buildUi];
  [self refreshNodeInfo];
  if (!_core.isRunning) _offlineView.hidden = NO;

  DBMainViewController *__unsafe_unretained weakSelf = self;
  [_core addHandler:@"main" handler:^(NSDictionary *ev) { [weakSelf onUiEvent:ev]; }];

  _clockTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                 target:self
                                               selector:@selector(onClockTick)
                                               userInfo:nil
                                                repeats:YES];
  [self updateClock];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [self maybePresentPairing];
}

// 未配対 (全ゼロ PSK) なら門口/室内 UI ではなく配対引導を全画面で出す。
- (void)maybePresentPairing {
  if (self.presentedViewController) return;  // 既に何か表示中
  NSDictionary *p = [_core pairingInfo];
  if (![p isKindOfClass:[NSDictionary class]]) return;      // core 未起動等 → 触らない
  if ([[p objectForKey:@"paired"] boolValue]) return;       // 配対済み
  DBPairingViewController *vc =
      [[[DBPairingViewController alloc] initWithCore:_core boot:_boot] autorelease];
  vc.modalPresentationStyle = UIModalPresentationFullScreen;
  [self presentViewController:vc animated:NO completion:nil];
}

- (void)onActivity {
  [_lastActivity release];
  _lastActivity = [[NSDate date] retain];
}

#pragma mark - UI 構築

- (void)buildUi {
  _themeBg = [[UIImageView alloc] init];
  _themeBg.contentMode = UIViewContentModeScaleAspectFill;
  _themeBg.clipsToBounds = YES;
  _themeBg.hidden = YES;
  [self.view addSubview:_themeBg];

  _clockLabel = [[UILabel alloc] init];
  _clockLabel.font = [UIFont systemFontOfSize:84];
  _clockLabel.textColor = DBFg();
  _clockLabel.textAlignment = NSTextAlignmentCenter;
  [self.view addSubview:_clockLabel];

  _dateLabel = [[UILabel alloc] init];
  _dateLabel.font = [UIFont systemFontOfSize:24];
  _dateLabel.textColor = DBDim();
  _dateLabel.textAlignment = NSTextAlignmentCenter;
  [self.view addSubview:_dateLabel];

  _statusLabel = [[UILabel alloc] init];
  _statusLabel.font = [UIFont systemFontOfSize:20];
  _statusLabel.textColor = DBDim();
  _statusLabel.textAlignment = NSTextAlignmentCenter;
  [self.view addSubview:_statusLabel];

  _eventsLabel = [[UILabel alloc] init];
  _eventsLabel.font = [UIFont systemFontOfSize:17];
  _eventsLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
  _eventsLabel.textAlignment = NSTextAlignmentCenter;
  _eventsLabel.numberOfLines = 0;
  [self.view addSubview:_eventsLabel];

  _nodeInfo = [[UILabel alloc] init];
  _nodeInfo.font = [UIFont systemFontOfSize:14];
  _nodeInfo.textColor = [UIColor colorWithWhite:1 alpha:0.35];
  [self.view addSubview:_nodeInfo];

  _sosButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
  [_sosButton setTitle:@"SOS" forState:UIControlStateNormal];
  _sosButton.titleLabel.font = [UIFont boldSystemFontOfSize:24];
  [_sosButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  _sosButton.backgroundColor = [UIColor colorWithRed:0.78 green:0.16 blue:0.12 alpha:1];
  _sosButton.layer.cornerRadius = 14;
  {
    UILongPressGestureRecognizer *hold =
        [[[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                       action:@selector(onSosHold:)] autorelease];
    hold.minimumPressDuration = 0.05;
    [_sosButton addGestureRecognizer:hold];
  }
  [self.view addSubview:_sosButton];

  _sosProgress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
  _sosProgress.progressTintColor = [UIColor whiteColor];
  _sosProgress.trackTintColor = [UIColor colorWithWhite:1 alpha:0.25];
  [self.view addSubview:_sosProgress];

  _nightTint = [[UIView alloc] init];
  _nightTint.backgroundColor = [UIColor colorWithRed:1.0 green:0.13 blue:0.0 alpha:0.20];
  _nightTint.userInteractionEnabled = NO;
  _nightTint.hidden = YES;
  [self.view addSubview:_nightTint];

  [self buildReplyBanner];
  [self buildOfflineView];
  [self buildEmergencyView];

  _secretCorner = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
  [_secretCorner addTarget:self action:@selector(onSecretCorner) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:_secretCorner];

  // 左下の ⓘ — 本機情報/デバッグ画面 (PIN 要求)。
  _infoButton = [[UIButton buttonWithType:UIButtonTypeInfoLight] retain];
  [_infoButton addTarget:self action:@selector(onInfo) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:_infoButton];

  // iOS5: UILabel が既定で不透明白背景で描画される個体があるため、全ラベルを透明化。
  [self clearLabelBackgrounds:self.view];
}

// この画面のラベルは全て透明背景にする (入れ子含め再帰)。
// (この個体では UILabel 既定背景が不透明白のため明示的に clearColor を設定)
- (void)clearLabelBackgrounds:(UIView *)v {
  for (UIView *sub in v.subviews) {
    if ([sub isKindOfClass:[UILabel class]]) sub.backgroundColor = [UIColor clearColor];
    [self clearLabelBackgrounds:sub];
  }
}

- (void)buildReplyBanner {
  _replyBanner = [[UIView alloc] init];
  _replyBanner.backgroundColor = [UIColor colorWithRed:0.11 green:0.30 blue:0.16 alpha:0.97];
  _replyBanner.layer.cornerRadius = 16;
  _replyBanner.hidden = YES;
  [self.view addSubview:_replyBanner];

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
  [self.view addSubview:_offlineView];
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
  [self.view addSubview:_emergencyView];
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
  // iOS5: System だと白背景 RoundedRect が描かれ bg/文字色が見えなくなる → Custom
  _emergencyCancel = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
  _emergencyCancel.titleLabel.font = [UIFont boldSystemFontOfSize:26];
  [_emergencyCancel setTitleColor:[UIColor colorWithRed:0.55 green:0.05 blue:0.04 alpha:1]
                         forState:UIControlStateNormal];
  _emergencyCancel.backgroundColor = [UIColor whiteColor];
  _emergencyCancel.layer.cornerRadius = 14;
  [_emergencyCancel addTarget:self action:@selector(onEmergencyCancel)
             forControlEvents:UIControlEventTouchUpInside];
  [_emergencyView addSubview:_emergencyCancel];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGSize sz = self.view.bounds.size;
  _themeBg.frame = self.view.bounds;
  _nightTint.frame = self.view.bounds;
  _offlineView.frame = self.view.bounds;
  _emergencyView.frame = self.view.bounds;

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

#pragma mark - 文言

- (void)applyStrings {
  _replyCaption.text = [_texts ts:@"reply.banner"];
  _offlineTitle.text = [_texts ts:@"offline.title"];
  _offlineBody.text = [_texts ts:@"offline.body"];
  [_sosButton setTitle:[_texts ts:@"emergency.button"] forState:UIControlStateNormal];
  _emergencyTitle.text = [_texts ts:@"emergency.title"];
  _emergencyNote.text = [_texts ts:@"emergency.notified"];
  [_emergencyCancel setTitle:[_texts ts:@"emergency.cancel"] forState:UIControlStateNormal];
}

#pragma mark - 時計 / ノード情報

- (void)onClockTick {
  [self updateClock];
}

- (void)updateClock {
  NSCalendar *cal = [[[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar] autorelease];
  NSDateComponents *c = [cal components:(NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit |
                                         NSHourCalendarUnit | NSMinuteCalendarUnit | NSSecondCalendarUnit |
                                         NSWeekdayCalendarUnit)
                               fromDate:[NSDate date]];
  _clockLabel.text = [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)c.hour,
                                                (long)c.minute, (long)c.second];
  NSArray *yobi = [NSArray arrayWithObjects:@"日", @"月", @"火", @"水", @"木", @"金", @"土", nil];
  _dateLabel.text = [NSString stringWithFormat:@"%ld年%ld月%ld日 (%@)", (long)c.year, (long)c.month,
                     (long)c.day, [yobi objectAtIndex:((c.weekday - 1) % 7)]];
}

- (void)refreshNodeInfo {
  [self refreshConfigCache];
  NSDictionary *st = [_core status];
  if (st) {
    NSDictionary *node = [st objectForKey:@"node"];
    if ([node isKindOfClass:[NSDictionary class]]) {
      NSString *newId = [DBConfigUtil evStr:node key:@"id"];
      [newId retain];
      [_nodeId release];
      _nodeId = newId;
    }
    NSInteger peers = 0;
    id ps = [st objectForKey:@"peers"];
    if ([ps isKindOfClass:[NSArray class]]) peers = [(NSArray *)ps count];
    NSDictionary *node2 = [st objectForKey:@"node"];
    _statusLabel.text = [NSString stringWithFormat:@"%@ · peers %ld",
                         [DBConfigUtil evStr:node2 key:@"name"], (long)peers];
    NSDictionary *disp = [st objectForKey:@"display"];
    if ([disp isKindOfClass:[NSDictionary class]]) [self applyDisplayValues:disp];
    NSDictionary *em = [st objectForKey:@"emergency"];
    if ([em isKindOfClass:[NSDictionary class]]) {
      if ([DBConfigUtil evBool:em key:@"active"]) {
        BOOL was = _emergencyActive;
        [self showEmergency];
        if (!was) [_audio startSiren:@"" volume:[DBConfigUtil intVal:_cfg path:@"emergency.alarm_volume" def:100]];
      } else {
        [self hideEmergency];
      }
    }
  }
  [self refreshSosConfig];
  [self applyTheme];
  [self applyStrings];
  [self refreshNodeInfoLine];
}

- (void)refreshNodeInfoLine {
  _nodeInfo.text = [NSString stringWithFormat:@"%@ · %@", _boot.name, _nodeId];
}

- (void)refreshConfigCache {
  NSDictionary *c = [[_core config] retain];
  [_cfg release];
  _cfg = c;
  [_texts setConfig:_cfg];
  NSString *tok = [self firstPanelToken];
  [tok retain];
  [_panelToken release];
  _panelToken = tok;
}

- (NSString *)firstPanelToken {
  id toks = [DBConfigUtil dig:_cfg path:@"panel.tokens"];
  if ([toks isKindOfClass:[NSArray class]]) {
    for (id t in (NSArray *)toks) {
      if ([t isKindOfClass:[NSString class]] && [(NSString *)t length] > 0) return t;
    }
  }
  return @"";
}

#pragma mark - テーマ

- (NSString *)themeValue:(NSString *)leaf {
  if ([_nodeId length] > 0) {
    NSString *v = [DBConfigUtil str:_cfg path:[NSString stringWithFormat:@"devices.%@.local.theme.%@", _nodeId, leaf]];
    if (v) return v;
  }
  return [DBConfigUtil str:_cfg path:[NSString stringWithFormat:@"display.theme.%@", leaf]];
}

- (void)applyTheme {
  NSString *color = [self themeValue:@"bg_color"];
  UIColor *c = color ? [DBConfigUtil parseHexColor:color] : nil;
  self.view.backgroundColor = c ? c : DBBg();
  NSString *hash = [self themeValue:@"bg_image"];
  if ([hash length] == 0) {
    [_themeHash release];
    _themeHash = nil;
    _themeBg.image = nil;
    _themeBg.hidden = YES;
    return;
  }
  if ([hash isEqualToString:_themeHash] && _themeBg.image != nil) return;
  [hash retain];
  [_themeHash release];
  _themeHash = hash;
  [self loadThemeImage:hash];
}

- (void)loadThemeImage:(NSString *)hash {
  NSMutableString *urlStr =
      [NSMutableString stringWithFormat:@"http://127.0.0.1:%ld/asset/%@", (long)_boot.httpPort, hash];
  if ([_panelToken length] > 0) [urlStr appendFormat:@"?k=%@", _panelToken];
  NSURL *url = [NSURL URLWithString:urlStr];
  if (url == nil) return;
  NSString *want = [[hash copy] autorelease];
  // 非同期取得 (NSURLConnection ブロック版 — iOS5)。
  NSURLRequest *req = [NSURLRequest requestWithURL:url];
  [NSURLConnection sendAsynchronousRequest:req
                                     queue:[NSOperationQueue mainQueue]
                         completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
    if (data == nil) return;
    if (![resp isKindOfClass:[NSHTTPURLResponse class]] ||
        [(NSHTTPURLResponse *)resp statusCode] != 200) return;
    if (![_themeHash isEqualToString:want]) return;
    UIImage *img = [UIImage imageWithData:data];
    if (img == nil) return;
    _themeBg.image = img;
    _themeBg.hidden = NO;
  }];
}

#pragma mark - 表示制御

- (void)applyDisplayValues:(NSDictionary *)d {
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

- (void)refreshSosConfig {
  BOOL show = [_boot.role isEqualToString:@"indoor_panel"];
  id roles = [DBConfigUtil dig:_cfg path:@"emergency.button_on_roles"];
  if ([roles isKindOfClass:[NSArray class]]) {
    show = NO;
    for (id r in (NSArray *)roles) {
      if ([r isKindOfClass:[NSString class]] && [(NSString *)r isEqualToString:_boot.role]) show = YES;
    }
  }
  _sosButton.hidden = !show;
  _sosProgress.hidden = !show;
  _sosHoldS = [DBConfigUtil doubleVal:_cfg path:@"emergency.hold_to_trigger_s" def:3];
  if (_sosHoldS <= 0) _sosHoldS = 3;
  _cancelRequiresPin = [DBConfigUtil boolVal:_cfg path:@"emergency.cancel_requires_pin" def:YES];
}

- (void)onSosHold:(UILongPressGestureRecognizer *)g {
  if (g.state == UIGestureRecognizerStateBegan) {
    [_sosDownAt release];
    _sosDownAt = [[NSDate date] retain];
    _sosHolding = YES;
    _sosProgress.progress = 0;
    [_sosTimer invalidate];
    _sosTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(onSosTick)
                                               userInfo:nil repeats:YES];
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

- (void)showEmergency {
  if (_emergencyActive) return;
  _emergencyActive = YES;
  _replyBanner.hidden = YES;
  if (self.presentedViewController) [self dismissViewControllerAnimated:NO completion:nil];
  _emergencyView.hidden = NO;
  [self setBrightness:100];
}

- (void)hideEmergency {
  if (!_emergencyActive) return;
  _emergencyActive = NO;
  [_audio stop];
  _emergencyView.hidden = YES;
  [_lastActivity release];
  _lastActivity = [[NSDate date] retain];
  [self applyDisplay];
}

- (void)onEmergencyCancel {
  if (_cancelRequiresPin) {
    DBAdminPinViewController *dlg = [[[DBAdminPinViewController alloc] initWithTexts:_texts] autorelease];
    DBMainViewController *__unsafe_unretained weakSelf = self;
    dlg.onUnlocked = ^{ [weakSelf cancelEmergencyConfirmed]; };
    [self presentViewController:dlg animated:YES completion:nil];
    return;
  }
  [self cancelEmergencyConfirmed];
}

- (void)cancelEmergencyConfirmed {
  [_core emergency:NO];
  [self hideEmergency];
}

#pragma mark - core イベント (main スレッド)

- (void)onUiEvent:(NSDictionary *)ev {
  NSString *t = [DBConfigUtil evStr:ev key:@"t"];
  if ([t isEqualToString:@"chime"]) {
    NSString *path = [DBConfigUtil evStr:ev key:@"audio_path"];
    if (![_audio playAssetPath:path] &&
        ![_audio playConfigured:[DBConfigUtil evStr:ev key:@"sound"]
                         dataDir:[DBBootConfig dataDir] loop:NO])
      AudioServicesPlaySystemSound((SystemSoundID)1013);
  } else if ([t isEqualToString:@"event"]) {
    [self appendEvent:ev];
  } else if ([t isEqualToString:@"reply"]) {
    NSString *path = [DBConfigUtil evStr:ev key:@"audio_path"];
    if ([path length] > 0) {
      if (![_audio playAssetPath:path]) AudioServicesPlaySystemSound((SystemSoundID)1013);
    }
    _replyText.text = [DBConfigUtil evStr:ev key:@"text"];
    _replyBanner.hidden = NO;
    double ttl = [DBConfigUtil doubleVal:ev path:@"ttl_s" def:30];
    if (ttl <= 0) ttl = 30;
    [_replyTimer invalidate];
    _replyTimer = [NSTimer scheduledTimerWithTimeInterval:ttl target:self
                                                 selector:@selector(hideReplyBanner)
                                                 userInfo:nil repeats:NO];
  } else if ([t isEqualToString:@"display"]) {
    [self applyDisplayValues:ev];
  } else if ([t isEqualToString:@"emergency"]) {
    if ([DBConfigUtil evBool:ev key:@"active"]) {
      [self showEmergency];
      [_audio startSiren:[DBConfigUtil evStr:ev key:@"audio_path"]
                  volume:[DBConfigUtil intVal:ev path:@"alarm_volume" def:100]];
    } else {
      [self hideEmergency];
    }
  } else if ([t isEqualToString:@"peers_changed"] || [t isEqualToString:@"config_changed"]) {
    [self refreshNodeInfo];
  }
}

- (void)hideReplyBanner {
  _replyBanner.hidden = YES;
}

- (void)appendEvent:(NSDictionary *)ev {
  NSString *type = [DBConfigUtil evStr:ev key:@"type"];
  NSString *door = [DBConfigUtil evStr:ev key:@"door"];
  NSCalendar *cal = [[[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar] autorelease];
  NSDateComponents *c =
      [cal components:(NSHourCalendarUnit | NSMinuteCalendarUnit | NSSecondCalendarUnit)
             fromDate:[NSDate date]];
  NSString *line = [NSString stringWithFormat:@"%02ld:%02ld:%02ld  %@ %@",
                    (long)c.hour, (long)c.minute, (long)c.second, type, door];
  [_events insertObject:line atIndex:0];
  while ([_events count] > 8) [_events removeLastObject];
  _eventsLabel.text = [_events componentsJoinedByString:@"\n"];
}

#pragma mark - 隠し管理入口

- (void)onSecretCorner {
  NSDate *now = [NSDate date];
  if ([now timeIntervalSinceDate:_secretFirst] > 5) {
    [_secretFirst release];
    _secretFirst = [now retain];
    _secretTaps = 0;
  }
  _secretTaps++;
  if (_secretTaps < 7) return;
  _secretTaps = 0;
  DBAdminPinViewController *dlg = [[[DBAdminPinViewController alloc] initWithTexts:_texts] autorelease];
  DBMainViewController *__unsafe_unretained weakSelf = self;
  dlg.onUnlocked = ^{ [weakSelf showAdminInfo]; };
  [self presentViewController:dlg animated:YES completion:nil];
}

- (void)onInfo {
  // 管理 PIN を要求してから debug 画面を開く。
  DBAdminPinViewController *dlg = [[[DBAdminPinViewController alloc] initWithTexts:_texts] autorelease];
  DBMainViewController *__unsafe_unretained weakSelf = self;
  dlg.onUnlocked = ^{ [weakSelf presentInfo]; };
  [self presentViewController:dlg animated:YES completion:nil];
}

- (void)presentInfo {
  DBInfoViewController *vc = [[[DBInfoViewController alloc] initWithCore:_core boot:_boot] autorelease];
  vc.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
  [self presentViewController:vc animated:YES completion:nil];
}

- (void)showAdminInfo {
  [UIApplication sharedApplication].idleTimerDisabled = NO;
  NSDictionary *st = [_core status];
  NSDictionary *node = [st objectForKey:@"node"];
  NSInteger peers = 0;
  id ps = [st objectForKey:@"peers"];
  if ([ps isKindOfClass:[NSArray class]]) peers = [(NSArray *)ps count];
  NSString *msg = [NSString stringWithFormat:@"node: %@ (%@)\npeers: %ld\ndata: %@",
                   [DBConfigUtil evStr:node key:@"name"], _nodeId, (long)peers, [DBBootConfig dataDir]];
  UIAlertView *a = [[[UIAlertView alloc] initWithTitle:[_texts ts:@"admin.title"]
                                               message:msg
                                              delegate:self
                                     cancelButtonTitle:@"OK"
                                     otherButtonTitles:nil] autorelease];
  [a show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
  [UIApplication sharedApplication].idleTimerDisabled = YES;
}

@end
