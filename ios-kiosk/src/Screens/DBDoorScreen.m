#import "DBDoorScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBPairingModel.h"
#import "../Core/DBCompatibilityProfile.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBMediaSource.h"
#import "../Core/DBSemanticStyle.h"
#import "../Core/DBTexts.h"
#import "../Core/DBNoticeModel.h"
#import "../Core/DBPurposeModel.h"
#import "../Core/DBUiTheme.h"
#import "../Media/DBSiren.h"
#import "../Net/DBMjpegClient.h"
#import "../Net/DBRTSPH264Source.h"
#import "../Net/DBSnapshotPoller.h"
#import "DBRouter.h"
#import "DBWidgets.h"
#import <math.h>

static CGFloat DBDoorStyleNumber(NSDictionary *style, NSString *key, CGFloat fallback,
                                 CGFloat minimum, CGFloat maximum) {
  id value = [style objectForKey:key];
  if (![value isKindOfClass:[NSNumber class]]) return fallback;
  double number = [(NSNumber *)value doubleValue];
  if (!isfinite(number) || number < minimum || number > maximum) return fallback;
  return (CGFloat)number;
}

static UIColor *DBDoorStyleColor(NSDictionary *style, NSString *key, UIColor *fallback) {
  id value = [style objectForKey:key];
  if (![value isKindOfClass:[NSString class]]) return fallback;
  UIColor *color = [DBConfigUtil parseHexColor:value];
  return color ?: fallback;
}

static void DBApplyDoorButtonStyle(UIButton *button, NSDictionary *style,
                                   UIColor *foreground, UIColor *background,
                                   CGFloat radius) {
  [button setTitleColor:DBDoorStyleColor(style, @"foreground", foreground)
               forState:UIControlStateNormal];
  button.backgroundColor = DBDoorStyleColor(style, @"background", background);
  UIColor *border = DBDoorStyleColor(style, @"border", nil);
  button.layer.borderColor = border ? border.CGColor : [UIColor clearColor].CGColor;
  button.layer.borderWidth = border ? 2.0 : 0.0;
  button.layer.cornerRadius = DBDoorStyleNumber(style, @"radius", radius, 0, 44);
}

static CGRect DBScaledDoorFrame(CGRect base, CGFloat scale, CGSize bounds, CGFloat margin) {
  CGFloat width = MIN(CGRectGetWidth(base) * scale, MAX(44, bounds.width - 2 * margin));
  CGFloat height = MIN(CGRectGetHeight(base) * scale, MAX(44, bounds.height * 0.28));
  return CGRectMake(CGRectGetMidX(base) - width / 2, CGRectGetMidY(base) - height / 2,
                    width, height);
}

typedef enum {
  DBDoorFlowIdle = 0,
  DBDoorFlowCalling,
  DBDoorFlowInCall
} DBDoorFlowState;

static const NSTimeInterval kDoorCallTimeoutS = 30.0;

typedef enum {
  DBDoorPurposeAlertNone = 0,
  DBDoorPurposeAlertLocal,
  DBDoorPurposeAlertActiveCall
} DBDoorPurposeAlertMode;

@interface DBDoorScreen () <UIAlertViewDelegate, DBSosSliderDelegate>
- (BOOL)beginCallWithPurpose:(NSString *)purpose;
- (void)presentPurposeAlertForActiveCall:(BOOL)activeCall;
- (void)configureRTSPSource;
- (void)configureLocalPreview;
- (void)startSnapshotPreviewForGeneration:(NSUInteger)generation;
- (void)stopLocalPreview;
- (void)publishMediaSourceStatus;
@end

@implementation DBDoorScreen {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  NSDictionary *_cfg;
  DBDoorFlowState _flowState;
  NSString *_visitorLang;
  NSString *_callingTitleOverride;
  NSInteger _snapshotGeneration;
  NSTimer *_callTimer;
  NSTimer *_replyTimer;
  DBSiren *_feedbackAudio;
  DBSiren *_replyAudio;
  DBSiren *_alarmAudio;
  DBMediaSource *_mediaSource;
  DBRTSPH264Source *_rtspSource;
  NSString *_rtspSourceRef;
  NSString *_rtspURL;
  NSString *_rtspSecretRef;
  NSString *_rtspState;
  NSString *_rtspReason;
  BOOL _rtspForwardingMeasured;
  BOOL _rtspSuspendedForMemoryPressure;
  NSUInteger _rtspGeneration;
  DBMjpegClient *_previewMjpeg;
  DBSnapshotPoller *_previewSnapshot;
  NSString *_previewSourceRef;
  NSString *_previewMjpegURL;
  NSString *_previewSnapshotURL;
  NSString *_previewSecretRef;
  NSString *_previewTransport;
  NSString *_previewState;
  NSString *_previewReason;
  BOOL _previewMeasured;
  BOOL _safeMode;
  BOOL _mediaSuspendedForBackground;
  NSUInteger _previewGeneration;
  NSString *_deviceID;
  NSString *_activeCallID;
  NSInteger _activeStageRevision;
  int64_t _activeCallExpiresAtMs;
  DBDoorPurposeAlertMode _purposeAlertMode;
  NSArray *_purposeAlertIDs;
  NSInteger _purposeSkipIndex;
  NSString *_purposePromptedCallID;

  UILabel *_titleLabel;
  UIImageView *_cameraPreviewView;
  UILabel *_touchHint;
  UILabel *_mediaBadge;
  UIButton *_callButton;
  UILabel *_purposeHint;
  UIScrollView *_purposeScroll;
  NSMutableArray *_purposeButtons;
  NSArray *_purposeIds;
  UIView *_languageBar;
  NSMutableArray *_languageButtons;
  NSArray *_languages;
  UIView *_callingOverlay;
  UILabel *_callingLabel;
  UIView *_pulse;
  UIButton *_cancelButton;
  UIView *_replyBanner;
  UILabel *_replyText;
  UIView *_emergencyOverlay;
  UILabel *_emergencyTitle;
  UILabel *_emergencyNote;
  UIButton *_emergencyCancel;
  UIButton *_infoButton;      // Invisible 7-tap corner; a visitor sees no admin entry.
  NSInteger _adminTaps;
  NSDate *_adminFirstTap;
  UIButton *_pairBanner;      // pair.not_set_up_banner while the node is not ready.
  NSString *_pairingState;

  // Batch-2 visitor screen (spec §4.2, §5.1).
  UILabel *_clockLabel;
  UILabel *_dateLabel;
  UILabel *_noticeLabel;
  UIButton *_noticeExpand;
  BOOL _noticeExpanded;
  UILabel *_versionLabel;
  NSDictionary *_display;   // status.display: core-resolved appearance and theme.
  NSDictionary *_status;
  DBSosSlider *_sos;
  DBUiPalette *_palette;
  NSTimer *_clockTimer;
  NSInteger _tzOffsetMinutes;
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _router = router;
    _core = router.core;
    _boot = router.boot;
    _texts = router.texts;
    _visitorLang = [_boot.uiLang length] ? _boot.uiLang : @"ja";
    _purposeButtons = [[NSMutableArray alloc] init];
    _languageButtons = [[NSMutableArray alloc] init];
    _adminFirstTap = [NSDate distantPast];
    _feedbackAudio = [[DBSiren alloc] init];
    _replyAudio = [[DBSiren alloc] init];
    _alarmAudio = [[DBSiren alloc] init];
    [self buildUI];
  }
  return self;
}

- (void)dealloc {
  // Never leave a repeating run-loop timer behind a released screen.
  [_clockTimer invalidate];
  [_callTimer invalidate];
  [_replyTimer invalidate];
}

- (NSString *)screenName {
  switch (_flowState) {
    case DBDoorFlowCalling: return @"door_calling";
    case DBDoorFlowInCall: return @"door_in_call";
    default: return @"door_idle";
  }
}

- (UIButton *)buttonWithTitle:(NSString *)title primary:(BOOL)primary {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
  [button setTitle:title forState:UIControlStateNormal];
  [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  button.titleLabel.font = [UIFont boldSystemFontOfSize:24];
  button.titleLabel.adjustsFontSizeToFitWidth = YES;
  button.titleLabel.minimumFontSize = 13;
  button.titleLabel.numberOfLines = 3;
  button.titleLabel.textAlignment = NSTextAlignmentCenter;
  button.backgroundColor = primary
      ? [UIColor colorWithRed:0.094 green:0.478 blue:0.235 alpha:1]
      : [UIColor colorWithWhite:1 alpha:0.12];
  button.layer.cornerRadius = 14;
  return button;
}

- (void)buildUI {
  self.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1];

  _cameraPreviewView = [[UIImageView alloc] initWithFrame:self.bounds];
  _cameraPreviewView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
      UIViewAutoresizingFlexibleHeight;
  _cameraPreviewView.contentMode = UIViewContentModeScaleAspectFill;
  _cameraPreviewView.clipsToBounds = YES;
  _cameraPreviewView.alpha = 0.18;
  _cameraPreviewView.hidden = YES;
  _cameraPreviewView.accessibilityIdentifier = @"door_camera_local_preview";
  [self addSubview:_cameraPreviewView];

  _titleLabel = [[UILabel alloc] init];
  _titleLabel.font = [UIFont boldSystemFontOfSize:42];
  _titleLabel.textColor = [UIColor whiteColor];
  _titleLabel.textAlignment = NSTextAlignmentCenter;
  _titleLabel.adjustsFontSizeToFitWidth = YES;
  _titleLabel.minimumFontSize = 22;
  [self addSubview:_titleLabel];

  _touchHint = [[UILabel alloc] init];
  _touchHint.font = [UIFont systemFontOfSize:21];
  _touchHint.textColor = [UIColor colorWithWhite:1 alpha:0.65];
  _touchHint.textAlignment = NSTextAlignmentCenter;
  [self addSubview:_touchHint];

  _mediaBadge = [[UILabel alloc] init];
  _mediaBadge.font = [UIFont boldSystemFontOfSize:14];
  _mediaBadge.textAlignment = NSTextAlignmentCenter;
  _mediaBadge.layer.cornerRadius = 8;
  _mediaBadge.clipsToBounds = YES;
  _mediaBadge.accessibilityIdentifier = @"door_media_source";
  [self addSubview:_mediaBadge];

  _callButton = [self buttonWithTitle:@"" primary:YES];
  _callButton.accessibilityIdentifier = @"door_call";
  [_callButton addTarget:self action:@selector(onCall) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_callButton];

  _purposeHint = [[UILabel alloc] init];
  _purposeHint.font = [UIFont systemFontOfSize:20];
  _purposeHint.textColor = [UIColor colorWithWhite:1 alpha:0.7];
  _purposeHint.textAlignment = NSTextAlignmentCenter;
  [self addSubview:_purposeHint];

  _purposeScroll = [[UIScrollView alloc] init];
  _purposeScroll.alwaysBounceVertical = YES;
  [self addSubview:_purposeScroll];

  _languageBar = [[UIView alloc] init];
  [self addSubview:_languageBar];

  // A door station that was skipped with 「あとで設定」 keeps a persistent,
  // tappable reminder instead of silently running unpaired.
  _pairBanner = [self buttonWithTitle:@"" primary:NO];
  _pairBanner.backgroundColor = [UIColor colorWithRed:0.72 green:0.45 blue:0.10 alpha:1];
  _pairBanner.titleLabel.font = [UIFont boldSystemFontOfSize:18];
  _pairBanner.layer.cornerRadius = 10;
  _pairBanner.accessibilityIdentifier = @"door_pair_banner";
  _pairBanner.hidden = YES;
  [_pairBanner addTarget:self action:@selector(onPairBanner)
        forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_pairBanner];

  // A door station shows no admin entry at all (spec §0.2): the corner is
  // invisible and needs seven taps plus the admin password.
  _infoButton = [UIButton buttonWithType:UIButtonTypeCustom];
  _infoButton.backgroundColor = [UIColor clearColor];
  _infoButton.accessibilityIdentifier = @"door_admin_corner";
  [_infoButton addTarget:self action:@selector(onAdminCorner)
        forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_infoButton];

  // Large HH:MM:SS plus the date, on every size (spec §5.1).
  _clockLabel = [[UILabel alloc] init];
  _clockLabel.backgroundColor = [UIColor clearColor];
  _clockLabel.textAlignment = NSTextAlignmentCenter;
  _clockLabel.font = [UIFont systemFontOfSize:72];
  [self addSubview:_clockLabel];

  _dateLabel = [[UILabel alloc] init];
  _dateLabel.backgroundColor = [UIColor clearColor];
  _dateLabel.textAlignment = NSTextAlignmentCenter;
  _dateLabel.font = [UIFont systemFontOfSize:22];
  [self addSubview:_dateLabel];

  // The visitor sees the announcement text only: no source line and no expiry.
  _noticeLabel = [[UILabel alloc] init];
  _noticeLabel.backgroundColor = [UIColor clearColor];
  _noticeLabel.font = [UIFont systemFontOfSize:22];
  _noticeLabel.numberOfLines = 2;
  _noticeLabel.hidden = YES;
  [self addSubview:_noticeLabel];

  _noticeExpand = [UIButton buttonWithType:UIButtonTypeCustom];
  _noticeExpand.backgroundColor = [UIColor clearColor];
  _noticeExpand.hidden = YES;
  [_noticeExpand addTarget:self action:@selector(onToggleNotice)
          forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_noticeExpand];

  _versionLabel = [[UILabel alloc] init];
  _versionLabel.backgroundColor = [UIColor clearColor];
  _versionLabel.font = [UIFont systemFontOfSize:13];
  _versionLabel.textAlignment = NSTextAlignmentCenter;
  [self addSubview:_versionLabel];

  _sos = [[DBSosSlider alloc] initWithFrame:CGRectZero];
  _sos.delegate = self;
  _sos.hidden = YES;
  [self addSubview:_sos];

  _replyBanner = [[UIView alloc] init];
  _replyBanner.backgroundColor = [UIColor colorWithRed:0.10 green:0.34 blue:0.17 alpha:0.98];
  _replyBanner.layer.cornerRadius = 14;
  _replyBanner.hidden = YES;
  _replyText = [[UILabel alloc] init];
  _replyText.font = [UIFont boldSystemFontOfSize:28];
  _replyText.textColor = [UIColor whiteColor];
  _replyText.textAlignment = NSTextAlignmentCenter;
  _replyText.numberOfLines = 4;
  [_replyBanner addSubview:_replyText];
  [self addSubview:_replyBanner];

  _callingOverlay = [[UIView alloc] init];
  _callingOverlay.backgroundColor = [UIColor colorWithRed:0.035 green:0.045 blue:0.06 alpha:0.99];
  _callingOverlay.hidden = YES;
  _pulse = [[UIView alloc] init];
  _pulse.backgroundColor = [UIColor colorWithRed:0.2 green:0.75 blue:0.4 alpha:1];
  _pulse.layer.cornerRadius = 55;
  [_callingOverlay addSubview:_pulse];
  _callingLabel = [[UILabel alloc] init];
  _callingLabel.font = [UIFont boldSystemFontOfSize:44];
  _callingLabel.textColor = [UIColor whiteColor];
  _callingLabel.textAlignment = NSTextAlignmentCenter;
  _callingLabel.numberOfLines = 3;
  [_callingOverlay addSubview:_callingLabel];
  _cancelButton = [self buttonWithTitle:@"" primary:NO];
  _cancelButton.backgroundColor = [UIColor colorWithRed:0.75 green:0.16 blue:0.13 alpha:1];
  _cancelButton.accessibilityIdentifier = @"door_cancel_call";
  [_cancelButton addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
  [_callingOverlay addSubview:_cancelButton];
  [self addSubview:_callingOverlay];

  _emergencyOverlay = [[UIView alloc] init];
  _emergencyOverlay.backgroundColor = [UIColor colorWithRed:0.52 green:0.0 blue:0.0 alpha:0.98];
  _emergencyOverlay.hidden = YES;
  _emergencyTitle = [[UILabel alloc] init];
  _emergencyTitle.font = [UIFont boldSystemFontOfSize:56];
  _emergencyTitle.textColor = [UIColor whiteColor];
  _emergencyTitle.textAlignment = NSTextAlignmentCenter;
  [_emergencyOverlay addSubview:_emergencyTitle];
  _emergencyNote = [[UILabel alloc] init];
  _emergencyNote.font = [UIFont systemFontOfSize:25];
  _emergencyNote.textColor = [UIColor whiteColor];
  _emergencyNote.textAlignment = NSTextAlignmentCenter;
  [_emergencyOverlay addSubview:_emergencyNote];
  _emergencyCancel = [self buttonWithTitle:@"" primary:NO];
  [_emergencyCancel addTarget:self action:@selector(onEmergencyCancel)
               forControlEvents:UIControlEventTouchUpInside];
  [_emergencyOverlay addSubview:_emergencyCancel];
  [self addSubview:_emergencyOverlay];

  [self clearLabelBackgrounds:self];
  _mediaBadge.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
  _replyBanner.backgroundColor = [UIColor colorWithRed:0.10 green:0.34 blue:0.17 alpha:0.98];
}

- (void)onScreenWillAppear {
  if (!_clockTimer) {
    _clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                 selector:@selector(updateClock)
                                                 userInfo:nil repeats:YES];
  }
  [self updateClock];
  [self refreshFromCore];
  [self applyStrings];
}

// Rendered from Core's local-time document: no operating-system time-zone
// database is needed and the clock follows the cluster zone and NTP offset.
- (void)updateClock {
  NSDictionary *local = [_core localTimeJson:0];
  if (![local isKindOfClass:[NSDictionary class]]) return;
  NSInteger hh = [DBConfigUtil intVal:local path:@"hh" def:-1];
  if (hh < 0) return;
  _clockLabel.text = [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)hh,
                      (long)[DBConfigUtil intVal:local path:@"mm" def:0],
                      (long)[DBConfigUtil intVal:local path:@"ss" def:0]];
  _tzOffsetMinutes = [DBConfigUtil intVal:local path:@"offset_min" def:_tzOffsetMinutes];
  NSArray *parts = [[DBConfigUtil str:local path:@"date"] componentsSeparatedByString:@"-"];
  if ([parts count] != 3) return;
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

- (NSInteger)minuteOfDay {
  NSArray *parts = [_clockLabel.text componentsSeparatedByString:@":"];
  if ([parts count] < 2) return 12 * 60;
  return [[parts objectAtIndex:0] integerValue] * 60 + [[parts objectAtIndex:1] integerValue];
}

- (void)onToggleNotice {
  _noticeExpanded = !_noticeExpanded;
  _noticeLabel.numberOfLines = _noticeExpanded ? 0 : 2;
  [self setNeedsLayout];
}

// The call button colour is computed from the effective background: hue rotated
// by 180 degrees and lightness moved until it separates, with the local
// fallback used whenever core published no auto_accent (spec §5.2).
- (void)applyVisitorTheme {
  NSString *background = [DBConfigUtil str:_cfg path:[NSString stringWithFormat:
      @"devices.%@.local.theme.bg_color", _deviceID]];
  if ([background length] == 0)
    background = [DBConfigUtil str:_cfg path:@"display.theme.bg_color"];
  _palette = [DBUiPalette paletteForConfig:_cfg deviceId:_deviceID display:_display
                             backgroundHex:background minuteOfDay:[self minuteOfDay]];
  UIColor *surface = _palette.surface;
  if (_cameraPreviewView.hidden) self.backgroundColor = surface;
  // The per-region colours land after layout, when each frame is known.
  [self applyRegionInk];
  [_sos applyPalette:_palette];
  [_sos applyConfig:_cfg texts:_texts];

  // An explicit semantic override still wins; otherwise the computed accent is
  // what the visitor sees.
  NSDictionary *callStyle = [self styleForSemanticID:@"call.primary"];
  if ([callStyle objectForKey:@"background"] == nil) {
    _callButton.backgroundColor = _palette.accent;
    [_callButton setTitleColor:_palette.accentInk forState:UIControlStateNormal];
  }

  BOOL showSos = NO;
  id roles = [DBConfigUtil dig:_cfg path:@"emergency.button_on_roles"];
  if ([roles isKindOfClass:[NSArray class]]) {
    for (id role in (NSArray *)roles)
      if ([role isKindOfClass:[NSString class]] &&
          [(NSString *)role isEqualToString:@"door_station"])
        showSos = YES;
  }
  _sos.hidden = !showSos;

  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  NSDictionary *notice = [DBNoticeModel effectiveNoticeForDoor:_boot.door config:_cfg
                                                          nowMs:nowMs];
  NSString *text = notice ? [DBNoticeModel noticeText:notice] : @"";
  _noticeLabel.text = text;
  _noticeLabel.hidden = ([text length] == 0);
  _noticeExpand.hidden = _noticeLabel.hidden;

  NSDictionary *power = [_core powerStateNow];
  NSString *appVersion = [[NSBundle mainBundle]
      objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
  _versionLabel.text = [DBUiTheme versionLineForName:[self doorLabel]
                                         coreVersion:[_core coreVersion]
                                          appVersion:appVersion
                                          batteryPct:[DBConfigUtil intVal:power
                                                                      path:@"battery_pct" def:-1]
                                            charging:[DBConfigUtil boolVal:power
                                                                      path:@"charging" def:NO]];
}

// Each text region takes the ink measured behind its own frame. The visitor
// screen paints a flat background today, so this resolves to core's per-region
// decision plus any administrator override; it is the same code path the
// dashboard uses over a theme image.
- (void)applyRegionInk {
  if (_palette == nil) return;
  [_palette applyInkToLabel:_clockLabel region:DBUiRegionClock];
  [_palette applyInkToLabel:_dateLabel region:DBUiRegionDate];
  [_palette applyInkToLabel:_touchHint region:DBUiRegionHint];
  [_palette applyInkToLabel:_noticeLabel region:DBUiRegionStatusLine];
  [_palette applyInkToLabel:_versionLabel region:DBUiRegionStatusLine];
  [_palette applyInkToLabel:_titleLabel region:DBUiRegionTileLabel];
}

- (void)sosSliderDidArm:(DBSosSlider *)slider { (void)slider; }
- (void)sosSliderDidCancel:(DBSosSlider *)slider { (void)slider; }

- (void)sosSliderDidFire:(DBSosSlider *)slider {
  (void)slider;
  (void)[_core emergency:YES];
}

- (void)onScreenWillDisappear {
  // Flow timers deliberately survive the admin/info overlay. A visitor call
  // must still expire and be cancelled while maintenance UI is visible.
}

- (void)refreshFromCore {
  NSInteger generation = ++_snapshotGeneration;
  DBCoreBridge *core = _core;
  __weak DBDoorScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *config = [core config];
    NSDictionary *status = [core status];
    NSDictionary *pairing = [core pairingInfo];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBDoorScreen *screen = weakSelf;
      if (!screen || generation != screen->_snapshotGeneration) return;
      [screen applyPairingSnapshot:pairing];
      screen->_cfg = config;
      screen->_status = status;
      NSDictionary *display = [status objectForKey:@"display"];
      if ([display isKindOfClass:[NSDictionary class]]) screen->_display = display;
      [screen->_texts setConfig:config];
      NSString *langPath = [NSString stringWithFormat:@"visitor_lang.%@", screen->_boot.door];
      NSString *lang = [DBConfigUtil str:status path:langPath];
      if ([lang length] > 0) screen->_visitorLang = lang;
      [screen->_texts setLang:screen->_visitorLang];
      NSString *selfID = [DBConfigUtil str:status path:@"node.id"];
      screen->_deviceID = [selfID copy];
      screen->_mediaSource = [DBMediaSource sourceForPeer:nil config:config
                                                      boot:screen->_boot door:screen->_boot.door
                                                  deviceID:selfID];
      [screen configureRTSPSource];
      [screen configureLocalPreview];
      NSDictionary *waitingCall = nil;
      NSArray *activeCalls = [status objectForKey:@"active_calls"];
      if ([activeCalls isKindOfClass:[NSArray class]]) {
        for (id rawCall in activeCalls) {
          if (![rawCall isKindOfClass:[NSDictionary class]]) continue;
          NSDictionary *call = rawCall;
          NSString *door = [DBConfigUtil evStr:call key:@"door"];
          NSString *callID = [DBConfigUtil evStr:call key:@"call_id"];
          if (![door isEqualToString:screen->_boot.door] || [callID length] == 0) continue;
          waitingCall = call;
          break;
        }
      }
      [screen publishMediaSourceStatus];
      [screen applyTheme];
      [screen rebuildPurposes];
      [screen rebuildLanguages];
      if (waitingCall) [screen restoreWaitingCall:waitingCall recoveryState:@""];
      [screen applyStrings];
      [screen applySemanticStyles];
      [screen setNeedsLayout];
    });
  });
}

- (void)applyPairingSnapshot:(NSDictionary *)pairing {
  NSString *state = [DBPairingModel stateFromPairingInfo:pairing];
  if (![state isEqualToString:DBPairingStateUnknown]) _pairingState = state;
  BOOL ready = [_pairingState isEqualToString:@"ready"];
  BOOL known = [_pairingState length] > 0 &&
      ![_pairingState isEqualToString:DBPairingStateUnknown];
  [_pairBanner setTitle:[_texts ts:@"pair.not_set_up_banner"] forState:UIControlStateNormal];
  _pairBanner.hidden = ready || !known;
  [self setNeedsLayout];
}

- (void)onPairBanner {
  [_router showPairing];
}

- (void)publishMediaSourceStatus {
  if (!_mediaSource) return;
  NSString *state = nil;
  NSString *reason = @"";
  if (_rtspForwardingMeasured) {
    state = @"ready";
  } else if (_mediaSource.h264SourceAvailable) {
    state = @"degraded";
    if (_safeMode && ![_mediaSource supportsDirectJPEGPlayback])
      reason = @"safe_mode_no_jpeg_fallback";
    else if (_rtspSuspendedForMemoryPressure)
      reason = @"safe_mode_h264_disabled";
    else if ([_rtspReason length])
      reason = _rtspReason;
    else if ([_rtspState isEqualToString:@"waiting_for_idr"])
      reason = @"rtsp_waiting_for_idr";
    else
      reason = @"rtsp_not_forwarding";
  } else if ([_mediaSource.kind isEqualToString:@"ip_camera"] &&
             [_mediaSource supportsDirectJPEGPlayback]) {
    state = @"degraded";
    reason = _previewMeasured ? @"jpeg_core_ingest_unavailable" :
        ([_previewReason length] ? _previewReason : @"camera_preview_not_ready");
  } else {
    state = [_mediaSource.degradedReason length] > 0
        ? @"degraded" : ([_mediaSource hasPreview] ? @"ready" : @"unavailable");
    reason = _mediaSource.degradedReason ?: @"";
  }
  NSString *fallback = [_mediaSource preferredPreviewTransport];
  [_core setRuntimeStatusSection:@"media_source" value:@{
    @"schema_version" : @1,
    @"device_id" : _mediaSource.deviceID ?: @"",
    @"source_ref" : _mediaSource.sourceRef ?: @"",
    @"state" : state ?: @"unavailable",
    @"reason" : reason ?: @"",
    @"fallback" : fallback,
    @"mjpeg_preview" : @([_mediaSource.mjpegURL length] > 0),
    @"snapshot_preview" : @([_mediaSource.snapshotURL length] > 0),
    @"local_preview_ready" : @(_previewMeasured),
    @"local_preview_transport" : _previewTransport ?: @"none",
    @"mjpeg_direct_playback" : @([_mediaSource.mjpegURL length] > 0),
    @"snapshot_direct_playback" : @([_mediaSource.snapshotURL length] > 0),
    @"jpeg_core_forwarding" : @NO,
    @"h264_rtsp_source" : @(_mediaSource.h264SourceAvailable),
    @"h264_annexb_forwarding" : @(_rtspForwardingMeasured),
    @"safe_mode" : @(_safeMode),
    @"low_resource_jpeg" : @(_safeMode &&
        [_mediaSource supportsDirectJPEGPlayback]),
  }];
}

- (void)stopLocalPreview {
  _previewGeneration++;
  [_previewMjpeg stop];
  _previewMjpeg = nil;
  [_previewSnapshot stop];
  _previewSnapshot = nil;
  _previewMeasured = NO;
  _previewTransport = @"none";
  [_core setRuntimeCapability:@"ip_camera_local_preview" enabled:NO];
  _cameraPreviewView.image = nil;
  _cameraPreviewView.hidden = YES;
}

- (void)startSnapshotPreviewForGeneration:(NSUInteger)generation {
  if (_previewSnapshot || generation != _previewGeneration ||
      [_previewSnapshotURL length] == 0) return;
  NSString *secretRef = [_previewSecretRef copy];
  __weak DBDoorScreen *weakSelf = self;
  _previewSnapshot = [[DBSnapshotPoller alloc]
      initWithURLString:_previewSnapshotURL credentialProvider:^NSString * {
    DBDoorScreen *screen = weakSelf;
    if (!screen || ![secretRef hasPrefix:@"secret:"] || [secretRef length] <= 7)
      return nil;
    return [screen->_core loadSecret:[secretRef substringFromIndex:7]];
  } stateHandler:^(NSString *state, NSString *reason) {
    DBDoorScreen *screen = weakSelf;
    if (!screen || generation != screen->_previewGeneration) return;
    screen->_previewState = [state copy];
    if ([reason length]) screen->_previewReason = [reason copy];
    if ([state isEqualToString:@"retry_wait"] &&
        [screen->_previewTransport isEqualToString:@"snapshot"]) {
      screen->_previewMeasured = NO;
      screen->_previewTransport = @"none";
      [screen->_core setRuntimeCapability:@"ip_camera_local_preview" enabled:NO];
    }
    [screen publishMediaSourceStatus];
  } onFrame:^(UIImage *image) {
    DBDoorScreen *screen = weakSelf;
    if (!screen || generation != screen->_previewGeneration ||
        (screen->_previewMeasured && ![screen->_previewTransport isEqualToString:@"snapshot"]))
      return;
    screen->_previewMeasured = YES;
    screen->_previewTransport = @"snapshot";
    screen->_previewState = @"ready";
    screen->_previewReason = @"jpeg_core_ingest_unavailable";
    screen->_cameraPreviewView.image = image;
    screen->_cameraPreviewView.hidden = NO;
    [screen->_core setRuntimeCapability:@"ip_camera_local_preview" enabled:YES];
    [screen publishMediaSourceStatus];
    [screen applyStrings];
  }];
  _previewSnapshot.lowResourceMode = _safeMode;
  [_previewSnapshot start];
}

- (void)configureLocalPreview {
  BOOL sameSource = [_previewSourceRef isEqualToString:_mediaSource.sourceRef] &&
      [_previewMjpegURL isEqualToString:_mediaSource.mjpegURL] &&
      [_previewSnapshotURL isEqualToString:_mediaSource.snapshotURL] &&
      [_previewSecretRef isEqualToString:_mediaSource.secretRef];
  if (sameSource && (_previewMjpeg || _previewSnapshot ||
                     [[_mediaSource preferredPreviewTransport] isEqualToString:@"none"]))
    return;

  [self stopLocalPreview];
  _previewSourceRef = [_mediaSource.sourceRef copy];
  _previewMjpegURL = [_mediaSource.mjpegURL copy];
  _previewSnapshotURL = [_mediaSource.snapshotURL copy];
  _previewSecretRef = [_mediaSource.secretRef copy];
  _previewState = @"starting";
  _previewReason = @"";
  if (_mediaSuspendedForBackground) {
    _previewReason = @"background";
    return;
  }

  NSUInteger generation = _previewGeneration;
  NSString *preferred = [_mediaSource preferredPreviewTransport];
  if ([preferred isEqualToString:@"snapshot"]) {
    [self startSnapshotPreviewForGeneration:generation];
    return;
  }
  if (![preferred isEqualToString:@"mjpeg"]) return;

  NSString *secretRef = [_previewSecretRef copy];
  __weak DBDoorScreen *weakSelf = self;
  _previewMjpeg = [[DBMjpegClient alloc]
      initWithURLString:_previewMjpegURL credentialProvider:^NSString * {
    DBDoorScreen *screen = weakSelf;
    if (!screen || ![secretRef hasPrefix:@"secret:"] || [secretRef length] <= 7)
      return nil;
    return [screen->_core loadSecret:[secretRef substringFromIndex:7]];
  } stateHandler:^(NSString *state, NSString *reason) {
    DBDoorScreen *screen = weakSelf;
    if (!screen || generation != screen->_previewGeneration) return;
    screen->_previewState = [state copy];
    if ([reason length]) screen->_previewReason = [reason copy];
    if ([state isEqualToString:@"retry_wait"]) {
      if ([screen->_previewTransport isEqualToString:@"mjpeg"]) {
        screen->_previewMeasured = NO;
        screen->_previewTransport = @"none";
        [screen->_core setRuntimeCapability:@"ip_camera_local_preview" enabled:NO];
      }
      [screen startSnapshotPreviewForGeneration:generation];
    }
    [screen publishMediaSourceStatus];
  } onFrame:^(UIImage *image) {
    DBDoorScreen *screen = weakSelf;
    if (!screen || generation != screen->_previewGeneration) return;
    screen->_previewMeasured = YES;
    screen->_previewTransport = @"mjpeg";
    screen->_previewState = @"ready";
    screen->_previewReason = @"jpeg_core_ingest_unavailable";
    screen->_cameraPreviewView.image = image;
    screen->_cameraPreviewView.hidden = NO;
    [screen->_previewSnapshot stop];
    screen->_previewSnapshot = nil;
    [screen->_core setRuntimeCapability:@"ip_camera_local_preview" enabled:YES];
    [screen publishMediaSourceStatus];
    [screen applyStrings];
  }];
  _previewMjpeg.lowResourceMode = _safeMode;
  if (_previewMjpeg) {
    [_previewMjpeg start];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      DBDoorScreen *screen = weakSelf;
      if (!screen || generation != screen->_previewGeneration || screen->_previewMeasured)
        return;
      [screen startSnapshotPreviewForGeneration:generation];
    });
  } else {
    _previewReason = @"invalid_mjpeg_url";
    [self startSnapshotPreviewForGeneration:generation];
  }
}

- (void)configureRTSPSource {
  BOOL usable = _mediaSource.h264SourceAvailable &&
      [_mediaSource.h264Transport isEqualToString:@"tcp"] &&
      [_mediaSource.h264Profile isEqualToString:@"baseline"] &&
      [_mediaSource.h264URL length] > 0;
  if (_rtspSuspendedForMemoryPressure || _mediaSuspendedForBackground || !usable) {
    [_rtspSource stop];
    _rtspSource = nil;
    _rtspSourceRef = nil;
    _rtspURL = nil;
    _rtspSecretRef = nil;
    _rtspForwardingMeasured = NO;
    [_core setRuntimeCapability:@"rtsp_h264_forwarding" enabled:NO];
    return;
  }
  BOOL sameSource = _rtspSource && [_rtspSourceRef isEqualToString:_mediaSource.sourceRef] &&
      [_rtspURL isEqualToString:_mediaSource.h264URL] &&
      [_rtspSecretRef isEqualToString:_mediaSource.secretRef];
  if (sameSource) return;

  [_rtspSource stop];
  _rtspSource = nil;
  _rtspGeneration++;
  NSUInteger generation = _rtspGeneration;
  _rtspSourceRef = [_mediaSource.sourceRef copy];
  _rtspURL = [_mediaSource.h264URL copy];
  _rtspSecretRef = [_mediaSource.secretRef copy];
  _rtspState = @"starting";
  _rtspReason = @"";
  _rtspForwardingMeasured = NO;
  [_core setRuntimeCapability:@"rtsp_h264_forwarding" enabled:NO];

  __weak DBDoorScreen *weakSelf = self;
  NSString *secretRef = [_rtspSecretRef copy];
  DBRTSPH264Source *source = [[DBRTSPH264Source alloc]
      initWithURLString:_rtspURL
      credentialProvider:^NSString * {
        DBDoorScreen *screen = weakSelf;
        if (!screen || ![secretRef hasPrefix:@"secret:"] || [secretRef length] <= 7)
          return nil;
        return [screen->_core loadSecret:[secretRef substringFromIndex:7]];
      }
      frameHandler:^BOOL(NSData *annexB, BOOL keyframe, int64_t timestampMs) {
        DBDoorScreen *screen = weakSelf;
        return screen ? [screen->_core trySubmitEncodedFrame:annexB keyframe:keyframe
                                                 timestampMs:timestampMs] : NO;
      }
      stateHandler:^(NSString *state, NSString *reason, BOOL forwardingMeasured) {
        dispatch_async(dispatch_get_main_queue(), ^{
          DBDoorScreen *screen = weakSelf;
          if (!screen || generation != screen->_rtspGeneration) return;
          screen->_rtspState = [state copy];
          screen->_rtspReason = [reason copy];
          screen->_rtspForwardingMeasured = forwardingMeasured;
          [screen->_core setRuntimeCapability:@"rtsp_h264_forwarding"
                                      enabled:forwardingMeasured];
          [screen publishMediaSourceStatus];
          [screen applyStrings];
        });
      }];
  _rtspSource = source;
  [_rtspSource start];
}

- (void)applyTheme {
  NSString *color = [DBConfigUtil str:_cfg path:@"display.theme.bg_color"];
  UIColor *parsed = [DBConfigUtil parseHexColor:color];
  self.backgroundColor = parsed ?: [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1];
}

- (NSString *)doorLabel {
  NSDictionary *entry = [DBConfigUtil dig:_cfg
      path:[NSString stringWithFormat:@"doors.%@", _boot.door]];
  NSString *label = [DBConfigUtil labelOf:entry lang:_visitorLang fallback:_boot.door];
  return [label length] ? label : _boot.name;
}

- (void)applyStrings {
  NSString *doorLabel = [self doorLabel];
  _titleLabel.text = doorLabel;
  _touchHint.text = [_texts ts:@"door.hint_call"];
  [_callButton setTitle:[_texts t:@"idle.call_button", doorLabel, nil]
               forState:UIControlStateNormal];
  // Round 5 dropped the purpose explainer; a control shows only what it does.
  _purposeHint.text = @"";
  _callingLabel.text = _flowState == DBDoorFlowInCall
      ? [_texts ts:@"incall.title"]
      : (_callingTitleOverride ?: [_texts ts:@"calling.title"]);
  [_cancelButton setTitle:(_flowState == DBDoorFlowInCall
                               ? [_texts ts:@"incall.end"] : [_texts ts:@"calling.cancel"])
                     forState:UIControlStateNormal];
  _emergencyTitle.text = [_texts ts:@"emergency.title"];
  _emergencyNote.text = [_texts ts:@"emergency.notified"];
  [_emergencyCancel setTitle:[_texts ts:@"emergency.cancel"] forState:UIControlStateNormal];

  _mediaBadge.accessibilityValue = [_mediaSource.sourceRef length]
      ? [NSString stringWithFormat:@"source_ref=%@", _mediaSource.sourceRef] : @"";
  if (_rtspForwardingMeasured) {
    _mediaBadge.text = @" IP CAMERA · H.264 ";
    _mediaBadge.textColor = [UIColor colorWithRed:0.55 green:1 blue:0.65 alpha:1];
  } else if ([_mediaSource.kind isEqualToString:@"ip_camera"] && _previewMeasured) {
    _mediaBadge.text = [_mediaSource.degradedReason length] > 0
        ? @" IP CAMERA · PREVIEW " : @" IP CAMERA ";
    _mediaBadge.textColor = [_mediaSource.degradedReason length] > 0
        ? [UIColor colorWithRed:1 green:0.75 blue:0.25 alpha:1]
        : [UIColor colorWithRed:0.55 green:1 blue:0.65 alpha:1];
  } else if (_mediaSource.h264SourceAvailable) {
    _mediaBadge.text = @" H.264 SOURCE · DEGRADED ";
    _mediaBadge.textColor = [UIColor colorWithRed:1 green:0.55 blue:0.25 alpha:1];
  } else if ([_mediaSource hasVideo]) {
    _mediaBadge.text = @" VIDEO READY ";
    _mediaBadge.textColor = [UIColor colorWithRed:0.55 green:1 blue:0.65 alpha:1];
  } else {
    _mediaBadge.text = [NSString stringWithFormat:@" %@ ", [_texts ts:@"ring.no_video"]];
    _mediaBadge.textColor = [UIColor colorWithWhite:1 alpha:0.65];
  }
  [self applyVisitorTheme];
}

- (NSDictionary *)styleForSemanticID:(NSString *)semanticID {
  UIColor *white = [UIColor whiteColor];
  UIColor *background = [UIColor colorWithRed:0.15 green:0.16 blue:0.18 alpha:1];
  if ([semanticID isEqualToString:@"call.primary"])
    background = [UIColor colorWithRed:0.094 green:0.478 blue:0.235 alpha:1];
  else if ([semanticID isEqualToString:@"cancel.call"] ||
           [semanticID isEqualToString:@"call.end"])
    background = [UIColor colorWithRed:0.75 green:0.16 blue:0.13 alpha:1];
  BOOL safety = [semanticID isEqualToString:@"cancel.call"] ||
      [semanticID isEqualToString:@"call.end"] ||
      [semanticID isEqualToString:@"sos.cancel"];
  return [DBSemanticStyle styleForConfig:_cfg deviceID:_deviceID semanticID:semanticID
                          safetyCritical:safety baselineForeground:white
                      baselineBackground:background baselineAccent:nil baselineBorder:nil];
}

- (void)applySemanticStyles {
  UIColor *white = [UIColor whiteColor];
  UIColor *neutral = [UIColor colorWithWhite:1 alpha:0.12];
  UIColor *green = [UIColor colorWithRed:0.094 green:0.478 blue:0.235 alpha:1];
  UIColor *red = [UIColor colorWithRed:0.75 green:0.16 blue:0.13 alpha:1];

  DBApplyDoorButtonStyle(_callButton, [self styleForSemanticID:@"call.primary"],
                         white, green, 14);
  NSString *cancelID = _flowState == DBDoorFlowInCall ? @"call.end" : @"cancel.call";
  DBApplyDoorButtonStyle(_cancelButton, [self styleForSemanticID:cancelID],
                         white, red, 14);
  NSDictionary *purposeStyle = [self styleForSemanticID:@"purpose.button"];
  for (UIButton *button in _purposeButtons)
    DBApplyDoorButtonStyle(button, purposeStyle, white, neutral, 14);
  DBApplyDoorButtonStyle(_emergencyCancel, [self styleForSemanticID:@"sos.cancel"],
                         white, neutral, 14);
}

- (void)rebuildPurposes {
  for (UIButton *button in _purposeButtons) [button removeFromSuperview];
  [_purposeButtons removeAllObjects];
  NSDictionary *purposes = [DBConfigUtil dig:_cfg path:@"visit_purposes"];
  if (![purposes isKindOfClass:[NSDictionary class]]) purposes = nil;
  // A purpose an administrator switched off is not offered to the visitor, in
  // the grid or in the follow-up chooser, which reads the same list.
  _purposeIds = [DBPurposeModel enabledPurposeIdsInConfig:_cfg];
  for (NSInteger i = 0; i < (NSInteger)[_purposeIds count]; i++) {
    NSString *identifier = [_purposeIds objectAtIndex:(NSUInteger)i];
    NSDictionary *entry = [purposes objectForKey:identifier];
    NSString *label = [DBConfigUtil labelOf:entry lang:_visitorLang fallback:identifier];
    NSString *icon = [entry objectForKey:@"icon"];
    if (![icon isKindOfClass:[NSString class]]) icon = @"";
    NSString *title = [icon length] ? [NSString stringWithFormat:@"%@\n%@", icon, label] : label;
    UIButton *button = [self buttonWithTitle:title primary:NO];
    button.tag = i;
    button.accessibilityIdentifier = [@"purpose_" stringByAppendingString:identifier];
    [button addTarget:self action:@selector(onPurpose:) forControlEvents:UIControlEventTouchUpInside];
    [_purposeScroll addSubview:button];
    [_purposeButtons addObject:button];
  }
  _purposeHint.hidden = [_purposeButtons count] == 0;
  _purposeScroll.hidden = [_purposeButtons count] == 0;
}

- (void)rebuildLanguages {
  for (UIButton *button in _languageButtons) [button removeFromSuperview];
  [_languageButtons removeAllObjects];
  id raw = [DBConfigUtil dig:_cfg path:@"ui.languages"];
  NSMutableArray *languages = [NSMutableArray array];
  if ([raw isKindOfClass:[NSArray class]]) {
    for (id value in (NSArray *)raw)
      if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0 &&
          ![languages containsObject:value]) [languages addObject:value];
  }
  _languages = [languages copy];
  for (NSInteger i = 0; i < (NSInteger)[_languages count]; i++) {
    NSString *lang = [_languages objectAtIndex:(NSUInteger)i];
    UIButton *button = [self buttonWithTitle:[DBTexts langDisplayName:lang] primary:NO];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    button.tag = i;
    button.accessibilityIdentifier = [@"language_" stringByAppendingString:lang];
    [button addTarget:self action:@selector(onLanguage:) forControlEvents:UIControlEventTouchUpInside];
    [_languageBar addSubview:button];
    [_languageButtons addObject:button];
  }
  _languageBar.hidden = [_languageButtons count] < 2;
  [self updateLanguageSelection];
}

- (void)updateLanguageSelection {
  for (NSInteger i = 0; i < (NSInteger)[_languageButtons count]; i++) {
    UIButton *button = [_languageButtons objectAtIndex:(NSUInteger)i];
    NSString *lang = [_languages objectAtIndex:(NSUInteger)i];
    BOOL selected = [lang isEqualToString:_visitorLang];
    button.backgroundColor = selected
        ? [UIColor colorWithRed:0.18 green:0.52 blue:0.78 alpha:1]
        : [UIColor colorWithWhite:1 alpha:0.12];
  }
}

- (void)setVisitorLanguage:(NSString *)lang {
  NSString *value = [lang length] ? lang : @"ja";
  _visitorLang = value;
  [_texts setLang:value];
  [self rebuildPurposes];
  [self updateLanguageSelection];
  [self applyStrings];
  [self applySemanticStyles];
  [self setNeedsLayout];
}

- (void)showCallingWithTitle:(NSString *)title {
  _flowState = DBDoorFlowCalling;
  _callingTitleOverride = [title copy];
  [_callTimer invalidate];
  NSTimeInterval timeout = [DBConfigUtil intVal:_cfg path:@"ui.call_ttl_s" def:60];
  if (timeout < 10 || timeout > 300) timeout = kDoorCallTimeoutS;
  int64_t nowMs = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
  if (_activeCallExpiresAtMs > 0)
    timeout = MAX(1.0, (_activeCallExpiresAtMs - nowMs) / 1000.0);
  else
    _activeCallExpiresAtMs = nowMs + (int64_t)(timeout * 1000.0);
  _callTimer = [NSTimer scheduledTimerWithTimeInterval:timeout
                                                target:self selector:@selector(onCallTimeout)
                                              userInfo:nil repeats:NO];
  _callingOverlay.hidden = NO;
  [self bringSubviewToFront:_callingOverlay];
  [self applyStrings];
  [self applySemanticStyles];
  [self setNeedsLayout];
  if (_safeMode) {
    [_pulse.layer removeAllAnimations];
    _pulse.alpha = 1.0;
  } else {
    _pulse.alpha = 0.25;
    [UIView animateWithDuration:0.85 delay:0
                       options:UIViewAnimationOptionAutoreverse | UIViewAnimationOptionRepeat |
                               UIViewAnimationOptionAllowUserInteraction
                    animations:^{ self->_pulse.alpha = 1.0; }
                    completion:nil];
  }
}

- (void)showInCall {
  _flowState = DBDoorFlowInCall;
  _callingTitleOverride = nil;
  [_callTimer invalidate];
  _callTimer = nil;
  [_feedbackAudio stop];
  _callingOverlay.hidden = NO;
  [self bringSubviewToFront:_callingOverlay];
  [self applyStrings];
  [self applySemanticStyles];
  [self setNeedsLayout];
}

- (void)showIdleWithHint:(NSString *)hint {
  _flowState = DBDoorFlowIdle;
  _activeCallID = nil;
  _activeStageRevision = 0;
  _activeCallExpiresAtMs = 0;
  _callingTitleOverride = nil;
  [_callTimer invalidate];
  _callTimer = nil;
  [_feedbackAudio stop];
  [_pulse.layer removeAllAnimations];
  _pulse.alpha = 1;
  _callingOverlay.hidden = YES;
  _purposeAlertMode = DBDoorPurposeAlertNone;
  _purposeAlertIDs = nil;
  _purposePromptedCallID = nil;
  if ([hint length] > 0) {
    _touchHint.text = hint;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restoreIdleHint)
                                               object:nil];
    [self performSelector:@selector(restoreIdleHint) withObject:nil afterDelay:5.0];
  } else {
    [self applyStrings];
  }
  [self applySemanticStyles];
  [self setNeedsLayout];
}

- (void)restoreIdleHint {
  _touchHint.text = [_texts ts:@"idle.touch_to_call"];
}

- (void)onCall {
  NSString *flow = [DBConfigUtil str:_cfg path:@"ui.call_flow"];
  if (![flow isEqualToString:@"ring_then_purpose"] && [_purposeIds count] > 0) {
    [self presentPurposeAlertForActiveCall:NO];
    return;
  }
  if (![self beginCallWithPurpose:@""]) return;
  [self showCallingWithTitle:nil];
  if ([flow isEqualToString:@"ring_then_purpose"] && [_purposeIds count] > 0)
    [self presentPurposeAlertForActiveCall:YES];
}

- (void)onPurpose:(UIButton *)sender {
  if (sender.tag < 0 || sender.tag >= (NSInteger)[_purposeIds count]) return;
  NSString *identifier = [_purposeIds objectAtIndex:(NSUInteger)sender.tag];
  NSDictionary *entry = [DBConfigUtil dig:_cfg
      path:[NSString stringWithFormat:@"visit_purposes.%@", identifier]];
  NSString *label = [DBConfigUtil labelOf:entry lang:_visitorLang fallback:identifier];
  NSString *flow = [DBConfigUtil str:_cfg path:@"ui.call_flow"];
  if ([flow isEqualToString:@"ring_then_purpose"]) {
    if (![self beginCallWithPurpose:@""]) return;
    if ([_core selectPurposeV2:_boot.door ?: @"" callID:_activeCallID purpose:identifier])
      _activeStageRevision = 1;
  } else if (![self beginCallWithPurpose:identifier]) {
    return;
  }
  [self showCallingWithTitle:[_texts t:@"purpose.sent", label, nil]];
}

- (BOOL)beginCallWithPurpose:(NSString *)purpose {
  _activeStageRevision = 0;
  _activeCallExpiresAtMs = 0;
  _purposePromptedCallID = nil;
  NSString *callID = [_core pressV2:_boot.door ?: @"" purpose:purpose ?: @""];
  if ([callID length] == 0) {
    [self showIdleWithHint:[_texts ts:@"offline.body"]];
    return NO;
  }
  _activeCallID = [callID copy];
  [_feedbackAudio playConfiguredSound:
      ([DBConfigUtil str:_cfg path:@"ui.call_sound"] ?: @"outdoor_call_alert")
                                  loop:[DBConfigUtil boolVal:_cfg path:@"ui.call_sound_loop" def:NO]];
  return YES;
}

- (BOOL)restoreWaitingCall:(NSDictionary *)call recoveryState:(NSString *)state {
  if (![call isKindOfClass:[NSDictionary class]]) return NO;
  NSString *door = [DBConfigUtil evStr:call key:@"door"];
  NSString *callID = [DBConfigUtil evStr:call key:@"call_id"];
  NSString *persistedState = [DBConfigUtil evStr:call key:@"state"];
  if ([callID length] == 0 ||
      ([door length] > 0 && ![door isEqualToString:_boot.door]) ||
      (![persistedState isEqualToString:@"ringing"] &&
       ![state isEqualToString:@"ringing"] &&
       ![state isEqualToString:@"purpose_pending"])) return NO;
  int64_t expires = [[call objectForKey:@"expires_at_ms"] longLongValue];
  int64_t nowMs = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
  if (expires <= nowMs) return NO;

  BOOL alreadyVisible = _flowState == DBDoorFlowCalling &&
      [_activeCallID isEqualToString:callID];
  _activeCallID = [callID copy];
  _activeStageRevision = [DBConfigUtil intVal:call path:@"stage_revision" def:0];
  _activeCallExpiresAtMs = expires;
  if (!alreadyVisible) {
    [_feedbackAudio playConfiguredSound:
        ([DBConfigUtil str:_cfg path:@"ui.call_sound"] ?: @"outdoor_call_alert")
                                    loop:[DBConfigUtil boolVal:_cfg
                                                        path:@"ui.call_sound_loop" def:NO]];
  }
  [self showCallingWithTitle:nil];

  NSString *flow = [DBConfigUtil evStr:call key:@"call_flow"];
  if ([flow length] == 0) flow = [DBConfigUtil str:_cfg path:@"ui.call_flow"];
  BOOL purposePending = [state isEqualToString:@"purpose_pending"] ||
      ([flow isEqualToString:@"ring_then_purpose"] && _activeStageRevision == 0 &&
       [[DBConfigUtil evStr:call key:@"purpose"] length] == 0);
  if (purposePending && [_purposeIds count] > 0 &&
      _purposeAlertMode == DBDoorPurposeAlertNone &&
      ![_purposePromptedCallID isEqualToString:callID])
    [self presentPurposeAlertForActiveCall:YES];
  return YES;
}

- (void)presentPurposeAlertForActiveCall:(BOOL)activeCall {
  if ([_purposeIds count] == 0) return;
  _purposeAlertMode = activeCall ? DBDoorPurposeAlertActiveCall : DBDoorPurposeAlertLocal;
  if (activeCall) _purposePromptedCallID = [_activeCallID copy];
  _purposeAlertIDs = [_purposeIds copy];
  _purposeSkipIndex = NSNotFound;
  NSString *cancel = activeCall ? [_texts ts:@"purpose.cancel_call"]
                                : [_texts ts:@"admin.cancel"];
  UIAlertView *alert = [[UIAlertView alloc] initWithTitle:[_texts ts:@"idle.choose_purpose"]
                                                  message:nil delegate:self
                                        cancelButtonTitle:cancel otherButtonTitles:nil];
  NSDictionary *purposes = [DBConfigUtil dig:_cfg path:@"visit_purposes"];
  for (NSString *identifier in _purposeAlertIDs) {
    NSDictionary *entry = [purposes objectForKey:identifier];
    NSString *label = [DBConfigUtil labelOf:entry lang:_visitorLang fallback:identifier];
    [alert addButtonWithTitle:label];
  }
  if (activeCall) {
    _purposeSkipIndex = [alert addButtonWithTitle:[_texts ts:@"purpose.skip"]];
  }
  [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
  DBDoorPurposeAlertMode mode = _purposeAlertMode;
  NSArray *identifiers = _purposeAlertIDs;
  _purposeAlertMode = DBDoorPurposeAlertNone;
  _purposeAlertIDs = nil;
  if (buttonIndex == alertView.cancelButtonIndex) {
    if (mode == DBDoorPurposeAlertActiveCall && [_activeCallID length] > 0) {
      [_core cancelCallV2:_boot.door ?: @"" callID:_activeCallID reason:@"visitor"];
      [_router sipListenerHangup];
      [self showIdleWithHint:nil];
    }
    return;
  }
  if (mode == DBDoorPurposeAlertActiveCall && buttonIndex == _purposeSkipIndex) return;
  NSInteger purposeIndex = buttonIndex - 1;  // index 0 is the cancel button
  if (purposeIndex < 0 || purposeIndex >= (NSInteger)[identifiers count]) return;
  NSString *identifier = [identifiers objectAtIndex:(NSUInteger)purposeIndex];
  NSDictionary *entry = [DBConfigUtil dig:_cfg
      path:[NSString stringWithFormat:@"visit_purposes.%@", identifier]];
  NSString *label = [DBConfigUtil labelOf:entry lang:_visitorLang fallback:identifier];
  if (mode == DBDoorPurposeAlertLocal) {
    if (![self beginCallWithPurpose:identifier]) return;
    [self showCallingWithTitle:[_texts t:@"purpose.sent", label, nil]];
  } else if (mode == DBDoorPurposeAlertActiveCall && [_activeCallID length] > 0) {
    if ([_core selectPurposeV2:_boot.door ?: @"" callID:_activeCallID purpose:identifier]) {
      _activeStageRevision += 1;
      _callingTitleOverride = [_texts t:@"purpose.sent", label, nil];
      [self applyStrings];
    }
  }
}

- (void)onLanguage:(UIButton *)sender {
  if (sender.tag < 0 || sender.tag >= (NSInteger)[_languages count]) return;
  NSString *lang = [_languages objectAtIndex:(NSUInteger)sender.tag];
  [_core setVisitorLang:_boot.door ?: @"" lang:lang];
  [self setVisitorLanguage:lang];
}

- (void)onCancel {
  if (_flowState != DBDoorFlowInCall && [_activeCallID length] > 0)
    [_core cancelCallV2:_boot.door ?: @"" callID:_activeCallID reason:@"visitor"];
  [_router sipListenerHangup];
  [self showIdleWithHint:nil];
}

- (void)onCallTimeout {
  // Timeout is a real cancellation, not a local-only UI reset. The common core
  // scopes and de-duplicates the replicated cancellation event.
  if ([_activeCallID length] > 0)
    [_core cancelCallV2:_boot.door ?: @"" callID:_activeCallID reason:@"timeout"];
  [_router sipListenerHangup];
  [self showIdleWithHint:[_texts ts:@"calling.no_answer"]];
}

- (void)onAdminCorner {
  NSDate *now = [NSDate date];
  if ([now timeIntervalSinceDate:_adminFirstTap] > 5) {
    _adminFirstTap = now;
    _adminTaps = 0;
  }
  _adminTaps++;
  if (_adminTaps < 7) return;
  _adminTaps = 0;
  __weak DBDoorScreen *weakSelf = self;
  [_router requestPinThen:^{
    DBDoorScreen *screen = weakSelf;
    if (screen) [screen->_router showSettings];
  }];
}

- (void)onEmergencyCancel {
  __weak DBDoorScreen *weakSelf = self;
  // Core reports whether clearing really needs the password: an unset cluster
  // password must never stand between a household and a running alarm, so the
  // prompt is skipped when there is nothing to prompt for.
  if (![DBConfigUtil boolVal:_status path:@"emergency.cancel_requires_password" def:YES]) {
    (void)[_core emergency:NO];
    return;
  }
  [_router requestPinThen:^{
    DBDoorScreen *screen = weakSelf;
    if (screen) (void)[screen->_core emergency:NO];
  }];
}

- (void)handleReplyEvent:(NSDictionary *)event {
  NSString *door = [DBConfigUtil evStr:event key:@"door"];
  if ([door length] > 0 && [_boot.door length] > 0 && ![door isEqualToString:_boot.door]) return;
  NSString *path = [DBConfigUtil evStr:event key:@"audio_path"];
  if ([path length] > 0) [_replyAudio playAssetPath:path];
  _replyText.text = [DBConfigUtil evStr:event key:@"text"];
  _replyBanner.hidden = NO;
  [self bringSubviewToFront:_replyBanner];
  [_replyTimer invalidate];
  NSTimeInterval ttl = [[event objectForKey:@"ttl_s"] doubleValue];
  if (ttl <= 0) ttl = 30;
  _replyTimer = [NSTimer scheduledTimerWithTimeInterval:ttl target:self
      selector:@selector(hideReplyBanner) userInfo:nil repeats:NO];
  [self showIdleWithHint:nil];
}

- (void)hideReplyBanner {
  _replyBanner.hidden = YES;
  [_replyAudio stop];
}

- (void)handleVisitorLangEvent:(NSDictionary *)event {
  NSString *door = [DBConfigUtil evStr:event key:@"door"];
  if ([door length] == 0 || [_boot.door length] == 0 || [door isEqualToString:_boot.door])
    [self setVisitorLanguage:[DBConfigUtil evStr:event key:@"lang"]];
}

- (void)handleCallEvent:(NSDictionary *)event {
  NSString *door = [DBConfigUtil evStr:event key:@"door"];
  if ([door length] > 0 && [_boot.door length] > 0 && ![door isEqualToString:_boot.door]) return;
  NSString *callID = [DBConfigUtil evStr:event key:@"call_id"];
  if ([callID length] == 0) return;
  NSString *type = [DBConfigUtil evStr:event key:@"type"];
  NSInteger revision = [DBConfigUtil intVal:event path:@"stage_revision" def:0];
  if ([type isEqualToString:@"press"]) {
    _activeCallID = [callID copy];
    _activeStageRevision = revision;
  } else if ([type isEqualToString:@"purpose_selected"] &&
             [_activeCallID isEqualToString:callID] && revision >= _activeStageRevision) {
    _activeStageRevision = revision;
  }
}

- (void)handleCallCancelled:(NSDictionary *)event {
  NSString *door = [DBConfigUtil evStr:event key:@"door"];
  if ([door length] > 0 && [_boot.door length] > 0 && ![door isEqualToString:_boot.door]) return;
  NSString *callID = [DBConfigUtil evStr:event key:@"call_id"];
  if ([callID length] == 0 || [_activeCallID length] == 0 ||
      ![callID isEqualToString:_activeCallID]) return;
  [_router sipListenerHangup];
  [self showIdleWithHint:nil];
}

- (void)handleCallAnswered:(NSDictionary *)event {
  NSString *door = [DBConfigUtil evStr:event key:@"door"];
  NSString *callID = [DBConfigUtil evStr:event key:@"call_id"];
  if (([door length] > 0 && [_boot.door length] > 0 && ![door isEqualToString:_boot.door]) ||
      [callID length] == 0 || ![callID isEqualToString:_activeCallID]) return;
  [self showInCall];
}

- (void)handleCallEnded:(NSDictionary *)event {
  NSString *door = [DBConfigUtil evStr:event key:@"door"];
  NSString *callID = [DBConfigUtil evStr:event key:@"call_id"];
  if (([door length] > 0 && [_boot.door length] > 0 && ![door isEqualToString:_boot.door]) ||
      [callID length] == 0 || ![callID isEqualToString:_activeCallID]) return;
  [_router sipListenerHangup];
  [self showIdleWithHint:nil];
}

- (void)handleStateEvent:(NSDictionary *)event {
  NSString *state = [DBConfigUtil evStr:event key:@"state"];
  if ([state isEqualToString:@"calling"]) {
    if (_flowState == DBDoorFlowIdle) [self showCallingWithTitle:nil];
  } else if ([state isEqualToString:@"in_call"]) {
    [self showInCall];
  } else if ([state isEqualToString:@"idle"]) {
    [self showIdleWithHint:nil];
  }
}

- (void)miniSipListenerStateChanged:(DBMiniSipState)state mode:(NSString *)mode {
  (void)mode;
  if (state == DBMiniSipRinging) {
    [self showCallingWithTitle:nil];
  } else if (state == DBMiniSipInCall) {
    [self showInCall];
  } else if (state == DBMiniSipEnded) {
    [self showIdleWithHint:nil];
  }
}

- (void)handleEmergencyEvent:(NSDictionary *)event {
  BOOL active = [DBConfigUtil evBool:event key:@"active"];
  NSDictionary *palette = [DBConfigUtil emergencyPalette:event];
  _emergencyOverlay.backgroundColor = [palette objectForKey:@"background"];
  _emergencyTitle.textColor = [palette objectForKey:@"foreground"];
  _emergencyNote.textColor = [palette objectForKey:@"foreground"];
  _emergencyCancel.backgroundColor = [palette objectForKey:@"accent"];
  [_emergencyCancel setTitleColor:[palette objectForKey:@"accent_foreground"]
                         forState:UIControlStateNormal];
  id visualValue = [event objectForKey:@"visual"];
  BOOL visual = ![visualValue isKindOfClass:[NSNumber class]] || [visualValue boolValue];
  _emergencyOverlay.hidden = !(active && visual);
  if (active) {
    NSInteger volume = [DBConfigUtil intVal:event path:@"alarm_volume" def:100];
    NSString *sound = [DBConfigUtil evStr:event key:@"alarm_sound"];
    NSString *path = [DBConfigUtil evStr:event key:@"audio_path"];
    if (([sound length] > 0 || [path length] > 0) && volume > 0)
      [_alarmAudio startSiren:path volume:volume];
    else
      [_alarmAudio stop];
    if (visual) [self bringSubviewToFront:_emergencyOverlay];
  } else {
    [_alarmAudio stop];
  }
}

- (void)releaseMediaForMemoryPressure {
  _rtspSuspendedForMemoryPressure = YES;
  _rtspGeneration++;
  [_rtspSource stop];
  _rtspSource = nil;
  _rtspForwardingMeasured = NO;
  _rtspState = @"stopped";
  _rtspReason = @"memory_pressure";
  [self stopLocalPreview];
  _previewReason = @"memory_pressure";
  [_core setRuntimeCapability:@"rtsp_h264_forwarding" enabled:NO];
  [self publishMediaSourceStatus];
  [self applyStrings];
  [_feedbackAudio stop];
  [_replyAudio stop];
  // Preserve an active emergency alarm; it is safety-critical and tiny.
  if (_emergencyOverlay.hidden) [_alarmAudio stop];
}

- (void)enterSafeMode {
  _safeMode = YES;
  _rtspSuspendedForMemoryPressure = YES;
  [self releaseMediaForMemoryPressure];
  if (!_mediaSuspendedForBackground) [self configureLocalPreview];
  [self publishMediaSourceStatus];
  [self applyStrings];
}

- (void)exitSafeMode {
  if (!_safeMode) return;
  _safeMode = NO;
  _rtspSuspendedForMemoryPressure = NO;
  if (!_mediaSuspendedForBackground) {
    [self configureRTSPSource];
    [self configureLocalPreview];
  }
  [self publishMediaSourceStatus];
  [self applyStrings];
}

- (NSDictionary *)safeModeMediaStatus {
  NSString *fallback = [_mediaSource preferredPreviewTransport];
  BOOL hasFallback = [fallback isEqualToString:@"mjpeg"] ||
      [fallback isEqualToString:@"snapshot"];
  return @{
    @"mode" : hasFallback ? @"low_resolution_jpeg" : @"audio_only",
    @"fallback" : fallback ?: @"none",
    @"mjpeg_available" : @([_mediaSource.mjpegURL length] > 0),
    @"snapshot_available" : @([_mediaSource.snapshotURL length] > 0),
    @"h264_forwarding" : @NO,
    @"reason" : hasFallback ? @"safe_mode" : @"safe_mode_no_jpeg_fallback",
  };
}

- (void)suspendMediaForBackground {
  _mediaSuspendedForBackground = YES;
  _rtspGeneration++;
  [_rtspSource stop];
  _rtspSource = nil;
  _rtspForwardingMeasured = NO;
  _rtspState = @"stopped";
  _rtspReason = @"background";
  [self stopLocalPreview];
  _previewReason = @"background";
  [_core setRuntimeCapability:@"rtsp_h264_forwarding" enabled:NO];
  [self publishMediaSourceStatus];
}

- (void)resumeMediaAfterBackground {
  if (!_mediaSuspendedForBackground) return;
  _mediaSuspendedForBackground = NO;
  if (!_rtspSuspendedForMemoryPressure) [self configureRTSPSource];
  [self configureLocalPreview];
  [self publishMediaSourceStatus];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  BOOL compact = DBCompatibilityLayoutForWidth(size.width) == DBCompatibilityLayoutCompact;
  BOOL portrait = size.height > size.width;
  CGFloat margin = compact ? 12 : 28;
  CGFloat top = compact ? 12 : 22;

  // No visible admin entry: the corner is transparent and needs seven taps.
  _infoButton.frame = CGRectMake(size.width - 110, 0, 110, 110);
  _mediaBadge.frame = CGRectMake(margin, top, compact ? 100 : 145, compact ? 26 : 30);

  CGFloat clockSize = compact ? 46 : (portrait ? 84 : 72);
  _clockLabel.font = [UIFont systemFontOfSize:clockSize];
  _dateLabel.font = [UIFont systemFontOfSize:compact ? 16 : 22];
  CGFloat y = top + (compact ? 26 : 34);
  _clockLabel.frame = CGRectMake(margin, y, size.width - 2 * margin, clockSize + 10);
  y += clockSize + 12;
  _dateLabel.frame = CGRectMake(margin, y, size.width - 2 * margin, compact ? 22 : 28);
  y += compact ? 26 : 34;

  // The version/battery line owns the last row; the slider sits strictly above
  // it with a real gap, so the two can never collide in either orientation.
  CGFloat versionHeight = 18;
  CGFloat footerGap = 10;
  CGFloat sosHeight = _sos.hidden ? 0 : (compact ? 52 : 60);
  CGFloat versionTop = size.height - margin - versionHeight;
  _versionLabel.frame = CGRectMake(margin, versionTop, size.width - 2 * margin,
                                   versionHeight);
  CGFloat sosTop = versionTop;
  if (sosHeight > 0) {
    CGFloat sosWidth = MIN(360, size.width - 2 * margin);
    sosTop = versionTop - footerGap - sosHeight;
    _sos.frame = CGRectMake((size.width - sosWidth) / 2, sosTop, sosWidth, sosHeight);
  } else {
    _sos.frame = CGRectZero;
  }
  CGFloat bottom = sosTop - footerGap;

  CGFloat bannerHeight = 0;
  if (_pairBanner.hidden) {
    _pairBanner.frame = CGRectZero;
  } else {
    CGFloat bannerWidth = MIN(size.width - 2 * margin, 560);
    bannerHeight = (compact ? 40 : 48) + 8;
    _pairBanner.frame = CGRectMake((size.width - bannerWidth) / 2, y, bannerWidth,
                                   bannerHeight - 8);
    y += bannerHeight;
  }

  BOOL hasNotice = !_noticeLabel.hidden;
  CGFloat langHeight = _languageBar.hidden ? 0 : (compact ? 44 : 54);
  NSDictionary *callStyle = [self styleForSemanticID:@"call.primary"];
  CGFloat callScale = DBDoorStyleNumber(callStyle, @"scale", 1, 0.75, 2);
  _callButton.titleLabel.font = [UIFont boldSystemFontOfSize:
      (compact ? 22 : 26) * DBDoorStyleNumber(callStyle, @"font_scale", 1, 0.75, 2)];
  CGFloat callHeight = MAX(96, (compact ? 88 : 118) * callScale);
  CGFloat hintHeight = compact ? 26 : 32;

  if (portrait || !hasNotice) {
    // Portrait (and any layout without a notice): clock -> notice -> language
    // row in the middle -> call button -> one-line hint -> footer.
    CGFloat contentWidth = size.width - 2 * margin;
    if (hasNotice) {
      CGFloat noticeHeight = _noticeExpanded ? MIN(160, bottom - y - 200) : (compact ? 52 : 62);
      noticeHeight = MAX(40, noticeHeight);
      _noticeLabel.frame = CGRectMake(margin, y, contentWidth, noticeHeight);
      _noticeExpand.frame = _noticeLabel.frame;
      y += noticeHeight + 10;
    } else {
      _noticeLabel.frame = CGRectZero;
      _noticeExpand.frame = CGRectZero;
    }
    if (langHeight > 0) {
      _languageBar.frame = CGRectMake(margin, y, contentWidth, langHeight);
      y += langHeight + 12;
    } else {
      _languageBar.frame = CGRectZero;
    }
    CGFloat callWidth = MIN(compact ? contentWidth : 480, contentWidth);
    CGFloat callY = MIN(y, bottom - callHeight - hintHeight - 12);
    _callButton.frame = CGRectMake((size.width - callWidth) / 2, callY, callWidth, callHeight);
    _touchHint.frame = CGRectMake(margin, CGRectGetMaxY(_callButton.frame) + 8,
                                  contentWidth, hintHeight);
    _titleLabel.frame = CGRectZero;
    _purposeHint.frame = CGRectZero;
    _purposeScroll.frame = CGRectMake(margin, CGRectGetMaxY(_touchHint.frame) + 8,
                                      contentWidth,
                                      MAX(0, bottom - CGRectGetMaxY(_touchHint.frame) - 8));
  } else {
    // Landscape with a notice: the notice takes the left column and the
    // language row sits directly above the call button on the right.
    CGFloat columnGap = 20;
    CGFloat leftWidth = (size.width - 2 * margin - columnGap) * 0.45;
    CGFloat rightX = margin + leftWidth + columnGap;
    CGFloat rightWidth = size.width - rightX - margin;
    _noticeLabel.numberOfLines = 0;
    _noticeLabel.frame = CGRectMake(margin, y, leftWidth, MAX(60, bottom - y));
    _noticeExpand.frame = _noticeLabel.frame;

    CGFloat callY = bottom - callHeight - hintHeight - 12;
    if (langHeight > 0) {
      _languageBar.frame = CGRectMake(rightX, callY - langHeight - 12, rightWidth, langHeight);
    } else {
      _languageBar.frame = CGRectZero;
    }
    _callButton.frame = CGRectMake(rightX, callY, rightWidth, callHeight);
    _touchHint.frame = CGRectMake(rightX, CGRectGetMaxY(_callButton.frame) + 8, rightWidth,
                                  hintHeight);
    _titleLabel.frame = CGRectZero;
    _purposeHint.frame = CGRectZero;
    _purposeScroll.frame = CGRectMake(rightX, y, rightWidth,
                                      MAX(0, CGRectGetMinY(_languageBar.frame) - y - 8));
  }

  NSInteger columns = compact ? 2 : 3;
  CGFloat gap = compact ? 7 : 12;
  CGFloat buttonW = (_purposeScroll.bounds.size.width - gap * (columns - 1)) / columns;
  CGFloat buttonH = compact ? 62 : 82;
  NSDictionary *purposeStyle = [self styleForSemanticID:@"purpose.button"];
  CGFloat purposeFontScale = DBDoorStyleNumber(purposeStyle, @"font_scale", 1, 0.75, 2);
  for (NSInteger i = 0; i < (NSInteger)[_purposeButtons count]; i++) {
    NSInteger row = i / columns;
    NSInteger col = i % columns;
    UIButton *button = [_purposeButtons objectAtIndex:(NSUInteger)i];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:
        (compact ? 16 : 21) * purposeFontScale];
    button.frame = CGRectMake(col * (buttonW + gap), row * (buttonH + gap), buttonW, buttonH);
  }
  NSInteger rows = ([_purposeButtons count] + columns - 1) / columns;
  _purposeScroll.contentSize = CGSizeMake(_purposeScroll.bounds.size.width,
                                          rows * (buttonH + gap));

  CGFloat languageGap = compact ? 5 : 10;
  CGFloat languageW = [_languageButtons count] > 0
      ? (_languageBar.bounds.size.width - languageGap * ([_languageButtons count] - 1)) /
        [_languageButtons count] : 0;
  for (NSInteger i = 0; i < (NSInteger)[_languageButtons count]; i++) {
    UIButton *button = [_languageButtons objectAtIndex:(NSUInteger)i];
    button.frame = CGRectMake(i * (languageW + languageGap), 0, languageW, langHeight);
  }

  [self applyRegionInk];

  _replyBanner.frame = CGRectMake(margin, top + (compact ? 52 : 70), size.width - 2 * margin,
                                  compact ? 88 : 110);
  _replyText.frame = CGRectInset(_replyBanner.bounds, 12, 8);

  _callingOverlay.frame = self.bounds;
  CGFloat pulseSide = compact ? 78 : 110;
  _pulse.layer.cornerRadius = pulseSide / 2;
  _pulse.frame = CGRectMake((size.width - pulseSide) / 2,
                            size.height * (compact ? 0.16 : 0.20), pulseSide, pulseSide);
  _callingLabel.frame = CGRectMake(margin, CGRectGetMaxY(_pulse.frame) + 24,
                                   size.width - 2 * margin, compact ? 90 : 130);
  CGFloat cancelW = compact ? size.width - 2 * margin : MIN(360, size.width - 2 * margin);
  NSString *cancelID = _flowState == DBDoorFlowInCall ? @"call.end" : @"cancel.call";
  NSDictionary *cancelStyle = [self styleForSemanticID:cancelID];
  CGFloat cancelScale = DBDoorStyleNumber(cancelStyle, @"scale", 1, 1, 2);
  _cancelButton.titleLabel.font = [UIFont boldSystemFontOfSize:
      24 * DBDoorStyleNumber(cancelStyle, @"font_scale", 1, 0.75, 2)];
  CGRect cancelBase = CGRectMake((size.width - cancelW) / 2, size.height - margin - 76,
                                 cancelW, 66);
  _cancelButton.frame = DBScaledDoorFrame(cancelBase, cancelScale, size, margin);
  _cancelButton.frame = CGRectMake(_cancelButton.frame.origin.x,
                                   size.height - margin - _cancelButton.frame.size.height,
                                   _cancelButton.frame.size.width,
                                   _cancelButton.frame.size.height);

  _emergencyOverlay.frame = self.bounds;
  _emergencyTitle.frame = CGRectMake(margin, size.height * 0.25, size.width - 2 * margin, 80);
  _emergencyNote.frame = CGRectMake(margin, size.height * 0.43, size.width - 2 * margin, 50);
  NSDictionary *sosStyle = [self styleForSemanticID:@"sos.cancel"];
  CGFloat sosScale = DBDoorStyleNumber(sosStyle, @"scale", 1, 1, 2);
  _emergencyCancel.titleLabel.font = [UIFont boldSystemFontOfSize:
      24 * DBDoorStyleNumber(sosStyle, @"font_scale", 1, 0.75, 2)];
  CGRect sosBase = CGRectMake((size.width - MIN(300, size.width - 2 * margin)) / 2,
                              size.height * 0.63, MIN(300, size.width - 2 * margin), 64);
  _emergencyCancel.frame = DBScaledDoorFrame(sosBase, sosScale, size, margin);
}

@end
