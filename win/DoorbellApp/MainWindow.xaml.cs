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
        private readonly Random _rng = new Random();
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
            ApplyStrings();

            _clock.Interval = TimeSpan.FromSeconds(1);
            _clock.Tick += (s, e) => OnClockTick();
            _clock.Start();
            UpdateClock();

            _callTimeout.Interval = TimeSpan.FromSeconds(30);
            _callTimeout.Tick += (s, e) => { _callTimeout.Stop(); ShowIdle(L10n.T("calling.no_answer")); };
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

            // 無操作検出 (Preview 系は全 view のタッチ/クリック/キーで発火する)
            PreviewMouseDown += (s, e) => OnActivity();
            PreviewTouchDown += (s, e) => OnActivity();
            PreviewKeyDown += (s, e) => OnActivity();

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

        private void ApplyStrings()
        {
            Title = L10n.T("app.name");
            CallButton.Content = L10n.T("idle.call_button", "").Trim();
            TouchHint.Text = L10n.T("idle.touch_to_call");
            CallingText.Text = L10n.T("calling.title");
            CancelButton.Content = L10n.T("calling.cancel");
            ReplyCaption.Text = L10n.T("reply.banner");
            OfflineTitle.Text = L10n.T("offline.title");
            OfflineBody.Text = L10n.T("offline.body");
            SosText.Text = L10n.T("emergency.button");
            SosHint.Text = L10n.T("emergency.hold_hint", _sosHoldS);
            EmergencyTitle.Text = L10n.T("emergency.title");
            EmergencyNote.Text = L10n.T("emergency.notified");
            EmergencyCancelButton.Content = L10n.T("emergency.cancel");
        }

        private void OnClockTick()
        {
            UpdateClock();
            // 無操作 screensaver_after_s でスクリーンセーバへ (待機中のみ)
            if (!_screensaverOn && !_emergencyActive && _screensaverAfterS > 0 &&
                IdleView.Visibility == Visibility.Visible &&
                CallingView.Visibility != Visibility.Visible &&
                OfflineView.Visibility != Visibility.Visible &&
                (DateTime.Now - _lastActivity).TotalSeconds > _screensaverAfterS)
                EnterScreensaver();
        }

        private void UpdateClock()
        {
            var now = DateTime.Now;
            ClockText.Text = now.ToString("HH:mm");
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
            var st = App.Core.Status();
            var cfg = App.Core.Config();
            if (st != null)
            {
                try
                {
                    var node = st["node"] as Dictionary<string, object>;
                    if (node != null)
                        NodeInfo.Text = node["name"] + " · v" + node["version"];
                }
                catch { }
                // 初期表示状態 (起動直後の {"t":"display"}/{"t":"emergency"} は購読前に流れている
                // ことがある — status_json の同梱値で追い付く)
                ApplyDisplayFromStatus(st);
            }
            // 呼び出しボタンにドアの表示名 (設定 doors.<door>.label.<lang>) を反映
            if (!string.IsNullOrEmpty(App.Boot.Door) && cfg != null)
            {
                var label = CoreClient.Dig(cfg, "doors." + App.Boot.Door + ".label." + App.Boot.UiLang)
                            ?? CoreClient.Dig(cfg, "doors." + App.Boot.Door + ".label.ja");
                if (label != null)
                    CallButton.Content = L10n.T("idle.call_button", label.ToString());
            }
            RefreshSosConfig(cfg);
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
            SosHint.Text = L10n.T("emergency.hold_hint", _sosHoldS);

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
            CallingView.Visibility = Visibility.Collapsed;
            OfflineView.Visibility = Visibility.Collapsed;
            IdleView.Visibility = Visibility.Visible;
            if (hint != null) TouchHint.Text = hint;
        }

        private void ShowCalling()
        {
            ExitScreensaver();
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
                    if (stv == "calling") ShowCalling();
                    else if (stv == "idle") ShowIdle();
                    else if (stv == "in_call") CallingText.Text = L10n.T("incall.title");
                    break;
                case "chime":
                    ExitScreensaver();
                    SystemSounds.Exclamation.Play();  // TODO(Phase1後半): 同梱 wav の再生
                    break;
                case "reply":
                    ExitScreensaver();
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

        // ---------- 操作 ----------
        private void OnCallClick(object sender, RoutedEventArgs e)
        {
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
            }
        }
    }
}
