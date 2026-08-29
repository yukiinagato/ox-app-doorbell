// 門口機メイン画面: 待機 / 呼び出し中 / 返信バナー / オフライン / スクリーンセーバ /
// 緊急事態 の状態機。core からの UI イベント (state/chime/reply/display/emergency/…) で遷移する。
// 表示制御 ({"t":"display"}): 輝度 = WMI (WmiMonitorBrightnessMethods, 失敗容認)、
// 夜間 red_tint = 全画面 #33FF2200 オーバーレイ + 時計を暗赤に。焼付対策 = pixel_shift_s 毎の
// ±8px 平行移動 + 無操作 screensaver_after_s でスクリーンセーバ (黒背景 + 低輝度 + 漂う時計)。
// SOS: 長押し hold_to_trigger_s 秒で db_core_emergency(1)。発報中は全画面赤 + サイレン
// (実行時生成 PCM wav ループ) + 「解除」→ AdminDialog PIN → db_core_emergency(0)。
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
        private readonly DispatcherTimer _sosTimer = new DispatcherTimer();
        private readonly DispatcherTimer _incomingTimeout = new DispatcherTimer();  // 来鈴 30s
        private readonly DispatcherTimer _answerDelay = new DispatcherTimer();      // 監聴→応答の切替待ち
        private readonly DispatcherTimer _peerPoll = new DispatcherTimer();         // /peer-frame.jpg 輪詢
        private readonly Random _rng = new Random();

        // ---- 来鈴/通話 (室内対講) ----
        private MjpegStreamer _incomingStreamer;   // 来鈴画面の門口ライブ
        private MjpegStreamer _inCallStreamer;     // 通話中の相手映像 (対称 MJPEG)
        private string _incomingDoor = "";
        private string _incomingHost;              // 直呼宛先 (門口機の mesh 実アドレス host)
        private string _incomingStreamUrl;
        private string _sipMode = "";              // "" | "monitor" | "answer"
        private bool _inCall;
        private bool _peerPollBusy;
        private int _directPort = 47190;           // config sip.direct_port (docs/network-ports.md)
        private int _secretTaps;
        private DateTime _secretFirst = DateTime.MinValue;
        private KioskHooks _kiosk;

        // ---- 表示制御の実効値 (core {"t":"display"} / status_json.display 由来) ----
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

        // ---- 個性化 (テーマ / 訪客言語 / 用件 / カスタム音声) ----
        private Dictionary<string, object> _cfg;   // 直近の core 設定 (config_changed で差替)
        private string _nodeId = "";               // 自機 node_id (devices.<id>.local.theme 用)
        private string _panelToken = "";           // config panel.tokens[0] (/asset の ?k=)
        private string _visitorLang = "ja";        // 門口機の表示言語 (訪客言語)
        private string _themeColor;                // 適用済み bg_color
        private string _themeHash;                 // 適用済み bg_image (sha256)
        private MediaPlayer _audio;                // reply/chime の audio_path 再生
        private MediaPlayer _effects;              // ボタン / 追加通知
        private MediaPlayer _callFeedback;         // 門口の呼出確認音
        private MediaPlayer _launchAudio;          // 起動音
        private Action _audioFallback;             // 再生失敗時の回落 (TTS / 内蔵音)
        private string _callTitleOverride;         // 用件付き按鈴の「{用件} で呼び出しました」
        private string _incomingPurpose = "";      // 来鈴中の用件 id (バッジ用)
        private string _incomingLang = "";         // 来鈴中の訪客言語 (返信ラベル/バッジ用)

        // ---- SOS ----
        private bool _emergencyActive;
        private double _sosHoldS = 3;
        private bool _cancelRequiresPin = true;
        private DateTime _sosDownAt = DateTime.MinValue;
        private bool _sosHolding;
        private SoundPlayer _siren;
        private MemoryStream _sirenStream;

        public MainWindow()
        {
            InitializeComponent();
            _visitorLang = App.Boot.UiLang;
            RefreshConfigCache();
            ApplyStrings();

            _clock.Interval = TimeSpan.FromSeconds(1);
            _clock.Tick += (s, e) => OnClockTick();
            _clock.Start();
            UpdateClock();

            _callTimeout.Interval = TimeSpan.FromSeconds(30);
            _callTimeout.Tick += (s, e) => { _callTimeout.Stop(); ShowIdle(Texts.T("calling.no_answer")); };
            _replyTimeout.Tick += (s, e) => { _replyTimeout.Stop(); ReplyBanner.Visibility = Visibility.Collapsed; };

            // 焼付対策: pixel_shift_s 毎に待機画面コンテナを ±8px 移動
            _pixelShift.Tick += (s, e) =>
            {
                IdleShift.X = _rng.Next(-8, 9);
                IdleShift.Y = _rng.Next(-8, 9);
            };
            // スクリーンセーバの時計漂移 (30 秒毎に位置替え)
            _saverDrift.Interval = TimeSpan.FromSeconds(30);
            _saverDrift.Tick += (s, e) => MoveSaverClock();
            // SOS 長押しの進捗 (50ms 刻み)
            _sosTimer.Interval = TimeSpan.FromMilliseconds(50);
            _sosTimer.Tick += (s, e) => OnSosTick();

            // 来鈴: 応答されないまま 30 秒で自動クローズ (映像/監聴を持続させない)
            _incomingTimeout.Interval = TimeSpan.FromSeconds(30);
            _incomingTimeout.Tick += (s, e) => CloseIncoming(true);
            // 監聴中に応答: hangup → 400ms 待って answer 直呼 (主呼は同時に 1 本)
            _answerDelay.Interval = TimeSpan.FromMilliseconds(400);
            _answerDelay.Tick += (s, e) => { _answerDelay.Stop(); PlaceAnswerCall(); };
            // 網頁通話の相手映像 (peer_stream 未解決時に自機の /peer-frame.jpg を輪詢)
            _peerPoll.Interval = TimeSpan.FromMilliseconds(500);
            _peerPoll.Tick += (s, e) => PollPeerFrame();

            // 無操作検出 (Preview 系は全 view のタッチ/クリック/キーで発火する)
            PreviewMouseDown += (s, e) => OnActivity();
            PreviewTouchDown += (s, e) => OnActivity();
            PreviewKeyDown += (s, e) => OnActivity();
            AddHandler(Button.ClickEvent, new RoutedEventHandler((s, e) =>
            {
                if (!ReferenceEquals(e.OriginalSource, CallButton))
                    _effects = PlayConfigured(_effects, SoundValue("button_sound", "button_click"), false);
            }));

            App.Core.UiEventReceived += ev => Dispatcher.BeginInvoke(new Action(() => OnUiEvent(ev)));

            Loaded += (s, e) =>
            {
                if (App.Boot.Kiosk)
                {
                    Topmost = true;
                    _kiosk = new KioskHooks();
                    _kiosk.Enable();
                }
                KioskHooks.KeepDisplayOn();
                RefreshNodeInfo();
                _launchAudio = PlayConfigured(_launchAudio,
                    SoundValue("launch_sound", "title_display"), false);
            };
            Closing += (s, e) =>
            {
                if (App.Boot.Kiosk && !_adminUnlocked) e.Cancel = true;  // kiosk 中は閉じさせない
                else _kiosk?.Disable();
            };
        }

        private bool _adminUnlocked;

        private static Brush Frozen(SolidColorBrush b) { b.Freeze(); return b; }

        private static bool IsTrue(string v) =>
            v == "True" || v == "true" || v == "1";

        /// <summary>全画面の文言を現在言語で貼り直す (Texts = i18n_overrides → resx の順で解決)。
        /// 訪客言語の切替でも呼ばれる。</summary>
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
            SosText.Text = Texts.T("emergency.button");
            SosHint.Text = Texts.T("emergency.hold_hint", _sosHoldS);
            EmergencyTitle.Text = Texts.T("emergency.title");
            EmergencyNote.Text = Texts.T("emergency.notified");
            EmergencyCancelButton.Content = Texts.T("emergency.cancel");
            AnswerButton.Content = Texts.T("ring.answer");
            MonitorButton.Content = Texts.T("ring.monitor");
            IgnoreButton.Content = Texts.T("ring.ignore");
            IncomingNoVideo.Text = Texts.T("ring.no_video");
            InCallTitle.Text = Texts.T("incall.title");
            EndCallButton.Content = Texts.T("incall.end");
        }

        /// <summary>ドアの表示名 (doors.&lt;door&gt;.label.&lt;lang&gt; → ja → door id)。</summary>
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
            // 無操作 screensaver_after_s でスクリーンセーバへ (待機中のみ)
            if (!_screensaverOn && !_emergencyActive && _screensaverAfterS > 0 &&
                IdleView.Visibility == Visibility.Visible &&
                CallingView.Visibility != Visibility.Visible &&
                OfflineView.Visibility != Visibility.Visible &&
                IncomingView.Visibility != Visibility.Visible &&
                InCallView.Visibility != Visibility.Visible &&
                (DateTime.Now - _lastActivity).TotalSeconds > _screensaverAfterS)
                EnterScreensaver();
        }

        private void UpdateClock()
        {
            var now = DateTime.Now;
            ClockText.Text = now.ToString("HH:mm:ss");
            string[] yobi = { "日", "月", "火", "水", "木", "金", "土" };
            DateText.Text = now.ToString("yyyy年M月d日") + " (" + yobi[(int)now.DayOfWeek] + ")";
            if (_screensaverOn)
            {
                SaverClock.Text = ClockText.Text;
                SaverDate.Text = DateText.Text;
            }
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
                        NodeInfo.Text = node["name"] + " · v" + node["version"];
                        object id;
                        if (node.TryGetValue("id", out id) && id != null) _nodeId = id.ToString();
                    }
                }
                catch { }
                // 初期表示状態 (起動直後の {"t":"display"}/{"t":"emergency"} は購読前に流れている
                // ことがある — status_json の同梱値で追い付く)
                ApplyDisplayFromStatus(st);
            }
            // 訪客言語の現在値 (status_json visitor_lang.<door>) — 再起動後の追い付き
            if (st != null && App.Boot.Role == "door_station" && !string.IsNullOrEmpty(App.Boot.Door))
            {
                var vl = CoreClient.Dig(st, "visitor_lang." + App.Boot.Door);
                SetVisitorLang(vl != null ? vl.ToString() : "ja");
            }
            RefreshSosConfig(_cfg);
            // 直呼待受ポート (config sip.direct_port — 既定 47190)
            var dp = CoreClient.Dig(_cfg, "sip.direct_port");
            if (dp != null)
            {
                int p;
                if (int.TryParse(dp.ToString(), out p) && p > 0) _directPort = p;
            }
            // 個性化 (テーマ / 用件 / 言語バー) — 文言は言語追従なので最後に貼り直す
            ApplyTheme();
            BuildPurposeButtons();
            BuildLangBar();
            ApplyStrings();
        }

        // ---------- 個性化 (テーマ / 訪客言語 / 用件) ----------

        /// <summary>core 設定のキャッシュ更新 (Texts の上書き文言もここで差し替える)。</summary>
        private void RefreshConfigCache()
        {
            _cfg = App.Core.Config();
            Texts.SetConfig(_cfg);
            _panelToken = FirstPanelToken(_cfg);
        }

        /// <summary>config panel.tokens[0] (資産取得 /asset/&lt;hash&gt;?k= に使う)。</summary>
        private static string FirstPanelToken(Dictionary<string, object> cfg)
        {
            var toks = CoreClient.Dig(cfg, "panel.tokens") as System.Collections.IEnumerable;
            if (toks == null || toks is string) return "";
            foreach (var t in toks)
                if (t != null && !string.IsNullOrEmpty(t.ToString())) return t.ToString();
            return "";
        }

        /// <summary>設定値を「端末別 (devices.&lt;self&gt;.local.theme.*) → 全体 (display.theme.*)」の
        /// 優先順で引く。</summary>
        private string ThemeValue(string leaf)
        {
            object v = null;
            if (!string.IsNullOrEmpty(_nodeId))
                v = CoreClient.Dig(_cfg, "devices." + _nodeId + ".local.theme." + leaf);
            if (v == null) v = CoreClient.Dig(_cfg, "display.theme." + leaf);
            return v != null ? v.ToString() : null;
        }

        /// <summary>テーマ適用: bg_color を背景に、bg_image (sha256) を最背面へ敷く。</summary>
        private void ApplyTheme()
        {
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
                        Debug.WriteLine("テーマ背景色が不正 (無視): " + color + " " + ex.Message);
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
            if (hash == _themeHash && ThemeBgImage.Source != null) return;  // 適用済み
            _themeHash = hash;
            LoadThemeImage(hash);
        }

        /// <summary>背景画像を自機 httpd から取得 (未キャッシュなら 404 — asset_ready で再試行)。</summary>
        private void LoadThemeImage(string hash)
        {
            string url = "http://127.0.0.1:" + App.Boot.HttpPort + "/asset/" + hash;
            if (!string.IsNullOrEmpty(_panelToken)) url += "?k=" + _panelToken;
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
                    // 未取得 (mesh 前取り待ち) — {"t":"asset_ready"} を待って再試行する
                    Debug.WriteLine("背景画像の取得失敗 (asset_ready 待ち): " + ex.Message);
                }
                if (data == null) return;
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (_themeHash != hash) return;  // 途中で設定が変わった
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
                        Debug.WriteLine("背景画像のデコード失敗 (無視): " + ex.Message);
                    }
                }));
            });
        }

        /// <summary>設定のオブジェクト直下のキー一覧を order 昇順 (同値は id 順) で返す。</summary>
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

        /// <summary>ラベル多言語解決 (label.&lt;lang&gt; → label.ja → 既定)。</summary>
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

        /// <summary>用件ボタン (config visit_purposes)。門口機の待機画面にだけ出す。</summary>
        private void BuildPurposeButtons()
        {
            PurposeGrid.Children.Clear();
            var purposes = CoreClient.Dig(_cfg, "visit_purposes") as Dictionary<string, object>;
            if (App.Boot.Role != "door_station" || purposes == null || purposes.Count == 0)
            {
                PurposeSection.Visibility = Visibility.Collapsed;
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
            }
            PurposeSection.Visibility = Visibility.Visible;
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
            App.Core.PressPurpose(App.Boot.Door, id);
            ShowCalling(Texts.T("purpose.sent", label));
        }

        /// <summary>訪客言語バー (config ui.languages)。門口機の待機画面下部。</summary>
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
            UpdateLangBarSelection();
        }

        /// <summary>言語の自言語表記 (訪客が自分の言語を見つけられるように)。</summary>
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
            App.Core.SetVisitorLang(App.Boot.Door, lang);  // 複製で visitor_lang が返ってくる
            SetVisitorLang(lang);                          // 体感優先で先に切り替える (冪等)
        }

        /// <summary>表示言語を切り替えて訪客向け文言を貼り直す (自操作・他端末・自動復帰の共通経路)。</summary>
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

        // ---------- カスタム音声 (reply / chime の audio_path) ----------

        /// <summary>資産のローカルファイルを再生。失敗時は fallback (TTS / 内蔵音) へ回落する。</summary>
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
                    _audio.MediaFailed += (s, e) =>
                    {
                        Debug.WriteLine("カスタム音声の再生失敗 (回落): " + e.ErrorException);
                        var fb = _audioFallback;
                        _audioFallback = null;
                        if (fb != null) fb();
                    };
                }
                _audio.Open(new Uri(path));
                _audio.Play();
            }
            catch (Exception ex)
            {
                Debug.WriteLine("カスタム音声を開けない (回落): " + ex.Message);
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

        private MediaPlayer PlayConfigured(MediaPlayer current, string value, bool loop,
                                           Action fallback = null)
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
                var player = new MediaPlayer();
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

        // ---------- 表示制御 ----------
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
            var em = CoreClient.Dig(st, "emergency") as Dictionary<string, object>;
            if (em != null)
            {
                if (DictBool(em, "active")) ShowEmergency();
                else HideEmergency();
            }
        }

        private void ApplyDisplay()
        {
            // 夜間: red tint オーバーレイ + 時計を暗赤に
            NightTint.Visibility = (_night && _redTint) ? Visibility.Visible : Visibility.Collapsed;
            ClockText.Foreground = _night ? NightClockBrush : (Brush)FindResource("Fg");
            DateText.Foreground = _night ? NightClockBrush : (Brush)FindResource("Dim");
            SaverClock.Foreground = _night ? NightClockBrush : SaverClockBrush;

            if (_pixelShiftS > 0)
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
        }

        /// <summary>輝度設定 (WMI WmiMonitorBrightnessMethods)。内蔵/対応モニタ以外は失敗容認ログのみ。</summary>
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
                    // 外部モニタ/仮想環境では未対応 — 容認 (表示制御の他要素は生きる)
                    Debug.WriteLine("brightness 設定失敗 (容認): " + ex.Message);
                }
            });
        }

        // ---------- スクリーンセーバ ----------
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
            _saverDrift.Start();
            SetBrightnessAsync(Math.Min(_brightness, 10));  // 低輝度
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

        // ---------- SOS ----------
        private void RefreshSosConfig(Dictionary<string, object> cfg)
        {
            // 既定 (config 未設定時) は config-schema の既定 button_on_roles=["indoor_panel"]
            bool show = App.Boot.Role == "indoor_panel";
            var roles = CoreClient.Dig(cfg, "emergency.button_on_roles") as System.Collections.IEnumerable;
            if (roles != null && !(roles is string))
            {
                show = false;
                foreach (var r in roles)
                    if (r != null && r.ToString() == App.Boot.Role) show = true;
            }
            SosButton.Visibility = show ? Visibility.Visible : Visibility.Collapsed;

            var hold = CoreClient.Dig(cfg, "emergency.hold_to_trigger_s");
            _sosHoldS = 3;
            if (hold != null)
            {
                double d;
                if (double.TryParse(hold.ToString(), out d) && d > 0) _sosHoldS = d;
            }
            SosHint.Text = Texts.T("emergency.hold_hint", _sosHoldS);

            var pin = CoreClient.Dig(cfg, "emergency.cancel_requires_pin");
            _cancelRequiresPin = !(pin is bool) || (bool)pin;  // 既定 true
        }

        private void OnSosDown(object sender, MouseButtonEventArgs e)
        {
            _sosDownAt = DateTime.Now;
            _sosHolding = true;
            SosProgress.Value = 0;
            _sosTimer.Start();
            SosButton.CaptureMouse();
        }

        private void OnSosTick()
        {
            if (!_sosHolding) { _sosTimer.Stop(); return; }
            double held = (DateTime.Now - _sosDownAt).TotalSeconds;
            SosProgress.Value = Math.Min(100, held / _sosHoldS * 100);
            if (held >= _sosHoldS)
            {
                ResetSosHold();
                App.Core.Emergency(true);  // {"t":"emergency","active":true} が全ノードへ届き UI が出る
            }
        }

        private void OnSosUp(object sender, MouseButtonEventArgs e) => ResetSosHold();
        private void OnSosLeave(object sender, MouseEventArgs e) => ResetSosHold();

        private void ResetSosHold()
        {
            _sosHolding = false;
            _sosTimer.Stop();
            SosProgress.Value = 0;
            if (SosButton.IsMouseCaptured) SosButton.ReleaseMouseCapture();
        }

        private void ShowEmergency()
        {
            if (_emergencyActive) return;
            _emergencyActive = true;
            ExitScreensaver();
            _callTimeout.Stop();
            CallingView.Visibility = Visibility.Collapsed;
            ReplyBanner.Visibility = Visibility.Collapsed;
            EmergencyView.Visibility = Visibility.Visible;
            SetBrightnessAsync(100);  // 警報中は最大輝度
            StartSiren();
        }

        private void HideEmergency()
        {
            if (!_emergencyActive) return;
            _emergencyActive = false;
            StopSiren();
            EmergencyView.Visibility = Visibility.Collapsed;
            ShowIdle();
            _lastActivity = DateTime.Now;
            ApplyDisplay();
        }

        private void OnEmergencyCancelClick(object sender, RoutedEventArgs e)
        {
            if (_cancelRequiresPin)
            {
                var dlg = new AdminDialog { Owner = this };
                if (dlg.ShowDialog() != true) return;
            }
            App.Core.Emergency(false);
            HideEmergency();  // core からの active=false 通知も来るが即時に畳む (冪等)
        }

        // ---------- サイレン (実行時生成 PCM wav ループ — 同梱音源なしで動く) ----------
        private void StartSiren()
        {
            try
            {
                if (_siren == null)
                {
                    _sirenStream = BuildSirenWav();
                    _siren = new SoundPlayer(_sirenStream);
                }
                _sirenStream.Position = 0;
                _siren.PlayLooping();
            }
            catch (Exception ex)
            {
                Debug.WriteLine("siren 再生失敗 (容認): " + ex.Message);
            }
        }

        private void StopSiren()
        {
            try { _siren?.Stop(); } catch { }
        }

        /// <summary>880/660Hz 交互 2 秒の警報音 (22.05kHz 16bit mono PCM WAV)。
        /// SoundPlayer に音量指定は無い — config emergency.alarm_volume は OS 音量に委ねる。</summary>
        private static MemoryStream BuildSirenWav()
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
            for (int i = 0; i < n; i++)
            {
                double t = (double)i / rate;
                double freq = (i / (rate / 2)) % 2 == 0 ? 880.0 : 660.0;  // 0.5 秒毎に交互
                double env = Math.Min(1.0, Math.Min(i, n - i) / (rate * 0.02));  // クリック防止
                short s = (short)(Math.Sin(2 * Math.PI * freq * t) * 0.6 * short.MaxValue * env);
                bw.Write(s);
            }
            bw.Flush();
            ms.Position = 0;
            return ms;
        }

        // ---------- 状態遷移 ----------
        private void ShowIdle(string hint = null)
        {
            StopPlayer(ref _callFeedback);
            _callTitleOverride = null;
            CallingView.Visibility = Visibility.Collapsed;
            OfflineView.Visibility = Visibility.Collapsed;
            IdleView.Visibility = Visibility.Visible;
            if (hint != null) TouchHint.Text = hint;
        }

        /// <summary>呼び出し中画面。title 指定時は「{用件} で呼び出しました」等に差し替える
        /// (core からの state=calling で上書きされないよう _callTitleOverride に覚える)。</summary>
        private void ShowCalling(string title = null)
        {
            ExitScreensaver();
            if (title != null) _callTitleOverride = title;
            CallingText.Text = _callTitleOverride ?? Texts.T("calling.title");
            IdleView.Visibility = Visibility.Collapsed;
            CallingView.Visibility = Visibility.Visible;
            _callTimeout.Stop();
            _callTimeout.Start();
            var anim = new DoubleAnimation(0.25, 1.0, TimeSpan.FromSeconds(0.9))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever };
            Pulse.BeginAnimation(OpacityProperty, anim);
        }

        private void OnUiEvent(UiEvent ev)
        {
            switch (ev.T)
            {
                case "state":
                    var stv = ev.Str("state");
                    if (stv == "calling") { if (App.Boot.Role == "door_station") ShowCalling(); }
                    else if (stv == "idle") OnSipIdle();
                    else if (stv == "in_call") { StopPlayer(ref _callFeedback); OnSipInCall(ev); }
                    break;
                case "event":
                    // 受鈴室内面板: press で来鈴画面 (門口ライブ + 応答/モニタ/無視)。
                    // reply (誰かが応対 — 複製イベントで全ノードに届く) で来鈴画面を畳む
                    if (App.Boot.Role == "indoor_panel" && ev.Str("type") == "press")
                        ShowIncoming(ev);
                    else if (ev.Str("type") == "reply" && !_inCall &&
                             IncomingView.Visibility == Visibility.Visible)
                        CloseIncoming(true);
                    if (App.Boot.Role == "indoor_panel" &&
                        (ev.Str("type") == "call_cancelled" || ev.Str("type") == "purpose_selected"))
                        _effects = PlayConfigured(_effects,
                            SoundValue("update_sound", "indoor_update"), false);
                    if (ev.Str("type") == "call_cancelled") StopPlayer(ref _callFeedback);
                    break;
                case "chime":
                    ExitScreensaver();
                    // カスタム音 (assets の audio_path) があればそれを、無ければ内蔵音
                    if (!string.IsNullOrEmpty(ev.Str("audio_path")))
                        PlayAudio(ev.Str("audio_path"), () => SystemSounds.Exclamation.Play());
                    else
                        _audio = PlayConfigured(_audio, ev.Str("sound"), false,
                            () => SystemSounds.Exclamation.Play());
                    break;
                case "visitor_lang":
                    // 訪客言語の切替 (自操作の複製 / 他端末からの変更 / 無操作復帰)
                    if (App.Boot.Role == "door_station" &&
                        (ev.Str("door") == App.Boot.Door || string.IsNullOrEmpty(ev.Str("door"))))
                        SetVisitorLang(ev.Str("lang"));
                    // 来鈴中の室内機は返信ラベル/バッジを追随させる
                    if (IncomingView.Visibility == Visibility.Visible &&
                        ev.Str("door") == _incomingDoor)
                    {
                        _incomingLang = ev.Str("lang");
                        UpdateIncomingBadges();
                        BuildQuickReplies();
                    }
                    break;
                case "asset_ready":
                    // 前取り完了 — 背景画像が待ちだったら読み直す
                    if (!string.IsNullOrEmpty(_themeHash) && ev.Str("hash") == _themeHash &&
                        ThemeBgImage.Source == null)
                        LoadThemeImage(_themeHash);
                    break;
                case "reply":
                    ExitScreensaver();
                    // 誰かが応対した → 来鈴画面は閉じる (監聴中なら切る)
                    if (IncomingView.Visibility == Visibility.Visible && !_inCall)
                        CloseIncoming(true);
                    // カスタム音声があれば再生 (無い時は core が TTS 済み — 二重発話しない)
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
                    // 訪客が見たら呼び出し継続は不要 → 待機へ
                    _callTimeout.Stop();
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
                    // 自端末発報も他端末発報も同じ UI (イベント複製で届く)
                    if (IsTrue(ev.Str("active"))) ShowEmergency();
                    else HideEmergency();
                    break;
                case "peers_changed":
                case "config_changed":
                    RefreshNodeInfo();
                    break;
            }
        }

        // ---------- 来鈴 / 室内対講 (計画書 §12: 三モード通話) ----------

        private static string DictStr(Dictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) && v != null ? v.ToString() : "";
        }

        /// <summary>statusJson peers[] からこの door 担当の door_station (自分以外・生存) を返す。</summary>
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

        /// <summary>peer の addrs[0] "host:port" → host (mesh の実アドレス — Asterisk 非経由)。</summary>
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

        /// <summary>来鈴画面 (indoor_panel が press イベント受信時)。用件/訪客言語は
        /// press イベント payload 由来 (バッジ表示 + クイック返信のラベル言語)。</summary>
        private void ShowIncoming(UiEvent ev)
        {
            if (_emergencyActive || _inCall) return;  // 警報中/通話中は画面を奪わない
            string door = ev.Str("door");
            if (IncomingView.Visibility == Visibility.Visible)
            {
                // 同じ画面が出ている間の再チャイム → タイマだけ張り直す (監聴等は継続)
                _incomingPurpose = ev.Str("purpose");
                _incomingLang = ev.Str("visitor_lang");
                UpdateIncomingBadges();
                BuildQuickReplies();
                _incomingTimeout.Stop();
                _incomingTimeout.Start();
                return;
            }
            ExitScreensaver();
            _incomingDoor = door ?? "";
            _incomingPurpose = ev.Str("purpose");
            _incomingLang = ev.Str("visitor_lang");
            IncomingTitle.Text = Texts.T("ring.incoming", DoorLabel(_incomingDoor));
            UpdateIncomingBadges();
            BuildQuickReplies();
            IncomingHint.Visibility = Visibility.Collapsed;

            // 門口機 peer 解決 (映像 URL + 直呼宛先 host)
            var peer = FindDoorPeer(App.Core.Status(), _incomingDoor);
            _incomingHost = PeerHost(peer);
            _incomingStreamUrl = DictStr(peer, "stream");
            AnswerButton.IsEnabled = !string.IsNullOrEmpty(_incomingHost);

            // 門口ライブ (MJPEG)。URL 不明なら「映像なし」のまま
            if (_incomingStreamer != null) { _incomingStreamer.Stop(); _incomingStreamer = null; }
            IncomingLive.Source = null;
            IncomingNoVideo.Visibility = Visibility.Visible;
            if (!string.IsNullOrEmpty(_incomingStreamUrl))
            {
                _incomingStreamer = new MjpegStreamer(_incomingStreamUrl, bmp =>
                    Dispatcher.BeginInvoke(new Action(() =>
                    {
                        IncomingNoVideo.Visibility = Visibility.Collapsed;
                        IncomingLive.Source = bmp;
                    })));
                _incomingStreamer.Start();
            }

            IncomingView.Visibility = Visibility.Visible;
            _incomingTimeout.Stop();
            _incomingTimeout.Start();  // 30 秒で自動クローズ (再チャイムで張り直し)
        }

        /// <summary>来鈴画面の用件バッジ (「📦 宅配便」) と訪客言語バッジ (「🌐 EN」)。</summary>
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
                // バッジは室内側の言語 (住人が読む) — 訪客言語ではない
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

        /// <summary>クイック返信ボタン (config quick_replies を order 順)。ラベルは訪客言語
        /// (quick_replies.&lt;id&gt;.label.&lt;visitor_lang&gt; — 無ければ ja)。</summary>
        private void BuildQuickReplies()
        {
            QuickReplyPanel.Children.Clear();
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
                QuickReplyPanel.Children.Add(b);
            }
            QuickReplyPanel.Visibility = Visibility.Visible;
        }

        private void OnQuickReplyClick(object sender, RoutedEventArgs e)
        {
            var b = sender as Button;
            if (b == null) return;
            App.Core.QuickReply(b.Tag as string, _incomingDoor);
            IncomingHint.Text = Texts.T("reply.sent", b.Content);
            IncomingHint.Visibility = Visibility.Visible;
            // 画面は複製されてくる reply イベント (= 応対済み) で畳む — 届かなくても
            // _incomingTimeout の安全弁がある
        }

        private void CloseIncoming(bool hangup)
        {
            _incomingTimeout.Stop();
            _answerDelay.Stop();
            if (_incomingStreamer != null) { _incomingStreamer.Stop(); _incomingStreamer = null; }
            IncomingView.Visibility = Visibility.Collapsed;
            IncomingLive.Source = null;
            AnswerButton.IsEnabled = true;
            if (hangup && _sipMode != "" && !_inCall)
            {
                App.Core.SipHangup();
                _sipMode = "";
            }
        }

        private void OnAnswerClick(object sender, RoutedEventArgs e)
        {
            if (string.IsNullOrEmpty(_incomingHost)) return;  // 門口機不明 — 応答不可
            AnswerButton.IsEnabled = false;                   // 二重発呼防止
            if (_sipMode == "monitor")
            {
                // 監聴呼を切ってから応答 (主呼は同時に 1 本 — sipctl の契約)
                App.Core.SipHangup();
                _answerDelay.Stop();
                _answerDelay.Start();
                return;
            }
            PlaceAnswerCall();
        }

        /// <summary>門口機へ直呼 (X-Doorbell-Mode: answer)。門口機側は電話腿を取消して双方向応答する。</summary>
        private void PlaceAnswerCall()
        {
            _sipMode = "answer";
            App.Core.SipCall("sip:" + _incomingHost + ":" + _directPort, "answer");
        }

        private void OnMonitorClick(object sender, RoutedEventArgs e)
        {
            if (string.IsNullOrEmpty(_incomingHost) || _sipMode != "") return;
            _sipMode = "monitor";
            App.Core.SipCall("sip:" + _incomingHost + ":" + _directPort, "monitor");
            IncomingHint.Text = Texts.T("ring.monitoring");
            IncomingHint.Visibility = Visibility.Visible;
        }

        private void OnIgnoreClick(object sender, RoutedEventArgs e) => CloseIncoming(true);

        private void OnEndCallClick(object sender, RoutedEventArgs e)
        {
            App.Core.SipHangup();  // state idle が来て CloseInCall される (即時にも畳む)
            CloseInCall();
        }

        /// <summary>SIP in_call — 役割ごとに通話中画面へ。ev.peer_stream = 相手映像 (対称 MJPEG)。</summary>
        private void OnSipInCall(UiEvent ev)
        {
            _inCall = true;
            _incomingTimeout.Stop();
            CallingText.Text = Texts.T("incall.title");  // CallingView 用 (映像なしの門口機)
            string stream = ev.Str("peer_stream");
            if (App.Boot.Role == "door_station")
            {
                _callTimeout.Stop();
                if (!string.IsNullOrEmpty(stream))
                {
                    ShowInCall(stream);        // 双方向映像の門口側 (相手 = 室内機)
                }
                else
                {
                    // 相手不明 (電話/網頁) — 網頁通話なら自機 /peer-frame.jpg にフレームが来る
                    _peerPollBusy = false;
                    _peerPoll.Start();
                }
            }
            else if (_sipMode == "answer")
            {
                // 室内機の応答が確立。相手映像 = peer_stream (無ければ来鈴と同じ門口 stream)
                if (string.IsNullOrEmpty(stream)) stream = _incomingStreamUrl;
                CloseIncoming(false);
                ShowInCall(stream);
            }
            // _sipMode == "monitor" は来鈴画面のまま (映像 + 監聴継続)
        }

        private void OnSipIdle()
        {
            bool wasInCall = _inCall;
            _inCall = false;
            _sipMode = "";
            CloseInCall();
            if (wasInCall && IncomingView.Visibility == Visibility.Visible)
                CloseIncoming(false);  // 応答通話が終わった → 来鈴画面も畳む
            if (App.Boot.Role == "door_station") ShowIdle();
        }

        private void ShowInCall(string streamUrl)
        {
            ExitScreensaver();
            if (_inCallStreamer != null) { _inCallStreamer.Stop(); _inCallStreamer = null; }
            PeerVideo.Source = null;
            if (!string.IsNullOrEmpty(streamUrl))
            {
                _inCallStreamer = new MjpegStreamer(streamUrl, bmp =>
                    Dispatcher.BeginInvoke(new Action(() => PeerVideo.Source = bmp)));
                _inCallStreamer.Start();
            }
            InCallView.Visibility = Visibility.Visible;
        }

        private void CloseInCall()
        {
            _peerPoll.Stop();
            if (_inCallStreamer != null) { _inCallStreamer.Stop(); _inCallStreamer = null; }
            PeerVideo.Source = null;
            InCallView.Visibility = Visibility.Collapsed;
        }

        /// <summary>網頁通話の相手映像: 自機 httpd の /peer-frame.jpg を輪詢 (通話中のみ)。</summary>
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
                catch { /* フレーム無し (404) = 相手が映像を送っていない */ }
                var bmp = jpg != null ? MjpegStreamer.Decode(jpg) : null;
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    _peerPollBusy = false;
                    if (!_inCall || bmp == null) return;
                    if (InCallView.Visibility != Visibility.Visible) ShowInCall(null);
                    PeerVideo.Source = bmp;
                }));
            });
        }

        // ---------- 操作 ----------
        private void OnCallClick(object sender, RoutedEventArgs e)
        {
            _callFeedback = PlayConfigured(_callFeedback,
                SoundValue("call_sound", "outdoor_call_alert"),
                ConfigBool("ui.call_sound_loop", false));
            App.Core.Press(App.Boot.Door);
            ShowCalling();
        }

        private void OnCancelClick(object sender, RoutedEventArgs e)
        {
            _callTimeout.Stop();
            ShowIdle();
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
                // watchdog の前台守衛を止める (存在中は引き戻さない — 再起動で自動削除)
                try
                {
                    File.WriteAllText(Path.Combine(App.DataDir, "admin_unlocked.flag"),
                                      DateTime.Now.ToString("s"));
                }
                catch { /* 書けなくても解錠自体は成立 */ }
            }
        }
    }
}
