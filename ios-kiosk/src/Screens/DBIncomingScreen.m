#import "DBIncomingScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBBackoffPolicy.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBMediaSource.h"
#import "../Core/DBSemanticStyle.h"
#import "../Core/DBTexts.h"
#import "../Media/DBH264Player.h"
#import "../Media/DBLowLatencyH264Player.h"
#import "../Media/DBQrCode.h"
#import "../Net/DBMjpegClient.h"
#import "../Net/DBSnapshotPoller.h"
#import "../Core/DBNoticeModel.h"
#import "../Core/DBUiTheme.h"
#import "../Support/DBAppDelegate.h"
#import "DBNoticeDialog.h"
#import "DBRouter.h"
#import "DBWidgets.h"

// The debug line is remembered per device (spec §5.2).
static NSString *const kDebugLineHiddenKey = @"DBIncomingDebugLineHidden";

static const NSTimeInterval kLegacyAutoCloseS = 30;
static const NSTimeInterval kCancelledCloseS = 15;

static BOOL DBSameString(NSString *a, NSString *b) {
  return (a == b) || [a isEqualToString:b];
}

@interface DBIncomingScreen ()
- (void)startVideoStatsTimer;
- (void)updateVideoStats:(NSTimer *)timer;
- (void)publishVideoRuntime:(DBVideoStats)stats force:(BOOL)force;
- (void)autoCloseTimerFired:(NSTimer *)timer;
- (void)startVideoOrientationPolling;
- (void)pollVideoOrientation:(NSTimer *)timer;
- (void)updateAdminAddressesFromPeer:(NSDictionary *)peer;
- (void)updateAdminQr;
- (void)layoutQrPicker:(CGSize)size;
- (NSArray *)videoStrategiesFromProfile:(NSDictionary *)profile legacy:(NSString *)legacy;
- (void)advanceVideoStrategy:(NSString *)reason;
- (void)retryCurrentH264:(NSString *)reason;
- (void)startCurrentVideoStrategy;
- (void)startMjpegPrewarm;
- (void)startSnapshotFallback;
- (NSDictionary *)styleForSemanticID:(NSString *)semanticID
                            foreground:(UIColor *)foreground
                            background:(UIColor *)background
                                safety:(BOOL)safety;
- (void)applySemanticStyles;
- (void)reportLifecycleEndedIfNeeded;
@end

@implementation DBIncomingScreen {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  NSString *_door;
  NSString *_purpose;
  NSString *_visitorLang;
  NSString *_callID;
  NSInteger _stageRevision;
  long long _callExpiresAtMs;
  NSString *_nodeId;

  NSDictionary *_cfg;
  DBMjpegClient *_streamer;
  DBSnapshotPoller *_snapshotPoller;
  DBH264Player *_h264;         // Preferred H.264 fMP4 player when available.
  DBLowLatencyH264Player *_lowLatency;
  NSString *_videoPlayback;    // low_latency (default) | hls | mjpeg
  NSArray *_videoStrategies;   // Effective Core strategies in priority order.
  // As delivered by Core, before startVideo: reorders H.264 ahead of the
  // availability layer. Comparing the reordered list against a fresh snapshot
  // would report a media change on every poll and restart a healthy pipeline.
  NSArray *_videoStrategiesSource;
  NSInteger _videoStrategyIndex;
  NSInteger _videoSessionGen;
  NSInteger _videoAttemptGen;
  NSString *_currentVideoStrategy;
  DBBackoffPolicy *_h264Backoff;  // Spaces out restarts against a dead HTTP endpoint.
  BOOL _videoStrategyPlaying;
  BOOL _mjpegAvailabilityDisabled;  // Profile turned the MJPEG layer off.
  UIImage *_pendingMjpegFrame;
  NSString *_incomingStreamUrl;
  NSString *_incomingStreamMp4Url;
  NSString *_videoMetaUrl;
  DBMediaSource *_mediaSource;
  NSString *_peerHost;
  NSInteger _directPort;
  NSString *_sipMode;  // "" | "monitor" | "answer"
  NSInteger _sipActionGen;  // Invalidates delayed answer work after navigation.
  BOOL _monitorOnly;         // Active monitoring selected from the idle screen.
  NSString *_selectedPeerId;
  NSString *_selectedPeerName;
  BOOL _inCall;
  BOOL _answerPending;
  BOOL _awaitingSupersededIdle;
  BOOL _lifecycleAnswered;
  BOOL _lifecycleEnded;
  BOOL _safeMode;
  BOOL _cancelled;
  NSTimer *_autoCloseTimer;
  BOOL _autoCloseTimerForCancelled;
  long long _autoCloseDeadlineMs;
  NSTimer *_videoStatsTimer;
  CFAbsoluteTime _lastMediaRuntimePublishAt;
  NSString *_lastMediaRuntimeSignature;
  NSTimer *_videoOrientationTimer;
  BOOL _videoOrientationBusy;
  NSInteger _videoRotation;
  NSInteger _snapshotGen;  // Discards stale background snapshots.
  NSString *_activeVideoTransport;
  NSArray *_adminHosts;
  NSInteger _adminHostIndex;
  NSInteger _adminQrGen;

  // UI
  UIImageView *_liveView;
  UILabel *_noVideoLabel;
  UILabel *_videoStatsLabel;
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
  UIButton *_micButton;
  UIButton *_repliesButton;
  DBNoticeChip *_noticeChip;
  DBNoticeDialog *_noticeDialog;
  DBUiPalette *_palette;
  NSDictionary *_display;   // status.display: core-resolved appearance and theme.
  NSDictionary *_doorUnlock;  // status.doors.<id>.unlock
  BOOL _monitorAudioOn;
  BOOL _micMuted;
  BOOL _repliesVisible;
  BOOL _debugLineHidden;
  BOOL _unlockConfigured;
  BOOL _unlockVisible;
  UIButton *_debugLineTap;
  UIButton *_adminQrButton;
  UILabel *_adminUrlLabel;
  UIView *_qrPickerOverlay;
  UIButton *_qrPickerBackdrop;
  UIView *_qrPickerPanel;
  UILabel *_qrPickerTitle;
  UIScrollView *_qrPickerList;
  UIButton *_qrPickerCancel;
  NSMutableArray *_qrPickerButtons;
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _router = router;
    _h264Backoff = [[DBBackoffPolicy alloc] init];
    _core = router.core;
    _boot = router.boot;
    _texts = router.texts;
    _door = @"";
    _purpose = @"";
    _visitorLang = @"";
    _incomingStreamUrl = @"";
    _incomingStreamMp4Url = @"";
    _videoMetaUrl = @"";
    _sipMode = @"";
    _videoPlayback = @"low_latency";
    _activeVideoTransport = @"NO STREAM";
    _directPort = 47190;
    _replyButtons = [[NSMutableArray alloc] init];
    _adminHosts = @[];
    _qrPickerButtons = [[NSMutableArray alloc] init];
    _debugLineHidden = [[NSUserDefaults standardUserDefaults] boolForKey:kDebugLineHiddenKey];
    [self buildUi];
  }
  return self;
}

- (NSString *)screenName {
  return @"incoming";
}

#pragma mark - UI

- (UIButton *)makeButton:(BOOL)primary {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
  b.titleLabel.font = [UIFont boldSystemFontOfSize:22];
  b.titleLabel.adjustsFontSizeToFitWidth = YES;
  b.titleLabel.minimumFontSize = 13;
  [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  b.backgroundColor = primary ? [UIColor colorWithRed:0.094 green:0.478 blue:0.235 alpha:1]
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

  _videoStatsLabel = [[UILabel alloc] init];
  _videoStatsLabel.font = [UIFont fontWithName:@"Menlo-Bold" size:15];
  if (!_videoStatsLabel.font) _videoStatsLabel.font = [UIFont boldSystemFontOfSize:15];
  _videoStatsLabel.textColor = [UIColor colorWithRed:0.55 green:1.0 blue:0.65 alpha:1];
  _videoStatsLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
  _videoStatsLabel.layer.cornerRadius = 6;
  _videoStatsLabel.clipsToBounds = YES;
  _videoStatsLabel.adjustsFontSizeToFitWidth = YES;
  _videoStatsLabel.minimumFontSize = 11;
  _videoStatsLabel.numberOfLines = 1;
  _videoStatsLabel.accessibilityIdentifier = @"video_stream_stats";
  [self addSubview:_videoStatsLabel];

  _titleLabel = [[UILabel alloc] init];
  _titleLabel.font = [UIFont boldSystemFontOfSize:30];
  _titleLabel.textColor = [UIColor whiteColor];
  _titleLabel.numberOfLines = 0;
  _titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
  _titleLabel.adjustsFontSizeToFitWidth = YES;
  _titleLabel.minimumFontSize = 15;
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

  // One control row (spec §5.1): モニター ON/OFF · 応答/通話終了 · マイク · 開錠 ·
  // クイック返信. Every entry shows its own state instead of a silent toggle.
  _micButton = [self makeButton:NO];
  [_micButton addTarget:self action:@selector(onMic)
       forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_micButton];

  _repliesButton = [self makeButton:NO];
  [_repliesButton addTarget:self action:@selector(onToggleReplies)
           forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_repliesButton];

  _noticeChip = [[DBNoticeChip alloc] initWithFrame:CGRectZero];
  [_noticeChip addTarget:self action:@selector(onNoticeChip)
        forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_noticeChip];

  // Tapping the debug line hides it; the choice is remembered per device.
  _debugLineTap = [UIButton buttonWithType:UIButtonTypeCustom];
  _debugLineTap.backgroundColor = [UIColor clearColor];
  [_debugLineTap addTarget:self action:@selector(onToggleDebugLine)
          forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_debugLineTap];

  _adminQrButton = [UIButton buttonWithType:UIButtonTypeCustom];
  _adminQrButton.backgroundColor = [UIColor whiteColor];
  _adminQrButton.layer.cornerRadius = 8;
  _adminQrButton.clipsToBounds = YES;
  _adminQrButton.imageView.contentMode = UIViewContentModeCenter;
  _adminQrButton.accessibilityIdentifier = @"admin_page_qr";
  [_adminQrButton addTarget:self action:@selector(onAdminQrTapped)
           forControlEvents:UIControlEventTouchUpInside];
  _adminQrButton.hidden = YES;
  [self addSubview:_adminQrButton];

  _adminUrlLabel = [[UILabel alloc] init];
  _adminUrlLabel.font = [UIFont systemFontOfSize:11];
  _adminUrlLabel.textColor = [UIColor colorWithWhite:1 alpha:0.72];
  _adminUrlLabel.textAlignment = NSTextAlignmentCenter;
  _adminUrlLabel.numberOfLines = 0;
  _adminUrlLabel.lineBreakMode = NSLineBreakByCharWrapping;
  _adminUrlLabel.hidden = YES;
  [self addSubview:_adminUrlLabel];

  // A custom dialog avoids fragile iOS 5 modals and exposes every peer address.
  _qrPickerOverlay = [[UIView alloc] init];
  _qrPickerOverlay.hidden = YES;
  _qrPickerBackdrop = [UIButton buttonWithType:UIButtonTypeCustom];
  _qrPickerBackdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
  [_qrPickerBackdrop addTarget:self action:@selector(onQrPickerCancel)
              forControlEvents:UIControlEventTouchUpInside];
  [_qrPickerOverlay addSubview:_qrPickerBackdrop];
  _qrPickerPanel = [[UIView alloc] init];
  _qrPickerPanel.backgroundColor = [UIColor colorWithRed:0.10 green:0.12 blue:0.16 alpha:1];
  _qrPickerPanel.layer.cornerRadius = 14;
  [_qrPickerOverlay addSubview:_qrPickerPanel];
  _qrPickerTitle = [[UILabel alloc] init];
  _qrPickerTitle.font = [UIFont boldSystemFontOfSize:22];
  _qrPickerTitle.textColor = [UIColor whiteColor];
  _qrPickerTitle.textAlignment = NSTextAlignmentCenter;
  _qrPickerTitle.numberOfLines = 2;
  [_qrPickerPanel addSubview:_qrPickerTitle];
  _qrPickerList = [[UIScrollView alloc] init];
  [_qrPickerPanel addSubview:_qrPickerList];
  _qrPickerCancel = [self makeButton:NO];
  [_qrPickerCancel addTarget:self action:@selector(onQrPickerCancel)
              forControlEvents:UIControlEventTouchUpInside];
  [_qrPickerPanel addSubview:_qrPickerCancel];
  [self addSubview:_qrPickerOverlay];

  [self clearLabelBackgrounds:self];
  _videoStatsLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
}


- (void)prepareWithDoor:(NSString *)door purpose:(NSString *)purpose lang:(NSString *)lang
                 callID:(NSString *)callID stageRevision:(NSInteger)stageRevision
            expiresAtMs:(long long)expiresAtMs {
  ++_sipActionGen;
  [_router sipHangup];
  _sipMode = @"";
  _monitorOnly = NO;
  _liveView.contentMode = UIViewContentModeScaleAspectFit;
  _selectedPeerId = nil;
  _selectedPeerName = nil;
  _adminHosts = @[];
  _adminHostIndex = 0;
  ++_adminQrGen;
  [_adminQrButton setImage:nil forState:UIControlStateNormal];
  _adminQrButton.hidden = YES;
  _adminUrlLabel.hidden = YES;
  _qrPickerOverlay.hidden = YES;
  _door = [door copy];
  _purpose = [purpose copy];
  _visitorLang = [lang copy];
  _callID = [callID copy];
  _stageRevision = MAX(0, stageRevision);
  _callExpiresAtMs = MAX(0LL, expiresAtMs);
  _answerPending = NO;
  _awaitingSupersededIdle = NO;
  _lifecycleAnswered = NO;
  _lifecycleEnded = NO;
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
  _videoMetaUrl = @"";
  _mediaSource = nil;
  _answerButton.enabled = NO;
  _monitorButton.enabled = NO;
  _monitorAudioOn = NO;
  _micMuted = NO;
  // A ringing call shows the quick replies straight away; monitoring does not.
  _repliesVisible = YES;
  _noVideoLabel.hidden = NO;
  _liveView.image = nil;

  // Resolve the media plan from the cached config first. fetchAndApplyCoreSnapshot
  // below hops to a background queue for [core config]/[core status]; starting
  // video only after it returns used to serialize the MJPEG availability layer
  // behind that round trip, which is the whole first-glass budget on iPad 1.
  // Start now with the last known URLs; the snapshot refresh restarts the
  // pipeline only if the effective media plan actually changed.
  NSDictionary *cached = [_core lastConfig];
  if (cached) {
    _cfg = cached;
    [_texts setConfig:_cfg];
    [_texts setLang:_boot.uiLang];
  }
  _mediaSource = [DBMediaSource sourceForPeer:nil config:_cfg boot:_boot door:_door
                                     deviceID:nil];
  _incomingStreamUrl = _mediaSource.mjpegURL;
  _incomingStreamMp4Url = _mediaSource.mp4URL;
  _videoMetaUrl = _mediaSource.videoMetaURL;
  [self startVideo:_incomingStreamUrl];

  [self applyContent];
  [self restartAutoClose];
  [self fetchAndApplyCoreSnapshot];
}

- (void)prepareMonitorWithPeer:(NSDictionary *)peer {
  ++_sipActionGen;
  [_router sipHangup];
  _sipMode = @"";
  _monitorOnly = YES;
  // Letterboxed, never cropped: a portrait door camera stays portrait.
  _liveView.contentMode = UIViewContentModeScaleAspectFit;
  _liveView.clipsToBounds = YES;
  _selectedPeerId = [[DBConfigUtil evStr:peer key:@"id"] copy];
  _selectedPeerName = [[DBConfigUtil evStr:peer key:@"name"] copy];
  _door = [[DBConfigUtil evStr:peer key:@"door"] copy];
  _purpose = @"";
  _visitorLang = @"";
  _callID = @"";
  _stageRevision = 0;
  _callExpiresAtMs = 0;
  _answerPending = NO;
  _awaitingSupersededIdle = NO;
  _lifecycleAnswered = NO;
  _lifecycleEnded = NO;
  _inCall = NO;
  _cancelled = NO;
  _statusLabel.font = [UIFont systemFontOfSize:20];
  _statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
  _statusLabel.backgroundColor = [UIColor clearColor];
  _statusLabel.textAlignment = NSTextAlignmentLeft;
  _statusLabel.layer.cornerRadius = 0;
  _peerHost = [[DBConfigUtil peerHost:peer] copy];
  _mediaSource = [DBMediaSource sourceForPeer:peer config:_cfg boot:_boot door:_door
                                     deviceID:nil];
  _incomingStreamUrl = _mediaSource.mjpegURL;
  _incomingStreamMp4Url = _mediaSource.mp4URL;
  _videoMetaUrl = _mediaSource.videoMetaURL;
  [self updateAdminAddressesFromPeer:peer];
  _answerButton.enabled = NO;
  _monitorButton.enabled = ([_peerHost length] > 0);
  _monitorAudioOn = NO;
  _micMuted = NO;
  _repliesVisible = NO;
  _noVideoLabel.hidden = NO;
  _liveView.image = nil;
  NSDictionary *cached = [_core lastConfig];
  if (cached) {
    _cfg = cached;
    [_texts setConfig:_cfg];
    [_texts setLang:_boot.uiLang];
    _directPort = [DBConfigUtil intVal:_cfg path:@"sip.direct_port" def:47190];
  }
  if (_boot.directPort > 0) _directPort = _boot.directPort;
  _videoPlayback = @"low_latency";
  [self applyContent];
  [self startVideo:_incomingStreamUrl];
  [self restartAutoClose];
  [self fetchAndApplyCoreSnapshot];
}

- (BOOL)isActiveMonitor {
  return _monitorOnly && self.superview != nil;
}

- (BOOL)isAnsweringCall {
  return !_monitorOnly && (_answerPending || [_sipMode isEqualToString:@"answer"]);
}

- (void)yieldAnsweredDialog {
  _answerPending = NO;
  _lifecycleAnswered = NO;
  _lifecycleEnded = YES;
}

- (BOOL)isIncomingForDoor:(NSString *)door {
  if (_monitorOnly || !self.superview) return NO;
  return ([door length] == 0 || [_door isEqualToString:door]);
}

- (void)refreshFromCore {
  [self fetchAndApplyCoreSnapshot];
}

- (void)refreshPurpose:(NSString *)purpose lang:(NSString *)lang
          stageRevision:(NSInteger)stageRevision {
  if (stageRevision <= _stageRevision) return;
  BOOL supersedesAnswer = !_monitorOnly && stageRevision > _stageRevision &&
      (_answerPending || _inCall || [_sipMode isEqualToString:@"answer"]);
  if (supersedesAnswer) {
    ++_sipActionGen;
    _answerPending = NO;
    _awaitingSupersededIdle = YES;
    _lifecycleAnswered = NO;
    _lifecycleEnded = YES;
    _inCall = NO;
    _sipMode = @"";
    [_autoCloseTimer invalidate];
  }
  _purpose = [purpose copy];
  _visitorLang = [lang copy];
  _stageRevision = MAX(_stageRevision, stageRevision);
  _cancelled = NO;
  [self applyContent];
  _answerButton.enabled = !supersedesAnswer && ([_peerHost length] > 0);
  _hintLabel.hidden = YES;
  if (!_inCall) [self restartAutoClose];
  if (supersedesAnswer) [_router sipHangup];
  [self fetchAndApplyCoreSnapshot];
}

- (void)handleSupersededSipIdle {
  if (!_awaitingSupersededIdle) return;
  _awaitingSupersededIdle = NO;
  if (!self.superview || _monitorOnly) return;
  _sipMode = @"";
  _answerButton.enabled = ([_peerHost length] > 0);
  [_answerButton setTitle:[_texts ts:@"ring.answer"] forState:UIControlStateNormal];
  _hintLabel.hidden = YES;
  [self restartAutoClose];
}


- (void)fetchAndApplyCoreSnapshot {
  NSInteger gen = ++_snapshotGen;
  DBCoreBridge *core = _core;
  __weak DBIncomingScreen *wself = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *cfg = [core config];
    NSDictionary *st = [core status];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBIncomingScreen *s = wself;
      if (!s || s->_snapshotGen != gen || !s.superview) return;
      NSString *oldMjpeg = [s->_incomingStreamUrl copy] ?: @"";
      NSString *oldMp4 = [s->_incomingStreamMp4Url copy] ?: @"";
      NSString *oldSnapshot = [s->_mediaSource.snapshotURL copy] ?: @"";
      NSString *oldMeta = [s->_videoMetaUrl copy] ?: @"";
      NSString *oldPlayback = [s->_videoPlayback copy] ?: @"";
      NSArray *oldStrategies = [s->_videoStrategiesSource copy] ?: @[];
      s->_cfg = cfg;
      [s->_texts setConfig:cfg];
      [s->_texts setLang:s->_boot.uiLang];
      s->_directPort = [DBConfigUtil intVal:cfg path:@"sip.direct_port" def:47190];
      if (s->_boot.directPort > 0) s->_directPort = s->_boot.directPort;

      // Resolve the door peer for media and direct SIP; explicit door_host wins.
      NSDictionary *peer = s->_monitorOnly
          ? [DBConfigUtil findPeer:st nodeId:s->_selectedPeerId]
          : [DBConfigUtil findDoorPeer:st door:s->_door];
      // Replace a boot door_host placeholder with confirmed mesh metadata once it arrives.
      if (!peer && s->_monitorOnly && [s->_peerHost length] > 0)
        peer = [DBConfigUtil findDoorPeer:st host:s->_peerHost];
      if (peer) {
        s->_peerHost = (!s->_monitorOnly && [s->_boot.doorHost length] > 0)
                           ? s->_boot.doorHost
                           : [DBConfigUtil peerHost:peer];
        s->_mediaSource = [DBMediaSource sourceForPeer:peer config:cfg boot:s->_boot door:s->_door
                                             deviceID:nil];
        s->_incomingStreamUrl = s->_mediaSource.mjpegURL;
        s->_incomingStreamMp4Url = s->_mediaSource.mp4URL;
        s->_videoMetaUrl = s->_mediaSource.videoMetaURL;
        if (s->_monitorOnly) {
          NSString *resolvedId = [DBConfigUtil evStr:peer key:@"id"];
          NSString *resolvedName = [DBConfigUtil evStr:peer key:@"name"];
          if ([resolvedId length] > 0) s->_selectedPeerId = resolvedId;
          if ([resolvedName length] > 0) s->_selectedPeerName = resolvedName;
        }
        [s updateAdminAddressesFromPeer:peer];
      } else if (!s->_monitorOnly) {
        s->_peerHost = ([s->_boot.doorHost length] > 0) ? s->_boot.doorHost : nil;
        s->_mediaSource = [DBMediaSource sourceForPeer:nil config:cfg boot:s->_boot door:s->_door
                                             deviceID:nil];
        s->_incomingStreamUrl = s->_mediaSource.mjpegURL;
        s->_incomingStreamMp4Url = s->_mediaSource.mp4URL;
        s->_videoMetaUrl = s->_mediaSource.videoMetaURL;
      }
      NSString *selfId = [DBConfigUtil str:st path:@"node.id"];
      s->_nodeId = [selfId copy] ?: @"";
      NSDictionary *display = [st objectForKey:@"display"];
      if ([display isKindOfClass:[NSDictionary class]]) s->_display = display;
      // Core reports whether an unlock action exists and whether the button
      // should be shown, so the shell never has to guess from configuration.
      s->_doorUnlock = [DBConfigUtil dig:st path:[NSString stringWithFormat:
          @"doors.%@.unlock", s->_door ?: @""]];
      NSString *playbackPath = [selfId length]
          ? [NSString stringWithFormat:@"devices.%@.local.video.playback", selfId] : nil;
      NSString *playback = playbackPath ? [DBConfigUtil str:cfg path:playbackPath] : nil;
      if (![playback isEqualToString:@"hls"] && ![playback isEqualToString:@"mjpeg"])
        playback = @"low_latency";
      s->_videoPlayback = playback;
      NSDictionary *profile = [peer objectForKey:@"playback_profile"];
      NSArray *nextStrategies = [s videoStrategiesFromProfile:profile legacy:playback];
      BOOL mediaChanged = !DBSameString(oldMjpeg, s->_incomingStreamUrl ?: @"") ||
          !DBSameString(oldMp4, s->_incomingStreamMp4Url ?: @"") ||
          !DBSameString(oldSnapshot, s->_mediaSource.snapshotURL ?: @"") ||
          !DBSameString(oldMeta, s->_videoMetaUrl ?: @"") ||
          !DBSameString(oldPlayback, playback ?: @"") ||
          ![oldStrategies isEqualToArray:nextStrategies];
      s->_videoStrategies = nextStrategies;
      s->_videoStrategiesSource = nextStrategies;
      s->_answerButton.enabled = (!s->_monitorOnly && !s->_awaitingSupersededIdle &&
                                  s->_peerHost != nil);
      s->_monitorButton.enabled = (s->_peerHost != nil);
      // Status/config refreshes are frequent.  Restarting an otherwise healthy
      // session here repeatedly forces iPad 1 through H.264 fallback and makes
      // the preview visibly jump.  Recreate the pipeline only for an effective
      // media-plan change or after it has fully stopped.
      BOOL videoStopped = !s->_streamer && !s->_snapshotPoller && !s->_h264 &&
          !s->_lowLatency && s->_currentVideoStrategy == nil;
      if (!s->_cancelled && (mediaChanged || videoStopped))
        [s startVideo:s->_incomingStreamUrl];
      [s applyContent];
      [s restartAutoClose];
    });
  });
}

- (void)applyContent {
  NSDictionary *doorEntry = [DBConfigUtil dig:_cfg path:[NSString stringWithFormat:@"doors.%@", _door]];
  NSString *label = [DBConfigUtil labelOf:doorEntry lang:_boot.uiLang fallback:_door];
  if (_monitorOnly) {
    NSString *name = [_selectedPeerName length] > 0 ? _selectedPeerName : label;
    _titleLabel.text = [_texts t:@"monitor.title", name, nil];
  } else {
    _titleLabel.text = [_texts t:@"ring.incoming", label, nil];
  }
  _noVideoLabel.text = [_texts ts:@"ring.no_video"];
  _statusLabel.text = _monitorOnly ? [_texts ts:@"monitor.live"]
                                   : [_texts ts:(_cancelled ? @"ring.cancelled" : @"reply.choose")];
  [_answerButton setTitle:(_inCall ? [_texts ts:@"incall.end"] : [_texts ts:@"ring.answer"])
                 forState:UIControlStateNormal];
  // The monitor and mic entries are stateful toggles with a visible on/off
  // state, not silent buttons (spec §5.1).
  [_monitorButton setTitle:[_texts ts:(_monitorAudioOn ? @"ring.monitor_on"
                                                       : @"ring.monitor_off")]
                  forState:UIControlStateNormal];
  [_micButton setTitle:[_texts ts:(_micMuted ? @"ring.mic_off" : @"ring.mic_on")]
              forState:UIControlStateNormal];
  [_repliesButton setTitle:[_texts ts:@"admin.quick_replies"] forState:UIControlStateNormal];
  [_openButton setTitle:[_texts ts:@"ring.open_door"] forState:UIControlStateNormal];
  [_ignoreButton setTitle:[_texts ts:(_monitorOnly ? @"monitor.close" : @"ring.ignore")]
                  forState:UIControlStateNormal];
  _answerButton.hidden = _monitorOnly;
  _micButton.hidden = _monitorOnly;
  _langBadge.hidden = _monitorOnly;
  [self refreshUnlockVisibility];
  [self refreshNoticeChip];
  [self applyPalette];
  [self updateBadges];
  [self buildReplyButtons];
  [self applySemanticStyles];
  [self setNeedsLayout];
}

// The unlock button is an admin decision (spec §5.2). It defaults to on when an
// unlock action exists and off when it does not, and an explicit setting wins.
// Core reports doors.<id>.unlock = {configured, command, show_button, source}:
// show_button defaults to configured and an administrator may force either
// answer (spec §5.2). An older core leaves the button on its configured state.
- (void)refreshUnlockVisibility {
  _unlockConfigured = [DBConfigUtil boolVal:_doorUnlock path:@"configured" def:NO];
  _unlockVisible = [DBConfigUtil boolVal:_doorUnlock path:@"show_button"
                                     def:_unlockConfigured];
  _openButton.hidden = !_unlockVisible;
}

- (void)refreshNoticeChip {
  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  NSDictionary *notice = [DBNoticeModel effectiveNoticeForDoor:_door config:_cfg nowMs:nowMs];
  [_noticeChip setChipTitle:[_texts ts:@"notice.chip"] active:(notice != nil)];
  _noticeChip.hidden = ([_door length] == 0);
}

- (void)applyPalette {
  _palette = [DBUiPalette paletteForConfig:_cfg deviceId:_nodeId display:_display
                             backgroundHex:nil minuteOfDay:[self minuteOfDay]];
  [_noticeChip applyPalette:_palette];
  _adminUrlLabel.textColor = [_palette.ink colorWithAlphaComponent:0.85];
}

- (NSInteger)minuteOfDay {
  NSDictionary *local = [_core localTimeJson:0];
  NSInteger hh = [DBConfigUtil intVal:local path:@"hh" def:-1];
  if (hh < 0) return 12 * 60;
  return hh * 60 + [DBConfigUtil intVal:local path:@"mm" def:0];
}

- (void)onNoticeChip {
  if ([_door length] == 0) return;
  if (!_noticeDialog) _noticeDialog = [[DBNoticeDialog alloc] initWithRouter:_router];
  NSMutableArray *doorIds = [NSMutableArray array];
  NSMutableDictionary *labels = [NSMutableDictionary dictionary];
  NSDictionary *doors = [DBConfigUtil dig:_cfg path:@"doors"];
  if ([doors isKindOfClass:[NSDictionary class]]) {
    for (NSString *identifier in [DBConfigUtil sortedByOrder:doors]) {
      [doorIds addObject:identifier];
      [labels setObject:[DBConfigUtil labelOf:[doors objectForKey:identifier]
                                         lang:_boot.uiLang fallback:identifier]
                 forKey:identifier];
    }
  }
  __weak DBIncomingScreen *weakSelf = self;
  // Opened from a door's own screen, so that door is preselected.
  [_noticeDialog presentInView:self config:_cfg doorIds:doorIds doorLabels:labels
               preselectedDoor:_door palette:_palette onFinished:^(BOOL changed) {
    DBIncomingScreen *screen = weakSelf;
    if (screen && changed) [screen refreshFromCore];
  }];
}

- (void)onMic {
  BOOL muted = !_micMuted;
  if ([DBCoreBridge supportsMicMute]) {
    // Core mutes the capture path in place and reports status.call.mic_muted,
    // so the call is never torn down to change the microphone.
    if ([_core setMicMuted:muted] != 0) return;
  } else if ([_sipMode isEqualToString:@"answer"] && [_peerHost length] > 0) {
    // Older Core: MiniSIP owns the microphone for the whole session, so muting
    // is expressed by restarting the answered leg in listen-only mode.
    [_router sipStart:_peerHost port:(int)_directPort
                 mode:(muted ? @"monitor" : @"answer")];
  }
  _micMuted = muted;
  [self applyContent];
}

- (void)onToggleReplies {
  _repliesVisible = !_repliesVisible;
  [self setNeedsLayout];
}

- (void)onToggleDebugLine {
  _debugLineHidden = !_debugLineHidden;
  [[NSUserDefaults standardUserDefaults] setBool:_debugLineHidden forKey:kDebugLineHiddenKey];
  [[NSUserDefaults standardUserDefaults] synchronize];
  _videoStatsLabel.hidden = _debugLineHidden;
  [self setNeedsLayout];
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
  UIColor *screen = [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1];
  NSDictionary *title = [self styleForSemanticID:@"ring.title" foreground:white
                                       background:screen safety:NO];
  [DBSemanticStyle applyLabel:_titleLabel style:title foreground:white
                    background:[UIColor clearColor] fontSize:30];

  UIColor *green = [UIColor colorWithRed:0.094 green:0.478 blue:0.235 alpha:1];
  NSString *answerID = _inCall ? @"call.end" : @"ring.action";
  NSDictionary *answer = [self styleForSemanticID:answerID foreground:white
                                        background:green safety:_inCall];
  [DBSemanticStyle applyButton:_answerButton style:answer foreground:white background:green
                        border:nil radius:12 fontSize:22];

  UIColor *neutralEffective = [UIColor colorWithRed:0.16 green:0.17 blue:0.19 alpha:1];
  NSDictionary *action = [self styleForSemanticID:@"ring.action" foreground:white
                                        background:neutralEffective safety:NO];
  for (UIButton *button in @[ _monitorButton, _openButton ])
    [DBSemanticStyle applyButton:button style:action foreground:white
                      background:[UIColor colorWithWhite:1 alpha:0.12]
                          border:nil radius:12 fontSize:22];

  NSString *closeID = _monitorOnly ? @"monitor.close" : @"ring.action";
  NSDictionary *close = [self styleForSemanticID:closeID foreground:white
                                       background:neutralEffective safety:_monitorOnly];
  [DBSemanticStyle applyButton:_ignoreButton style:close foreground:white
                    background:[UIColor colorWithWhite:1 alpha:0.12]
                        border:nil radius:12 fontSize:22];

  NSDictionary *reply = [self styleForSemanticID:@"reply.button" foreground:white
                                       background:neutralEffective safety:NO];
  for (UIButton *button in _replyButtons)
    [DBSemanticStyle applyButton:button style:reply foreground:white
                      background:[UIColor colorWithWhite:1 alpha:0.10]
                          border:nil radius:12 fontSize:22];
}

- (void)updateBadges {
  if (_monitorOnly) {
    _purposeBadge.hidden = YES;
    _langBadge.hidden = YES;
    return;
  }
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
  if (_monitorOnly || _inCall) return;
  NSDictionary *replies = [DBConfigUtil dig:_cfg path:@"quick_replies"];
  if (![replies isKindOfClass:[NSDictionary class]] || [replies count] == 0) return;
  NSString *lang = [_visitorLang length] == 0 ? @"ja" : _visitorLang;
  for (NSString *rid in [DBConfigUtil sortedByOrder:replies]) {
    NSDictionary *entry = [replies objectForKey:rid];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
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

#pragma mark - Door-station Admin QR

- (NSInteger)adminHttpPort {
  // An external camera URL is not the door station's admin endpoint.
  return 47180;
}

- (NSString *)adminUrlForHost:(NSString *)host {
  NSString *urlHost = [DBConfigUtil urlHost:host];
  if ([urlHost length] == 0) return nil;
  return [NSString stringWithFormat:@"http://%@:%ld/admin/", urlHost,
                                    (long)[self adminHttpPort]];
}

- (void)updateAdminAddressesFromPeer:(NSDictionary *)peer {
  NSString *old = (_adminHostIndex >= 0 && _adminHostIndex < (NSInteger)[_adminHosts count])
      ? [_adminHosts objectAtIndex:_adminHostIndex] : nil;
  NSMutableArray *hosts = [NSMutableArray arrayWithArray:[DBConfigUtil peerHosts:peer]];

  // Include a reachable stream host even when it is absent from peer addresses.
  NSString *streamHost = [[NSURL URLWithString:_incomingStreamUrl ?: @""] host];
  if ([_mediaSource.kind isEqualToString:@"node"] && [streamHost length] > 0 &&
      ![hosts containsObject:streamHost])
    [hosts insertObject:streamHost atIndex:0];
  if ([_peerHost length] > 0 && ![hosts containsObject:_peerHost])
    [hosts insertObject:_peerHost atIndex:0];

  _adminHosts = [hosts copy];
  NSInteger selected = NSNotFound;
  if ([old length] > 0) selected = [_adminHosts indexOfObject:old];
  if (selected == NSNotFound && [_peerHost length] > 0)
    selected = [_adminHosts indexOfObject:_peerHost];
  _adminHostIndex = selected == NSNotFound ? 0 : selected;
  [self updateAdminQr];
}

- (void)updateAdminQr {
  NSInteger gen = ++_adminQrGen;
  // The door station's admin QR stays visible in a corner of the incoming
  // screen too (spec §5.2, round 5), not only while actively monitoring.
  BOOL available = ([_adminHosts count] > 0);
  _adminQrButton.hidden = !available;
  _adminUrlLabel.hidden = !available;
  if (!available) {
    [_adminQrButton setImage:nil forState:UIControlStateNormal];
    _adminUrlLabel.text = [_texts ts:@"monitor.admin_qr_none"];
    return;
  }
  if (_adminHostIndex < 0 || _adminHostIndex >= (NSInteger)[_adminHosts count])
    _adminHostIndex = 0;
  NSString *host = [_adminHosts objectAtIndex:_adminHostIndex];
  NSString *url = [self adminUrlForHost:host];
  _adminUrlLabel.text = url;
  _adminQrButton.accessibilityLabel = [NSString stringWithFormat:@"%@: %@",
      [_texts ts:@"monitor.admin_qr"], url];
  [_adminQrButton setImage:nil forState:UIControlStateNormal];

  __weak DBIncomingScreen *wself = self;
  NSString *want = [url copy];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    UIImage *img = [DBQrCode imageForString:want targetPx:138];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBIncomingScreen *s = wself;
      if (!s || !s.superview || s->_adminQrGen != gen) return;
      [s->_adminQrButton setImage:img forState:UIControlStateNormal];
    });
  });
  [self setNeedsLayout];
}

- (void)onAdminQrTapped {
  if ([_adminHosts count] == 0) return;
  for (UIButton *b in _qrPickerButtons) [b removeFromSuperview];
  [_qrPickerButtons removeAllObjects];
  for (NSInteger i = 0; i < (NSInteger)[_adminHosts count]; i++) {
    NSString *url = [self adminUrlForHost:[_adminHosts objectAtIndex:i]];
    UIButton *b = [self makeButton:(i == _adminHostIndex)];
    b.tag = i;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    b.titleLabel.numberOfLines = 2;
    b.titleLabel.lineBreakMode = NSLineBreakByCharWrapping;
    NSString *title = i == _adminHostIndex ? [@"✓  " stringByAppendingString:url] : url;
    [b setTitle:title forState:UIControlStateNormal];
    [b addTarget:self action:@selector(onAdminAddressChoice:)
        forControlEvents:UIControlEventTouchUpInside];
    [_qrPickerList addSubview:b];
    [_qrPickerButtons addObject:b];
  }
  _qrPickerTitle.text = [_texts ts:@"monitor.admin_qr_select"];
  [_qrPickerCancel setTitle:[_texts ts:@"admin.cancel"] forState:UIControlStateNormal];
  _qrPickerOverlay.hidden = NO;
  [self bringSubviewToFront:_qrPickerOverlay];
  [self setNeedsLayout];
  [self layoutIfNeeded];
}

- (void)onAdminAddressChoice:(UIButton *)sender {
  if (sender.tag >= 0 && sender.tag < (NSInteger)[_adminHosts count]) {
    _adminHostIndex = sender.tag;
    [self updateAdminQr];
  }
  _qrPickerOverlay.hidden = YES;
}

- (void)onQrPickerCancel {
  _qrPickerOverlay.hidden = YES;
}

- (void)layoutQrPicker:(CGSize)size {
  _qrPickerOverlay.frame = CGRectMake(0, 0, size.width, size.height);
  _qrPickerBackdrop.frame = _qrPickerOverlay.bounds;
  CGFloat panelW = MIN(620, size.width - 80);
  CGFloat listH = MIN(MAX(58, [_adminHosts count] * 62), size.height - 230);
  CGFloat panelH = 78 + listH + 72;
  _qrPickerPanel.frame = CGRectMake((size.width - panelW) / 2,
                                    (size.height - panelH) / 2, panelW, panelH);
  _qrPickerTitle.frame = CGRectMake(18, 12, panelW - 36, 54);
  _qrPickerList.frame = CGRectMake(18, 74, panelW - 36, listH);
  CGFloat y = 0;
  for (UIButton *b in _qrPickerButtons) {
    b.frame = CGRectMake(0, y, panelW - 36, 54);
    y += 62;
  }
  _qrPickerList.contentSize = CGSizeMake(panelW - 36, y);
  _qrPickerCancel.frame = CGRectMake(18, panelH - 60, panelW - 36, 48);
}

#pragma mark - Video

// Core resolves pair, global, legacy, and default inheritance. Older Core versions
// without a profile receive a compatible two-step strategy from the legacy value.
- (NSArray *)videoStrategiesFromProfile:(NSDictionary *)profile legacy:(NSString *)legacy {
  id raw = [profile objectForKey:@"strategies"];
  NSMutableArray *out = [NSMutableArray array];
  // The MJPEG availability layer runs whenever an MJPEG URL exists, whatever
  // the strategy order, unless a profile explicitly disables the MJPEG
  // strategy. A profile that simply omits mjpeg must not leave the screen with
  // nothing to paint while H.264 probes.
  _mjpegAvailabilityDisabled = NO;
  if ([raw isKindOfClass:[NSArray class]]) {
    for (id value in (NSArray *)raw) {
      if (![value isKindOfClass:[NSDictionary class]]) continue;
      NSDictionary *s = (NSDictionary *)value;
      NSString *sid = [DBConfigUtil evStr:s key:@"id"];
      BOOL known = [sid isEqualToString:@"h264_low_latency"] ||
                   [sid isEqualToString:@"h264_hls"] || [sid isEqualToString:@"mjpeg"];
      BOOL enabled = [DBConfigUtil evBool:s key:@"enabled"];
      if ([sid isEqualToString:@"mjpeg"] && !enabled) _mjpegAvailabilityDisabled = YES;
      if (known && enabled) [out addObject:s];
    }
  }
  if ([out count]) return out;
  NSDictionary *mjpeg = @{ @"id": @"mjpeg", @"enabled": @YES,
      @"startup_timeout_ms": @5000, @"stall_timeout_ms": @3000 };
  NSString *sid = [legacy isEqualToString:@"hls"] ? @"h264_hls" : @"h264_low_latency";
  NSDictionary *h264 = @{ @"id": sid, @"enabled": @YES,
      @"startup_timeout_ms": @5000, @"stall_timeout_ms":
          [sid isEqualToString:@"h264_hls"] ? @5000 : @3000 };
  return @[h264, mjpeg];
}

- (void)startVideo:(NSString *)mjpegUrl {
  (void)mjpegUrl;
  [self stopVideoPlayers];
  [self startVideoOrientationPolling];
  if (_safeMode) {
    _videoStrategies = [_incomingStreamUrl length] > 0 ? @[@{
      @"id" : @"mjpeg", @"enabled" : @YES,
      @"startup_timeout_ms" : @5000, @"stall_timeout_ms" : @3000,
    }] : @[];
  } else if (![_videoStrategies count]) {
    _videoStrategies = [self videoStrategiesFromProfile:nil legacy:_videoPlayback];
    _videoStrategiesSource = _videoStrategies;
  }
  if (!_safeMode && [_incomingStreamMp4Url length] > 0) {
    NSMutableArray *h264 = [NSMutableArray array];
    NSMutableArray *fallback = [NSMutableArray array];
    for (NSDictionary *strategy in _videoStrategies) {
      NSString *sid = [DBConfigUtil evStr:strategy key:@"id"];
      if ([sid isEqualToString:@"h264_low_latency"] || [sid isEqualToString:@"h264_hls"])
        [h264 addObject:strategy];
      else
        [fallback addObject:strategy];
    }
    if (![h264 count]) [h264 addObject:@{ @"id": @"h264_low_latency", @"enabled": @YES,
        @"startup_timeout_ms": @5000, @"stall_timeout_ms": @3000 }];
    [h264 addObjectsFromArray:fallback];
    _videoStrategies = h264;
  }
  _videoSessionGen++;
  _videoAttemptGen = 0;
  [_h264Backoff reset];
  _videoStrategyIndex = -1;
  _currentVideoStrategy = nil;
  _videoStrategyPlaying = NO;
  _pendingMjpegFrame = nil;
  _activeVideoTransport = @"STARTING";
  [self updateVideoStats:nil];
  _noVideoLabel.hidden = NO;
  _liveView.image = nil;
  if ([_incomingStreamUrl length] == 0 && [_incomingStreamMp4Url length] == 0 &&
      [_mediaSource.snapshotURL length] == 0) {
    _activeVideoTransport = @"NO STREAM";
    [self updateVideoStats:nil];
    return;
  }
  if ([_incomingStreamUrl length] == 0 && [_incomingStreamMp4Url length] == 0) {
    [self startSnapshotFallback];
    return;
  }
  // MJPEG is the availability layer while an H.264 decoder waits for its first
  // IDR and while it proves it can sustain a frame rate. Start it whenever an
  // MJPEG URL exists — regardless of where mjpeg sits in the strategy order,
  // and even when the profile omits the mjpeg strategy entirely — unless the
  // profile explicitly disabled it.
  if ([_incomingStreamUrl length] > 0 && !_mjpegAvailabilityDisabled)
    [self startMjpegPrewarm];
  [self advanceVideoStrategy:@"session_start"];
}

- (void)startMjpegPrewarm {
  if (_streamer) return;
  if ([_incomingStreamUrl length] == 0) return;
  NSInteger session = _videoSessionGen;
  NSString *secretRef = [_mediaSource.secretRef copy];
  __weak DBIncomingScreen *wself = self;
  _streamer = [[DBMjpegClient alloc] initWithURLString:_incomingStreamUrl
      credentialProvider:^NSString * {
    DBIncomingScreen *screen = wself;
    if (!screen || ![secretRef hasPrefix:@"secret:"] || [secretRef length] <= 7)
      return nil;
    return [screen->_core loadSecret:[secretRef substringFromIndex:7]];
  } stateHandler:^(NSString *state, NSString *reason) {
    DBIncomingScreen *screen = wself;
    if (!screen || screen->_videoSessionGen != session ||
        ![screen->_currentVideoStrategy isEqualToString:@"mjpeg"]) return;
    if ([state isEqualToString:@"retry_wait"] && !screen->_videoStrategyPlaying) {
      screen->_activeVideoTransport = @"WAIT MJPEG";
      [screen updateVideoStats:nil];
    }
    (void)reason;
  } onFrame:^(UIImage *img) {
    DBIncomingScreen *s = wself;
    if (!s || s->_videoSessionGen != session) return;
    s->_pendingMjpegFrame = img;
    if ([s->_currentVideoStrategy isEqualToString:@"mjpeg"] || !s->_videoStrategyPlaying) {
      BOOL selectedMjpeg = [s->_currentVideoStrategy isEqualToString:@"mjpeg"];
      if (selectedMjpeg) s->_videoStrategyPlaying = YES;
      s->_activeVideoTransport = selectedMjpeg
          ? @"MJPEG" : @"MJPEG / H.264 PROBING";
      s->_noVideoLabel.hidden = YES;
      s->_liveView.image = img;
    }
  }];
  _streamer.lowResourceMode = _safeMode;
  [_streamer start];
}

- (void)startSnapshotFallback {
  if (_snapshotPoller || [_mediaSource.snapshotURL length] == 0) return;
  NSInteger session = _videoSessionGen;
  _activeVideoTransport = @"WAIT SNAPSHOT";
  NSString *secretRef = [_mediaSource.secretRef copy];
  __weak DBIncomingScreen *weakSelf = self;
  _snapshotPoller = [[DBSnapshotPoller alloc] initWithURLString:_mediaSource.snapshotURL
      credentialProvider:^NSString * {
    DBIncomingScreen *screen = weakSelf;
    if (!screen || ![secretRef hasPrefix:@"secret:"] || [secretRef length] <= 7)
      return nil;
    return [screen->_core loadSecret:[secretRef substringFromIndex:7]];
  } stateHandler:^(NSString *state, NSString *reason) {
    DBIncomingScreen *screen = weakSelf;
    if (!screen || screen->_videoSessionGen != session) return;
    if ([state isEqualToString:@"retry_wait"] && !screen->_videoStrategyPlaying) {
      screen->_activeVideoTransport = @"WAIT SNAPSHOT";
      screen->_noVideoLabel.hidden = NO;
      [screen updateVideoStats:nil];
    }
    (void)reason;
  } onFrame:^(UIImage *image) {
    DBIncomingScreen *screen = weakSelf;
    if (!screen || screen->_videoSessionGen != session) return;
    screen->_videoStrategyPlaying = YES;
    screen->_activeVideoTransport = @"SNAPSHOT";
    screen->_liveView.image = image;
    screen->_noVideoLabel.hidden = YES;
    [screen updateVideoStats:nil];
  }];
  _snapshotPoller.lowResourceMode = _safeMode;
  [_snapshotPoller start];
}

- (void)advanceVideoStrategy:(NSString *)reason {
  NSLog(@"[doorbell] playback advance from=%@ reason=%@", _currentVideoStrategy, reason);
  _videoAttemptGen++;
  [_lowLatency stop]; _lowLatency = nil;
  [_h264 stop]; _h264 = nil;
  if ([_currentVideoStrategy isEqualToString:@"mjpeg"]) {
    [_streamer stop]; _streamer = nil;
    _pendingMjpegFrame = nil;
  }
  _videoStrategyPlaying = NO;
  _currentVideoStrategy = nil;
  // Each strategy gets its own schedule; only the retry loop inside one
  // strategy is what needs to be spaced out.
  [_h264Backoff reset];
  _videoStrategyIndex++;
  while (_videoStrategyIndex < (NSInteger)[_videoStrategies count]) {
    NSDictionary *s = [_videoStrategies objectAtIndex:(NSUInteger)_videoStrategyIndex];
    NSString *sid = [DBConfigUtil evStr:s key:@"id"];
    if (_safeMode && ![sid isEqualToString:@"mjpeg"]) {
      _videoStrategyIndex++;
      continue;
    }
    if ([sid isEqualToString:@"h264_hls"] && ![DBH264Player hardwareSupported]) {
      _videoStrategyIndex++;
      continue;
    }
    [self startCurrentVideoStrategy];
    return;
  }
  [_streamer stop]; _streamer = nil;
  if ([_mediaSource.snapshotURL length] > 0) {
    [self startSnapshotFallback];
    return;
  }
  _activeVideoTransport = @"NO STREAM";
  _noVideoLabel.hidden = NO;
  [self updateVideoStats:nil];
}

- (void)retryCurrentH264:(NSString *)reason {
  NSString *sid = _currentVideoStrategy;
  if (!([sid isEqualToString:@"h264_low_latency"] || [sid isEqualToString:@"h264_hls"])) {
    [self advanceVideoStrategy:reason];
    return;
  }
  // A door station whose mesh peer is alive but whose HTTP server never answers
  // used to be restarted on a flat 2 s timer, which produced an endless
  // "start fMP4 direct decode" / "response header ended" loop. Back off
  // 1 -> 2 -> 5 -> 10 s (capped) and reset the schedule as soon as a transport
  // reports that it is playing. MJPEG stays up as the availability layer
  // throughout, and the wait is a timer, never a blocked main thread.
  NSTimeInterval delay = [_h264Backoff nextDelay];
  NSLog(@"[doorbell] keeping MJPEG visible; retrying %@ after %@ in %.0fs (attempt %lu)",
        sid, reason, delay, (unsigned long)[_h264Backoff attempt]);
  NSInteger session = _videoSessionGen;
  NSInteger retry = ++_videoAttemptGen;
  [_lowLatency stop]; _lowLatency = nil;
  [_h264 stop]; _h264 = nil;
  _videoStrategyPlaying = NO;
  _activeVideoTransport = @"MJPEG / H.264 RETRY";
  // Never sit on a dead H.264 attempt with no availability layer running.
  if (!_streamer && [_incomingStreamUrl length] > 0 && !_mjpegAvailabilityDisabled)
    [self startMjpegPrewarm];
  if (_pendingMjpegFrame) {
    _liveView.image = _pendingMjpegFrame;
    _noVideoLabel.hidden = YES;
  }
  [self updateVideoStats:nil];
  __weak DBIncomingScreen *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    DBIncomingScreen *s = weakSelf;
    if (!s || s->_videoSessionGen != session || s->_videoAttemptGen != retry ||
        ![s->_currentVideoStrategy isEqualToString:sid]) return;
    [s startCurrentVideoStrategy];
  });
}

- (void)startCurrentVideoStrategy {
  if (_videoStrategyIndex < 0 || _videoStrategyIndex >= (NSInteger)[_videoStrategies count]) return;
  NSDictionary *strategy = [_videoStrategies objectAtIndex:(NSUInteger)_videoStrategyIndex];
  NSString *sid = [DBConfigUtil evStr:strategy key:@"id"];
  _currentVideoStrategy = sid;
  _videoStrategyPlaying = NO;
  NSInteger session = _videoSessionGen;
  NSInteger attempt = ++_videoAttemptGen;
  NSInteger timeoutMs = [[strategy objectForKey:@"startup_timeout_ms"] integerValue];
  if (timeoutMs < 100) timeoutMs = 300;
  // The direct fMP4 stream is healthy before its first decodable IDR arrives.
  // Old fleet profiles used 300 ms, and some device codecs defer a requested
  // IDR for several seconds. Keep old profiles compatible while enforcing a
  // realistic decoder startup floor.
  if (([sid isEqualToString:@"h264_low_latency"] ||
       [sid isEqualToString:@"h264_hls"]) && timeoutMs < 5000)
    timeoutMs = 5000;
  _activeVideoTransport = [NSString stringWithFormat:@"WAIT %@", sid];
  [self updateVideoStats:nil];

  if ([sid isEqualToString:@"mjpeg"]) {
    [self startMjpegPrewarm];
    if (_pendingMjpegFrame) {
      _videoStrategyPlaying = YES;
      _activeVideoTransport = @"MJPEG";
      _liveView.image = _pendingMjpegFrame;
      _noVideoLabel.hidden = YES;
    }
  } else if ([_incomingStreamMp4Url length] == 0) {
    [self advanceVideoStrategy:@"no_mp4_url"];
    return;
  } else if ([sid isEqualToString:@"h264_low_latency"]) {
    __weak DBIncomingScreen *wself = self;
    _lowLatency = [[DBLowLatencyH264Player alloc] initWithURL:_incomingStreamMp4Url
        container:_liveView onState:^(DBLowLatencyPlayerState st) {
      DBIncomingScreen *s = wself;
      if (!s || s->_videoSessionGen != session || s->_videoAttemptGen != attempt ||
          ![s->_currentVideoStrategy isEqualToString:@"h264_low_latency"]) return;
      if (st == DBLowLatencyPlayerPlaying) {
        s->_videoStrategyPlaying = YES;
        [s->_h264Backoff reset];
        s->_activeVideoTransport = @"H.264 LOW-LAT";
        s->_noVideoLabel.hidden = YES;
        [s updateVideoStats:nil];
      } else if (st == DBLowLatencyPlayerFailed) {
        [s retryCurrentH264:@"decoder_error"];
      } else if (st == DBLowLatencyPlayerStalled) {
        // The player already uncovered the MJPEG layer; repaint it and retry.
        [s retryCurrentH264:@"display_stall"];
      }
    }];
    // Optional fleet knobs; absent keys keep the safe adaptive defaults.
    id startKnob = [strategy objectForKey:@"live_edge_start_ms"];
    id floorKnob = [strategy objectForKey:@"live_edge_min_ms"];
    id ceilingKnob = [strategy objectForKey:@"live_edge_max_ms"];
    if ([startKnob isKindOfClass:[NSNumber class]])
      _lowLatency.liveEdgeStartMs = (int64_t)[startKnob longLongValue];
    if ([floorKnob isKindOfClass:[NSNumber class]])
      _lowLatency.liveEdgeFloorMs = (int64_t)[floorKnob longLongValue];
    if ([ceilingKnob isKindOfClass:[NSNumber class]])
      _lowLatency.liveEdgeCeilingMs = (int64_t)[ceilingKnob longLongValue];
    [_lowLatency start];
  } else if ([sid isEqualToString:@"h264_hls"]) {
    __weak DBIncomingScreen *wself = self;
    _h264 = [[DBH264Player alloc] initWithURL:_incomingStreamMp4Url container:_liveView
                                      onState:^(DBH264PlayerState st) {
      DBIncomingScreen *s = wself;
      if (!s || s->_videoSessionGen != session || s->_videoAttemptGen != attempt ||
          ![s->_currentVideoStrategy isEqualToString:@"h264_hls"]) return;
      if (st == DBH264PlayerPlaying) {
        s->_videoStrategyPlaying = YES;
        [s->_h264Backoff reset];
        s->_activeVideoTransport = @"HLS H.264";
        s->_noVideoLabel.hidden = YES;
        [s updateVideoStats:nil];
      } else if (st == DBH264PlayerFailed) {
        [s retryCurrentH264:@"decoder_error"];
      }
    }];
    [_h264 start];
  }

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutMs * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    DBIncomingScreen *s = self;
    if (!s || s->_videoSessionGen != session || s->_videoAttemptGen != attempt ||
        s->_videoStrategyPlaying) return;
    if ([sid isEqualToString:@"h264_low_latency"] || [sid isEqualToString:@"h264_hls"])
      [s retryCurrentH264:@"startup_timeout"];
    else
      [s advanceVideoStrategy:@"startup_timeout"];
  });
}

- (void)stopVideoPlayers {
  _videoSessionGen++;
  _videoAttemptGen++;
  _videoStrategyPlaying = NO;
  _currentVideoStrategy = nil;
  _pendingMjpegFrame = nil;
  [_videoOrientationTimer invalidate];
  _videoOrientationTimer = nil;
  _videoOrientationBusy = NO;
  _videoRotation = 0;
  _liveView.transform = CGAffineTransformIdentity;
  [_streamer stop];
  _streamer = nil;
  [_snapshotPoller stop];
  _snapshotPoller = nil;
  [_h264 stop];
  _h264 = nil;
  [_lowLatency stop];
  _lowLatency = nil;
}

// A long-lived H.264 stream cannot carry changing HTTP metadata. Poll the small
// video-meta endpoint only during a call and use the same transform for all codecs.
- (void)startVideoOrientationPolling {
  [_videoOrientationTimer invalidate];
  _videoOrientationTimer = nil;
  if ([_videoMetaUrl length] == 0) return;
  _videoOrientationTimer = [NSTimer timerWithTimeInterval:0.5 target:self
      selector:@selector(pollVideoOrientation:) userInfo:nil repeats:YES];
  [[NSRunLoop mainRunLoop] addTimer:_videoOrientationTimer forMode:NSRunLoopCommonModes];
  [self pollVideoOrientation:nil];
}

- (void)pollVideoOrientation:(NSTimer *)timer {
  (void)timer;
  if (_videoOrientationBusy || !self.superview) return;
  NSURL *url = [NSURL URLWithString:_videoMetaUrl];
  if (!url) return;
  _videoOrientationBusy = YES;
  NSURLRequest *req = [NSURLRequest requestWithURL:url
      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:1.0];
  __weak DBIncomingScreen *wself = self;
  [NSURLConnection sendAsynchronousRequest:req queue:[NSOperationQueue mainQueue]
      completionHandler:^(NSURLResponse *resp, NSData *data, NSError *error) {
    (void)resp;
    DBIncomingScreen *s = wself;
    if (!s) return;
    s->_videoOrientationBusy = NO;
    if (error || !data) return;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSInteger rotation = [[j objectForKey:@"rotation"] integerValue];
    rotation = ((rotation % 360) + 360) % 360;
    if (rotation == s->_videoRotation) return;
    s->_videoRotation = rotation;
    // Clear the old transform before relayout; assigning a frame under a non-identity
    // transform is undefined and can leave shrunken bounds after rotation.
    s->_liveView.transform = CGAffineTransformIdentity;
    [s setNeedsLayout];
    [s layoutIfNeeded];
    CGFloat angle = (CGFloat)rotation * (CGFloat)3.14159265358979323846 / 180.0f;
    CGFloat scale = 1.0f;
    if ((rotation == 90 || rotation == 270) && s->_liveView.bounds.size.width > 0 &&
        s->_liveView.bounds.size.height > 0) {
      scale = MIN(s->_liveView.bounds.size.width / s->_liveView.bounds.size.height,
                  s->_liveView.bounds.size.height / s->_liveView.bounds.size.width);
    }
    [UIView animateWithDuration:0.2 animations:^{
      s->_liveView.transform = CGAffineTransformScale(CGAffineTransformMakeRotation(angle),
                                                       scale, scale);
    }];
  }];
}



- (void)startVideoStatsTimer {
  [_videoStatsTimer invalidate];
  _videoStatsTimer = [NSTimer timerWithTimeInterval:0.30 target:self
                                            selector:@selector(updateVideoStats:)
                                            userInfo:nil repeats:YES];
  [[NSRunLoop mainRunLoop] addTimer:_videoStatsTimer forMode:NSRunLoopCommonModes];
  [self updateVideoStats:nil];
}

- (void)updateVideoStats:(NSTimer *)timer {
  (void)timer;
  DBVideoStats stats = DBVideoStatsMake(NO, 0, 0, 0);
  if ([_activeVideoTransport isEqualToString:@"H.264 LOW-LAT"] && _lowLatency)
    stats = [_lowLatency videoStats];
  else if ([_activeVideoTransport isEqualToString:@"HLS H.264"] && _h264)
    stats = [_h264 videoStats];
  else if ([_activeVideoTransport isEqualToString:@"MJPEG"] && _streamer)
    stats = [_streamer videoStats];

  if (_videoStrategyPlaying && _videoStrategyIndex >= 0 &&
      _videoStrategyIndex < (NSInteger)[_videoStrategies count]) {
    NSDictionary *strategy = [_videoStrategies objectAtIndex:(NSUInteger)_videoStrategyIndex];
    NSInteger stallMs = [[strategy objectForKey:@"stall_timeout_ms"] integerValue];
    if (stallMs < 1000) stallMs = 3000;
    CFAbsoluteTime last = 0;
    if ([_currentVideoStrategy isEqualToString:@"h264_low_latency"] && _lowLatency)
      last = [_lowLatency lastFrameAt];
    else if ([_currentVideoStrategy isEqualToString:@"h264_hls"] && _h264)
      last = [_h264 lastFrameAt];
    else if ([_currentVideoStrategy isEqualToString:@"mjpeg"] && _streamer)
      last = [_streamer lastFrameAt];
    if (last > 0 && (CFAbsoluteTimeGetCurrent() - last) * 1000.0 > stallMs) {
      [self advanceVideoStrategy:@"frame_stall"];
      return;
    }
  }

  // Unobtrusive debug line (spec §5.2): codec/strategy, end-to-end latency,
  // jitter, fps, dropped. Tapping it hides it, remembered per device.
  NSString *transport = [_activeVideoTransport length] ? _activeVideoTransport : @"NO STREAM";
  NSString *strategy = [_currentVideoStrategy length] ? _currentVideoStrategy : @"-";
  NSUInteger dropped = _lowLatency ? [_lowLatency droppedFrames] : 0;
  _videoStatsLabel.hidden = _debugLineHidden;
  if (stats.valid) {
    _videoStatsLabel.text = [NSString stringWithFormat:
        @"  %@/%@ · %ld ms · jit %ld ms · %.1f fps · drop %lu  ", transport, strategy,
        (long)stats.latencyMs, (long)stats.jitterMs, (double)stats.framesPerSecond,
        (unsigned long)dropped];
    _videoStatsLabel.textColor = stats.latencyMs < 800
        ? [UIColor colorWithWhite:1 alpha:0.68]
        : [UIColor colorWithRed:1.0 green:0.65 blue:0.45 alpha:0.85];
  } else {
    _videoStatsLabel.text = [NSString stringWithFormat:
        @"  %@/%@ · -- ms · jit -- ms · -- fps · drop %lu  ", transport, strategy,
        (unsigned long)dropped];
    _videoStatsLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
  }
  [self publishVideoRuntime:stats force:NO];
}

- (void)publishVideoRuntime:(DBVideoStats)stats force:(BOOL)force {
  NSString *label = [_activeVideoTransport length] ? _activeVideoTransport : @"NO STREAM";
  BOOL active = self.superview != nil && ![label isEqualToString:@"INACTIVE"];
  NSString *state = @"loading";
  if (!active)
    state = @"inactive";
  else if ([label isEqualToString:@"CANCELLED"])
    state = @"cancelled";
  else if ([label hasSuffix:@" PAUSE"])
    state = @"paused";
  else if ([label isEqualToString:@"NO STREAM"])
    state = @"unavailable";
  else if (_videoStrategyPlaying)
    state = @"playing";

  NSString *transport = @"none";
  NSString *codec = @"none";
  NSString *compositor = @"none";
  if ([_currentVideoStrategy isEqualToString:@"h264_low_latency"] ||
      [label isEqualToString:@"H.264 LOW-LAT"]) {
    transport = @"fmp4_direct";
    codec = @"h264";
    compositor = _lowLatency ? [_lowLatency presentationMode] : @"uikit_bgra_sibling";
  } else if ([_currentVideoStrategy isEqualToString:@"h264_hls"] ||
             [label isEqualToString:@"HLS H.264"]) {
    transport = @"hls";
    codec = @"h264";
    compositor = @"avplayer_layer";
  } else if ([_currentVideoStrategy isEqualToString:@"mjpeg"] ||
             [label rangeOfString:@"MJPEG"].location != NSNotFound) {
    transport = @"mjpeg";
    codec = @"mjpeg";
    compositor = @"uikit_image";
  } else if ([label rangeOfString:@"SNAPSHOT"].location != NSNotFound) {
    transport = @"snapshot";
    codec = @"jpeg";
    compositor = @"uikit_image";
  }

  NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%@|%d|%d", state,
      transport, codec, compositor, active ? 1 : 0, _safeMode ? 1 : 0];
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  BOOL changed = ![_lastMediaRuntimeSignature isEqualToString:signature];
  if (!force && !changed && now - _lastMediaRuntimePublishAt < 2.0) return;
  _lastMediaRuntimeSignature = [signature copy];
  _lastMediaRuntimePublishAt = now;

  NSUInteger decoded = _lowLatency ? [_lowLatency decodedFrames] : 0;
  NSUInteger displayed = _lowLatency ? [_lowLatency displayedFrames] : 0;
  NSUInteger dropped = _lowLatency ? [_lowLatency droppedFrames] : 0;
  NSMutableDictionary *runtime = [NSMutableDictionary dictionaryWithDictionary:@{
    @"schema_version" : @1,
    @"state" : state,
    @"transport" : transport,
    @"codec" : codec,
    @"compositor" : compositor,
    @"decoded_frames" : @(decoded),
    @"displayed_frames" : @(displayed),
    @"dropped_frames" : @(dropped),
    @"active" : @(active),
    @"safe_mode" : @(_safeMode),
    @"updated_at_ms" : @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
  }];
  if (stats.valid) {
    [runtime setObject:@(MAX(0, stats.latencyMs)) forKey:@"latency_ms"];
    [runtime setObject:@(MAX(0, stats.jitterMs)) forKey:@"jitter_ms"];
    [runtime setObject:@((NSInteger)MAX(0, stats.framesPerSecond * 10.0f))
                 forKey:@"fps_x10"];
  }
  [_core setRuntimeStatusSection:@"media_playback" value:runtime];
}



- (void)restartAutoClose {
  if (_monitorOnly) {
    [_autoCloseTimer invalidate];
    _autoCloseTimer = nil;
    _autoCloseTimerForCancelled = NO;
    _autoCloseDeadlineMs = 0;
    return;
  }
  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  long long deadlineMs = 0;
  if (_cancelled) {
    deadlineMs = nowMs + (long long)(kCancelledCloseS * 1000.0);
  } else if (_callExpiresAtMs > 0) {
    deadlineMs = _callExpiresAtMs;
  } else {
    // Legacy callers that predate schema-v2 have no Core deadline. Keep the
    // old bounded fallback, but schema-v2 calls always use expires_at_ms.
    deadlineMs = nowMs + (long long)(kLegacyAutoCloseS * 1000.0);
  }
  // Snapshot/config refreshes can arrive several times per second. They must
  // not keep extending the same ringing/cancelled deadline indefinitely.
  // Only a real transition into or out of the cancelled state replaces it.
  if (_autoCloseTimer && [_autoCloseTimer isValid] &&
      _autoCloseTimerForCancelled == _cancelled &&
      llabs(_autoCloseDeadlineMs - deadlineMs) < 100)
    return;
  [_autoCloseTimer invalidate];
  _autoCloseTimerForCancelled = _cancelled;
  _autoCloseDeadlineMs = deadlineMs;
  NSTimeInterval remaining = MAX(0.01, (deadlineMs - nowMs) / 1000.0);
  _autoCloseTimer = [NSTimer timerWithTimeInterval:remaining
                                             target:self
                                           selector:@selector(autoCloseTimerFired:)
                                           userInfo:nil
                                            repeats:NO];
  [[NSRunLoop mainRunLoop] addTimer:_autoCloseTimer forMode:NSRunLoopCommonModes];
}

- (void)autoCloseTimerFired:(NSTimer *)timer {
  if (timer != _autoCloseTimer) return;
  _autoCloseTimer = nil;
  _autoCloseDeadlineMs = 0;
  [self closeSelf];
}

- (void)handleCallCancelled:(NSDictionary *)ev {
  if (_monitorOnly) return;
  NSString *door = [DBConfigUtil evStr:ev key:@"door"];
  if ([door length] > 0 && [_door length] > 0 && ![door isEqualToString:_door]) return;
  if (_inCall) return;
  _cancelled = YES;
  // Keep the cancelled banner visible briefly, but immediately release every
  // decoder/network path. A later status refresh must not restart the stream.
  ++_snapshotGen;
  [self stopVideoPlayers];
  _liveView.image = nil;
  _pendingMjpegFrame = nil;
  _activeVideoTransport = @"CANCELLED";
  _noVideoLabel.hidden = NO;
  _answerButton.enabled = NO;
  _monitorButton.enabled = NO;
  [self updateVideoStats:nil];
  _statusLabel.text = [_texts ts:@"ring.cancelled"];
  _statusLabel.font = [UIFont boldSystemFontOfSize:24];
  _statusLabel.textColor = [UIColor whiteColor];
  _statusLabel.backgroundColor = [UIColor colorWithRed:0.78 green:0.14 blue:0.12 alpha:1];
  _statusLabel.textAlignment = NSTextAlignmentCenter;
  _statusLabel.layer.cornerRadius = 8;
  _statusLabel.clipsToBounds = YES;
  [self setNeedsLayout];
  [self restartAutoClose];
  NSLog(@"[doorbell] call cancelled: chime and video stopped; banner remains for %.0fs",
        kCancelledCloseS);
}

- (void)handlePurposeSelected:(NSDictionary *)ev {
  NSString *door = [DBConfigUtil evStr:ev key:@"door"];
  if ([door length] > 0 && [_door length] > 0 && ![door isEqualToString:_door]) return;
  NSString *purpose = [DBConfigUtil evStr:ev key:@"purpose"];
  if ([purpose length] == 0) return;
  NSString *lang = [DBConfigUtil evStr:ev key:@"visitor_lang"];
  if ([lang length] == 0) lang = _visitorLang;
  [self refreshPurpose:purpose lang:lang
          stageRevision:[DBConfigUtil intVal:ev path:@"stage_revision" def:_stageRevision]];
}

- (void)closeSelf {
  [_autoCloseTimer invalidate];
  _autoCloseTimer = nil;
  _autoCloseTimerForCancelled = NO;
  _autoCloseDeadlineMs = 0;
  [_router closeIncomingAnimated:YES];
}

- (void)onScreenWillAppear {
  [self startVideoStatsTimer];
  if (!_boot.diagnosticDumps) return;
  // Support-only snapshot. It is opt-in because a full-window bitmap can be a
  // meaningful fraction of the original iPad's available memory.
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
  ++_sipActionGen;
  [_autoCloseTimer invalidate];
  _autoCloseTimer = nil;
  _autoCloseDeadlineMs = 0;
  [_videoStatsTimer invalidate];
  _videoStatsTimer = nil;
  [self stopVideoPlayers];
  _activeVideoTransport = @"INACTIVE";
  [self updateVideoStats:nil];
  // Always stop the router-owned session, including the gap before delayed answer.
  [_router sipHangup];
  [self reportLifecycleEndedIfNeeded];
  _answerPending = NO;
  _awaitingSupersededIdle = NO;
  _sipMode = @"";
  _inCall = NO;
}

- (void)releaseMediaForMemoryPressure {
  [self stopVideoPlayers];
  _liveView.image = nil;
  _pendingMjpegFrame = nil;
  _activeVideoTransport = @"MEMORY PAUSE";
  _noVideoLabel.hidden = NO;
  [self updateVideoStats:nil];
}

- (void)enterSafeMode {
  _safeMode = YES;
  [self releaseMediaForMemoryPressure];
  if (self.superview) [self startVideo:_incomingStreamUrl];
}

- (void)exitSafeMode {
  if (!_safeMode) return;
  _safeMode = NO;
  if (self.superview) [self startVideo:_incomingStreamUrl];
}

- (NSDictionary *)safeModeMediaStatus {
  BOOL mjpeg = [_incomingStreamUrl length] > 0;
  BOOL snapshot = [_mediaSource.snapshotURL length] > 0;
  NSString *fallback = mjpeg ? @"mjpeg" : (snapshot ? @"snapshot" : @"none");
  return @{
    @"mode" : (mjpeg || snapshot) ? @"low_resolution_jpeg" : @"audio_only",
    @"fallback" : fallback,
    @"mjpeg_available" : @(mjpeg),
    @"snapshot_available" : @(snapshot),
    @"h264_decode" : @NO,
    @"reason" : (mjpeg || snapshot) ? @"safe_mode" :
        @"safe_mode_no_jpeg_fallback",
  };
}

- (void)suspendMediaForBackground {
  [self stopVideoPlayers];
  _liveView.image = nil;
  _pendingMjpegFrame = nil;
  _activeVideoTransport = @"BACKGROUND PAUSE";
  _noVideoLabel.hidden = NO;
  [self updateVideoStats:nil];
}

- (void)resumeMediaAfterBackground {
  if (!self.superview) return;
  [self startVideo:_incomingStreamUrl];
}


- (void)onAnswer {
  if (_peerHost == nil) return;
  if (_inCall) {
    [_router sipHangup];
    [self reportLifecycleEndedIfNeeded];
    _sipMode = @"";
    [self closeSelf];
    return;
  }
  _answerPending = YES;
  _answerButton.enabled = NO;
  [_autoCloseTimer invalidate];
  if ([_sipMode isEqualToString:@"monitor"]) {

    [_router sipHangup];
    _sipMode = @"";
    NSInteger gen = ++_sipActionGen;
    __weak DBIncomingScreen *wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      DBIncomingScreen *s = wself;
      if (!s || !s.superview || s->_sipActionGen != gen) return;
      [s placeAnswerCall];
    });
    return;
  }
  [self placeAnswerCall];
}

- (void)placeAnswerCall {
  _answerPending = NO;
  _lifecycleAnswered = NO;
  _lifecycleEnded = NO;
  _sipMode = @"answer";
  [self startSip:@"answer"];
}

- (void)onMonitor {
  if (_peerHost == nil) return;
  // モニター is a stateful ON/OFF toggle for door audio; the answered call is
  // never torn down by it.
  if (_monitorAudioOn && [_sipMode isEqualToString:@"monitor"]) {
    [_router sipHangup];
    _sipMode = @"";
    _monitorAudioOn = NO;
    _hintLabel.hidden = YES;
    [self applyContent];
    return;
  }
  if ([_sipMode length] > 0 && ![_sipMode isEqualToString:@"monitor"]) return;
  _sipMode = @"monitor";
  _monitorAudioOn = YES;
  [self startSip:@"monitor"];
  _hintLabel.text = [_texts ts:@"ring.monitoring"];
  _hintLabel.hidden = NO;
  [self applyContent];
}

- (void)beginMonitorAudio {
  if (_monitorOnly) [self onMonitor];
}

- (void)startSip:(NSString *)mode {

  [_router sipStart:_peerHost port:(int)_directPort mode:mode];
  _openButton.enabled = YES;
}

- (void)onOpenDoor {
  // db_core_open_door publishes the configured unlock action; -3 means nothing
  // is configured anywhere. Shown but unconfigured must explain itself, because
  // a silent no-op reads as a broken lock (spec §5.2).
  int status = [_core openDoor:_door];
  _hintLabel.text = (status == 0) ? [_texts ts:@"ring.unlock_sent"]
                                  : [_texts ts:@"ring.unlock_unconfigured"];
  _hintLabel.hidden = NO;
}

- (void)onIgnore {
  [self closeSelf];
}

- (void)onReply:(UIButton *)sender {
  if (_inCall) return;
  NSString *rid = sender.accessibilityIdentifier;
  BOOL accepted = [_core quickReplyV2:rid door:_door callID:_callID
                        stageRevision:_stageRevision];
  _hintLabel.text = accepted
      ? [_texts t:@"reply.sent", (sender.currentTitle ?: @""), nil]
      : [_texts ts:@"reply.failed"];
  _hintLabel.hidden = NO;
  if (accepted && !_inCall) [self restartAutoClose];
}



- (void)sipStateChanged:(DBMiniSipState)state {
  if (!self.superview) return;
  if (state == DBMiniSipInCall) {
    if (![_sipMode isEqualToString:@"answer"]) return;
    _inCall = YES;
    [self buildReplyButtons];
    if (!_lifecycleAnswered) {
      _lifecycleAnswered = [_core reportCallAnsweredV2:_door callID:_callID
                                        stageRevision:_stageRevision];
    }
    [_autoCloseTimer invalidate];
    _answerButton.enabled = YES;
    [_answerButton setTitle:[_texts ts:@"incall.end"] forState:UIControlStateNormal];
    _statusLabel.text = [_texts ts:@"incall.title"];
    _hintLabel.hidden = YES;
    [self applySemanticStyles];
  } else if (state == DBMiniSipEnded) {
    if (_awaitingSupersededIdle) {
      [self handleSupersededSipIdle];
      return;
    }
    BOOL wasAnswer = [_sipMode isEqualToString:@"answer"];
    if (wasAnswer) [self reportLifecycleEndedIfNeeded];
    _inCall = NO;
    _answerPending = NO;
    if (wasAnswer) {
      [self closeSelf];
    } else {
      // Restore retry controls after monitor signaling or audio setup fails.
      _sipMode = @"";
      _hintLabel.hidden = YES;
    }
  }
}

- (void)reportLifecycleEndedIfNeeded {
  if (!_inCall || ![_sipMode isEqualToString:@"answer"] || !_lifecycleAnswered ||
      _lifecycleEnded || [_callID length] == 0) return;
  _lifecycleEnded = [_core reportCallEndedV2:_door callID:_callID
                                stageRevision:_stageRevision reason:@"sip_ended"];
}

- (void)handleReplyEvent:(NSDictionary *)ev {
  if (_monitorOnly) return;  // Another resident response must not close active monitoring.
  NSString *door = [DBConfigUtil evStr:ev key:@"door"];
  if ([door length] > 0 && [_door length] > 0 && ![door isEqualToString:_door]) return;
  // Close after a visitor-side reply unless an established call remains active.
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

// The door camera's aspect drives the video slot: a portrait stream is shown
// portrait, letterboxed, never cropped or stretched (spec §5.1). The image's
// own size wins; before the first frame the reported sensor rotation decides.
- (CGSize)videoContentSize {
  UIImage *frame = _liveView.image;
  if (frame != nil && frame.size.width > 0 && frame.size.height > 0) return frame.size;
  BOOL rotatedPortrait = (_videoRotation == 90 || _videoRotation == 270);
  return rotatedPortrait ? CGSizeMake(3, 4) : CGSizeMake(4, 3);
}

- (void)layoutVideoInSlot:(CGRect)slot {
  CGRect frame = DBAspectFitRect(slot, [self videoContentSize]);
  _liveView.frame = frame;
  _noVideoLabel.frame = frame;
  // The debug line sits inside the video slot's bottom edge and never covers
  // the picture's centre.
  CGFloat statsWidth = MIN(CGRectGetWidth(slot) - 16, 460);
  CGRect stats = CGRectMake(CGRectGetMinX(slot) + 8,
                            CGRectGetMaxY(slot) - 30, statsWidth, 24);
  _videoStatsLabel.frame = stats;
  _debugLineTap.frame = CGRectInset(stats, -6, -6);
}

- (NSArray *)visibleControlButtons {
  NSMutableArray *buttons = [NSMutableArray array];
  [buttons addObject:_monitorButton];
  if (!_answerButton.hidden) [buttons addObject:_answerButton];
  if (!_micButton.hidden) [buttons addObject:_micButton];
  if (!_openButton.hidden) [buttons addObject:_openButton];
  if ([_replyButtons count] > 0) [buttons addObject:_repliesButton];
  [buttons addObject:_ignoreButton];
  return buttons;
}

- (void)layoutControlRow:(CGRect)row {
  NSArray *buttons = [self visibleControlButtons];
  NSUInteger count = [buttons count];
  if (count == 0) return;
  CGFloat gap = 10;
  CGFloat width = (CGRectGetWidth(row) - gap * (count - 1)) / count;
  CGFloat x = CGRectGetMinX(row);
  for (UIButton *button in buttons) {
    button.frame = CGRectMake(x, CGRectGetMinY(row), width, CGRectGetHeight(row));
    x += width + gap;
  }
  for (UIButton *button in @[ _monitorButton, _answerButton, _micButton, _openButton,
                              _repliesButton, _ignoreButton ]) {
    if (![buttons containsObject:button]) button.frame = CGRectZero;
  }
}

- (void)layoutAdminQr:(CGSize)size {
  BOOL show = ([_adminHosts count] > 0);
  _adminQrButton.hidden = !show;
  _adminUrlLabel.hidden = !show;
  if (!show) {
    _adminQrButton.frame = CGRectZero;
    _adminUrlLabel.frame = CGRectZero;
    return;
  }
  // Small, in the corner, same component as the dashboard footer.
  CGFloat side = 84;
  _adminQrButton.frame = CGRectMake(size.width - side - 14, 14, side, side);
  _adminUrlLabel.frame = CGRectMake(size.width - side - 30, 14 + side + 2, side + 16, 28);
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  [self layoutQrPicker:size];
  _noticeDialog.frame = self.bounds;
  BOOL portrait = size.height > size.width;
  CGFloat margin = 20;
  CGFloat controlHeight = 62;
  CGFloat gap = 14;

  _titleLabel.backgroundColor = [UIColor clearColor];
  _titleLabel.layer.cornerRadius = 0;
  _statusLabel.backgroundColor = _cancelled ? _statusLabel.backgroundColor
                                            : [UIColor clearColor];
  _hintLabel.backgroundColor = [UIColor clearColor];
  _titleLabel.font = [UIFont boldSystemFontOfSize:portrait ? 26 : 30];
  _titleLabel.numberOfLines = 2;

  [self layoutAdminQr:size];
  CGFloat headerRight = _adminQrButton.hidden ? size.width - margin
                                              : CGRectGetMinX(_adminQrButton.frame) - 12;

  // Header: notice chip, door name, then the fixed-height purpose slot.
  CGFloat headerY = 16;
  if (_noticeChip.hidden) {
    _noticeChip.frame = CGRectZero;
  } else {
    CGSize chipFit = [_noticeChip sizeThatFits:CGSizeMake(260, 34)];
    CGFloat chipWidth = MIN(240, MAX(120, chipFit.width + 14));
    _noticeChip.frame = CGRectMake(margin, headerY, chipWidth, 34);
    headerY += 42;
  }
  _titleLabel.frame = CGRectMake(margin, headerY, MAX(0, headerRight - margin), 44);
  headerY += 48;

  // The purpose slot keeps its height even while empty, so the layout never
  // jumps when the visitor's purpose arrives after the ring (spec §5.2).
  CGFloat purposeSlotHeight = _monitorOnly ? 0 : 38;
  if (purposeSlotHeight > 0) {
    _purposeBadge.frame = CGRectMake(margin, headerY, MIN(320, size.width - 2 * margin), 34);
    _langBadge.frame = CGRectMake(margin + MIN(320, size.width - 2 * margin) + 10, headerY,
                                  80, 34);
    headerY += purposeSlotHeight + 6;
  } else {
    _purposeBadge.frame = CGRectZero;
    _langBadge.frame = CGRectZero;
  }

  CGFloat contentTop = headerY;
  CGFloat bottom = size.height - margin;
  CGFloat controlY = bottom - controlHeight;
  CGFloat statusHeight = _cancelled ? 52 : 28;

  BOOL sideBySide = !portrait && size.width >= 700 && !_monitorOnly &&
                    (_repliesVisible && [_replyButtons count] > 0);
  CGFloat replyWidth = sideBySide ? MIN(320, size.width * 0.32) : 0;
  CGFloat videoRight = size.width - margin - (sideBySide ? replyWidth + gap : 0);
  CGRect videoSlot = CGRectMake(margin, contentTop, MAX(80, videoRight - margin),
                                MAX(80, controlY - contentTop - gap - statusHeight - 8));
  [self layoutVideoInSlot:videoSlot];

  _statusLabel.frame = CGRectMake(margin, CGRectGetMaxY(videoSlot) + 6,
                                  MAX(0, videoRight - margin), statusHeight);
  _hintLabel.frame = CGRectMake(margin, CGRectGetMaxY(_statusLabel.frame),
                                MAX(0, videoRight - margin), 24);
  _hintLabel.numberOfLines = 1;

  // Quick replies: a column beside the video when there is room, otherwise a
  // scrollable stack over the lower half. The control row never moves.
  BOOL showReplies = _repliesVisible && [_replyButtons count] > 0;
  if (!showReplies) {
    _replyStack.frame = CGRectZero;
    for (UIButton *button in _replyButtons) button.frame = CGRectZero;
  } else if (sideBySide) {
    CGFloat x = videoRight + gap;
    CGFloat y = 0;
    for (UIButton *button in _replyButtons) {
      button.frame = CGRectMake(0, y, replyWidth, 54);
      y += 54 + 10;
    }
    _replyStack.frame = CGRectMake(x, contentTop, replyWidth,
                                   MAX(0, controlY - contentTop - gap));
  } else {
    CGFloat stackWidth = size.width - 2 * margin;
    CGFloat y = 0;
    for (UIButton *button in _replyButtons) {
      button.frame = CGRectMake(0, y, stackWidth, 50);
      y += 50 + 8;
    }
    CGFloat stackHeight = MIN(y, MAX(60, controlY - contentTop - gap));
    _replyStack.frame = CGRectMake(margin, controlY - gap - stackHeight, stackWidth,
                                   stackHeight);
  }

  [self layoutControlRow:CGRectMake(margin, controlY, size.width - 2 * margin,
                                    controlHeight)];
}

@end
