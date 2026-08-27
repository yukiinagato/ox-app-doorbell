// 門口機メイン画面: 待機 / 呼び出し中 / 返信バナー / オフライン の状態機。
// core からの UI イベント (state/chime/reply/…) で遷移する。SIP 実装 (Phase 1 後半) までは
// calling は 30 秒でタイムアウトして待機へ戻る。
using System;
using System.Media;
using System.Windows;
using System.Windows.Input;
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
        private int _secretTaps;
        private DateTime _secretFirst = DateTime.MinValue;
        private KioskHooks _kiosk;

        public MainWindow()
        {
            InitializeComponent();
            ApplyStrings();

            _clock.Interval = TimeSpan.FromSeconds(1);
            _clock.Tick += (s, e) => UpdateClock();
            _clock.Start();
            UpdateClock();

            _callTimeout.Interval = TimeSpan.FromSeconds(30);
            _callTimeout.Tick += (s, e) => { _callTimeout.Stop(); ShowIdle(L10n.T("calling.no_answer")); };
            _replyTimeout.Tick += (s, e) => { _replyTimeout.Stop(); ReplyBanner.Visibility = Visibility.Collapsed; };

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
        }

        private void UpdateClock()
        {
            var now = DateTime.Now;
            ClockText.Text = now.ToString("HH:mm");
            string[] yobi = { "日", "月", "火", "水", "木", "金", "土" };
            DateText.Text = now.ToString("yyyy年M月d日") + " (" + yobi[(int)now.DayOfWeek] + ")";
        }

        private void RefreshNodeInfo()
        {
            var st = App.Core.Status();
            if (st == null) return;
            try
            {
                var node = st["node"] as System.Collections.Generic.Dictionary<string, object>;
                if (node != null)
                    NodeInfo.Text = node["name"] + " · v" + node["version"];
            }
            catch { }
            // 呼び出しボタンにドアの表示名 (設定 doors.<door>.label.<lang>) を反映
            if (!string.IsNullOrEmpty(App.Boot.Door))
            {
                var cfg = App.Core.Config();
                var label = CoreClient.Dig(cfg, "doors." + App.Boot.Door + ".label." + App.Boot.UiLang)
                            ?? CoreClient.Dig(cfg, "doors." + App.Boot.Door + ".label.ja");
                if (label != null)
                    CallButton.Content = L10n.T("idle.call_button", label.ToString());
            }
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
                    SystemSounds.Exclamation.Play();  // TODO(Phase1後半): 同梱 wav の再生
                    break;
                case "reply":
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
