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
    // Brightness and the screensaver.
    public partial class MainWindow
    {
        private void ApplyDisplayFromStatus(Dictionary<string, object> st)
        {
            _status = st;
            var disp = CoreClient.Dig(st, "display") as Dictionary<string, object>;
            if (disp != null)
            {
                _display = disp;
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
            var saver = CoreClient.Dig(_display, "screensaver") as Dictionary<string, object>;
            _screensaverBrightness = DictInt(saver, "brightness", 10);
            _screensaverMode = DictStr(saver, "mode");
            if (_screensaverAfterS <= 0) ExitScreensaver();
            UpdateScreensaverPresentation();
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
                SetBrightnessAsync(_screensaverOn ? Math.Min(_brightness, _screensaverBrightness) : _brightness);
            ApplyThemeBackdrop();
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
            UpdateScreensaverPresentation();
            MoveSaverClock();
            if (!App.SafeMode) _saverDrift.Start();
            SetBrightnessAsync(Math.Min(_brightness, _screensaverBrightness));
        }

        private void UpdateScreensaverPresentation()
        {
            ScreensaverView.Visibility = _screensaverOn && _screensaverMode == "clock"
                ? Visibility.Visible : Visibility.Collapsed;
            ThemeBgImage.Visibility = !SaverHidesImage && ThemeBgImage.Source != null
                ? Visibility.Visible : Visibility.Collapsed;
            ApplyThemeBackdrop();
            ApplyAutoInk();
            QueueInkPass();
        }

        private void ExitScreensaver()
        {
            if (!_screensaverOn) return;
            _screensaverOn = false;
            _saverDrift.Stop();
            UpdateScreensaverPresentation();
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
    }
}
