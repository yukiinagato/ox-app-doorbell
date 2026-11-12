#import "DBHomeScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBCallHistoryModel.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBDoorTileModel.h"
#import "../Core/DBFrostedBlur.h"
#import "../Core/DBFleetCounts.h"
#import "../Core/DBHomeLayout.h"
#import "../Core/DBNoticeModel.h"
#import "../Core/DBPairingModel.h"
#import "../Core/DBRefreshCoalescer.h"
#import "../Core/DBSemanticStyle.h"
#import "../Core/DBTexts.h"
#import "../Core/DBUiTheme.h"
#import "../Media/DBSiren.h"
#import "DBChrome.h"
#import "DBNoticeDialog.h"
#import "DBRouter.h"
#import "DBSosPanel.h"
#import "DBWidgets.h"
#import <AudioToolbox/AudioToolbox.h>

static CGRect DBRectFromArray(NSArray *rect) {
  if ([rect count] != 4) return CGRectZero;
  return CGRectMake((CGFloat)[[rect objectAtIndex:0] doubleValue],
                    (CGFloat)[[rect objectAtIndex:1] doubleValue],
                    (CGFloat)[[rect objectAtIndex:2] doubleValue],
                    (CGFloat)[[rect objectAtIndex:3] doubleValue]);
}

@interface DBFrostedPlateView : UIView
- (void)setBackdrop:(UIImage *)backdrop sourceFrame:(CGRect)sourceFrame
         canvasSize:(CGSize)canvasSize tint:(UIColor *)tint border:(UIColor *)border;
@end

@implementation DBFrostedPlateView {
  UIImage *_backdrop;
  CGRect _sourceFrame;
  CGSize _canvasSize;
  UIColor *_tint;
}

- (void)setBackdrop:(UIImage *)backdrop sourceFrame:(CGRect)sourceFrame
         canvasSize:(CGSize)canvasSize tint:(UIColor *)tint border:(UIColor *)border {
  _backdrop = backdrop;
  _sourceFrame = sourceFrame;
  _canvasSize = canvasSize;
  _tint = tint;
  self.layer.borderWidth = 0.5;
  self.layer.borderColor = border.CGColor;
  [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
  (void)rect;
  if (_backdrop && _sourceFrame.size.width > 0 && _sourceFrame.size.height > 0 &&
      _canvasSize.width > 0 && _canvasSize.height > 0) {
    CGFloat sx = self.bounds.size.width / _sourceFrame.size.width;
    CGFloat sy = self.bounds.size.height / _sourceFrame.size.height;
    [_backdrop drawInRect:CGRectMake(-_sourceFrame.origin.x * sx,
                                     -_sourceFrame.origin.y * sy,
                                     _canvasSize.width * sx, _canvasSize.height * sy)];
  }
  [_tint setFill];
  UIRectFillUsingBlendMode(self.bounds, kCGBlendModeNormal);
}

@end

static const NSTimeInterval kSnapshotIntervalS = 5.0;
// Safe mode keeps the door picture, smaller and less often. It is already the
// bounded low-resolution snapshot the safe-mode contract asks for, and a panel
// latched in safe mode for hours must not sit in front of a black door tile.
static const CGFloat kSnapshotMaxSide = 320;
static const CGFloat kSafeModeSnapshotMaxSide = 160;
static const NSInteger kSafeModeSnapshotEveryNTicks = 3;
// The dashboard reads the call log only for its unread missed-call count.
static const NSInteger kMissedScanLimit = 20;

// One door tile: a five-second still, the door label, and the announcement mark. The caption
// and the mark are plates over the picture, which is custom content, not stock chrome.
@interface DBDoorTile : UIButton
// Stable identity across status polls, so a tile is created once per door. The
// door id is that identity: a door outlives the station serving it, and keying
// on the peer threw the still away every time the serving node changed.
@property(nonatomic, copy) NSString *doorId;
@property(nonatomic, strong) NSDictionary *peer;
@property(nonatomic, copy) NSString *snapshotURL;
@property(nonatomic, copy) NSString *videoMetaURL;
@property(nonatomic) NSInteger videoRotation;
@property(nonatomic) BOOL online;
@property(nonatomic, readonly) UIImageView *still;
@property(nonatomic, readonly) DBPillLabel *caption;
@property(nonatomic, readonly) DBPillLabel *noticeChip;
@property(nonatomic, readonly) UILabel *offlineLabel;
@end

@implementation DBDoorTile {
  UIImageView *_still;
  DBPillLabel *_caption;
  DBPillLabel *_noticeChip;
  UILabel *_offlineLabel;
}

@synthesize doorId = _doorId, peer = _peer, snapshotURL = _snapshotURL, online = _online,
            still = _still, caption = _caption, noticeChip = _noticeChip,
            offlineLabel = _offlineLabel;

- (id)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.layer.cornerRadius = 12;
    self.clipsToBounds = YES;
    _still = [[UIImageView alloc] init];
    _still.contentMode = UIViewContentModeScaleAspectFill;
    _still.clipsToBounds = YES;
    _still.userInteractionEnabled = NO;
    _still.backgroundColor = [UIColor blackColor];
    [self addSubview:_still];
    _offlineLabel = [[UILabel alloc] init];
    _offlineLabel.backgroundColor = [UIColor clearColor];
    _offlineLabel.textAlignment = NSTextAlignmentCenter;
    _offlineLabel.font = [UIFont systemFontOfSize:19];
    _offlineLabel.userInteractionEnabled = NO;
    [self addSubview:_offlineLabel];
    _caption = [[DBPillLabel alloc] initWithFrame:CGRectZero];
    _caption.font = [UIFont boldSystemFontOfSize:22];
    _caption.userInteractionEnabled = NO;
    [self addSubview:_caption];
    _noticeChip = [[DBPillLabel alloc] initWithFrame:CGRectZero];
    _noticeChip.font = [UIFont boldSystemFontOfSize:16];
    _noticeChip.userInteractionEnabled = NO;
    _noticeChip.hidden = YES;
    [self addSubview:_noticeChip];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  _still.frame = self.bounds;
  _offlineLabel.frame = CGRectMake(0, size.height / 2 - 12, size.width, 24);
  CGSize captionFit = [_caption sizeThatFits:CGSizeMake(size.width - 16, 32)];
  _caption.frame = CGRectMake(8, size.height - 40, MIN(size.width - 16, captionFit.width), 32);
  CGSize chipFit = [_noticeChip sizeThatFits:CGSizeMake(size.width - 16, 30)];
  _noticeChip.frame = CGRectMake(8, 8, MIN(size.width - 16, chipFit.width), 30);
}

@end

@interface DBHomeScreen () <DBSosSliderDelegate, UIActionSheetDelegate>
@end

@implementation DBHomeScreen {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  DBSiren *_audio;
  DBUiPalette *_palette;
  DBNoticeDialog *_noticeDialog;

  NSDictionary *_cfg;
  NSDictionary *_status;
  NSDictionary *_display;   // status.display: core-resolved appearance and theme.
  NSString *_nodeId;
  NSString *_themeHash;
  NSString *_themeAverageHex;   // Whole-image average, the fallback background.
  NSString *_themeFallbackReason;   // Why the picture is not on screen.
  NSDictionary *_themeOverlay;      // The scrim the picture was prepared with.
  UIImage *_themeImage;
  DBBackgroundSampler *_sampler;   // Per-region sampling of the theme image.
  CGSize _samplerSize;
  CGSize _themeImageSize;
  BOOL _samplerBuilding;
  NSArray *_doorTileInfos;
  NSInteger _unreadMissed;
  NSInteger _tzOffsetMinutes;
  NSString *_pairingState;

  NSInteger _brightness;
  BOOL _night;
  BOOL _redTint;
  BOOL _emergencyActive;
  BOOL _safeMode;
  BOOL _cancelRequiresPin;

  NSTimer *_clockTimer;
  NSTimer *_replyTimer;
  NSTimer *_snapshotTimer;
  NSTimer *_peersTimer;
  NSInteger _snapshotGeneration;
  NSInteger _snapshotTick;
  NSInteger _previewPage;
  NSMutableArray *_previewPriorityDoors;

  dispatch_queue_t _refreshQueue;
  DBRefreshCoalescer *_refreshGate;
  BOOL _screenVisible;
  BOOL _callRefreshPending;

  DBNavBar *_nav;
  DBHomeTabs *_tabs;
  UIBarButtonItem *_noticeItem;
  UIBarButtonItem *_monitorItem;
  UIBarButtonItem *_addDeviceItem;
  UIActionSheet *_monitorSheet;
  NSArray *_monitorSheetPeers;
  UIImageView *_themeBg;
  UIImage *_themeGlassImage;
  NSUInteger _themeGlassRadius;
  UIView *_footerScrim;    // Readability plate under the QR block and version line.
  UILabel *_clockLabel;
  UILabel *_dateLabel;
  NSArray *_fleetCounters;   // Three DBFleetCounter, left to right.
  UIButton *_pairBanner;
  UIButton *_missedNotice;
  UIButton *_doorsPager;
  UILabel *_noDoorsLabel;
  NSMutableArray *_doorTiles;
  DBAdminQrView *_qr;
  DBSosSlider *_sos;        // Lives inside the confirmation panel, never on the dashboard.
  DBSosPanel *_sosPanel;
  UIButton *_sosButton;
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
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _router = router;
    _core = router.core;
    _boot = router.boot;
    _texts = router.texts;
    _audio = [[DBSiren alloc] init];
    _doorTileInfos = [NSArray array];
    _doorTiles = [[NSMutableArray alloc] init];
    _previewPriorityDoors = [[NSMutableArray alloc] init];
    _nodeId = @"";
    _brightness = 70;
    _cancelRequiresPin = YES;
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

- (void)buildUi {
  _themeBg = [[UIImageView alloc] init];
  _themeBg.contentMode = UIViewContentModeScaleAspectFill;
  _themeBg.opaque = YES;
  _themeBg.clipsToBounds = YES;
  _themeBg.hidden = YES;
  [self addSubview:_themeBg];
  // The footer's small text sits on a plate over the picture; the recent calls are stock
  // grouped cells, which are their own card.
  _footerScrim = [self newScrimView];

  _clockLabel = [[DBReadableLabel alloc] init];
  _clockLabel.backgroundColor = [UIColor clearColor];
  _clockLabel.adjustsFontSizeToFitWidth = YES;
  [self addSubview:_clockLabel];

  _dateLabel = [[DBReadableLabel alloc] init];
  _dateLabel.backgroundColor = [UIColor clearColor];
  _dateLabel.adjustsFontSizeToFitWidth = YES;
  [self addSubview:_dateLabel];

  NSMutableArray *counters = [NSMutableArray array];
  DBFleetGlyph glyphs[3] = { DBFleetGlyphCluster, DBFleetGlyphDoorStation,
                             DBFleetGlyphIndoorPanel };
  for (NSUInteger i = 0; i < 3; i++) {
    DBFleetCounter *counter = [[DBFleetCounter alloc] initWithFrame:CGRectZero];
    counter.glyph = glyphs[i];
    counter.userInteractionEnabled = NO;
    [self addSubview:counter];
    [counters addObject:counter];
  }
  _fleetCounters = counters;

  _pairBanner = DBChromeButton(@"", 19);
  if (DBChromeIsFlat()) {
    // The flat system button is bare text, which a wallpaper can swallow; it gets a card.
    _pairBanner.backgroundColor = [UIColor whiteColor];
    _pairBanner.layer.cornerRadius = 8;
  }
  _pairBanner.hidden = YES;
  [_pairBanner addTarget:self action:@selector(onPairBanner)
        forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_pairBanner];

  // Unread missed calls: one notice that opens the History tab, where they are listed.
  _missedNotice = DBChromeButton(@"", 19);
  _missedNotice.hidden = YES;
  [_missedNotice addTarget:self action:@selector(onHistory)
          forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_missedNotice];

  // Shown only when the doors need more than one preview page.
  _doorsPager = DBChromeButton(@"", 17);
  _doorsPager.hidden = YES;
  [_doorsPager addTarget:self action:@selector(onNextDoorPreviewPage)
        forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_doorsPager];
  if (DBChromeIsFlat()) {
    for (UIButton *button in [NSArray arrayWithObjects:_missedNotice, _doorsPager, nil]) {
      button.backgroundColor = [UIColor whiteColor];
      button.layer.cornerRadius = 8;
    }
  }

  _noDoorsLabel = [[DBReadableLabel alloc] init];
  _noDoorsLabel.backgroundColor = [UIColor clearColor];
  _noDoorsLabel.font = [UIFont systemFontOfSize:24];
  _noDoorsLabel.textAlignment = NSTextAlignmentCenter;
  _noDoorsLabel.numberOfLines = 0;
  _noDoorsLabel.hidden = YES;
  [self addSubview:_noDoorsLabel];

  _qr = [[DBAdminQrView alloc] initWithFrame:CGRectZero];
  [self addSubview:_qr];

  _sos = [[DBSosSlider alloc] initWithFrame:CGRectZero];
  _sosPanel = [[DBSosPanel alloc] initWithSlider:_sos delegate:self];
  _sosButton = DBSosTriggerButton();
  _sosButton.accessibilityIdentifier = @"home_sos_open";
  _sosButton.hidden = YES;
  [_sosButton addTarget:self action:@selector(onSosButton)
       forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_sosButton];

  _nav = [[DBNavBar alloc] init];
  [self addSubview:_nav.bar];
  _tabs = [[DBHomeTabs alloc] initWithRouter:_router tab:DBHomeTabHome];
  [self addSubview:_tabs.bar];
  _noticeItem = DBChromeBarItem(@"", self, @selector(onGlobalNotice));
  _monitorItem = DBChromeBarItem(@"", self, @selector(onMonitor));
  _addDeviceItem = DBChromeSystemBarItem(UIBarButtonSystemItemAdd, self, @selector(onMembership));
  UINavigationItem *item = [_nav setRootTitle:@"" backTitle:nil onBack:nil];
  item.leftBarButtonItem = _noticeItem;
  item.rightBarButtonItems = [NSArray arrayWithObjects:_addDeviceItem, _monitorItem, nil];

  _nightTint = [[UIView alloc] init];
  _nightTint.backgroundColor = [UIColor colorWithRed:0.55 green:0.0 blue:0.0 alpha:0.35];
  _nightTint.userInteractionEnabled = NO;
  _nightTint.hidden = YES;
  [self addSubview:_nightTint];

  [self buildReplyBanner];
  [self buildOfflineView];
  [self buildEmergencyView];

  [self applyPalette];
}

- (void)buildReplyBanner {
  _replyBanner = [[UIView alloc] init];
  _replyBanner.backgroundColor = [UIColor colorWithRed:0.11 green:0.30 blue:0.16 alpha:0.97];
  _replyBanner.layer.cornerRadius = 16;
  _replyBanner.hidden = YES;
  [self addSubview:_replyBanner];
  _replyCaption = [[UILabel alloc] init];
  _replyCaption.backgroundColor = [UIColor clearColor];
  _replyCaption.font = [UIFont systemFontOfSize:18];
  _replyCaption.textColor = [UIColor colorWithWhite:1 alpha:0.7];
  _replyCaption.textAlignment = NSTextAlignmentCenter;
  [_replyBanner addSubview:_replyCaption];
  _replyText = [[UILabel alloc] init];
  _replyText.backgroundColor = [UIColor clearColor];
  _replyText.font = [UIFont boldSystemFontOfSize:32];
  _replyText.textColor = [UIColor whiteColor];
  _replyText.numberOfLines = 0;
  _replyText.textAlignment = NSTextAlignmentCenter;
  [_replyBanner addSubview:_replyText];
}

- (void)buildOfflineView {
  _offlineView = [[UIView alloc] init];
  _offlineView.hidden = YES;
  [self addSubview:_offlineView];
  _offlineTitle = [[UILabel alloc] init];
  _offlineTitle.backgroundColor = [UIColor clearColor];
  _offlineTitle.font = [UIFont boldSystemFontOfSize:34];
  _offlineTitle.textAlignment = NSTextAlignmentCenter;
  [_offlineView addSubview:_offlineTitle];
  _offlineBody = [[UILabel alloc] init];
  _offlineBody.backgroundColor = [UIColor clearColor];
  _offlineBody.font = [UIFont systemFontOfSize:22];
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
  _emergencyTitle.backgroundColor = [UIColor clearColor];
  _emergencyTitle.font = [UIFont boldSystemFontOfSize:64];
  _emergencyTitle.textColor = [UIColor whiteColor];
  _emergencyTitle.textAlignment = NSTextAlignmentCenter;
  [_emergencyView addSubview:_emergencyTitle];
  _emergencyNote = [[UILabel alloc] init];
  _emergencyNote.backgroundColor = [UIColor clearColor];
  _emergencyNote.font = [UIFont systemFontOfSize:26];
  _emergencyNote.textColor = [UIColor colorWithWhite:1 alpha:0.85];
  _emergencyNote.textAlignment = NSTextAlignmentCenter;
  _emergencyNote.numberOfLines = 0;
  [_emergencyView addSubview:_emergencyNote];
  _emergencyCancel = DBChromeFilledButton(26);
  [_emergencyCancel setTitleColor:[UIColor colorWithRed:0.55 green:0.05 blue:0.04 alpha:1]
                         forState:UIControlStateNormal];
  _emergencyCancel.backgroundColor = [UIColor whiteColor];
  [_emergencyCancel addTarget:self action:@selector(onEmergencyCancel)
             forControlEvents:UIControlEventTouchUpInside];
  [_emergencyView addSubview:_emergencyCancel];
}

#pragma mark - lifecycle

- (void)onScreenWillAppear {
  _screenVisible = YES;
  [_tabs syncSelection];
  if (!_clockTimer) {
    _clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                 selector:@selector(updateClock)
                                                 userInfo:nil repeats:YES];
  }
  if (!_peersTimer) {
    // Membership changes are event driven, but a coalesced event must never
    // leave a joined door station invisible. This slow poll bounds that to 5 s.
    _peersTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self
                                                 selector:@selector(refreshFromCore)
                                                 userInfo:nil repeats:YES];
  }
  if (!_snapshotTimer) {
    _snapshotTimer = [NSTimer scheduledTimerWithTimeInterval:kSnapshotIntervalS target:self
                                                    selector:@selector(refreshSnapshots)
                                                    userInfo:nil repeats:YES];
  }
  [self updateClock];
  [self refreshFromCore];
  [self refreshSnapshots];
}

- (void)onScreenWillDisappear {
  _screenVisible = NO;
  // A hidden home screen draws nothing; its clock restarts on the next appearance, which also
  // repaints the time immediately. An A4 iPad 1 has no CPU to spare for invisible ticks.
  [_clockTimer invalidate];
  _clockTimer = nil;
  [_peersTimer invalidate];
  _peersTimer = nil;
  // Stills are pure decoration: never keep polling five-second JPEGs behind a
  // live call on an A4 device.
  [_snapshotTimer invalidate];
  _snapshotTimer = nil;
  ++_snapshotGeneration;
  [_noticeDialog dismiss];
  [_sosPanel dismiss];
  [_monitorSheet dismissWithClickedButtonIndex:_monitorSheet.cancelButtonIndex animated:NO];
  _monitorSheet = nil;
}

- (void)dealloc {
  [_peersTimer invalidate];
  [_clockTimer invalidate];
  [_replyTimer invalidate];
  [_snapshotTimer invalidate];
}

#pragma mark - clock

// Every clock is rendered from Core's local-time document, so the kiosk needs
// no operating-system time-zone database and follows the cluster zone and the
// NTP correction exactly like every other shell.
- (void)updateClock {
  NSDictionary *local = [_core cachedLocalTime];
  if (![local isKindOfClass:[NSDictionary class]]) return;
  NSInteger hh = [DBConfigUtil intVal:local path:@"hh" def:-1];
  if (hh < 0) return;
  _clockLabel.text = [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)hh,
                      (long)[DBConfigUtil intVal:local path:@"mm" def:0],
                      (long)[DBConfigUtil intVal:local path:@"ss" def:0]];
  _tzOffsetMinutes = [DBConfigUtil intVal:local path:@"offset_min" def:_tzOffsetMinutes];

  NSString *date = [DBConfigUtil str:local path:@"date"];
  NSArray *parts = [date componentsSeparatedByString:@"-"];
  if ([parts count] == 3) {
    NSArray *weekdayKeys = [NSArray arrayWithObjects:@"day.sun", @"day.mon", @"day.tue",
        @"day.wed", @"day.thu", @"day.fri", @"day.sat", nil];
    NSInteger weekday = [DBConfigUtil intVal:local path:@"weekday_num" def:0];
    if (weekday < 0 || weekday > 6) weekday = 0;
    _dateLabel.text = [_texts t:@"date.full",
        [NSNumber numberWithInteger:[[parts objectAtIndex:0] integerValue]],
        [NSNumber numberWithInteger:[[parts objectAtIndex:1] integerValue]],
        [NSNumber numberWithInteger:[[parts objectAtIndex:2] integerValue]],
        [_texts ts:[weekdayKeys objectAtIndex:(NSUInteger)weekday]], nil];
  }
}

#pragma mark - core snapshot

- (void)refreshFromCore {
  if (!_screenVisible) return;
  if (![_refreshGate beginRefresh]) return;
  DBCoreBridge *core = _core;
  __weak DBHomeScreen *weakSelf = self;
  dispatch_async(_refreshQueue, ^{
    NSDictionary *cfg = [core config];
    NSDictionary *status = [core status];
    NSDictionary *pairing = [core pairingInfo];
    NSDictionary *log = [core callLogSince:0 limit:kMissedScanLimit];
    NSDictionary *localTime = [core localTimeJson:0];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBHomeScreen *screen = weakSelf;
      if (!screen) return;
      BOOL again = [screen->_refreshGate endRefresh];
      if (!screen->_screenVisible) return;
      screen->_tzOffsetMinutes = [DBConfigUtil intVal:localTime path:@"offset_min"
                                                  def:screen->_tzOffsetMinutes];
      [screen applyCoreSnapshotWithConfig:cfg status:status log:log];
      [screen applyPairingSnapshot:pairing];
      if (again) [screen refreshFromCore];
    });
  });
}

- (void)applyCoreSnapshotWithConfig:(NSDictionary *)cfg status:(NSDictionary *)status
                                log:(NSDictionary *)log {
  if (cfg) {
    _cfg = cfg;
    [_texts setConfig:_cfg];
    [_texts setLang:_boot.uiLang];
  }
  if (status) {
    _status = status;
    _nodeId = [DBConfigUtil str:status path:@"node.id"] ?: @"";
    _doorTileInfos = [DBDoorTileModel tilesFromStatus:status config:_cfg boot:_boot];
    [self updateFleetCounters];
    NSDictionary *display = [status objectForKey:@"display"];
    if ([display isKindOfClass:[NSDictionary class]]) {
      _display = display;
      [self applyDisplayEvent:display];
    }
  }
  if (log) {
    _unreadMissed = [DBCallHistoryModel unreadMissedFromLog:log];
  }
  // Core computes this as emergency.cancel_requires_pin AND a password
  // actually being set: an unset password must never stand between a household
  // and a running alarm, so the raw config flag is not the gate.
  _cancelRequiresPin = [DBConfigUtil boolVal:_status
      path:@"emergency.cancel_requires_password"
       def:[DBConfigUtil boolVal:_cfg path:@"emergency.cancel_requires_pin" def:YES]];
  [self applyPalette];
  [self applyTheme];
  [self applyStrings];
  [self rebuildDoorTiles];
  [self updateFooter];
  [self refreshSosVisibility];
  _offlineView.hidden = _core.isRunning;
  [self setNeedsLayout];
}

- (void)applyPairingSnapshot:(NSDictionary *)pairing {
  NSString *state = [DBPairingModel stateFromPairingInfo:pairing];
  if (![state isEqualToString:DBPairingStateUnknown]) _pairingState = state;
  BOOL ready = [_pairingState isEqualToString:@"ready"];
  BOOL showBanner = !ready && ![_pairingState isEqualToString:DBPairingStateUnknown];
  [_pairBanner setTitle:[_texts ts:@"pair.not_set_up_banner"] forState:UIControlStateNormal];
  _pairBanner.hidden = !showBanner;
  [self setNeedsLayout];
}

#pragma mark - appearance

- (NSInteger)minuteOfDay {
  NSArray *parts = [_clockLabel.text componentsSeparatedByString:@":"];
  if ([parts count] < 2) return 12 * 60;
  return [[parts objectAtIndex:0] integerValue] * 60 + [[parts objectAtIndex:1] integerValue];
}

- (NSString *)themeValue:(NSString *)leaf {
  if ([_nodeId length] > 0) {
    NSString *value = [DBConfigUtil str:_cfg path:[NSString stringWithFormat:
        @"devices.%@.local.theme.%@", _nodeId, leaf]];
    if (value) return value;
  }
  return [DBConfigUtil str:_cfg path:[NSString stringWithFormat:@"display.theme.%@", leaf]];
}

- (void)applyPalette {
  // The ink rule samples the effective background: the theme image's average
  // when one is loaded, otherwise the theme colour, otherwise the mode surface.
  NSString *background = _themeAverageHex ?: [self themeValue:@"bg_color"];
  _palette = [DBUiPalette paletteForConfig:_cfg deviceId:_nodeId display:_display
                             backgroundHex:background minuteOfDay:[self minuteOfDay]];
  if (_themeBg.hidden) {
    [_palette setRenderedFlatBackgroundHex:_safeMode ? nil : [self themeValue:@"bg_color"]];
    self.backgroundColor = _palette.surface;
  }

  // The per-region colours are applied after layout, when each label's frame is
  // known; this only refreshes what does not depend on geometry.
  [_palette setBackgroundSampler:_themeBg.hidden ? nil : _sampler];
  [self applyRegionInk];

  [_qr applyPalette:_palette];
  [_sos applyPalette:_palette];
  [_sos applyConfig:_cfg texts:_texts];
  [_sosPanel applyTexts:_texts];
  _offlineView.backgroundColor = _palette.surface;
  _offlineTitle.textColor = _palette.ink;
  _offlineBody.textColor = _palette.mutedInk;
  [self applyScrimTone];
}

// The footer plate: frosted wallpaper under a tint of the surface colour, so the address and
// version line keep a stable ground. It never takes touches from the controls above it.
- (UIView *)newScrimView {
  UIView *scrim = [[DBFrostedPlateView alloc] initWithFrame:CGRectZero];
  scrim.layer.cornerRadius = 12;
  scrim.clipsToBounds = YES;
  scrim.userInteractionEnabled = NO;
  scrim.hidden = YES;
  [self insertSubview:scrim aboveSubview:_themeBg];
  return scrim;
}

static const CGFloat kFooterGlassAlpha = 0.65;

// The plate exists only over a picture; on a flat ground it would be a visible rectangle of
// very slightly different colour for no benefit.
- (void)applyScrimTone {
  BOOL overPicture = !_themeBg.hidden && _themeBg.image != nil;
  _footerScrim.backgroundColor = [UIColor clearColor];
  _footerScrim.hidden = !overPicture;
}

// Why the dashboard is on a flat ground rather than the theme picture. The two
// answers look identical on screen and are entirely different faults, so the
// panel says which one it is exactly once per transition.
- (void)noteThemeFallback:(NSString *)reason {
  if ([_themeFallbackReason isEqualToString:reason]) return;
  _themeFallbackReason = [reason copy];
  if ([reason length] > 0)
    NSLog(@"[doorbell] dashboard is on the flat auto background: %@", reason);
}

- (void)applyTheme {
  if (_safeMode) {
    // Safe mode disables custom visuals by contract; the picture is one.
    [self noteThemeFallback:@"safe_mode"];
    _themeHash = nil;
    _themeAverageHex = nil;
    _themeImage = nil;
    _themeGlassImage = nil;
    _themeBg.image = nil;
    _themeBg.hidden = YES;
    [self refreshBackgroundSampler];
    [self applyPalette];
    [self applyScrimTone];
    return;
  }
  NSString *hash = [self themeValue:@"bg_image"];
  if ([hash length] == 0) {
    [self noteThemeFallback:@"no_theme_image_configured"];
    _themeHash = nil;
    _themeAverageHex = nil;
    _themeImage = nil;
    _themeGlassImage = nil;
    _themeBg.image = nil;
    _themeBg.hidden = YES;
    [self refreshBackgroundSampler];
    [self applyPalette];
    [self applyScrimTone];
    return;
  }
  self.backgroundColor = _palette.surface;
  [self applyScrimTone];
  NSDictionary *overlay = [DBUiTheme backdropOverlayForConfig:_cfg deviceId:_nodeId
                                                      display:_display];
  NSUInteger glassRadius = [DBUiTheme frostedGlassRadiusForConfig:_cfg deviceId:_nodeId
                                                           display:_display];
  BOOL sameOverlay = [_themeOverlay isEqualToDictionary:overlay];
  if ([_themeHash isEqualToString:hash] && _themeBg.image != nil && sameOverlay &&
      _themeGlassRadius == glassRadius) return;
  _themeOverlay = overlay;
  _themeGlassRadius = glassRadius;
  _themeHash = hash;
  [self loadThemeImage:hash];
}

- (void)loadThemeImage:(NSString *)hash {
  NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:%ld/asset/%@",
                         (long)_boot.httpPort, hash];
  NSURL *url = [NSURL URLWithString:urlString];
  if (url == nil) return;
  NSString *want = [hash copy];
  CGSize size = self.bounds.size;
  // The administrator's overlay, resolved before the hop off the main thread so
  // the worker reads no shared state.
  NSDictionary *overlay = [DBUiTheme backdropOverlayForConfig:_cfg deviceId:_nodeId
                                                      display:_display];
  NSUInteger glassRadius = [DBUiTheme frostedGlassRadiusForConfig:_cfg deviceId:_nodeId
                                                           display:_display];
  __weak DBHomeScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
    // One decode, at panel size, darkened once and cached per picture and
    // size; the sampler then measures the very pixels that are on screen.
    UIImage *backdrop = [DBThemeBackdrop cachedBackdropForKey:want size:size
                                                      overlay:overlay];
    NSData *data = nil;
    if (backdrop == nil) {
      data = [NSData dataWithContentsOfURL:url];
      backdrop = [DBThemeBackdrop backdropForData:data key:want size:size overlay:overlay];
    }
    BOOL usedGPU = NO;
    UIImage *glass = [DBFrostedBlur blurredImage:backdrop radius:glassRadius usedGPU:&usedGPU];
    if (backdrop && !glass) glass = backdrop;
    NSString *average = [DBUiPalette averageHexForImage:backdrop];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBHomeScreen *screen = weakSelf;
      if (!screen || ![screen->_themeHash isEqualToString:want] ||
          screen->_themeGlassRadius != glassRadius ||
          ![screen->_themeOverlay isEqualToDictionary:overlay] ||
          !CGSizeEqualToSize(screen.bounds.size, size)) return;
      [screen noteThemeFallback:(backdrop != nil) ? @""
          : ([data length] == 0 ? @"theme_asset_fetch_failed" : @"theme_asset_decode_failed")];
      screen->_themeBg.image = backdrop;
      screen->_themeBg.hidden = (backdrop == nil);
      screen->_themeAverageHex = average;
      screen->_themeImage = backdrop;
      screen->_themeGlassImage = glass;
      screen->_themeGlassRadius = glassRadius;
      if (glass) NSLog(@"[doorbell] frosted glass radius=%lu renderer=%@",
                       (unsigned long)glassRadius, usedGPU ? @"gpu" : @"cpu");
      screen->_themeImageSize = size;
      screen->_samplerSize = CGSizeZero;
      [screen refreshBackgroundSampler];
      [screen applyPalette];
      [screen rebuildDoorTiles];
    });
  });
}

#pragma mark - content

- (void)applyStrings {
  _replyCaption.text = [_texts ts:@"reply.banner"];
  _offlineTitle.text = [_texts ts:@"offline.title"];
  _offlineBody.text = [_texts ts:@"offline.body"];
  _emergencyTitle.text = [_texts ts:@"emergency.title"];
  _emergencyNote.text = [_texts ts:@"emergency.notified"];
  [_emergencyCancel setTitle:[_texts ts:@"emergency.cancel"] forState:UIControlStateNormal];
  _noDoorsLabel.text = [_texts ts:@"dash.no_doors"];
  [_missedNotice setTitle:[_texts t:@"history.unread_banner",
      [NSString stringWithFormat:@"%ld", (long)_unreadMissed], nil]
                 forState:UIControlStateNormal];
  _missedNotice.hidden = _unreadMissed <= 0;
  [_tabs applyTexts:_texts];
  [_tabs setMissedCount:_unreadMissed];
  NSString *deviceName = [DBConfigUtil str:_cfg path:[NSString stringWithFormat:
      @"devices.%@.name", _nodeId]];
  if ([deviceName length] == 0) deviceName = _boot.name;
  _nav.topItem.title = [deviceName length] > 0 ? deviceName : [_texts ts:@"app.name"];
  [_monitorItem setTitle:[_texts ts:@"nav.monitor"]];
  _monitorItem.enabled = [_doorTileInfos count] > 0;
  _addDeviceItem.accessibilityLabel = [_texts ts:@"admin.add_device"];

  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  NSDictionary *global = [DBNoticeModel effectiveNoticeForDoor:nil config:_cfg nowMs:nowMs];
  // An announcement in force shows as the bar's highlighted (Done) style.
  [_noticeItem setTitle:[_texts ts:@"dash.notice_global"]];
  _noticeItem.style = global != nil ? UIBarButtonItemStyleDone : UIBarButtonItemStyleBordered;
}

- (void)updateFooter {
  NSDictionary *power = [_core powerStateNow];
  NSInteger battery = [DBConfigUtil intVal:power path:@"battery_pct" def:-1];
  BOOL charging = [DBConfigUtil boolVal:power path:@"charging" def:NO];
  NSString *appVersion = [[NSBundle mainBundle]
      objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
  NSString *deviceName = [DBConfigUtil str:_cfg path:[NSString stringWithFormat:
      @"devices.%@.name", _nodeId]] ?: _boot.name;
  [_qr setVersionLine:[DBUiTheme versionLineForName:deviceName
                                        coreVersion:[_core coreVersion]
                                         appVersion:appVersion
                                         batteryPct:battery charging:charging]];
  // The admin QR is always visible on an indoor panel; opening the admin still
  // asks for the password (spec §5.1).
  [_qr setUrl:[self adminUrl] caption:[_texts ts:@"web_admin.open"]];
}

- (NSString *)adminUrl {
  NSString *host = nil;
  id addresses = [DBConfigUtil dig:_status path:@"node.local_addrs"];
  if ([addresses isKindOfClass:[NSArray class]]) {
    for (id candidate in (NSArray *)addresses) {
      if (![candidate isKindOfClass:[NSString class]]) continue;
      if ([(NSString *)candidate rangeOfString:@":"].location != NSNotFound) continue;
      host = candidate;
      break;
    }
  }
  if ([host length] == 0) host = @"127.0.0.1";
  // Security protocol v3: the admin is served over HTTPS on 47443 only.
  return [NSString stringWithFormat:@"https://%@:47443/admin/", [DBConfigUtil urlHost:host]];
}

// Status arrives every five seconds and on every event. Tearing the tiles down
// and rebuilding them each time threw away the still image and forced a fresh
// decode, which is the hitch the owner sees on the dashboard. Tiles are now
// created once per door and updated in place; only a membership change touches
// the view tree.
- (void)updateFleetCounters {
  if ([_fleetCounters count] != 3) return;
  DBFleetCounts *counts = [DBFleetCounts countsFromStatus:_status config:_cfg];
  NSString *devices = [NSString stringWithFormat:@"%ld", (long)counts.devices];
  NSString *doors = [NSString stringWithFormat:@"%ld/%ld", (long)counts.doorStationsOnline,
                     (long)counts.doorStations];
  NSString *panels = [NSString stringWithFormat:@"%ld/%ld", (long)counts.panelsOnline,
                      (long)counts.panels];
  DBFleetCounter *first = [_fleetCounters objectAtIndex:0];
  DBFleetCounter *second = [_fleetCounters objectAtIndex:1];
  DBFleetCounter *third = [_fleetCounters objectAtIndex:2];
  first.value = devices;
  second.value = doors;
  third.value = panels;
  // The glyphs carry the meaning on screen; a screen reader gets the sentence.
  first.accessibilityLabel = [_texts t:@"dash.count_devices", devices, nil];
  second.accessibilityLabel = [_texts t:@"dash.count_door_stations",
      [NSString stringWithFormat:@"%ld", (long)counts.doorStationsOnline],
      [NSString stringWithFormat:@"%ld", (long)counts.doorStations], nil];
  third.accessibilityLabel = [_texts t:@"dash.count_panels",
      [NSString stringWithFormat:@"%ld", (long)counts.panelsOnline],
      [NSString stringWithFormat:@"%ld", (long)counts.panels], nil];
  [self setNeedsLayout];
}

- (void)rebuildDoorTiles {
  NSMutableArray *live = [NSMutableArray array];
  NSMutableArray *keys = [NSMutableArray array];
  for (DBDoorTileInfo *info in _doorTileInfos) [keys addObject:info.doorId];
  // Drop tiles whose door left the cluster.
  for (NSInteger i = (NSInteger)[_doorTiles count] - 1; i >= 0; i--) {
    DBDoorTile *tile = [_doorTiles objectAtIndex:(NSUInteger)i];
    if (![keys containsObject:tile.doorId ?: @""]) {
      [tile removeFromSuperview];
      [_doorTiles removeObjectAtIndex:(NSUInteger)i];
    }
  }
  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  NSInteger index = 0;
  for (DBDoorTileInfo *info in _doorTileInfos) {
    DBDoorTile *tile = nil;
    for (DBDoorTile *candidate in _doorTiles) {
      if ([(candidate.doorId ?: @"") isEqualToString:info.doorId]) {
        tile = candidate;
        break;
      }
    }
    if (tile == nil) {
      tile = [[DBDoorTile alloc] initWithFrame:CGRectZero];
      tile.doorId = info.doorId;
      [tile addTarget:self action:@selector(onDoorTile:)
     forControlEvents:UIControlEventTouchUpInside];
      [self addSubview:tile];
      [_doorTiles addObject:tile];
    }
    [live addObject:tile];
    tile.peer = info.peer;
    if (![tile.snapshotURL isEqualToString:info.snapshotURL] ||
        ![tile.videoMetaURL isEqualToString:info.videoMetaURL]) {
      tile.videoRotation = 0;
      tile.still.image = nil;
    }
    tile.snapshotURL = info.snapshotURL;
    tile.videoMetaURL = info.videoMetaURL;
    tile.online = info.online;
    tile.tag = index++;
    tile.backgroundColor = _palette.elevated;
    NSDictionary *doorEntry = [DBConfigUtil dig:_cfg
        path:[NSString stringWithFormat:@"doors.%@", info.doorId]];
    NSString *name = [DBConfigUtil labelOf:doorEntry lang:_boot.uiLang fallback:@""];
    if ([name length] == 0) name = info.label;
    if ([name length] == 0) name = [DBConfigUtil evStr:info.peer key:@"name"];
    if ([name length] == 0) name = info.doorId;
    tile.caption.text = name;
    tile.caption.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    tile.caption.textColor = [UIColor whiteColor];
    // The video placeholder is black regardless of the dashboard appearance.
    tile.offlineLabel.textColor = DBColorFromHex([DBUiTheme mutedInkHexForMode:@"dark"],
                                               [UIColor lightGrayColor]);
    tile.offlineLabel.text = [_texts ts:@"dash.tile_offline"];
    // The badge reports the door station, never the state of the still cache.
    // A tile whose first JPEG has not landed yet is online with a black frame.
    tile.offlineLabel.hidden = info.online;
    if (!info.online) tile.still.image = nil;
    NSDictionary *notice = [DBNoticeModel effectiveNoticeForDoor:tile.doorId config:_cfg
                                                            nowMs:nowMs];
    tile.noticeChip.text = [_texts ts:@"notice.chip"];
    tile.noticeChip.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    tile.noticeChip.textColor = [UIColor whiteColor];
    tile.noticeChip.hidden = (notice == nil);
  }
  // Keep the array in configuration order without recreating anything.
  [_doorTiles removeAllObjects];
  [_doorTiles addObjectsFromArray:live];
  [self applyDoorPreviewSelection];
}

// iPad 1 keeps at most three camera surfaces active (one in safe mode). A large fleet remains
// reachable in pages, while press/motion events occupy the front of the active page. A burst is
// bounded by the same capacity, so it cannot create an unbounded decode/network fan-out.
- (NSArray *)visibleDoorTiles {
  NSInteger total = (NSInteger)[_doorTiles count];
  NSInteger capacity = _safeMode ? 1 : 3;
  if (total <= capacity) return [NSArray arrayWithArray:_doorTiles];
  NSMutableArray *selected = [NSMutableArray arrayWithCapacity:(NSUInteger)capacity];
  for (NSString *door in _previewPriorityDoors) {
    for (DBDoorTile *tile in _doorTiles) {
      if ([tile.doorId isEqualToString:door] && ![selected containsObject:tile]) {
        [selected addObject:tile];
        break;
      }
    }
    if ((NSInteger)[selected count] >= capacity) return selected;
  }
  NSInteger start = (_previewPage * capacity) % total;
  for (NSInteger offset = 0; offset < total && (NSInteger)[selected count] < capacity; offset++) {
    DBDoorTile *tile = [_doorTiles objectAtIndex:(NSUInteger)((start + offset) % total)];
    if (![selected containsObject:tile]) [selected addObject:tile];
  }
  return selected;
}

- (void)applyDoorPreviewSelection {
  NSArray *visible = [self visibleDoorTiles];
  for (DBDoorTile *tile in _doorTiles) tile.hidden = ![visible containsObject:tile];
  NSInteger total = (NSInteger)[_doorTiles count];
  _noDoorsLabel.hidden = total > 0;
  BOOL paged = total > (NSInteger)[visible count];
  _doorsPager.hidden = !paged;
  if (paged) {
    [_doorsPager setTitle:[NSString stringWithFormat:@"%@  %ld/%ld",
        [_texts ts:@"dash.doors"], (long)[visible count], (long)total]
                 forState:UIControlStateNormal];
  }
  [self setNeedsLayout];
}

- (void)prioritizeDoorPreview:(NSString *)door {
  if ([door length] == 0) return;
  [_previewPriorityDoors removeObject:door];
  [_previewPriorityDoors insertObject:door atIndex:0];
  NSInteger capacity = _safeMode ? 1 : 3;
  while ((NSInteger)[_previewPriorityDoors count] > capacity)
    [_previewPriorityDoors removeLastObject];
  _previewPage = 0;
  [self applyDoorPreviewSelection];
}

#pragma mark - door stills

- (void)refreshSnapshots {
  if (self.superview == nil) return;
  _snapshotTick++;
  if (_safeMode && (_snapshotTick % kSafeModeSnapshotEveryNTicks) != 0) return;
  CGFloat maxSide = _safeMode ? kSafeModeSnapshotMaxSide : kSnapshotMaxSide;
  NSInteger generation = ++_snapshotGeneration;
  for (DBDoorTile *tile in [self visibleDoorTiles]) {
    // The still comes off the serving peer's own media origin, resolved once in
    // DBMediaSource; the dashboard never guesses a host or a port of its own.
    if (!tile.online || [tile.snapshotURL length] == 0) continue;
    NSURL *url = [NSURL URLWithString:tile.snapshotURL];
    if (url == nil) continue;
    NSString *snapshotURL = tile.snapshotURL;
    NSString *metaURL = tile.videoMetaURL;
    NSInteger previousRotation = tile.videoRotation;
    __weak DBDoorTile *weakTile = tile;
    __weak DBHomeScreen *weakSelf = self;
    // One still per door every five seconds (fifteen in safe mode), fetched and
    // downscaled entirely off the main thread: a full-size JPEG decode on the
    // main run loop of an iPad 1 is visible as a dropped clock second.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
      NSInteger rotation = previousRotation;
      NSURL *metadataURL = [metaURL length] > 0 ? [NSURL URLWithString:metaURL] : nil;
      if (metadataURL != nil) {
        NSMutableURLRequest *metadataRequest = [NSMutableURLRequest requestWithURL:metadataURL
            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:1.0];
        DBAuthorizeLocalMediaRequest(metadataRequest);
        NSURLResponse *metadataResponse = nil;
        NSData *metadataData = [NSURLConnection sendSynchronousRequest:metadataRequest
            returningResponse:&metadataResponse error:NULL];
        if ([metadataResponse isKindOfClass:[NSHTTPURLResponse class]] &&
            [(NSHTTPURLResponse *)metadataResponse statusCode] == 200 && metadataData != nil) {
          id metadata = [NSJSONSerialization JSONObjectWithData:metadataData options:0 error:NULL];
          rotation = [DBDoorTileModel videoRotationFromMetadata:metadata fallback:rotation];
        }
      }
      NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:3.0];
      DBAuthorizeLocalMediaRequest(request);
      NSURLResponse *response = nil;
      NSError *error = nil;
      NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response
                                                       error:&error];
      UIImage *image = data ? [UIImage imageWithData:data] : nil;
      UIImage *thumbnail = [DBHomeScreen thumbnailForImage:image maxSide:maxSide rotation:rotation];
      // A door that is online but never shows a picture is otherwise silent.
      if (thumbnail == nil) {
        NSLog(@"[doorbell] still fetch failed for %@: %lu bytes, image=%d, %@", url,
              (unsigned long)[data length], image != nil, error ?: (id)@"no error");
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        DBHomeScreen *screen = weakSelf;
        DBDoorTile *strongTile = weakTile;
        if (!screen || !strongTile || screen->_snapshotGeneration != generation) return;
        if (![strongTile.snapshotURL isEqualToString:snapshotURL] ||
            ![strongTile.videoMetaURL isEqualToString:metaURL]) return;
        if (thumbnail != nil && strongTile.online) {
          strongTile.videoRotation = rotation;
          strongTile.still.image = thumbnail;
        }
      });
    });
  }
}

+ (UIImage *)thumbnailForImage:(UIImage *)image maxSide:(CGFloat)maxSide
                    rotation:(NSInteger)rotation {
  if (image == nil) return nil;
  CGSize size = image.size;
  if (size.width <= 0 || size.height <= 0) return nil;
  CGFloat scale = MIN(1.0, maxSide / MAX(size.width, size.height));
  CGSize target = CGSizeMake(floor(size.width * scale), floor(size.height * scale));
  if (target.width < 1 || target.height < 1) return nil;
  BOOL quarterTurn = rotation == 90 || rotation == 270;
  CGSize canvas = quarterTurn ? CGSizeMake(target.height, target.width) : target;
  UIGraphicsBeginImageContext(canvas);
  CGContextRef context = UIGraphicsGetCurrentContext();
  CGContextTranslateCTM(context, canvas.width / 2, canvas.height / 2);
  CGContextRotateCTM(context, (CGFloat)rotation * (CGFloat)3.14159265358979323846 / 180.0f);
  [image drawInRect:CGRectMake(-target.width / 2, -target.height / 2, target.width, target.height)];
  UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return out;
}

#pragma mark - actions

- (void)onDoorTile:(DBDoorTile *)sender {
  if (sender.peer == nil) return;
  [_router showMonitorPeer:sender.peer];
}

// One door opens its monitor at once; several are offered as a list, so every door is
// reachable even when its tile is on another preview page.
- (void)onMonitor {
  NSMutableArray *peers = [NSMutableArray array];
  NSMutableArray *titles = [NSMutableArray array];
  for (DBDoorTile *tile in _doorTiles) {
    if (tile.peer == nil) continue;
    [peers addObject:tile.peer];
    [titles addObject:tile.caption.text ?: tile.doorId ?: @""];
  }
  if ([peers count] == 0) return;
  if ([peers count] == 1) {
    [_router showMonitorPeer:[peers objectAtIndex:0]];
    return;
  }
  UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:[_texts ts:@"dash.doors"]
                                                     delegate:self
                                            cancelButtonTitle:nil
                                       destructiveButtonTitle:nil
                                            otherButtonTitles:nil];
  for (NSString *title in titles) [sheet addButtonWithTitle:title];
  sheet.cancelButtonIndex = [sheet addButtonWithTitle:[_texts ts:@"admin.cancel"]];
  _monitorSheet = sheet;
  _monitorSheetPeers = peers;
  if (DBChromeIsPad())
    [sheet showFromBarButtonItem:_monitorItem animated:NO];
  else
    [sheet showInView:self];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)buttonIndex {
  if (sheet != _monitorSheet) return;
  NSArray *peers = _monitorSheetPeers;
  _monitorSheet = nil;
  _monitorSheetPeers = nil;
  if (buttonIndex < 0 || buttonIndex == sheet.cancelButtonIndex ||
      buttonIndex >= (NSInteger)[peers count]) return;
  [_router showMonitorPeer:[peers objectAtIndex:(NSUInteger)buttonIndex]];
}

- (void)onNextDoorPreviewPage {
  NSInteger total = (NSInteger)[_doorTiles count];
  NSInteger capacity = _safeMode ? 1 : 3;
  if (total <= capacity) return;
  [_previewPriorityDoors removeAllObjects];
  NSInteger pages = (total + capacity - 1) / capacity;
  _previewPage = (_previewPage + 1) % MAX(1, pages);
  [self applyDoorPreviewSelection];
  [self refreshSnapshots];
}

- (void)onMembership {
  if (![_pairingState isEqualToString:@"ready"]) {
    [_router showPairing];
    return;
  }
  __weak DBHomeScreen *weakSelf = self;
  [_router requestPinThen:^{
    DBHomeScreen *screen = weakSelf;
    if (screen) [screen.router showAddDevice];
  }];
}

- (void)onPairBanner {
  [_router showPairing];
}

- (void)onHistory {
  // Opening the history marks the missed calls seen, which clears the badge.
  [_router selectHomeTab:DBHomeTabHistory];
}

- (void)onGlobalNotice {
  if (!_noticeDialog) _noticeDialog = [[DBNoticeDialog alloc] initWithRouter:_router];
  NSMutableArray *doorIds = [NSMutableArray array];
  NSMutableDictionary *labels = [NSMutableDictionary dictionary];
  NSDictionary *doors = [DBConfigUtil dig:_cfg path:@"doors"];
  if ([doors isKindOfClass:[NSDictionary class]]) {
    for (NSString *door in [DBConfigUtil sortedByOrder:doors]) {
      [doorIds addObject:door];
      [labels setObject:[DBConfigUtil labelOf:[doors objectForKey:door] lang:_boot.uiLang
                                     fallback:door] forKey:door];
    }
  }
  __weak DBHomeScreen *weakSelf = self;
  // The dashboard's button opens the dialog with 全体 preselected (spec §5.1).
  [_noticeDialog presentInView:self config:_cfg doorIds:doorIds doorLabels:labels
               preselectedDoor:nil palette:_palette onFinished:^(BOOL changed) {
    DBHomeScreen *screen = weakSelf;
    if (screen && changed) [screen refreshFromCore];
  }];
}

#pragma mark - SOS

- (void)refreshSosVisibility {
  BOOL show = [_boot.role isEqualToString:@"indoor_panel"];
  id roles = [DBConfigUtil dig:_cfg path:@"emergency.button_on_roles"];
  if ([roles isKindOfClass:[NSArray class]]) {
    show = NO;
    for (id role in (NSArray *)roles) {
      if ([role isKindOfClass:[NSString class]] &&
          [(NSString *)role isEqualToString:_boot.role])
        show = YES;
    }
  }
  if (_sosButton.hidden == show) [self setNeedsLayout];
  _sosButton.hidden = !show;
  if (!show) [_sosPanel dismiss];
}

// The button only opens the confirmation panel; the slide inside it is the second gesture.
- (void)onSosButton {
  if (_emergencyActive) return;
  [_sosPanel presentInView:self below:_emergencyView];
}

- (void)sosSliderDidArm:(DBSosSlider *)slider {
  (void)slider;
}

- (void)sosSliderDidCancel:(DBSosSlider *)slider {
  (void)slider;
}

- (void)sosSliderDidFire:(DBSosSlider *)slider {
  (void)slider;
  // Core is told only here, at countdown zero.
  (void)[_core emergency:YES];
}

- (void)onEmergencyCancel {
  __weak DBHomeScreen *weakSelf = self;
  if (_cancelRequiresPin) {
    [_router requestPinThen:^{ [weakSelf cancelEmergencyConfirmed]; }];
    return;
  }
  [self cancelEmergencyConfirmed];
}

- (void)cancelEmergencyConfirmed {
  if ([_core emergency:NO]) [self hideEmergencyEvent:nil];
}

#pragma mark - events from the router

- (void)refreshAfterCallEvent {
  if (_callRefreshPending || !_screenVisible) return;
  _callRefreshPending = YES;
  __weak DBHomeScreen *weakSelf = self;
  // Durable history is refreshed on return; its query/layout must not precede
  // admission and first-frame presentation for a newly ringing call.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    DBHomeScreen *screen = weakSelf;
    if (!screen) return;
    screen->_callRefreshPending = NO;
    [screen refreshFromCore];
  });
}

- (void)appendEvent:(NSDictionary *)ev {
  NSString *type = [DBConfigUtil evStr:ev key:@"type"];
  if ([type isEqualToString:@"motion"])
    [self prioritizeDoorPreview:[DBConfigUtil evStr:ev key:@"door"]];
  else if ([type isEqualToString:@"press"]) {
    NSString *door = [DBConfigUtil evStr:ev key:@"door"];
    __weak DBHomeScreen *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      DBHomeScreen *screen = weakSelf;
      if (screen && screen->_screenVisible) [screen prioritizeDoorPreview:door];
    });
  }
  // The volatile ticker is gone: the dashboard renders the durable call log
  // instead, so a refresh is the correct response to any call-lifecycle event.
  [self refreshAfterCallEvent];
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
  _replyTimer = [NSTimer scheduledTimerWithTimeInterval:ttl target:self
                                               selector:@selector(hideReplyBanner)
                                               userInfo:nil repeats:NO];
}

- (void)hideReplyBanner {
  _replyBanner.hidden = YES;
}

// The proxy is rebuilt only when the image or the view size actually changes,
// and always off the main thread: it decodes and scales the theme picture.
- (void)refreshBackgroundSampler {
  CGSize size = self.bounds.size;
  if (_themeImage == nil || _safeMode || size.width <= 0 || size.height <= 0) {
    _sampler = nil;
    _samplerSize = CGSizeZero;
    [_palette setBackgroundSampler:nil];
    return;
  }
  if (_samplerBuilding) return;
  if (CGSizeEqualToSize(_samplerSize, size) && _sampler != nil) return;
  _samplerBuilding = YES;
  UIImage *image = _themeImage;
  __weak DBHomeScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
    DBBackgroundSampler *sampler = [DBBackgroundSampler samplerWithImage:image viewSize:size];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBHomeScreen *screen = weakSelf;
      if (!screen) return;
      screen->_samplerBuilding = NO;
      if (screen->_themeImage != image) return;
      screen->_sampler = sampler;
      screen->_samplerSize = size;
      [screen->_palette setBackgroundSampler:sampler];
      [screen applyRegionInk];
    });
  });
}

// Every text region takes the ink measured behind its own frame, so a caption
// over a light corner of a dark picture is dark, not white. Called after
// layout, when the frames are final; changing a text colour does not itself
// invalidate layout, so this cannot loop.
- (void)applyRegionInk {
  if (_palette == nil) return;
  [_palette setBackgroundSampler:_themeBg.hidden ? nil : _sampler];
  [_palette applyInkToLabel:_clockLabel region:DBUiRegionClock];
  [_palette applyInkToLabel:_dateLabel region:DBUiRegionDate];
  [_palette applyInkToLabel:_noDoorsLabel region:DBUiRegionHint];
  // The counters are a status line drawn by hand, so they take the same ink
  // and the same halo decision the labels beside them take.
  for (DBFleetCounter *counter in _fleetCounters) {
    counter.ink = [_palette inkForRegion:DBUiRegionStatusLine frame:counter.frame];
    counter.halo = [_palette needsShadowForRegion:DBUiRegionStatusLine frame:counter.frame];
    [counter setNeedsDisplay];
  }
  for (DBDoorTile *tile in _doorTiles) {
    // A tile caption sits on its own translucent pill over live video, so it
    // is measured against the tile, not the wallpaper behind it.
    [_palette applyInkToLabel:tile.caption region:DBUiRegionTileLabel];
    tile.caption.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    tile.caption.textColor = [UIColor whiteColor];
    tile.caption.shadowColor = nil;
  }
}

- (void)applyDisplayEvent:(NSDictionary *)display {
  // The event carries the same contract as status.display, including the
  // resolved appearance and the automatic theme decision.
  if ([display objectForKey:@"theme"] != nil ||
      [display objectForKey:@"appearance"] != nil)
    _display = display;
  _brightness = [DBConfigUtil intVal:display path:@"brightness" def:_brightness];
  _night = [DBConfigUtil evBool:display key:@"night"];
  _redTint = [DBConfigUtil evBool:display key:@"red_tint"];
  [self applyDisplay];
}

- (void)applyDisplay {
  _nightTint.hidden = !(_night && _redTint);
  if (!_emergencyActive) [self setBrightness:_brightness];
}

- (void)setBrightness:(NSInteger)percent {
  [UIScreen mainScreen].brightness = (CGFloat)MAX(0, MIN(100, percent)) / 100.0;
}

- (void)showEmergencyEvent:(NSDictionary *)ev {
  _emergencyActive = YES;
  _replyBanner.hidden = YES;
  [_sosPanel dismiss];
  [_sos reset];
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
  if (([sound length] > 0 || [path length] > 0) && volume > 0)
    [_audio startSiren:path volume:volume];
  else
    [_audio stop];
}

- (void)hideEmergencyEvent:(NSDictionary *)ev {
  (void)ev;
  _emergencyActive = NO;
  [_audio stop];
  _emergencyView.hidden = YES;
  [_sos reset];
  [self applyDisplay];
}

- (void)enterSafeMode {
  _safeMode = YES;
  _themeHash = nil;
  _themeAverageHex = nil;
  _themeImage = nil;
  _sampler = nil;
  _samplerSize = CGSizeZero;
  _themeBg.image = nil;
  _themeBg.hidden = YES;
  for (DBDoorTile *tile in _doorTiles) tile.still.image = nil;
  [self applyDoorPreviewSelection];
  [self applyPalette];
  self.backgroundColor = _palette.surface;
}

- (void)exitSafeMode {
  if (!_safeMode) return;
  _safeMode = NO;
  [self applyDoorPreviewSelection];
  [self applyTheme];
  [self applyDisplay];
  [self refreshSnapshots];
}

#pragma mark - layout

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  BOOL portrait = size.height > size.width;
  _themeBg.frame = self.bounds;
  _nightTint.frame = self.bounds;
  _offlineView.frame = self.bounds;
  _emergencyView.frame = self.bounds;
  _noticeDialog.frame = self.bounds;

  CGFloat navHeight = [_nav layoutInBounds:self.bounds];
  CGFloat tabHeight = [_tabs layoutInBounds:self.bounds];
  // The QR, the version line and the SOS slider are placed by one shared, host-tested split
  // above the tab bar, so they can never overlap in either orientation.
  CGFloat footerViewHeight = size.height - tabHeight;
  NSDictionary *footer = [DBUiTheme footerLayoutForViewWidth:size.width
                                                  viewHeight:footerViewHeight
                                                    portrait:portrait
                                                  sosVisible:NO];
  CGFloat footerHeight = (CGFloat)[[footer objectForKey:@"height"] doubleValue];
  DBHomeLayout layout = DBHomeLayoutMake(size, navHeight, tabHeight, footerHeight,
                                         !_pairBanner.hidden, !_missedNotice.hidden,
                                         !_doorsPager.hidden, !_sosButton.hidden);

  _clockLabel.font = [UIFont systemFontOfSize:floorf((float)layout.clock.size.height * 0.9f)];
  _dateLabel.font = [UIFont systemFontOfSize:floorf((float)layout.date.size.height * 0.75f)];
  _clockLabel.frame = layout.clock;
  _dateLabel.frame = layout.date;
  _pairBanner.frame = layout.banner;
  _missedNotice.frame = layout.missed;
  _doorsPager.frame = layout.pager;
  _noDoorsLabel.frame = CGRectInset(layout.tiles, 0, MAX(0, (layout.tiles.size.height - 80) / 2));

  // Each counter sizes to its own glyph and number, right aligned in its band.
  CGFloat counterGap = 8;
  CGFloat counterRight = CGRectGetMaxX(layout.counters);
  for (NSInteger i = (NSInteger)[_fleetCounters count] - 1; i >= 0; i--) {
    DBFleetCounter *counter = [_fleetCounters objectAtIndex:(NSUInteger)i];
    CGFloat width = [counter widthThatFits];
    counter.frame = CGRectMake(counterRight - width, layout.counters.origin.y, width,
                               layout.counters.size.height);
    counterRight -= width + counterGap;
  }

  NSArray *visibleTiles = [self visibleDoorTiles];
  NSInteger count = (NSInteger)[visibleTiles count];
  for (NSInteger i = 0; i < count; i++) {
    DBDoorTile *tile = [visibleTiles objectAtIndex:(NSUInteger)i];
    tile.frame = DBHomeLayoutTileFrame(layout, i, count);
  }

  // The address and the version line are two stacked lines inside the QR block, so the block
  // takes the width of both rectangles.
  CGRect footerBlock = CGRectUnion(DBRectFromArray([footer objectForKey:@"qr"]),
                                   DBRectFromArray([footer objectForKey:@"version"]));
  _qr.frame = footerBlock;
  _sosButton.frame = layout.sos;
  // One plate under the footer block.
  CGFloat footerPad = 8;
  _footerScrim.frame = CGRectIsEmpty(footerBlock)
      ? CGRectZero : CGRectInset(footerBlock, -footerPad, -footerPad);
  if ([_footerScrim isKindOfClass:[DBFrostedPlateView class]]) {
    UIColor *tint = [_palette.surface colorWithAlphaComponent:kFooterGlassAlpha];
    UIColor *border = [_palette.ink colorWithAlphaComponent:0.18];
    [(DBFrostedPlateView *)_footerScrim setBackdrop:_themeGlassImage
                                        sourceFrame:_footerScrim.frame
                                         canvasSize:size tint:tint border:border];
  }

  CGFloat replyWidth = MIN(size.width - 40, 560);
  _replyBanner.frame = CGRectMake((size.width - replyWidth) / 2, navHeight + 12, replyWidth, 96);
  _replyCaption.frame = CGRectMake(20, 12, replyWidth - 40, 24);
  _replyText.frame = CGRectMake(20, 40, replyWidth - 40, 44);

  _offlineTitle.frame = CGRectMake(0, size.height / 2 - 50, size.width, 40);
  _offlineBody.frame = CGRectMake(20, size.height / 2, size.width - 40, 60);
  _emergencyTitle.frame = CGRectMake(0, size.height / 2 - 120, size.width, 80);
  _emergencyNote.frame = CGRectMake(20, size.height / 2 - 20, size.width - 40, 40);
  _emergencyCancel.frame = CGRectMake(size.width / 2 - 110, size.height / 2 + 50, 220, 64);

  // A rotation needs the picture rebuilt at the new panel size.
  if ([_themeHash length] > 0 && !CGSizeEqualToSize(_themeImageSize, size)) {
    _themeImageSize = size;
    [self loadThemeImage:_themeHash];
  }
  [self refreshBackgroundSampler];
  [self applyRegionInk];
}

@end
