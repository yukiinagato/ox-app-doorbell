#import "DBHomeScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBCallHistoryModel.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBDoorTileModel.h"
#import "../Core/DBFleetCounts.h"
#import "../Core/DBNoticeModel.h"
#import "../Core/DBPairingModel.h"
#import "../Core/DBRefreshCoalescer.h"
#import "../Core/DBSemanticStyle.h"
#import "../Core/DBTexts.h"
#import "../Core/DBUiTheme.h"
#import "../Media/DBSiren.h"
#import "DBNoticeDialog.h"
#import "DBRouter.h"
#import "DBWidgets.h"
#import <AudioToolbox/AudioToolbox.h>

static CGRect DBRectFromArray(NSArray *rect) {
  if ([rect count] != 4) return CGRectZero;
  return CGRectMake((CGFloat)[[rect objectAtIndex:0] doubleValue],
                    (CGFloat)[[rect objectAtIndex:1] doubleValue],
                    (CGFloat)[[rect objectAtIndex:2] doubleValue],
                    (CGFloat)[[rect objectAtIndex:3] doubleValue]);
}

static const NSTimeInterval kSnapshotIntervalS = 5.0;
// Safe mode keeps the door picture, smaller and less often. It is already the
// bounded low-resolution snapshot the safe-mode contract asks for, and a panel
// latched in safe mode for hours must not sit in front of a black door tile.
static const CGFloat kSnapshotMaxSide = 320;
static const CGFloat kSafeModeSnapshotMaxSide = 160;
static const NSInteger kSafeModeSnapshotEveryNTicks = 3;
static const NSInteger kRecentCallLimit = 20;

// One door tile: a five-second still, the door label, and the announcement chip.
@interface DBDoorTile : UIButton
// Stable identity across status polls, so a tile is created once per door. The
// door id is that identity: a door outlives the station serving it, and keying
// on the peer threw the still away every time the serving node changed.
@property(nonatomic, copy) NSString *doorId;
@property(nonatomic, strong) NSDictionary *peer;
@property(nonatomic, copy) NSString *snapshotURL;
@property(nonatomic) BOOL online;
@property(nonatomic, readonly) UIImageView *still;
@property(nonatomic, readonly) DBPillLabel *caption;
@property(nonatomic, readonly) DBNoticeChip *noticeChip;
@property(nonatomic, readonly) UILabel *offlineLabel;
@end

@implementation DBDoorTile {
  UIImageView *_still;
  DBPillLabel *_caption;
  DBNoticeChip *_noticeChip;
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
    _noticeChip = [[DBNoticeChip alloc] initWithFrame:CGRectZero];
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
  _noticeChip.frame = CGRectMake(8, 8, MIN(size.width - 16, chipFit.width + 14), 30);
}

@end

@interface DBHomeScreen () <DBSosSliderDelegate>
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
  UIImage *_themeImage;
  DBBackgroundSampler *_sampler;   // Per-region sampling of the theme image.
  CGSize _samplerSize;
  CGSize _themeImageSize;
  BOOL _samplerBuilding;
  NSArray *_doorTileInfos;
  NSArray *_recentRows;
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

  NSInteger _secretTaps;
  NSDate *_secretFirst;

  dispatch_queue_t _refreshQueue;
  DBRefreshCoalescer *_refreshGate;

  // UI
  UIImageView *_themeBg;
  UILabel *_clockLabel;
  UILabel *_dateLabel;
  NSArray *_fleetCounters;   // Three DBFleetCounter, left to right.
  UIButton *_membershipButton;
  DBPillLabel *_missedBadge;
  UIButton *_missedButton;
  UIButton *_adminButton;
  DBNoticeChip *_globalNoticeChip;
  UIButton *_pairBanner;
  UILabel *_doorsCaption;
  NSMutableArray *_doorTiles;
  UILabel *_recentCaption;
  UIButton *_seeAllButton;
  UIScrollView *_recentList;
  NSMutableArray *_recentLabels;
  UILabel *_recentEmpty;
  DBAdminQrView *_qr;
  UILabel *_versionLabel;
  DBSosSlider *_sos;
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
    _recentRows = [NSArray array];
    _doorTiles = [[NSMutableArray alloc] init];
    _recentLabels = [[NSMutableArray alloc] init];
    _nodeId = @"";
    _brightness = 70;
    _cancelRequiresPin = YES;
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

- (UIButton *)flatButton:(CGFloat)size {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
  button.titleLabel.font = [UIFont boldSystemFontOfSize:size];
  button.titleLabel.adjustsFontSizeToFitWidth = NO;
  button.layer.cornerRadius = 10;
  button.clipsToBounds = YES;
  button.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
  return button;
}

- (void)buildUi {
  _themeBg = [[UIImageView alloc] init];
  _themeBg.contentMode = UIViewContentModeScaleAspectFill;
  _themeBg.opaque = YES;
  _themeBg.clipsToBounds = YES;
  _themeBg.hidden = YES;
  [self addSubview:_themeBg];

  _clockLabel = [[UILabel alloc] init];
  _clockLabel.backgroundColor = [UIColor clearColor];
  _clockLabel.font = [UIFont systemFontOfSize:96];
  [self addSubview:_clockLabel];

  _dateLabel = [[UILabel alloc] init];
  _dateLabel.backgroundColor = [UIColor clearColor];
  _dateLabel.font = [UIFont systemFontOfSize:28];
  [self addSubview:_dateLabel];

  // Three compact counters instead of one sentence: at a glance the owner wants
  // how many devices there are and how many of each kind are answering.
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
  _membershipButton = [UIButton buttonWithType:UIButtonTypeCustom];
  [_membershipButton addTarget:self action:@selector(onMembership)
              forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_membershipButton];

  _missedBadge = [[DBPillLabel alloc] initWithFrame:CGRectZero];
  _missedBadge.font = [UIFont boldSystemFontOfSize:21];
  _missedBadge.hidden = YES;
  [self addSubview:_missedBadge];
  _missedButton = [UIButton buttonWithType:UIButtonTypeCustom];
  _missedButton.hidden = YES;
  [_missedButton addTarget:self action:@selector(onHistory)
          forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_missedButton];

  _adminButton = [self flatButton:22];
  [_adminButton addTarget:self action:@selector(onAdmin)
         forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_adminButton];

  _globalNoticeChip = [[DBNoticeChip alloc] initWithFrame:CGRectZero];
  [_globalNoticeChip addTarget:self action:@selector(onGlobalNotice)
              forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_globalNoticeChip];

  _pairBanner = [self flatButton:19];
  _pairBanner.backgroundColor = [UIColor colorWithRed:0.72 green:0.45 blue:0.10 alpha:1];
  [_pairBanner setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  _pairBanner.hidden = YES;
  [_pairBanner addTarget:self action:@selector(onPairBanner)
        forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_pairBanner];

  _doorsCaption = [[UILabel alloc] init];
  _doorsCaption.backgroundColor = [UIColor clearColor];
  _doorsCaption.font = [UIFont systemFontOfSize:20];
  [self addSubview:_doorsCaption];

  _recentCaption = [[UILabel alloc] init];
  _recentCaption.backgroundColor = [UIColor clearColor];
  _recentCaption.font = [UIFont systemFontOfSize:20];
  [self addSubview:_recentCaption];

  _seeAllButton = [self flatButton:19];
  [_seeAllButton addTarget:self action:@selector(onHistory)
          forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_seeAllButton];

  _recentList = [[UIScrollView alloc] init];
  _recentList.alwaysBounceVertical = YES;
  [self addSubview:_recentList];

  _recentEmpty = [[UILabel alloc] init];
  _recentEmpty.backgroundColor = [UIColor clearColor];
  _recentEmpty.font = [UIFont systemFontOfSize:20];
  [self addSubview:_recentEmpty];

  _qr = [[DBAdminQrView alloc] initWithFrame:CGRectZero];
  [self addSubview:_qr];

  _versionLabel = [[UILabel alloc] init];
  _versionLabel.backgroundColor = [UIColor clearColor];
  _versionLabel.font = [UIFont systemFontOfSize:16];
  _versionLabel.numberOfLines = 2;
  [self addSubview:_versionLabel];

  _sos = [[DBSosSlider alloc] initWithFrame:CGRectZero];
  _sos.delegate = self;
  [self addSubview:_sos];

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

#pragma mark - lifecycle

- (void)onScreenWillAppear {
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
  [_peersTimer invalidate];
  _peersTimer = nil;
  // Stills are pure decoration: never keep polling five-second JPEGs behind a
  // live call on an A4 device.
  [_snapshotTimer invalidate];
  _snapshotTimer = nil;
  ++_snapshotGeneration;
  [_noticeDialog dismiss];
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
  if (![_refreshGate beginRefresh]) return;
  DBCoreBridge *core = _core;
  __weak DBHomeScreen *weakSelf = self;
  dispatch_async(_refreshQueue, ^{
    NSDictionary *cfg = [core config];
    NSDictionary *status = [core status];
    NSDictionary *pairing = [core pairingInfo];
    NSDictionary *log = [core callLogSince:0 limit:kRecentCallLimit];
    NSDictionary *localTime = [core localTimeJson:0];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBHomeScreen *screen = weakSelf;
      if (!screen) return;
      BOOL again = [screen->_refreshGate endRefresh];
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
    _recentRows = [DBCallHistoryModel pageRows:[DBCallHistoryModel rowsFromLog:log]
                                      beforeMs:0 limit:kRecentCallLimit];
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
  [self rebuildRecentCalls];
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
  if (_themeBg.hidden) self.backgroundColor = _palette.surface;

  // The per-region colours are applied after layout, when each label's frame is
  // known; this only refreshes what does not depend on geometry.
  [_palette setBackgroundSampler:_sampler];
  [self applyRegionInk];

  for (DBFleetCounter *counter in _fleetCounters) {
    counter.fill = _palette.elevated;
    counter.ink = _palette.ink;
  }
  _missedBadge.backgroundColor = _palette.danger;
  _missedBadge.textColor = _palette.dangerInk;
  _adminButton.backgroundColor = _palette.elevated;
  [_adminButton setTitleColor:_palette.ink forState:UIControlStateNormal];
  _seeAllButton.backgroundColor = _palette.elevated;
  [_seeAllButton setTitleColor:_palette.ink forState:UIControlStateNormal];
  [_globalNoticeChip applyPalette:_palette];
  [_qr applyPalette:_palette];
  [_sos applyPalette:_palette];
  [_sos applyConfig:_cfg texts:_texts];
  _offlineView.backgroundColor = _palette.surface;
  _offlineTitle.textColor = _palette.ink;
  _offlineBody.textColor = _palette.mutedInk;
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
    _themeBg.image = nil;
    _themeBg.hidden = YES;
    [self refreshBackgroundSampler];
    self.backgroundColor = _palette.surface;
    return;
  }
  NSString *color = [self themeValue:@"bg_color"];
  UIColor *parsed = color ? [DBConfigUtil parseHexColor:color] : nil;
  NSString *hash = [self themeValue:@"bg_image"];
  if ([hash length] == 0) {
    [self noteThemeFallback:@"no_theme_image_configured"];
    _themeHash = nil;
    _themeAverageHex = nil;
    _themeImage = nil;
    _themeBg.image = nil;
    _themeBg.hidden = YES;
    [self refreshBackgroundSampler];
    self.backgroundColor = parsed ?: _palette.surface;
    return;
  }
  self.backgroundColor = parsed ?: _palette.surface;
  if ([_themeHash isEqualToString:hash] && _themeBg.image != nil) return;
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
  __weak DBHomeScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
    // One decode, at panel size, darkened once and cached per picture and
    // size; the sampler then measures the very pixels that are on screen.
    UIImage *backdrop = [DBThemeBackdrop cachedBackdropForKey:want size:size];
    NSData *data = nil;
    if (backdrop == nil) {
      data = [NSData dataWithContentsOfURL:url];
      backdrop = [DBThemeBackdrop backdropForData:data key:want size:size];
    }
    NSString *average = [DBUiPalette averageHexForImage:backdrop];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBHomeScreen *screen = weakSelf;
      if (!screen || ![screen->_themeHash isEqualToString:want]) return;
      [screen noteThemeFallback:(backdrop != nil) ? @""
          : ([data length] == 0 ? @"theme_asset_fetch_failed" : @"theme_asset_decode_failed")];
      screen->_themeBg.image = backdrop;
      screen->_themeBg.hidden = (backdrop == nil);
      screen->_themeAverageHex = average;
      screen->_themeImage = backdrop;
      screen->_themeImageSize = size;
      screen->_samplerSize = CGSizeZero;
      [screen refreshBackgroundSampler];
      [screen applyPalette];
      [screen rebuildDoorTiles];
      [screen rebuildRecentCalls];
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
  [_adminButton setTitle:[_texts ts:@"dash.admin"] forState:UIControlStateNormal];
  [_seeAllButton setTitle:[_texts ts:@"dash.see_all"] forState:UIControlStateNormal];
  _doorsCaption.text = [_texts ts:@"dash.doors"];
  _recentCaption.text = [_texts ts:@"dash.recent_calls"];
  _recentEmpty.text = [_texts ts:@"history.empty"];

  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  NSDictionary *global = [DBNoticeModel effectiveNoticeForDoor:nil config:_cfg nowMs:nowMs];
  [_globalNoticeChip setChipTitle:[_texts ts:@"dash.notice_global"] active:(global != nil)];

  if (_unreadMissed > 0) {
    _missedBadge.text = [_texts t:@"history.missed_badge",
        [NSString stringWithFormat:@"%ld", (long)_unreadMissed], nil];
    _missedBadge.hidden = NO;
    _missedButton.hidden = NO;
  } else {
    _missedBadge.hidden = YES;
    _missedButton.hidden = YES;
  }
}

- (void)updateFooter {
  NSDictionary *power = [_core powerStateNow];
  NSInteger battery = [DBConfigUtil intVal:power path:@"battery_pct" def:-1];
  BOOL charging = [DBConfigUtil boolVal:power path:@"charging" def:NO];
  NSString *appVersion = [[NSBundle mainBundle]
      objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
  _versionLabel.text = [DBUiTheme versionLineForName:_boot.name
                                         coreVersion:[_core coreVersion]
                                          appVersion:appVersion
                                          batteryPct:battery charging:charging];
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
  return [NSString stringWithFormat:@"http://%@:%ld/admin/", [DBConfigUtil urlHost:host],
                                    (long)_boot.httpPort];
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
    tile.snapshotURL = info.snapshotURL;
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
    tile.offlineLabel.textColor = _palette.mutedInk;
    tile.offlineLabel.text = [_texts ts:@"dash.tile_offline"];
    // The badge reports the door station, never the state of the still cache.
    // A tile whose first JPEG has not landed yet is online with a black frame.
    tile.offlineLabel.hidden = info.online;
    if (!info.online) tile.still.image = nil;
    NSDictionary *notice = [DBNoticeModel effectiveNoticeForDoor:tile.doorId config:_cfg
                                                            nowMs:nowMs];
    [tile.noticeChip applyPalette:_palette];
    [tile.noticeChip setChipTitle:[_texts ts:@"notice.chip"] active:YES];
    tile.noticeChip.hidden = (notice == nil);
  }
  // Keep the array in configuration order without recreating anything.
  [_doorTiles removeAllObjects];
  [_doorTiles addObjectsFromArray:live];
  _doorsCaption.text = [_doorTiles count] > 0 ? [_texts ts:@"dash.doors"]
                                              : [_texts ts:@"dash.no_doors"];
  [self setNeedsLayout];
}

- (void)rebuildRecentCalls {
  for (UILabel *label in _recentLabels) [label removeFromSuperview];
  [_recentLabels removeAllObjects];
  for (NSDictionary *row in _recentRows) {
    UILabel *label = [[UILabel alloc] init];
    label.backgroundColor = [UIColor clearColor];
    label.font = [UIFont systemFontOfSize:20];
    label.textColor = [DBCallHistoryModel rowIsMissed:row] ? _palette.danger : _palette.ink;
    NSString *door = [DBConfigUtil evStr:row key:@"door"];
    NSDictionary *doorEntry = [DBConfigUtil dig:_cfg
        path:[NSString stringWithFormat:@"doors.%@", door]];
    NSString *doorLabel = [DBConfigUtil labelOf:doorEntry lang:_boot.uiLang fallback:door];
    NSString *outcome = [DBConfigUtil evStr:row key:@"outcome"];
    NSString *outcomeKey = [NSString stringWithFormat:@"history.outcome_%@", outcome];
    label.text = [NSString stringWithFormat:@"%@   %@   %@",
        [DBCallHistoryModel clockForTs:[DBConfigUtil longLongVal:row path:@"ts" def:0]
                         offsetMinutes:_tzOffsetMinutes],
        doorLabel, [_texts ts:outcomeKey]];
    [_recentList addSubview:label];
    [_recentLabels addObject:label];
  }
  _recentEmpty.hidden = ([_recentLabels count] > 0);
  [self setNeedsLayout];
}

#pragma mark - door stills

- (void)refreshSnapshots {
  if (self.superview == nil) return;
  _snapshotTick++;
  if (_safeMode && (_snapshotTick % kSafeModeSnapshotEveryNTicks) != 0) return;
  CGFloat maxSide = _safeMode ? kSafeModeSnapshotMaxSide : kSnapshotMaxSide;
  NSInteger generation = ++_snapshotGeneration;
  for (DBDoorTile *tile in _doorTiles) {
    // The still comes off the serving peer's own media origin, resolved once in
    // DBMediaSource; the dashboard never guesses a host or a port of its own.
    if (!tile.online || [tile.snapshotURL length] == 0) continue;
    NSURL *url = [NSURL URLWithString:tile.snapshotURL];
    if (url == nil) continue;
    __weak DBDoorTile *weakTile = tile;
    __weak DBHomeScreen *weakSelf = self;
    // One still per door every five seconds (fifteen in safe mode), fetched and
    // downscaled entirely off the main thread: a full-size JPEG decode on the
    // main run loop of an iPad 1 is visible as a dropped clock second.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
      NSURLRequest *request = [NSURLRequest requestWithURL:url
                                              cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                          timeoutInterval:3.0];
      NSURLResponse *response = nil;
      NSError *error = nil;
      NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response
                                                       error:&error];
      UIImage *image = data ? [UIImage imageWithData:data] : nil;
      UIImage *thumbnail = [DBHomeScreen thumbnailForImage:image maxSide:maxSide];
      // A door that is online but never shows a picture is otherwise silent.
      if (thumbnail == nil) {
        NSLog(@"[doorbell] still fetch failed for %@: %lu bytes, image=%d, %@", url,
              (unsigned long)[data length], image != nil, error ?: (id)@"no error");
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        DBHomeScreen *screen = weakSelf;
        DBDoorTile *strongTile = weakTile;
        if (!screen || !strongTile || screen->_snapshotGeneration != generation) return;
        if (thumbnail != nil && strongTile.online) strongTile.still.image = thumbnail;
      });
    });
  }
}

+ (UIImage *)thumbnailForImage:(UIImage *)image maxSide:(CGFloat)maxSide {
  if (image == nil) return nil;
  CGSize size = image.size;
  if (size.width <= 0 || size.height <= 0) return nil;
  CGFloat scale = MIN(1.0, maxSide / MAX(size.width, size.height));
  CGSize target = CGSizeMake(floor(size.width * scale), floor(size.height * scale));
  if (target.width < 1 || target.height < 1) return nil;
  UIGraphicsBeginImageContext(target);
  [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
  UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return out;
}

#pragma mark - actions

- (void)onDoorTile:(DBDoorTile *)sender {
  if (sender.peer == nil) return;
  [_router showMonitorPeer:sender.peer];
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

- (void)onAdmin {
  __weak DBHomeScreen *weakSelf = self;
  [_router requestPinThen:^{
    DBHomeScreen *screen = weakSelf;
    if (screen) [screen.router showSettings];
  }];
}

- (void)onHistory {
  // Opening the history marks the missed calls seen, which clears the badge.
  [_router showHistory];
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

- (void)onSecretCorner {
  NSDate *now = [NSDate date];
  if ([now timeIntervalSinceDate:_secretFirst] > 5) {
    _secretFirst = now;
    _secretTaps = 0;
  }
  _secretTaps++;
  if (_secretTaps < 7) return;
  _secretTaps = 0;
  __weak DBHomeScreen *weakSelf = self;
  [_router requestPinThen:^{
    DBHomeScreen *screen = weakSelf;
    if (screen) [screen.router showInfo];
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
  _sos.hidden = !show;
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

- (void)appendEvent:(NSDictionary *)ev {
  (void)ev;
  // The volatile ticker is gone: the dashboard renders the durable call log
  // instead, so a refresh is the correct response to any call-lifecycle event.
  [self refreshFromCore];
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
  [_palette setBackgroundSampler:_sampler];
  [_palette applyInkToLabel:_clockLabel region:DBUiRegionClock];
  [_palette applyInkToLabel:_dateLabel region:DBUiRegionDate];
  [_palette applyInkToLabel:_doorsCaption region:DBUiRegionStatusLine];
  [_palette applyInkToLabel:_recentCaption region:DBUiRegionStatusLine];
  [_palette applyInkToLabel:_recentEmpty region:DBUiRegionHint];
  [_palette applyInkToLabel:_versionLabel region:DBUiRegionStatusLine];
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
  [self applyPalette];
  self.backgroundColor = _palette.surface;
}

- (void)exitSafeMode {
  if (!_safeMode) return;
  _safeMode = NO;
  [self applyTheme];
  [self applyDisplay];
  [self refreshSnapshots];
}

#pragma mark - layout

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  BOOL portrait = size.height > size.width;
  CGFloat pad = 20;
  _themeBg.frame = self.bounds;
  _nightTint.frame = self.bounds;
  _offlineView.frame = self.bounds;
  _emergencyView.frame = self.bounds;
  _noticeDialog.frame = self.bounds;
  _secretCorner.frame = CGRectMake(size.width - 120, 0, 120, 120);

  // Header: clock and date on the left, status controls on the right. The
  // boxes are derived from the fonts, so a larger size moves what follows
  // instead of overlapping it.
  CGFloat clockHeight = ceilf((float)_clockLabel.font.lineHeight) + 4;
  CGFloat dateHeight = ceilf((float)_dateLabel.font.lineHeight) + 2;
  _clockLabel.frame = CGRectMake(pad, 10, size.width * 0.5, clockHeight);
  _dateLabel.frame = CGRectMake(pad + 4, CGRectGetMaxY(_clockLabel.frame) + 2,
                                size.width * 0.5, dateHeight);
  CGFloat headerBottom = CGRectGetMaxY(_dateLabel.frame);

  CGFloat rightX = size.width - pad;
  CGSize adminFit = [_adminButton sizeThatFits:CGSizeMake(200, 40)];
  CGFloat adminWidth = MAX(96, adminFit.width);
  _adminButton.frame = CGRectMake(rightX - adminWidth, 18, adminWidth, 40);
  rightX -= adminWidth + 10;

  CGSize noticeFit = [_globalNoticeChip sizeThatFits:CGSizeMake(320, 40)];
  CGFloat noticeWidth = MIN(300, MAX(140, noticeFit.width + 14));
  _globalNoticeChip.frame = CGRectMake(rightX - noticeWidth, 18, noticeWidth, 40);
  rightX -= noticeWidth + 10;

  if (!_missedBadge.hidden) {
    CGSize missedFit = [_missedBadge sizeThatFits:CGSizeMake(260, 36)];
    CGFloat missedWidth = MIN(260, MAX(120, missedFit.width));
    _missedBadge.frame = CGRectMake(rightX - missedWidth, 20, missedWidth, 36);
    _missedButton.frame = _missedBadge.frame;
    rightX -= missedWidth + 10;
  }

  // One row of counters, right aligned under the admin button. Each sizes to
  // its own glyph and number, so a three-digit fleet does not clip.
  CGFloat counterHeight = 34;
  CGFloat counterTop = CGRectGetMaxY(_adminButton.frame) + 8;
  CGFloat counterGap = 8;
  CGFloat counterRight = size.width - pad;
  for (NSInteger i = (NSInteger)[_fleetCounters count] - 1; i >= 0; i--) {
    DBFleetCounter *counter = [_fleetCounters objectAtIndex:(NSUInteger)i];
    CGFloat width = [counter widthThatFits];
    counter.frame = CGRectMake(counterRight - width, counterTop, width, counterHeight);
    counterRight -= width + counterGap;
  }
  CGFloat countersLeft = counterRight + counterGap;
  _membershipButton.frame = CGRectMake(countersLeft, counterTop,
                                       MAX(0, size.width - pad - countersLeft), counterHeight);

  CGFloat bannerHeight = 0;
  if (_pairBanner.hidden) {
    _pairBanner.frame = CGRectZero;
  } else {
    CGFloat bannerWidth = MIN(size.width - 2 * pad, 560);
    _pairBanner.frame = CGRectMake((size.width - bannerWidth) / 2, headerBottom + 6,
                                   bannerWidth, 46);
    bannerHeight = 54;
  }

  CGFloat contentTop = headerBottom + 28 + bannerHeight;
  // The QR, the version line and the SOS slider are placed by one shared,
  // host-tested split so they can never overlap in either orientation.
  NSDictionary *footer = [DBUiTheme footerLayoutForViewWidth:size.width
                                                  viewHeight:size.height
                                                    portrait:portrait
                                                  sosVisible:!_sos.hidden];
  CGFloat footerHeight = (CGFloat)[[footer objectForKey:@"height"] doubleValue];
  CGFloat contentHeight = MAX(120, size.height - contentTop - footerHeight);

  CGFloat tilesWidth, tilesHeight, listX, listY, listWidth, listHeight;
  if (portrait) {
    // Portrait stacks the tiles above the call list (spec §4.2 responsiveness).
    tilesWidth = size.width - 2 * pad;
    tilesHeight = MIN(contentHeight * 0.5, 220);
    listX = pad;
    listY = contentTop + tilesHeight + 44;
    listWidth = tilesWidth;
    listHeight = MAX(80, contentHeight - tilesHeight - 44);
  } else {
    tilesWidth = (size.width - 3 * pad) * 0.55;
    tilesHeight = contentHeight;
    listX = pad + tilesWidth + pad;
    listY = contentTop;
    listWidth = size.width - listX - pad;
    listHeight = contentHeight;
  }

  _doorsCaption.frame = CGRectMake(pad, contentTop - 24, tilesWidth, 20);
  NSInteger count = (NSInteger)[_doorTiles count];
  if (count > 0) {
    NSInteger columns = (count == 1) ? 1 : 2;
    NSInteger rows = (count + columns - 1) / columns;
    CGFloat gap = 12;
    CGFloat tileWidth = (tilesWidth - gap * (columns - 1)) / columns;
    CGFloat tileHeight = MIN(200, (tilesHeight - gap * (rows - 1)) / MAX(1, rows));
    for (NSInteger i = 0; i < count; i++) {
      DBDoorTile *tile = [_doorTiles objectAtIndex:(NSUInteger)i];
      tile.frame = CGRectMake(pad + (i % columns) * (tileWidth + gap),
                              contentTop + (i / columns) * (tileHeight + gap),
                              tileWidth, tileHeight);
    }
  }

  CGSize seeAllFit = [_seeAllButton sizeThatFits:CGSizeMake(listWidth, 36)];
  CGFloat seeAllWidth = MIN(listWidth * 0.6, MAX(104, seeAllFit.width + 8));
  _recentCaption.frame = CGRectMake(listX, listY - 26, listWidth - seeAllWidth - 10, 24);
  _seeAllButton.frame = CGRectMake(listX + listWidth - seeAllWidth, listY - 30,
                                   seeAllWidth, 34);
  _recentList.frame = CGRectMake(listX, listY, listWidth, listHeight);
  CGFloat rowY = 0;
  for (UILabel *label in _recentLabels) {
    label.frame = CGRectMake(0, rowY, listWidth, 34);
    rowY += 36;
  }
  _recentList.contentSize = CGSizeMake(listWidth, rowY);
  _recentEmpty.frame = CGRectMake(listX, listY + 8, listWidth, 26);

  // Footer: admin QR (always), version + battery, SOS slider.
  _qr.frame = DBRectFromArray([footer objectForKey:@"qr"]);
  _versionLabel.frame = DBRectFromArray([footer objectForKey:@"version"]);
  _sos.frame = DBRectFromArray([footer objectForKey:@"sos"]);

  CGFloat replyWidth = MIN(size.width - 40, 560);
  _replyBanner.frame = CGRectMake((size.width - replyWidth) / 2, 20, replyWidth, 96);
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
