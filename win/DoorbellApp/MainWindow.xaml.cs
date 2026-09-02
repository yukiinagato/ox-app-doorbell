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
        private readonly DispatcherTimer _replyTimeout = new DispatcherTimer();
        private readonly DispatcherTimer _pixelShift = new DispatcherTimer();
        private readonly DispatcherTimer _saverDrift = new DispatcherTimer();
        private readonly DispatcherTimer _sosCountdown = new DispatcherTimer();
        private readonly DispatcherTimer _tileRefresh = new DispatcherTimer();
        private readonly DispatcherTimer _statsRefresh = new DispatcherTimer();
        private readonly DispatcherTimer _emergencyPresentationTimeout = new DispatcherTimer();
        private readonly DispatcherTimer _incomingTimeout = new DispatcherTimer();
        private readonly DispatcherTimer _answerDelay = new DispatcherTimer();
        private readonly DispatcherTimer _peerPoll = new DispatcherTimer();
        private readonly DispatcherTimer _h264Fallback = new DispatcherTimer();
        private readonly DispatcherTimer _peerH264Retry = new DispatcherTimer();
        private readonly DispatcherTimer _pairingPoll = new DispatcherTimer();
        private readonly Random _rng = new Random();

        private PairingSnapshot _pairing = new PairingSnapshot();
        // "Set up later" hides onboarding until the operator taps the banner again.
        private bool _pairingSkipped;

        private MjpegStreamer _incomingStreamer;
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
        private bool _lifecycleAnswered;
        private bool _lifecycleEnded;
        private bool _suppressLosingSipIdle;
        private readonly Dictionary<string, int> _acceptedChimeRevisions =
            new Dictionary<string, int>();
        private readonly Queue<string> _acceptedChimeOrder = new Queue<string>();
        private const int AcceptedChimeCapacity = 128;
        private string _activeCallId = "";
        private long _activeCallExpiresAtMs;
        private string _reportedRecoveryCallId = "";
        private string _callFlow = "purpose_first";
        private bool _monitorOnly;
        private string _sipMode = "";
        private bool _inCall;
        private bool _peerPollBusy;
        private int _directPort = 47190;
        private int _secretTaps;
        private DateTime _secretFirst = DateTime.MinValue;
        private KioskHooks _kiosk;

        private int _brightness = 70;
        private bool _night;
        private bool _redTint;
        private int _screensaverAfterS = 120;
        private int _pixelShiftS = 300;
        private int _lastBrightnessSet = -1;
        private DateTime _lastActivity = DateTime.Now;
        private bool _screensaverOn;
        private static readonly Brush NightClockBrush = Frozen(new SolidColorBrush(Color.FromRgb(0x8B, 0x24, 0x1C)));
        private static readonly Brush SaverClockBrush = Frozen(new SolidColorBrush(Color.FromRgb(0x39, 0x42, 0x4C)));

        private Dictionary<string, object> _cfg;
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
        private readonly HashSet<string> _tileFetching =
            new HashSet<string>(StringComparer.Ordinal);
        private int _unreadMissed;
        private string _latestCallHlc = "";
        private bool _showVideoStats = true;
        private bool _micMuted;
        private bool _monitorAudioOn;
        private bool _quickRepliesOpen;
        private string _noticeChipDoor = "";
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
            RefreshConfigCache();
            ApplyStrings();
            // Pick the home screen before the first frame so a role never flashes the other one.
            ApplyRoleHome();

            _clock.Interval = TimeSpan.FromSeconds(1);
            _clock.Tick += (s, e) => OnClockTick();
            _clock.Start();
            UpdateClock();

            _callTimeout.Tick += (s, e) =>
            {
                _callTimeout.Stop();
                if (CancelActiveCall("timeout")) ShowIdle(Texts.T("calling.no_answer"));
                else CallingText.Text = Texts.T("calling.cancel_failed");
            };
            _replyTimeout.Tick += (s, e) => { _replyTimeout.Stop(); ReplyBanner.Visibility = Visibility.Collapsed; };

            _pixelShift.Tick += (s, e) =>
            {
                IdleShift.X = _rng.Next(-8, 9);
                IdleShift.Y = _rng.Next(-8, 9);
            };
            _saverDrift.Interval = TimeSpan.FromSeconds(30);
            _saverDrift.Tick += (s, e) => MoveSaverClock();
            _sosCountdown.Interval = TimeSpan.FromSeconds(1);
            _sosCountdown.Tick += (s, e) => OnSosCountdownTick();
            SosSlide.Armed += OnSosArmed;
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
            _incomingTimeout.Tick += (s, e) => CloseIncoming(true);
            _answerDelay.Interval = TimeSpan.FromMilliseconds(400);
            _answerDelay.Tick += (s, e) => { _answerDelay.Stop(); PlaceAnswerCall(); };
            _peerPoll.Interval = TimeSpan.FromMilliseconds(500);
            _peerPoll.Tick += (s, e) => PollPeerFrame();
            _h264Fallback.Interval = TimeSpan.FromSeconds(3);
            _h264Fallback.Tick += (s, e) =>
            {
                _h264Fallback.Stop();
                if (IncomingView.Visibility == Visibility.Visible &&
                    IncomingH264.Visibility == Visibility.Visible) ScheduleIncomingH264Retry();
            };
            IncomingH264.MediaOpened += (s, e) =>
            {
                _h264Fallback.Stop();
                IncomingH264.Opacity = 1;
                IncomingLive.Visibility = Visibility.Collapsed;
                IncomingNoVideo.Visibility = Visibility.Collapsed;
            };
            IncomingH264.MediaFailed += (s, e) => ScheduleIncomingH264Retry();
            _peerH264Retry.Interval = TimeSpan.FromSeconds(3);
            _peerH264Retry.Tick += (s, e) =>
            {
                _peerH264Retry.Stop();
                if (InCallView.Visibility == Visibility.Visible) StartInCallH264();
            };
            PeerH264.MediaOpened += (s, e) =>
            {
                _peerH264Retry.Stop();
                PeerH264.Opacity = 1;
                PeerVideo.Visibility = Visibility.Collapsed;
            };
            PeerH264.MediaFailed += (s, e) => ScheduleInCallH264Retry();

            PreviewMouseDown += (s, e) => OnActivity();
            PreviewTouchDown += (s, e) => OnActivity();
            PreviewKeyDown += (s, e) => OnActivity();
            AddHandler(Button.ClickEvent, new RoutedEventHandler((s, e) =>
            {
                if (!ReferenceEquals(e.OriginalSource, CallButton))
                    _effects = PlayConfigured(_effects,
                        SoundValue("button_sound", "button_click"), false, null, _volumeIdle);
            }));

            App.Core.UiEventReceived += ev => Dispatcher.BeginInvoke(new Action(() => OnUiEvent(ev)));

            PairingOverlay.DismissRequested += OnPairingDismissed;
            _pairingPoll.Interval = TimeSpan.FromSeconds(2);
            _pairingPoll.Tick += (s, e) => RefreshPairingState();

            _showVideoStats = LoadVideoStatsPreference();
            Loaded += (s, e) =>
            {
                ApplyResponsiveLayout();
                if (App.Boot.Kiosk)
                {
                    Topmost = true;
                    _kiosk = new KioskHooks();
                    _kiosk.Enable();
                }
                KioskHooks.KeepDisplayOn();
                RefreshNodeInfo();
                RefreshCallHistory();
                RefreshPairingState();
                _pairingPoll.Start();
                RecoverActiveCall();
                _launchAudio = PlayConfigured(_launchAudio,
                    SoundValue("launch_sound", "title_display"), false, null, _volumeIdle);
            };
            Closing += (s, e) =>
            {
                if (App.Boot.Kiosk && !_adminUnlocked) e.Cancel = true;
                else _kiosk?.Disable();
                if (!e.Cancel) _alertNotifier.Dispose();
            };
        }

        private bool _adminUnlocked;

        private static Brush Frozen(SolidColorBrush b) { b.Freeze(); return b; }

        private static bool IsTrue(string v) =>
            v == "True" || v == "true" || v == "1";

        private void ApplyStrings()
        {
            Title = Texts.T("app.name");
            CallButton.Content = Texts.T("idle.call_button", DoorLabel(App.Boot.Door)).Trim();
            TouchHint.Text = Texts.T("idle.touch_to_call");
            PurposeHint.Text = Texts.T("idle.choose_purpose");
            CallingText.Text = Texts.T("calling.title");
            CancelButton.Content = Texts.T("calling.cancel");
            ReplyCaption.Text = Texts.T("reply.banner");
            OfflineTitle.Text = Texts.T("offline.title");
            OfflineBody.Text = Texts.T("offline.body");
            ApplySosLabel();
            SosCountdownCancel.Content = Texts.T("sos.abort");
            EmergencyTitle.Text = Texts.T("emergency.title");
            EmergencyNote.Text = Texts.T("emergency.notified");
            EmergencyCancelButton.Content = Texts.T("emergency.cancel");
            AnswerButton.Content = Texts.T("ring.answer");
            MonitorButton.Content = Texts.T("ring.monitor");
            OpenDoorButton.Content = Texts.T("ring.open_door");
            InCallOpenDoorButton.Content = Texts.T("ring.open_door");
            IgnoreButton.Content = Texts.T("ring.ignore");
            IncomingNoVideo.Text = Texts.T("ring.no_video");
            InCallTitle.Text = Texts.T("incall.title");
            EndCallButton.Content = Texts.T("incall.end_call");
            QuickReplyToggle.Content = Texts.T("ring.quick_replies");
            NoticeChipText.Text = Texts.T("notice.chip");
            NoticeEditButton.Content = Texts.T("notice.edit");
            NoticeClearButton.Content = Texts.T("notice.clear");
            NoticePopoverClose.Content = Texts.T("monitor.close");
            AdminEntryButton.Content = Texts.T("admin.title");
            AdminLinkTitle.Text = Texts.T("web_admin.open");
            NoticeGlobalButton.Content = Texts.T("dash.notice_global");
            RecentCallsTitle.Text = Texts.T("history.title");
            SeeAllCallsButton.Content = Texts.T("dash.see_all");
            HistoryTitle.Text = Texts.T("history.title");
            HistoryCloseButton.Content = Texts.T("monitor.close");
            HistoryFilterAll.Content = Texts.T("history.filter_all");
            HistoryFilterMissed.Content = Texts.T("history.filter_missed");
            HistoryMarkSeenButton.Content = Texts.T("history.mark_seen");
            HistoryMoreButton.Content = Texts.T("history.load_more");
            HistoryNote.Text = Texts.T("history.page_limit");
            ApplyMicLabel();
            ApplyMonitorLabel();
            OpenMonitorButton.Content = Texts.T("monitor.open");
            MonitorPickerTitle.Text = Texts.T("monitor.choose");
            MonitorPickerClose.Content = Texts.T("monitor.close");
            CallingPurposeHint.Text = Texts.T("idle.choose_purpose");
            PairBannerText.Text = Texts.T("pair.not_set_up_banner");
            if (App.Boot.Role == "door_station") TouchHint.Text = Texts.T("door.hint_call");
            PairingOverlay.ApplyStrings();
        }

        private string DoorLabel(string door)
        {
            if (string.IsNullOrEmpty(door)) return "";
            var label = CoreClient.Dig(_cfg, "doors." + door + ".label." + Texts.Lang)
                        ?? CoreClient.Dig(_cfg, "doors." + door + ".label.ja");
            return label != null ? label.ToString() : door;
        }

        private void OnClockTick()
        {
            UpdateClock();
            if (!_screensaverOn && !_emergencyActive && _screensaverAfterS > 0 &&
                !PairingOverlay.IsActive &&
                IdleView.Visibility == Visibility.Visible &&
                CallingView.Visibility != Visibility.Visible &&
                OfflineView.Visibility != Visibility.Visible &&
                IncomingView.Visibility != Visibility.Visible &&
                InCallView.Visibility != Visibility.Visible &&
                (DateTime.Now - _lastActivity).TotalSeconds > _screensaverAfterS)
                EnterScreensaver();
        }

        // Every clock is rendered from db_core_local_time_json, so the cluster time zone and any
        // NTP correction apply without touching this machine's own clock.
        private void UpdateClock()
        {
            string time, date;
            if (!CoreLocalTime(out time, out date))
            {
                var now = DateTime.Now;
                time = now.ToString("HH:mm:ss");
                date = now.ToString("yyyy年M月d日") + " (" + Weekday((int)now.DayOfWeek) + ")";
            }
            ClockText.Text = time;
            DateText.Text = date;
            DashClock.Text = time;
            DashDate.Text = date;
            if (_screensaverOn)
            {
                SaverClock.Text = time;
                SaverDate.Text = date;
            }
        }

        private static string Weekday(int dayOfWeek)
        {
            string[] names = { "日", "月", "火", "水", "木", "金", "土" };
            return dayOfWeek >= 0 && dayOfWeek < names.Length ? names[dayOfWeek] : "";
        }

        private bool CoreLocalTime(out string time, out string date)
        {
            time = "";
            date = "";
            var local = App.Core.LocalTime(0);
            if (local == null) return false;
            object known;
            int hour = DictInt(local, "hh", -1);
            int minute = DictInt(local, "mm", -1);
            int second = DictInt(local, "ss", -1);
            if (hour < 0 || minute < 0 || second < 0) return false;
            time = hour.ToString("00") + ":" + minute.ToString("00") + ":" + second.ToString("00");
            string iso = DictStr(local, "date");
            DateTime parsed;
            if (DateTime.TryParse(iso, System.Globalization.CultureInfo.InvariantCulture,
                                  System.Globalization.DateTimeStyles.None, out parsed))
                date = parsed.ToString("yyyy年M月d日") + " (" +
                       Weekday((int)parsed.DayOfWeek) + ")";
            else
                date = iso;
            if (local.TryGetValue("known", out known) && known is bool && !(bool)known)
                System.Diagnostics.Debug.WriteLine("core reports an unknown time zone");
            return true;
        }

        private void RefreshNodeInfo()
        {
            RefreshConfigCache();
            var st = App.Core.Status();
            if (st != null)
            {
                try
                {
                    var node = st["node"] as Dictionary<string, object>;
                    if (node != null)
                    {
                        object id;
                        if (node.TryGetValue("id", out id) && id != null) _nodeId = id.ToString();
                        ReadPowerFromStatus(st);
                        ApplyVersionLine(DictStr(node, "name"), DictStr(node, "version"));
                    }
                }
                catch { }
                ApplyDisplayFromStatus(st);
            }
            if (st != null && App.Boot.Role == "door_station" && !string.IsNullOrEmpty(App.Boot.Door))
            {
                var vl = CoreClient.Dig(st, "visitor_lang." + App.Boot.Door);
                SetVisitorLang(vl != null ? vl.ToString() : "ja");
            }
            RefreshSosConfig(_cfg);
            RefreshAudioVolumes();
            var dp = CoreClient.Dig(_cfg, "sip.direct_port");
            if (dp != null)
            {
                int p;
                if (int.TryParse(dp.ToString(), out p) && p > 0) _directPort = p;
            }
            // v2 contract is a top-level string. Keep the historical ui.call_flow
            // read only so a staged fleet upgrade does not change behaviour mid-call.
            var flow = CoreClient.Dig(_cfg, "call_flow") ??
                       CoreClient.Dig(_cfg, "ui.call_flow");
            _callFlow = flow != null && flow.ToString() == "ring_then_purpose" ?
                "ring_then_purpose" : "purpose_first";
            ApplyTheme();
            ApplyAppearance();
            BuildPurposeButtons();
            BuildLangBar();
            ApplyStrings();
            ApplyRoleHome();
            RefreshAdminLink();
            RefreshNoticeSurfaces();
            RefreshDoorTiles();
            _semanticStyles = SemanticUiOverrides.Load(_cfg, _nodeId, App.DataDir);
            ApplySemanticStyles();
            PublishUiStyleWithAdvisories();
            OpenMonitorButton.Visibility = App.Boot.Role == "indoor_panel" ?
                Visibility.Visible : Visibility.Collapsed;
            MicButton.Visibility = App.Core.SipMicMuteAvailable ?
                Visibility.Visible : Visibility.Collapsed;
            InCallMicButton.Visibility = MicButton.Visibility;
            bool sip = App.Core.SipAvailable;
            AnswerButton.IsEnabled = sip && !_suppressLosingSipIdle;
            MonitorButton.IsEnabled = sip;
            OpenDoorButton.IsEnabled = sip;
            InCallOpenDoorButton.IsEnabled = sip;
        }


        private void RefreshConfigCache()
        {
            _cfg = App.Core.Config();
            Texts.SetConfig(_cfg);
        }

        private void ApplySemanticStyles()
        {
            if (_semanticStyles == null) return;
            _semanticApplier.Apply(CallButton, _semanticStyles.Get("call.primary"), false);
            _semanticApplier.Apply(CancelButton, _semanticStyles.Get("cancel.call"), true);
            _semanticApplier.Apply(EndCallButton, _semanticStyles.Get("call.end"), true);
            _semanticApplier.Apply(SosButton, _semanticStyles.Get("sos.trigger"), true);
            _semanticApplier.Apply(EmergencyCancelButton, _semanticStyles.Get("sos.cancel"), true);
            foreach (FrameworkElement child in PurposeGrid.Children)
                _semanticApplier.Apply(child, _semanticStyles.Get("purpose.button"), false);
            foreach (FrameworkElement child in CallingPurposeGrid.Children)
                _semanticApplier.Apply(child, _semanticStyles.Get("purpose.button"), false);
            foreach (FrameworkElement child in QuickReplyPanel.Children)
                _semanticApplier.Apply(child, _semanticStyles.Get("reply.button"), false);
            foreach (FrameworkElement child in new FrameworkElement[]
                     { AnswerButton, MonitorButton, OpenDoorButton, IgnoreButton })
                _semanticApplier.Apply(child, _semanticStyles.Get("ring.action"), false);
            _semanticApplier.Apply(IncomingTitle, _semanticStyles.Get("ring.title"), false);
            _semanticApplier.Apply(MonitorPickerClose, _semanticStyles.Get("monitor.close"), true);
        }

        private string ThemeValue(string leaf)
        {
            object v = null;
            if (!string.IsNullOrEmpty(_nodeId))
                v = CoreClient.Dig(_cfg, "devices." + _nodeId + ".local.theme." + leaf);
            if (v == null) v = CoreClient.Dig(_cfg, "display.theme." + leaf);
            return v != null ? v.ToString() : null;
        }

        private void ApplyTheme()
        {
            if (App.SafeMode)
            {
                _themeColor = null;
                _themeHash = null;
                Background = (Brush)FindResource("Bg");
                ThemeBgImage.Source = null;
                ThemeBgImage.Visibility = Visibility.Collapsed;
                return;
            }
            string color = ThemeValue("bg_color");
            if (color != _themeColor)
            {
                _themeColor = color;
                if (!string.IsNullOrEmpty(color))
                {
                    try
                    {
                        var c = (Color)ColorConverter.ConvertFromString(color);
                        Background = Frozen(new SolidColorBrush(c));
                    }
                    catch (Exception ex)
                    {
                        Debug.WriteLine("Ignoring invalid theme background color: " + color + " " + ex.Message);
                    }
                }
                else
                {
                    Background = (Brush)FindResource("Bg");
                }
            }

            string hash = ThemeValue("bg_image");
            if (string.IsNullOrEmpty(hash))
            {
                _themeHash = null;
                ThemeBgImage.Source = null;
                ThemeBgImage.Visibility = Visibility.Collapsed;
                return;
            }
            if (hash == _themeHash && ThemeBgImage.Source != null) return;
            _themeHash = hash;
            LoadThemeImage(hash);
        }

        private void LoadThemeImage(string hash)
        {
            string url = "http://127.0.0.1:" + App.Boot.HttpPort + "/asset/" + hash;
            Task.Run(() =>
            {
                byte[] data = null;
                try
                {
                    using (var wc = new System.Net.WebClient())
                        data = wc.DownloadData(url);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine("Theme image fetch failed; waiting for asset_ready: " + ex.Message);
                }
                if (data == null) return;
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (_themeHash != hash) return;
                    try
                    {
                        var bmp = new BitmapImage();
                        bmp.BeginInit();
                        bmp.CacheOption = BitmapCacheOption.OnLoad;
                        bmp.StreamSource = new MemoryStream(data);
                        bmp.EndInit();
                        bmp.Freeze();
                        ThemeBgImage.Source = bmp;
                        ThemeBgImage.Visibility = Visibility.Visible;
                    }
                    catch (Exception ex)
                    {
                        Debug.WriteLine("Ignoring invalid theme image: " + ex.Message);
                    }
                }));
            });
        }

        private static List<string> SortedByOrder(Dictionary<string, object> map)
        {
            var ids = new List<string>();
            if (map == null) return ids;
            ids.AddRange(map.Keys);
            ids.Sort((a, b) =>
            {
                int c = OrderOf(map, a).CompareTo(OrderOf(map, b));
                return c != 0 ? c : string.CompareOrdinal(a, b);
            });
            return ids;
        }

        private static int OrderOf(Dictionary<string, object> map, string id)
        {
            var e = map[id] as Dictionary<string, object>;
            object v;
            if (e != null && e.TryGetValue("order", out v) && v != null)
            {
                int i;
                if (int.TryParse(v.ToString(), out i)) return i;
            }
            return 999;
        }

        private static string LabelOf(Dictionary<string, object> entry, string lang, string fallback)
        {
            var label = entry != null && entry.ContainsKey("label")
                ? entry["label"] as Dictionary<string, object> : null;
            if (label != null)
            {
                object v;
                if (label.TryGetValue(lang, out v) && v != null && !string.IsNullOrEmpty(v.ToString()))
                    return v.ToString();
                if (label.TryGetValue("ja", out v) && v != null && !string.IsNullOrEmpty(v.ToString()))
                    return v.ToString();
            }
            return fallback;
        }

        private void BuildPurposeButtons()
        {
            PurposeGrid.Children.Clear();
            CallingPurposeGrid.Children.Clear();
            var purposes = CoreClient.Dig(_cfg, "visit_purposes") as Dictionary<string, object>;
            if (App.Boot.Role != "door_station" || purposes == null || purposes.Count == 0)
            {
                PurposeSection.Visibility = Visibility.Collapsed;
                CallingPurposeSection.Visibility = Visibility.Collapsed;
                return;
            }
            foreach (var id in SortedByOrder(purposes))
            {
                var entry = purposes[id] as Dictionary<string, object>;
                string label = LabelOf(entry, Texts.Lang, id);
                object icon;
                string iconText = entry != null && entry.TryGetValue("icon", out icon) && icon != null
                    ? icon.ToString() : "";
                PurposeGrid.Children.Add(MakePurposeButton(id, iconText, label));
                CallingPurposeGrid.Children.Add(MakePurposeButton(id, iconText, label));
            }
            PurposeSection.Visibility = Visibility.Visible;
            CallingPurposeSection.Visibility = _callFlow == "ring_then_purpose" &&
                !string.IsNullOrEmpty(_activeCallId) ? Visibility.Visible : Visibility.Collapsed;
        }

        private Button MakePurposeButton(string id, string icon, string label)
        {
            var panel = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
            if (!string.IsNullOrEmpty(icon))
                panel.Children.Add(new TextBlock
                {
                    Text = icon,
                    FontSize = 34,
                    HorizontalAlignment = HorizontalAlignment.Center,
                });
            panel.Children.Add(new TextBlock
            {
                Text = label,
                FontSize = 22,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                Foreground = (Brush)FindResource("Fg"),
            });
            var b = new Button
            {
                Content = panel,
                MinWidth = 190,
                MinHeight = 110,
                Margin = new Thickness(8),
                Padding = new Thickness(12, 10, 12, 10),
                Background = (Brush)FindResource("Card"),
                Foreground = (Brush)FindResource("Fg"),
                BorderBrush = (Brush)FindResource("Dim"),
                Cursor = Cursors.Hand,
                Tag = id,
            };
            b.Click += OnPurposeClick;
            if (_semanticStyles != null)
                _semanticApplier.Apply(b, _semanticStyles.Get("purpose.button"), false);
            return b;
        }

        private void OnPurposeClick(object sender, RoutedEventArgs e)
        {
            var b = sender as Button;
            if (b == null) return;
            string id = b.Tag as string;
            if (string.IsNullOrEmpty(id)) return;
            var purposes = CoreClient.Dig(_cfg, "visit_purposes") as Dictionary<string, object>;
            var entry = purposes != null && purposes.ContainsKey(id)
                ? purposes[id] as Dictionary<string, object> : null;
            string label = LabelOf(entry, Texts.Lang, id);
            if (_callFlow == "ring_then_purpose" && !string.IsNullOrEmpty(_activeCallId))
            {
                if (!App.Core.SelectPurpose(App.Boot.Door, _activeCallId, id))
                {
                    CallingText.Text = Texts.T("purpose.select_failed");
                    return;
                }
                CallingPurposeSection.Visibility = Visibility.Collapsed;
            }
            else
            {
                _activeCallId = App.Core.PressPurpose(App.Boot.Door, id) ?? "";
                if (string.IsNullOrEmpty(_activeCallId))
                {
                    ShowOffline();
                    return;
                }
                _activeCallExpiresAtMs = ResolveActiveCallExpiryMs();
            }
            ShowCalling(Texts.T("purpose.sent", label));
        }

        private void BuildLangBar()
        {
            LangBar.Children.Clear();
            var langs = CoreClient.Dig(_cfg, "ui.languages") as System.Collections.IEnumerable;
            var list = new List<string>();
            if (langs != null && !(langs is string))
                foreach (var l in langs)
                    if (l != null && !string.IsNullOrEmpty(l.ToString())) list.Add(l.ToString());
            if (App.Boot.Role != "door_station" || list.Count < 2)
            {
                LangBar.Visibility = Visibility.Collapsed;
                return;
            }
            foreach (var lang in list)
            {
                var b = new Button
                {
                    Content = LangDisplayName(lang),
                    FontSize = 20,
                    Padding = new Thickness(22, 8, 22, 8),
                    Margin = new Thickness(6, 0, 6, 0),
                    Background = (Brush)FindResource("Card"),
                    Foreground = (Brush)FindResource("Dim"),
                    BorderBrush = (Brush)FindResource("Dim"),
                    Cursor = Cursors.Hand,
                    Tag = lang,
                };
                b.Click += OnLangClick;
                LangBar.Children.Add(b);
            }
            LangBar.Visibility = Visibility.Visible;
            LangBar.ToolTip = Texts.T("door.lang_switch");
            UpdateLangBarSelection();
        }

        private static string LangDisplayName(string lang)
        {
            switch (lang)
            {
                case "ja": return "日本語";
                case "en": return "English";
                case "zh": return "中文";
                default: return lang;
            }
        }

        private void UpdateLangBarSelection()
        {
            foreach (var child in LangBar.Children)
            {
                var b = child as Button;
                if (b == null) continue;
                bool on = (b.Tag as string) == _visitorLang;
                b.Background = on ? (Brush)FindResource("Accent") : (Brush)FindResource("Card");
                b.Foreground = on ? Brushes.Black : (Brush)FindResource("Dim");
            }
        }

        private void OnLangClick(object sender, RoutedEventArgs e)
        {
            var b = sender as Button;
            if (b == null) return;
            string lang = b.Tag as string;
            App.Core.SetVisitorLang(App.Boot.Door, lang);
            SetVisitorLang(lang);
        }

        private void SetVisitorLang(string lang)
        {
            if (string.IsNullOrEmpty(lang)) lang = "ja";
            if (_visitorLang == lang) return;
            _visitorLang = lang;
            Texts.SetLang(lang);
            ApplyStrings();
            BuildPurposeButtons();
            UpdateLangBarSelection();
        }


        private void PlayAudio(string path, Action fallback)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path))
            {
                _audioFallback = null;
                if (fallback != null) fallback();
                return;
            }
            _audioFallback = fallback;
            try
            {
                if (_audio == null)
                {
                    _audio = new MediaPlayer();
                    _audio.Volume = _volumeCall / 100.0;
                    _audio.MediaFailed += (s, e) =>
                    {
                        Debug.WriteLine("Custom audio playback failed; using fallback: " + e.ErrorException);
                        var fb = _audioFallback;
                        _audioFallback = null;
                        if (fb != null) fb();
                    };
                }
                _audio.Volume = _volumeCall / 100.0;
                _audio.Open(new Uri(path));
                _audio.Play();
            }
            catch (Exception ex)
            {
                Debug.WriteLine("Custom audio could not be opened; using fallback: " + ex.Message);
                _audioFallback = null;
                if (fallback != null) fallback();
            }
        }

        private string SoundValue(string key, string fallback)
        {
            var value = CoreClient.Dig(_cfg, "ui." + key);
            return value is string ? (string)value : fallback;
        }

        private bool ConfigBool(string path, bool fallback)
        {
            var value = CoreClient.Dig(_cfg, path);
            return value is bool ? (bool)value : fallback;
        }

        private static string BundledSoundFile(string value)
        {
            switch (value)
            {
                case "outdoor_call_alert": return "outdoor_call_alert.mp3";
                case "button_click": return "button_click.mp3";
                case "school_chime": return "学校のチャイム.mp3";
                case "indoor_update": return "indoor_update.mp3";
                case "title_display": return "title_display.mp3";
                default: return null;
            }
        }

        /// <summary>
        /// Effective 呼出 / SOS / 通常 volumes for this device, resolved by core from the device
        /// override and the cluster default (db_core_audio_json).
        /// </summary>
        private void RefreshAudioVolumes()
        {
            var levels = App.Core.AudioVolumes(_nodeId);
            if (levels == null) return;
            _volumeCall = Clamp(DictInt(levels, "call", _volumeCall));
            _volumeSos = Clamp(DictInt(levels, "sos", _volumeSos));
            _volumeIdle = Clamp(DictInt(levels, "idle", _volumeIdle));
        }

        private static int Clamp(int percent)
        {
            return percent < 0 ? 0 : (percent > 100 ? 100 : percent);
        }

        private MediaPlayer PlayConfigured(MediaPlayer current, string value, bool loop,
                                           Action fallback = null, int volumePercent = -1)
        {
            StopPlayer(ref current);
            if (string.IsNullOrEmpty(value)) return null;
            string path = null;
            if (value.StartsWith("asset:") && value.Length == 70)
                path = Path.Combine(App.DataDir, "assets", value.Substring(6));
            else
            {
                var filename = BundledSoundFile(value);
                if (filename != null)
                    path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Audio", filename);
            }
            if (string.IsNullOrEmpty(path) || !File.Exists(path))
            {
                fallback?.Invoke();
                return null;
            }
            try
            {
                var player = new MediaPlayer
                { Volume = volumePercent < 0 ? 1.0 : Clamp(volumePercent) / 100.0 };
                player.MediaEnded += (s, e) =>
                {
                    if (loop) { player.Position = TimeSpan.Zero; player.Play(); }
                };
                player.MediaFailed += (s, e) => fallback?.Invoke();
                player.Open(new Uri(path));
                player.Play();
                return player;
            }
            catch
            {
                fallback?.Invoke();
                return null;
            }
        }

        private static void StopPlayer(ref MediaPlayer player)
        {
            if (player == null) return;
            try { player.Stop(); player.Close(); } catch { }
            player = null;
        }

        private static int DictInt(Dictionary<string, object> d, string key, int def)
        {
            object v;
            if (d != null && d.TryGetValue(key, out v) && v != null)
            {
                int i;
                if (int.TryParse(v.ToString(), out i)) return i;
            }
            return def;
        }

        private static long DictLong(Dictionary<string, object> d, string key, long def)
        {
            object value;
            long number;
            return d != null && d.TryGetValue(key, out value) && value != null &&
                   long.TryParse(value.ToString(), out number) ? number : def;
        }

        private static double DictDouble(Dictionary<string, object> d, string key, double def)
        {
            object value;
            double number;
            return d != null && d.TryGetValue(key, out value) && value != null &&
                   double.TryParse(value.ToString(), out number) &&
                   !double.IsNaN(number) && !double.IsInfinity(number) ? number : def;
        }

        private static bool DictBool(Dictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) && v is bool && (bool)v;
        }

        private void ApplyDisplayFromStatus(Dictionary<string, object> st)
        {
            var disp = CoreClient.Dig(st, "display") as Dictionary<string, object>;
            if (disp != null)
            {
                _brightness = DictInt(disp, "brightness", _brightness);
                _night = DictBool(disp, "night");
                _redTint = DictBool(disp, "red_tint");
                _screensaverAfterS = DictInt(disp, "screensaver_after_s", _screensaverAfterS);
                _pixelShiftS = DictInt(disp, "pixel_shift_s", _pixelShiftS);
                ApplyDisplay();
            }
        }

        private void ApplyDisplay()
        {
            NightTint.Visibility = (_night && _redTint) ? Visibility.Visible : Visibility.Collapsed;
            ClockText.Foreground = _night ? NightClockBrush : (Brush)FindResource("Fg");
            DateText.Foreground = _night ? NightClockBrush : (Brush)FindResource("Dim");
            DashClock.Foreground = ClockText.Foreground;
            DashDate.Foreground = DateText.Foreground;
            SaverClock.Foreground = _night ? NightClockBrush : SaverClockBrush;

            if (!App.SafeMode && _pixelShiftS > 0)
            {
                _pixelShift.Interval = TimeSpan.FromSeconds(_pixelShiftS);
                if (!_pixelShift.IsEnabled) _pixelShift.Start();
            }
            else
            {
                _pixelShift.Stop();
                IdleShift.X = 0;
                IdleShift.Y = 0;
            }

            if (!_emergencyActive)
                SetBrightnessAsync(_screensaverOn ? Math.Min(_brightness, 10) : _brightness);
            ApplyAutoInk();
        }

        private void SetBrightnessAsync(int percent)
        {
            if (percent < 0) percent = 0;
            if (percent > 100) percent = 100;
            if (percent == _lastBrightnessSet) return;
            _lastBrightnessSet = percent;
            byte val = (byte)percent;
            Task.Run(() =>
            {
                try
                {
                    using (var searcher = new ManagementObjectSearcher(
                               "root\\wmi", "SELECT * FROM WmiMonitorBrightnessMethods"))
                    using (var results = searcher.Get())
                    {
                        foreach (ManagementObject mo in results)
                        {
                            using (mo)
                                mo.InvokeMethod("WmiSetBrightness", new object[] { (uint)1, val });
                        }
                    }
                }
                catch (Exception ex)
                {
                    Debug.WriteLine("Brightness adjustment is unavailable: " + ex.Message);
                }
            });
        }

        private void OnActivity()
        {
            _lastActivity = DateTime.Now;
            ExitScreensaver();
        }

        private void EnterScreensaver()
        {
            if (_screensaverOn) return;
            _screensaverOn = true;
            UpdateClock();
            ScreensaverView.Visibility = Visibility.Visible;
            MoveSaverClock();
            if (!App.SafeMode) _saverDrift.Start();
            SetBrightnessAsync(Math.Min(_brightness, 10));
        }

        private void ExitScreensaver()
        {
            if (!_screensaverOn) return;
            _screensaverOn = false;
            _saverDrift.Stop();
            ScreensaverView.Visibility = Visibility.Collapsed;
            if (!_emergencyActive) SetBrightnessAsync(_brightness);
        }

        private void MoveSaverClock()
        {
            double w = ScreensaverView.ActualWidth - SaverBlock.ActualWidth;
            double h = ScreensaverView.ActualHeight - SaverBlock.ActualHeight;
            if (w < 1) w = 1;
            if (h < 1) h = 1;
            Canvas.SetLeft(SaverBlock, _rng.NextDouble() * w);
            Canvas.SetTop(SaverBlock, _rng.NextDouble() * h);
        }

        private void RefreshSosConfig(Dictionary<string, object> cfg)
        {
            bool show = App.Boot.Role == "indoor_panel";
            var roles = CoreClient.Dig(cfg, "emergency.button_on_roles") as System.Collections.IEnumerable;
            if (roles != null && !(roles is string))
            {
                show = false;
                foreach (var r in roles)
                    if (r != null && r.ToString() == App.Boot.Role) show = true;
            }
            SosButton.Visibility = show ? Visibility.Visible : Visibility.Collapsed;

            // Slide mode is the only trigger; "hold" stays accepted so an older configuration
            // keeps validating, and the cancellable countdown is what it configures.
            var countdown = CoreClient.Dig(cfg, "emergency.trigger.countdown_s");
            _sosCountdownS = 3;
            if (countdown != null)
            {
                int seconds;
                if (int.TryParse(countdown.ToString(), out seconds) &&
                    seconds >= 0 && seconds <= 10) _sosCountdownS = seconds;
            }
            ApplySosLabel();

            var pin = CoreClient.Dig(cfg, "emergency.cancel_requires_pin");
            _cancelRequiresPin = !(pin is bool) || (bool)pin;
        }

        // Deliberate two-part label: the second line is the smaller, muted explanation and the
        // break is authored in the catalog rather than produced by wrapping.
        private void ApplySosLabel()
        {
            string label = Texts.T("sos.slide_label", _sosCountdownS);
            int split = label.IndexOf('\n');
            SosText.Text = split >= 0 ? label.Substring(0, split) : label;
            SosHint.Text = split >= 0 ? label.Substring(split + 1) : "";
            SosHint.Visibility = SosHint.Text.Length == 0 ?
                Visibility.Collapsed : Visibility.Visible;
        }

        /// <summary>The thumb was released past 90 %: start the cancellable countdown.</summary>
        private void OnSosArmed()
        {
            if (_emergencyActive) return;
            if (_sosCountdownS <= 0)
            {
                CommitEmergency();
                return;
            }
            _sosCountdownLeft = _sosCountdownS;
            SosCountdownText.Text = Texts.T("sos.countdown", _sosCountdownLeft);
            SosCountdownView.Visibility = Visibility.Visible;
            _sosCountdown.Stop();
            _sosCountdown.Start();
        }

        private void OnSosCountdownTick()
        {
            _sosCountdownLeft--;
            if (_sosCountdownLeft > 0)
            {
                SosCountdownText.Text = Texts.T("sos.countdown", _sosCountdownLeft);
                return;
            }
            StopSosCountdown();
            CommitEmergency();
        }

        // Core only ever learns about the emergency when the countdown reaches zero.
        private void CommitEmergency()
        {
            if (!App.Core.Emergency(true))
                System.Diagnostics.Debug.WriteLine("SOS state was not durably committed");
        }

        private void OnSosCountdownCancel(object sender, RoutedEventArgs e) => StopSosCountdown();

        private void StopSosCountdown()
        {
            _sosCountdown.Stop();
            _sosCountdownLeft = 0;
            SosCountdownView.Visibility = Visibility.Collapsed;
            SosSlide.Reset();
        }

        private void ShowEmergency(UiEvent ev)
        {
            bool active = EventBool(ev, "active", false);
            bool inApp = EventHasChannel(ev, "in_app");
            bool systemNotification = EventHasChannel(ev, "system_notification");
            bool visual = EventBool(ev, "visual", true);
            bool sticky = EventBool(ev, "sticky", active);
            double ttl = Math.Max(0, DictDouble(ev.Data, "ttl_s", active ? 0 : 10));
            int volume = Math.Max(0, Math.Min(100,
                DictInt(ev.Data, "alarm_volume", _volumeSos)));
            bool hasSound = !string.IsNullOrEmpty(ev.Str("alarm_sound")) ||
                            !string.IsNullOrEmpty(ev.Str("audio_path"));
            bool sound = hasSound && volume > 0;
            bool systemSound = sound && (!inApp || !active);
            var channelResults = new List<Dictionary<string, object>>();

            _emergencyPresentationTimeout.Stop();
            HideEmergency();
            string colorLimitation = ApplyEmergencyPresentationColors(ev);

            if (inApp)
                channelResults.Add(AlertChannelResult(
                    "in_app", active ? "presented" : "cleared", visual && active,
                    sound && active, sticky && active, ttl, colorLimitation));

            if (systemNotification)
            {
                bool posted = _alertNotifier.Show(
                    Texts.T("emergency.title"),
                    Texts.T(active ? "emergency.notified" : "emergency.cancel"), visual);
                string limitation = sticky ? "sticky_system_notification_unsupported" : "";
                if (sound && !systemSound) limitation = "sound_owned_by_in_app_channel";
                string systemResult = !visual && !systemSound ?
                    "suppressed_by_presentation" :
                    (posted || systemSound ? "presented" : "unsupported");
                channelResults.Add(AlertChannelResult(
                    "system_notification", systemResult,
                    visual && posted, systemSound, false, ttl, limitation));
            }
            object rawChannels;
            if (ev.Data != null && ev.Data.TryGetValue("channels", out rawChannels) &&
                rawChannels is System.Collections.IEnumerable && !(rawChannels is string))
            {
                foreach (object raw in (System.Collections.IEnumerable)rawChannels)
                {
                    string channel = raw == null ? "" : raw.ToString();
                    if (channel == "in_app" || channel == "system_notification" ||
                        string.IsNullOrEmpty(channel)) continue;
                    channelResults.Add(AlertChannelResult(
                        channel, "unsupported", false, false, false, 0,
                        "unsupported_channel"));
                }
            }

            PublishEmergencyReport(ev, active, channelResults);
            if (!active)
            {
                if (systemSound) StartSiren(ev, volume, sticky);
                if (systemNotification && !sticky && ttl > 0)
                {
                    _emergencyPresentationTimeout.Interval = TimeSpan.FromSeconds(ttl);
                    _emergencyPresentationTimeout.Start();
                }
                return;
            }

            _emergencyActive = inApp;
            _emergencyVisual = inApp && visual;
            _callTimeout.Stop();
            if (_emergencyVisual)
            {
                ExitScreensaver();
                CallingView.Visibility = Visibility.Collapsed;
                ReplyBanner.Visibility = Visibility.Collapsed;
                EmergencyView.Visibility = Visibility.Visible;
                SetBrightnessAsync(100);
            }
            else EmergencyView.Visibility = Visibility.Collapsed;

            if (sound && (inApp || systemNotification)) StartSiren(ev, volume, sticky);
            else StopSiren();

            if (!sticky && ttl > 0)
            {
                _emergencyPresentationTimeout.Interval = TimeSpan.FromSeconds(ttl);
                _emergencyPresentationTimeout.Start();
            }
        }

        private void HideEmergency()
        {
            StopSosCountdown();
            _emergencyPresentationTimeout.Stop();
            _alertNotifier.Clear();
            _emergencyActive = false;
            StopSiren();
            EmergencyView.Visibility = Visibility.Collapsed;
            if (_emergencyVisual) ShowIdle();
            _emergencyVisual = false;
            _lastActivity = DateTime.Now;
            ApplyDisplay();
        }

        private void ExpireEmergencyPresentation()
        {
            HideEmergency();
            if (_emergencyReport == null) return;
            var previous = _emergencyReport["channels"] as List<Dictionary<string, object>>;
            var expired = new List<Dictionary<string, object>>();
            if (previous != null)
            {
                foreach (var item in previous)
                {
                    var next = new Dictionary<string, object>(item);
                    string result = DictStr(next, "result");
                    if (result != "unsupported" && result != "permission_denied")
                        next["result"] = "ttl_expired";
                    expired.Add(next);
                }
            }
            _emergencyReport["channels"] = expired;
            _emergencyReport["updated_at_ms"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            App.Core.PublishDeviceAlertStatus(App.Boot.Role, App.SafeMode, _emergencyReport);
        }

        private static Dictionary<string, object> AlertChannelResult(
            string channel, string result, bool visual, bool sound, bool sticky,
            double ttl, string limitation)
        {
            var value = new Dictionary<string, object>
            {
                { "channel", channel },
                { "result", result },
                { "visual_applied", visual },
                { "sound_applied", sound },
                { "sticky_applied", sticky },
                { "ttl_s", ttl },
            };
            if (!string.IsNullOrEmpty(limitation)) value["limitation"] = limitation;
            return value;
        }

        private string ApplyEmergencyPresentationColors(UiEvent ev)
        {
            const string defaultBackground = "#8C0D0A";
            const string defaultForeground = "#FFFFFF";
            const string defaultAccent = "#FFFFFF";
            string background = ev == null ? "" : ev.Str("background");
            string foreground = ev == null ? "" : ev.Str("foreground");
            string accent = ev == null ? "" : ev.Str("accent");
            background = string.IsNullOrEmpty(background) ? defaultBackground : background;
            foreground = string.IsNullOrEmpty(foreground) ? defaultForeground : foreground;
            accent = string.IsNullOrEmpty(accent) ? defaultAccent : accent;
            bool valid = IsExactHexColor(background) && IsExactHexColor(foreground) &&
                         IsExactHexColor(accent) &&
                         SemanticColorSafety.HasContrast(foreground, background, 4.5) &&
                         SemanticColorSafety.HasContrast(accent, background, 3.0);
            if (!valid)
            {
                background = defaultBackground;
                foreground = defaultForeground;
                accent = defaultAccent;
            }
            var backgroundBrush = Frozen(new SolidColorBrush(
                (Color)ColorConverter.ConvertFromString(background)));
            var foregroundBrush = Frozen(new SolidColorBrush(
                (Color)ColorConverter.ConvertFromString(foreground)));
            var accentBrush = Frozen(new SolidColorBrush(
                (Color)ColorConverter.ConvertFromString(accent)));
            string accentText = SemanticColorSafety.HasContrast("#000000", accent, 4.5)
                ? "#000000" : "#FFFFFF";
            EmergencyView.Background = backgroundBrush;
            EmergencyTitle.Foreground = foregroundBrush;
            EmergencyNote.Foreground = foregroundBrush;
            EmergencyCancelButton.Background = accentBrush;
            EmergencyCancelButton.Foreground = Frozen(new SolidColorBrush(
                (Color)ColorConverter.ConvertFromString(accentText)));
            return valid ? "" : "invalid_emergency_presentation_colors";
        }

        private static bool IsExactHexColor(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length != 7 || value[0] != '#') return false;
            for (int i = 1; i < value.Length; i++)
                if (!Uri.IsHexDigit(value[i])) return false;
            return true;
        }

        private void PublishEmergencyReport(UiEvent ev, bool active,
            List<Dictionary<string, object>> channelResults)
        {
            _emergencyReport = new Dictionary<string, object>
            {
                { "schema_version", 1 },
                { "event_hlc", ev.Str("event_hlc") },
                { "active", active },
                { "result", channelResults.Count == 0 ? "not_requested" : "applied" },
                { "channels", channelResults },
                { "updated_at_ms", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() },
            };
            App.Core.PublishDeviceAlertStatus(App.Boot.Role, App.SafeMode, _emergencyReport);
        }

        private static bool EventBool(UiEvent ev, string key, bool fallback)
        {
            if (ev == null || ev.Data == null || !ev.Data.ContainsKey(key)) return fallback;
            object value = ev.Data[key];
            return value is bool ? (bool)value : IsTrue(value == null ? "" : value.ToString());
        }

        private static bool EventHasChannel(UiEvent ev, string channel)
        {
            object raw;
            if (ev == null || ev.Data == null || !ev.Data.TryGetValue("channels", out raw) ||
                !(raw is System.Collections.IEnumerable) || raw is string)
                return channel == "in_app";
            foreach (object value in (System.Collections.IEnumerable)raw)
                if (value != null && value.ToString() == channel) return true;
            return false;
        }

        private void OnEmergencyCancelClick(object sender, RoutedEventArgs e)
        {
            if (_cancelRequiresPin)
            {
                var dlg = new AdminDialog { Owner = this };
                if (dlg.ShowDialog() != true) return;
            }
            if (App.Core.Emergency(false)) HideEmergency();
            else System.Diagnostics.Debug.WriteLine("SOS clear was not durably committed");
        }

        private void StartSiren(UiEvent ev, int volume, bool sticky)
        {
            StopSiren();
            try
            {
                string path = ev == null ? "" : ev.Str("audio_path");
                if (!string.IsNullOrEmpty(path) && File.Exists(path))
                {
                    var player = new MediaPlayer { Volume = volume / 100.0 };
                    player.MediaEnded += (s, e) =>
                    {
                        if (sticky) { player.Position = TimeSpan.Zero; player.Play(); }
                    };
                    player.Open(new Uri(path));
                    player.Play();
                    _emergencyAudio = player;
                    return;
                }
                _sirenStream = BuildSirenWav(volume);
                _siren = new SoundPlayer(_sirenStream);
                _sirenStream.Position = 0;
                if (sticky) _siren.PlayLooping();
                else _siren.Play();
            }
            catch (Exception ex)
            {
                Debug.WriteLine("Siren playback is unavailable: " + ex.Message);
            }
        }

        private void StopSiren()
        {
            try { _siren?.Stop(); } catch { }
            _siren = null;
            _sirenStream?.Dispose();
            _sirenStream = null;
            if (_emergencyAudio != null)
            {
                try { _emergencyAudio.Stop(); _emergencyAudio.Close(); } catch { }
                _emergencyAudio = null;
            }
        }

        private static MemoryStream BuildSirenWav(int volume)
        {
            const int rate = 22050;
            const int seconds = 2;
            int n = rate * seconds;
            int dataLen = n * 2;
            var ms = new MemoryStream();
            var bw = new BinaryWriter(ms);
            bw.Write(Encoding.ASCII.GetBytes("RIFF"));
            bw.Write(36 + dataLen);
            bw.Write(Encoding.ASCII.GetBytes("WAVE"));
            bw.Write(Encoding.ASCII.GetBytes("fmt "));
            bw.Write(16);
            bw.Write((short)1);        // PCM
            bw.Write((short)1);        // mono
            bw.Write(rate);
            bw.Write(rate * 2);        // byte rate
            bw.Write((short)2);        // block align
            bw.Write((short)16);       // bits
            bw.Write(Encoding.ASCII.GetBytes("data"));
            bw.Write(dataLen);
            double gain = Math.Max(0, Math.Min(100, volume)) / 100.0;
            for (int i = 0; i < n; i++)
            {
                double t = (double)i / rate;
                double freq = (i / (rate / 2)) % 2 == 0 ? 880.0 : 660.0;
                double env = Math.Min(1.0, Math.Min(i, n - i) / (rate * 0.02));
                short s = (short)(Math.Sin(2 * Math.PI * freq * t) *
                                  0.6 * short.MaxValue * env * gain);
                bw.Write(s);
            }
            bw.Flush();
            ms.Position = 0;
            return ms;
        }

        private void ShowIdle(string hint = null)
        {
            StopPlayer(ref _callFeedback);
            _callTitleOverride = null;
            CallingView.Visibility = Visibility.Collapsed;
            CallingPurposeSection.Visibility = Visibility.Collapsed;
            OfflineView.Visibility = Visibility.Collapsed;
            IdleView.Visibility = Visibility.Visible;
            if (string.IsNullOrEmpty(_activeCallId)) _activeCallExpiresAtMs = 0;
            if (hint != null) TouchHint.Text = hint;
        }

        private void ShowOffline()
        {
            ExitScreensaver();
            IdleView.Visibility = Visibility.Collapsed;
            CallingView.Visibility = Visibility.Collapsed;
            OfflineView.Visibility = Visibility.Visible;
        }

        private long ResolveActiveCallExpiryMs()
        {
            if (string.IsNullOrEmpty(_activeCallId)) return 0;
            var status = App.Core.Status();
            var calls = status != null && status.ContainsKey("active_calls")
                ? status["active_calls"] as System.Collections.IEnumerable : null;
            if (calls == null) return 0;
            foreach (var item in calls)
            {
                var call = item as Dictionary<string, object>;
                if (call != null && DictStr(call, "call_id") == _activeCallId)
                    return DictLong(call, "expires_at_ms", 0);
            }
            return 0;
        }

        private void ShowCalling(string title = null, long expiresAtMs = 0)
        {
            ExitScreensaver();
            if (title != null) _callTitleOverride = title;
            CallingText.Text = _callTitleOverride ?? Texts.T("calling.title");
            IdleView.Visibility = Visibility.Collapsed;
            CallingView.Visibility = Visibility.Visible;
            CallingPurposeSection.Visibility = _callFlow == "ring_then_purpose" &&
                !string.IsNullOrEmpty(_activeCallId) ? Visibility.Visible : Visibility.Collapsed;
            _callTimeout.Stop();
            if (expiresAtMs > 0) _activeCallExpiresAtMs = expiresAtMs;
            if (_activeCallExpiresAtMs <= 0)
                _activeCallExpiresAtMs = ResolveActiveCallExpiryMs();
            if (_activeCallExpiresAtMs > 0)
            {
                long remainingMs = _activeCallExpiresAtMs -
                    DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                _callTimeout.Interval = TimeSpan.FromMilliseconds(Math.Max(1, remainingMs));
                _callTimeout.Start();
            }
            if (App.SafeMode)
            {
                Pulse.BeginAnimation(OpacityProperty, null);
                Pulse.Opacity = 1.0;
            }
            else
            {
                var anim = new DoubleAnimation(0.25, 1.0, TimeSpan.FromSeconds(0.9))
                { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever };
                Pulse.BeginAnimation(OpacityProperty, anim);
            }
        }

        private void OnUiEvent(UiEvent ev)
        {
            HandlePairingEvent(ev);
            switch (ev.T)
            {
                case "state":
                    var stv = ev.Str("state");
                    if (stv == "calling") { if (App.Boot.Role == "door_station") ShowCalling(); }
                    else if (stv == "idle") OnSipIdle();
                    else if (stv == "in_call" || stv == "answered")
                    {
                        StopPlayer(ref _callFeedback);
                        OnSipInCall(ev);
                    }
                    else if (stv == "degraded" && App.Boot.Role == "door_station")
                        CallingText.Text = Texts.T("sip.unavailable");
                    else if (stv == "offline") ShowOffline();
                    break;
                case "event":
                    string eventType = ev.Str("type");
                    bool purposeApplied = false;
                    // press is replicated to every node. It updates call identity only; the
                    // targeted schema-v2 chime below is the sole trigger for ring UI/audio.
                    if (eventType == "press")
                    {
                        if (App.Boot.Role == "door_station" &&
                            (string.IsNullOrEmpty(ev.Str("door")) || ev.Str("door") == App.Boot.Door) &&
                            string.IsNullOrEmpty(_activeCallId)) _activeCallId = ev.Str("call_id");
                        if (ev.Str("call_id") == _activeCallId)
                        {
                            long expiry = DictLong(ev.Data, "expires_at_ms", 0);
                            if (expiry > 0)
                            {
                                _activeCallExpiresAtMs = expiry;
                                if (CallingView.Visibility == Visibility.Visible)
                                    ShowCalling();
                            }
                        }
                        if (App.Boot.Role == "indoor_panel") UpdateIncomingCallData(ev);
                    }
                    else if (eventType == "reply" && !_inCall &&
                             IncomingView.Visibility == Visibility.Visible &&
                             CallMatches(ev.Str("call_id"), ev.Str("door"),
                                         _incomingCallId, _incomingDoor))
                        CloseIncoming(true);
                    if (eventType == "purpose_selected")
                        purposeApplied = HandlePurposeSelected(ev);
                    if (App.Boot.Role == "indoor_panel" &&
                        (eventType == "call_cancelled" || eventType == "call_answered" ||
                         eventType == "call_ended" ||
                         (eventType == "purpose_selected" && purposeApplied)))
                        _effects = PlayConfigured(_effects,
                            SoundValue("update_sound", "indoor_update"), false, null,
                            _volumeIdle);
                    if (eventType == "call_answered")
                    {
                        StopPlayer(ref _callFeedback);
                        int answeredStage = Math.Max(0,
                            DictInt(ev.Data, "stage_revision", 0));
                        string owner = ev.Str("dialog_owner");
                        if (string.IsNullOrEmpty(owner)) owner = ev.Str("device");
                        if (_inCall && ev.Str("call_id") == _lifecycleCallId &&
                            !string.IsNullOrEmpty(owner) && !string.IsNullOrEmpty(_nodeId) &&
                            owner != _nodeId)
                        {
                            // The earliest confirmed claim owns the call. Terminate this losing
                            // SIP leg without publishing call_ended for the winning dialog.
                            _lifecycleAnswered = false;
                            _lifecycleEnded = true;
                            _inCall = false;
                            _sipMode = "";
                            App.Core.SipHangup();
                            CloseInCall();
                            ShowIdle();
                        }
                        else if (!_inCall && IncomingView.Visibility == Visibility.Visible &&
                            answeredStage >= _incomingStageRevision &&
                            CallMatches(ev.Str("call_id"), ev.Str("door"),
                                        _incomingCallId, _incomingDoor)) CloseIncoming(true);
                    }
                    if (eventType == "call_cancelled" || eventType == "call_ended")
                    {
                        StopPlayer(ref _callFeedback);
                        if (CallMatches(ev.Str("call_id"), ev.Str("door"),
                                        _activeCallId, App.Boot.Door))
                        {
                            _activeCallId = "";
                            _activeCallExpiresAtMs = 0;
                            _callTimeout.Stop();
                            if (App.Boot.Role == "door_station") ShowIdle();
                        }
                        int resolvedStage = Math.Max(0,
                            DictInt(ev.Data, "stage_revision", 0));
                        if (IncomingView.Visibility == Visibility.Visible &&
                            (eventType == "call_cancelled" ||
                             resolvedStage >= _incomingStageRevision) &&
                            CallMatches(ev.Str("call_id"), ev.Str("door"),
                                        _incomingCallId, _incomingDoor)) CloseIncoming(true);
                    }
                    break;
                case "chime":
                    if (!AcceptChimeRevision(ev)) break;
                    ExitScreensaver();
                    if (App.Boot.Role == "indoor_panel") ShowIncoming(ev);
                    if (!string.IsNullOrEmpty(ev.Str("audio_path")))
                        PlayAudio(ev.Str("audio_path"), () => SystemSounds.Exclamation.Play());
                    else
                        _audio = PlayConfigured(_audio, ev.Str("sound"), false,
                            () => SystemSounds.Exclamation.Play(), _volumeCall);
                    break;
                case "call_recovery_required":
                    RecoverCall(ev);
                    break;
                case "visitor_lang":
                    if (App.Boot.Role == "door_station" &&
                        (ev.Str("door") == App.Boot.Door || string.IsNullOrEmpty(ev.Str("door"))))
                        SetVisitorLang(ev.Str("lang"));
                    if (IncomingView.Visibility == Visibility.Visible &&
                        ev.Str("door") == _incomingDoor)
                    {
                        _incomingLang = ev.Str("lang");
                        UpdateIncomingBadges();
                        BuildQuickReplies();
                    }
                    break;
                case "asset_ready":
                    if (!string.IsNullOrEmpty(_themeHash) && ev.Str("hash") == _themeHash &&
                        ThemeBgImage.Source == null)
                        LoadThemeImage(_themeHash);
                    break;
                case "reply":
                    ExitScreensaver();
                    if (IncomingView.Visibility == Visibility.Visible && !_inCall &&
                        (string.IsNullOrEmpty(ev.Str("door")) || ev.Str("door") == _incomingDoor))
                        CloseIncoming(true);
                    if (!string.IsNullOrEmpty(ev.Str("audio_path")))
                    {
                        string spoken = ev.Str("text");
                        string spokenLang = ev.Str("lang");
                        PlayAudio(ev.Str("audio_path"), () => App.Core.SpeakText(spoken, spokenLang));
                    }
                    ReplyText.Text = ev.Str("text");
                    ReplyBanner.Visibility = Visibility.Visible;
                    double ttl = 30;
                    double.TryParse(ev.Str("ttl_s"), out ttl);
                    _replyTimeout.Interval = TimeSpan.FromSeconds(ttl <= 0 ? 30 : ttl);
                    _replyTimeout.Stop();
                    _replyTimeout.Start();
                    _callTimeout.Stop();
                    _activeCallId = "";
                    ShowIdle();
                    break;
                case "display":
                    _brightness = DictInt(ev.Data, "brightness", _brightness);
                    _night = IsTrue(ev.Str("night"));
                    _redTint = IsTrue(ev.Str("red_tint"));
                    _screensaverAfterS = DictInt(ev.Data, "screensaver_after_s", _screensaverAfterS);
                    _pixelShiftS = DictInt(ev.Data, "pixel_shift_s", _pixelShiftS);
                    ApplyDisplay();
                    break;
                case "emergency":
                    ShowEmergency(ev);
                    break;
                case "peers_changed":
                case "config_changed":
                    RefreshNodeInfo();
                    break;
                case "time_changed":
                    // The source flipped or the correction moved: redraw every clock now.
                    UpdateClock();
                    ApplyAppearance();
                    break;
                case "power_changed":
                    _batteryPct = DictInt(ev.Data, "battery_pct", _batteryPct);
                    _batteryCharging = EventBool(ev, "charging", _batteryCharging);
                    RefreshNodeInfo();
                    break;
                case "notice_changed":
                    RefreshConfigCache();
                    RefreshNoticeSurfaces();
                    RefreshDoorTiles();
                    break;
                case "call_log_changed":
                    _unreadMissed = DictInt(ev.Data, "unread_missed", _unreadMissed);
                    RefreshCallHistory();
                    break;
            }
        }


        private static string DictStr(Dictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) && v != null ? v.ToString() : "";
        }

        private static bool CallMatches(string eventCallId, string eventDoor,
                                        string currentCallId, string currentDoor)
        {
            if (!string.IsNullOrEmpty(eventCallId) && !string.IsNullOrEmpty(currentCallId))
                return eventCallId == currentCallId;
            return string.IsNullOrEmpty(eventDoor) || string.IsNullOrEmpty(currentDoor) ||
                   eventDoor == currentDoor;
        }

        private bool AcceptChimeRevision(UiEvent ev)
        {
            string callId = ev.Str("call_id");
            if (string.IsNullOrEmpty(callId)) return true;
            int revision = Math.Max(0, DictInt(ev.Data, "stage_revision", 0));
            int accepted;
            if (_acceptedChimeRevisions.TryGetValue(callId, out accepted))
            {
                if (revision <= accepted) return false;
                _acceptedChimeRevisions[callId] = revision;
                return true;
            }
            _acceptedChimeRevisions[callId] = revision;
            _acceptedChimeOrder.Enqueue(callId);
            while (_acceptedChimeOrder.Count > AcceptedChimeCapacity)
                _acceptedChimeRevisions.Remove(_acceptedChimeOrder.Dequeue());
            return true;
        }

        private bool HandlePurposeSelected(UiEvent ev)
        {
            if (App.Boot.Role != "indoor_panel") return false;
            string callId = ev.Str("call_id");
            string door = ev.Str("door");
            bool matchesIncoming = CallMatches(callId, door, _incomingCallId, _incomingDoor);
            bool matchesAnswer = !string.IsNullOrEmpty(_lifecycleCallId) &&
                CallMatches(callId, door, _lifecycleCallId, _lifecycleDoor);
            if (!matchesIncoming && !matchesAnswer) return false;

            int revision = Math.Max(0,
                DictInt(ev.Data, "stage_revision", _incomingStageRevision));
            int currentRevision = _incomingStageRevision;
            if (matchesAnswer) currentRevision = Math.Max(currentRevision, _lifecycleStageRevision);
            if (revision <= currentRevision) return false;

            bool supersedesAnswer = matchesAnswer && !_monitorOnly &&
                (_sipMode == "answer" || _answerDelay.IsEnabled || _inCall);
            if (!supersedesAnswer)
            {
                UpdateIncomingCallData(ev);
                return true;
            }

            _answerDelay.Stop();
            _lifecycleAnswered = false;
            _lifecycleEnded = true;
            _lifecycleCallId = "";
            _lifecycleDoor = "";
            _inCall = false;
            _sipMode = "";
            _suppressLosingSipIdle = true;
            CloseInCall();
            ShowIncoming(ev);
            AnswerButton.IsEnabled = false;
            App.Core.SipHangup();
            return true;
        }

        private void UpdateIncomingCallData(UiEvent ev)
        {
            if (ev == null) return;
            string callId = ev.Str("call_id");
            string door = ev.Str("door");
            if (IncomingView.Visibility == Visibility.Visible &&
                !CallMatches(callId, door, _incomingCallId, _incomingDoor)) return;
            if (!string.IsNullOrEmpty(callId)) _incomingCallId = callId;
            if (!string.IsNullOrEmpty(door)) _incomingDoor = door;
            _incomingStageRevision = Math.Max(_incomingStageRevision,
                DictInt(ev.Data, "stage_revision", _incomingStageRevision));
            if (!string.IsNullOrEmpty(ev.Str("purpose"))) _incomingPurpose = ev.Str("purpose");
            if (!string.IsNullOrEmpty(ev.Str("visitor_lang"))) _incomingLang = ev.Str("visitor_lang");
            if (IncomingView.Visibility == Visibility.Visible)
            {
                UpdateIncomingBadges();
                BuildQuickReplies();
            }
        }

        private void RecoverActiveCall()
        {
            UiEvent pending = App.Core.TakePendingRecovery();
            if (pending != null)
            {
                RecoverCall(pending);
                return;
            }
            var status = App.Core.Status();
            var calls = status != null && status.ContainsKey("active_calls")
                ? status["active_calls"] as System.Collections.IEnumerable : null;
            if (calls == null) return;
            foreach (var item in calls)
            {
                var call = item as Dictionary<string, object>;
                if (call == null) continue;
                string state = DictStr(call, "state");
                bool ownsDialog = state == "in_call" &&
                                  DictStr(call, "dialog_owner") == _nodeId;
                bool ownsWaiting = state == "ringing" && App.Boot.Role == "door_station" &&
                                   DictStr(call, "origin") == _nodeId &&
                                   (string.IsNullOrEmpty(DictStr(call, "door")) ||
                                    DictStr(call, "door") == App.Boot.Door);
                if (!ownsDialog && !ownsWaiting) continue;
                var data = new Dictionary<string, object>(call) { { "t", "call_recovery_required" } };
                RecoverCall(new UiEvent { T = "call_recovery_required", Data = data });
                return;
            }
        }

        private void RecoverCall(UiEvent ev)
        {
            string callId = ev == null ? "" : ev.Str("call_id");
            if (string.IsNullOrEmpty(callId) || callId == _reportedRecoveryCallId) return;
            var status = App.Core.Status();
            if (string.IsNullOrEmpty(_nodeId))
                _nodeId = DictStr(CoreClient.Dig(status, "node") as Dictionary<string, object>, "id");
            if (string.IsNullOrEmpty(_nodeId))
            {
                ReportRecoveryOnce(callId, false);
                return;
            }

            Dictionary<string, object> active = null;
            var calls = status != null && status.ContainsKey("active_calls")
                ? status["active_calls"] as System.Collections.IEnumerable : null;
            if (calls != null)
                foreach (var item in calls)
                {
                    var call = item as Dictionary<string, object>;
                    if (call != null && DictStr(call, "call_id") == callId)
                    {
                        active = call;
                        break;
                    }
                }
            if (active == null)
            {
                string eventOwner = ev == null ? "" : ev.Str("dialog_owner");
                if (string.IsNullOrEmpty(eventOwner) || eventOwner == _nodeId)
                    ReportRecoveryOnce(callId, false);
                return;
            }

            string persistedState = DictStr(active, "state");
            string eventState = ev == null ? "" : ev.Str("state");
            string owner = ev == null ? "" : ev.Str("dialog_owner");
            if (string.IsNullOrEmpty(owner)) owner = DictStr(active, "dialog_owner");
            if (persistedState == "in_call" || eventState == "in_call")
            {
                if (owner != _nodeId) return;
                // A WPF process restart destroys the PJSIP dialog; rebuilding controls alone is
                // never evidence that the established audio call survived.
                ReportRecoveryOnce(callId, false);
                return;
            }

            bool waiting = persistedState == "ringing" || eventState == "ringing" ||
                           eventState == "purpose_pending";
            bool localDoor = App.Boot.Role == "door_station" &&
                             DictStr(active, "origin") == _nodeId &&
                             (string.IsNullOrEmpty(DictStr(active, "door")) ||
                              DictStr(active, "door") == App.Boot.Door);
            if (!waiting || !localDoor) return;
            long expiry = DictLong(active, "expires_at_ms", 0);
            if (expiry <= DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())
            {
                ReportRecoveryOnce(callId, false);
                return;
            }

            _activeCallId = callId;
            _activeCallExpiresAtMs = expiry;
            string callFlow = DictStr(active, "call_flow");
            if (callFlow == "ring_then_purpose" || callFlow == "purpose_first")
                _callFlow = callFlow;
            _callFeedback = PlayConfigured(_callFeedback,
                SoundValue("call_sound", "outdoor_call_alert"),
                ConfigBool("ui.call_sound_loop", false), null, _volumeCall);
            ShowCalling(null, expiry);
            ReportRecoveryOnce(callId, true);
        }

        private void ReportRecoveryOnce(string callId, bool restored)
        {
            if (string.IsNullOrEmpty(callId) || callId == _reportedRecoveryCallId) return;
            _reportedRecoveryCallId = callId;
            App.Core.ReportCallRecovery(callId, restored);
        }

        private static Dictionary<string, object> FindDoorPeer(Dictionary<string, object> st, string door)
        {
            var peers = (st != null && st.ContainsKey("peers"))
                ? st["peers"] as System.Collections.IEnumerable : null;
            if (peers == null) return null;
            foreach (var o in peers)
            {
                var p = o as Dictionary<string, object>;
                if (p == null) continue;
                object self;
                if (p.TryGetValue("self", out self) && self is bool && (bool)self) continue;
                if (DictStr(p, "role") != "door_station") continue;
                if (!string.IsNullOrEmpty(door) && DictStr(p, "door") != door) continue;
                if (DictStr(p, "status") == "dead") continue;
                return p;
            }
            return null;
        }

        private static string PeerHost(Dictionary<string, object> peer)
        {
            var addrs = (peer != null && peer.ContainsKey("addrs"))
                ? peer["addrs"] as System.Collections.IEnumerable : null;
            if (addrs == null) return null;
            foreach (var a in addrs)
            {
                string s = a as string;
                if (string.IsNullOrEmpty(s)) continue;
                int i = s.LastIndexOf(':');
                return i > 0 ? s.Substring(0, i) : s;
            }
            return null;
        }

        /// <summary>Targeted chime (or an explicit local monitor action) opens the incoming view.</summary>
        private void ShowIncoming(UiEvent ev, bool monitorOnly = false)
        {
            if (_emergencyActive || _inCall) return;
            string door = ev.Str("door");
            string callId = ev.Str("call_id");
            if (IncomingView.Visibility == Visibility.Visible)
            {
                if (!_monitorOnly && !monitorOnly &&
                    CallMatches(callId, door, _incomingCallId, _incomingDoor))
                {
                    // A repeated chime from the same door keeps media and refreshes metadata only.
                    if (!string.IsNullOrEmpty(callId)) _incomingCallId = callId;
                    _incomingStageRevision = Math.Max(_incomingStageRevision,
                        DictInt(ev.Data, "stage_revision", _incomingStageRevision));
                    _incomingPurpose = ev.Str("purpose");
                    _incomingLang = ev.Str("visitor_lang");
                    UpdateIncomingBadges();
                    BuildQuickReplies();
                    _incomingTimeout.Stop();
                    _incomingTimeout.Start();
                    return;
                }
                // A different door stops the old stream and monitor SIP before switching targets.
                CloseIncoming(true);
            }
            ExitScreensaver();
            _monitorOnly = monitorOnly;
            _incomingDoor = door ?? "";
            _incomingCallId = callId ?? "";
            _incomingStageRevision = DictInt(ev.Data, "stage_revision", 0);
            _incomingPurpose = ev.Str("purpose");
            _incomingLang = ev.Str("visitor_lang");
            IncomingTitle.Text = monitorOnly ? Texts.T("monitor.title", DoorLabel(_incomingDoor)) :
                                               Texts.T("ring.incoming", DoorLabel(_incomingDoor));
            _quickRepliesOpen = false;
            _monitorAudioOn = false;
            _micMuted = false;
            ApplyMicLabel();
            ApplyMonitorLabel();
            UpdateIncomingBadges();
            BuildQuickReplies();
            QuickReplyToggle.Visibility = monitorOnly ?
                Visibility.Collapsed : Visibility.Visible;
            IncomingHint.Visibility = Visibility.Collapsed;

            // Resolve the door peer into a video URL and direct-call host.
            var peer = FindDoorPeer(App.Core.Status(), _incomingDoor);
            _incomingHost = PeerHost(peer);
            _incomingStreamUrl = DictStr(peer, "stream");
            _incomingStreamMp4Url = DictStr(peer, "stream_mp4");
            bool sip = App.Core.SipAvailable && !string.IsNullOrEmpty(_incomingHost);
            AnswerButton.Visibility = monitorOnly ? Visibility.Collapsed : Visibility.Visible;
            AnswerButton.IsEnabled = sip;
            MonitorButton.IsEnabled = sip;
            OpenDoorButton.IsEnabled = false;
            bool unlock = UnlockShown(_incomingDoor);
            OpenDoorButton.Visibility = unlock ? Visibility.Visible : Visibility.Collapsed;
            InCallOpenDoorButton.Visibility = OpenDoorButton.Visibility;
            IgnoreButton.Content = monitorOnly ? Texts.T("monitor.close") : Texts.T("ring.ignore");

            StartIncomingVideo();

            IncomingView.Visibility = Visibility.Visible;
            ShowCallOverlay(_incomingDoor);
            _statsRefresh.Stop();
            _statsRefresh.Start();
            RefreshVideoStats();
            _incomingTimeout.Stop();
            if (!monitorOnly) _incomingTimeout.Start();  // Proactive monitoring remains until closed.
        }

        private void StartIncomingVideo()
        {
            StopIncomingVideo();
            IncomingNoVideo.Visibility = Visibility.Visible;
            StartIncomingMjpeg(true);
            StartIncomingH264();
        }

        private void StartIncomingH264()
        {
            if (App.SafeMode || string.IsNullOrEmpty(_incomingStreamMp4Url)) return;
            try
            {
                IncomingH264.Opacity = 0;
                IncomingH264.Source = new Uri(_incomingStreamMp4Url, UriKind.Absolute);
                IncomingH264.Visibility = Visibility.Visible;
                IncomingH264.Play();
                _h264Fallback.Stop();
                _h264Fallback.Start();
            }
            catch (Exception ex)
            {
                Debug.WriteLine("H.264 start failed: " + ex.Message);
                ScheduleIncomingH264Retry();
            }
        }

        private void ScheduleIncomingH264Retry()
        {
            _h264Fallback.Stop();
            try { IncomingH264.Stop(); } catch { }
            IncomingH264.Source = null;
            IncomingH264.Visibility = Visibility.Collapsed;
            IncomingH264.Opacity = 1;
            IncomingLive.Visibility = Visibility.Visible;
            if (IncomingView.Visibility == Visibility.Visible && !App.SafeMode &&
                !string.IsNullOrEmpty(_incomingStreamMp4Url)) _h264Fallback.Start();
        }

        private void StartIncomingMjpeg(bool keepH264 = false)
        {
            if (!keepH264)
            {
                _h264Fallback.Stop();
                try { IncomingH264.Stop(); } catch { }
                IncomingH264.Source = null;
                IncomingH264.Visibility = Visibility.Collapsed;
                IncomingH264.Opacity = 1;
            }
            IncomingLive.Visibility = Visibility.Visible;
            if (_incomingStreamer != null) return;
            if (string.IsNullOrEmpty(_incomingStreamUrl)) return;
            _incomingStreamer = new MjpegStreamer(_incomingStreamUrl, (bmp, rotation) =>
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    IncomingNoVideo.Visibility = Visibility.Collapsed;
                    IncomingLive.Source = bmp;
                    IncomingLive.LayoutTransform = new RotateTransform(rotation);
                })), App.SafeMode);
            _incomingStreamer.Start();
        }

        private void StopIncomingVideo()
        {
            _h264Fallback.Stop();
            if (_incomingStreamer != null) { _incomingStreamer.Stop(); _incomingStreamer = null; }
            try { IncomingH264.Stop(); } catch { }
            IncomingH264.Source = null;
            IncomingH264.Visibility = Visibility.Collapsed;
            IncomingH264.Opacity = 1;
            IncomingLive.Source = null;
            IncomingLive.Visibility = Visibility.Visible;
            IncomingLive.LayoutTransform = Transform.Identity;
        }

        private void UpdateIncomingBadges()
        {
            var purposes = CoreClient.Dig(_cfg, "visit_purposes") as Dictionary<string, object>;
            var entry = purposes != null && !string.IsNullOrEmpty(_incomingPurpose) &&
                        purposes.ContainsKey(_incomingPurpose)
                ? purposes[_incomingPurpose] as Dictionary<string, object> : null;
            if (string.IsNullOrEmpty(_incomingPurpose))
            {
                PurposeBadge.Visibility = Visibility.Collapsed;
            }
            else
            {
                string label = LabelOf(entry, App.Boot.UiLang, _incomingPurpose);
                object icon;
                string iconText = entry != null && entry.TryGetValue("icon", out icon) && icon != null
                    ? icon.ToString() + " " : "";
                PurposeBadgeText.Text = iconText + label;
                PurposeBadge.ToolTip = Texts.T("ring.purpose_badge", label);
                PurposeBadge.Visibility = Visibility.Visible;
            }

            if (string.IsNullOrEmpty(_incomingLang) || _incomingLang == "ja")
            {
                LangBadge.Visibility = Visibility.Collapsed;
            }
            else
            {
                LangBadgeText.Text = "🌐 " + _incomingLang.ToUpperInvariant();
                LangBadge.ToolTip = Texts.T("ring.lang_badge", LangDisplayName(_incomingLang));
                LangBadge.Visibility = Visibility.Visible;
            }
        }

        private void BuildQuickReplies()
        {
            QuickReplyPanel.Children.Clear();
            if (_inCall)
            {
                QuickReplyPanel.Visibility = Visibility.Collapsed;
                return;
            }
            var replies = CoreClient.Dig(_cfg, "quick_replies") as Dictionary<string, object>;
            if (replies == null || replies.Count == 0)
            {
                QuickReplyPanel.Visibility = Visibility.Collapsed;
                return;
            }
            string lang = string.IsNullOrEmpty(_incomingLang) ? "ja" : _incomingLang;
            foreach (var id in SortedByOrder(replies))
            {
                var entry = replies[id] as Dictionary<string, object>;
                var b = new Button
                {
                    Content = LabelOf(entry, lang, id),
                    FontSize = 22,
                    Padding = new Thickness(26, 12, 26, 12),
                    Margin = new Thickness(8),
                    Background = (Brush)FindResource("Card"),
                    Foreground = (Brush)FindResource("Fg"),
                    BorderBrush = (Brush)FindResource("Dim"),
                    Cursor = Cursors.Hand,
                    Tag = id,
                };
                b.Click += OnQuickReplyClick;
                if (_semanticStyles != null)
                    _semanticApplier.Apply(b, _semanticStyles.Get("reply.button"), false);
                QuickReplyPanel.Children.Add(b);
            }
            ApplyQuickReplyVisibility();
        }

        private void ApplyQuickReplyVisibility()
        {
            QuickReplyPanel.Visibility = _quickRepliesOpen && !_inCall &&
                QuickReplyPanel.Children.Count != 0 ?
                Visibility.Visible : Visibility.Collapsed;
        }

        private void OnQuickReplyClick(object sender, RoutedEventArgs e)
        {
            if (_inCall) return;
            var b = sender as Button;
            if (b == null) return;
            bool accepted = App.Core.QuickReplyV2(b.Tag as string, _incomingDoor,
                                                  _incomingCallId, _incomingStageRevision);
            IncomingHint.Text = accepted ? Texts.T("reply.sent", b.Content) :
                                           Texts.T("reply.failed");
            IncomingHint.Visibility = Visibility.Visible;
        }

        private void CloseIncoming(bool hangup)
        {
            _incomingTimeout.Stop();
            _answerDelay.Stop();
            StopIncomingVideo();
            IncomingView.Visibility = Visibility.Collapsed;
            if (InCallView.Visibility != Visibility.Visible) HideCallOverlay();
            AnswerButton.IsEnabled = true;
            if (hangup && _sipMode != "" && !_inCall)
            {
                App.Core.SipHangup();
                _sipMode = "";
            }
            _incomingCallId = "";
            _monitorOnly = false;
            _quickRepliesOpen = false;
            _monitorAudioOn = false;
            ApplyQuickReplyVisibility();
            ApplyMonitorLabel();
            AnswerButton.Visibility = Visibility.Visible;
            IgnoreButton.Content = Texts.T("ring.ignore");
            OpenDoorButton.IsEnabled = false;
        }

        private void OnAnswerClick(object sender, RoutedEventArgs e)
        {
            if (!App.Core.SipAvailable)
            {
                IncomingHint.Text = Texts.T("sip.unavailable");
                IncomingHint.Visibility = Visibility.Visible;
                return;
            }
            if (string.IsNullOrEmpty(_incomingHost)) return;
            _lifecycleDoor = _incomingDoor;
            _lifecycleCallId = _incomingCallId;
            _lifecycleStageRevision = _incomingStageRevision;
            _lifecycleAnswered = false;
            _lifecycleEnded = false;
            AnswerButton.IsEnabled = false;
            if (_sipMode == "monitor")
            {
                App.Core.SipHangup();
                _answerDelay.Stop();
                _answerDelay.Start();
                return;
            }
            PlaceAnswerCall();
        }

        private void PlaceAnswerCall()
        {
            if (!App.Core.SipAvailable) return;
            _sipMode = "answer";
            _lifecycleDoor = _incomingDoor;
            _lifecycleCallId = _incomingCallId;
            _lifecycleStageRevision = _incomingStageRevision;
            _lifecycleAnswered = false;
            _lifecycleEnded = false;
            App.Core.SipCall("sip:" + _incomingHost + ":" + _directPort, "answer");
            OpenDoorButton.IsEnabled = true;
        }

        private void OnMonitorClick(object sender, RoutedEventArgs e)
        {
            if (!App.Core.SipAvailable)
            {
                IncomingHint.Text = Texts.T("sip.unavailable");
                IncomingHint.Visibility = Visibility.Visible;
                return;
            }
            if (_sipMode == "monitor")
            {
                // Visible ON/OFF state: turning it off stops door audio without ending the call.
                App.Core.SipHangup();
                _sipMode = "";
                _monitorAudioOn = false;
                OpenDoorButton.IsEnabled = false;
                ApplyMonitorLabel();
                return;
            }
            if (string.IsNullOrEmpty(_incomingHost) || _sipMode != "") return;
            _sipMode = "monitor";
            _monitorAudioOn = true;
            ApplyMonitorLabel();
            App.Core.SipCall("sip:" + _incomingHost + ":" + _directPort, "monitor");
            IncomingHint.Text = Texts.T("ring.monitoring");
            IncomingHint.Visibility = Visibility.Visible;
            OpenDoorButton.IsEnabled = true;
        }

        private void OnIgnoreClick(object sender, RoutedEventArgs e) => CloseIncoming(true);

        private void OnOpenDoorClick(object sender, RoutedEventArgs e)
        {
            // A door whose unlock action is not configured explains itself instead of no-opping.
            if (!UnlockConfigured(CurrentCallDoor()))
            {
                ShowCallMessage(Texts.T("ring.open_unconfigured"));
                return;
            }
            bool ok = App.Core.SipAvailable && _sipMode != "" &&
                      App.Core.SipSendDtmf("*1");
            ShowCallMessage(Texts.T(ok ? "ring.open_sent" : "ring.open_failed"));
        }

        private string CurrentCallDoor()
        {
            if (InCallView.Visibility == Visibility.Visible &&
                !string.IsNullOrEmpty(_lifecycleDoor)) return _lifecycleDoor;
            return _incomingDoor;
        }

        private void ShowCallMessage(string message)
        {
            if (InCallView.Visibility == Visibility.Visible) InCallTitle.Text = message;
            else { IncomingHint.Text = message; IncomingHint.Visibility = Visibility.Visible; }
        }

        /// <summary>
        /// doors.&lt;id&gt;.unlock.show_button decides whether the control is offered at all;
        /// an unset key defaults to whether an unlock action exists.
        /// </summary>
        private bool UnlockShown(string door)
        {
            if (App.Boot.Role != "indoor_panel") return false;
            var value = CoreClient.Dig(_cfg, "doors." + (door ?? "") + ".unlock.show_button");
            if (value is bool) return (bool)value;
            return UnlockConfigured(door);
        }

        private bool UnlockConfigured(string door)
        {
            if (CoreClient.Dig(_cfg, "doors." + (door ?? "") + ".unlock.action") != null)
                return true;
            var actions = CoreClient.Dig(_cfg, "sip.dtmf_actions") as Dictionary<string, object>;
            return actions != null && actions.Count != 0;
        }

        private void OnOpenMonitorClick(object sender, RoutedEventArgs e)
        {
            MonitorDoorList.Children.Clear();
            var status = App.Core.Status();
            var peers = status != null && status.ContainsKey("peers") ?
                status["peers"] as System.Collections.IEnumerable : null;
            if (peers != null)
                foreach (object raw in peers)
                {
                    var peer = raw as Dictionary<string, object>;
                    if (peer == null || DictStr(peer, "role") != "door_station" ||
                        DictStr(peer, "status") == "dead") continue;
                    string door = DictStr(peer, "door");
                    if (string.IsNullOrEmpty(door)) continue;
                    var button = new Button
                    {
                        Content = DoorLabel(door), Tag = door, FontSize = 26,
                        Padding = new Thickness(34, 16, 34, 16), Margin = new Thickness(6),
                        Background = (Brush)FindResource("Card"),
                        Foreground = (Brush)FindResource("Fg"),
                        BorderBrush = (Brush)FindResource("Dim"),
                    };
                    button.Click += OnMonitorDoorClick;
                    MonitorDoorList.Children.Add(button);
                }
            if (MonitorDoorList.Children.Count == 0)
                MonitorDoorList.Children.Add(new TextBlock
                {
                    Text = Texts.T("ring.no_video"), FontSize = 20,
                    Foreground = (Brush)FindResource("Dim"), TextAlignment = TextAlignment.Center,
                });
            MonitorPickerView.Visibility = Visibility.Visible;
            _semanticApplier.Apply(MonitorPickerClose,
                _semanticStyles == null ? null : _semanticStyles.Get("monitor.close"), true);
        }

        private void OnMonitorDoorClick(object sender, RoutedEventArgs e)
        {
            string door = (sender as Button)?.Tag as string;
            if (string.IsNullOrEmpty(door)) return;
            MonitorPickerView.Visibility = Visibility.Collapsed;
            ShowIncoming(new UiEvent
            {
                T = "monitor",
                Data = new Dictionary<string, object> { { "door", door } },
            }, true);
        }

        private void OnMonitorPickerClose(object sender, RoutedEventArgs e) =>
            MonitorPickerView.Visibility = Visibility.Collapsed;

        private void OnEndCallClick(object sender, RoutedEventArgs e)
        {
            App.Core.SipHangup();
            ReportLifecycleEndedIfNeeded();
            OnSipIdle();
        }

        private void OnSipInCall(UiEvent ev)
        {
            _inCall = true;
            BuildQuickReplies();
            _incomingTimeout.Stop();
            CallingText.Text = Texts.T("incall.title");
            string stream = ev.Str("peer_stream");
            if (App.Boot.Role == "door_station")
            {
                _callTimeout.Stop();
                _peerPoll.Stop();
                ShowInCall(stream);
                if (string.IsNullOrEmpty(stream))
                {
                    _peerPollBusy = false;
                    _peerPoll.Start();
                }
            }
            else if (_sipMode == "answer")
            {
                if (!_lifecycleAnswered)
                    _lifecycleAnswered = App.Core.ReportCallAnswered(
                        _lifecycleDoor, _lifecycleCallId, _lifecycleStageRevision);
                if (string.IsNullOrEmpty(stream)) stream = _incomingStreamUrl;
                CloseIncoming(false);
                ShowInCall(stream);
            }
        }

        private void OnSipIdle()
        {
            if (_suppressLosingSipIdle)
            {
                _suppressLosingSipIdle = false;
                _inCall = false;
                _sipMode = "";
                CloseInCall();
                if (IncomingView.Visibility == Visibility.Visible)
                {
                    AnswerButton.IsEnabled = App.Core.SipAvailable &&
                        !string.IsNullOrEmpty(_incomingHost);
                    _incomingTimeout.Stop();
                    _incomingTimeout.Start();
                }
                return;
            }
            bool wasInCall = _inCall;
            if (wasInCall) ReportLifecycleEndedIfNeeded();
            _inCall = false;
            _sipMode = "";
            CloseInCall();
            if (wasInCall && IncomingView.Visibility == Visibility.Visible)
                CloseIncoming(false);
            if (App.Boot.Role == "door_station") ShowIdle();
        }

        private void ReportLifecycleEndedIfNeeded()
        {
            if (!_inCall || _sipMode != "answer" || !_lifecycleAnswered || _lifecycleEnded ||
                string.IsNullOrEmpty(_lifecycleCallId)) return;
            _lifecycleEnded = App.Core.ReportCallEnded(
                _lifecycleDoor, _lifecycleCallId, _lifecycleStageRevision, "sip_ended");
        }

        private void ShowInCall(string streamUrl)
        {
            ExitScreensaver();
            IdleView.Visibility = Visibility.Collapsed;
            CallingView.Visibility = Visibility.Collapsed;
            if (_inCallStreamer != null) { _inCallStreamer.Stop(); _inCallStreamer = null; }
            try { PeerH264.Stop(); } catch { }
            PeerH264.Source = null;
            PeerH264.Visibility = Visibility.Collapsed;
            PeerH264.Opacity = 1;
            PeerVideo.Source = null;
            PeerVideo.Visibility = Visibility.Visible;
            PeerVideo.LayoutTransform = Transform.Identity;
            bool streamIsMp4 = !string.IsNullOrEmpty(streamUrl) &&
                streamUrl.IndexOf(".mp4", StringComparison.OrdinalIgnoreCase) >= 0;
            _inCallH264Url = streamIsMp4
                ? streamUrl : _incomingStreamMp4Url;
            _inCallMjpegUrl = streamIsMp4
                ? _incomingStreamUrl : streamUrl;
            StartInCallMjpeg();
            StartInCallH264();
            InCallView.Visibility = Visibility.Visible;
            UpdateInCallPurpose();
            ShowCallOverlay(_lifecycleDoor.Length != 0 ? _lifecycleDoor : _incomingDoor);
            _statsRefresh.Stop();
            _statsRefresh.Start();
            RefreshVideoStats();
        }

        private void StartInCallMjpeg()
        {
            PeerVideo.Visibility = Visibility.Visible;
            if (_inCallStreamer != null || string.IsNullOrEmpty(_inCallMjpegUrl)) return;
            _inCallStreamer = new MjpegStreamer(_inCallMjpegUrl, (bmp, rotation) =>
                Dispatcher.BeginInvoke(new Action(() => {
                    PeerVideo.Source = bmp;
                    PeerVideo.LayoutTransform = new RotateTransform(rotation);
                })), App.SafeMode);
            _inCallStreamer.Start();
        }

        private void StartInCallH264()
        {
            if (App.SafeMode || string.IsNullOrEmpty(_inCallH264Url)) return;
            try
            {
                PeerH264.Opacity = 0;
                PeerH264.Source = new Uri(_inCallH264Url, UriKind.Absolute);
                PeerH264.Visibility = Visibility.Visible;
                PeerH264.Play();
                _peerH264Retry.Stop();
                _peerH264Retry.Start();
            }
            catch { ScheduleInCallH264Retry(); }
        }

        private void ScheduleInCallH264Retry()
        {
            _peerH264Retry.Stop();
            try { PeerH264.Stop(); } catch { }
            PeerH264.Source = null;
            PeerH264.Visibility = Visibility.Collapsed;
            PeerH264.Opacity = 1;
            StartInCallMjpeg();
            if (InCallView.Visibility == Visibility.Visible && !App.SafeMode &&
                !string.IsNullOrEmpty(_inCallH264Url)) _peerH264Retry.Start();
        }

        private void CloseInCall()
        {
            _peerPoll.Stop();
            _peerH264Retry.Stop();
            if (IncomingView.Visibility != Visibility.Visible) _statsRefresh.Stop();
            if (_inCallStreamer != null) { _inCallStreamer.Stop(); _inCallStreamer = null; }
            try { PeerH264.Stop(); } catch { }
            PeerH264.Source = null;
            PeerH264.Visibility = Visibility.Collapsed;
            PeerH264.Opacity = 1;
            PeerVideo.Source = null;
            PeerVideo.Visibility = Visibility.Visible;
            PeerVideo.LayoutTransform = Transform.Identity;
            _inCallMjpegUrl = "";
            _inCallH264Url = "";
            InCallView.Visibility = Visibility.Collapsed;
            _micMuted = false;
            ApplyMicLabel();
            if (IncomingView.Visibility != Visibility.Visible) HideCallOverlay();
        }

        private void PollPeerFrame()
        {
            if (!_inCall || _peerPollBusy) return;
            _peerPollBusy = true;
            Task.Run(() =>
            {
                byte[] jpg = null;
                try
                {
                    using (var wc = new System.Net.WebClient())
                        jpg = wc.DownloadData("http://127.0.0.1:47180/peer-frame.jpg");
                }
                catch {  }
                var bmp = jpg != null ? MjpegStreamer.Decode(jpg, App.SafeMode ? 640 : 0) : null;
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    _peerPollBusy = false;
                    if (!_inCall || bmp == null) return;
                    if (InCallView.Visibility != Visibility.Visible) ShowInCall(null);
                    PeerVideo.Source = bmp;
                }));
            });
        }

        private void OnCallClick(object sender, RoutedEventArgs e)
        {
            _callFeedback = PlayConfigured(_callFeedback,
                SoundValue("call_sound", "outdoor_call_alert"),
                ConfigBool("ui.call_sound_loop", false), null, _volumeCall);
            _activeCallId = App.Core.Press(App.Boot.Door) ?? "";
            if (string.IsNullOrEmpty(_activeCallId))
            {
                ShowOffline();
                return;
            }
            _activeCallExpiresAtMs = ResolveActiveCallExpiryMs();
            ShowCalling();
        }

        private void OnCancelClick(object sender, RoutedEventArgs e)
        {
            if (CancelActiveCall("visitor"))
            {
                _callTimeout.Stop();
                ShowIdle();
            }
            else
            {
                CallingText.Text = Texts.T("calling.cancel_failed");
            }
        }

        private bool CancelActiveCall(string reason)
        {
            string callId = _activeCallId;
            if (string.IsNullOrEmpty(callId)) return false;
            bool ok = App.Core.CancelCall(App.Boot.Door, callId, reason);
            if (ok)
            {
                _activeCallId = "";
                _activeCallExpiresAtMs = 0;
            }
            return ok;
        }

        // Pairing is core-authoritative: this window renders pairing.state and never infers it.
        private void HandlePairingEvent(UiEvent ev)
        {
            switch (ev.T)
            {
                case "pairing_revoked":
                    // App owns the factory reset for a revoke (spec 5.4); this view only renders.
                    _pairingSkipped = false;
                    ShowPairingOverlay();
                    PairingOverlay.HandleCoreEvent(ev);
                    RefreshPairingState();
                    return;
                case "pairing_state":
                case "paired":
                case "join_result":
                case "invite_rejected":
                case "pairing_persistence_error":
                case "join_token_changed":
                case "pending_changed":
                    PairingOverlay.HandleCoreEvent(ev);
                    RefreshPairingState();
                    return;
            }
        }

        private void RefreshPairingState()
        {
            var snapshot = PairingSnapshot.From(App.Core.PairingInfo());
            // {} means core has not published a snapshot yet: unknown, so do not show onboarding.
            if (!snapshot.Known) return;
            _pairing = snapshot;
            bool ready = _pairing.IsReady;
            if (ready) _pairingSkipped = false;
            if (!ready && !_pairingSkipped && !PairingOverlay.IsActive) ShowPairingOverlay();

            PairBanner.Visibility = !ready && !PairingOverlay.IsActive ?
                Visibility.Visible : Visibility.Collapsed;
            MembershipStatus.Visibility = ready && !PairingOverlay.IsActive ?
                Visibility.Visible : Visibility.Collapsed;
            MembershipText.Text = Texts.T("pair.membership", _pairing.MemberCount.ToString());
            MembershipBadge.Text = _pairing.IsFounder ? Texts.T("pair.created_badge") :
                Texts.T("pair.membership_connected", _pairing.ConnectedCount.ToString());
        }

        private void ShowPairingOverlay()
        {
            PairBanner.Visibility = Visibility.Collapsed;
            MembershipStatus.Visibility = Visibility.Collapsed;
            PairingOverlay.Activate();
        }

        private void OnPairingDismissed()
        {
            _pairingSkipped = true;
            PairingOverlay.Deactivate();
            RefreshPairingState();
        }

        private void OnPairBannerClick(object sender, MouseButtonEventArgs e)
        {
            _pairingSkipped = false;
            ShowPairingOverlay();
        }

        private void OnMembershipClick(object sender, MouseButtonEventArgs e)
        {
            OpenAddDevicePanel();
        }

        /// <summary>Opens the Add-device panel, behind the admin password on a kiosk.</summary>
        private void OpenAddDevicePanel()
        {
            if (App.Boot.Kiosk && !_adminUnlocked)
            {
                var prompt = new AdminDialog { Owner = this };
                if (prompt.ShowDialog() != true) return;
            }
            var panel = new AddDeviceWindow { Owner = this, Topmost = Topmost };
            panel.ShowDialog();
            if (panel.OnboardingRequested)
            {
                _pairingSkipped = false;
                ShowPairingOverlay();
                return;
            }
            RefreshPairingState();
        }

        private void OnSecretCorner(object sender, MouseButtonEventArgs e)
        {
            var now = DateTime.Now;
            if ((now - _secretFirst).TotalSeconds > 5) { _secretFirst = now; _secretTaps = 0; }
            if (++_secretTaps < 7) return;
            _secretTaps = 0;
            var dlg = new AdminDialog { Owner = this };
            if (dlg.ShowDialog() == true)
            {
                _adminUnlocked = true;
                _kiosk?.Disable();
                Topmost = false;
                WindowState = WindowState.Normal;
                WindowStyle = WindowStyle.SingleBorderWindow;
                ResizeMode = ResizeMode.CanResize;
                try
                {
                    File.WriteAllText(Path.Combine(App.DataDir, "admin_unlocked.flag"),
                                      DateTime.Now.ToString("s"));
                }
                catch {  }
            }
        }
    }
}
