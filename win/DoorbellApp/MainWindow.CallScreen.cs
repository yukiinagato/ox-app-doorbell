using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp
{
    /// <summary>
    /// Incoming and in-call surfaces (spec 5.1 and 5.2, page A2): the shared overlay with the
    /// announcement chip, this node's admin QR and the player statistics, plus the stateful
    /// controls in the single control row.
    /// </summary>
    public partial class MainWindow
    {
        private void ShowCallOverlay(string door)
        {
            _noticeChipDoor = door ?? "";
            CallOverlay.Visibility = Visibility.Visible;
            NoticePopover.Visibility = Visibility.Collapsed;
            VideoStatsCard.Visibility = _showVideoStats ?
                Visibility.Visible : Visibility.Collapsed;
            RefreshAdminLink();
            RefreshCallNoticeChip();
        }

        private void HideCallOverlay()
        {
            CallOverlay.Visibility = Visibility.Collapsed;
            NoticePopover.Visibility = Visibility.Collapsed;
            _statsRefresh.Stop();
        }

        /// <summary>Tapping the line hides it; the choice is remembered on this device.</summary>
        private void OnVideoStatsClick(object sender, MouseButtonEventArgs e)
        {
            _showVideoStats = !_showVideoStats;
            VideoStatsCard.Visibility = _showVideoStats ?
                Visibility.Visible : Visibility.Collapsed;
            SaveVideoStatsPreference();
        }

        /// <summary>
        /// codec/strategy, latency, jitter, frame rate and dropped frames from the player's own
        /// counters. It sits in the bottom corner and never covers the video.
        /// </summary>
        private void RefreshVideoStats()
        {
            if (!_showVideoStats || CallOverlay.Visibility != Visibility.Visible) return;
            bool inCall = InCallView.Visibility == Visibility.Visible;
            MjpegStreamer streamer = inCall ? _inCallStreamer : _incomingStreamer;
            H264LiveStreamer native = inCall ? _inCallNative : _incomingNative;
            bool nativeActive = native != null && native.HasFrames;
            MediaElement h264 = inCall ? PeerH264 : IncomingH264;
            bool h264Active = h264.Visibility == Visibility.Visible && h264.Opacity > 0.5;
            if (streamer == null && !h264Active && !nativeActive)
            {
                VideoStatsText.Text = "";
                return;
            }
            VideoStats stats = nativeActive ? native.Stats() :
                (streamer == null ? null : streamer.Stats());
            string codec = nativeActive || h264Active ? "h264" : "mjpeg";
            if (App.SafeMode) codec += "/safe";
            string latency = stats != null && stats.LatencyMs >= 0 ?
                stats.LatencyMs.ToString() : "—";
            string jitter = stats != null && stats.JitterMs >= 0 ?
                stats.JitterMs.ToString() : "—";
            string fps = stats != null && stats.Fps > 0 ?
                stats.Fps.ToString("0.0") : "—";
            string dropped = stats == null ? "0" : stats.Dropped.ToString();
            VideoStatsText.Text = Texts.T("video.stats", codec, latency, jitter, fps, dropped);
        }

        private void ApplyMonitorLabel()
        {
            MonitorButton.Content = _monitorAudioOn ? Texts.T("ring.monitor_on")
                                                    : Texts.T("ring.monitor_off");
            MonitorButton.Background = _monitorAudioOn ?
                (Brush)FindResource("Accent") : (Brush)FindResource("Card");
            MonitorButton.Foreground = _monitorAudioOn ?
                (Brush)FindResource("OnAccent") : (Brush)FindResource("Fg");
        }

        private void ApplyMicLabel()
        {
            string label = _micMuted ? Texts.T("ring.mic_off") : Texts.T("ring.mic_on");
            MicButton.Content = label;
            InCallMicButton.Content = label;
            Brush background = _micMuted ?
                (Brush)FindResource("Danger") : (Brush)FindResource("Card");
            Brush foreground = _micMuted ?
                (Brush)FindResource("OnDanger") : (Brush)FindResource("Fg");
            MicButton.Background = background;
            MicButton.Foreground = foreground;
            InCallMicButton.Background = background;
            InCallMicButton.Foreground = foreground;
        }

        /// <summary>
        /// The microphone toggle only exists when the loaded Core exports a mute entry point; the
        /// shell never offers a control it cannot honour.
        /// </summary>
        private void OnMicClick(object sender, RoutedEventArgs e)
        {
            if (!App.Core.SipMicMuteAvailable) return;
            bool wanted = !_micMuted;
            if (!App.Core.SipSetMicMuted(wanted))
            {
                ShowCallMessage(Texts.T("sip.unavailable"));
                return;
            }
            _micMuted = wanted;
            ApplyMicLabel();
        }

        private void OnQuickReplyToggleClick(object sender, RoutedEventArgs e)
        {
            _quickRepliesOpen = !_quickRepliesOpen;
            ApplyQuickReplyVisibility();
        }

        /// <summary>
        /// Keeps the visitor's chosen purpose visible while talking. The slot has a fixed height,
        /// so a purpose that arrives after the call started never moves the controls.
        /// </summary>
        private void UpdateInCallPurpose()
        {
            var purposes = CoreClient.Dig(_cfg, "visit_purposes") as Dictionary<string, object>;
            var entry = purposes != null && !string.IsNullOrEmpty(_incomingPurpose) &&
                        purposes.ContainsKey(_incomingPurpose)
                ? purposes[_incomingPurpose] as Dictionary<string, object> : null;
            if (string.IsNullOrEmpty(_incomingPurpose))
            {
                InCallPurposeBadge.Visibility = Visibility.Collapsed;
                return;
            }
            FillPurposeBadge(InCallPurposeContent, entry, _incomingPurpose,
                             LabelOf(entry, Texts.Lang, _incomingPurpose));
            InCallPurposeBadge.Visibility = Visibility.Visible;
        }
    }
}
