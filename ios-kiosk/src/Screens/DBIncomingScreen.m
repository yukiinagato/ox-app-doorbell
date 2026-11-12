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
#import "../Core/DBCallReturnCountdown.h"
#import "../Core/DBNoticeModel.h"
#import "../Core/DBPurposeModel.h"
#import "../Core/DBUiTheme.h"
#import "../Support/DBAppDelegate.h"
#import "DBChrome.h"
#import "DBNoticeDialog.h"
#import "DBRouter.h"
#import "DBWidgets.h"

void DBH264Dbg(NSString *fmt, ...);

// The debug line is remembered per device.
static NSString *const kDebugLineHiddenKey = @"DBIncomingDebugLineHidden";

static const CGFloat kListRowHeight = 50;
static const CGFloat kListWidth = 380;
static const NSUInteger kListMaxVisibleRows = 8;
static const CGFloat kPrimaryRowHeight = 64;
static const CGFloat kAnswerColumnHeight = 72;
static const CGFloat kReplyColumnHeight = 52;
static const CGFloat kSecondaryHeight = 44;
static const CGFloat kAdminQrSide = 84;

typedef enum {
  DBIncomingListNone = 0,
  DBIncomingListReplies,
  DBIncomingListAdminAddresses,
} DBIncomingListKind;

static BOOL DBSameString(NSString *a, NSString *b) {
  return (a == b) || [a isEqualToString:b];
}

// Popover content on the iPad idiom: a plain table of one-tap choices.
@interface DBIncomingListController : UIViewController <UITableViewDataSource,
                                                        UITableViewDelegate>
@property(nonatomic, copy) NSArray *titles;
@property(nonatomic, copy) NSString *headerTitle;
// The row carrying a checkmark, or -1.
@property(nonatomic, assign) NSInteger checkedIndex;
// An administrator's semantic override for the rows, or nil for the stock look.
@property(nonatomic, strong) NSDictionary *style;
@property(nonatomic, copy) void (^onSelect)(NSInteger index);
@end

@implementation DBIncomingListController

- (void)loadView {
  UITableView *table = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, kListWidth, 300)
                                                    style:UITableViewStylePlain];
  table.dataSource = self;
  table.delegate = self;
  table.rowHeight = kListRowHeight;
  self.view = table;
}

- (void)dealloc {
  if ([self isViewLoaded]) {
    UITableView *table = (UITableView *)self.view;
    table.dataSource = nil;
    table.delegate = nil;
  }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  (void)tableView;
  (void)section;
  return (NSInteger)[_titles count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  (void)tableView;
  (void)section;
  return [_headerTitle length] > 0 ? _headerTitle : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"choice"];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                  reuseIdentifier:@"choice"];
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
  }
  cell.textLabel.text = [_titles objectAtIndex:(NSUInteger)indexPath.row];
  cell.accessoryType = indexPath.row == _checkedIndex ? UITableViewCellAccessoryCheckmark
                                                      : UITableViewCellAccessoryNone;
  return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
  (void)tableView;
  (void)indexPath;
  if (!_style) return;
  UIColor *background = [DBSemanticStyle colorInStyle:_style key:@"background" fallback:nil];
  UIColor *foreground = [DBSemanticStyle colorInStyle:_style key:@"foreground" fallback:nil];
  CGFloat fontScale = [DBSemanticStyle numberInStyle:_style key:@"font_scale" fallback:0
                                             minimum:0.75 maximum:2];
  if (background) cell.backgroundColor = background;
  if (foreground) cell.textLabel.textColor = foreground;
  if (fontScale > 0) cell.textLabel.font = [UIFont boldSystemFontOfSize:17 * fontScale];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:NO];
  // The handler may let go of this controller; the local keeps the block alive until it returns.
  void (^handler)(NSInteger) = _onSelect;
  if (handler) handler(indexPath.row);
}

@end

@interface DBIncomingScreen () <UIActionSheetDelegate, UIAlertViewDelegate,
                                UIScrollViewDelegate>
- (void)startVideoStatsTimer;
- (void)updateVideoStats:(NSTimer *)timer;
- (void)publishVideoRuntime:(DBVideoStats)stats force:(BOOL)force;
- (void)startVideoOrientationPolling;
- (void)pollVideoOrientation:(NSTimer *)timer;
- (void)updateAdminAddressesFromPeer:(NSDictionary *)peer;
- (void)updateAdminQr;
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
- (void)dismissChoiceList;
- (void)resetVideoZoom;
- (void)rebuildReplies;
- (void)sendReplyAtIndex:(NSInteger)index;
- (void)chooseAdminAddressAtIndex:(NSInteger)index;
@end

@implementation DBIncomingScreen {
  NSMutableDictionary *_visits;
  NSMutableArray *_visitOrder;
  NSMutableDictionary *_retiredVisits;
  NSMutableDictionary *_roomEvents;
  UIScrollView *_visitPanel;
  NSMutableArray *_visitButtons;
  NSString *_visitSignature;
  BOOL _selectingVisit;
  NSString *_touchVisit;
  NSNumber *_touchRoomVersion;
  NSDictionary *_pendingTakeoverRequest;
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  NSString *_door;
  NSString *_purpose;
  NSString *_visitorLang;
  NSString *_callID;
  NSInteger _stageRevision;
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
  BOOL _mjpegAvailabilityDisabled;
  BOOL _mediaStandbyReady;  // Profile turned the MJPEG layer off.
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
  NSTimer *_videoStatsTimer;
  CFAbsoluteTime _lastMediaRuntimePublishAt;
  NSString *_lastMediaRuntimeSignature;
  NSTimer *_videoOrientationTimer;
  BOOL _videoOrientationBusy;
  NSInteger _videoRotation;
  NSDictionary *_appearanceConfig;
  NSDictionary *_appearanceDisplay;
  NSString *_appearanceNodeId;
  CFAbsoluteTime _fastStartupUntil;
  BOOL _snapshotDeferred;
  NSInteger _snapshotGen;  // Discards stale background snapshots.
  NSString *_activeVideoTransport;
  NSArray *_adminHosts;
  NSString *_adminQrUrl;   // The URL the cached QR bitmap encodes.
  NSInteger _adminHostIndex;
  NSInteger _adminQrGen;

  // UI
  DBNavBar *_navBar;
  UIBarButtonItem *_noticeItem;
  // The zoomable video slot: the scroll view fills the slot, its one zooming subview is the
  // letterboxed picture rect, and the live view (the MJPEG/snapshot image and the container the
  // H.264 players attach to) fills that. The sensor rotation stays a transform on the live view,
  // so it never collides with the zoom transform the scroll view puts on its parent.
  UIScrollView *_videoScroll;
  UIView *_zoomContent;
  CGSize _zoomSlotSize;
  CGSize _zoomPictureSize;
  UIImageView *_liveView;
  UILabel *_noVideoLabel;
  UILabel *_videoStatsLabel;
  UILabel *_titleLabel;
  UILabel *_purposeBadge;
  UILabel *_langBadge;
  UILabel *_statusLabel;
  UILabel *_hintLabel;
  UILabel *_noticeLabel;
  UIButton *_answerButton;
  UIButton *_monitorButton;
  UIButton *_openButton;
  UIButton *_ignoreButton;
  DBCallReturnCountdown *_returnCountdown;
  NSTimer *_returnTimer;
  UIButton *_countdownButton;
  UIButton *_micButton;
  UIButton *_repliesButton;
  DBNoticeDialog *_noticeDialog;
  DBUiPalette *_palette;
  NSDictionary *_display;   // status.display: core-resolved appearance and theme.
  NSDictionary *_doorUnlock;  // status.doors.<id>.unlock
  BOOL _monitorAudioOn;
  BOOL _micMuted;
  BOOL _debugLineHidden;
  BOOL _unlockConfigured;
  BOOL _unlockVisible;
  // YES while an administrator's ring.title override colours the headline instead of region ink.
  BOOL _titleStyled;
  UIButton *_debugLineTap;
  UIButton *_adminQrButton;
  UILabel *_adminUrlLabel;

  // Quick replies offered for the call on screen, in configuration order.
  NSArray *_replyIds;
  NSArray *_replyTitles;
  NSDictionary *_replyStyle;  // reply.button override, or nil.
  // The choice list on screen: a popover on the iPad idiom, an action sheet elsewhere. A
  // dismissed popover stays referenced until the next one replaces it, because its content may
  // still be running the selection handler that dismissed it.
  DBIncomingListKind _listKind;
  UIPopoverController *_listPopover;
  __weak UIActionSheet *_listSheet;
  CGSize _laidOutSize;
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _visits = [[NSMutableDictionary alloc] init];
    _visitOrder = [[NSMutableArray alloc] init];
    _retiredVisits = [[NSMutableDictionary alloc] init];
    _roomEvents = [[NSMutableDictionary alloc] init];
    _visitButtons = [[NSMutableArray alloc] init];
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
    _replyIds = @[];
    _replyTitles = @[];
    _adminHosts = @[];
    _debugLineHidden = [[NSUserDefaults standardUserDefaults] boolForKey:kDebugLineHiddenKey];
    _returnCountdown = [[DBCallReturnCountdown alloc] init];
    [self buildUi];
  }
  return self;
}

- (NSString *)screenName {
  return @"incoming";
}

#pragma mark - UI

- (UILabel *)detailLabelWithFont:(UIFont *)font lines:(NSInteger)lines {
  UILabel *label = [[UILabel alloc] init];
  label.font = font;
  label.textColor = [UIColor colorWithWhite:1 alpha:0.7];
  label.numberOfLines = lines;
  [self addSubview:label];
  return label;
}

- (UIButton *)actionButton:(SEL)action {
  UIButton *button = DBChromeButton(nil, 18);
  [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:button];
  return button;
}

- (void)buildUi {
  // The call screen keeps a near-black ground so the picture reads well; only the video, the
  // debug line, the QR plate, and the labels on that ground are drawn by this screen.
  self.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1];

  _videoScroll = [[UIScrollView alloc] init];
  _videoScroll.delegate = self;
  _videoScroll.minimumZoomScale = 1;
  _videoScroll.maximumZoomScale = 4;
  _videoScroll.bouncesZoom = YES;
  _videoScroll.showsHorizontalScrollIndicator = NO;
  _videoScroll.showsVerticalScrollIndicator = NO;
  _videoScroll.scrollsToTop = NO;
  // The whole slot is the video area, so a letterboxed picture has no stray bands beside it.
  _videoScroll.backgroundColor = [UIColor blackColor];
  [self addSubview:_videoScroll];
  UITapGestureRecognizer *doubleTap =
      [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onVideoDoubleTap:)];
  doubleTap.numberOfTapsRequired = 2;
  [_videoScroll addGestureRecognizer:doubleTap];

  _zoomContent = [[UIView alloc] init];
  [_videoScroll addSubview:_zoomContent];

  _liveView = [[UIImageView alloc] init];
  _liveView.contentMode = UIViewContentModeScaleAspectFit;
  _liveView.backgroundColor = [UIColor blackColor];
  [_zoomContent addSubview:_liveView];

  _noVideoLabel = [[UILabel alloc] init];
  _noVideoLabel.font = [UIFont systemFontOfSize:22];
  _noVideoLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
  _noVideoLabel.textAlignment = NSTextAlignmentCenter;
  [self addSubview:_noVideoLabel];

  _videoStatsLabel = [[UILabel alloc] init];
  _videoStatsLabel.font = [UIFont fontWithName:@"Menlo-Bold" size:15];
  if (!_videoStatsLabel.font) _videoStatsLabel.font = [UIFont boldSystemFontOfSize:15];
  _videoStatsLabel.textColor = [UIColor colorWithRed:0.55 green:1.0 blue:0.65 alpha:1];
  _videoStatsLabel.layer.cornerRadius = 6;
  _videoStatsLabel.clipsToBounds = YES;
  _videoStatsLabel.adjustsFontSizeToFitWidth = YES;
  _videoStatsLabel.minimumFontSize = 11;
  _videoStatsLabel.numberOfLines = 1;
  _videoStatsLabel.accessibilityIdentifier = @"video_stream_stats";
  [self addSubview:_videoStatsLabel];

  // Tapping the debug line hides it; the choice is remembered per device.
  _debugLineTap = [UIButton buttonWithType:UIButtonTypeCustom];
  _debugLineTap.backgroundColor = [UIColor clearColor];
  [_debugLineTap addTarget:self action:@selector(onToggleDebugLine)
          forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_debugLineTap];

  _titleLabel = [self detailLabelWithFont:[UIFont boldSystemFontOfSize:24] lines:2];
  _titleLabel.textColor = [UIColor whiteColor];
  _titleLabel.lineBreakMode = NSLineBreakByWordWrapping;

  _purposeBadge = [self detailLabelWithFont:[UIFont boldSystemFontOfSize:17] lines:1];
  _purposeBadge.adjustsFontSizeToFitWidth = YES;
  _purposeBadge.minimumFontSize = 12;
  _purposeBadge.hidden = YES;

  _langBadge = [self detailLabelWithFont:[UIFont systemFontOfSize:17] lines:1];
  _langBadge.adjustsFontSizeToFitWidth = YES;
  _langBadge.minimumFontSize = 12;
  _langBadge.hidden = YES;

  _statusLabel = [self detailLabelWithFont:[UIFont systemFontOfSize:20] lines:1];
  _statusLabel.adjustsFontSizeToFitWidth = YES;
  _statusLabel.minimumFontSize = 12;

  _hintLabel = [self detailLabelWithFont:[UIFont systemFontOfSize:17] lines:2];
  _hintLabel.hidden = YES;

  _noticeLabel = [self detailLabelWithFont:[UIFont systemFontOfSize:15] lines:2];
  _noticeLabel.hidden = YES;

  _visitPanel = [[UIScrollView alloc] init];
  _visitPanel.hidden = YES;
  [self addSubview:_visitPanel];

  _answerButton = DBChromeFilledButton(24);
  [_answerButton addTarget:self action:@selector(onAnswer)
          forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_answerButton];

  _repliesButton = [self actionButton:@selector(onReplies)];
  _ignoreButton = [self actionButton:@selector(onIgnore)];
  _monitorButton = [self actionButton:@selector(onMonitor)];
  _openButton = [self actionButton:@selector(onOpenDoor)];
  _micButton = [self actionButton:@selector(onMic)];
  for (UIButton *button in @[_answerButton, _openButton])
    [button addTarget:self action:@selector(captureVisit) forControlEvents:UIControlEventTouchDown];

  // The remaining seconds are the button's title, so the number itself is the control that
  // stops the countdown.
  _countdownButton = [self actionButton:@selector(onCancelCountdown)];
  _countdownButton.hidden = YES;

  _adminQrButton = [UIButton buttonWithType:UIButtonTypeCustom];
  // An opaque white plate with a radius and padding: a QR drawn straight onto
  // dark video chrome is unreadable to a phone camera.
  _adminQrButton.backgroundColor = [UIColor whiteColor];
  _adminQrButton.layer.cornerRadius = 8;
  _adminQrButton.clipsToBounds = YES;
  _adminQrButton.contentEdgeInsets = UIEdgeInsetsMake(6, 6, 6, 6);
  _adminQrButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
  _adminQrButton.accessibilityIdentifier = @"admin_page_qr";
  [_adminQrButton addTarget:self action:@selector(onAdminQrTapped)
           forControlEvents:UIControlEventTouchUpInside];
  _adminQrButton.hidden = YES;
  [self addSubview:_adminQrButton];

  _adminUrlLabel = [self detailLabelWithFont:[UIFont systemFontOfSize:13] lines:0];
  _adminUrlLabel.lineBreakMode = NSLineBreakByCharWrapping;
  _adminUrlLabel.hidden = YES;

  [self clearLabelBackgrounds:self];
  _videoStatsLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];

  _navBar = [[DBNavBar alloc] init];
  [_navBar setRootTitle:@"" backTitle:nil onBack:nil];
  [self addSubview:_navBar.bar];
  _noticeItem = DBChromeBarItem(@"", self, @selector(onNoticeChip));
}


- (void)prewarmAppearanceWithStatus:(NSDictionary *)status {
  if (self.superview) return;
  NSDictionary *config = [_core lastConfig];
  NSString *node = [DBConfigUtil str:status path:@"node.id"];
  NSDictionary *display = [status objectForKey:@"display"];
  if (!config || ![node length]) return;
  if ([_appearanceConfig isEqual:config] && [_appearanceDisplay isEqual:display] &&
      [_appearanceNodeId isEqual:node]) return;
  _appearanceConfig = config; _appearanceDisplay = display; _appearanceNodeId = [node copy];
  _cfg = config; _display = display; _nodeId = [node copy];
  BOOL monitor = _monitorOnly, inCall = _inCall;
  _monitorOnly = NO; _inCall = NO;
  [self applyContent];
  [self layoutIfNeeded];
  _monitorOnly = monitor; _inCall = inCall;
}

- (void)prepareWithDoor:(NSString *)door purpose:(NSString *)purpose lang:(NSString *)lang
                 callID:(NSString *)callID stageRevision:(NSInteger)stageRevision
            expiresAtMs:(long long)expiresAtMs {
  if ([callID length] > 0 && [door length] > 0) {
    NSString *key = [NSString stringWithFormat:@"%@:%@", door, callID];
    NSInteger retired = [_retiredVisits objectForKey:key] ? [[_retiredVisits objectForKey:key] integerValue] : -1;
    if (stageRevision <= retired) return;
    NSDictionary *visit = @{ @"door":door, @"call_id":callID, @"purpose":purpose ?: @"",
        @"visitor_lang":lang ?: @"", @"stage_revision":@(stageRevision), @"expires_at_ms":@(expiresAtMs) };
    if (![_visits objectForKey:key]) [_visitOrder addObject:key];
    NSDictionary *old = [_visits objectForKey:key];
    if (!old || stageRevision >= [[old objectForKey:@"stage_revision"] integerValue]) [_visits setObject:visit forKey:key];
    if (!_selectingVisit && self.superview && [_callID length] > 0 &&
        (![_callID isEqual:callID] || ![_door isEqual:door])) { [self refreshVisits]; return; }
  }

  (void)expiresAtMs;
  ++_snapshotGen; _snapshotDeferred = NO; _fastStartupUntil = 0;
  ++_sipActionGen;
  [_router sipHangup];
  _sipMode = @"";
  _monitorOnly = NO;
  [self resetVideoZoom];
  _liveView.contentMode = UIViewContentModeScaleAspectFit;
  _selectedPeerId = nil;
  _selectedPeerName = nil;
  _adminHosts = @[];
  _adminHostIndex = 0;
  ++_adminQrGen;
  _adminQrUrl = nil;
  [_adminQrButton setImage:nil forState:UIControlStateNormal];
  _adminQrButton.hidden = YES;
  _adminUrlLabel.hidden = YES;
  [self dismissChoiceList];
  _door = [door copy];
  _purpose = [purpose copy];
  _visitorLang = [lang copy];
  _callID = [callID copy];
  _stageRevision = MAX(0, stageRevision);
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
  _mediaStandbyReady = NO;
  _answerButton.enabled = NO;
  _monitorButton.enabled = NO;
  _monitorAudioOn = NO;
  _micMuted = NO;
  // The page now closes itself on this countdown instead of the old fixed
  // auto-close, so a visitor cancelling no longer takes the live view away.
  [_returnCountdown startWithSeconds:[DBCallReturnCountdown defaultSeconds]];
  [self startReturnTimer];
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
  NSDictionary *cachedStatus = [_core lastStatus];
  NSDictionary *cachedPeer = [DBConfigUtil findDoorPeer:cachedStatus door:_door];
  _nodeId = [DBConfigUtil str:cachedStatus path:@"node.id"] ?: @"";
  if ([[cachedStatus objectForKey:@"display"] isKindOfClass:[NSDictionary class]])
    _display = [cachedStatus objectForKey:@"display"];
  _doorUnlock = [DBConfigUtil dig:cachedStatus path:[NSString stringWithFormat:@"doors.%@.unlock", _door ?: @""]];
  _mediaStandbyReady = [DBConfigUtil evBool:cachedPeer key:@"media_standby_ready"];
  if (_mediaStandbyReady) _fastStartupUntil = CFAbsoluteTimeGetCurrent() + 1.0;
  _peerHost = [DBConfigUtil peerHost:cachedPeer];
  _mediaSource = [DBMediaSource sourceForPeer:cachedPeer config:_cfg boot:_boot door:_door
                                     deviceID:nil];
  _videoStrategies = [self videoStrategiesFromProfile:[cachedPeer objectForKey:@"playback_profile"]
                                               legacy:_videoPlayback];
  _videoStrategiesSource = _videoStrategies;
  _incomingStreamUrl = _mediaSource.mjpegURL;
  _incomingStreamMp4Url = _mediaSource.mp4URL;
  _videoMetaUrl = _mediaSource.videoMetaURL;
  [self startVideo:_incomingStreamUrl];

  DBH264Dbg(@"[startup-ui] content_begin unix_ms=%lld", (long long)(CFAbsoluteTimeGetCurrent() * 1000.0 + kCFAbsoluteTimeIntervalSince1970 * 1000.0));
  [self applyContent];
  DBH264Dbg(@"[startup-ui] content_end unix_ms=%lld", (long long)(CFAbsoluteTimeGetCurrent() * 1000.0 + kCFAbsoluteTimeIntervalSince1970 * 1000.0));
  [self fetchAndApplyCoreSnapshot];
}

- (void)prepareMonitorWithPeer:(NSDictionary *)peer {
  _fastStartupUntil = 0; _snapshotDeferred = NO;
  ++_sipActionGen;
  [_router sipHangup];
  _sipMode = @"";
  _monitorOnly = YES;
  [self resetVideoZoom];
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
  [self dismissChoiceList];
  [_returnCountdown reset];
  [self stopReturnTimer];
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
  }
  _purpose = [purpose copy];
  _visitorLang = [lang copy];
  _stageRevision = MAX(_stageRevision, stageRevision);
  _cancelled = NO;
  [self applyContent];
  _answerButton.enabled = !supersedesAnswer && ([_peerHost length] > 0);
  _hintLabel.hidden = YES;
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
}


- (void)fetchAndApplyCoreSnapshot {
  // Admission already supplied a fresh authoritative status sample. Avoid
  // competing JSON work on the A4 CPU while the first image is being decoded.
  CFAbsoluteTime delay = _fastStartupUntil - CFAbsoluteTimeGetCurrent();
  if (delay > 0 && !_videoStrategyPlaying) {
    if (_snapshotDeferred) return;
    _snapshotDeferred = YES;
    NSInteger generation = _snapshotGen;
    __weak DBIncomingScreen *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
      DBIncomingScreen *screen = weakSelf;
      if (!screen || screen->_snapshotGen != generation || !screen.superview) return;
      screen->_snapshotDeferred = NO;
      [screen fetchAndApplyCoreSnapshot];
    });
    return;
  }
  _snapshotDeferred = NO;
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
        s->_mediaStandbyReady = [DBConfigUtil evBool:peer key:@"media_standby_ready"];
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
      if (!s->_monitorOnly && s->_returnCountdown.isVisible) {
        NSInteger configured = [DBCallReturnCountdown secondsFromStatus:st];
        if (configured != s->_returnCountdown.fullSeconds)
          [s->_returnCountdown startWithSeconds:configured];
      }
      // Core remembers the mute flag across calls and reports it here, so the
      // toggle shows the real position instead of a local guess.
      if ([DBConfigUtil dig:st path:@"call.mic_muted"] != nil)
        s->_micMuted = [DBConfigUtil boolVal:st path:@"call.mic_muted" def:s->_micMuted];
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
    });
  });
}

- (void)applyContent {
  NSDictionary *doorEntry = [DBConfigUtil dig:_cfg path:[NSString stringWithFormat:@"doors.%@", _door]];
  NSString *label = [DBConfigUtil labelOf:doorEntry lang:_boot.uiLang fallback:_door];
  NSString *barTitle = label;
  if (_monitorOnly) {
    NSString *name = [_selectedPeerName length] > 0 ? _selectedPeerName : label;
    _titleLabel.text = [_texts t:@"monitor.title", name, nil];
    barTitle = name;
  } else {
    _titleLabel.text = [_texts t:@"ring.incoming", label, nil];
  }
  if (!DBSameString(_navBar.topItem.title, barTitle ?: @"")) _navBar.topItem.title = barTitle ?: @"";
  _noVideoLabel.text = [_texts ts:@"ring.no_video"];
  _statusLabel.text = _monitorOnly ? [_texts ts:@"monitor.live"]
                                   : [_texts ts:(_cancelled ? @"ring.cancelled" : @"reply.choose")];
  [_answerButton setTitle:(_inCall ? [_texts ts:@"incall.end"] : [_texts ts:@"ring.answer"])
                 forState:UIControlStateNormal];
  // The monitor and mic entries are toggles whose title states the current position.
  [_monitorButton setTitle:[_texts ts:(_monitorAudioOn ? @"ring.monitor_on"
                                                       : @"ring.monitor_off")]
                  forState:UIControlStateNormal];
  [_micButton setTitle:[_texts ts:(_micMuted ? @"ring.mic_off" : @"ring.mic_on")]
              forState:UIControlStateNormal];
  [_repliesButton setTitle:[_texts ts:@"ring.quick_reply"] forState:UIControlStateNormal];
  [_openButton setTitle:[_texts ts:@"ring.open_door"] forState:UIControlStateNormal];
  [_ignoreButton setTitle:[_texts ts:(_monitorOnly ? @"monitor.close" : @"ring.ignore")]
                  forState:UIControlStateNormal];
  _countdownButton.accessibilityLabel = [_texts ts:@"ring.return_countdown_a11y"];
  _videoScroll.accessibilityHint = [_texts ts:@"ring.video_zoom_hint"];
  _answerButton.hidden = _monitorOnly;
  _repliesButton.hidden = _monitorOnly;
  _micButton.hidden = _monitorOnly;
  _langBadge.hidden = _monitorOnly;
  [self refreshUnlockVisibility];
  [self refreshNotice];
  [self applyPalette];
  [self updateBadges];
  [self rebuildReplies];
  [self applySemanticStyles];
  [self setNeedsLayout];
}

// The unlock button is an administrator's decision. Core reports
// doors.<id>.unlock = {configured, command, show_button, source}: show_button
// defaults to configured and an administrator may force either answer. An
// older core leaves the button on its configured state.
- (void)refreshUnlockVisibility {
  _unlockConfigured = [DBConfigUtil boolVal:_doorUnlock path:@"configured" def:NO];
  _unlockVisible = [DBConfigUtil boolVal:_doorUnlock path:@"show_button"
                                     def:_unlockConfigured];
  _openButton.hidden = !_unlockVisible;
}

// The announcement entry lives in the navigation bar; an announcement that is showing at this
// door is quoted in the details.
- (void)refreshNotice {
  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  NSDictionary *notice = [DBNoticeModel effectiveNoticeForDoor:_door config:_cfg nowMs:nowMs];
  NSString *text = notice ? [DBNoticeModel noticeText:notice] : nil;
  _noticeLabel.hidden = ([text length] == 0);
  _noticeLabel.text = [text length] > 0
      ? [NSString stringWithFormat:@"%@: %@", [_texts ts:@"notice.chip"], text] : @"";
  NSString *entry = [_texts ts:@"notice.for_this_door"];
  if (!DBSameString(_noticeItem.title, entry)) _noticeItem.title = entry;
  UIBarButtonItem *wanted = [_door length] > 0 ? _noticeItem : nil;
  if (_navBar.topItem.rightBarButtonItem != wanted) _navBar.topItem.rightBarButtonItem = wanted;
}

- (void)applyPalette {
  // The incoming page keeps its own near-black chrome so video reads well; it
  // never draws the theme picture, so its ink is measured against that chrome.
  _palette = [DBUiPalette paletteForConfig:_cfg deviceId:_nodeId display:_display
                             backgroundHex:@"#0A0D12" minuteOfDay:[self minuteOfDay]];
  [_palette setUsesThemeBackground:NO];
  [self applyRegionInk];
}

// The same per-region ink rule the dashboard and the visitor screen use, applied to the labels
// that sit on this screen's own dark ground. An administrator's override still wins. The stats
// line keeps its own opaque plate and stock controls keep the system's colours.
- (void)applyRegionInk {
  if (_palette == nil) return;
  if (!_titleStyled) [_palette applyInkToLabel:_titleLabel region:DBUiRegionTileLabel];
  if (!_cancelled) [_palette applyInkToLabel:_statusLabel region:DBUiRegionStatusLine];
  [_palette applyInkToLabel:_hintLabel region:DBUiRegionHint];
  for (UILabel *label in @[ _purposeBadge, _langBadge, _noticeLabel ])
    [_palette applyInkToLabel:label region:DBUiRegionStatusLine];
  _adminUrlLabel.textColor = [[_palette inkForRegion:DBUiRegionStatusLine
                                               frame:_adminUrlLabel.frame]
      colorWithAlphaComponent:0.85];
}

- (NSInteger)minuteOfDay {
  NSDictionary *local = [_core cachedLocalTime];
  NSInteger hh = [DBConfigUtil intVal:local path:@"hh" def:-1];
  if (hh < 0) return 12 * 60;
  return hh * 60 + [DBConfigUtil intVal:local path:@"mm" def:0];
}

- (void)onNoticeChip {
  if ([_door length] == 0) return;
  [self dismissChoiceList];
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

#pragma mark - return countdown

- (void)startReturnTimer {
  if (_returnTimer) return;
  _returnTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                selector:@selector(onReturnTick:)
                                                userInfo:nil repeats:YES];
}

- (void)stopReturnTimer {
  [_returnTimer invalidate];
  _returnTimer = nil;
}

- (void)onReturnTick:(NSTimer *)timer {
  if ([_visitOrder count] > 1) return;
  (void)timer;
  BOOL expired = [_returnCountdown tick];
  [self updateCountdownLabel];
  if (expired) {
    [self stopReturnTimer];
    [self closeSelf];
  }
}

- (void)updateCountdownLabel {
  BOOL visible = !_monitorOnly && _returnCountdown.isVisible;
  if (_countdownButton.hidden == visible) [self setNeedsLayout];
  _countdownButton.hidden = !visible;
  if (!visible) return;
  NSString *title = [_texts t:@"ring.return_countdown_action",
      [NSString stringWithFormat:@"%ld", (long)_returnCountdown.remaining], nil];
  UIButton *button = _countdownButton;
  // The flat system button cross-fades a new title; a number that changes every second must not.
  if ([UIView respondsToSelector:@selector(performWithoutAnimation:)]) {
    [UIView performWithoutAnimation:^{
      [button setTitle:title forState:UIControlStateNormal];
      [button layoutIfNeeded];
    }];
  } else {
    [button setTitle:title forState:UIControlStateNormal];
  }
}

- (void)onCancelCountdown {
  // The resident wants to stay on this page; nothing closes it after this.
  if (![_returnCountdown cancelByUser]) return;
  [self stopReturnTimer];
  [self updateCountdownLabel];
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

- (void)onToggleDebugLine {
  _debugLineHidden = !_debugLineHidden;
  [[NSUserDefaults standardUserDefaults] setBool:_debugLineHidden forKey:kDebugLineHiddenKey];
  [[NSUserDefaults standardUserDefaults] synchronize];
  _videoStatsLabel.hidden = _debugLineHidden;
  [self setNeedsLayout];
}

#pragma mark - choice lists

// Quick replies and the admin address choices share one presentation: a popover holding a plain
// table on the iPad idiom, where UIPopoverController exists, and an action sheet elsewhere. The
// call screen stays alive underneath either.
- (void)presentChoices:(NSArray *)titles kind:(DBIncomingListKind)kind
               checked:(NSInteger)checked title:(NSString *)title anchor:(UIView *)anchor
                 style:(NSDictionary *)style {
  [self dismissChoiceList];
  if ([titles count] == 0 || !self.window || CGRectIsEmpty(anchor.frame)) return;
  _listKind = kind;
  if (DBChromeIsPad()) {
    DBIncomingListController *list = [[DBIncomingListController alloc] init];
    list.titles = titles;
    list.headerTitle = title;
    list.checkedIndex = checked;
    list.style = style;
    __weak DBIncomingScreen *weakSelf = self;
    list.onSelect = ^(NSInteger index) {
      [weakSelf choiceSelectedAtIndex:index];
    };
    NSUInteger rows = MIN([titles count], kListMaxVisibleRows);
    CGFloat header = [title length] > 0 ? 28 : 0;
    _listPopover = [[UIPopoverController alloc] initWithContentViewController:list];
    _listPopover.popoverContentSize = CGSizeMake(kListWidth, rows * kListRowHeight + header);
    [_listPopover presentPopoverFromRect:anchor.frame inView:self
                permittedArrowDirections:UIPopoverArrowDirectionAny animated:NO];
    return;
  }
  UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:title delegate:self
                                            cancelButtonTitle:nil destructiveButtonTitle:nil
                                            otherButtonTitles:nil];
  for (NSString *choice in titles) [sheet addButtonWithTitle:choice];
  sheet.cancelButtonIndex = [sheet addButtonWithTitle:[_texts ts:@"admin.cancel"]];
  _listSheet = sheet;
  [sheet showInView:self];
}

- (void)dismissChoiceList {
  if ([_listPopover isPopoverVisible]) [_listPopover dismissPopoverAnimated:NO];
  UIActionSheet *sheet = _listSheet;
  _listSheet = nil;
  if (sheet) {
    sheet.delegate = nil;
    [sheet dismissWithClickedButtonIndex:sheet.cancelButtonIndex animated:NO];
  }
  _listKind = DBIncomingListNone;
}

- (void)choiceSelectedAtIndex:(NSInteger)index {
  DBIncomingListKind kind = _listKind;
  [self dismissChoiceList];
  if (kind == DBIncomingListReplies) [self sendReplyAtIndex:index];
  else if (kind == DBIncomingListAdminAddresses) [self chooseAdminAddressAtIndex:index];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
  if (actionSheet != _listSheet) return;
  // The sheet dismisses itself after this callback.
  _listSheet = nil;
  if (buttonIndex < 0 || buttonIndex == actionSheet.cancelButtonIndex) {
    _listKind = DBIncomingListNone;
    return;
  }
  [self choiceSelectedAtIndex:buttonIndex];
}

- (void)onReplies {
  [self presentChoices:_replyTitles kind:DBIncomingListReplies checked:-1
                 title:[_texts ts:@"reply.choose"] anchor:_repliesButton style:_replyStyle];
}

#pragma mark - semantic styles

- (NSDictionary *)styleForSemanticID:(NSString *)semanticID
                            foreground:(UIColor *)foreground
                            background:(UIColor *)background
                                safety:(BOOL)safety {
  return [DBSemanticStyle styleForConfig:_cfg deviceID:_nodeId semanticID:semanticID
                          safetyCritical:safety baselineForeground:foreground
                      baselineBackground:background baselineAccent:nil baselineBorder:nil];
}

// A stock button cannot carry an administrator's fill, border, or radius. A secondary action
// whose semantic id has an override in effect is therefore swapped for a filled button, and
// swapped back to the stock one when the override goes away. Title, state, and targets move
// with it.
- (UIButton *)button:(UIButton *)button usingFill:(BOOL)filled {
  BOOL isFilled = button.buttonType == UIButtonTypeCustom;
  if (isFilled == filled) return button;
  UIButton *next = filled ? DBChromeFilledButton(18) : DBChromeButton(nil, 18);
  [next setTitle:[button titleForState:UIControlStateNormal] forState:UIControlStateNormal];
  next.enabled = button.enabled;
  next.hidden = button.hidden;
  next.frame = button.frame;
  UIControlEvents events[] = {UIControlEventTouchDown, UIControlEventTouchUpInside};
  for (NSUInteger i = 0; i < sizeof(events) / sizeof(events[0]); i++) {
    for (NSString *action in [button actionsForTarget:self forControlEvent:events[i]])
      [next addTarget:self action:NSSelectorFromString(action) forControlEvents:events[i]];
  }
  [self insertSubview:next aboveSubview:button];
  [button removeFromSuperview];
  return next;
}

- (void)applyFill:(UIButton *)button style:(NSDictionary *)style
       foreground:(UIColor *)foreground background:(UIColor *)background
         fontSize:(CGFloat)fontSize {
  [DBSemanticStyle applyButton:button style:style foreground:foreground background:background
                        border:nil radius:10 fontSize:fontSize];
  // A filled button keeps its ink at full strength while disabled: a dimmed title on the fill
  // was unreadable on the device, and the status line already says why the action is off.
  UIColor *ink = [button titleColorForState:UIControlStateNormal] ?: foreground;
  [button setTitleColor:ink forState:UIControlStateDisabled];
}

- (void)applySemanticStyles {
  UIColor *white = [UIColor whiteColor];
  UIColor *screen = [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1];
  NSDictionary *title = [self styleForSemanticID:@"ring.title" foreground:white
                                       background:screen safety:NO];
  _titleStyled = (title != nil);
  [DBSemanticStyle applyLabel:_titleLabel style:title foreground:white
                    background:[UIColor clearColor] fontSize:24];

  // Answer and End are the one filled control: positive while ringing, negative in a call.
  UIColor *green = [UIColor colorWithRed:0.094 green:0.478 blue:0.235 alpha:1];
  UIColor *red = [UIColor colorWithRed:0.749 green:0.161 blue:0.129 alpha:1];
  UIColor *fill = _inCall ? red : green;
  NSString *answerID = _inCall ? @"call.end" : @"ring.action";
  NSDictionary *answer = [self styleForSemanticID:answerID foreground:white
                                        background:fill safety:_inCall];
  [self applyFill:_answerButton style:answer foreground:white background:fill fontSize:24];

  UIColor *neutral = [UIColor colorWithRed:0.16 green:0.17 blue:0.19 alpha:1];
  NSDictionary *action = [self styleForSemanticID:@"ring.action" foreground:white
                                        background:neutral safety:NO];
  _monitorButton = [self button:_monitorButton usingFill:(action != nil)];
  _openButton = [self button:_openButton usingFill:(action != nil)];
  if (action) {
    for (UIButton *button in @[ _monitorButton, _openButton ])
      [self applyFill:button style:action foreground:white background:neutral fontSize:18];
  }

  NSString *closeID = _monitorOnly ? @"monitor.close" : @"ring.action";
  NSDictionary *close = [self styleForSemanticID:closeID foreground:white
                                       background:neutral safety:_monitorOnly];
  _ignoreButton = [self button:_ignoreButton usingFill:(close != nil)];
  if (close)
    [self applyFill:_ignoreButton style:close foreground:white background:neutral fontSize:18];

  // The quick replies are table rows; the override, when there is one, colours those rows.
  _replyStyle = [self styleForSemanticID:@"reply.button" foreground:white
                              background:neutral safety:NO];
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
    // Deliberately not filtered by visit_purposes.<id>.enabled: this slot
    // reports what the visitor actually pressed, and a purpose disabled after
    // the call would otherwise vanish from a call that already happened.
    NSDictionary *entry =
        [DBConfigUtil dig:_cfg path:[NSString stringWithFormat:@"visit_purposes.%@", _purpose]];
    NSString *label = [DBConfigUtil labelOf:entry lang:_boot.uiLang fallback:_purpose];
    NSString *icon = [DBPurposeModel displayIconForConfiguredIcon:
        [entry objectForKey:@"icon"]];
    NSString *purposeText = [_texts t:@"ring.purpose_badge", label, nil];
    _purposeBadge.text = [icon length] == 0
                             ? purposeText
                             : [NSString stringWithFormat:@"%@ %@", icon, purposeText];
    _purposeBadge.hidden = NO;
  }
  if ([_visitorLang length] == 0 || [_visitorLang isEqualToString:@"ja"]) {
    _langBadge.hidden = YES;
  } else {
    _langBadge.text = [_texts t:@"ring.lang_badge", [_visitorLang uppercaseString], nil];
    _langBadge.hidden = NO;
  }
  [self setNeedsLayout];
}

// The replies offered for this call, labelled in the visitor's language. None while monitoring
// or in a call, which disables the Reply button.
- (void)rebuildReplies {
  NSMutableArray *ids = [NSMutableArray array];
  NSMutableArray *titles = [NSMutableArray array];
  NSDictionary *replies = [DBConfigUtil dig:_cfg path:@"quick_replies"];
  if (!_monitorOnly && !_inCall && [replies isKindOfClass:[NSDictionary class]]) {
    NSString *lang = [_visitorLang length] == 0 ? @"ja" : _visitorLang;
    for (NSString *rid in [DBConfigUtil sortedByOrder:replies]) {
      [ids addObject:rid];
      [titles addObject:[DBConfigUtil labelOf:[replies objectForKey:rid] lang:lang fallback:rid]
                            ?: rid];
    }
  }
  BOOL changed = ![ids isEqualToArray:_replyIds] || ![titles isEqualToArray:_replyTitles];
  _replyIds = ids;
  _replyTitles = titles;
  _repliesButton.enabled = [ids count] > 0;
  if (changed && _listKind == DBIncomingListReplies) [self dismissChoiceList];
}

#pragma mark - Door-station Admin QR

- (NSInteger)adminHttpPort {
  // An external camera URL is not the door station's admin endpoint. Security
  // protocol v3 serves the admin over HTTPS on 47443 only.
  return 47443;
}

- (NSString *)adminUrlForHost:(NSString *)host {
  NSString *urlHost = [DBConfigUtil urlHost:host];
  if ([urlHost length] == 0) return nil;
  return [NSString stringWithFormat:@"https://%@:%ld/admin/", urlHost,
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
  // The door station's admin QR stays visible on the incoming screen too, not only while
  // actively monitoring.
  BOOL available = ([_adminHosts count] > 0);
  _adminQrButton.hidden = !available;
  _adminUrlLabel.hidden = !available;
  if (!available) {
    _adminQrUrl = nil;
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
  // Encoding a QR is pure CPU work this device cannot spare on every status
  // refresh. The bitmap only depends on the URL, so it is regenerated when the
  // address or port changes and cached otherwise.
  if ([_adminQrUrl isEqualToString:url] &&
      [_adminQrButton imageForState:UIControlStateNormal] != nil) {
    [self setNeedsLayout];
    return;
  }
  _adminQrUrl = [url copy];
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
  NSMutableArray *urls = [NSMutableArray array];
  for (NSString *host in _adminHosts) [urls addObject:[self adminUrlForHost:host] ?: host];
  [self presentChoices:urls kind:DBIncomingListAdminAddresses checked:_adminHostIndex
                 title:[_texts ts:@"monitor.admin_qr_select"] anchor:_adminQrButton style:nil];
}

- (void)chooseAdminAddressAtIndex:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)[_adminHosts count]) return;
  _adminHostIndex = index;
  [self updateAdminQr];
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
  if ([_incomingStreamUrl length] > 0 && !_mjpegAvailabilityDisabled) {
    if (!_mediaStandbyReady) [self startMjpegPrewarm];
    else {
      NSInteger session = _videoSessionGen;
      __weak DBIncomingScreen *weakSelf = self;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        DBIncomingScreen *screen = weakSelf;
        if (screen && screen->_videoSessionGen == session && !screen->_videoStrategyPlaying && !screen->_cancelled)
          [screen startMjpegPrewarm];
      });
    }
  }
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
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:1.0];
  DBAuthorizeLocalMediaRequest(req);
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
  [self refreshVisits];
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
  // Residents see the line only for a real stream; without one it is diagnostics-only.
  BOOL streaming = stats.valid || ![transport isEqualToString:@"NO STREAM"];
  _videoStatsLabel.hidden = _debugLineHidden || !(streaming || _boot.diagnosticDumps);
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



- (void)handleCallCancelled:(NSDictionary *)ev {
  if (_monitorOnly) return;
  NSString *door = [DBConfigUtil evStr:ev key:@"door"];
  if ([door length] > 0 && [_door length] > 0 && ![door isEqualToString:_door]) return;
  if (_inCall) return;
  _cancelled = YES;
  // The visitor ended the call lifecycle, not the resident's view. Keep the existing transport,
  // decoder and last frame alive until this screen's normal close deadline; refreshFromCore also
  // respects _cancelled, so it will neither tear down nor replace this stream underneath us.
  _answerButton.enabled = NO;
  _monitorButton.enabled = NO;
  _statusLabel.text = [_texts ts:@"ring.cancelled"];
  _statusLabel.font = [UIFont boldSystemFontOfSize:24];
  _statusLabel.textColor = [UIColor whiteColor];
  _statusLabel.backgroundColor = [UIColor colorWithRed:0.78 green:0.14 blue:0.12 alpha:1];
  _statusLabel.textAlignment = NSTextAlignmentCenter;
  _statusLabel.layer.cornerRadius = 8;
  _statusLabel.clipsToBounds = YES;
  [self setNeedsLayout];
  NSLog(@"[doorbell] call cancelled: video retained until the return deadline or resident close");
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
  [_router closeIncomingAnimated:YES];
}

- (void)onScreenWillAppear {
  [self startVideoStatsTimer];
  if (!_monitorOnly && _returnCountdown.isVisible) [self startReturnTimer];
  [self updateCountdownLabel];
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
  for (NSDictionary *call in [self visitSnapshots]) {
    NSDictionary *room = [self roomFor:call];
    if (![self ownRoomMember:room]) continue;
    [_core conversation:@{ @"action":@"leave", @"door":[call objectForKey:@"door"],
        @"call_id":[call objectForKey:@"call_id"], @"stage_revision":[call objectForKey:@"stage_revision"],
        @"expected_version":[room objectForKey:@"version"] }];
  }
  ++_sipActionGen;
  [self dismissChoiceList];
  [self resetVideoZoom];
  [self stopReturnTimer];
  [_returnCountdown reset];
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
  if (![self visitTargetMatches]) return;
  if ([self usesConversation]) {
    NSDictionary *member = [self ownRoomMember:[self roomFor:[self selectedVisitSnapshot]]];
    [self sendConversation:!member || [[member objectForKey:@"state"] isEqual:@"waiting"] ? @"answer" : @"leave"];
    return;
  }
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
  // Monitor is a stateful on/off toggle for door audio; the answered call is
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
  if ([self usesConversation]) return;
  if (_monitorOnly) [self onMonitor];
}

- (void)startSip:(NSString *)mode {

  [_router sipStart:_peerHost port:(int)_directPort mode:mode];
  _openButton.enabled = YES;
}

- (void)onOpenDoor {
  // db_core_open_door publishes the configured unlock action; -3 means nothing
  // is configured anywhere and -4 that a configured command failed. Each must
  // explain itself, because a silent no-op reads as a broken lock (spec §5.2).
  if (![self visitTargetMatches]) return;
  int status = [_callID length] > 0 ? [_core openDoor:_door callID:_callID revision:_stageRevision] : [_core openDoor:_door];
  if (status == 0) _hintLabel.text = [_texts ts:@"ring.unlock_sent"];
  else if (status == -3) _hintLabel.text = [_texts ts:@"unlock.not_configured"];
  else _hintLabel.text = [_texts ts:@"ring.unlock_failed"];
  _hintLabel.hidden = NO;
}

- (void)onIgnore {
  NSString *key = [NSString stringWithFormat:@"%@:%@", _door, _callID];
  [_retiredVisits setObject:@(_stageRevision) forKey:key];
  [_visits removeObjectForKey:key]; [_visitOrder removeObject:key];
  if ([_visitOrder count] == 0) [self closeSelf];
  else { _answerButton.enabled = NO; [self refreshVisits]; }
}

- (void)sendReplyAtIndex:(NSInteger)index {
  if (_inCall) return;
  if (index < 0 || index >= (NSInteger)[_replyIds count]) return;
  NSString *rid = [_replyIds objectAtIndex:(NSUInteger)index];
  NSString *title = [_replyTitles objectAtIndex:(NSUInteger)index];
  BOOL accepted = [_core quickReplyV2:rid door:_door callID:_callID
                        stageRevision:_stageRevision];
  _hintLabel.text = accepted
      ? [_texts t:@"reply.sent", (title ?: @""), nil]
      : [_texts ts:@"reply.failed"];
  _hintLabel.hidden = NO;
}

- (void)sipStateChanged:(DBMiniSipState)state {
  if (!self.superview) return;
  if (state == DBMiniSipInCall) {
    if (![_sipMode isEqualToString:@"answer"]) return;
    _inCall = YES;
    [_returnCountdown pauseForAnsweredCall];
    [self updateCountdownLabel];
    [self rebuildReplies];
    if (!_lifecycleAnswered) {
      _lifecycleAnswered = [_core reportCallAnsweredV2:_door callID:_callID
                                        stageRevision:_stageRevision];
    }
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
    _sipMode = @"";
    _hintLabel.hidden = YES;
    // The page no longer closes the moment a conversation ends: the resident
    // keeps the live view and the full countdown starts again (batch 3).
    [_returnCountdown resumeAfterCall];
    if (_returnCountdown.isVisible) [self startReturnTimer];
    [self updateCountdownLabel];
    [self applyContent];
    (void)wasAnswer;
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
    [self rebuildReplies];
  }
}

- (NSArray *)visitSnapshots {
  NSArray *calls = [[_core lastStatus] objectForKey:@"active_calls"];
  return [calls isKindOfClass:[NSArray class]] ? calls : @[];
}
- (NSDictionary *)selectedVisitSnapshot {
  for (NSDictionary *call in [self visitSnapshots]) if ([[call objectForKey:@"door"] isEqual:_door] &&
      [[call objectForKey:@"call_id"] isEqual:_callID]) return call;
  return nil;
}
- (BOOL)usesConversation { return [[[self selectedVisitSnapshot] objectForKey:@"conversation_supported"] boolValue]; }
- (NSDictionary *)roomFor:(NSDictionary *)call {
  NSDictionary *snapshot = [call objectForKey:@"conversation"];
  NSDictionary *event = [_roomEvents objectForKey:[call objectForKey:@"call_id"] ?: @""];
  return [[event objectForKey:@"version"] longLongValue] > [[snapshot objectForKey:@"version"] longLongValue] ? event : snapshot;
}
- (NSDictionary *)ownRoomMember:(NSDictionary *)room {
  for (NSDictionary *member in [room objectForKey:@"participants"])
    if ([[member objectForKey:@"device"] isEqual:_nodeId]) return member;
  return nil;
}
- (BOOL)isVisitSelected:(NSDictionary *)event {
  return [[event objectForKey:@"door"] isEqual:_door] && [[event objectForKey:@"call_id"] isEqual:_callID];
}
- (void)captureVisit {
  _touchVisit = [NSString stringWithFormat:@"%@:%@:%ld", _door, _callID, (long)_stageRevision];
  _touchRoomVersion = [[self roomFor:[self selectedVisitSnapshot]] objectForKey:@"version"] ?: @0;
}
- (BOOL)visitTargetMatches {
  NSString *target = _touchVisit;
  _touchVisit = nil;
  return !target || [target isEqual:[NSString stringWithFormat:@"%@:%@:%ld", _door, _callID, (long)_stageRevision]];
}
- (void)sendConversation:(NSString *)action {
  if ([_sipMode length] > 0) { [_router sipHangup]; _sipMode = @""; _inCall = NO; }
  NSDictionary *request = @{ @"action":action, @"door":_door ?: @"", @"call_id":_callID ?: @"",
      @"stage_revision":@(_stageRevision), @"expected_version":_touchRoomVersion ?:
        ([[self roomFor:[self selectedVisitSnapshot]] objectForKey:@"version"] ?: @0) };
  _touchRoomVersion = nil;
  if ([action isEqual:@"takeover"]) {
    _pendingTakeoverRequest = request;
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:[_texts ts:@"conversation.takeover"]
        message:[_texts ts:@"conversation.takeover_confirm"] delegate:(id)self
        cancelButtonTitle:[_texts ts:@"admin.cancel"] otherButtonTitles:[_texts ts:@"conversation.takeover"], nil];
    [alert show];
    return;
  }
  NSDictionary *result = [_core conversation:request];
  _hintLabel.text = [_texts ts:[[result objectForKey:@"ok"] boolValue] ? @"conversation.pending" : @"conversation.failed"];
  _hintLabel.hidden = NO;
}
- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
  NSDictionary *request = _pendingTakeoverRequest;
  _pendingTakeoverRequest = nil;
  if (index == alert.cancelButtonIndex || !request) return;
  NSDictionary *result = [_core conversation:request];
  _hintLabel.text = [_texts ts:[[result objectForKey:@"ok"] boolValue] ? @"conversation.pending" : @"conversation.failed"];
  _hintLabel.hidden = NO;
}
- (void)onVisitButton:(UIButton *)button {
  NSDictionary *entry = button.tag >= 0 && button.tag < (NSInteger)[_visitButtons count]
      ? [_visitButtons objectAtIndex:button.tag] : nil;
  NSString *action = [entry objectForKey:@"action"];
  if (action) { if ([self visitTargetMatches]) [self sendConversation:action]; return; }
  NSDictionary *visit = [_visits objectForKey:[entry objectForKey:@"key"]];
  if (!visit || (_inCall && ![self usesConversation])) return;
  [_core conversation:@{ @"action":@"select", @"door":[visit objectForKey:@"door"],
                          @"call_id":[visit objectForKey:@"call_id"] }];
  _selectingVisit = YES;
  [self prepareWithDoor:[visit objectForKey:@"door"] purpose:[visit objectForKey:@"purpose"]
      lang:[visit objectForKey:@"visitor_lang"] callID:[visit objectForKey:@"call_id"]
      stageRevision:[[visit objectForKey:@"stage_revision"] integerValue]
      expiresAtMs:[[visit objectForKey:@"expires_at_ms"] longLongValue]];
  _selectingVisit = NO;
  [self refreshVisits];
}
- (BOOL)handleVisitEvent:(NSDictionary *)event {
  NSString *key = [NSString stringWithFormat:@"%@:%@", [event objectForKey:@"door"], [event objectForKey:@"call_id"]];
  NSDictionary *visit = [_visits objectForKey:key];
  if (!visit) return NO;
  NSString *type = [event objectForKey:@"type"];
  if ([type isEqual:@"call_cancelled"] || [type isEqual:@"call_ended"] || [type isEqual:@"reply"]) {
    NSNumber *revision = [event objectForKey:@"stage_revision"];
    if (revision && [revision integerValue] >= [[visit objectForKey:@"stage_revision"] integerValue]) {
      [_retiredVisits setObject:revision forKey:key]; [_visits removeObjectForKey:key]; [_visitOrder removeObject:key];
      if ([self isVisitSelected:event]) { _answerButton.enabled = NO; _inCall = NO; }
    }
  }
  [self refreshVisits];
  return [type isEqual:@"call_answered"] || [type isEqual:@"call_cancelled"] || [type isEqual:@"call_ended"] || [type isEqual:@"reply"];
}
- (void)handleConversationEvent:(NSDictionary *)event {
  NSString *callID = [event objectForKey:@"call_id"];
  if ([callID length] > 0 && [[event objectForKey:@"t"] isEqual:@"conversation"] &&
      [[event objectForKey:@"version"] longLongValue] > [[[_roomEvents objectForKey:callID] objectForKey:@"version"] longLongValue])
    [_roomEvents setObject:event forKey:callID];
  [self refreshVisits];
}
- (void)refreshVisits {
  if (!_visitPanel) return;
  for (NSDictionary *call in [self visitSnapshots]) if ([[call objectForKey:@"notification_eligible"] boolValue]) {
    NSString *key = [NSString stringWithFormat:@"%@:%@", [call objectForKey:@"door"], [call objectForKey:@"call_id"]];
    NSNumber *retired = [_retiredVisits objectForKey:key];
    if (retired && [[call objectForKey:@"stage_revision"] integerValue] <= [retired integerValue]) continue;
    if (![_visits objectForKey:key]) [_visitOrder addObject:key];
    [_visits setObject:call forKey:key];
  }
  NSDictionary *selected = [self selectedVisitSnapshot];
  NSDictionary *room = [self roomFor:selected];
  NSDictionary *me = [self ownRoomMember:room];
  NSString *state = [me objectForKey:@"state"] ?: @"";
  BOOL supported = [self usesConversation];
  BOOL media = [[selected objectForKey:@"conversation_local_media"] boolValue];
  if (supported) {
    _inCall = [state isEqual:@"connected"] && media;
    [_answerButton setTitle:[_texts ts:!me || [state isEqual:@"waiting"] ? @"conversation.answer" : @"conversation.leave"] forState:UIControlStateNormal];
    _answerButton.enabled = me || [[room objectForKey:@"owner"] length] == 0;
    _monitorButton.hidden = YES;
    _openButton.enabled = YES;
    if ([state length] > 0 && ![state isEqual:@"waiting"]) [_returnCountdown pauseForAnsweredCall];
  }
  NSString *signature = [NSString stringWithFormat:@"%@:%@:%@:%@:%d:%d", _visitOrder, _door, _callID,
      [room objectForKey:@"version"], supported, media];
  if ([_visitSignature isEqual:signature]) return;
  _visitSignature = signature;
  for (UIView *view in [_visitPanel subviews]) [view removeFromSuperview];
  [_visitButtons removeAllObjects];
  CGFloat y = 0, width = MAX(200, self.bounds.size.width - 40);
  // A lone visit is already the one on screen; the switcher appears with a second door.
  for (NSString *key in ([_visitOrder count] > 1 ? _visitOrder : [NSArray array])) {
    NSDictionary *call = [_visits objectForKey:key];
    NSString *door = [call objectForKey:@"door"];
    NSString *name = [DBConfigUtil labelOf:[DBConfigUtil dig:_cfg path:[@"doors." stringByAppendingString:door]] lang:_boot.uiLang fallback:door];
    UIButton *button = DBChromeButton(nil, 17);
    button.tag = [_visitButtons count];
    [_visitButtons addObject:@{ @"key":key }];
    [button setTitle:[_texts t:[self isVisitSelected:call] ? @"ring.queue_selected" : @"ring.queue_waiting", name, nil] forState:UIControlStateNormal];
    [button addTarget:self action:@selector(onVisitButton:) forControlEvents:UIControlEventTouchUpInside];
    button.frame = CGRectMake(0, y, width, 44); y += 48; [_visitPanel addSubview:button];
  }
  NSMutableArray *actions = [NSMutableArray array];
  if (supported) {
    if ([state isEqual:@"connected"] && media) [actions addObject:@"hold"];
    else if ([state isEqual:@"held"] || ([state isEqual:@"connected"] && !media)) [actions addObject:@"resume"];
    else if (!me && [[room objectForKey:@"owner"] length] > 0) [actions addObjectsFromArray:@[@"join", @"takeover"]];
    else if (!me) [actions addObject:@"respond"];
  }
  for (NSString *action in actions) {
    UIButton *button = DBChromeButton(nil, 17); button.tag = [_visitButtons count];
    [_visitButtons addObject:@{ @"action":action }];
    [button setTitle:[_texts ts:[@"conversation." stringByAppendingString:action]] forState:UIControlStateNormal];
    [button addTarget:self action:@selector(captureVisit) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(onVisitButton:) forControlEvents:UIControlEventTouchUpInside];
    button.frame = CGRectMake(0, y, width, 44); y += 48; [_visitPanel addSubview:button];
  }
  for (NSDictionary *call in [self visitSnapshots]) for (NSDictionary *member in [[self roomFor:call] objectForKey:@"participants"]) {
    NSString *device = [member objectForKey:@"device"];
    NSString *name = [DBConfigUtil labelOf:[DBConfigUtil dig:_cfg path:[@"devices." stringByAppendingString:device]] lang:_boot.uiLang fallback:device];
    NSString *phase = [member objectForKey:@"state"];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, y, width, 44)];
    label.numberOfLines = 2; label.textColor = [UIColor whiteColor]; label.backgroundColor = [UIColor clearColor];
    label.text = [NSString stringWithFormat:@"%@ · %@", [call objectForKey:@"door"],
        [_texts t:[phase isEqual:@"waiting"] ? @"conversation.queued" : [@"conversation." stringByAppendingString:phase], name, nil]];
    [_visitPanel addSubview:label]; y += 48;
  }
  _visitPanel.contentSize = CGSizeMake(width, y);
  _visitPanel.hidden = y == 0;
  [self setNeedsLayout];
}

#pragma mark - layout

// The door camera's aspect drives the picture inside its slot: a portrait stream is shown
// portrait, letterboxed, never cropped or stretched. The image's own size wins; before the
// first frame the reported sensor rotation decides.
- (CGSize)videoContentSize {
  UIImage *frame = _liveView.image;
  if (frame != nil && frame.size.width > 0 && frame.size.height > 0) return frame.size;
  BOOL rotatedPortrait = (_videoRotation == 90 || _videoRotation == 270);
  return rotatedPortrait ? CGSizeMake(3, 4) : CGSizeMake(4, 3);
}

#pragma mark - video zoom

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
  (void)scrollView;
  return _zoomContent;
}

// Keeps the picture centred in the slot while it is smaller than the slot on an axis. Once it
// is larger, the scroll view's own content bounds stop a pan at the picture's edges.
- (void)centreZoomContent {
  CGSize slot = _videoScroll.bounds.size;
  CGSize content = _videoScroll.contentSize;
  _zoomContent.center = CGPointMake(content.width / 2 + MAX(0, (slot.width - content.width) / 2),
                                    content.height / 2 +
                                        MAX(0, (slot.height - content.height) / 2));
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
  (void)scrollView;
  [self centreZoomContent];
}

- (void)resetVideoZoom {
  if (_videoScroll.zoomScale != 1) [_videoScroll setZoomScale:1 animated:NO];
  _videoScroll.contentOffset = CGPointZero;
  [self centreZoomContent];
}

// Double tap toggles between fit and 2x around the touched point. Only the flat-UI devices
// animate the change; the A4 switches at once.
- (void)onVideoDoubleTap:(UITapGestureRecognizer *)recognizer {
  BOOL animated = DBChromeIsFlat();
  if (_videoScroll.zoomScale > 1.01f) {
    [_videoScroll setZoomScale:1 animated:animated];
    return;
  }
  CGSize slot = _videoScroll.bounds.size;
  if (slot.width <= 0 || slot.height <= 0) return;
  CGPoint point = [recognizer locationInView:_zoomContent];
  CGSize visible = CGSizeMake(slot.width / 2, slot.height / 2);
  [_videoScroll zoomToRect:CGRectMake(point.x - visible.width / 2, point.y - visible.height / 2,
                                      visible.width, visible.height)
                  animated:animated];
}

- (void)layoutVideoInSlot:(CGRect)slot {
  CGRect frame = DBAspectFitRect(slot, [self videoContentSize]);
  // A new slot or picture size starts again from 1x, which is also the only scale at which the
  // zooming view's frame may be assigned. An unchanged layout pass leaves a zoomed picture alone.
  BOOL resized = !CGSizeEqualToSize(slot.size, _zoomSlotSize) ||
                 !CGSizeEqualToSize(frame.size, _zoomPictureSize);
  _videoScroll.frame = slot;
  if (resized) {
    _zoomSlotSize = slot.size;
    _zoomPictureSize = frame.size;
    if (_videoScroll.zoomScale != 1) [_videoScroll setZoomScale:1 animated:NO];
    _zoomContent.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);
    _videoScroll.contentSize = frame.size;
    _videoScroll.contentOffset = CGPointZero;
    // The sensor rotation is a transform on the live view, and a frame assigned under a
    // non-identity transform is undefined, so the picture is placed by bounds and centre.
    _liveView.bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    _liveView.center = CGPointMake(frame.size.width / 2, frame.size.height / 2);
    [self centreZoomContent];
  }
  _noVideoLabel.frame = slot;
  // The debug line sits inside the video slot's bottom edge and never covers
  // the picture's centre. It and its tap target lie above the scroll view, outside the zoom.
  CGFloat statsWidth = MAX(0, MIN(CGRectGetWidth(slot) - 16, 460));
  CGRect stats = CGRectMake(CGRectGetMinX(slot) + 8,
                            CGRectGetMaxY(slot) - 30, statsWidth, 24);
  if (CGRectGetHeight(slot) < 40) stats = CGRectZero;
  _videoStatsLabel.frame = stats;
  _debugLineTap.frame = CGRectIsEmpty(stats) ? CGRectZero : CGRectInset(stats, -6, -6);
}

// Places the action zone against the bottom edge of rect and returns the height it takes. The
// order never changes: Answer (End in a call), Reply, Ignore (Close while monitoring), then the
// secondary toggles. In a column Answer takes its own row above Reply and Ignore.
- (CGFloat)layoutActionsInRect:(CGRect)rect column:(BOOL)column {
  CGFloat gap = 8;
  CGFloat x = CGRectGetMinX(rect);
  CGFloat width = CGRectGetWidth(rect);
  NSMutableArray *secondary = [NSMutableArray array];
  for (UIButton *button in @[ _monitorButton, _openButton, _micButton ]) {
    if (button.hidden) button.frame = CGRectZero;
    else [secondary addObject:button];
  }
  NSUInteger count = [secondary count];
  NSUInteger perRow = column ? 2 : MAX((NSUInteger)1, count);
  NSUInteger rows = count > 0 ? (count + perRow - 1) / perRow : 0;
  CGFloat secondaryHeight = rows > 0 ? rows * kSecondaryHeight + (rows - 1) * gap : 0;
  BOOL answer = !_answerButton.hidden;
  BOOL reply = !_repliesButton.hidden;
  CGFloat primaryHeight = column
      ? (answer ? kAnswerColumnHeight + gap : 0) + kReplyColumnHeight
      : kPrimaryRowHeight;
  CGFloat total = primaryHeight + (rows > 0 ? gap + secondaryHeight : 0);
  CGFloat y = CGRectGetMaxY(rect) - total;

  if (column) {
    _answerButton.frame = answer ? CGRectMake(x, y, width, kAnswerColumnHeight) : CGRectZero;
    if (answer) y += kAnswerColumnHeight + gap;
    CGFloat half = floorf((width - gap) / 2);
    _repliesButton.frame = reply ? CGRectMake(x, y, half, kReplyColumnHeight) : CGRectZero;
    _ignoreButton.frame = CGRectMake(x + width - half, y, half, kReplyColumnHeight);
    y += kReplyColumnHeight;
  } else {
    CGFloat unit = floorf((width - 2 * gap) / 4);
    _answerButton.frame = answer ? CGRectMake(x, y, 2 * unit, kPrimaryRowHeight) : CGRectZero;
    _repliesButton.frame = reply ? CGRectMake(x + 2 * unit + gap, y, unit, kPrimaryRowHeight)
                                 : CGRectZero;
    _ignoreButton.frame = CGRectMake(x + width - unit, y, unit, kPrimaryRowHeight);
    y += kPrimaryRowHeight;
  }

  CGFloat cell = floorf((width - (perRow - 1) * gap) / perRow);
  for (NSUInteger i = 0; i < count; i++) {
    UIButton *button = [secondary objectAtIndex:i];
    button.frame = CGRectMake(x + (i % perRow) * (cell + gap),
                              y + gap + (i / perRow) * (kSecondaryHeight + gap), cell,
                              kSecondaryHeight);
  }
  return total;
}

// Stacks the details from the top of rect: headline, purpose and visitor language, status with
// the return countdown, hint, the announcement on show, the visit queue, and the admin QR in
// the bottom corner. A row that no longer fits is left out rather than drawn over the actions.
- (void)layoutDetailsInRect:(CGRect)rect {
  CGFloat x = CGRectGetMinX(rect);
  CGFloat width = CGRectGetWidth(rect);
  CGFloat maxY = CGRectGetMaxY(rect);
  __block CGFloat y = CGRectGetMinY(rect);
  CGRect (^row)(CGFloat) = ^CGRect(CGFloat height) {
    if (width <= 0 || y + height > maxY) return CGRectZero;
    CGRect frame = CGRectMake(x, y, width, height);
    y += height + 4;
    return frame;
  };

  _titleLabel.frame = row(ceilf(_titleLabel.font.lineHeight * 2) + 2);

  // The purpose slot keeps its height even while empty, so nothing jumps when the visitor's
  // purpose arrives after the ring.
  if (_monitorOnly) {
    _purposeBadge.frame = CGRectZero;
    _langBadge.frame = CGRectZero;
  } else {
    CGRect line = row(26);
    CGFloat purposeWidth = 0;
    if (!_purposeBadge.hidden && !CGRectIsEmpty(line)) {
      CGFloat fit = ceilf([_purposeBadge.text sizeWithFont:_purposeBadge.font].width);
      CGFloat limit = _langBadge.hidden ? line.size.width : floorf(line.size.width * 0.62f);
      purposeWidth = MIN(fit, limit);
    }
    _purposeBadge.frame = CGRectMake(line.origin.x, line.origin.y, purposeWidth,
                                     line.size.height);
    CGFloat langX = line.origin.x + (purposeWidth > 0 ? purposeWidth + 12 : 0);
    _langBadge.frame = CGRectMake(langX, line.origin.y,
                                  MAX(0, CGRectGetMaxX(line) - langX), line.size.height);
  }

  // The cancelled banner is set up by handleCallCancelled; any other status is a plain line.
  if (!_cancelled) {
    _statusLabel.backgroundColor = [UIColor clearColor];
    _statusLabel.font = [UIFont systemFontOfSize:20];
    _statusLabel.textAlignment = NSTextAlignmentLeft;
    _statusLabel.layer.cornerRadius = 0;
  }
  _statusLabel.frame = row(_cancelled ? 44 : 28);
  // The return countdown is its own full-width row that says what the number is.
  _countdownButton.frame = _countdownButton.hidden ? CGRectZero : row(44);

  // The hint keeps its slot while hidden for the same reason the purpose does.
  _hintLabel.frame = row(44);
  _noticeLabel.frame = _noticeLabel.hidden ? CGRectZero : row(40);

  BOOL qr = [_adminHosts count] > 0;
  CGFloat qrReserve = qr ? kAdminQrSide + 8 : 0;
  if (_visitPanel.hidden) {
    _visitPanel.frame = CGRectZero;
  } else {
    CGFloat content = _visitPanel.contentSize.height;
    CGFloat room = maxY - y;
    // The queue outranks the QR: it gives the QR its corner only while two rows still fit.
    if (room - qrReserve >= 92) room -= qrReserve;
    _visitPanel.frame = row(MAX(0, MIN(content, room)));
    CGFloat panelWidth = CGRectGetWidth(_visitPanel.frame);
    for (UIView *view in [_visitPanel subviews]) {
      if (![view isKindOfClass:[UIButton class]] && ![view isKindOfClass:[UILabel class]])
        continue;
      CGRect frame = view.frame;
      frame.size.width = panelWidth;
      view.frame = frame;
    }
    _visitPanel.contentSize = CGSizeMake(panelWidth, content);
  }

  CGFloat side = MIN(kAdminQrSide, maxY - y);
  BOOL showQr = qr && side >= 60 && width >= side;
  _adminQrButton.hidden = !showQr;
  _adminUrlLabel.hidden = !showQr;
  if (showQr) {
    _adminQrButton.frame = CGRectMake(x, maxY - side, side, side);
    _adminUrlLabel.frame = CGRectMake(x + side + 10, maxY - side,
                                      MAX(0, width - side - 10), side);
  } else {
    _adminQrButton.frame = CGRectZero;
    _adminUrlLabel.frame = CGRectZero;
  }
}

// The one place frames are decided. Landscape on a tablet-wide screen puts the video on the
// left (64 % of the width) with details and actions in a right column; every other size stacks
// a 16:9 video slot, the details, and the action zone, which is always pinned to the bottom.
- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  if (!CGSizeEqualToSize(size, _laidOutSize)) {
    // A popover points at a button frame that is about to move.
    if (_laidOutSize.width > 0) [self dismissChoiceList];
    _laidOutSize = size;
  }
  _noticeDialog.frame = self.bounds;

  CGFloat top = [_navBar layoutInBounds:self.bounds];
  CGFloat margin = size.width >= 600 ? 12 : 8;
  CGFloat gap = 8;
  CGRect body = CGRectMake(margin, top + margin, MAX(0, size.width - 2 * margin),
                           MAX(0, size.height - top - 2 * margin));
  BOOL sideBySide = size.width > size.height && size.width >= 700;

  CGRect videoSlot;
  CGRect details;
  if (sideBySide) {
    CGFloat videoWidth = floorf(size.width * 0.64f);
    CGFloat columnX = CGRectGetMinX(body) + videoWidth + margin;
    CGRect column = CGRectMake(columnX, CGRectGetMinY(body),
                               MAX(0, CGRectGetMaxX(body) - columnX), CGRectGetHeight(body));
    videoSlot = CGRectMake(CGRectGetMinX(body), CGRectGetMinY(body), videoWidth,
                           CGRectGetHeight(body));
    CGFloat actions = [self layoutActionsInRect:column column:YES];
    details = CGRectMake(columnX, CGRectGetMinY(column), CGRectGetWidth(column),
                         MAX(0, CGRectGetHeight(column) - actions - gap));
  } else {
    CGFloat actions = [self layoutActionsInRect:body column:NO];
    CGFloat room = MAX(0, CGRectGetHeight(body) - actions - gap);
    // 16:9 when the details still get their minimum; half of what is left on a small screen.
    CGFloat videoHeight = MIN(floorf(CGRectGetWidth(body) * 9 / 16), room - 150);
    if (videoHeight < 80) videoHeight = floorf(room / 2);
    videoSlot = CGRectMake(CGRectGetMinX(body), CGRectGetMinY(body), CGRectGetWidth(body),
                           videoHeight);
    details = CGRectMake(CGRectGetMinX(body), CGRectGetMaxY(videoSlot) + gap,
                         CGRectGetWidth(body), MAX(0, room - videoHeight - gap));
  }
  [self layoutVideoInSlot:videoSlot];
  [self layoutDetailsInRect:details];

  [self applyRegionInk];
}

@end
