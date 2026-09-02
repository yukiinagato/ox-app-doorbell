#import "DBHomeScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBPairingModel.h"
#import "../Core/DBRefreshCoalescer.h"
#import "../Core/DBSemanticStyle.h"
#import "../Core/DBTexts.h"
#import "../Media/DBSiren.h"
#import "DBRouter.h"
#import <AudioToolbox/AudioToolbox.h>

static UIColor *DBBg(void) { return [UIColor colorWithRed:0.063 green:0.078 blue:0.094 alpha:1]; }
static UIColor *DBFg(void) { return [UIColor colorWithWhite:0.94 alpha:1]; }
static UIColor *DBDim(void) { return [UIColor colorWithWhite:0.62 alpha:1]; }
static UIColor *DBNightClk(void) { return [UIColor colorWithRed:0.545 green:0.141 blue:0.110 alpha:1]; }

static CGRect DBHomeScaledFrame(CGRect base, CGFloat scale, CGSize bounds, CGFloat margin) {
  CGFloat width = MIN(CGRectGetWidth(base) * scale, bounds.width - 2 * margin);
  CGFloat height = MIN(CGRectGetHeight(base) * scale, bounds.height * 0.28);
  CGFloat x = MIN(MAX(margin, CGRectGetMidX(base) - width / 2), bounds.width - margin - width);
  CGFloat y = MIN(MAX(margin, CGRectGetMidY(base) - height / 2), bounds.height - margin - height);
  return CGRectMake(x, y, MAX(44, width), MAX(44, height));
}

@interface DBHomeScreen ()
- (NSDictionary *)styleForSemanticID:(NSString *)semanticID
                            foreground:(UIColor *)foreground
                            background:(UIColor *)background
                                safety:(BOOL)safety;
- (void)applySemanticStyles;
@end

@implementation DBHomeScreen {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  DBSiren *_audio;

  NSDictionary *_cfg;
  NSString *_nodeId;
  NSString *_themeHash;
  NSMutableArray *_events;  // At most eight recent event strings.
  NSArray *_doorPeers;      // Live door stations from status.peers.

  // Display state.
  NSInteger _brightness;
  BOOL _night;
  BOOL _redTint;

  // SOS state.
  BOOL _emergencyActive;
  BOOL _safeMode;
  double _sosHoldS;
  BOOL _cancelRequiresPin;
  NSDate *_sosDownAt;
  BOOL _sosHolding;
  NSTimer *_sosTimer;

  NSTimer *_clockTimer;
  NSTimer *_replyTimer;


  NSInteger _secretTaps;
  NSDate *_secretFirst;


  dispatch_queue_t _refreshQueue;
  DBRefreshCoalescer *_refreshGate;
  NSTimer *_peersTimer;
  NSString *_pairingState;

  // UI
  UIImageView *_themeBg;
  UILabel *_clockLabel;
  UILabel *_dateLabel;
  UILabel *_statusLabel;
  UILabel *_eventsLabel;
  UILabel *_nodeInfo;
  UIButton *_sosButton;
  UIButton *_monitorButton;
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
  UIButton *_membershipButton;   // Opens the Add-device panel behind the admin password.
  UIButton *_pairBanner;         // pair.not_set_up_banner while the node is not ready.
  UIView *_monitorPicker;
  UILabel *_monitorPickerTitle;
  UIScrollView *_monitorPickerList;
  NSMutableArray *_monitorPeerButtons;
  UIButton *_monitorCancel;
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
    _doorPeers = @[];
    _monitorPeerButtons = [[NSMutableArray alloc] init];
    _nodeId = @"";
    _brightness = 70;
    _sosHoldS = 3.0;
    _cancelRequiresPin = YES;
    _sosDownAt = [NSDate distantPast];
    _secretFirst = [NSDate distantPast];
    _refreshQueue = dispatch_queue_create("doorbell.home.refresh", DISPATCH_QUEUE_SERIAL);
    _refreshGate = [[DBRefreshCoalescer alloc] init];
    _pairingState = DBPairingStateUnknown;
    [self buildUi];
  }
  return self;
}

- (NSString *)screenName {
  return @"home";
}


- (UIButton *)buttonWithTitle:(NSString *)title font:(CGFloat)size
                        color:(UIColor *)color bg:(UIColor *)bg {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
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

  // The membership line is the documented, non-hidden entry to the Add-device
  // panel. It stays behind the admin password like every other admin action.
  _membershipButton = [UIButton buttonWithType:UIButtonTypeCustom];
  _membershipButton.backgroundColor = [UIColor clearColor];
  [_membershipButton addTarget:self action:@selector(onMembership)
              forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_membershipButton];

  _pairBanner = [self buttonWithTitle:@"" font:19 color:[UIColor whiteColor]
                                   bg:[UIColor colorWithRed:0.72 green:0.45 blue:0.10 alpha:1]];
  _pairBanner.layer.cornerRadius = 10;
  _pairBanner.hidden = YES;
  [_pairBanner addTarget:self action:@selector(onPairBanner)
        forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_pairBanner];

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

  _monitorButton = [self buttonWithTitle:@"" font:24 color:[UIColor whiteColor]
                                      bg:[UIColor colorWithRed:0.10 green:0.42 blue:0.72 alpha:1]];
  _monitorButton.layer.cornerRadius = 14;
  [_monitorButton addTarget:self action:@selector(onMonitorList)
             forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_monitorButton];

  _nightTint = [[UIView alloc] init];
  _nightTint.backgroundColor = [UIColor colorWithRed:0.55 green:0.0 blue:0.0 alpha:0.35];
  _nightTint.userInteractionEnabled = NO;
  _nightTint.hidden = YES;
  [self addSubview:_nightTint];

  [self buildReplyBanner];
  [self buildOfflineView];
  [self buildMonitorPicker];
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

- (void)buildMonitorPicker {
  _monitorPicker = [[UIView alloc] init];
  _monitorPicker.backgroundColor = [UIColor colorWithRed:0.035 green:0.045 blue:0.06 alpha:0.98];
  _monitorPicker.hidden = YES;
  [self addSubview:_monitorPicker];

  _monitorPickerTitle = [[UILabel alloc] init];
  _monitorPickerTitle.font = [UIFont boldSystemFontOfSize:34];
  _monitorPickerTitle.textColor = [UIColor whiteColor];
  _monitorPickerTitle.textAlignment = NSTextAlignmentCenter;
  [_monitorPicker addSubview:_monitorPickerTitle];

  _monitorPickerList = [[UIScrollView alloc] init];
  _monitorPickerList.alwaysBounceVertical = YES;
  [_monitorPicker addSubview:_monitorPickerList];

  _monitorCancel = [self buttonWithTitle:@"" font:22 color:[UIColor whiteColor]
                                      bg:[UIColor colorWithWhite:1 alpha:0.14]];
  _monitorCancel.layer.cornerRadius = 12;
  [_monitorCancel addTarget:self action:@selector(onMonitorPickerCancel)
             forControlEvents:UIControlEventTouchUpInside];
  [_monitorPicker addSubview:_monitorCancel];
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
  _membershipButton.frame = CGRectMake(sz.width / 2 - 200, cy + 82, 400, 38);
  _eventsLabel.frame = CGRectMake(20, cy + 130, sz.width - 40, 180);
  CGFloat bannerW = MIN(sz.width - 40, 560);
  // Below the reply banner's slot so a quick reply cannot hide the reminder.
  _pairBanner.frame = CGRectMake((sz.width - bannerW) / 2, 122, bannerW, 52);

  _infoButton.frame = CGRectMake(14, sz.height - 42, 34, 34);
  _nodeInfo.frame = CGRectMake(54, sz.height - 30, sz.width * 0.6, 20);
  CGFloat sosW = 150, sosH = 62;
  CGRect sosBase = CGRectMake(sz.width - sosW - 20, sz.height - sosH - 20, sosW, sosH);
  NSDictionary *sosStyle = [self styleForSemanticID:@"sos.trigger"
                                          foreground:[UIColor whiteColor]
                                          background:[UIColor colorWithRed:0.78 green:0.08 blue:0.06 alpha:1]
                                              safety:YES];
  CGFloat sosScale = [DBSemanticStyle numberInStyle:sosStyle key:@"scale" fallback:1
                                            minimum:1 maximum:2];
  _sosButton.frame = DBHomeScaledFrame(sosBase, sosScale, sz, 12);
  _sosProgress.frame = CGRectMake(sz.width - sosW - 20, sz.height - sosH - 30, sosW, 4);
  CGFloat monitorW = 240;
  _monitorButton.frame = CGRectMake((sz.width - monitorW) / 2, sz.height - sosH - 20,
                                    monitorW, sosH);
  _secretCorner.frame = CGRectMake(sz.width - 120, 0, 120, 120);


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
  CGRect emergencyBase = CGRectMake(sz.width / 2 - 110, sz.height / 2 + 50, 220, 64);
  NSDictionary *cancelStyle = [self styleForSemanticID:@"sos.cancel"
                                             foreground:[UIColor colorWithRed:0.55 green:0.05 blue:0.04 alpha:1]
                                             background:[UIColor whiteColor] safety:YES];
  CGFloat cancelScale = [DBSemanticStyle numberInStyle:cancelStyle key:@"scale" fallback:1
                                               minimum:1 maximum:2];
  _emergencyCancel.frame = DBHomeScaledFrame(emergencyBase, cancelScale, sz, 12);

  // Door-station picker overlay.
  _monitorPicker.frame = self.bounds;
  _monitorPickerTitle.frame = CGRectMake(20, 54, sz.width - 40, 48);
  CGFloat pickerMargin = sz.width > sz.height ? sz.width * 0.20 : 42;
  CGFloat listY = 122;
  CGFloat cancelH = 58;
  _monitorPickerList.frame = CGRectMake(pickerMargin, listY, sz.width - 2 * pickerMargin,
                                        sz.height - listY - cancelH - 42);
  CGFloat rowY = 0;
  for (UIButton *b in _monitorPeerButtons) {
    b.frame = CGRectMake(0, rowY, _monitorPickerList.bounds.size.width, 64);
    rowY += 76;
  }
  _monitorPickerList.contentSize = CGSizeMake(_monitorPickerList.bounds.size.width, rowY);
  _monitorCancel.frame = CGRectMake(sz.width / 2 - 100, sz.height - cancelH - 18, 200, cancelH);
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
  // Mesh membership changes are event driven, but a lost or coalesced event
  // must never leave a joined door station invisible in the monitor picker.
  // This slow safety poll bounds that to five seconds.
  if (!_peersTimer) {
    _peersTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                   target:self
                                                 selector:@selector(refreshFromCore)
                                                 userInfo:nil
                                                  repeats:YES];
  }
  // The first status may contain only UDP discovery identity/address data. This
  // convergence refresh picks up role/name metadata; duplicate updates merge safely.
  __weak DBHomeScreen *wself = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    DBHomeScreen *s = wself;
    if (s && s.superview) [s refreshFromCore];
  });
}

- (void)onScreenWillDisappear {
  // Alerts and the clock remain active while the root home view is covered.
  _monitorPicker.hidden = YES;
  [_peersTimer invalidate];
  _peersTimer = nil;
}

- (void)dealloc {
  [_peersTimer invalidate];
  [_clockTimer invalidate];
  [_replyTimer invalidate];
  [_sosTimer invalidate];
}


- (void)applyStrings {
  _replyCaption.text = [_texts ts:@"reply.banner"];
  _offlineTitle.text = [_texts ts:@"offline.title"];
  _offlineBody.text = [_texts ts:@"offline.body"];
  [_sosButton setTitle:[_texts ts:@"emergency.button"] forState:UIControlStateNormal];
  _emergencyTitle.text = [_texts ts:@"emergency.title"];
  _emergencyNote.text = [_texts ts:@"emergency.notified"];
  [_emergencyCancel setTitle:[_texts ts:@"emergency.cancel"] forState:UIControlStateNormal];
  [_monitorButton setTitle:[_texts ts:@"monitor.open"] forState:UIControlStateNormal];
  _monitorPickerTitle.text = [_texts ts:@"monitor.choose"];
  [_monitorCancel setTitle:[_texts ts:@"monitor.close"] forState:UIControlStateNormal];
}

- (void)updateClock {
  NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
  NSDateComponents *c =
      [cal components:(NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit |
                       NSHourCalendarUnit | NSMinuteCalendarUnit | NSSecondCalendarUnit |
                       NSWeekdayCalendarUnit)
             fromDate:[NSDate date]];
  _clockLabel.text = [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)c.hour,
                                                (long)c.minute, (long)c.second];
  NSArray *weekdayKeys = @[@"day.sun", @"day.mon", @"day.tue", @"day.wed", @"day.thu",
                            @"day.fri", @"day.sat"];
  _dateLabel.text = [_texts t:@"date.full", [NSNumber numberWithLong:(long)c.year],
                           [NSNumber numberWithLong:(long)c.month],
                           [NSNumber numberWithLong:(long)c.day],
                           [_texts ts:[weekdayKeys objectAtIndex:((c.weekday - 1) % 7)]], nil];
}



- (void)refreshFromCore {
  // The refresh slot is owned by DBRefreshCoalescer. The previous inline gate
  // kept `busy` set while it re-entered itself, which latched the flag on
  // forever: after the first overlapping request this screen never read Core
  // again, so a door station that joined later never reached the monitor list.
  if (![_refreshGate beginRefresh]) return;
  DBCoreBridge *core = _core;
  __weak DBHomeScreen *wself = self;
  dispatch_async(_refreshQueue, ^{
    NSDictionary *cfg = [core config];
    NSDictionary *st = [core status];
    NSDictionary *pairing = [core pairingInfo];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBHomeScreen *s = wself;
      if (!s) return;
      BOOL again = [s->_refreshGate endRefresh];
      [s applyCoreSnapshotWithConfig:cfg status:st];
      [s applyPairingSnapshot:pairing];
      if (again) [s refreshFromCore];
    });
  });
}

- (void)applyPairingSnapshot:(NSDictionary *)pairing {
  NSString *state = [DBPairingModel stateFromPairingInfo:pairing];
  if (![state isEqualToString:DBPairingStateUnknown]) _pairingState = state;
  NSInteger members = [DBConfigUtil intVal:pairing path:@"home.member_count" def:0];
  NSInteger connected = [DBConfigUtil intVal:pairing path:@"home.connected_count" def:0];
  BOOL founder = [DBConfigUtil boolVal:pairing path:@"is_founder" def:NO];
  BOOL ready = [_pairingState isEqualToString:@"ready"];

  if (ready && members > 0) {
    NSMutableArray *parts = [NSMutableArray array];
    [parts addObject:[_texts t:@"pair.membership",
                          [NSString stringWithFormat:@"%ld", (long)members], nil]];
    [parts addObject:[_texts t:@"pair.membership_connected",
                          [NSString stringWithFormat:@"%ld", (long)connected], nil]];
    if (founder) [parts addObject:[_texts ts:@"pair.created_badge"]];
    _statusLabel.text = [parts componentsJoinedByString:@"  ·  "];
  }
  // The banner stays until the node is ready; tapping it reopens onboarding.
  BOOL showBanner = !ready && ![_pairingState isEqualToString:DBPairingStateUnknown];
  [_pairBanner setTitle:[_texts ts:@"pair.not_set_up_banner"] forState:UIControlStateNormal];
  _pairBanner.hidden = !showBanner;
}

- (void)onMembership {
  if (![_pairingState isEqualToString:@"ready"]) {
    [_router showPairing];
    return;
  }
  __weak DBHomeScreen *wself = self;
  [_router requestPinThen:^{
    DBHomeScreen *s = wself;
    if (!s) return;
    [s.router showAddDevice];
  }];
}

- (void)onPairBanner {
  [_router showPairing];
}


- (void)applyCoreSnapshotWithConfig:(NSDictionary *)cfg status:(NSDictionary *)st {
  if (cfg) {
    _cfg = cfg;
    [_texts setConfig:_cfg];
    [_texts setLang:_boot.uiLang];
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
    NSMutableArray *monitorPeers = [[DBConfigUtil doorPeers:st] mutableCopy];
    NSMutableSet *knownHosts = [NSMutableSet set];
    for (NSDictionary *peer in monitorPeers) {
      // Record every address so NIC ordering changes cannot duplicate a peer.
      for (NSString *host in [DBConfigUtil peerHosts:peer])
        if ([host length] > 0) [knownHosts addObject:host];
    }
    // A mesh seed proves only connectivity. It may be an indoor panel, server,
    // or gateway, so never synthesize a door_station or camera from seed_peers.
    // `door_host`, in contrast, is an explicit local operator override and is a
    // safe last-resort monitor target while peer metadata converges.
    NSString *explicitDoorHost = _boot.doorHost;
    if ([explicitDoorHost length] > 0 && ![knownHosts containsObject:explicitDoorHost]) {
      [knownHosts addObject:explicitDoorHost];
      NSString *urlHost = [DBConfigUtil urlHost:explicitDoorHost];
      [monitorPeers addObject:@{
        @"id" : [@"door-host:" stringByAppendingString:explicitDoorHost],
        @"name" : explicitDoorHost,
        @"role" : @"door_station",
        @"status" : @"configured",
        @"door" : (_boot.door ?: @""),
        @"addrs" : @[ explicitDoorHost ],
        @"stream" : [NSString stringWithFormat:@"http://%@:47180/stream.mjpeg", urlHost],
        @"stream_mp4" : [NSString stringWithFormat:@"http://%@:47180/stream.mp4", urlHost]
      }];
    }
    _doorPeers = [monitorPeers copy];
    [self rebuildMonitorPicker];
    NSDictionary *disp = [st objectForKey:@"display"];
    if ([disp isKindOfClass:[NSDictionary class]]) [self applyDisplayEvent:disp];
  }
  [self refreshSosConfig];
  [self applyTheme];
  [self applyStrings];
  [self applySemanticStyles];
  _nodeInfo.text = [NSString stringWithFormat:@"%@ · %@", _boot.name, _nodeId];
  _offlineView.hidden = _core.isRunning;
}

- (void)rebuildMonitorPicker {
  for (UIButton *b in _monitorPeerButtons) [b removeFromSuperview];
  [_monitorPeerButtons removeAllObjects];
  NSInteger idx = 0;
  for (NSDictionary *peer in _doorPeers) {
    NSString *name = [DBConfigUtil evStr:peer key:@"name"];
    if ([name length] == 0) name = [DBConfigUtil evStr:peer key:@"id"];
    NSString *door = [DBConfigUtil evStr:peer key:@"door_label"];
    NSString *title = [door length] > 0
        ? [NSString stringWithFormat:@"%@  ·  %@", name, door] : name;
    UIButton *b = [self buttonWithTitle:title font:24 color:[UIColor whiteColor]
                                      bg:[UIColor colorWithRed:0.10 green:0.42 blue:0.72 alpha:1]];
    b.layer.cornerRadius = 12;
    b.tag = idx++;
    [b addTarget:self action:@selector(onMonitorPeer:) forControlEvents:UIControlEventTouchUpInside];
    [_monitorPickerList addSubview:b];
    [_monitorPeerButtons addObject:b];
  }
  _monitorButton.enabled = ([_doorPeers count] > 0);
  _monitorButton.alpha = _monitorButton.enabled ? 1.0 : 0.35;
  [self setNeedsLayout];
}

- (void)onMonitorList {
  if ([_doorPeers count] == 0) return;
  _monitorPicker.hidden = NO;
  [self bringSubviewToFront:_monitorPicker];
  [self setNeedsLayout];
}

- (void)onMonitorPeer:(UIButton *)sender {
  NSInteger idx = sender.tag;
  if (idx < 0 || idx >= (NSInteger)[_doorPeers count]) return;
  NSDictionary *peer = [_doorPeers objectAtIndex:(NSUInteger)idx];
  _monitorPicker.hidden = YES;
  [_router showMonitorPeer:peer];
}

- (void)onMonitorPickerCancel {
  _monitorPicker.hidden = YES;
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
      [cal components:(NSHourCalendarUnit | NSMinuteCalendarUnit | NSSecondCalendarUnit)
             fromDate:[NSDate date]];
  NSString *line = [NSString stringWithFormat:@"%02ld:%02ld:%02ld  %@ %@", (long)c.hour,
                    (long)c.minute, (long)c.second, type, door];
  [_events insertObject:line atIndex:0];
  while ([_events count] > 8) [_events removeLastObject];
  _eventsLabel.text = [_events componentsJoinedByString:@"\n"];
}


- (NSString *)themeValue:(NSString *)leaf {
  if ([_nodeId length] > 0) {
    NSString *v =
        [DBConfigUtil str:_cfg path:[NSString stringWithFormat:@"devices.%@.local.theme.%@", _nodeId, leaf]];
    if (v) return v;
  }
  return [DBConfigUtil str:_cfg path:[NSString stringWithFormat:@"display.theme.%@", leaf]];
}

- (void)applyTheme {
  if (_safeMode) {
    _themeHash = nil;
    _themeBg.image = nil;
    _themeBg.hidden = YES;
    self.backgroundColor = DBBg();
    return;
  }
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

- (NSDictionary *)styleForSemanticID:(NSString *)semanticID
                            foreground:(UIColor *)foreground
                            background:(UIColor *)background
                                safety:(BOOL)safety {
  return [DBSemanticStyle styleForConfig:_cfg deviceID:_nodeId semanticID:semanticID
                          safetyCritical:safety baselineForeground:foreground
                      baselineBackground:background baselineAccent:nil baselineBorder:nil];
}

- (void)applySemanticStyles {
  UIColor *white = [UIColor whiteColor];
  UIColor *red = [UIColor colorWithRed:0.78 green:0.08 blue:0.06 alpha:1];
  NSDictionary *trigger = [self styleForSemanticID:@"sos.trigger" foreground:white
                                         background:red safety:YES];
  [DBSemanticStyle applyButton:_sosButton style:trigger foreground:white background:red
                        border:nil radius:14 fontSize:24];

  UIColor *darkRed = [UIColor colorWithRed:0.55 green:0.05 blue:0.04 alpha:1];
  NSDictionary *cancel = [self styleForSemanticID:@"sos.cancel" foreground:darkRed
                                        background:white safety:YES];
  [DBSemanticStyle applyButton:_emergencyCancel style:cancel foreground:darkRed background:white
                        border:nil radius:14 fontSize:26];

  UIColor *neutral = [UIColor colorWithRed:0.17 green:0.18 blue:0.20 alpha:1];
  NSDictionary *monitorClose = [self styleForSemanticID:@"monitor.close" foreground:white
                                              background:neutral safety:YES];
  [DBSemanticStyle applyButton:_monitorCancel style:monitorClose foreground:white
                    background:[UIColor colorWithWhite:1 alpha:0.14]
                        border:nil radius:12 fontSize:22];
}


- (void)loadThemeImage:(NSString *)hash {
  NSString *urlStr =
      [NSString stringWithFormat:@"http://127.0.0.1:%ld/asset/%@", (long)_boot.httpPort, hash];
  NSURL *url = [NSURL URLWithString:urlStr];
  if (url == nil) return;
  NSString *want = [hash copy];
  __weak DBHomeScreen *wself = self;
  NSURLRequest *req = [NSURLRequest requestWithURL:url];
  [NSURLConnection sendAsynchronousRequest:req
                                     queue:[NSOperationQueue mainQueue]
                         completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
    (void)err;
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
    (void)[_core emergency:YES];
  }
}

- (void)resetSosHold {
  _sosHolding = NO;
  [_sosTimer invalidate];
  _sosTimer = nil;
  _sosProgress.progress = 0;
}



- (void)showEmergencyEvent:(NSDictionary *)ev {
  _emergencyActive = YES;
  _replyBanner.hidden = YES;
  NSDictionary *palette = [DBConfigUtil emergencyPalette:ev];
  _emergencyView.backgroundColor = [palette objectForKey:@"background"];
  _emergencyTitle.textColor = [palette objectForKey:@"foreground"];
  _emergencyNote.textColor = [palette objectForKey:@"foreground"];
  _emergencyCancel.backgroundColor = [palette objectForKey:@"accent"];
  [_emergencyCancel setTitleColor:[palette objectForKey:@"accent_foreground"]
                         forState:UIControlStateNormal];
  id visualValue = [ev objectForKey:@"visual"];
  BOOL visual = ![visualValue isKindOfClass:[NSNumber class]] || [visualValue boolValue];
  _emergencyView.hidden = !visual;
  if (visual) {
    [self bringSubviewToFront:_emergencyView];
    [self setBrightness:100];
  }
  NSString *sound = [DBConfigUtil evStr:ev key:@"alarm_sound"];
  NSString *path = [DBConfigUtil evStr:ev key:@"audio_path"];
  NSInteger volume = [DBConfigUtil intVal:ev path:@"alarm_volume" def:100];
  if (([sound length] > 0 || [path length] > 0) && volume > 0) {
    [_audio startSiren:[DBConfigUtil evStr:ev key:@"audio_path"]
                volume:volume];
  } else {
    [_audio stop];
  }
}

- (void)hideEmergencyEvent:(NSDictionary *)ev {
  (void)ev;
  _emergencyActive = NO;
  [_audio stop];
  _emergencyView.hidden = YES;
  [self applyDisplay];
}

- (void)enterSafeMode {
  _safeMode = YES;
  _themeHash = nil;
  _themeBg.image = nil;
  _themeBg.hidden = YES;
  self.backgroundColor = DBBg();
}

- (void)exitSafeMode {
  if (!_safeMode) return;
  _safeMode = NO;
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
  if ([_core emergency:NO]) [self hideEmergencyEvent:nil];
}



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
