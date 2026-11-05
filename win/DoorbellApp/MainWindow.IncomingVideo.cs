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
    // Incoming-call video: native H.264, MediaElement fallback and MJPEG.
    public partial class MainWindow
    {
        private void StartIncomingVideo()
        {
            StopIncomingVideo();
            IncomingNoVideo.Visibility = Visibility.Visible;
            _incomingH264Failures = 0;
            StartIncomingMjpeg(true);
            StartIncomingH264();
        }

        private void StartIncomingH264()
        {
            if (App.SafeMode || string.IsNullOrEmpty(_incomingStreamMp4Url)) return;
            if (H264LiveStreamer.Available)
            {
                StartIncomingNativeH264();
                return;
            }
            try
            {
                VideoDiagnostics.RecordAttempt("incoming", _incomingStreamMp4Url);
                IncomingH264.Opacity = 0;
                IncomingH264.Source = new Uri(_incomingStreamMp4Url, UriKind.Absolute);
                IncomingH264.Visibility = Visibility.Visible;
                IncomingH264.Play();
                _h264Fallback.Stop();
                _h264Fallback.Interval = H264OpenTimeout;
                _h264Fallback.Start();
            }
            catch (Exception ex)
            {
                Debug.WriteLine("H.264 start failed: " + ex.Message);
                VideoDiagnostics.RecordFailure("incoming", _incomingStreamMp4Url,
                    "start_exception", ex);
                ScheduleIncomingH264Retry();
            }
        }

        private void StartIncomingNativeH264()
        {
            if (_incomingNative != null) return;
            string url = _incomingStreamMp4Url;
            VideoDiagnostics.RecordAttempt("incoming_native", url);
            H264LiveStreamer native = null;
            native = new H264LiveStreamer(url, Dispatcher, (bmp, rotation) =>
            {
                if (_incomingNative != native) return;
                if (!ReferenceEquals(IncomingH264Image.Source, bmp)) IncomingH264Image.Source = bmp;
                IncomingH264Image.LayoutTransform = new RotateTransform(rotation);
                if (IncomingH264Image.Visibility != Visibility.Visible)
                {
                    IncomingH264Image.Visibility = Visibility.Visible;
                    IncomingLive.Visibility = Visibility.Collapsed;
                    IncomingNoVideo.Visibility = Visibility.Collapsed;
                    VideoDiagnostics.RecordSuccess("incoming_native", url + " first_frame_ms=" +
                        native.FirstFrameMs + " decoder=" + native.DecoderLabel);
                    // The MJPEG availability layer has done its job.
                    if (_incomingStreamer != null) { _incomingStreamer.Stop(); _incomingStreamer = null; }
                }
            }, reason =>
            {
                if (_incomingNative != native) return;
                VideoDiagnostics.RecordFailure("incoming_native", url, reason, null);
                StopIncomingNative();
                if (IncomingView.Visibility == Visibility.Visible) StartIncomingMjpeg(true);
            });
            _incomingNative = native;
            native.Start();
        }

        private void StopIncomingNative()
        {
            if (_incomingNative != null) { _incomingNative.Stop(); _incomingNative = null; }
            IncomingH264Image.Source = null;
            IncomingH264Image.Visibility = Visibility.Collapsed;
            IncomingH264Image.LayoutTransform = Transform.Identity;
            IncomingLive.Visibility = Visibility.Visible;
        }

        private void ScheduleIncomingH264Retry()
        {
            _h264Fallback.Stop();
            try { IncomingH264.Stop(); } catch { }
            IncomingH264.Source = null;
            IncomingH264.Visibility = Visibility.Collapsed;
            IncomingH264.Opacity = 1;
            IncomingLive.Visibility = Visibility.Visible;
            if (IncomingView.Visibility != Visibility.Visible || App.SafeMode ||
                string.IsNullOrEmpty(_incomingStreamMp4Url)) return;
            _incomingH264Failures++;
            if (_incomingH264Failures >= H264RetryBudget)
            {
                if (_incomingH264Failures == H264RetryBudget)
                    VideoDiagnostics.RecordFailure("incoming", _incomingStreamMp4Url,
                        "retry_budget_exhausted_mjpeg_only", null);
                return;
            }
            _h264Fallback.Interval = H264RetryDelay;
            _h264Fallback.Start();
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
            StopIncomingNative();
            if (_incomingStreamer != null) { _incomingStreamer.Stop(); _incomingStreamer = null; }
            try { IncomingH264.Stop(); } catch { }
            IncomingH264.Source = null;
            IncomingH264.Visibility = Visibility.Collapsed;
            IncomingH264.Opacity = 1;
            IncomingLive.Source = null;
            IncomingLive.Visibility = Visibility.Visible;
            IncomingLive.LayoutTransform = Transform.Identity;
        }
    }
}
