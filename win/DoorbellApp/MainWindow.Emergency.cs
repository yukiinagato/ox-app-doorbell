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
    // SOS trigger, presentation and siren.
    public partial class MainWindow
    {
        private void RefreshSosConfig(Dictionary<string, object> cfg)
        {
            bool previousVisibility = SosButton.Visibility == Visibility.Visible;
            int previousCountdown = _sosCountdownS;
            bool show = App.Boot.Role == "indoor_panel";
            var roles = CoreClient.Dig(cfg, "emergency.button_on_roles") as System.Collections.IEnumerable;
            if (roles != null && !(roles is string))
            {
                show = false;
                foreach (var r in roles)
                    if (r != null && r.ToString() == App.Boot.Role) show = true;
            }
            SosButton.Visibility = show ? Visibility.Visible : Visibility.Collapsed;

            // Sliding and confirmed accessible activation use the same cancellable countdown.
            // Legacy "hold" remains an accepted configuration spelling.
            var countdown = CoreClient.Dig(cfg, "emergency.trigger.countdown_s");
            _sosCountdownS = 3;
            if (countdown != null)
            {
                int seconds;
                if (int.TryParse(countdown.ToString(), out seconds) &&
                    seconds >= 0 && seconds <= 10) _sosCountdownS = seconds;
            }
            if (previousVisibility != show || previousCountdown != _sosCountdownS) _sosReview.Revoke();
            ApplySosLabel();

            // status.emergency.cancel_requires_password is cancel_requires_pin AND a password
            // actually being set; core is explicit that the clear control must never be gated on
            // cancel_requires_pin alone.
            bool? required = App.Core.EmergencyCancelRequiresPassword(_status);
            if (required.HasValue)
            {
                _cancelRequiresPin = required.Value;
                return;
            }
            var pin = CoreClient.Dig(cfg, "emergency.cancel_requires_pin");
            _cancelRequiresPin = !(pin is bool) || (bool)pin;
        }

        // Deliberate two-part label: the second line is the smaller, muted explanation and the
        // break is authored in the catalog rather than produced by wrapping.
        private void ApplySosLabel()
        {
            System.Windows.Automation.AutomationProperties.SetName(SosSlide, Texts.T("sos.accessibility_start"));
            System.Windows.Automation.AutomationProperties.SetHelpText(SosSlide, Texts.T("sos.accessibility_hint"));
            string label = Texts.T("sos.slide_label", _sosCountdownS);
            int split = label.IndexOf('\n');
            SosText.Text = split >= 0 ? label.Substring(0, split) : label;
            SosHint.Text = split >= 0 ? label.Substring(split + 1) : "";
            SosHint.Visibility = SosHint.Text.Length == 0 ?
                Visibility.Collapsed : Visibility.Visible;
        }

        /// <summary>A complete slide or reviewed activation starts the same cancellable countdown.</summary>
        private void OnSosArmed()
        {
            if (_emergencyActive || _sosCountdownLeft > 0 || !SosSlide.IsLoaded ||
                !SosSlide.IsVisible || !SosSlide.IsEnabled) return;
            _sosReview.Revoke();
            if (_sosCountdownS <= 0)
            {
                CommitEmergency();
                return;
            }
            _sosCountdownLeft = _sosCountdownS;
            SosCountdownText.Text = Texts.T("sos.countdown", _sosCountdownLeft);
            SosCountdownView.Visibility = Visibility.Visible;
            long revision = ++_sosCountdownRevision, generation = App.Core.Generation;
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _sosCountdown = timer;
            timer.Tick += (s, e) => {
                if (_sosCountdown != timer || revision != _sosCountdownRevision) return;
                if (generation != App.Core.Generation) { StopSosCountdown(); return; }
                OnSosCountdownTick();
            };
            timer.Start();
        }

        private void OnSosCountdownTick()
        {
            if (_sosCountdownLeft <= 0 || SosCountdownView.Visibility != Visibility.Visible) return;
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
            _sosReview.Revoke();
            ++_sosCountdownRevision;
            _sosCountdown?.Stop();
            _sosCountdown = null;
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
            // _cancelRequiresPin already carries core's own answer, which folds in "a password
            // is actually set". The second test only covers a core that does not report it.
            bool prompted = false;
            if (_cancelRequiresPin && !AdminDialog.ClusterPasswordUnset())
            {
                var dlg = new AdminDialog { Owner = this };
                if (dlg.ShowDialog() != true) return;
                prompted = true;
            }
            if (App.Core.Emergency(false)) HideEmergency();
            else CoreClient.WriteAppLog("SOS clear was not durably committed");
            // The password only authorised this clear, not a lasting native admin session.
            if (prompted && !_adminUnlocked) App.Core.AdminLock();
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
    }
}
