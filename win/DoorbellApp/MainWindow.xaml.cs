using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Media;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Kiosk;
using DoorbellApp.Pairing;
using DoorbellApp.Util;

namespace DoorbellApp
{
    public partial class MainWindow : Window
    {
        private readonly DispatcherTimer _clock = new DispatcherTimer();
        private readonly DispatcherTimer _callTimeout = new DispatcherTimer();
        private EventHandler _callTimeoutHandler;
        private readonly DispatcherTimer _replyTimeout = new DispatcherTimer();
        private readonly DispatcherTimer _pixelShift = new DispatcherTimer();
        private readonly DispatcherTimer _saverDrift = new DispatcherTimer();
        private DispatcherTimer _sosCountdown;
        private long _sosCountdownRevision;
        private readonly DispatcherTimer _tileRefresh = new DispatcherTimer();
        private readonly DispatcherTimer _statsRefresh = new DispatcherTimer();
        private readonly DispatcherTimer _emergencyPresentationTimeout = new DispatcherTimer();
        private readonly DispatcherTimer _incomingTimeout = new DispatcherTimer();
        private readonly DispatcherTimer _returnTimer = new DispatcherTimer();
        private readonly DispatcherTimer _clockSync = new DispatcherTimer();
        private readonly DispatcherTimer _homeRefresh = new DispatcherTimer();
        private readonly DispatcherTimer _answerDelay = new DispatcherTimer();
        private readonly DispatcherTimer _peerPoll = new DispatcherTimer();
        private readonly DispatcherTimer _h264Fallback = new DispatcherTimer();
        private readonly DispatcherTimer _peerH264Retry = new DispatcherTimer();
        // MediaElement gets this many tries per screen before the panel settles on MJPEG for the
        // rest of the call. Every retry re-subscribes the door station's H.264 encoder, so an
        // endless 3-second loop is not free for the station either. Why an attempt failed is
        // written by VideoDiagnostics (video.log + runtime status).
        private const int H264RetryBudget = 3;
        // Measured on the Toughpad (2026-09-05): MediaElement raises MediaOpened for the door
        // station's live fMP4 about 4.5 s after Open, after WMP has buffered a few seconds. A 3 s
        // wait therefore gave up on every attempt; MJPEG keeps showing until MediaOpened anyway.
        private static readonly TimeSpan H264OpenTimeout = TimeSpan.FromSeconds(8);
        private static readonly TimeSpan H264RetryDelay = TimeSpan.FromSeconds(3);
        private const string H264OpenTimeoutReason = "no_media_opened_within_8s";
        private int _incomingH264Failures;
        private int _inCallH264Failures;
        private readonly DispatcherTimer _pairingPoll = new DispatcherTimer();
        private readonly Random _rng = new Random();

        private PairingSnapshot _pairing = new PairingSnapshot();
        // "Set up later" hides onboarding until the operator taps the banner again.
        private bool _pairingSkipped;

        private MjpegStreamer _incomingStreamer;
        // Core-hosted fMP4/H.264 players (H264LiveStreamer). When the loaded Core exports
        // db_h264_player_*, these replace the MediaElement attempts below entirely.
        private H264LiveStreamer _incomingNative;
        private H264LiveStreamer _inCallNative;
        private MjpegStreamer _inCallStreamer;
        private string _inCallMjpegUrl = "";
        private string _inCallH264Url = "";
        private string _incomingDoor = "";
        private string _incomingHost;
        private string _incomingStreamUrl;
        private string _incomingStreamMp4Url;
        private string _incomingCallId = "";
        private int _incomingStageRevision;
        private string _lifecycleDoor = "";
        private string _lifecycleCallId = "";
        private int _lifecycleStageRevision;
        private readonly CallLifecycleState _callLifecycle = new CallLifecycleState();
        private long _lifecycleCoreGeneration;
        private bool _suppressLosingSipIdle;
        private readonly Dictionary<string, int> _acceptedChimeRevisions =
            new Dictionary<string, int>();
        private readonly Queue<string> _acceptedChimeOrder = new Queue<string>();
        private const int AcceptedChimeCapacity = 128;
        private string _activeCallId = "";
        private readonly CallTiming _callTiming = new CallTiming();
        private string _timedCallId = "";
        private long _timedCoreGeneration;
        private long _callViewRevision;
        private CallTiming.Snapshot _suspendedCallSample;
        private string _reportedRecoveryCallId = "";
        private string _callFlow = "purpose_first";
        private bool _monitorOnly;
        private string _sipMode = "";
        private bool _inCall;
        private bool _peerPollBusy;
        private long _peerFrameView;
        private System.Net.HttpWebRequest _peerFrameRequest;
        private readonly PeerFrameGate _peerFrameGate = new PeerFrameGate();
        private PeerFrameGate.Identity _peerDisplayedIdentity;
        private int _directPort = 47190;
        private int _secretTaps;
        private DateTime _secretFirst = DateTime.MinValue;
        private KioskHooks _kiosk;

        private int _brightness = 70;
        private bool _night;
        private bool _redTint;
        private int _screensaverAfterS = 120;
        private int _screensaverBrightness = 10;
        private string _screensaverMode = "dim";
        private bool SaverHidesImage { get { return _screensaverOn && _screensaverMode == "minimal"; } }
        private int _pixelShiftS = 300;
        private int _lastBrightnessSet = -1;
        private DateTime _lastActivity = DateTime.Now;
        private bool _screensaverOn;
        private static readonly Brush NightClockBrush = Frozen(new SolidColorBrush(Color.FromRgb(0x8B, 0x24, 0x1C)));
        private static readonly Brush SaverClockBrush = Frozen(new SolidColorBrush(Color.FromRgb(0xD9, 0xD9, 0xD9)));

        // Core republishes peers_changed and config_changed far faster than a person can read
        // them. Every handler asks for a refresh; the timer runs at most one a second, and that
        // one takes a single status document off the UI thread and hands it to every consumer.
        [Flags]
        private enum HomeRefresh
        {
            None = 0,
            Node = 1,
            Notice = 2,
            Tiles = 4,
            History = 8,
            Pairing = 16,
            All = Node | Notice | Tiles | History | Pairing,
        }

        /// <summary>One read of core per refresh, taken on a worker and applied on the UI thread.</summary>
        private sealed class HomeSnapshot
        {
            public Dictionary<string, object> Status;
            public Dictionary<string, object> Config;
            public Dictionary<string, object> Pairing;
            public Dictionary<string, object> CallLog;
            public Dictionary<string, object> Audio;
            public string SipBackend = "";
            public bool SipAvailable;
        }

        private HomeRefresh _pendingRefresh;
        private bool _homeRefreshBusy;

        private Dictionary<string, object> _cfg;
        // The display contract core publishes: appearance, theme and the automatic contrast
        // decision. Both status.display and the {"t":"display"} event carry the same document.
        private Dictionary<string, object> _display;
        private Dictionary<string, object> _status;
        private string _nodeId = "";
        private string _visitorLang = "ja";
        private string _themeColor;
        private string _themeHash;
        private MediaPlayer _audio;
        private MediaPlayer _effects;
        private MediaPlayer _callFeedback;
        private MediaPlayer _launchAudio;
        private Action _audioFallback;
        private string _callTitleOverride;
        private string _purposeChosenCallId = "";
        private string _activeCallFlow = "purpose_first";
        private string _incomingPurpose = "";
        private string _incomingLang = "";
        private SemanticUiOverrides _semanticStyles;
        private readonly SemanticUiApplier _semanticApplier = new SemanticUiApplier();

        private string _coreVersion = "";
        private string _appVersion = "";
        private int _batteryPct = -1;
        private bool _batteryCharging;
        private string _adminUrl = "";
        private string _renderedAdminQr = "";
        private readonly List<string> _tileDoors = new List<string>();
        private readonly Dictionary<string, Image> _tileImages =
            new Dictionary<string, Image>(StringComparer.Ordinal);
        private readonly Dictionary<string, Border> _tileNoticeChips =
            new Dictionary<string, Border>(StringComparer.Ordinal);
        private readonly Dictionary<string, string> _tileSnapshotUrls =
            new Dictionary<string, string>(StringComparer.Ordinal);
        // Tile captions are drawn over the tile surface and follow the same per-region ink rule.
        private readonly List<TextBlock> _tileLabels = new List<TextBlock>();
        private readonly HashSet<string> _tileFetching =
            new HashSet<string>(StringComparer.Ordinal);
        private int _unreadMissed;
        private string _latestCallHlc = "";
        private bool _showVideoStats = true;
        private bool _micMuted;
        private bool _monitorAudioOn;
        private bool _quickRepliesOpen;
        private string _noticeChipDoor = "";
        // Seconds until the incoming page returns home on its own, and whether the resident
        // stopped that return by tapping the number.
        private int _returnSecondsLeft;
        private bool _returnCancelled;
        private string _returnDoor = "";
        // The clock renders from a cached base: core's corrected wall clock and zone offset,
        // refreshed off the UI thread, never asked for on the tick that draws a second.
        private int _clockZoneOffsetMin;
        private bool _clockBaseKnown;
        private bool _clockSyncBusy;
        private bool _clockSyncPending;
        private long _clockBaseWallMs;
        private long _clockBaseTimestamp;
        private int _volumeCall = 80;
        private int _volumeSos = 100;
        private int _volumeIdle = 60;

        private bool _emergencyActive;
        private bool _emergencyVisual;
        private Dictionary<string, object> _emergencyReport;
        private int _sosCountdownS = 3;
        private int _sosCountdownLeft;
        private bool _cancelRequiresPin = true;
        private SoundPlayer _siren;
        private MemoryStream _sirenStream;
        private MediaPlayer _emergencyAudio;
        private readonly DeviceAlertNotifier _alertNotifier = new DeviceAlertNotifier();

        public MainWindow()
        {
            InitializeComponent();
            _visitorLang = App.Boot.UiLang;
            RefreshConfigCache(App.Core.Config());
            ApplyStrings();
            // Pick the home screen before the first frame so a role never flashes the other one.
            ApplyRoleHome();

            _clock.Interval = TimeSpan.FromSeconds(1);
            _clock.Tick += (s, e) => OnClockTick();
            _clock.Start();
            // Core's offset moves slowly, so it is re-read on its own schedule and whenever core
            // says the time source changed, never once per rendered second.
            _homeRefresh.Interval = TimeSpan.FromSeconds(1);
            _homeRefresh.Tick += (s, e) => { _homeRefresh.Stop(); RunHomeRefresh(); };
            _clockSync.Interval = TimeSpan.FromSeconds(30);
            _clockSync.Tick += (s, e) => SyncClockBase();
            _clockSync.Start();
            SyncClockBase();
            UpdateClock();

            _callTimeout.Interval = TimeSpan.FromSeconds(1);
            _replyTimeout.Tick += (s, e) => { _replyTimeout.Stop(); ReplyBanner.Visibility = Visibility.Collapsed; };

            _pixelShift.Tick += (s, e) =>
            {
                IdleShift.X = _rng.Next(-8, 9);
                IdleShift.Y = _rng.Next(-8, 9);
            };
            _saverDrift.Interval = TimeSpan.FromSeconds(30);
            _saverDrift.Tick += (s, e) => MoveSaverClock();
            SosSlide.Armed += ConfirmSos;
            SosSlide.ReviewRequested += OnSosReviewRequested;
            EmergencyClearSlide.Armed += ConfirmEmergencyClear;
            EmergencyClearSlide.ReviewRequested += () => EmergencyClearConfirm.Focus();
            // When the trigger goes away (SOS switched off, or a call takes the screen) an open
            // confirmation and a running countdown go with it.
            SosButton.IsVisibleChanged += (s, e) =>
            {
                if (SosButton.IsVisible) return;
                CloseSosConfirm();
                StopSosCountdown();
            };
            BindVisitorAction(CancelButton, Ui.VisitorActionKind.Cancel);
            BindVisitorAction(EndCallButton, Ui.VisitorActionKind.End);
            _tileRefresh.Interval = TimeSpan.FromSeconds(5);
            _tileRefresh.Tick += (s, e) => RefreshDoorTileStills();
            _statsRefresh.Interval = TimeSpan.FromSeconds(1);
            _statsRefresh.Tick += (s, e) => RefreshVideoStats();
            SizeChanged += (s, e) => ApplyResponsiveLayout();
            _emergencyPresentationTimeout.Tick += (s, e) =>
            {
                _emergencyPresentationTimeout.Stop();
                ExpireEmergencyPresentation();
            };

            _incomingTimeout.Interval = TimeSpan.FromSeconds(30);
            // A call nobody answered is over, but the live view stays until the return countdown
            // ends or the resident leaves the page.
            _incomingTimeout.Tick += (s, e) =>
                EndIncomingCall(true, Texts.T("calling.no_answer"));
            _returnTimer.Interval = TimeSpan.FromSeconds(1);
            _returnTimer.Tick += (s, e) => OnReturnTick();
            _answerDelay.Interval = TimeSpan.FromMilliseconds(400);
            _answerDelay.Tick += (s, e) => { _answerDelay.Stop(); PlaceAnswerCall(); };
            _peerPoll.Interval = TimeSpan.FromMilliseconds(500);
            _peerPoll.Tick += (s, e) =>
            {
                ExpirePeerFrameIfStale();
                PollPeerFrame();
            };
            _h264Fallback.Interval = H264OpenTimeout;
            _h264Fallback.Tick += (s, e) =>
            {
                _h264Fallback.Stop();
                if (IncomingView.Visibility != Visibility.Visible) return;
                if (IncomingH264.Visibility == Visibility.Visible)
                {
                    // Still no MediaOpened after the open timeout: count it as a failure.
                    VideoDiagnostics.RecordFailure("incoming", _incomingStreamMp4Url,
                        H264OpenTimeoutReason, null);
                    ScheduleIncomingH264Retry();
                    return;
                }
                // The MJPEG fallback is showing; the retry budget allowed another attempt.
                StartIncomingH264();
            };
            IncomingH264.MediaOpened += (s, e) =>
            {
                _h264Fallback.Stop();
                _incomingH264Failures = 0;
                VideoDiagnostics.RecordSuccess("incoming", _incomingStreamMp4Url);
                IncomingH264.Opacity = 1;
                IncomingLive.Visibility = Visibility.Collapsed;
                IncomingNoVideo.Visibility = Visibility.Collapsed;
            };
            IncomingH264.MediaFailed += (s, e) =>
            {
                VideoDiagnostics.RecordFailure("incoming", _incomingStreamMp4Url,
                    "media_failed", e.ErrorException);
                ScheduleIncomingH264Retry();
            };
            _peerH264Retry.Interval = H264OpenTimeout;
            _peerH264Retry.Tick += (s, e) =>
            {
                _peerH264Retry.Stop();
                if (InCallView.Visibility != Visibility.Visible) return;
                if (PeerH264.Visibility == Visibility.Visible)
                {
                    // Still no MediaOpened after the open timeout: count it like a failure.
                    VideoDiagnostics.RecordFailure("in_call", _inCallH264Url,
                        H264OpenTimeoutReason, null);
                    ScheduleInCallH264Retry();
                    return;
                }
                StartInCallH264();
            };
            PeerH264.MediaOpened += (s, e) =>
            {
                _peerH264Retry.Stop();
                _inCallH264Failures = 0;
                VideoDiagnostics.RecordSuccess("in_call", _inCallH264Url);
                PeerH264.Opacity = 1;
                PeerVideo.Visibility = Visibility.Collapsed;
            };
            PeerH264.MediaFailed += (s, e) =>
            {
                VideoDiagnostics.RecordFailure("in_call", _inCallH264Url, "media_failed",
                    e.ErrorException);
                ScheduleInCallH264Retry();
            };

            PreviewMouseDown += (s, e) => OnActivity();
            PreviewTouchDown += (s, e) => OnActivity();
            PreviewKeyDown += (s, e) => OnActivity();
            AddHandler(Button.ClickEvent, new RoutedEventHandler((s, e) =>
            {
                if (!ReferenceEquals(e.OriginalSource, CallButton))
                    _effects = PlayConfigured(_effects,
                        SoundValue("button_sound", "button_click"), false, null, _volumeIdle);
            }));

            App.Core.UiEventReceived += ev => {
                long viewRevision = System.Threading.Interlocked.Read(ref _callViewRevision);
                Dispatcher.BeginInvoke(new Action(() => {
                    if (ev.CoreGeneration != App.Core.Generation ||
                        (ev.T == "state" && viewRevision != _callViewRevision)) return;
                    OnUiEvent(ev);
                }));
            };
            Microsoft.Win32.SystemEvents.PowerModeChanged += OnPowerModeChanged;
            StateChanged += (s, e) => {
                if (WindowState == WindowState.Minimized) SuspendCallTiming();
                else ResumeCallTiming();
            };
            Closed += (s, e) => {
                LeaveConversations();
                Microsoft.Win32.SystemEvents.PowerModeChanged -= OnPowerModeChanged;
                StopSosCountdown();
                _callTimeout.Stop();
                System.Threading.Interlocked.Increment(ref _callViewRevision);
            };

            PairingOverlay.DismissRequested += OnPairingDismissed;
            // The banner is drawn over the window; the screens move down by its height while
            // it shows, so it covers nothing.
            PairBanner.IsVisibleChanged += (s, e) =>
                ScreenHost.Margin = new Thickness(0, PairBanner.IsVisible ? PairBanner.Height : 0, 0, 0);
            _pairingPoll.Interval = TimeSpan.FromSeconds(2);
            _pairingPoll.Tick += (s, e) => RequestHomeRefresh(HomeRefresh.Pairing);

            _showVideoStats = LoadVideoStatsPreference();
            Loaded += (s, e) =>
            {
                ApplyResponsiveLayout();
                if (App.Boot.Kiosk)
                {
                    Topmost = true;
                    _kiosk = new KioskHooks();
                    _kiosk.Enable();
                    // Under the service the supervisor runs in session 0 and cannot raise this
                    // window, so the kiosk keeps itself in front.
                    _foregroundGuard.Interval = TimeSpan.FromSeconds(3);
                    _foregroundGuard.Tick += (sender, args) => KeepKioskInFront();
                    _foregroundGuard.Start();
                }
                CoreClient.AdminPrompt = PromptAdminForWrite;
                StartUiTestHooks();
                Microsoft.Win32.SystemEvents.SessionSwitch += OnSessionSwitch;
                KioskHooks.KeepDisplayOn();
                // The first paint does not wait out the coalescing window, but still reads
                // core off the UI thread.
                RunHomeRefresh(HomeRefresh.All);
                _pairingPoll.Start();
                RecoverActiveCall();
                _launchAudio = PlayConfigured(_launchAudio,
                    SoundValue("launch_sound", "title_display"), false, null, _volumeIdle);
            };
            Closing += (s, e) =>
            {
                if (App.Boot.Kiosk && !_adminUnlocked && !_closingForExit) e.Cancel = true;
                else _kiosk?.Disable();
                if (!e.Cancel)
                {
                    _alertNotifier.Dispose();
                    _foregroundGuard.Stop();
                    _relockTimer.Stop();
                    Microsoft.Win32.SystemEvents.SessionSwitch -= OnSessionSwitch;
                    CoreClient.AdminPrompt = null;
                }
            };
        }

        private bool _adminUnlocked;
        private bool _closingForExit;
        private readonly DispatcherTimer _foregroundGuard = new DispatcherTimer();
        private readonly DispatcherTimer _relockTimer = new DispatcherTimer();
        // The kiosk relocks itself after this long; the supervisor's unlock window matches it.
        private static readonly TimeSpan KioskUnlockDuration = TimeSpan.FromMinutes(30);

        /// <summary>The supervisor asked the app to exit; the kiosk must not veto it.</summary>
        public void AllowClose() => _closingForExit = true;

        private void KeepKioskInFront()
        {
            if (_adminUnlocked || IsActive || OwnedWindows.Count > 0) return;
            if (WindowState == WindowState.Minimized) WindowState = WindowState.Maximized;
            Topmost = true;
            Activate();
        }

        /// <summary>
        /// Leaves kiosk mode after the administrator password was accepted. The supervisor is
        /// told over its channel (not through a file any user could create), and both the kiosk
        /// and Core's native admin window close again after KioskUnlockDuration.
        /// </summary>
        private void UnlockKiosk()
        {
            _adminUnlocked = true;
            _kiosk?.Disable();
            Topmost = false;
            WindowState = WindowState.Normal;
            WindowStyle = WindowStyle.SingleBorderWindow;
            ResizeMode = ResizeMode.CanResize;
            App.Watchdog?.Unlock(KioskUnlockDuration);
            _relockTimer.Stop();
            _relockTimer.Interval = KioskUnlockDuration;
            _relockTimer.Tick -= OnRelockTick;
            _relockTimer.Tick += OnRelockTick;
            _relockTimer.Start();
        }

        private void OnRelockTick(object sender, EventArgs e) => RelockKiosk();

        private void RelockKiosk()
        {
            _relockTimer.Stop();
            App.Core?.AdminLock();
            if (!_adminUnlocked) return;
            _adminUnlocked = false;
            App.Watchdog?.Lock();
            if (!App.Boot.Kiosk) return;
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            WindowState = WindowState.Maximized;
            Topmost = true;
            _kiosk?.Enable();
        }

        private void OnSessionSwitch(object sender, Microsoft.Win32.SessionSwitchEventArgs e)
        {
            if (e.Reason != Microsoft.Win32.SessionSwitchReason.SessionLock &&
                e.Reason != Microsoft.Win32.SessionSwitchReason.ConsoleDisconnect &&
                e.Reason != Microsoft.Win32.SessionSwitchReason.SessionLogoff) return;
            Dispatcher.BeginInvoke(new Action(RelockKiosk));
        }

        /// <summary>
        /// Core refused a native configuration write because its admin window is closed. Ask
        /// for the password once; CoreClient retries the write when this returns true.
        /// </summary>
        private bool PromptAdminForWrite()
        {
            if (!Dispatcher.CheckAccess())
                return (bool)Dispatcher.Invoke(new Func<bool>(PromptAdminForWrite));
            var prompt = new AdminDialog { Owner = this, Topmost = Topmost };
            return prompt.ShowDialog() == true;
        }

        private static Brush Frozen(SolidColorBrush b) { b.Freeze(); return b; }

        private static bool IsTrue(string v) =>
            v == "True" || v == "true" || v == "1";

        private void ApplyStrings()
        {
            Title = Texts.T("app.name");
            // A visitor is not told which door or device they are standing at; the button says
            // only what it does.
            CallButton.Content = Texts.T(ShowsHomePurposes() ? "door.call_direct" : "idle.call");
            TouchHint.Text = Texts.T("idle.touch_to_call");
            PurposeHint.Text = Texts.T("idle.choose_purpose");
            CallingText.Text = Texts.T("calling.title");
            CancelButton.Content = Texts.T("calling.cancel");
            CallingPurposeSkip.Content = Texts.T("purpose.skip");
            OfflineAction.Content = Texts.T(string.IsNullOrEmpty(_activeCallId) ? "idle.call" : "calling.cancel");
            ReplyCaption.Text = Texts.T("reply.banner");
            OfflineTitle.Text = Texts.T("offline.title");
            OfflineBody.Text = Texts.T("offline.body");
            ApplySosLabel();
            SosCountdownCancel.Content = Texts.T("sos.abort");
            EmergencyTitle.Text = Texts.T("emergency.title");
            EmergencyNote.Text = Texts.T("emergency.notified");
            EmergencyCancelButton.Content = Texts.T("emergency.cancel");
            ApplySosConfirmStrings();
            bool ending = _inCall && IncomingView.Visibility == Visibility.Visible;
            AnswerButton.Content = IconStack(ending ? "IconPhoneOff" : "IconPhone",
                Texts.T(ending ? "incall.end_call" : "ring.answer"),
                (Brush)FindResource(ending ? "OnNegative" : "OnPositive"));
            PaintAnswerSlot(ending);
            MonitorButton.Content = IconStack("IconEye", Texts.T("ring.monitor"));
            OpenDoorButton.Content = IconStack("IconLockOpen", Texts.T("ring.open_door"),
                (Brush)FindResource("Warning"));
            InCallOpenDoorButton.Content = IconStack("IconLockOpen", Texts.T("ring.open_door"),
                (Brush)FindResource("Warning"));
            IgnoreButton.Content = IconStack("IconBellOff", Texts.T("ring.ignore"), (Brush)FindResource("NegativeText"));
            IncomingNoVideo.Text = Texts.T("ring.no_video");
            InCallTitle.Text = Texts.T("incall.title");
            EndCallButton.Content = Texts.T("incall.end_call");
            QuickReplyToggle.Content = IconStack("IconMessageReply", Texts.T("ring.quick_replies"));
            NoticeChipText.Text = Texts.T("notice.chip");
            NoticeEditButton.Content = Texts.T("notice.edit");
            NoticeClearButton.Content = Texts.T("notice.clear");
            NoticePopoverClose.Content = Texts.T("monitor.close");
            ApplyNavigationStrings();
            AdminLinkTitle.Text = Texts.T("web_admin.title");
            NoticeGlobalButton.Content = IconLabel("IconBell", Texts.T("dash.notice_global"));
            DoorCounterLabel.Text = Texts.T("admin.role_door");
            PanelCounterLabel.Text = Texts.T("admin.role_indoor");
            if (DoorsSectionTitle.Text.Length == 0) DoorsSectionTitle.Text = Texts.T("dash.doors");
            HistoryTitle.Text = Texts.T("history.title");
            HistoryCloseButton.Content = Texts.T("monitor.close");
            HistoryFilterAll.Content = Texts.T("history.filter_all");
            HistoryFilterMissed.Content = Texts.T("history.filter_missed");
            HistoryMarkSeenButton.Content = Texts.T("history.mark_seen");
            HistoryMoreButton.Content = Texts.T("history.load_more");
            HistoryNote.Text = Texts.T("history.page_limit");
            ApplyMicLabel();
            ApplyMonitorLabel();
            MonitorPickerTitle.Text = Texts.T("monitor.choose");
            MonitorPickerClose.Content = Texts.T("monitor.close");
            CallingPurposeHint.Text = Texts.T("idle.choose_purpose");
            PairBannerText.Text = Texts.T("pair.not_set_up_banner");
            SaverHint.Text = Texts.T(App.Boot.Role == "door_station"
                ? "display.saver_door_hint" : "display.saver_panel_hint");
            if (App.Boot.Role == "door_station") TouchHint.Text = Texts.T(
                ShowsHomePurposes() ? "door.hint_purpose_first" : "door.hint_call");
            PairingOverlay.ApplyStrings();
            ApplyLayoutStrings();
        }

        private string DoorLabel(string door)
        {
            if (string.IsNullOrEmpty(door)) return "";
            var label = CoreClient.Dig(_cfg, "doors." + door + ".label." + Texts.Lang)
                        ?? CoreClient.Dig(_cfg, "doors." + door + ".label.ja");
            return label != null ? label.ToString() : door;
        }
    }
}
