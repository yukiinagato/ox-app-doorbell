using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp.Pairing
{
    /// <summary>
    /// Full-screen QR scanner (spec 5.1.4). Core owns both the camera and the decoder on Windows:
    /// this window starts scan mode, keeps feeding the frames core publishes, and renders the
    /// qr_scanned / invite_result / device_joined events that follow.
    /// </summary>
    public partial class QrScanWindow : Window
    {
        private const int NoCameraTimeoutSeconds = 8;
        private const int LocalDecodeGraceMs = 1500;
        private const int CloseAfterJoinSeconds = 2;

        private readonly DispatcherTimer _cameraWatchdog = new DispatcherTimer();
        private readonly DispatcherTimer _localDecodeGrace = new DispatcherTimer();
        private readonly DispatcherTimer _closeDelay = new DispatcherTimer();
        private readonly Action<UiEvent> _eventHandler;
        private PairingCameraFeed _feed;

        private string _handledText = "";
        private string _pendingLocalText = "";
        private bool _cameraFailed;

        public QrScanWindow()
        {
            InitializeComponent();
            Title = Texts.T("app.name");
            HintText.Text = Texts.T("pair.scan_hint");
            CancelButton.Content = Texts.T("calling.cancel");
            MessageText.Text = Texts.T("pair.scan_no_camera");
            ShowStatus(Texts.T("pair.scan_opening"), "");

            _eventHandler = ev => Dispatcher.BeginInvoke(new Action(() => OnCoreEvent(ev)));

            _cameraWatchdog.Interval = TimeSpan.FromSeconds(NoCameraTimeoutSeconds);
            _cameraWatchdog.Tick += (sender, args) =>
            {
                _cameraWatchdog.Stop();
                if (_feed != null && _feed.FrameCount > 0) return;
                ShowCameraUnavailable();
            };
            _localDecodeGrace.Interval = TimeSpan.FromMilliseconds(LocalDecodeGraceMs);
            _localDecodeGrace.Tick += (sender, args) =>
            {
                _localDecodeGrace.Stop();
                ApplyLocalDecode();
            };
            _closeDelay.Interval = TimeSpan.FromSeconds(CloseAfterJoinSeconds);
            _closeDelay.Tick += (sender, args) => { _closeDelay.Stop(); Close(); };

            Loaded += (sender, args) => StartScanning();
            Closed += (sender, args) => StopScanning();
        }

        private void StartScanning()
        {
            App.Core.UiEventReceived += _eventHandler;
            App.Core.QrScanStart();
            _feed = new PairingCameraFeed(Dispatcher, OnPreviewFrame, OnLocalDecode);
            _feed.Start();
            _cameraWatchdog.Start();
        }

        private void StopScanning()
        {
            _cameraWatchdog.Stop();
            _localDecodeGrace.Stop();
            _closeDelay.Stop();
            App.Core.UiEventReceived -= _eventHandler;
            if (_feed != null)
            {
                _feed.Stop();
                _feed = null;
            }
            App.Core.QrScanStop();
        }

        private void OnPreviewFrame(BitmapSource frame)
        {
            if (_cameraFailed) return;
            PreviewImage.Source = frame;
            MessagePanel.Visibility = Visibility.Collapsed;
            Viewfinder.Visibility = Visibility.Visible;
            if (_handledText.Length == 0) ShowStatus("", "");
        }

        private void ShowCameraUnavailable()
        {
            _cameraFailed = true;
            if (_feed != null)
            {
                _feed.Stop();
                _feed = null;
            }
            PreviewImage.Source = null;
            Viewfinder.Visibility = Visibility.Collapsed;
            MessagePanel.Visibility = Visibility.Visible;
            ShowStatus("", "");
        }

        private void ShowStatus(string text, string detail)
        {
            StatusText.Text = text ?? "";
            StatusText.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed :
                                                                 Visibility.Visible;
            StatusDetail.Text = detail ?? "";
            StatusDetail.Visibility = string.IsNullOrEmpty(detail) ? Visibility.Collapsed :
                                                                     Visibility.Visible;
        }

        // Redundant local decode. Core normally answers first with qr_scanned; this only fires when
        // it stays silent for the grace window, so a payload is never invited twice.
        private void OnLocalDecode(string text)
        {
            if (string.IsNullOrEmpty(text) || text == _handledText) return;
            if (_localDecodeGrace.IsEnabled && text == _pendingLocalText) return;
            _pendingLocalText = text;
            _localDecodeGrace.Stop();
            _localDecodeGrace.Start();
        }

        private void ApplyLocalDecode()
        {
            string text = _pendingLocalText;
            _pendingLocalText = "";
            if (string.IsNullOrEmpty(text) || text == _handledText) return;
            _handledText = text;
            Invite(text);
        }

        private void OnCoreEvent(UiEvent ev)
        {
            if (ev == null) return;
            switch (ev.T)
            {
                case "qr_scanned":
                    {
                        string text = ev.Str("text");
                        if (string.IsNullOrEmpty(text)) break;
                        _localDecodeGrace.Stop();
                        _pendingLocalText = "";
                        if (text == _handledText) break;
                        _handledText = text;
                        // Core invites automatically for a valid pairing payload.
                        if (EventBool(ev, "invited")) ShowStatus(Texts.T("pair.adding"), "");
                        else Invite(text);
                        break;
                    }
                case "invite_result":
                    if (!EventBool(ev, "ok"))
                    {
                        string code = ev.Str("err");
                        ShowStatus(Texts.T("pair.add_failed") + " — " +
                                   PairingText.ErrorMessage(code), PairingText.ErrorDetail(code));
                        _handledText = "";
                    }
                    break;
                case "device_joined":
                    ShowStatus(Texts.T("pair.added") + " ✓", "");
                    _closeDelay.Stop();
                    _closeDelay.Start();
                    break;
            }
        }

        private void Invite(string text)
        {
            string addr, id, publicKey;
            if (!PairingText.TryParsePairPayload(text, out addr, out id, out publicKey))
            {
                // Not one of our Add QRs: keep scanning instead of failing the whole flow.
                _handledText = "";
                ShowStatus("", "");
                return;
            }
            ShowStatus(Texts.T("pair.adding"), "");
            Task.Factory.StartNew(() => App.Core.InviteDirect(addr, id, publicKey));
        }

        private static bool EventBool(UiEvent ev, string key)
        {
            object value;
            if (ev == null || ev.Data == null || !ev.Data.TryGetValue(key, out value) ||
                value == null) return false;
            if (value is bool) return (bool)value;
            string text = value.ToString();
            return text == "true" || text == "True" || text == "1";
        }

        private void OnCancelClick(object sender, RoutedEventArgs e)
        {
            Close();
        }
    }
}
