#import "DBDoorScreen.h"

#import "../Core/DBAirQualityModel.h"
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
#import "../Core/DBVisitorFlowModel.h"
#import "../Core/DBTextFit.h"
#import "../Core/DBLatestWins.h"
#import "../Core/DBReplyDismissal.h"
#import "../Core/DBUiTheme.h"
#import "../Media/DBSiren.h"
#import "../Net/DBMjpegClient.h"
#import "../Net/DBRTSPH264Source.h"
#import "../Net/DBSnapshotPoller.h"
#import "DBChrome.h"
#import "DBRouter.h"
#import "DBSosPanel.h"
#import "DBWidgets.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
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

// A flow image decoded at no more than maxPixel on its long side, so the A4 never holds a
// full-size photograph. Runs off the main thread.
static UIImage *DBFlowDecodeImage(NSString *path, CGFloat maxPixel) {
  if ([path length] == 0) return nil;
  CGImageSourceRef source = CGImageSourceCreateWithURL(
      (__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
  if (source == NULL) return nil;
  NSDictionary *options = @{
    (id)kCGImageSourceCreateThumbnailFromImageAlways : (__bridge id)kCFBooleanTrue,
    (id)kCGImageSourceThumbnailMaxPixelSize : [NSNumber numberWithFloat:(float)maxPixel],
    (id)kCGImageSourceCreateThumbnailWithTransform : (__bridge id)kCFBooleanTrue,
    (id)kCGImageSourceShouldCache : (__bridge id)kCFBooleanFalse,
  };
  CGImageRef decoded = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                           (__bridge CFDictionaryRef)options);
  CFRelease(source);
  if (decoded == NULL) return nil;
  UIImage *image = [UIImage imageWithCGImage:decoded];
  CGImageRelease(decoded);
  return image;
}

static const CGFloat kFlowImageMaxPixel = 1024;


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

@interface DBDoorScreen () <UIAlertViewDelegate, UIActionSheetDelegate, DBSosSliderDelegate,
                            UIScrollViewDelegate>
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
static const CGFloat kPurposeIconSide = 28;
static const NSInteger kPurposeIconTag = 7401;
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
  // The visitor flow (docs/en/visitor-flow-contract.md): the page card, the fixed option zone,
  // and Back. All of it is hidden while the classic screen or a call is showing.
  DBVisitorFlowModel *_flow;
  NSString *_flowRevision;
  NSInteger _flowGeneration;
  UIView *_flowPlate;
  UIScrollView *_flowScroll;
  UILabel *_flowNotice;
  UILabel *_flowTitle;
  UILabel *_flowBody;
  NSMutableArray *_flowImageViews;
  NSMutableArray *_flowImageAlts;
  NSArray *_flowImageInfos;
  NSMutableDictionary *_flowImageCache;
  NSMutableSet *_flowImageLoading;
  UIScrollView *_flowOptionScroll;
  UIView *_flowFade;
  NSMutableArray *_flowOptionButtons;
  NSMutableArray *_flowOptionPlates;
  NSArray *_flowOptionModels;
  BOOL _flowFilled;
  BOOL _flowHasContent;
  UIView *_flowBackPlate;
  UIButton *_flowBackButton;
  NSString *_flowRenderedPage;
  NSString *_flowRenderedMode;
  NSTimeInterval _flowLastInput;
  NSTimeInterval _flowEndSince;
  BOOL _flowBusy;
  BOOL _flowDebugHold;
  NSString *_endReason;
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
  UIControl *_replyPlate;
  UILabel *_replyHint;
  UILabel *_replyCountdown;
  DBReplyDismissal _replyDismissal;
  NSTimeInterval _replyDeadline;
  NSUInteger _langGeneration;
  BOOL _langWritePending;
  UIScrollView *_replyScroll;
  UILabel *_replyText;
  NSString *_replyFitKey;
  BOOL _replyShown;
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
  DBAirQualityIndicator *_air;
  NSDictionary *_airDocument;
  NSInteger _airGeneration;
  NSTimer *_airTimer;
  UIView *_noticeCard;
  UILabel *_noticeLabel;
  UIButton *_noticeExpand;
  BOOL _noticeExpanded;
  UILabel *_versionLabel;
  UILabel *_titleLabel;       // The door name, leading edge of the top row.
  UIView *_timeScrim;         // Seats the small time under a subtle band over any wallpaper.
  UIImageView *_themeBg;
  NSString *_themeHash;
  CGSize _themeImageSize;
  DBBackgroundSampler *_sampler;
  CGSize _samplerSize;
  BOOL _samplerBuilding;
  NSDictionary *_display;   // status.display: core-resolved appearance and theme.
  NSDictionary *_status;
  DBSosSlider *_sos;        // Lives inside the confirmation panel, never on the visitor screen.
  DBSosPanel *_sosPanel;
  UIButton *_sosButton;
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
  [_airTimer invalidate];
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
  _timeScrim = [[UIView alloc] init];
  _timeScrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35f];
  _timeScrim.layer.cornerRadius = 8;
  [self addSubview:_timeScrim];

  _titleLabel = [self wallpaperLabelWithFont:[UIFont boldSystemFontOfSize:28]];
  _titleLabel.textAlignment = NSTextAlignmentLeft;
  _titleLabel.adjustsFontSizeToFitWidth = YES;
  _titleLabel.minimumFontSize = 16;
  _titleLabel.accessibilityIdentifier = @"door_title";
  [self addSubview:_titleLabel];

  _clockLabel = [self wallpaperLabelWithFont:[UIFont systemFontOfSize:72]];
  _clockLabel.adjustsFontSizeToFitWidth = YES;
  _clockLabel.minimumFontSize = 14;
  _clockLabel.textAlignment = NSTextAlignmentLeft;
  [self addSubview:_clockLabel];

  _dateLabel = [self wallpaperLabelWithFont:[UIFont systemFontOfSize:22]];
  _dateLabel.adjustsFontSizeToFitWidth = YES;
  _dateLabel.minimumFontSize = 12;
  _dateLabel.textAlignment = NSTextAlignmentLeft;
  [self addSubview:_dateLabel];

  _air = [[DBAirQualityIndicator alloc] init];
  [_air addToView:self];

  _touchHint = [self wallpaperLabelWithFont:[UIFont systemFontOfSize:24]];
  _touchHint.numberOfLines = 2;
  _touchHint.textColor = [UIColor colorWithWhite:1 alpha:0.65];
  [self addSubview:_touchHint];

  _versionLabel = [self wallpaperLabelWithFont:[UIFont systemFontOfSize:16]];
  _versionLabel.adjustsFontSizeToFitWidth = YES;
  _versionLabel.minimumFontSize = 11;
  _versionLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
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
  [self buildFlowViews];

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

  _replyPlate = [[UIControl alloc] init];
  _replyPlate.hidden = YES;
  _replyScroll = [[UIScrollView alloc] init];
  _replyScroll.backgroundColor = [UIColor clearColor];
  [_replyPlate addSubview:_replyScroll];
  _replyText = [self plateLabelWithFont:[UIFont boldSystemFontOfSize:28]];
  _replyText.textAlignment = NSTextAlignmentCenter;
  _replyText.textColor = [UIColor whiteColor];
  _replyText.accessibilityIdentifier = @"door_reply";
  [_replyScroll addSubview:_replyText];
  // A full-screen opaque overlay: any tap dismisses it, as announced to assistive technology.
  _replyPlate.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1];
  _replyPlate.isAccessibilityElement = YES;
  _replyPlate.accessibilityTraits = UIAccessibilityTraitButton;
  [_replyPlate addTarget:self action:@selector(onReplyTap)
        forControlEvents:UIControlEventTouchUpInside];
  [_replyScroll addGestureRecognizer:[[UITapGestureRecognizer alloc]
      initWithTarget:self action:@selector(onReplyTap)]];
  _replyHint = [self plateLabelWithFont:[UIFont systemFontOfSize:14]];
  _replyHint.numberOfLines = 1;
  _replyHint.textAlignment = NSTextAlignmentCenter;
  _replyHint.textColor = [UIColor colorWithWhite:1 alpha:0.7f];
  _replyHint.userInteractionEnabled = NO;
  [_replyPlate addSubview:_replyHint];
  _replyCountdown = [self plateLabelWithFont:[UIFont systemFontOfSize:14]];
  _replyCountdown.numberOfLines = 1;
  _replyCountdown.textAlignment = NSTextAlignmentRight;
  _replyCountdown.textColor = [UIColor colorWithWhite:1 alpha:0.7f];
  _replyCountdown.userInteractionEnabled = NO;
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
  _sosPanel = [[DBSosPanel alloc] initWithSlider:_sos delegate:self];
  _sosButton = DBSosTriggerButton();
  _sosButton.accessibilityIdentifier = @"door_sos_open";
  _sosButton.hidden = YES;
  [_sosButton addTarget:self action:@selector(onSosButton)
       forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_sosButton];

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
  // A call state change or an emergency replaces the reply at once.
  if (_replyShown && (!idle || !_emergencyOverlay.hidden)) {
    _replyShown = NO;
    [_replyTimer invalidate];
    [_replyAudio stop];
  }
  BOOL reply = idle && _replyShown;
  BOOL notice = idle && !reply && !_noticeLabel.hidden;
  BOOL covered = reply || (notice && _noticeExpanded);
  _replyPlate.hidden = !reply;
  if (reply) [self insertSubview:_replyPlate belowSubview:_emergencyOverlay];
  _noticeCard.hidden = !notice;
  _clockLabel.hidden = !idle || covered;
  _dateLabel.hidden = !idle || covered;
  _timeScrim.hidden = CGRectIsEmpty(_titleLabel.frame);
  [_air setSuppressed:!idle || covered || CGRectIsEmpty(_air.label.frame)];
  BOOL flowOn = idle && [self flowShowing];
  _purposeScroll.hidden = !idle;
  _touchHint.hidden = !idle || flowOn;
  _callButton.hidden = !idle || flowOn;
  _flowPlate.hidden = !(flowOn && _flowHasContent);
  _flowOptionScroll.hidden = !flowOn;
  _flowBackButton.hidden = !(flowOn && [_flow canGoBack]);
  _flowBackPlate.hidden = _flowBackButton.hidden;
  if (!flowOn) _flowFade.hidden = YES;
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
  if (!_airTimer) {
    // air_quality_changed omits age changes, so a visible line is re-read once a minute.
    _airTimer = [NSTimer scheduledTimerWithTimeInterval:60.0 target:self
                                               selector:@selector(refreshAirQuality)
                                               userInfo:nil repeats:YES];
  }
  [self updateClock];
  [self refreshFromCore];
  [self refreshAirQuality];
  [self applyStrings];
}

- (void)pollKeyframeRequest:(NSTimer *)timer {
  (void)timer;
  if ([_core takeVideoKeyframeRequest]) [_rtspSource requestKeyFrame];
}

// Rendered from Core's local-time document: no operating-system time-zone
// database is needed and the clock follows the cluster zone and NTP offset.
- (void)updateClock {
  [self updateReplyCaptions];
  [self flowTick];
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
  [_sosPanel applyTexts:_texts];

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
  if (showSos != !_sosButton.hidden) {
    NSLog(@"[doorbell][sos] door station bar %@ (button_on_roles=%@)",
          showSos ? @"shown" : @"hidden", roles ?: @"<unset>");
  }
  if (_sosButton.hidden == showSos) [self setNeedsLayout];
  _sosButton.hidden = !showSos;
  if (!showSos) [_sosPanel dismiss];

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
  _titleLabel.textColor = [UIColor whiteColor];  // The name and the time sit on a dark band.
  _clockLabel.textColor = [UIColor whiteColor];
  _dateLabel.textColor = [UIColor whiteColor];
  [_air applyPalette:_palette region:DBUiRegionDate];
  [_palette applyInkToLabel:_touchHint region:DBUiRegionHint];
  [_palette applyInkToLabel:_versionLabel region:DBUiRegionStatusLine];
  [_palette applyInkToLabel:_mediaBadge region:DBUiRegionStatusLine];
}

- (void)sosSliderDidArm:(DBSosSlider *)slider { (void)slider; }
- (void)sosSliderDidCancel:(DBSosSlider *)slider { (void)slider; }

// The button only opens the confirmation panel; the slide inside it is the second gesture.
- (void)onSosButton {
  if (!_emergencyOverlay.hidden) return;
  [_sosPanel presentInView:self below:_emergencyOverlay];
}

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
  [_airTimer invalidate];
  _airTimer = nil;
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
    NSDictionary *flowDocument = [DBCoreBridge supportsVisitorFlow]
        ? [core visitorFlowJson:@""] : nil;
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
      [screen applyFlowDocument:flowDocument];
      [screen publishMediaSourceStatus];
      [screen applyTheme];
      [screen rebuildPurposes];
      [screen rebuildLanguages];
      if (waitingCall) [screen restoreWaitingCall:[DBConfigUtil evStr:waitingCall key:@"call_id"]
                                        snapshot:timingSnapshot];
      [screen applyStrings];
      [screen applyAirQuality];
      [screen applySemanticStyles];
      [screen setNeedsLayout];
    });
  });
}

- (void)refreshAirQuality {
  if (!_onScreen) return;
  NSInteger generation = ++_airGeneration;
  DBCoreBridge *core = _core;
  __weak DBDoorScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *document = [core airQualityJson];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBDoorScreen *screen = weakSelf;
      if (!screen || generation != screen->_airGeneration || !screen->_onScreen) return;
      screen->_airDocument = document;
      [screen applyAirQuality];
    });
  });
}

// The row moves the notice and the purposes, and the text width places the dot, so every change
// goes through layout.
- (void)applyAirQuality {
  BOOL wasVisible = _air.visible;
  [_air applyModel:[DBAirQualityModel modelWithDocument:_airDocument texts:_texts]];
  if (wasVisible || _air.visible) [self setNeedsLayout];
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
  // The configured door label for this station's door, else the device's own name; never the
  // opaque door id.
  NSString *label = [DBConfigUtil labelOf:entry lang:_visitorLang fallback:@""];
  return [label length] ? label : _boot.name;
}

- (NSString *)callFlowMode {
  id value = [DBConfigUtil dig:_cfg path:@"ui.call_flow"];
  if ([value isKindOfClass:[NSDictionary class]]) value = [value objectForKey:@"mode"];
  return [value isKindOfClass:[NSString class]] && [value isEqualToString:@"ring_then_purpose"]
      ? @"ring_then_purpose" : @"purpose_first";
}

- (BOOL)showsHomePurposes {
  return ![self flowActive] && [[self callFlowMode] isEqualToString:@"purpose_first"] &&
      [_purposeIds count] > 0;
}

- (void)applyStrings {
  _nav.topItem.title = [self doorLabel];
  _titleLabel.text = [self doorLabel];
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

  [_flowBackButton setTitle:[_texts ts:@"flow.back"] forState:UIControlStateNormal];
  _flowBackButton.accessibilityLabel = _flowBackButton.currentTitle;
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
  [self applyFlowStyles];
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
    // Emoji never reach a card: a missing asset leaves the label alone.
    NSString *title = label;
    UIButton *button = _purposeButtonsFilled ? [self filledButton] : DBChromeButton(title, 22);
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.adjustsFontSizeToFitWidth = NO;
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
    if (asset != nil) {
      // The icon rides above the label as its own view, so every card lines up the same way.
      UIImageView *icon = [[UIImageView alloc] initWithImage:asset];
      icon.tag = kPurposeIconTag;
      if (!_purposeButtonsFilled && [asset respondsToSelector:@selector(imageWithRenderingMode:)])
        icon.image = [asset imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
      [button addSubview:icon];
      button.titleEdgeInsets = UIEdgeInsetsMake(kPurposeIconSide + 6, 0, 0, 0);
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

// YES when the existing cards still match the enabled purposes and were relabelled.
- (BOOL)retitlePurposesInPlace {
  NSArray *ids = [DBPurposeModel enabledPurposeIdsInConfig:_cfg];
  if (![ids isEqualToArray:_purposeIds ?: @[]] ||
      [ids count] != [_purposeButtons count]) return NO;
  NSDictionary *purposes = [DBConfigUtil dig:_cfg path:@"visit_purposes"];
  if (![purposes isKindOfClass:[NSDictionary class]]) purposes = nil;
  for (NSUInteger i = 0; i < [ids count]; i++) {
    NSString *identifier = [ids objectAtIndex:i];
    NSString *label = [DBConfigUtil labelOf:[purposes objectForKey:identifier] lang:_visitorLang
                                   fallback:identifier];
    UIButton *button = [_purposeButtons objectAtIndex:i];
    [button setTitle:label forState:UIControlStateNormal];
    button.accessibilityLabel = label;
  }
  return YES;
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
  // The cards keep their views and icons; only their labels change with the language.
  if (![self retitlePurposesInPlace]) [self rebuildPurposes];
  if (_flow != nil) {
    _flow.lang = value;
    [self flowStateChanged];
  }
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
  if (_flowState != DBDoorFlowIdle) {
    _cancelActionGeneration++;
    [self flowCallEnded];
  }
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
  [self renderFlow];
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
  if ([self flowShowing]) return;
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
  [self setVisitorLanguage:lang];
  // Only the final selection reaches Core: each tap supersedes the pending write.
  NSUInteger token = DBLatestWinsBegin(&_langGeneration);
  _langWritePending = YES;
  NSString *door = _boot.door ?: @"";
  __weak DBDoorScreen *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    DBDoorScreen *screen = weakSelf;
    if (!screen || !DBLatestWinsIsCurrent(screen->_langGeneration, token)) return;
    screen->_langWritePending = NO;
    [screen->_core setVisitorLang:door lang:screen->_visitorLang];
  });
}

- (void)onLanguageChanged:(UISegmentedControl *)sender {
  CFTimeInterval started = CACurrentMediaTime();
  [self selectLanguageAtIndex:sender.selectedSegmentIndex];
  if (_boot.debugScreenshots) {
    CFTimeInterval applied = CACurrentMediaTime();
    [self layoutIfNeeded];
    CFTimeInterval done = CACurrentMediaTime();
    [self traceLanguageMilliseconds:(done - started) * 1000
                            applied:(applied - started) * 1000];
  }
}

// Debug builds only: the handler's cost, appended where the diagnostics can fetch it.
- (void)traceLanguageMilliseconds:(double)milliseconds applied:(double)applied {
  NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/langtiming.txt"];
  NSString *line = [NSString stringWithFormat:@"%.1f apply=%.1f\n", milliseconds, applied];
  NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!handle) {
    [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    return;
  }
  [handle seekToEndOfFile];
  [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
  [handle closeFile];
}

// Debug builds only: rapid switching as a finger would do it.
- (void)debugLanguageBurst {
  if ([_languages count] < 2) return;
  for (NSInteger i = 0; i < 12; i++) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      _languageControl.selectedSegmentIndex = i % (NSInteger)[_languages count];
      [self onLanguageChanged:_languageControl];
    });
  }
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
    _endReason = @"timeout";
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
  _replyPlate.accessibilityLabel = [_texts ts:@"ui.close"];
  _replyPlate.accessibilityValue = _replyText.text;
  _replyShown = YES;
  [_flow applyEvent:@{ @"reply" : @YES }];
  _replyDismissal = DBReplyDismissalBegin(DBCallMonotonicTime());
  [_replyTimer invalidate];
  NSTimeInterval ttl = [[event objectForKey:@"ttl_s"] doubleValue];
  if (ttl <= 0) ttl = 30;
  _replyDeadline = DBCallMonotonicTime() + ttl;
  [self updateReplyCaptions];
  _replyTimer = [NSTimer scheduledTimerWithTimeInterval:ttl target:self
      selector:@selector(hideReplyBanner) userInfo:nil repeats:NO];
  [self showIdleWithHint:nil];
}

- (void)debugShowState:(NSString *)state {
  if ([state isEqualToString:@"calling"]) {
    [self showCallingWithTitle:nil];
  } else if ([state isEqualToString:@"connected"]) {
    [self showInCall];
  } else if ([state isEqualToString:@"langburst"]) {
    [self debugLanguageBurst];
  } else if ([state hasPrefix:@"reply"]) {
    // "reply" shows a sample; "reply:<text>" shows that text.
    NSString *sample = [state length] > 6 ? [state substringFromIndex:6]
        : @"少々お待ちください。すぐに参ります。";
    [self handleReplyEvent:@{ @"text" : sample, @"ttl_s" : @300 }];
  } else if ([state hasPrefix:@"flow"]) {
    // "flow" shows the start page; "flow:<step id>" shows that page or end page.
    [self debugShowFlowStep:[state length] > 5 ? [state substringFromIndex:5] : @"" attempt:0];
  } else if ([state isEqualToString:@"noanswer"]) {
    [self showIdleWithHint:[_texts ts:@"calling.no_answer"]];
  }
}

// The largest size at which the whole reply fits the box; below the floor the text scrolls.
// Runs only when the text or the box changed, never on a plain layout pass.
- (void)fitReplyTextInBox:(CGSize)box {
  NSString *text = _replyText.text ?: @"";
  NSString *key = [NSString stringWithFormat:@"%@|%.0f|%.0f", text, box.width, box.height];
  if ([key isEqualToString:_replyFitKey]) return;
  _replyFitKey = key;
  CGFloat size = DBTextFitSize(box, 28, box.height, ^CGFloat(CGFloat candidate, CGFloat width) {
    return [text sizeWithFont:[UIFont boldSystemFontOfSize:candidate]
            constrainedToSize:CGSizeMake(width, 100000)
                lineBreakMode:NSLineBreakByWordWrapping].height;
  });
  UIFont *font = [UIFont boldSystemFontOfSize:size];
  CGFloat height = ceil([text sizeWithFont:font constrainedToSize:CGSizeMake(box.width, 100000)
                             lineBreakMode:NSLineBreakByWordWrapping].height);
  _replyText.font = font;
  CGFloat contentHeight = MAX(box.height, height);
  _replyText.frame = CGRectMake(0, floor((contentHeight - height) / 2), box.width, height);
  _replyScroll.contentSize = CGSizeMake(box.width, contentHeight);
  _replyScroll.contentOffset = CGPointZero;
}

// Runs from the one-second clock tick, and only while the reply is on screen.
- (void)updateReplyCaptions {
  if (!_replyShown) return;
  // The emergency overlay already covers the reply; the next tick retires it.
  if (!_emergencyOverlay.hidden) {
    [self hideReplyBanner];
    return;
  }
  NSTimeInterval now = DBCallMonotonicTime();
  _replyCountdown.text = [NSString stringWithFormat:@"%ld",
      (long)MAX(0, (NSInteger)ceil(_replyDeadline - now))];
  DBReplyHint hint = DBReplyDismissalHint(_replyDismissal, now);
  NSString *text = hint == DBReplyHintFirst ? [_texts ts:@"reply.exit_hint"]
      : (hint == DBReplyHintConfirm ? [_texts ts:@"reply.exit_confirm"] : @"");
  if (![_replyHint.text isEqualToString:text]) _replyHint.text = text;
  _replyHint.font = hint == DBReplyHintConfirm ? [UIFont boldSystemFontOfSize:18]
                                               : [UIFont systemFontOfSize:14];
  _replyHint.textColor = [UIColor colorWithWhite:1 alpha:hint == DBReplyHintConfirm ? 1 : 0.7f];
}

- (void)onReplyTap {
  if (!_replyShown) return;
  if (DBReplyDismissalTap(&_replyDismissal, DBCallMonotonicTime()) == DBReplyTapClose)
    [self hideReplyBanner];
  else [self updateReplyCaptions];
}

- (void)hideReplyBanner {
  _replyShown = NO;
  [_flow applyEvent:@{ @"reply" : @NO }];
  [_replyAudio stop];
  [self applyFlowVisibility];
  [self setNeedsLayout];
}

- (void)handleVisitorLangEvent:(NSDictionary *)event {
  NSString *door = [DBConfigUtil evStr:event key:@"door"];
  NSString *lang = [DBConfigUtil evStr:event key:@"lang"];
  // The echo of an earlier selection must not undo a newer one that is still pending.
  if (_langWritePending || [lang isEqualToString:_visitorLang ?: @""]) return;
  if ([door length] == 0 || [_boot.door length] == 0 || [door isEqualToString:_boot.door])
    [self setVisitorLanguage:lang];
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
  // A missed call is a cancellation with reason "timeout"; the flow may branch on it.
  _endReason = [DBConfigUtil evStr:event key:@"reason"];
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
  // A real alarm supersedes a confirmation that is still open underneath it.
  if (active) [_sosPanel dismiss];
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

#pragma mark - visitor flow

- (BOOL)flowActive {
  return _flow != nil && _flow.active;
}

// The page or end page of the flow is what the visitor sees, and nothing else claims the screen.
- (BOOL)flowShowing {
  return [self flowActive] && _flowState == DBDoorFlowIdle &&
      ([_flow.mode isEqualToString:DBVisitorFlowModePage] ||
       [_flow.mode isEqualToString:DBVisitorFlowModeEnd]);
}

- (void)buildFlowViews {
  _flowImageViews = [[NSMutableArray alloc] init];
  _flowImageAlts = [[NSMutableArray alloc] init];
  _flowImageCache = [[NSMutableDictionary alloc] init];
  _flowImageLoading = [[NSMutableSet alloc] init];
  _flowOptionButtons = [[NSMutableArray alloc] init];
  _flowOptionPlates = [[NSMutableArray alloc] init];

  _flowPlate = DBDoorPlate();
  _flowPlate.hidden = YES;
  [self addSubview:_flowPlate];
  _flowScroll = [[UIScrollView alloc] init];
  _flowScroll.backgroundColor = [UIColor clearColor];
  _flowScroll.delegate = self;
  _flowScroll.accessibilityIdentifier = @"flow_text";
  [_flowPlate addSubview:_flowScroll];
  _flowNotice = [self plateLabelWithFont:[UIFont boldSystemFontOfSize:20]];
  _flowNotice.textColor = [UIColor colorWithRed:0.75 green:0.16 blue:0.13 alpha:1];
  _flowNotice.textAlignment = NSTextAlignmentCenter;
  _flowNotice.accessibilityIdentifier = @"flow_notice";
  [_flowScroll addSubview:_flowNotice];
  _flowTitle = [self plateLabelWithFont:[UIFont boldSystemFontOfSize:34]];
  _flowTitle.textAlignment = NSTextAlignmentCenter;
  _flowTitle.accessibilityIdentifier = @"flow_title";
  [_flowScroll addSubview:_flowTitle];
  _flowBody = [self plateLabelWithFont:[UIFont systemFontOfSize:24]];
  _flowBody.accessibilityIdentifier = @"flow_body";
  [_flowScroll addSubview:_flowBody];

  _flowOptionScroll = [[UIScrollView alloc] init];
  _flowOptionScroll.backgroundColor = [UIColor clearColor];
  _flowOptionScroll.delegate = self;
  _flowOptionScroll.hidden = YES;
  _flowOptionScroll.accessibilityIdentifier = @"flow_options";
  [self addSubview:_flowOptionScroll];
  _flowFade = [[UIView alloc] init];
  _flowFade.userInteractionEnabled = NO;
  _flowFade.hidden = YES;
  CAGradientLayer *gradient = [CAGradientLayer layer];
  gradient.colors = [NSArray arrayWithObjects:
      (id)[UIColor colorWithWhite:0 alpha:0].CGColor,
      (id)[UIColor colorWithWhite:0 alpha:0.5f].CGColor, nil];
  [_flowFade.layer addSublayer:gradient];
  [self addSubview:_flowFade];

  if (DBChromeIsFlat()) {
    _flowBackPlate = DBDoorPlate();
    _flowBackPlate.hidden = YES;
    [self addSubview:_flowBackPlate];
  }
  _flowBackButton = DBChromeButton(@"", 20);
  _flowBackButton.accessibilityIdentifier = @"flow_back";
  _flowBackButton.hidden = YES;
  [_flowBackButton addTarget:self action:@selector(onFlowBack)
            forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_flowBackButton];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  if (event.type == UIEventTypeTouches) _flowLastInput = DBCallMonotonicTime();
  return [super hitTest:point withEvent:event];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
  _flowLastInput = DBCallMonotonicTime();
  if (scrollView == _flowOptionScroll) [self updateFlowFade];
}

- (void)updateFlowFade {
  BOOL more = _flowOptionScroll.contentSize.height - _flowOptionScroll.contentOffset.y >
      _flowOptionScroll.bounds.size.height + 4;
  _flowFade.hidden = !(more && !_flowOptionScroll.hidden);
}

// Every path the document references, so the decoded cache keeps only what a page can show.
- (NSSet *)flowImagePathsInDocument:(NSDictionary *)document {
  NSMutableSet *paths = [NSMutableSet set];
  id steps = [document objectForKey:@"steps"];
  if (![steps isKindOfClass:[NSDictionary class]]) return paths;
  for (id step in [(NSDictionary *)steps allValues]) {
    id images = [step isKindOfClass:[NSDictionary class]] ? [step objectForKey:@"images"] : nil;
    if (![images isKindOfClass:[NSArray class]]) continue;
    for (id image in (NSArray *)images) {
      id path = [image isKindOfClass:[NSDictionary class]] ? [image objectForKey:@"path"] : nil;
      if ([path isKindOfClass:[NSString class]] && [path length] > 0) [paths addObject:path];
    }
  }
  return paths;
}

- (void)applyFlowDocument:(NSDictionary *)document {
  // A Core that is slow or older than the flow leaves what is on screen alone.
  if (![document isKindOfClass:[NSDictionary class]]) return;
  // A debug screen on an indoor panel shows a borrowed document and keeps it.
  if (_flowDebugHold && ![_boot.role isEqualToString:@"door_station"]) return;
  NSString *revision = [document objectForKey:@"revision"];
  if (![revision isKindOfClass:[NSString class]]) revision = @"";
  if (_flow == nil) {
    _flow = [[DBVisitorFlowModel alloc] initWithFlow:document lang:_visitorLang];
  } else if ([revision length] > 0 && [revision isEqualToString:_flowRevision ?: @""]) {
    // The same document: a refresh for another reason must not rebuild the page.
    return;
  } else {
    _flow.lang = _visitorLang;
    [_flow applyEvent:@{ @"flow_changed" : document }];
  }
  _flowRevision = [revision copy];
  NSSet *live = [self flowImagePathsInDocument:document];
  for (NSString *path in [_flowImageCache allKeys])
    if (![live containsObject:path]) [_flowImageCache removeObjectForKey:path];
  [self flowStateChanged];
}

// Core announced a changed document; several events in a row cost one read.
- (void)handleFlowChanged:(NSDictionary *)event {
  (void)event;
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refreshFlow)
                                             object:nil];
  [self performSelector:@selector(refreshFlow) withObject:nil afterDelay:0.15];
}

- (void)refreshFlow {
  if (![DBCoreBridge supportsVisitorFlow]) return;
  NSInteger generation = ++_flowGeneration;
  DBCoreBridge *core = _core;
  NSUInteger coreGeneration = core.lifecycleGeneration;
  __weak DBDoorScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *document = [core visitorFlowJson:@""];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBDoorScreen *screen = weakSelf;
      if (!screen || generation != screen->_flowGeneration ||
          coreGeneration != core.lifecycleGeneration) return;
      [screen applyFlowDocument:document];
    });
  });
}

- (void)flowStateChanged {
  [self renderFlow];
  [self applyFlowVisibility];
  [self setNeedsLayout];
}

- (NSArray *)flowDisplayOptions {
  if ([_flow.mode isEqualToString:DBVisitorFlowModeEnd])
    return @[ @{ @"id" : @"__done", @"semantic_id" : @"call.primary",
                 @"label" : [_texts ts:@"flow.done"], @"icon" : @"", @"style" : @"primary",
                 @"to" : @"", @"purpose" : @"" } ];
  return [_flow currentOptions];
}

- (void)renderFlow {
  if (![self flowActive]) {
    _flowHasContent = NO;
    return;
  }
  NSString *page = [_flow currentStepID];
  NSString *mode = _flow.mode;
  BOOL changed = ![page ?: @"" isEqualToString:_flowRenderedPage ?: @""] ||
      ![mode isEqualToString:_flowRenderedMode ?: @""];
  if (changed) {
    _flowLastInput = DBCallMonotonicTime();
    if ([mode isEqualToString:DBVisitorFlowModeEnd]) _flowEndSince = _flowLastInput;
  }
  _flowRenderedPage = [page copy];
  _flowRenderedMode = [mode copy];
  if (![self flowShowing]) return;

  NSDictionary *step = [_flow currentStep];
  NSString *title = [_flow text:[step objectForKey:@"title"]];
  NSString *body = [_flow text:[step objectForKey:@"body"]];
  NSString *notice = [_flow.notice length] > 0 ? [_texts ts:_flow.notice] : nil;
  _flowTitle.text = title ?: @"";
  _flowBody.text = body ?: @"";
  _flowNotice.text = notice ?: @"";
  _flowTitle.hidden = [title length] == 0;
  _flowBody.hidden = [body length] == 0;
  _flowNotice.hidden = [notice length] == 0;
  [self renderFlowImages:[step objectForKey:@"images"]];
  _flowHasContent = [title length] > 0 || [body length] > 0 || [notice length] > 0 ||
      [_flowImageViews count] > 0;
  [self rebuildFlowOptions];
  if (changed) {
    _flowScroll.contentOffset = CGPointZero;
    _flowOptionScroll.contentOffset = CGPointZero;
    if (self.window != nil && UIAccessibilityIsVoiceOverRunning())
      UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification,
                                      [title length] > 0 ? (id)_flowTitle : (id)_flowPlate);
  }
}

- (void)renderFlowImages:(id)raw {
  for (UIView *view in _flowImageViews) [view removeFromSuperview];
  for (UIView *view in _flowImageAlts) [view removeFromSuperview];
  [_flowImageViews removeAllObjects];
  [_flowImageAlts removeAllObjects];
  NSMutableArray *infos = [NSMutableArray array];
  NSArray *images = [raw isKindOfClass:[NSArray class]] ? raw : @[];
  for (id entry in images) {
    if (![entry isKindOfClass:[NSDictionary class]] || [infos count] >= 2) continue;
    NSDictionary *image = entry;
    id rawPath = [image objectForKey:@"path"];
    NSString *path = [rawPath isKindOfClass:[NSString class]] ? rawPath : @"";
    NSString *alt = [_flow text:[image objectForKey:@"alt"]] ?: @"";
    BOOL below = [[image objectForKey:@"place"] isEqual:@"below"];
    UIImageView *view = [[UIImageView alloc] init];
    view.contentMode = UIViewContentModeScaleAspectFit;
    view.clipsToBounds = YES;
    view.isAccessibilityElement = YES;
    view.accessibilityLabel = alt;
    view.accessibilityTraits = UIAccessibilityTraitImage;
    view.accessibilityIdentifier = @"flow_image";
    UILabel *placeholder = [self plateLabelWithFont:[UIFont systemFontOfSize:17]];
    placeholder.text = alt;
    placeholder.textAlignment = NSTextAlignmentCenter;
    placeholder.textColor = [UIColor grayColor];
    id cached = [path length] > 0 ? [_flowImageCache objectForKey:path] : nil;
    if ([cached isKindOfClass:[UIImage class]]) {
      view.image = cached;
      placeholder.hidden = YES;
    } else if ([path length] > 0 && cached == nil) {
      [self loadFlowImage:path];
    }
    [_flowScroll addSubview:view];
    [_flowScroll addSubview:placeholder];
    [_flowImageViews addObject:view];
    [_flowImageAlts addObject:placeholder];
    [infos addObject:@{ @"below" : @(below) }];
  }
  _flowImageInfos = infos;
}

// Decoded off the main thread at a capped size; a file that cannot be decoded leaves its
// description on screen and is not retried until the document changes.
- (void)loadFlowImage:(NSString *)path {
  if ([_flowImageLoading containsObject:path]) return;
  [_flowImageLoading addObject:path];
  __weak DBDoorScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
    UIImage *image = DBFlowDecodeImage(path, kFlowImageMaxPixel);
    dispatch_async(dispatch_get_main_queue(), ^{
      DBDoorScreen *screen = weakSelf;
      if (!screen) return;
      [screen->_flowImageLoading removeObject:path];
      if ([screen->_flowImageCache count] >= 6) [screen->_flowImageCache removeAllObjects];
      [screen->_flowImageCache setObject:image ?: (id)[NSNull null] forKey:path];
      [screen flowStateChanged];
    });
  });
}

- (void)rebuildFlowOptions {
  for (UIView *view in _flowOptionButtons) [view removeFromSuperview];
  for (id plate in _flowOptionPlates)
    if ([plate isKindOfClass:[UIView class]]) [(UIView *)plate removeFromSuperview];
  [_flowOptionButtons removeAllObjects];
  [_flowOptionPlates removeAllObjects];
  NSArray *options = [self flowDisplayOptions];
  _flowOptionModels = options;
  NSDictionary *purposeStyle = [self styleForSemanticID:@"purpose.button"];
  _flowFilled = DBDoorStyleNeedsFill(purposeStyle);
  UIColor *ink = DBDoorStyleColor(purposeStyle, @"foreground", [UIColor blackColor]);
  BOOL seenPrimary = NO;
  for (NSUInteger i = 0; i < [options count]; i++) {
    NSDictionary *option = [options objectAtIndex:i];
    BOOL primary = !seenPrimary && [[option objectForKey:@"style"] isEqual:@"primary"];
    if (primary) seenPrimary = YES;
    NSString *label = [option objectForKey:@"label"];
    NSString *purpose = [option objectForKey:@"purpose"];
    NSString *iconName = [purpose length] > 0 ? [DBPurposeModel iconNameForPurpose:purpose] : nil;
    NSString *glyph = [DBPurposeModel displayIconForConfiguredIcon:[option objectForKey:@"icon"]];
    NSString *title = label;
    // A glyph the administrator typed stands in for an icon this shell has no asset for.
    if (iconName == nil && [glyph length] > 0)
      title = [NSString stringWithFormat:@"%@  %@", glyph, label];
    UIButton *button;
    UIView *plate = nil;
    if (primary) {
      button = [self filledButton];
      button.titleLabel.numberOfLines = 3;
    } else {
      button = _flowFilled ? [self filledButton] : DBChromeButton(title, 22);
      button.titleLabel.numberOfLines = 2;
    }
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.adjustsFontSizeToFitWidth = NO;
    button.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
    UIImage *asset = nil;
    if (!primary && iconName != nil) {
      asset = _flowFilled ? [DBIconAsset tintedImageNamed:iconName color:ink
                                                     size:CGSizeMake(kPurposeIconSide, kPurposeIconSide)]
                          : [DBIconAsset imageNamed:iconName];
    }
    if (asset != nil) {
      UIImageView *icon = [[UIImageView alloc] initWithImage:asset];
      icon.tag = kPurposeIconTag;
      if (!_flowFilled && [asset respondsToSelector:@selector(imageWithRenderingMode:)])
        icon.image = [asset imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
      [button addSubview:icon];
      button.titleEdgeInsets = UIEdgeInsetsMake(kPurposeIconSide + 6, 0, 0, 0);
    }
    button.tag = (NSInteger)i;
    NSString *identifier = [option objectForKey:@"id"];
    button.accessibilityIdentifier = [identifier isEqualToString:@"__done"] ? @"flow_done"
        : (primary ? @"door_call" : ([purpose length] > 0
               ? [@"purpose_" stringByAppendingString:purpose]
               : [@"flow_option_" stringByAppendingString:identifier ?: @""]));
    button.accessibilityLabel = label;
    [button addTarget:self action:@selector(onFlowOption:)
        forControlEvents:UIControlEventTouchUpInside];
    if (DBChromeIsFlat() && !primary && !_flowFilled) {
      plate = DBDoorPlate();
      [_flowOptionScroll addSubview:plate];
    }
    [_flowOptionScroll addSubview:button];
    [_flowOptionButtons addObject:button];
    [_flowOptionPlates addObject:(plate ?: (id)[NSNull null])];
  }
  [self applyFlowStyles];
}

// The primary option wears the Call button's look; the rest are the stock purpose buttons.
- (void)applyFlowStyles {
  if (![self flowActive]) return;
  NSDictionary *purposeStyle = [self styleForSemanticID:@"purpose.button"];
  if (DBDoorStyleNeedsFill(purposeStyle) != _flowFilled && [self flowShowing]) {
    [self renderFlow];
    [self setNeedsLayout];
    return;
  }
  NSDictionary *callStyle = [self styleForSemanticID:@"call.primary"];
  UIColor *white = [UIColor whiteColor];
  UIColor *green = [UIColor colorWithRed:0.094 green:0.478 blue:0.235 alpha:1];
  BOOL seenPrimary = NO;
  for (NSUInteger i = 0; i < [_flowOptionButtons count] && i < [_flowOptionModels count]; i++) {
    UIButton *button = [_flowOptionButtons objectAtIndex:i];
    BOOL primary = !seenPrimary &&
        [[[_flowOptionModels objectAtIndex:i] objectForKey:@"style"] isEqual:@"primary"];
    if (primary) {
      seenPrimary = YES;
      DBApplyDoorButtonStyle(button, callStyle, white, green, 10);
      if (_palette != nil && [callStyle objectForKey:@"background"] == nil) {
        button.backgroundColor = _palette.accent;
        [button setTitleColor:_palette.accentInk forState:UIControlStateNormal];
      }
    } else if (_flowFilled) {
      DBApplyDoorButtonStyle(button, purposeStyle, [UIColor blackColor], white, 10);
    }
  }
}

#pragma mark - visitor flow input

- (void)onFlowBack {
  if (![self flowShowing]) return;
  [_flow applyEvent:@{ @"back" : @YES }];
  _flowLastInput = DBCallMonotonicTime();
  [self flowStateChanged];
}

- (void)onFlowOption:(UIButton *)sender {
  if (_flowBusy || ![self flowShowing]) return;
  if (sender.tag < 0 || sender.tag >= (NSInteger)[_flowOptionModels count]) return;
  NSString *optionID = [[_flowOptionModels objectAtIndex:(NSUInteger)sender.tag]
      objectForKey:@"id"];
  _flowLastInput = DBCallMonotonicTime();
  if ([_flow.mode isEqualToString:DBVisitorFlowModeEnd]) {
    [_flow applyEvent:@{ @"done" : @YES }];
    [self flowStateChanged];
    return;
  }
  NSDictionary *plan = [_flow planForTap:optionID];
  if (plan == nil) return;
  if ([[plan objectForKey:@"action"] isEqualToString:@"notify"]) {
    // Core's loop answers; the visitor sees the next page whatever it says, and a failure rings.
    _flowBusy = YES;
    NSString *stepID = [plan objectForKey:@"step"];
    NSString *door = _boot.door ?: @"";
    DBCoreBridge *core = _core;
    __weak DBDoorScreen *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      NSDictionary *result = [core visitorNotify:door step:stepID];
      dispatch_async(dispatch_get_main_queue(), ^{
        DBDoorScreen *screen = weakSelf;
        if (!screen) return;
        screen->_flowBusy = NO;
        NSArray *calls = [screen->_flow applyEvent:@{
            @"tap" : optionID, @"notify_result" : result ?: @{ @"ok" : @NO } }];
        [screen flowPerformCalls:calls];
        [screen flowStateChanged];
      });
    });
    return;
  }
  NSArray *calls = [_flow applyEvent:@{ @"tap" : optionID }];
  [self flowPerformCalls:calls];
  [self flowStateChanged];
}

// The notify call is already made; every press goes through the existing call path.
- (void)flowPerformCalls:(NSArray *)calls {
  for (NSDictionary *call in calls) {
    NSString *purpose = [call objectForKey:@"press"];
    if (purpose == nil) continue;
    if (![self beginCallWithPurpose:purpose]) {
      [_flow applyEvent:@{ @"press_failed" : @YES }];
      continue;
    }
    NSString *title = nil;
    if ([purpose length] > 0) {
      NSDictionary *entry = [DBConfigUtil dig:_cfg
          path:[NSString stringWithFormat:@"visit_purposes.%@", purpose]];
      title = [_texts t:@"purpose.sent",
               [DBConfigUtil labelOf:entry lang:_visitorLang fallback:purpose], nil];
    }
    [self showCallingWithTitle:title];
  }
}

- (void)flowCallEnded {
  NSString *reason = _endReason ?: @"ended";
  _endReason = nil;
  if (![self flowActive]) return;
  if ([_flow.mode isEqualToString:DBVisitorFlowModeCalling])
    [_flow applyEvent:@{ @"call_ended" : reason }];
  else
    // A call this screen did not start (a replicated press): the visitor lands on the start page.
    [_flow applyEvent:@{ @"idle_timeout" : @YES }];
  _flowRenderedMode = nil;
}

// Once a second: the idle return on a page and the automatic return from an end page.
- (void)flowTick {
  if (![self flowShowing] || _flowDebugHold || _replyShown) return;
  NSTimeInterval now = DBCallMonotonicTime();
  if ([_flow.mode isEqualToString:DBVisitorFlowModeEnd]) {
    if (now - _flowEndSince < [_flow returnSeconds]) return;
    [_flow applyEvent:@{ @"end_timeout" : @YES }];
  } else {
    BOOL needed = [_flow canGoBack] || [_flow.notice length] > 0;
    if (!needed || now - _flowLastInput < [_flow idleSeconds]) return;
    [_flow applyEvent:@{ @"idle_timeout" : @YES }];
  }
  [self flowStateChanged];
}

// A small resolved document in the contract's shape, for debug start screens on a panel that has
// no flow of its own.
- (NSDictionary *)debugSampleFlow {
  NSDictionary *(^text)(NSString *, NSString *, NSString *) =
      ^NSDictionary *(NSString *ja, NSString *en, NSString *zh) {
    return @{ @"ja" : ja, @"en" : en, @"zh" : zh };
  };
  return @{
    @"schema_version" : @1, @"enabled" : @YES, @"source" : @"default", @"revision" : @"debug",
    @"start" : @"s_home", @"idle_s" : @45, @"require_call" : @YES, @"issues" : @[],
    @"steps" : @{
      @"s_home" : @{ @"kind" : @"page", @"images" : @[],
        @"title" : text(@"ご用件をお選びください", @"How can we help?", @"请选择来访目的"),
        @"options" : @[
          @{ @"id" : @"o_call", @"semantic_id" : @"call.primary", @"style" : @"primary", @"icon" : @"",
             @"label" : text(@"呼び出す", @"Call", @"呼叫"), @"to" : @"c_any" },
          @{ @"id" : @"o_visit", @"semantic_id" : @"purpose.button", @"style" : @"normal",
             @"purpose" : @"p_visit", @"icon" : @"",
             @"label" : text(@"訪問", @"Visit", @"访客"), @"to" : @"c_visit" },
          @{ @"id" : @"o_delivery", @"semantic_id" : @"purpose.button", @"style" : @"normal",
             @"purpose" : @"p_delivery", @"icon" : @"",
             @"label" : text(@"宅配便", @"Delivery", @"快递"), @"to" : @"s_parcel" } ] },
      @"s_parcel" : @{ @"kind" : @"page", @"images" : @[],
        @"title" : text(@"置き配できますか？", @"Can you leave it at the door?", @"可以放在门口吗？"),
        @"body" : text(@"サイン不要のお荷物は玄関前に置いてください。",
                        @"If no signature is needed, please leave the parcel by the door.",
                        @"无需签收的包裹请放在门口。"),
        @"options" : @[
          @{ @"id" : @"o_leave", @"semantic_id" : @"call.primary", @"style" : @"primary", @"icon" : @"",
             @"label" : text(@"置き配する", @"Leave it", @"放在门口"), @"to" : @"e_thanks" },
          @{ @"id" : @"o_hand", @"semantic_id" : @"purpose.button", @"style" : @"normal", @"icon" : @"",
             @"label" : text(@"手渡し・サイン必要", @"Hand over / signature", @"需当面签收"),
             @"to" : @"c_visit" } ] },
      @"c_any" : @{ @"kind" : @"call" },
      @"c_visit" : @{ @"kind" : @"call", @"purpose" : @"p_visit" },
      @"e_thanks" : @{ @"kind" : @"end", @"images" : @[], @"return_s" : @8,
        @"title" : text(@"ありがとうございました", @"Thank you", @"谢谢") },
    },
  };
}

// Debug start screens "visitor:flow" and "visitor:flow:<step id>". The document may still be on
// its way from Core, so the request waits for it.
- (void)debugShowFlowStep:(NSString *)step attempt:(int)attempt {
  NSString *target = [step hasPrefix:@":"] ? [step substringFromIndex:1] : step;
  if (![self flowActive] && ![_boot.role isEqualToString:@"door_station"] && attempt == 0) {
    // An indoor panel has no door of its own: borrow the document of the first door station
    // whose shell renders the flow.
    NSMutableArray *doors = [NSMutableArray array];
    NSDictionary *devices = [DBConfigUtil dig:_cfg path:@"devices"];
    if ([devices isKindOfClass:[NSDictionary class]])
      for (NSString *key in [[devices allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *entry = [devices objectForKey:key];
        id door = [entry isKindOfClass:[NSDictionary class]] ? [entry objectForKey:@"door"] : nil;
        if ([[entry objectForKey:@"role"] isEqual:@"door_station"] &&
            [door isKindOfClass:[NSString class]] && [door length] > 0) [doors addObject:door];
      }
    DBCoreBridge *core = _core;
    __weak DBDoorScreen *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      NSDictionary *document = nil;
      for (NSString *door in doors) {
        document = [core visitorFlowJson:door];
        if ([[document objectForKey:@"enabled"] boolValue]) break;
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        // Without a door station that renders the flow, the panel shows a sample document.
        [weakSelf applyFlowDocument:[[document objectForKey:@"enabled"] boolValue]
            ? document : [weakSelf debugSampleFlow]];
        [weakSelf debugShowFlowStep:step attempt:1];
      });
    });
    return;
  }
  if (![self flowActive]) {
    if (attempt < 8) {
      __weak DBDoorScreen *weakSelf = self;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        [weakSelf debugShowFlowStep:step attempt:attempt + 1];
      });
    }
    return;
  }
  if ([target length] == 0) target = [_flow.flow objectForKey:@"start"];
  _flowDebugHold = YES;
  if ([_flow jumpToStep:target]) [self flowStateChanged];
}

// The flow zone: the page card above the fixed option zone, Back in the bottom row.
- (void)layoutFlowWithLayout:(DBDoorVisitorLayout)layout {
  if (![self flowActive]) return;
  BOOL compact = layout.compact;
  CGFloat gap = layout.gap;
  NSArray *models = _flowOptionModels ?: @[];
  NSMutableArray *secondary = [NSMutableArray array];
  NSInteger primaryIndex = -1;
  for (NSUInteger i = 0; i < [models count]; i++) {
    if (primaryIndex < 0 && [[[models objectAtIndex:i] objectForKey:@"style"] isEqual:@"primary"])
      primaryIndex = (NSInteger)i;
    else [secondary addObject:[NSNumber numberWithUnsignedInteger:i]];
  }
  BOOL hasPrimary = primaryIndex >= 0;
  NSInteger count = (NSInteger)[secondary count];

  CGFloat header = 0;
  if (!_pairBanner.hidden) header += compact ? 44 : 56;
  if (!_mediaBadge.hidden) header += (header > 0 ? gap : 0) + 40;
  DBDoorVisitorFlowLayout probe = DBDoorVisitorFlowLayoutMake(layout, 0, hasPrimary, count, 0, YES);
  CGFloat cellWidth = DBDoorVisitorFlowOptionFrame(probe, hasPrimary, 0, MAX(1, count)).size.width;
  NSDictionary *purposeStyle = [self styleForSemanticID:@"purpose.button"];
  CGFloat fontSize = (compact ? 18 : 22) *
      DBDoorStyleNumber(purposeStyle, @"font_scale", 1, 0.75, 2);
  UIFont *font = DBDoorFont(fontSize, _flowFilled || !DBChromeIsFlat());
  CGFloat rowText = 0;
  for (NSNumber *index in secondary) {
    UIButton *button = [_flowOptionButtons objectAtIndex:[index unsignedIntegerValue]];
    CGSize text = [button.currentTitle sizeWithFont:font
        constrainedToSize:CGSizeMake(MAX(44, cellWidth - 16), 1000)
        lineBreakMode:NSLineBreakByWordWrapping];
    rowText = MAX(rowText, MIN(text.height, font.lineHeight * 2) + 24 +
                  ([button viewWithTag:kPurposeIconTag] != nil ? kPurposeIconSide + 6 : 0));
  }
  DBDoorVisitorFlowLayout flow =
      DBDoorVisitorFlowLayoutMake(layout, header, hasPrimary, count, rowText, YES);

  // The pairing reminder and the diagnostics line keep their place above the page.
  _purposeScroll.frame = CGRectMake(flow.columnX, probe.zone.origin.y, flow.columnWidth, header);
  CGFloat pairHeight = _pairBanner.hidden ? 0 : (compact ? 44 : 56);
  _pairBanner.frame = CGRectMake(0, 0, flow.columnWidth, pairHeight);
  _pairPlate.frame = _pairBanner.frame;
  _mediaBadge.frame = CGRectMake(0, pairHeight > 0 ? pairHeight + gap : 0, flow.columnWidth,
                                 _mediaBadge.hidden ? 0 : 40);
  _purposeScroll.contentSize = CGSizeMake(flow.columnWidth, header);

  // Options: fixed above the bottom row; they scroll inside their own viewport when they exceed
  // half of the screen.
  _flowOptionScroll.frame = flow.options;
  _flowOptionScroll.contentSize = CGSizeMake(flow.columnWidth, flow.optionsContentHeight);
  for (NSUInteger i = 0; i < [_flowOptionButtons count] && i < [models count]; i++) {
    UIButton *button = [_flowOptionButtons objectAtIndex:i];
    if ((NSInteger)i == primaryIndex) {
      CGRect frame = DBDoorVisitorFlowPrimaryFrame(flow);
      button.frame = frame;
      NSDictionary *callStyle = [self styleForSemanticID:@"call.primary"];
      NSString *kind = [_flow kindOfStep:[[models objectAtIndex:i] objectForKey:@"to"]];
      BOOL bell = [kind isEqualToString:@"call"];
      CGFloat bellSide = compact ? 28 : 40;
      if (bell) {
        UIColor *callInk = [button titleColorForState:UIControlStateNormal] ?: [UIColor blackColor];
        [button setImage:[DBIconAsset tintedImageNamed:@"f7:bell_fill" color:callInk
                                                   size:CGSizeMake(bellSide, bellSide)]
                forState:UIControlStateNormal];
        button.titleEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 0);
      } else {
        [button setImage:nil forState:UIControlStateNormal];
        button.titleEdgeInsets = UIEdgeInsetsZero;
      }
      CGSize room = CGSizeMake(frame.size.width - 24 - (bell ? bellSide + 12 : 0),
                               frame.size.height - 16);
      button.titleLabel.font = DBDoorFittingFont(button.currentTitle ?: @"",
          (compact ? 24 : 40) * DBDoorStyleNumber(callStyle, @"font_scale", 1, 0.75, 2),
          16, YES, room);
      continue;
    }
    NSInteger slot = (NSInteger)[secondary indexOfObject:[NSNumber numberWithUnsignedInteger:i]];
    CGRect frame = DBDoorVisitorFlowOptionFrame(flow, hasPrimary, slot, count);
    button.frame = frame;
    button.titleLabel.font = font;
    UIView *icon = [button viewWithTag:kPurposeIconTag];
    if (icon != nil) {
      CGSize text = [button.currentTitle sizeWithFont:font
          constrainedToSize:CGSizeMake(MAX(44, frame.size.width - 16), 1000)
          lineBreakMode:NSLineBreakByWordWrapping];
      CGFloat block = kPurposeIconSide + 6 + MIN(text.height, font.lineHeight * 2);
      icon.frame = CGRectMake(floor((frame.size.width - kPurposeIconSide) / 2),
                              floor((frame.size.height - block) / 2), kPurposeIconSide,
                              kPurposeIconSide);
    }
    id plate = [_flowOptionPlates objectAtIndex:i];
    if ([plate isKindOfClass:[UIView class]]) [(UIView *)plate setFrame:frame];
  }
  _flowFade.frame = CGRectMake(flow.options.origin.x, CGRectGetMaxY(flow.options) - 28,
                               flow.columnWidth, 28);
  [(CALayer *)[_flowFade.layer.sublayers firstObject] setFrame:_flowFade.bounds];
  [self updateFlowFade];

  _flowBackButton.frame = flow.back;
  _flowBackPlate.frame = flow.back;
  _flowBackPlate.layer.cornerRadius = 10;

  // The page card: notice, title, images above, text, images below. It scrolls when it is taller
  // than the room above the options, and sits centred in that room otherwise.
  CGRect room = flow.content;
  CGFloat pad = compact ? 12 : 20;
  CGFloat inner = MAX(0, room.size.width - pad * 2);
  CGFloat spacing = compact ? 8 : 14;
  CGFloat y = pad;
  _flowNotice.font = [UIFont boldSystemFontOfSize:compact ? 17 : 22];
  _flowTitle.font = [UIFont boldSystemFontOfSize:compact ? 26 : 36];
  _flowBody.font = [UIFont systemFontOfSize:compact ? 19 : 26];
  UILabel *labels[2] = { _flowNotice, _flowTitle };
  for (int i = 0; i < 2; i++) {
    UILabel *label = labels[i];
    if (label.hidden) continue;
    CGFloat height = ceil([label.text sizeWithFont:label.font
        constrainedToSize:CGSizeMake(inner, 100000)
        lineBreakMode:NSLineBreakByWordWrapping].height);
    label.frame = CGRectMake(pad, y, inner, height);
    y += height + spacing;
  }
  for (int pass = 0; pass < 2; pass++) {
    if (pass == 1 && !_flowBody.hidden) {
      CGFloat height = ceil([_flowBody.text sizeWithFont:_flowBody.font
          constrainedToSize:CGSizeMake(inner, 100000)
          lineBreakMode:NSLineBreakByWordWrapping].height);
      _flowBody.frame = CGRectMake(pad, y, inner, height);
      y += height + spacing;
    }
    for (NSUInteger i = 0; i < [_flowImageViews count] && i < [_flowImageInfos count]; i++) {
      BOOL below = [[[_flowImageInfos objectAtIndex:i] objectForKey:@"below"] boolValue];
      if (below != (pass == 1)) continue;
      UIImageView *view = [_flowImageViews objectAtIndex:i];
      UILabel *alt = [_flowImageAlts objectAtIndex:i];
      CGFloat height;
      CGFloat width = inner;
      if (view.image != nil) {
        height = DBDoorVisitorFlowImageHeight(view.image.size, inner, layout.size.height);
        width = MIN(inner, height * view.image.size.width / MAX(1, view.image.size.height));
      } else {
        height = [alt.text length] > 0
            ? ceil([alt.text sizeWithFont:alt.font constrainedToSize:CGSizeMake(inner, 1000)
                            lineBreakMode:NSLineBreakByWordWrapping].height) + 24
            : 0;
      }
      view.frame = CGRectMake(pad + floor((inner - width) / 2), y, width, view.image ? height : 0);
      alt.frame = CGRectMake(pad, y, inner, view.image ? 0 : height);
      y += height + spacing;
    }
  }
  CGFloat natural = MAX(0, y - spacing) + pad;
  CGFloat plateHeight = MIN(natural, room.size.height);
  _flowPlate.frame = CGRectMake(room.origin.x,
      room.origin.y + floor((room.size.height - plateHeight) / 2), room.size.width, plateHeight);
  _flowScroll.frame = _flowPlate.bounds;
  _flowScroll.contentSize = CGSizeMake(room.size.width, natural);
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
  DBDoorVisitorLayout layout = DBDoorVisitorLayoutMake(size, !_sosButton.hidden, actionScale);
  NSInteger languageCount = (NSInteger)[_languages count];
  layout = DBDoorVisitorLayoutFitContent(layout, languageCount >= 2, !_noticeLabel.hidden,
                                         _air.visible,
                                         [self showsHomePurposes]
                                             ? (NSInteger)[_purposeButtons count] : 0);
  BOOL compact = layout.compact;
  CGFloat margin = layout.margin;
  CGFloat gap = layout.gap;

  BOOL columnLayout = !CGRectIsEmpty(layout.title);
  _nav.bar.hidden = columnLayout;
  _nav.bar.frame = layout.topBar;
  _titleLabel.hidden = !columnLayout;
  _titleLabel.frame = layout.title;
  _titleLabel.font = [UIFont boldSystemFontOfSize:compact ? 22 : 28];
  _infoButton.frame = CGRectMake(size.width - 64, 0, 64, 64);
  _callButton.frame = layout.action;
  _cancelButton.frame = layout.action;
  _touchHint.frame = layout.status;
  _touchHint.font = [UIFont systemFontOfSize:compact ? 17 : 24];
  _versionLabel.font = [UIFont systemFontOfSize:12];
  _versionLabel.frame = layout.version;
  _sosButton.frame = layout.sos;

  // Segments while each stays wide enough to hit and read; one button that opens a sheet
  // once more languages are enabled than fit.
  _languageUsesSheet =
      layout.language.size.width < kLanguageSegmentMinimum * (CGFloat)languageCount;
  _languageControl.frame = layout.language;
  _languageButton.frame = layout.language;
  _languagePlate.frame = layout.language;
  // The ground follows the outline of what it sits under: a flat segmented control rounds its
  // corners by about 4 pt, the sheet button by the chrome's 10 pt.
  _languagePlate.layer.cornerRadius = _languageUsesSheet ? 10 : 4;
  [self applyFlowVisibility];

  _clockLabel.font = [UIFont boldSystemFontOfSize:18];
  _clockLabel.textAlignment = NSTextAlignmentCenter;
  _clockLabel.frame = layout.clock;
  _dateLabel.font = [UIFont systemFontOfSize:12];
  _dateLabel.textAlignment = NSTextAlignmentCenter;
  // One subtle band seats the door name and the time over any wallpaper.
  CGRect band = CGRectIsEmpty(layout.clock)
      ? layout.title : CGRectUnion(layout.title, CGRectUnion(layout.clock, layout.date));
  _timeScrim.frame = CGRectIsEmpty(layout.title) ? CGRectZero : CGRectInset(band, -10, -2);
  _timeScrim.hidden = CGRectIsEmpty(layout.title);
  _dateLabel.frame = layout.date;
  [_air layoutInFrame:layout.air fontSize:compact ? 14 : 16 centered:NO];
  [self applyFlowVisibility];

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

  _replyPlate.frame = self.bounds;
  // Two caption lines sit below the text box: the exit hint centred, the countdown trailing.
  CGFloat caption = 20;
  CGRect replyBox = CGRectInset(_replyPlate.bounds, layout.margin, layout.margin);
  replyBox.size.height = MAX(0, replyBox.size.height - caption - 4);
  _replyScroll.frame = replyBox;
  CGFloat captionY = _replyPlate.bounds.size.height - layout.margin - caption;
  CGFloat captionWidth = _replyPlate.bounds.size.width - layout.margin * 2;
  _replyCountdown.frame = CGRectMake(layout.margin + captionWidth - 56, captionY, 56, caption);
  _replyHint.frame = CGRectMake(layout.margin + 60, captionY, MAX(0, captionWidth - 120), caption);
  [self fitReplyTextInBox:_replyScroll.frame.size];

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
    CGSize textSize = [button.currentTitle sizeWithFont:purposeFont
        constrainedToSize:CGSizeMake(MAX(44, cellWidth - 16), 1000)
        lineBreakMode:NSLineBreakByWordWrapping];
    rowHeight = MAX(rowHeight, MIN(textSize.height, purposeFont.lineHeight * 2) + 24 +
                    ([button viewWithTag:kPurposeIconTag] != nil ? kPurposeIconSide + 6 : 0));
  }
  for (NSInteger i = 0; i < purposeCount; i++) {
    UIButton *button = [_purposeButtons objectAtIndex:(NSUInteger)i];
    CGRect frame = CGRectOffset(DBDoorVisitorPurposeFrame(layout, i, rowHeight), 0, y);
    button.frame = frame;
    button.hidden = !showsPurposes;
    UIView *icon = [button viewWithTag:kPurposeIconTag];
    if (icon != nil) {
      CGSize text = [button.currentTitle sizeWithFont:purposeFont
          constrainedToSize:CGSizeMake(MAX(44, frame.size.width - 16), 1000)
          lineBreakMode:NSLineBreakByWordWrapping];
      CGFloat block = kPurposeIconSide + 6 + MIN(text.height, purposeFont.lineHeight * 2);
      icon.frame = CGRectMake(floor((frame.size.width - kPurposeIconSide) / 2),
                              floor((frame.size.height - block) / 2), kPurposeIconSide,
                              kPurposeIconSide);
    }
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
  CGSize actionText = CGSizeMake(layout.action.size.width - 24 - (compact ? 40 : 52),
                                 layout.action.size.height - 16);
  _callButton.titleLabel.font = DBDoorFittingFont(_callButton.currentTitle ?: @"",
      (compact ? 24 : 40) * DBDoorStyleNumber(callStyle, @"font_scale", 1, 0.75, 2),
      16, YES, actionText);
  // The bell leads the call label, in the ink of the button's own title.
  CGFloat bell = compact ? 28 : 40;
  UIColor *callInk = [_callButton titleColorForState:UIControlStateNormal] ?: [UIColor blackColor];
  [_callButton setImage:[DBIconAsset tintedImageNamed:@"f7:bell_fill" color:callInk
                                                  size:CGSizeMake(bell, bell)]
               forState:UIControlStateNormal];
  _callButton.titleEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 0);
  _cancelButton.titleLabel.font = DBDoorFittingFont(_cancelButton.currentTitle ?: @"",
      (compact ? 24 : 40) * DBDoorStyleNumber(activeCancelStyle, @"font_scale", 1, 0.75, 2),
      16, YES, actionText);

  // Calling and connected: one status plate in the content zone, above the same action
  // rectangle that now holds Cancel or End.
  CGFloat plateHeight = MIN(layout.content.size.height, compact ? 140 : 240);
  _callPlate.frame = CGRectMake(layout.content.origin.x,
      CGRectGetMaxY(layout.content) - plateHeight, layout.content.size.width, plateHeight);
  CGSize spinnerSize = _callSpinner.bounds.size;
  _callSpinner.center = CGPointMake(floor(_callPlate.bounds.size.width / 2),
                                    12 + floor(spinnerSize.height / 2));
  CGFloat statusTop = 12 + spinnerSize.height + 8;
  CGRect statusFrame = CGRectMake(12, statusTop, MAX(0, _callPlate.bounds.size.width - 24),
                                  MAX(0, plateHeight - statusTop - 12));
  _callingLabel.frame = statusFrame;
  _callingLabel.font = DBDoorFittingFont(_callingLabel.text ?: @"", compact ? 24 : 40, 14, YES,
                                         statusFrame.size);

  [self layoutFlowWithLayout:layout];
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
