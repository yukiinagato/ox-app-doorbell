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
    // Wall clock and cluster-time display.
    public partial class MainWindow
    {
        private void OnClockTick()
        {
            UpdateClock();
            RefreshConversations();
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

        // Ticks once a second from the cached base, so a second never waits on a call into core.
        private void UpdateClock()
        {
            DateTime now = CorrectedNow();
            string time = now.ToString("HH:mm:ss");
            string date = now.ToString("yyyy年M月d日") + " (" + Weekday((int)now.DayOfWeek) + ")";
            ClockText.Text = time;
            DateText.Text = date;
            // Dashboard: hours and minutes large, the seconds small beside them (iPad 1 layout).
            DashClock.Text = now.ToString("HH:mm");
            DashClockSeconds.Text = ":" + now.ToString("ss");
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

        private static readonly DateTime UnixEpoch =
            new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        /// <summary>
        /// Now, in the cluster time zone, from the cached base alone. Until core has answered
        /// once this is simply the machine's own local clock.
        /// </summary>
        private DateTime CorrectedNow()
        {
            if (!_clockBaseKnown) return DateTime.Now;
            long elapsed = Stopwatch.GetTimestamp() - _clockBaseTimestamp;
            long elapsedMs = elapsed * 1000L / Stopwatch.Frequency;
            return InZone(_clockBaseWallMs + elapsedMs);
        }

        /// <summary>
        /// The current hour and minute for the appearance schedule, taken from the cached clock
        /// base so evaluating it costs no call into core.
        /// </summary>
        private Dictionary<string, object> ScheduleClock()
        {
            DateTime now = CorrectedNow();
            return new Dictionary<string, object>
            {
                { "hh", now.Hour },
                { "mm", now.Minute },
            };
        }

        /// <summary>One recorded wall-clock instant, rendered in the cluster time zone.</summary>
        private DateTime InZone(long wallMs)
        {
            if (!_clockBaseKnown) return UnixEpoch.AddMilliseconds(wallMs).ToLocalTime();
            return UnixEpoch.AddMilliseconds(wallMs + _clockZoneOffsetMin * 60000L);
        }

        /// <summary>
        /// Re-reads core's corrected wall clock and zone offset on a worker thread, then hands
        /// the two numbers back to the UI thread. Everything the clock draws comes from those.
        /// </summary>
        private void SyncClockBase()
        {
            if (_clockSyncBusy) { _clockSyncPending = true; return; }
            _clockSyncBusy = true;
            Task.Run(() =>
            {
                long before = Stopwatch.GetTimestamp();
                Dictionary<string, object> local = null;
                try { local = App.Core.LocalTime(0); }
                catch (Exception ex)
                {
                    Debug.WriteLine("clock base unavailable: " + ex.Message);
                }
                long after = Stopwatch.GetTimestamp();
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    _clockSyncBusy = false;
                    if (_clockSyncPending)
                    {
                        _clockSyncPending = false;
                        SyncClockBase();
                        return;
                    }
                    ApplyClockBase(local, before, after);
                }));
            });
        }

        private void ApplyClockBase(Dictionary<string, object> local, long before, long after)
        {
            if (local == null) return;
            long wallMs = DictLong(local, "wall_ms", 0);
            if (wallMs <= 0) return;
            object offset;
            if (!local.TryGetValue("offset_min", out offset) || offset == null) return;
            int zoneMinutes;
            if (!int.TryParse(offset.ToString(), out zoneMinutes) ||
                zoneMinutes < -900 || zoneMinutes > 900) return;
            // The reading is from the middle of the call, so the round trip does not skew it.
            _clockBaseWallMs = wallMs;
            _clockBaseTimestamp = before + (after - before) / 2;
            _clockZoneOffsetMin = zoneMinutes;
            _clockBaseKnown = true;
            object known;
            if (local.TryGetValue("known", out known) && known is bool && !(bool)known)
                Debug.WriteLine("core reports an unknown time zone");
            UpdateClock();
        }
    }
}
