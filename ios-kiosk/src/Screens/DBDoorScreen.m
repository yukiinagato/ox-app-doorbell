#import "DBDoorScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBPairingModel.h"
#import "../Core/DBCompatibilityProfile.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBCallTiming.h"
#import "../Core/DBMediaSource.h"
#import "../Core/DBSemanticStyle.h"
#import "../Core/DBTexts.h"
#import "../Core/DBNoticeModel.h"
#import "../Core/DBIconAsset.h"
#import "../Core/DBPurposeModel.h"
#import "../Core/DBDoorVisitorLayout.h"
#import "../Core/DBUiTheme.h"
#import "../Media/DBSiren.h"
#import "../Net/DBMjpegClient.h"
#import "../Net/DBRTSPH264Source.h"
#import "../Net/DBSnapshotPoller.h"
#import "DBChrome.h"
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

// YES when a validated administrator override carries something a stock button cannot show.
static BOOL DBDoorStyleNeedsFill(NSDictionary *style) {
  return DBDoorStyleColor(style, @"foreground", nil) != nil ||
      DBDoorStyleColor(style, @"background", nil) != nil ||
      DBDoorStyleColor(style, @"border", nil) != nil ||
      [[style objectForKey:@"radius"] isKindOfClass:[NSNumber class]];
}

// The standard card for content that sits on the wallpaper: the system's cell colours on a
// plain view. No masking, so the A4 never renders it offscreen.
static UIView *DBDoorPlate(void) {
  UIView *plate = [[UIView alloc] init];
  plate.backgroundColor = [UIColor whiteColor];
  plate.layer.cornerRadius = 10;
  if (!DBChromeIsFlat()) {
    plate.layer.borderWidth = 1;
    plate.layer.borderColor = [UIColor colorWithWhite:0.67f alpha:1].CGColor;
  }
  return plate;
}

static UIFont *DBDoorFont(CGFloat size, BOOL bold) {
  return bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
}

// The largest font from size down to minimum whose wrapped text fits.
static UIFont *DBDoorFittingFont(NSString *text, CGFloat size, CGFloat minimum, BOOL bold,
                                 CGSize available) {
  UIFont *font = DBDoorFont(size, bold);
  while (size > minimum &&
         [text sizeWithFont:font constrainedToSize:CGSizeMake(available.width, 1000)
              lineBreakMode:NSLineBreakByWordWrapping].height > available.height) {
    size -= 1;
    font = DBDoorFont(size, bold);
  }
  return font;
}

typedef enum {
  DBDoorFlowIdle = 0,
  DBDoorFlowCalling,
  DBDoorFlowInCall
} DBDoorFlowState;

typedef enum {
  DBDoorPurposeAlertNone = 0,
  DBDoorPurposeAlertLocal,
  DBDoorPurposeAlertActiveCall
} DBDoorPurposeAlertMode;

@interface DBDoorScreen () <UIAlertViewDelegate, UIActionSheetDelegate, DBSosSliderDelegate>
- (BOOL)beginCallWithPurpose:(NSString *)purpose;
- (void)presentPurposeAlertForActiveCall:(BOOL)activeCall;
- (void)dismissPurposeAlert;
- (void)configureRTSPSource;
- (void)configureLocalPreview;
- (void)startSnapshotPreviewForGeneration:(NSUInteger)generation;
- (void)stopLocalPreview;
- (void)publishMediaSourceStatus;
@end

// The purpose icon on a button that carries an administrator override.
static const CGFloat kPurposeIconSide = 24;
// The narrowest language segment a visitor can still hit and read.
static const CGFloat kLanguageSegmentMinimum = 64;

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
  DBCallTiming *_callTiming;
  BOOL _callTimingChecking;
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
  DBDoorPurposeAlertMode _purposeAlertMode;
  NSArray *_purposeAlertIDs;
  NSInteger _purposeSkipIndex;
  NSString *_purposePromptedCallID;
  NSString *_purposeAlertCallID;
  UIAlertView *_purposeAlert;

  DBNavBar *_nav;
  UIImageView *_cameraPreviewView;
  UILabel *_touchHint;
  UILabel *_mediaBadge;
  UIButton *_callButton;
  UIScrollView *_purposeScroll;
  NSMutableArray *_purposeButtons;
  // A UIView under each stock purpose button on a flat system, or NSNull.
  NSMutableArray *_purposePlates;
  BOOL _purposeButtonsFilled;
  NSArray *_purposeIds;
  UISegmentedControl *_languageControl;
  // Replaces the segmented control when the enabled languages would not fit as segments.
  UIButton *_languageButton;
  UIActionSheet *_languageSheet;
  UIView *_languagePlate;
  BOOL _languageUsesSheet;
  NSArray *_languages;
  UIView *_callPlate;
  UILabel *_callingLabel;
  UIActivityIndicatorView *_callSpinner;
  UIButton *_cancelButton;
  BOOL _cancelTouchPending;
  DBDoorFlowState _cancelTouchPhase;
  NSString *_cancelTouchCallID;
  NSUInteger _cancelActionGeneration;
  NSUInteger _cancelTouchGeneration;
  UIView *_replyPlate;
  UILabel *_replyText;
  UILabel *_replyCountdown;
  BOOL _replyShown;
  NSTimeInterval _replyDeadline;
  UIView *_emergencyOverlay;
  UILabel *_emergencyTitle;
  UILabel *_emergencyNote;
  UIButton *_emergencyCancel;
  UIButton *_infoButton;      // Invisible 7-tap corner; a visitor sees no admin entry.
  NSInteger _adminTaps;
  NSDate *_adminFirstTap;
  UIButton *_pairBanner;      // pair.not_set_up_banner while the node is not ready.
  UIView *_pairPlate;
  NSString *_pairingState;
  BOOL _onScreen;

  UILabel *_clockLabel;
  UILabel *_dateLabel;
  UIView *_noticeCard;
  UILabel *_noticeLabel;
  UIButton *_noticeExpand;
  BOOL _noticeExpanded;
  UILabel *_versionLabel;
  UIImageView *_themeBg;
  NSString *_themeHash;
  CGSize _themeImageSize;
  DBBackgroundSampler *_sampler;
  CGSize _samplerSize;
  BOOL _samplerBuilding;
  NSDictionary *_display;   // status.display: core-resolved appearance and theme.
  NSDictionary *_status;
  DBSosSlider *_sos;
  DBUiPalette *_palette;
  NSTimer *_clockTimer;
  NSTimer *_keyframeTimer;
  NSInteger _tzOffsetMinutes;
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _router = router;
    _core = router.core;
    _boot = router.boot;
    _texts = router.texts;
    _callTiming = [[DBCallTiming alloc] init];
    _visitorLang = [_boot.uiLang length] ? _boot.uiLang : @"ja";
    _purposeButtons = [[NSMutableArray alloc] init];
    _purposePlates = [[NSMutableArray alloc] init];
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
  [_keyframeTimer invalidate];
  [_callTimer invalidate];
  [_replyTimer invalidate];
  _languageSheet.delegate = nil;
}

- (NSString *)screenName {
  switch (_flowState) {
    case DBDoorFlowCalling: return @"door_calling";
    case DBDoorFlowInCall: return @"door_in_call";
    default: return @"door_idle";
  }
}

// Call, Cancel, End, and the SOS clear have no stock equivalent and keep a semantic fill.
- (UIButton *)filledButton {
  UIButton *button = DBChromeFilledButton(24);
  button.isAccessibilityElement = YES;
  button.accessibilityTraits = UIAccessibilityTraitButton;
  [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  button.titleLabel.adjustsFontSizeToFitWidth = NO;
  button.titleLabel.numberOfLines = 3;
  button.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
  button.titleLabel.textAlignment = NSTextAlignmentCenter;
  button.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
  return button;
}

// Text drawn straight on the wallpaper; applyRegionInk gives it the measured ink.
- (UILabel *)wallpaperLabelWithFont:(UIFont *)font {
  DBReadableLabel *label = [[DBReadableLabel alloc] init];
  label.backgroundColor = [UIColor clearColor];
  label.textColor = [UIColor whiteColor];
  label.textAlignment = NSTextAlignmentCenter;
  label.font = font;
  return label;
}

// Text on a plate keeps the system's label colour. UILabel is opaque white before iOS 7.
- (UILabel *)plateLabelWithFont:(UIFont *)font {
  UILabel *label = [[UILabel alloc] init];
  label.backgroundColor = [UIColor clearColor];
  label.font = font;
  label.numberOfLines = 0;
  return label;
}

- (void)buildUI {
  self.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1];

  // The cluster's theme picture sits behind everything, prepared once for this
  // panel and darkened, with the per-region ink measured against it.
  _themeBg = [[UIImageView alloc] initWithFrame:self.bounds];
  _themeBg.autoresizingMask = UIViewAutoresizingFlexibleWidth |
      UIViewAutoresizingFlexibleHeight;
  _themeBg.contentMode = UIViewContentModeScaleAspectFill;
  _themeBg.clipsToBounds = YES;
  _themeBg.opaque = YES;
  _themeBg.hidden = YES;
  [self addSubview:_themeBg];

  _cameraPreviewView = [[UIImageView alloc] initWithFrame:self.bounds];
  _cameraPreviewView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
      UIViewAutoresizingFlexibleHeight;
  _cameraPreviewView.contentMode = UIViewContentModeScaleAspectFill;
  _cameraPreviewView.clipsToBounds = YES;
  _cameraPreviewView.alpha = 0;
  _cameraPreviewView.hidden = YES;
  _cameraPreviewView.accessibilityIdentifier = @"door_camera_local_preview";
  [self addSubview:_cameraPreviewView];

  // Clock, date, hint, and version are direct children of the screen: the background sampler
  // is keyed to the screen's size, so only a direct child gets ink measured behind its frame.
  _clockLabel = [self wallpaperLabelWithFont:[UIFont systemFontOfSize:72]];
  _clockLabel.adjustsFontSizeToFitWidth = YES;
  _clockLabel.minimumFontSize = 20;
  [self addSubview:_clockLabel];

  _dateLabel = [self wallpaperLabelWithFont:[UIFont systemFontOfSize:22]];
  _dateLabel.adjustsFontSizeToFitWidth = YES;
  _dateLabel.minimumFontSize = 12;
  [self addSubview:_dateLabel];

  _touchHint = [self wallpaperLabelWithFont:[UIFont systemFontOfSize:24]];
  _touchHint.numberOfLines = 2;
  _touchHint.textColor = [UIColor colorWithWhite:1 alpha:0.65];
  [self addSubview:_touchHint];

  _versionLabel = [self wallpaperLabelWithFont:[UIFont systemFontOfSize:16]];
  _versionLabel.adjustsFontSizeToFitWidth = YES;
  _versionLabel.minimumFontSize = 12;
  [self addSubview:_versionLabel];

  _nav = [[DBNavBar alloc] init];
  [_nav setRootTitle:@"" backTitle:nil onBack:nil];
  _nav.bar.autoresizingMask = UIViewAutoresizingNone;
  [self addSubview:_nav.bar];

  // A door station shows no admin entry at all: the corner is invisible and needs seven taps
  // plus the admin password. It lies over the right end of the bar and under the language
  // control, so it never takes a visitor's touch away from a visible control.
  _infoButton = [UIButton buttonWithType:UIButtonTypeCustom];
  _infoButton.backgroundColor = [UIColor clearColor];
  _infoButton.accessibilityIdentifier = @"door_admin_corner";
  [_infoButton addTarget:self action:@selector(onAdminCorner)
        forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_infoButton];

  // A flat system draws its controls without a ground of their own, so there they get the
  // standard plate; the iOS 5 controls are opaque and need none.
  if (DBChromeIsFlat()) {
    _languagePlate = DBDoorPlate();
    [self addSubview:_languagePlate];
  }
  _languageControl = [[UISegmentedControl alloc] initWithItems:nil];
  _languageControl.accessibilityIdentifier = @"door_language";
  _languageControl.hidden = YES;
  [_languageControl addTarget:self action:@selector(onLanguageChanged:)
             forControlEvents:UIControlEventValueChanged];
  [self addSubview:_languageControl];
  _languageButton = DBChromeButton(@"", 18);
  _languageButton.accessibilityIdentifier = @"door_language_menu";
  _languageButton.hidden = YES;
  [_languageButton addTarget:self action:@selector(onLanguageButton)
            forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_languageButton];

  _purposeScroll = [[UIScrollView alloc] init];
  _purposeScroll.backgroundColor = [UIColor clearColor];
  _purposeScroll.accessibilityIdentifier = @"door_secondary_content";
  [self addSubview:_purposeScroll];

  // A door station that was set up without pairing keeps a persistent, tappable reminder
  // instead of silently running unpaired.
  if (DBChromeIsFlat()) {
    _pairPlate = DBDoorPlate();
    _pairPlate.hidden = YES;
    [_purposeScroll addSubview:_pairPlate];
  }
  _pairBanner = DBChromeButton(@"", 18);
  _pairBanner.accessibilityIdentifier = @"door_pair_banner";
  _pairBanner.hidden = YES;
  [_pairBanner addTarget:self action:@selector(onPairBanner)
        forControlEvents:UIControlEventTouchUpInside];
  [_purposeScroll addSubview:_pairBanner];

  _mediaBadge = [[DBReadableLabel alloc] init];
  _mediaBadge.backgroundColor = [UIColor clearColor];
  _mediaBadge.textColor = [UIColor colorWithWhite:1 alpha:0.65];
  _mediaBadge.font = [UIFont boldSystemFontOfSize:15];
  _mediaBadge.numberOfLines = 2;
  _mediaBadge.textAlignment = NSTextAlignmentCenter;
  _mediaBadge.accessibilityIdentifier = @"door_media_source";
  [_purposeScroll addSubview:_mediaBadge];

  // The visitor sees the announcement text only: no source line and no expiry.
  _noticeCard = DBDoorPlate();
  _noticeCard.hidden = YES;
  _noticeLabel = [self plateLabelWithFont:[UIFont systemFontOfSize:20]];
  _noticeLabel.numberOfLines = 2;
  _noticeLabel.hidden = YES;
  [_noticeCard addSubview:_noticeLabel];
  _noticeExpand = [UIButton buttonWithType:UIButtonTypeCustom];
  _noticeExpand.backgroundColor = [UIColor clearColor];
  _noticeExpand.hidden = YES;
  _noticeExpand.accessibilityIdentifier = @"door_notice";
  [_noticeExpand addTarget:self action:@selector(onToggleNotice)
          forControlEvents:UIControlEventTouchUpInside];
  [_noticeCard addSubview:_noticeExpand];
  [self addSubview:_noticeCard];

  _replyPlate = DBDoorPlate();
  _replyPlate.hidden = YES;
  _replyText = [self plateLabelWithFont:[UIFont boldSystemFontOfSize:28]];
  _replyText.textAlignment = NSTextAlignmentCenter;
  _replyText.accessibilityIdentifier = @"door_reply";
  [_replyPlate addSubview:_replyText];
  _replyCountdown = [self plateLabelWithFont:[UIFont systemFontOfSize:15]];
  _replyCountdown.numberOfLines = 1;
  _replyCountdown.textAlignment = NSTextAlignmentRight;
  [_replyPlate addSubview:_replyCountdown];
  [self addSubview:_replyPlate];

  _callPlate = DBDoorPlate();
  _callPlate.hidden = YES;
  _callSpinner = [[UIActivityIndicatorView alloc]
      initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
  [_callPlate addSubview:_callSpinner];
  _callingLabel = [self plateLabelWithFont:[UIFont boldSystemFontOfSize:40]];
  _callingLabel.textAlignment = NSTextAlignmentCenter;
  _callingLabel.accessibilityIdentifier = @"door_call_status";
  [_callPlate addSubview:_callingLabel];
  [self addSubview:_callPlate];

  _callButton = [self filledButton];
  _callButton.backgroundColor = [UIColor colorWithRed:0.094 green:0.478 blue:0.235 alpha:1];
  _callButton.accessibilityIdentifier = @"door_call";
  [_callButton addTarget:self action:@selector(onCall) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_callButton];

  _cancelButton = [self filledButton];
  _cancelButton.backgroundColor = [UIColor colorWithRed:0.75 green:0.16 blue:0.13 alpha:1];
  _cancelButton.accessibilityIdentifier = @"door_cancel_call";
  _cancelButton.hidden = YES;
  [_cancelButton addTarget:self action:@selector(onCancelTouchDown) forControlEvents:UIControlEventTouchDown];
  [_cancelButton addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
  [_cancelButton addTarget:self action:@selector(onCancelTouchCancel)
         forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
  [self addSubview:_cancelButton];

  _sos = [[DBSosSlider alloc] initWithFrame:CGRectZero];
  _sos.delegate = self;
  _sos.hidden = YES;
  [self addSubview:_sos];

  // The emergency layer stays custom and is the last subview, so it covers the navigation
  // bar and every control.
  _emergencyOverlay = [[UIView alloc] init];
  _emergencyOverlay.backgroundColor = [UIColor colorWithRed:0.52 green:0.0 blue:0.0 alpha:0.98];
  _emergencyOverlay.hidden = YES;
  _emergencyOverlay.accessibilityViewIsModal = YES;
  _emergencyTitle = [[UILabel alloc] init];
  _emergencyTitle.backgroundColor = [UIColor clearColor];
  _emergencyTitle.font = [UIFont boldSystemFontOfSize:56];
  _emergencyTitle.textColor = [UIColor whiteColor];
  _emergencyTitle.textAlignment = NSTextAlignmentCenter;
  _emergencyTitle.numberOfLines = 2;
  [_emergencyOverlay addSubview:_emergencyTitle];
  _emergencyNote = [[UILabel alloc] init];
  _emergencyNote.backgroundColor = [UIColor clearColor];
  _emergencyNote.font = [UIFont systemFontOfSize:25];
  _emergencyNote.textColor = [UIColor whiteColor];
  _emergencyNote.textAlignment = NSTextAlignmentCenter;
  _emergencyNote.numberOfLines = 3;
  [_emergencyOverlay addSubview:_emergencyNote];
  _emergencyCancel = [self filledButton];
  _emergencyCancel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
  _emergencyCancel.accessibilityIdentifier = @"door_sos_clear";
  [_emergencyCancel addTarget:self action:@selector(onEmergencyCancel)
               forControlEvents:UIControlEventTouchUpInside];
  [_emergencyOverlay addSubview:_emergencyCancel];
  [self addSubview:_emergencyOverlay];
}

// One place decides what each call phase shows. The idle content, the call plate, and the
// two action buttons share their rectangles, so exactly one of each is visible.
- (void)applyFlowVisibility {
  BOOL idle = _flowState == DBDoorFlowIdle;
  BOOL languages = idle && [_languages count] >= 2;
  _languageControl.hidden = !languages || _languageUsesSheet;
  _languageButton.hidden = !languages || !_languageUsesSheet;
  _languagePlate.hidden = !languages;
  if (!languages) [self dismissLanguageSheet];
  BOOL reply = idle && _replyShown;
  BOOL notice = idle && !reply && !_noticeLabel.hidden;
  BOOL covered = reply || (notice && _noticeExpanded);
  _replyPlate.hidden = !reply;
  _noticeCard.hidden = !notice;
  _clockLabel.hidden = !idle || covered;
  _dateLabel.hidden = !idle || covered;
  _purposeScroll.hidden = !idle;
  _touchHint.hidden = !idle;
  _callButton.hidden = !idle;
  _cancelButton.hidden = idle;
  _callPlate.hidden = idle;
  // The indicator runs only while a call is ringing on a visible screen, and never in safe
  // mode.
  if (_flowState == DBDoorFlowCalling && _onScreen && !_safeMode) [_callSpinner startAnimating];
  else [_callSpinner stopAnimating];
}

- (void)onScreenWillAppear {
  _onScreen = YES;
  [self applyFlowVisibility];
  if (!_clockTimer) {
    _clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                 selector:@selector(updateClock)
                                                 userInfo:nil repeats:YES];
  }
  if (!_keyframeTimer) {
    _keyframeTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
                                                    selector:@selector(pollKeyframeRequest:)
                                                    userInfo:nil repeats:YES];
  }
  [self updateClock];
  [self refreshFromCore];
  [self applyStrings];
}

- (void)pollKeyframeRequest:(NSTimer *)timer {
  (void)timer;
  if ([_core takeVideoKeyframeRequest]) [_rtspSource requestKeyFrame];
}

// Rendered from Core's local-time document: no operating-system time-zone
// database is needed and the clock follows the cluster zone and NTP offset.
- (void)updateClock {
  [self updateReplyCountdown];
  NSDictionary *local = [_core cachedLocalTime];
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
  [self applyFlowVisibility];
  [self setNeedsLayout];
}

// The call button colour is computed from the effective background: hue rotated
// by 180 degrees and lightness moved until it separates, with the local
// fallback used whenever core published no auto_accent (spec §5.2).
- (NSString *)themeValue:(NSString *)leaf {
  if ([_deviceID length] > 0) {
    NSString *value = [DBConfigUtil str:_cfg path:[NSString stringWithFormat:
        @"devices.%@.local.theme.%@", _deviceID, leaf]];
    if (value) return value;
  }
  return [DBConfigUtil str:_cfg path:[NSString stringWithFormat:@"display.theme.%@", leaf]];
}

- (void)refreshThemeBackdrop {
  if (_safeMode) {
    _themeHash = nil;
    _themeBg.image = nil;
    _themeBg.hidden = YES;
    _sampler = nil;
    return;
  }
  NSString *hash = [self themeValue:@"bg_image"];
  CGSize size = self.bounds.size;
  if ([hash length] == 0) {
    _themeHash = nil;
    _themeBg.image = nil;
    _themeBg.hidden = YES;
    _sampler = nil;
    return;
  }
  if ([_themeHash isEqualToString:hash] && _themeBg.image != nil &&
      CGSizeEqualToSize(_themeImageSize, size))
    return;
  if (size.width <= 0 || size.height <= 0) return;
  _themeHash = [hash copy];
  _themeImageSize = size;
  NSString *want = [hash copy];
  NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:%ld/asset/%@",
                         (long)_boot.httpPort, hash];
  NSURL *url = [NSURL URLWithString:urlString];
  if (url == nil) return;
  // The same administrator overlay the dashboard uses; this screen has no
  // device id of its own to key a per-device override on, so it takes the
  // cluster's answer and core's resolved one.
  NSDictionary *overlay = [DBUiTheme backdropOverlayForConfig:_cfg deviceId:nil
                                                      display:_display];
  __weak DBDoorScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
    UIImage *backdrop = [DBThemeBackdrop cachedBackdropForKey:want size:size
                                                      overlay:overlay];
    if (backdrop == nil) {
      NSData *data = [NSData dataWithContentsOfURL:url];
      backdrop = [DBThemeBackdrop backdropForData:data key:want size:size overlay:overlay];
    }
    DBBackgroundSampler *sampler = [DBBackgroundSampler samplerWithImage:backdrop
                                                                viewSize:size];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBDoorScreen *screen = weakSelf;
      if (!screen || ![screen->_themeHash isEqualToString:want]) return;
      screen->_themeBg.image = backdrop;
      screen->_themeBg.hidden = (backdrop == nil);
      screen->_sampler = sampler;
      screen->_samplerSize = size;
      [screen->_palette setBackgroundSampler:sampler];
      [screen applyRegionInk];
    });
  });
}

- (void)applyVisitorTheme {
  NSString *background = [DBConfigUtil str:_cfg path:[NSString stringWithFormat:
      @"devices.%@.local.theme.bg_color", _deviceID]];
  if ([background length] == 0)
    background = [DBConfigUtil str:_cfg path:@"display.theme.bg_color"];
  _palette = [DBUiPalette paletteForConfig:_cfg deviceId:_deviceID display:_display
                             backgroundHex:background minuteOfDay:[self minuteOfDay]];
  [self refreshThemeBackdrop];
  [_palette setBackgroundSampler:_sampler];
  if (_cameraPreviewView.hidden && _themeBg.hidden) {
    [_palette setRenderedFlatBackgroundHex:_safeMode ? nil : background];
    self.backgroundColor = _palette.surface;
  }
  // The per-region colours land after layout, when each frame is known.
  [self applyRegionInk];
  [_sos applyPalette:_palette];
  [_sos applyConfig:_cfg texts:_texts];

  // The same rule as every other shell: the bar is drawn when the cluster's
  // emergency.button_on_roles names this role.
  BOOL showSos = NO;
  id roles = [DBConfigUtil dig:_cfg path:@"emergency.button_on_roles"];
  if ([roles isKindOfClass:[NSArray class]]) {
    for (id role in (NSArray *)roles)
      if ([role isKindOfClass:[NSString class]] &&
          [(NSString *)role isEqualToString:@"door_station"])
        showSos = YES;
  }
  if (showSos != !_sos.hidden) {
    NSLog(@"[doorbell][sos] door station bar %@ (button_on_roles=%@)",
          showSos ? @"shown" : @"hidden", roles ?: @"<unset>");
  }
  if (_sos.hidden == showSos) [self setNeedsLayout];
  _sos.hidden = !showSos;

  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  NSDictionary *notice = [DBNoticeModel effectiveNoticeForDoor:_boot.door config:_cfg
                                                          nowMs:nowMs];
  NSString *text = notice ? [DBNoticeModel noticeText:notice] : @"";
  if (![text isEqualToString:_noticeLabel.text ?: @""]) [self setNeedsLayout];
  _noticeLabel.text = text;
  // The label's own hidden flag records whether an announcement exists; the card around it
  // follows the call phase.
  _noticeLabel.hidden = ([text length] == 0);
  _noticeExpand.hidden = _noticeLabel.hidden;
  if (_noticeLabel.hidden) _noticeExpanded = NO;
  [self applyFlowVisibility];

  NSDictionary *power = [_core powerStateNow];
  NSString *appVersion = [[NSBundle mainBundle]
      objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
  NSString *deviceName = [DBConfigUtil str:_cfg path:[NSString stringWithFormat:
      @"devices.%@.name", _deviceID]] ?: _boot.name;
  _versionLabel.text = [DBUiTheme versionLineForName:deviceName
                                         coreVersion:[_core coreVersion]
                                          appVersion:appVersion
                                          batteryPct:[DBConfigUtil intVal:power
                                                                      path:@"battery_pct" def:-1]
                                            charging:[DBConfigUtil boolVal:power
                                                                      path:@"charging" def:NO]];
}

// Each text region takes the ink measured behind its own frame; an administrator override
// still wins. The media line scrolls with the purposes, so it takes the whole-background
// answer.
- (void)applyRegionInk {
  if (_palette == nil) return;
  [_palette applyInkToLabel:_clockLabel region:DBUiRegionClock];
  [_palette applyInkToLabel:_dateLabel region:DBUiRegionDate];
  [_palette applyInkToLabel:_touchHint region:DBUiRegionHint];
  [_palette applyInkToLabel:_versionLabel region:DBUiRegionStatusLine];
  [_palette applyInkToLabel:_mediaBadge region:DBUiRegionStatusLine];
}

- (void)sosSliderDidArm:(DBSosSlider *)slider { (void)slider; }
- (void)sosSliderDidCancel:(DBSosSlider *)slider { (void)slider; }

- (void)sosSliderDidFire:(DBSosSlider *)slider {
  (void)slider;
  (void)[_core emergency:YES];
}

- (void)onScreenWillDisappear {
  // Keep observing Core while the admin/info overlay is visible. The keyframe poll keeps running:
  // remote viewers still receive this station's camera and need their keyframes. The clock is
  // only drawn here, so it stops until the screen appears again.
  [_clockTimer invalidate];
  _clockTimer = nil;
  _onScreen = NO;
  [_callSpinner stopAnimating];
  [self dismissLanguageSheet];
}

- (void)refreshFromCore {
  NSInteger generation = ++_snapshotGeneration;
  DBCoreBridge *core = _core;
  NSUInteger coreGeneration = core.lifecycleGeneration;
  __weak DBDoorScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *config = [core config];
    DBCallTimingSnapshot *timingSnapshot = [core callTimingSnapshot];
    NSDictionary *status = timingSnapshot.document;
    NSDictionary *pairing = [core pairingInfo];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBDoorScreen *screen = weakSelf;
      if (!screen || generation != screen->_snapshotGeneration ||
          timingSnapshot.coreGeneration != coreGeneration ||
          timingSnapshot.coreGeneration != core.lifecycleGeneration) return;
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
      NSDictionary *localCamera = core.cameraActive ? @{
          @"id": selfID ?: @"", @"role": @"door_station",
          @"stream_mjpeg": [NSString stringWithFormat:@"http://127.0.0.1:%ld/stream.mjpeg", (long)screen->_boot.httpPort],
          @"snapshot_url": [NSString stringWithFormat:@"http://127.0.0.1:%ld/snapshot.jpg", (long)screen->_boot.httpPort]
      } : nil;
      screen->_mediaSource = [DBMediaSource sourceForPeer:localCamera config:config
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
      if (waitingCall) [screen restoreWaitingCall:[DBConfigUtil evStr:waitingCall key:@"call_id"]
                                        snapshot:timingSnapshot];
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
  if (_core.h264CameraActive) {
    state = @"ready";
  } else if (_rtspForwardingMeasured) {
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
  if (_core.cameraActive && [_mediaSource.kind isEqualToString:@"node"]) {
    [self stopLocalPreview];
    return;
  }
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

- (NSString *)callFlowMode {
  id value = [DBConfigUtil dig:_cfg path:@"ui.call_flow"];
  if ([value isKindOfClass:[NSDictionary class]]) value = [value objectForKey:@"mode"];
  return [value isKindOfClass:[NSString class]] && [value isEqualToString:@"ring_then_purpose"]
      ? @"ring_then_purpose" : @"purpose_first";
}

- (BOOL)showsHomePurposes {
  return [[self callFlowMode] isEqualToString:@"purpose_first"] && [_purposeIds count] > 0;
}

- (void)applyStrings {
  _nav.topItem.title = [self doorLabel];
  _touchHint.text = [_texts ts:[self showsHomePurposes] ? @"door.hint_purpose_first" : @"door.hint_call"];
  [_callButton setTitle:[_texts ts:[self showsHomePurposes] ? @"door.call_direct" : @"idle.call"]
              forState:UIControlStateNormal];
  _callingLabel.text = _callTimingChecking ? [_texts ts:@"visitor.restoring"] : _flowState == DBDoorFlowInCall
      ? [_texts ts:@"incall.title"]
      : (_callingTitleOverride ?: [_texts ts:@"calling.title"]);
  [_cancelButton setTitle:(_flowState == DBDoorFlowInCall
                               ? [_texts ts:@"incall.end"] : [_texts ts:@"calling.cancel"])
                     forState:UIControlStateNormal];
  _cancelButton.accessibilityIdentifier = _flowState == DBDoorFlowInCall
      ? @"door_end_call" : @"door_cancel_call";
  _cancelButton.accessibilityLabel = _cancelButton.currentTitle;
  _callButton.accessibilityLabel = _callButton.currentTitle;
  _emergencyTitle.text = [_texts ts:@"emergency.title"];
  _emergencyNote.text = [_texts ts:@"emergency.active_detail"];
  [_emergencyCancel setTitle:[_texts ts:@"emergency.cancel"] forState:UIControlStateNormal];
  [_pairBanner setTitle:[_texts ts:@"pair.not_set_up_banner"] forState:UIControlStateNormal];
  [self updateLanguageSelection];

  _mediaBadge.accessibilityValue = [_mediaSource.sourceRef length]
      ? [NSString stringWithFormat:@"source_ref=%@", _mediaSource.sourceRef] : @"";
  if (_core.h264CameraActive) {
    _mediaBadge.text = @"H.264";
  } else if (_rtspForwardingMeasured) {
    _mediaBadge.text = @"IP CAMERA · H.264";
  } else if ([_mediaSource.kind isEqualToString:@"ip_camera"] && _previewMeasured) {
    _mediaBadge.text = [_mediaSource.degradedReason length] > 0
        ? @"IP CAMERA · PREVIEW" : @"IP CAMERA";
  } else if (_mediaSource.h264SourceAvailable) {
    _mediaBadge.text = @"H.264 SOURCE · DEGRADED";
  } else if ([_mediaSource hasVideo]) {
    _mediaBadge.text = @"VIDEO READY";
  } else {
    _mediaBadge.text = [_texts ts:@"ring.no_video"];
  }
  // The media source line is for the installer, not the visitor: it is drawn only on a panel
  // with diagnostics enabled, and stays readable to tooling through its accessibility value.
  _mediaBadge.hidden = !_boot.diagnosticDumps;
  [self applyVisitorTheme];
}

- (NSDictionary *)styleForSemanticID:(NSString *)semanticID {
  UIColor *foreground = [UIColor whiteColor];
  UIColor *background = [UIColor colorWithRed:0.15 green:0.16 blue:0.18 alpha:1];
  if ([semanticID isEqualToString:@"call.primary"]) {
    background = [UIColor colorWithRed:0.094 green:0.478 blue:0.235 alpha:1];
  } else if ([semanticID isEqualToString:@"cancel.call"] ||
             [semanticID isEqualToString:@"call.end"]) {
    background = [UIColor colorWithRed:0.75 green:0.16 blue:0.13 alpha:1];
  } else if ([semanticID isEqualToString:@"purpose.button"]) {
    // A purpose override is drawn on a plate-coloured button, so a single overridden colour
    // is contrast-checked against the colour it will really meet.
    foreground = [UIColor blackColor];
    background = [UIColor whiteColor];
  }
  BOOL safety = [semanticID isEqualToString:@"cancel.call"] ||
      [semanticID isEqualToString:@"call.end"] ||
      [semanticID isEqualToString:@"sos.cancel"];
  return [DBSemanticStyle styleForConfig:_cfg deviceID:_deviceID semanticID:semanticID
                          safetyCritical:safety baselineForeground:foreground
                      baselineBackground:background baselineAccent:nil baselineBorder:nil];
}

- (void)applySemanticStyles {
  UIColor *white = [UIColor whiteColor];
  UIColor *neutral = [UIColor colorWithWhite:1 alpha:0.12];
  UIColor *green = [UIColor colorWithRed:0.094 green:0.478 blue:0.235 alpha:1];
  UIColor *red = [UIColor colorWithRed:0.75 green:0.16 blue:0.13 alpha:1];

  NSDictionary *callStyle = [self styleForSemanticID:@"call.primary"];
  DBApplyDoorButtonStyle(_callButton, callStyle, white, green, 10);
  // An administrator's explicit colour wins; otherwise the button takes the accent Core
  // computed from the effective background. This runs after the semantic pass because that
  // pass would otherwise paint the baseline green over it.
  if (_palette != nil && [callStyle objectForKey:@"background"] == nil) {
    _callButton.backgroundColor = _palette.accent;
    [_callButton setTitleColor:_palette.accentInk forState:UIControlStateNormal];
  }
  NSString *cancelID = _flowState == DBDoorFlowInCall ? @"call.end" : @"cancel.call";
  DBApplyDoorButtonStyle(_cancelButton, [self styleForSemanticID:cancelID],
                         white, red, 10);
  // A purpose is the stock button. Only a validated override that names a colour, a border,
  // or a radius turns it into a filled button, and then exactly that override is drawn.
  NSDictionary *purposeStyle = [self styleForSemanticID:@"purpose.button"];
  if (DBDoorStyleNeedsFill(purposeStyle) != _purposeButtonsFilled) {
    [self rebuildPurposes];
    [self setNeedsLayout];
  }
  if (_purposeButtonsFilled) {
    for (UIButton *button in _purposeButtons)
      DBApplyDoorButtonStyle(button, purposeStyle, [UIColor blackColor], white, 10);
  }
  DBApplyDoorButtonStyle(_emergencyCancel, [self styleForSemanticID:@"sos.cancel"],
                         white, neutral, 10);
}

- (void)rebuildPurposes {
  for (UIButton *button in _purposeButtons) [button removeFromSuperview];
  for (id plate in _purposePlates)
    if ([plate isKindOfClass:[UIView class]]) [(UIView *)plate removeFromSuperview];
  [_purposeButtons removeAllObjects];
  [_purposePlates removeAllObjects];
  NSDictionary *purposes = [DBConfigUtil dig:_cfg path:@"visit_purposes"];
  if (![purposes isKindOfClass:[NSDictionary class]]) purposes = nil;
  // A purpose an administrator switched off is not offered to the visitor, in
  // the grid or in the follow-up chooser, which reads the same list.
  _purposeIds = [DBPurposeModel enabledPurposeIdsInConfig:_cfg];
  NSDictionary *style = [self styleForSemanticID:@"purpose.button"];
  _purposeButtonsFilled = DBDoorStyleNeedsFill(style);
  UIColor *ink = DBDoorStyleColor(style, @"foreground", [UIColor blackColor]);
  BOOL shown = [self showsHomePurposes];
  for (NSInteger i = 0; i < (NSInteger)[_purposeIds count]; i++) {
    NSString *identifier = [_purposeIds objectAtIndex:(NSUInteger)i];
    NSDictionary *entry = [purposes objectForKey:identifier];
    NSString *label = [DBConfigUtil labelOf:entry lang:_visitorLang fallback:identifier];
    // A real icon when this shell has one for the purpose; otherwise whatever
    // glyph the administrator typed, which is all an invented purpose has.
    NSString *iconName = [DBPurposeModel iconNameForPurpose:identifier];
    UIImage *asset = _purposeButtonsFilled
        ? [DBIconAsset tintedImageNamed:iconName color:ink
                                   size:CGSizeMake(kPurposeIconSide, kPurposeIconSide)]
        : [DBIconAsset imageNamed:iconName];
    NSString *glyph = asset != nil ? @"" : [DBPurposeModel displayIconForConfiguredIcon:
        [entry objectForKey:@"icon"]];
    NSString *title = [glyph length] ? [NSString stringWithFormat:@"%@ %@", glyph, label] : label;
    UIButton *button = _purposeButtonsFilled ? [self filledButton] : DBChromeButton(title, 22);
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.adjustsFontSizeToFitWidth = NO;
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
    if (asset != nil) {
      [button setImage:asset forState:UIControlStateNormal];
      button.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    }
    button.tag = i;
    button.hidden = !shown;
    button.accessibilityIdentifier = [@"purpose_" stringByAppendingString:identifier];
    button.accessibilityLabel = label;
    [button addTarget:self action:@selector(onPurpose:) forControlEvents:UIControlEventTouchUpInside];
    UIView *plate = nil;
    if (DBChromeIsFlat() && !_purposeButtonsFilled) {
      plate = DBDoorPlate();
      plate.hidden = !shown;
      [_purposeScroll addSubview:plate];
    }
    [_purposeScroll addSubview:button];
    [_purposeButtons addObject:button];
    [_purposePlates addObject:(plate ?: (id)[NSNull null])];
    if (_purposeButtonsFilled) DBApplyDoorButtonStyle(button, style, [UIColor blackColor],
                                                      [UIColor whiteColor], 10);
  }
}

- (void)rebuildLanguages {
  id raw = [DBConfigUtil dig:_cfg path:@"ui.languages"];
  NSMutableArray *languages = [NSMutableArray array];
  if ([raw isKindOfClass:[NSArray class]]) {
    for (id value in (NSArray *)raw)
      if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0 &&
          ![languages containsObject:value]) [languages addObject:value];
  }
  if (![languages isEqualToArray:_languages ?: @[]]) {
    [self dismissLanguageSheet];
    _languages = [languages copy];
    [_languageControl removeAllSegments];
    for (NSUInteger i = 0; i < [_languages count]; i++)
      [_languageControl insertSegmentWithTitle:[DBTexts langDisplayName:[_languages objectAtIndex:i]]
                                       atIndex:i animated:NO];
    [self setNeedsLayout];
  }
  [self updateLanguageSelection];
  [self applyFlowVisibility];
}

- (void)updateLanguageSelection {
  NSUInteger index = [_languages indexOfObject:_visitorLang ?: @""];
  NSInteger selected = index == NSNotFound ? UISegmentedControlNoSegment : (NSInteger)index;
  if (_languageControl.selectedSegmentIndex != selected)
    _languageControl.selectedSegmentIndex = selected;
  [_languageButton setTitle:[NSString stringWithFormat:@"%@: %@",
                             [_texts ts:@"door.lang_switch"],
                             [DBTexts langDisplayName:_visitorLang ?: @""]]
                   forState:UIControlStateNormal];
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
  if (_flowState != DBDoorFlowCalling) _cancelActionGeneration++;
  _flowState = DBDoorFlowCalling;
  _callingTitleOverride = [title copy];
  [_callTimer invalidate];
  [self refreshCallingDeadline];
  [self applyFlowVisibility];
  [self applyStrings];
  [self applySemanticStyles];
  [self setNeedsLayout];
  if (self.window != nil && UIAccessibilityIsVoiceOverRunning())
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, _callingLabel);
}

- (void)showInCall {
  [self dismissPurposeAlert];
  if (_flowState != DBDoorFlowInCall) _cancelActionGeneration++;
  _flowState = DBDoorFlowInCall;
  _callTimingChecking = NO;
  _callingTitleOverride = nil;
  [_callTimer invalidate];
  _callTimer = nil;
  [_callTiming invalidateCallbacks];
  [_feedbackAudio stop];
  [self applyFlowVisibility];
  [self applyStrings];
  [self applySemanticStyles];
  [self setNeedsLayout];
  if (self.window != nil && UIAccessibilityIsVoiceOverRunning())
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, _callingLabel);
}

- (void)showIdleWithHint:(NSString *)hint {
  [self dismissPurposeAlert];
  if (_flowState != DBDoorFlowIdle) _cancelActionGeneration++;
  _flowState = DBDoorFlowIdle;
  _activeCallID = nil;
  _activeStageRevision = 0;
  _callingTitleOverride = nil;
  [_callTimer invalidate];
  _callTimer = nil;
  [_callTiming invalidateCallbacks];
  [_callTiming reset];
  _callTimingChecking = NO;
  [_feedbackAudio stop];
  [self applyFlowVisibility];
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
  _touchHint.text = [_texts ts:[self showsHomePurposes] ? @"door.hint_purpose_first" : @"door.hint_call"];
}

- (void)onCall {
  if (_flowState != DBDoorFlowIdle) return;
  NSString *flow = [self callFlowMode];
  if (![self beginCallWithPurpose:@""]) return;
  [self showCallingWithTitle:nil];
  if ([flow isEqualToString:@"ring_then_purpose"] && [_purposeIds count] > 0)
    [self presentPurposeAlertForActiveCall:YES];
}

- (void)onPurpose:(UIButton *)sender {
  if (![self showsHomePurposes] || _flowState != DBDoorFlowIdle) return;
  if (sender.tag < 0 || sender.tag >= (NSInteger)[_purposeIds count]) return;
  NSString *identifier = [_purposeIds objectAtIndex:(NSUInteger)sender.tag];
  NSDictionary *entry = [DBConfigUtil dig:_cfg
      path:[NSString stringWithFormat:@"visit_purposes.%@", identifier]];
  NSString *label = [DBConfigUtil labelOf:entry lang:_visitorLang fallback:identifier];
  if (![self beginCallWithPurpose:identifier]) return;
  [self showCallingWithTitle:[_texts t:@"purpose.sent", label, nil]];
}

- (BOOL)beginCallWithPurpose:(NSString *)purpose {
  _activeStageRevision = 0;
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

- (BOOL)restoreWaitingCall:(NSString *)callID snapshot:(DBCallTimingSnapshot *)snapshot {
  if (_mediaSuspendedForBackground || snapshot.coreGeneration != _core.lifecycleGeneration)
    return NO;
  DBCallTimingReading *reading = [_callTiming observeSnapshot:snapshot callID:callID
      door:_boot.door now:DBCallMonotonicTime()];
  NSDictionary *call = reading.call;
  if (reading.disposition != DBCallTimingActive ||
      ![[DBConfigUtil evStr:call key:@"state"] isEqualToString:@"ringing"] ||
      ![[DBConfigUtil evStr:call key:@"origin"] isEqualToString:
          [DBConfigUtil str:snapshot.document path:@"node.id"]] ||
      [reading.remainingSeconds doubleValue] <= 0 ||
      ([DBConfigUtil evBool:call key:@"recovery_required"] && !reading.mayRestore)) return NO;

  BOOL alreadyVisible = _flowState == DBDoorFlowCalling &&
      [_activeCallID isEqualToString:callID];
  _activeCallID = [callID copy];
  _activeStageRevision = [DBConfigUtil intVal:call path:@"stage_revision" def:0];
  if (!alreadyVisible) {
    [_feedbackAudio playConfiguredSound:
        ([DBConfigUtil str:_cfg path:@"ui.call_sound"] ?: @"outdoor_call_alert")
                                    loop:[DBConfigUtil boolVal:_cfg
                                                        path:@"ui.call_sound_loop" def:NO]];
  }
  [self showCallingWithTitle:nil];

  NSString *flow = [DBConfigUtil evStr:call key:@"call_flow"];
  if ([flow length] == 0) flow = [DBConfigUtil str:_cfg path:@"ui.call_flow"];
  BOOL purposePending = ([flow isEqualToString:@"ring_then_purpose"] && _activeStageRevision == 0 &&
       [[DBConfigUtil evStr:call key:@"purpose"] length] == 0);
  if (purposePending && [_purposeIds count] > 0 &&
      _purposeAlertMode == DBDoorPurposeAlertNone &&
      ![_purposePromptedCallID isEqualToString:callID])
    [self presentPurposeAlertForActiveCall:YES];
  return YES;
}

- (void)dismissPurposeAlert {
  UIAlertView *alert = _purposeAlert;
  _purposeAlert = nil;
  alert.delegate = nil;
  [alert dismissWithClickedButtonIndex:alert.cancelButtonIndex animated:NO];
  _purposeAlertMode = DBDoorPurposeAlertNone;
  _purposeAlertIDs = nil;
  _purposeAlertCallID = nil;
}

- (void)presentPurposeAlertForActiveCall:(BOOL)activeCall {
  [self dismissPurposeAlert];
  if ([_purposeIds count] == 0) return;
  _purposeAlertMode = activeCall ? DBDoorPurposeAlertActiveCall : DBDoorPurposeAlertLocal;
  _purposeAlertCallID = activeCall ? [_activeCallID copy] : nil;
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
  _purposeAlert = alert;
  [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
  if (alertView != _purposeAlert) return;
  _purposeAlert = nil;
  DBDoorPurposeAlertMode mode = _purposeAlertMode;
  NSArray *identifiers = _purposeAlertIDs;
  NSString *callID = _purposeAlertCallID;
  _purposeAlertMode = DBDoorPurposeAlertNone;
  _purposeAlertIDs = nil;
  _purposeAlertCallID = nil;
  // A modal response belongs to the ringing call that opened it. It cannot
  // cancel a connected call or change a replacement call's purpose.
  if (mode == DBDoorPurposeAlertActiveCall &&
      (_flowState != DBDoorFlowCalling || ![callID isEqualToString:_activeCallID])) return;
  if (buttonIndex == alertView.cancelButtonIndex) {
    if (mode == DBDoorPurposeAlertActiveCall) [self onCancel];
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

- (void)selectLanguageAtIndex:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)[_languages count]) return;
  NSString *lang = [_languages objectAtIndex:(NSUInteger)index];
  [_core setVisitorLang:_boot.door ?: @"" lang:lang];
  [self setVisitorLanguage:lang];
}

- (void)onLanguageChanged:(UISegmentedControl *)sender {
  [self selectLanguageAtIndex:sender.selectedSegmentIndex];
}

- (void)onLanguageButton {
  [self dismissLanguageSheet];
  UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:[_texts ts:@"door.lang_switch"]
                                                     delegate:self
                                            cancelButtonTitle:nil
                                       destructiveButtonTitle:nil
                                            otherButtonTitles:nil];
  for (NSString *lang in _languages) [sheet addButtonWithTitle:[DBTexts langDisplayName:lang]];
  sheet.cancelButtonIndex = [sheet addButtonWithTitle:[_texts ts:@"admin.cancel"]];
  _languageSheet = sheet;
  [sheet showFromRect:_languageButton.frame inView:self animated:NO];
}

- (void)dismissLanguageSheet {
  UIActionSheet *sheet = _languageSheet;
  if (sheet == nil) return;
  _languageSheet = nil;
  sheet.delegate = nil;
  [sheet dismissWithClickedButtonIndex:sheet.cancelButtonIndex animated:NO];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
  if (actionSheet != _languageSheet) return;
  _languageSheet = nil;
  if (buttonIndex == actionSheet.cancelButtonIndex) return;
  [self selectLanguageAtIndex:buttonIndex];
}

- (void)onCancelTouchDown {
  _cancelTouchPending = YES;
  _cancelTouchPhase = _flowState;
  _cancelTouchCallID = [_activeCallID copy];
  _cancelTouchGeneration = _cancelActionGeneration;
}

- (void)onCancelTouchCancel {
  _cancelTouchPending = NO;
  _cancelTouchCallID = nil;
}

- (void)onCancel {
  BOOL captured = _cancelTouchPending;
  DBDoorFlowState phase = _cancelTouchPhase;
  NSString *callID = _cancelTouchCallID;
  NSUInteger generation = _cancelTouchGeneration;
  [self onCancelTouchCancel];
  // Keep a physical gesture bound to the operation shown at touch-down.
  // Accessibility activation has no touch-down and uses the currently visible operation.
  BOOL sameCall = callID == _activeCallID || [callID isEqualToString:_activeCallID];
  if (captured && (phase != _flowState || !sameCall ||
                   generation != _cancelActionGeneration)) return;
  if (_flowState == DBDoorFlowIdle) return;
  if (_flowState != DBDoorFlowInCall &&
      ([_activeCallID length] == 0 ||
       ![_core cancelCallV2:_boot.door ?: @"" callID:_activeCallID reason:@"visitor"])) return;
  [_router sipListenerHangup];
  [self showIdleWithHint:nil];
}

- (void)refreshCallingDeadline {
  [_callTimer invalidate];
  _callTimer = nil;
  [_callTiming invalidateCallbacks];
  if (_mediaSuspendedForBackground || _flowState != DBDoorFlowCalling ||
      [_activeCallID length] == 0) return;
  NSTimeInterval delay = 1.0;
  DBCallTimingSnapshot *snapshot = [_core callTimingSnapshot];
  DBCallTimingReading *reading = [_callTiming observeSnapshot:snapshot callID:_activeCallID
      door:_boot.door now:DBCallMonotonicTime()];
  if (reading.disposition == DBCallTimingAbsent) {
    [self showIdleWithHint:[_texts ts:@"calling.no_answer"]];
    return;
  }
  _callTimingChecking = reading.disposition != DBCallTimingActive ||
      ![[DBConfigUtil evStr:reading.call key:@"state"] isEqualToString:@"ringing"] ||
      [reading.remainingSeconds doubleValue] <= 0;
  if (!_callTimingChecking) delay = MIN(1.0, MAX(0.25, [reading.remainingSeconds doubleValue]));
  [self applyStrings];
  _callTimer = [NSTimer scheduledTimerWithTimeInterval:delay target:self
      selector:@selector(onCallTimeout:) userInfo:[_callTiming callbackForCall:_activeCallID
          coreGeneration:_core.lifecycleGeneration] repeats:NO];
}

- (void)onCallTimeout:(NSTimer *)timer {
  if (timer != _callTimer || ![_callTiming acceptsCallback:timer.userInfo callID:_activeCallID
      coreGeneration:_core.lifecycleGeneration]) return;
  [self refreshCallingDeadline];
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
  _replyShown = YES;
  [_replyTimer invalidate];
  NSTimeInterval ttl = [[event objectForKey:@"ttl_s"] doubleValue];
  if (ttl <= 0) ttl = 30;
  _replyDeadline = DBCallMonotonicTime() + ttl;
  [self updateReplyCountdown];
  _replyTimer = [NSTimer scheduledTimerWithTimeInterval:ttl target:self
      selector:@selector(hideReplyBanner) userInfo:nil repeats:NO];
  [self showIdleWithHint:nil];
}

- (void)hideReplyBanner {
  _replyShown = NO;
  [_replyAudio stop];
  [self applyFlowVisibility];
  [self setNeedsLayout];
}

// The seconds until the reply leaves the screen, refreshed by the clock tick so the screen
// runs no second timer.
- (void)updateReplyCountdown {
  if (!_replyShown) return;
  NSInteger seconds = (NSInteger)ceil(_replyDeadline - DBCallMonotonicTime());
  _replyCountdown.text = [NSString stringWithFormat:@"%ld", (long)MAX(0, seconds)];
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
    // Returning to a screen that is already idle costs a full re-theme and
    // relayout for nothing, and the listener can end dialogs faster than the
    // iPad 1 can lay out.
    if (_flowState == DBDoorFlowIdle) return;
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
  [self applyFlowVisibility];
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
  [self applyFlowVisibility];
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
  ++_snapshotGeneration;
  [_callTimer invalidate];
  _callTimer = nil;
  [_callTiming requireFreshSnapshot:[_core callTimingSnapshot]];
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
  [_callTiming requireFreshSnapshot:[_core callTimingSnapshot]];
  [self refreshCallingDeadline];
  [self refreshFromCore];
  if (!_rtspSuspendedForMemoryPressure) [self configureRTSPSource];
  [self configureLocalPreview];
  [self publishMediaSourceStatus];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  NSDictionary *callStyle = [self styleForSemanticID:@"call.primary"];
  NSDictionary *cancelStyle = [self styleForSemanticID:@"cancel.call"];
  NSDictionary *endStyle = [self styleForSemanticID:@"call.end"];
  // Reserve the largest configured action size before any transition; both
  // cancellation and local end stay in that rectangle throughout the call.
  CGFloat actionScale = MAX(DBDoorStyleNumber(callStyle, @"scale", 1, 0.75, 2),
      MAX(DBDoorStyleNumber(cancelStyle, @"scale", 1, 1, 2),
          DBDoorStyleNumber(endStyle, @"scale", 1, 1, 2)));
  DBDoorVisitorLayout layout = DBDoorVisitorLayoutMake(size, !_sos.hidden, actionScale);
  NSInteger languageCount = (NSInteger)[_languages count];
  layout = DBDoorVisitorLayoutFit(layout, languageCount >= 2, !_noticeLabel.hidden);
  BOOL compact = layout.compact;
  CGFloat margin = layout.margin;
  CGFloat gap = layout.gap;

  _nav.bar.frame = layout.topBar;
  _infoButton.frame = CGRectMake(size.width - 64, 0, 64, 64);
  _callButton.frame = layout.action;
  _cancelButton.frame = layout.action;
  _touchHint.frame = layout.status;
  _touchHint.font = [UIFont systemFontOfSize:compact ? 15 : (layout.sideBySide ? 20 : 24)];
  _versionLabel.frame = layout.version;
  _sos.frame = layout.sos;

  // Segments while each stays wide enough to hit and read; one button that opens a sheet
  // once more languages are enabled than fit.
  _languageUsesSheet =
      layout.language.size.width < kLanguageSegmentMinimum * (CGFloat)languageCount;
  _languageControl.frame = layout.language;
  _languageButton.frame = layout.language;
  _languagePlate.frame = layout.language;
  [self applyFlowVisibility];

  _clockLabel.font = [UIFont systemFontOfSize:compact ? 36 : 72];
  _clockLabel.frame = layout.clock;
  _dateLabel.font = [UIFont systemFontOfSize:compact ? 15 : 22];
  _dateLabel.frame = layout.date;

  // Collapsed, the announcement shows two lines in its own row. Expanded, it grows over the
  // clock and the date, and never over a purpose or an action.
  _noticeLabel.font = [UIFont systemFontOfSize:compact ? 15 : 20];
  _noticeLabel.numberOfLines = _noticeExpanded ? 0 : 2;
  CGRect noticeFrame = layout.notice;
  if (_noticeExpanded && !_noticeLabel.hidden) {
    CGFloat wanted = [_noticeLabel sizeThatFits:
        CGSizeMake(layout.headline.size.width - 24, 1000)].height + 16;
    noticeFrame = layout.headline;
    noticeFrame.size.height = MIN(layout.headline.size.height,
                                  MAX(layout.notice.size.height, wanted));
  }
  _noticeCard.frame = noticeFrame;
  _noticeLabel.frame = CGRectInset(_noticeCard.bounds, 12, 6);
  _noticeExpand.frame = _noticeCard.bounds;

  _replyPlate.frame = layout.headline;
  CGRect replyBounds = CGRectInset(_replyPlate.bounds, 12, 6);
  replyBounds.size.height = MAX(0, replyBounds.size.height - 20);
  _replyText.frame = replyBounds;
  _replyText.font = DBDoorFittingFont(_replyText.text ?: @"", compact ? 20 : 28, 13, YES,
                                      replyBounds.size);
  _replyCountdown.frame = CGRectMake(12, CGRectGetMaxY(replyBounds),
                                     MAX(0, _replyPlate.bounds.size.width - 24), 20);

  // The purposes scroll inside their viewport when the grid is taller than it. The pairing
  // reminder leads and the media line trails the grid.
  _purposeScroll.frame = layout.purposes;
  CGFloat gridWidth = layout.purposes.size.width;
  CGFloat y = 0;
  CGRect pairFrame = CGRectZero;
  if (!_pairBanner.hidden) {
    pairFrame = CGRectMake(0, 0, gridWidth, compact ? 44 : 56);
    y = CGRectGetMaxY(pairFrame) + gap;
  }
  _pairBanner.frame = pairFrame;
  _pairPlate.frame = pairFrame;
  _pairPlate.hidden = _pairBanner.hidden;

  BOOL showsPurposes = [self showsHomePurposes];
  NSInteger purposeCount = (NSInteger)[_purposeButtons count];
  NSDictionary *purposeStyle = [self styleForSemanticID:@"purpose.button"];
  CGFloat purposeFontSize = (compact ? 18 : 22) *
      DBDoorStyleNumber(purposeStyle, @"font_scale", 1, 0.75, 2);
  UIFont *purposeFont = DBDoorFont(purposeFontSize, _purposeButtonsFilled || !DBChromeIsFlat());
  CGFloat cellWidth = DBDoorVisitorPurposeFrame(layout, 0, 0).size.width;
  CGFloat rowHeight = 0;
  for (UIButton *button in _purposeButtons) {
    button.titleLabel.font = purposeFont;
    CGFloat iconWidth = [button imageForState:UIControlStateNormal] != nil
        ? kPurposeIconSide + 8 : 0;
    CGSize textSize = [button.currentTitle sizeWithFont:purposeFont
        constrainedToSize:CGSizeMake(MAX(44, cellWidth - 16 - iconWidth), 1000)
        lineBreakMode:NSLineBreakByWordWrapping];
    rowHeight = MAX(rowHeight, MIN(textSize.height, purposeFont.lineHeight * 2) + 24);
  }
  for (NSInteger i = 0; i < purposeCount; i++) {
    UIButton *button = [_purposeButtons objectAtIndex:(NSUInteger)i];
    CGRect frame = CGRectOffset(DBDoorVisitorPurposeFrame(layout, i, rowHeight), 0, y);
    button.frame = frame;
    button.hidden = !showsPurposes;
    id plate = [_purposePlates objectAtIndex:(NSUInteger)i];
    if ([plate isKindOfClass:[UIView class]]) {
      [(UIView *)plate setFrame:frame];
      [(UIView *)plate setHidden:!showsPurposes];
    }
  }
  if (showsPurposes && purposeCount > 0)
    y += DBDoorVisitorPurposeGridHeight(layout, purposeCount, rowHeight) + gap;
  _mediaBadge.frame = CGRectMake(0, y, gridWidth, _mediaBadge.hidden ? 0 : 40);
  _purposeScroll.contentSize = CGSizeMake(gridWidth, CGRectGetMaxY(_mediaBadge.frame));

  // The call button carries the largest text on the screen. A long label shrinks until it
  // fits the fixed rectangle instead of moving it.
  NSDictionary *activeCancelStyle = _flowState == DBDoorFlowInCall ? endStyle : cancelStyle;
  CGSize actionText = CGSizeMake(layout.action.size.width - 24, layout.action.size.height - 16);
  _callButton.titleLabel.font = DBDoorFittingFont(_callButton.currentTitle ?: @"",
      (compact ? 24 : 40) * DBDoorStyleNumber(callStyle, @"font_scale", 1, 0.75, 2),
      16, YES, actionText);
  _cancelButton.titleLabel.font = DBDoorFittingFont(_cancelButton.currentTitle ?: @"",
      (compact ? 24 : 40) * DBDoorStyleNumber(activeCancelStyle, @"font_scale", 1, 0.75, 2),
      16, YES, actionText);

  // Calling and connected: one status plate in the content zone, above the same action
  // rectangle that now holds Cancel or End.
  CGFloat plateHeight = MIN(layout.content.size.height, compact ? 140 : 240);
  _callPlate.frame = CGRectMake(layout.content.origin.x,
      floor(layout.content.origin.y + (layout.content.size.height - plateHeight) / 2),
      layout.content.size.width, plateHeight);
  CGSize spinnerSize = _callSpinner.bounds.size;
  _callSpinner.center = CGPointMake(floor(_callPlate.bounds.size.width / 2),
                                    12 + floor(spinnerSize.height / 2));
  CGFloat statusTop = 12 + spinnerSize.height + 8;
  CGRect statusFrame = CGRectMake(12, statusTop, MAX(0, _callPlate.bounds.size.width - 24),
                                  MAX(0, plateHeight - statusTop - 12));
  _callingLabel.frame = statusFrame;
  _callingLabel.font = DBDoorFittingFont(_callingLabel.text ?: @"", compact ? 24 : 40, 14, YES,
                                         statusFrame.size);

  [self applyRegionInk];

  _emergencyOverlay.frame = self.bounds;
  CGFloat width = size.width - 2 * margin;
  NSDictionary *sosStyle = [self styleForSemanticID:@"sos.cancel"];
  CGRect clearFrame = DBDoorVisitorLayoutMake(size, NO,
      DBDoorStyleNumber(sosStyle, @"scale", 1, 1, 2)).action;
  clearFrame.origin.x = floor((size.width - clearFrame.size.width) / 2);
  clearFrame.origin.y = size.height - margin - clearFrame.size.height;
  _emergencyTitle.font = [UIFont boldSystemFontOfSize:compact ? 32 : 56];
  _emergencyTitle.frame = CGRectMake(margin, margin, width, compact ? 76 : 120);
  _emergencyNote.font = [UIFont systemFontOfSize:compact ? 20 : 25];
  _emergencyNote.frame = CGRectMake(margin, CGRectGetMaxY(_emergencyTitle.frame) + gap,
      width, MAX(44, CGRectGetMinY(clearFrame) - CGRectGetMaxY(_emergencyTitle.frame) - gap * 2));
  _emergencyCancel.titleLabel.font = [UIFont boldSystemFontOfSize:
      24 * DBDoorStyleNumber(sosStyle, @"font_scale", 1, 0.75, 2)];
  _emergencyCancel.frame = clearFrame;
}

@end
