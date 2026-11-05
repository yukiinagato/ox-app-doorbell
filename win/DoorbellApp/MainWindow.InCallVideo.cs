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
    // In-call video and the peer return frame.
    public partial class MainWindow
    {
        private void ShowInCall(string streamUrl)
        {
            StopSosCountdown();
            OfflineView.Visibility = Visibility.Collapsed;
            UpdateVisitorActionHeights(ActualWidth);
            ExitScreensaver();
            IdleView.Visibility = Visibility.Collapsed;
            CallingView.Visibility = Visibility.Collapsed;
            if (_inCallStreamer != null) { _inCallStreamer.Stop(); _inCallStreamer = null; }
            StopInCallNative();
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
            _inCallH264Failures = 0;
            StartInCallMjpeg();
            StartInCallH264();
            InCallView.Visibility = Visibility.Visible;
            PauseReturnCountdown();
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
            if (H264LiveStreamer.Available)
            {
                StartInCallNativeH264();
                return;
            }
            try
            {
                VideoDiagnostics.RecordAttempt("in_call", _inCallH264Url);
                PeerH264.Opacity = 0;
                PeerH264.Source = new Uri(_inCallH264Url, UriKind.Absolute);
                PeerH264.Visibility = Visibility.Visible;
                PeerH264.Play();
                _peerH264Retry.Stop();
                _peerH264Retry.Interval = H264OpenTimeout;
                _peerH264Retry.Start();
            }
            catch (Exception ex)
            {
                VideoDiagnostics.RecordFailure("in_call", _inCallH264Url, "start_exception", ex);
                ScheduleInCallH264Retry();
            }
        }

        private void StartInCallNativeH264()
        {
            if (_inCallNative != null) return;
            string url = _inCallH264Url;
            VideoDiagnostics.RecordAttempt("in_call_native", url);
            H264LiveStreamer native = null;
            native = new H264LiveStreamer(url, Dispatcher, (bmp, rotation) =>
            {
                if (_inCallNative != native) return;
                if (!ReferenceEquals(PeerH264Image.Source, bmp)) PeerH264Image.Source = bmp;
                PeerH264Image.LayoutTransform = new RotateTransform(rotation);
                if (PeerH264Image.Visibility != Visibility.Visible)
                {
                    PeerH264Image.Visibility = Visibility.Visible;
                    PeerVideo.Visibility = Visibility.Collapsed;
                    VideoDiagnostics.RecordSuccess("in_call_native", url + " first_frame_ms=" +
                        native.FirstFrameMs + " decoder=" + native.DecoderLabel);
                    if (_inCallStreamer != null) { _inCallStreamer.Stop(); _inCallStreamer = null; }
                }
            }, reason =>
            {
                if (_inCallNative != native) return;
                VideoDiagnostics.RecordFailure("in_call_native", url, reason, null);
                StopInCallNative();
                if (InCallView.Visibility == Visibility.Visible) StartInCallMjpeg();
            });
            _inCallNative = native;
            native.Start();
        }

        private void StopInCallNative()
        {
            if (_inCallNative != null) { _inCallNative.Stop(); _inCallNative = null; }
            PeerH264Image.Source = null;
            PeerH264Image.Visibility = Visibility.Collapsed;
            PeerH264Image.LayoutTransform = Transform.Identity;
            PeerVideo.Visibility = Visibility.Visible;
        }

        private void ScheduleInCallH264Retry()
        {
            _peerH264Retry.Stop();
            try { PeerH264.Stop(); } catch { }
            PeerH264.Source = null;
            PeerH264.Visibility = Visibility.Collapsed;
            PeerH264.Opacity = 1;
            StartInCallMjpeg();
            if (InCallView.Visibility != Visibility.Visible || App.SafeMode ||
                string.IsNullOrEmpty(_inCallH264Url)) return;
            _inCallH264Failures++;
            if (_inCallH264Failures >= H264RetryBudget)
            {
                if (_inCallH264Failures == H264RetryBudget)
                    VideoDiagnostics.RecordFailure("in_call", _inCallH264Url,
                        "retry_budget_exhausted_mjpeg_only", null);
                return;
            }
            _peerH264Retry.Interval = H264RetryDelay;
            _peerH264Retry.Start();
        }

        private void CloseInCall()
        {
            RetirePeerFrame();
            _peerPoll.Stop();
            _peerH264Retry.Stop();
            StopInCallNative();
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

        private void RetirePeerFrame()
        {
            ++_peerFrameView;
            var request = _peerFrameRequest;
            _peerFrameRequest = null;
            _peerPollBusy = false;
            _peerFrameGate.Reset();
            _peerDisplayedIdentity = null;
            try { request?.Abort(); } catch { }
        }

        private void ExpirePeerFrameIfStale()
        {
            if (!_inCall || _peerDisplayedIdentity == null ||
                _peerFrameGate.IsFresh(_peerDisplayedIdentity)) return;
            PeerVideo.Source = null;
            PeerVideo.Visibility = Visibility.Collapsed;
            _peerDisplayedIdentity = null;
            InCallTitle.Text = Texts.T("ring.no_video");
        }

        private void PollPeerFrame()
        {
            if (!_inCall || _peerPollBusy) return;
            var identity = PeerFrameGate.Capture(App.Core.CallTimingSnapshot(), App.Boot.Door,
                                                  _activeCallId, _peerFrameView);
            if (identity == null || identity.CoreGeneration != App.Core.Generation) return;
            string peerFrameUrl;
            if (!PeerFrameUrlBuilder.TryBuild(App.Boot.HttpPort, identity.Query, out peerFrameUrl))
            {
                _peerPoll.Stop();
                RetirePeerFrame();
                PeerVideo.Source = null;
                return;
            }
            var request = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(
                peerFrameUrl);
            request.Timeout = 2000;
            request.ReadWriteTimeout = 1500;
            request.AllowAutoRedirect = false;
            request.CachePolicy = new System.Net.Cache.RequestCachePolicy(System.Net.Cache.RequestCacheLevel.NoCacheNoStore);
            _peerFrameRequest = request;
            _peerPollBusy = true;
            Task.Run(() =>
            {
                byte[] jpg = null;
                System.Net.WebHeaderCollection headers = null;
                try
                {
                    using (var deadline = new System.Threading.Timer(_ =>
                           { try { request.Abort(); } catch { } }, null, 2000, System.Threading.Timeout.Infinite))
                    using (var response = (System.Net.HttpWebResponse)request.GetResponse())
                    using (var stream = response.GetResponseStream())
                    using (var bytes = new MemoryStream())
                    {
                        if (response.StatusCode != System.Net.HttpStatusCode.OK ||
                            response.ContentLength > 1024 * 1024) throw new IOException("Invalid frame response");
                        headers = response.Headers;
                        var buffer = new byte[8192];
                        int count;
                        while ((count = stream.Read(buffer, 0, buffer.Length)) > 0)
                        {
                            if (bytes.Length + count > 1024 * 1024) throw new IOException("Frame exceeds limit");
                            bytes.Write(buffer, 0, count);
                        }
                        jpg = bytes.ToArray();
                    }
                }
                catch {  }
                var bmp = jpg != null && headers != null ? MjpegStreamer.Decode(jpg, App.SafeMode ? 640 : 0) : null;
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (_peerFrameRequest != request) return;
                    _peerFrameRequest = null;
                    _peerPollBusy = false;
                    if (!_inCall || bmp == null) return;
                    var current = PeerFrameGate.Capture(App.Core.CallTimingSnapshot(), App.Boot.Door,
                                                        _activeCallId, _peerFrameView);
                    if (identity.CoreGeneration != App.Core.Generation || !_peerFrameGate.Accept(identity,
                        current, headers["X-Doorbell-Call-Id"], headers["X-Doorbell-Stage-Revision"],
                        headers["X-Doorbell-Dialog-Owner"], headers["X-Doorbell-Media-Generation"],
                        headers["X-Doorbell-Frame-Sequence"])) return;
                    if (_peerDisplayedIdentity == null) InCallTitle.Text = Texts.T("incall.title");
                    _peerDisplayedIdentity = identity;
                    if (InCallView.Visibility != Visibility.Visible) ShowInCall(null);
                    PeerVideo.Visibility = Visibility.Visible;
                    PeerVideo.Source = bmp;
                }));
            });
        }
    }
}
