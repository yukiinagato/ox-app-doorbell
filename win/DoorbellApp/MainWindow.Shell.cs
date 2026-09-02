using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DoorbellApp.Core;
using DoorbellApp.Pairing;
using DoorbellApp.Util;

namespace DoorbellApp
{
    /// <summary>
    /// Cross-cutting shell behaviour: which home screen a role shows, the responsive layout,
    /// light/dark appearance with automatic ink, the version and battery line, and the
    /// 「Web 管理を開く」 entry that replaces native settings on Windows (spec 0.1).
    /// </summary>
    public partial class MainWindow
    {
        private const string RegionClock = "clock";
        private const string RegionDate = "date";
        private const string RegionFooter = "footer";
        private const string RegionHint = "hint";

        /// <summary>Door stations get the visitor screen; indoor panels get the dashboard.</summary>
        private void ApplyRoleHome()
        {
            bool door = App.Boot.Role == "door_station";
            VisitorHome.Visibility = door ? Visibility.Visible : Visibility.Collapsed;
            DashboardHome.Visibility = door ? Visibility.Collapsed : Visibility.Visible;
            // A door station never shows an entry to administration; the hidden corner plus the
            // admin password is the only way in (spec 0.2).
            SecretCorner.Visibility = Visibility.Visible;
            AdminEntryButton.Visibility = door ? Visibility.Collapsed : Visibility.Visible;
            AdminLinkCard.Visibility = door ? Visibility.Collapsed : Visibility.Visible;
            NoticeGlobalButton.Visibility = door ? Visibility.Collapsed : Visibility.Visible;
            ApplyResponsiveLayout();
        }

        /// <summary>
        /// Placement is computed from the window size rather than fixed to one orientation, so the
        /// same elements serve a portrait phone-sized window and a landscape tablet.
        /// </summary>
        private void ApplyResponsiveLayout()
        {
            double width = ActualWidth > 0 ? ActualWidth : SystemParameters.PrimaryScreenWidth;
            double height = ActualHeight > 0 ? ActualHeight : SystemParameters.PrimaryScreenHeight;
            bool portrait = height >= width || width < 900;
            bool large = width >= 1024;
            bool tablet = width >= 768;

            if (portrait)
            {
                VisitorRightColumn.Width = new GridLength(0);
                PlaceVisitor(VisitorClockBlock, 0, 0, 2, 1);
                PlaceVisitor(VisitorNoticeCard, 1, 0, 2, 1);
                PlaceVisitor(LangBar, 2, 0, 2, 1);
                PlaceVisitor(VisitorCallBlock, 3, 0, 2, 1);
                PlaceVisitor(TouchHint, 4, 0, 2, 1);
                VisitorClockBlock.HorizontalAlignment = HorizontalAlignment.Center;
            }
            else
            {
                VisitorRightColumn.Width = new GridLength(1.2, GridUnitType.Star);
                PlaceVisitor(VisitorClockBlock, 0, 0, 1, 1);
                // The notice fills the left column beside the language row and the call button.
                PlaceVisitor(VisitorNoticeCard, 1, 0, 1, 3);
                PlaceVisitor(LangBar, 2, 1, 1, 1);
                PlaceVisitor(VisitorCallBlock, 3, 1, 1, 1);
                PlaceVisitor(TouchHint, 4, 1, 1, 1);
                VisitorClockBlock.HorizontalAlignment = HorizontalAlignment.Left;
            }

            ClockText.FontSize = large ? 84 : (tablet ? 68 : 52);
            DateText.FontSize = large ? 26 : (tablet ? 22 : 17);
            CallButton.MinHeight = large ? 170 : (tablet ? 120 : 96);
            CallButton.MinWidth = tablet ? 360 : 240;
            CallButton.FontSize = large ? 44 : (tablet ? 34 : 26);
            TouchHint.FontSize = tablet ? 21 : 16;
            VisitorNoticeText.FontSize = tablet ? 22 : 17;

            if (portrait)
            {
                DashboardLeftColumn.Width = new GridLength(1, GridUnitType.Star);
                DashboardRightColumn.Width = new GridLength(0);
                DashboardTopRow.Height = new GridLength(1, GridUnitType.Star);
                DashboardBottomRow.Height = new GridLength(1.1, GridUnitType.Star);
                PlaceDashboard(DoorTilesPanel, 0, 0, 2);
                PlaceDashboard(RecentCallsPanel, 1, 0, 2);
                DoorTilesPanel.Margin = new Thickness(0, 0, 0, 8);
                RecentCallsPanel.Margin = new Thickness(0, 8, 0, 0);
            }
            else
            {
                DashboardLeftColumn.Width = new GridLength(1.4, GridUnitType.Star);
                DashboardRightColumn.Width = new GridLength(1, GridUnitType.Star);
                DashboardTopRow.Height = new GridLength(1, GridUnitType.Star);
                DashboardBottomRow.Height = new GridLength(0);
                PlaceDashboard(DoorTilesPanel, 0, 0, 1);
                PlaceDashboard(RecentCallsPanel, 0, 1, 1);
                DoorTilesPanel.Margin = new Thickness(0, 0, 8, 0);
                RecentCallsPanel.Margin = new Thickness(8, 0, 0, 0);
            }
            DoorTileGrid.Columns = portrait ? 2 : (large ? 2 : 1);

            bool stretchSos = portrait && App.Boot.Role == "door_station";
            SosButton.HorizontalAlignment = stretchSos ?
                HorizontalAlignment.Stretch : HorizontalAlignment.Right;
            SosButton.Width = stretchSos ? double.NaN : 238;
            SosButton.Margin = stretchSos ? new Thickness(26, 0, 26, 16)
                                          : new Thickness(0, 0, 20, 16);
            bool sosVisible = SosButton.Visibility == Visibility.Visible;
            VisitorFooter.Margin = new Thickness(0, 12, 0, stretchSos && sosVisible ? 76 : 0);
        }

        private static void PlaceVisitor(FrameworkElement element, int row, int column,
                                         int columnSpan, int rowSpan)
        {
            if (element == null) return;
            Grid.SetRow(element, row);
            Grid.SetColumn(element, column);
            Grid.SetColumnSpan(element, columnSpan);
            Grid.SetRowSpan(element, rowSpan);
        }

        private static void PlaceDashboard(FrameworkElement element, int row, int column,
                                           int columnSpan)
        {
            if (element == null) return;
            Grid.SetRow(element, row);
            Grid.SetColumn(element, column);
            Grid.SetColumnSpan(element, columnSpan);
        }

        /// <summary>Applies display.appearance and then the per-region automatic ink.</summary>
        private void ApplyAppearance()
        {
            Appearance.Apply(_cfg, _nodeId, App.Core.LocalTime(0), _display);
            ApplyAutoInk();
        }

        /// <summary>
        /// Text without its own background follows the luminance of what is behind it. Core
        /// publishes the decision so every shell agrees; this recomputes it only when the
        /// published value is absent.
        /// </summary>
        private void ApplyAutoInk()
        {
            if (_night) return;  // Night mode owns the clock colours.
            Color background = EffectiveBackground();
            Color ink = ThemeContrast.Ink(_display, RegionClock, background);
            Color dim = ThemeContrast.Ink(_display, RegionDate, background);
            var inkBrush = ThemeContrast.Brush(ink);
            var dimBrush = ThemeContrast.Brush(MixTowards(dim, background, 0.35));
            ClockText.Foreground = inkBrush;
            DashClock.Foreground = inkBrush;
            DateText.Foreground = dimBrush;
            DashDate.Foreground = dimBrush;
            TouchHint.Foreground = ThemeContrast.Brush(
                MixTowards(ThemeContrast.Ink(_display, RegionHint, background),
                           background, 0.25));
            var statusBrush = ThemeContrast.Brush(
                MixTowards(ThemeContrast.Ink(_display, RegionFooter, background),
                           background, 0.35));
            NodeInfo.Foreground = statusBrush;
            VisitorVersionLine.Foreground = statusBrush;

            if (App.Boot.Role == "door_station")
            {
                Color fill = ThemeContrast.CallButton(_display, background);
                CallButton.Background = ThemeContrast.Brush(fill);
                CallButton.Foreground =
                    ThemeContrast.Brush(ThemeContrast.CallButtonInk(_display, fill));
            }
        }

        /// <summary>The colour actually behind the idle screen, sampled from a theme image.</summary>
        private Color EffectiveBackground()
        {
            Color contract;
            // Core measured this once for the whole cluster, image averaging included.
            if (ThemeContrast.TryContractBackground(_display, out contract)) return contract;
            Color average;
            var bitmap = ThemeBgImage.Source as BitmapSource;
            if (ThemeBgImage.Visibility == Visibility.Visible && bitmap != null &&
                ThemeContrast.TryAverage(bitmap, out average)) return average;
            var brush = Background as SolidColorBrush;
            if (brush != null && brush.Color.A == 255) return brush.Color;
            return Appearance.Token("Bg");
        }

        private static Color MixTowards(Color ink, Color background, double amount)
        {
            if (amount <= 0) return ink;
            if (amount > 1) amount = 1;
            return Color.FromRgb(
                (byte)(ink.R + (background.R - ink.R) * amount),
                (byte)(ink.G + (background.G - ink.G) * amount),
                (byte)(ink.B + (background.B - ink.B) * amount));
        }

        /// <summary>
        /// A colour that misses its WCAG target is still applied; the shortfall is reported so the
        /// administrator sees the same soft warning the web admin shows (spec 5.2).
        /// </summary>
        private void PublishUiStyleWithAdvisories()
        {
            if (_semanticStyles == null) return;
            var report = _semanticStyles.RuntimeReport;
            if (report != null)
            {
                Color background = EffectiveBackground();
                var advisories = new List<Dictionary<string, object>>();
                AddAdvisory(advisories, "clock", ClockText.Foreground, background, 3.0);
                AddAdvisory(advisories, "footer", NodeInfo.Foreground, background, 4.5);
                if (App.Boot.Role == "door_station")
                {
                    var fill = CallButton.Background as SolidColorBrush;
                    if (fill != null)
                    {
                        AddAdvisory(advisories, "call_button_text", CallButton.Foreground,
                                    fill.Color, 4.5);
                        var advisory = ThemeContrast.Advise("call_button_bg", fill.Color,
                                                            background, 3.0);
                        if (advisory != null) advisories.Add(advisory.ToDictionary());
                    }
                }
                report["contrast_advisories"] = advisories;
                report["appearance"] = Appearance.Current;
                report["appearance_mode"] = Appearance.ConfiguredMode;
            }
            App.Core.PublishUiStyleStatus(App.Boot.Role, App.SafeMode, report);
        }

        private static void AddAdvisory(List<Dictionary<string, object>> into, string element,
                                        Brush foreground, Color background, double minimum)
        {
            var brush = foreground as SolidColorBrush;
            if (brush == null || brush.Color.A != 255) return;
            var advisory = ThemeContrast.Advise(element, brush.Color, background, minimum);
            if (advisory != null) into.Add(advisory.ToDictionary());
        }

        /// <summary>
        /// status.call.mic_muted is authoritative for the microphone toggle, so a mute set from
        /// another surface is reflected here too (spec 5.5).
        /// </summary>
        private void ReadCallStateFromStatus(Dictionary<string, object> status)
        {
            if (!App.Core.SipMicMuteAvailable) return;
            var call = CoreClient.Dig(status, "call") as Dictionary<string, object>;
            if (call == null || !call.ContainsKey("mic_muted")) return;
            bool muted = DictBool(call, "mic_muted");
            if (muted == _micMuted) return;
            _micMuted = muted;
            ApplyMicLabel();
        }

        private void ReadPowerFromStatus(Dictionary<string, object> status)
        {
            var power = CoreClient.Dig(status, "self.power") as Dictionary<string, object>;
            if (power == null)
                power = CoreClient.Dig(status, "node.power") as Dictionary<string, object>;
            if (power == null) return;
            _batteryPct = DictInt(power, "battery_pct", _batteryPct);
            _batteryCharging = DictBool(power, "charging");
        }

        /// <summary>
        /// Footer identity line: device name, the Core version and this app's version, then the
        /// battery. A device with no battery reports -1 and the indicator is hidden entirely.
        /// </summary>
        private void ApplyVersionLine(string name, string nodeVersion)
        {
            if (string.IsNullOrEmpty(_coreVersion))
            {
                _coreVersion = App.Core.CoreVersion;
                if (string.IsNullOrEmpty(_coreVersion)) _coreVersion = nodeVersion ?? "";
            }
            if (string.IsNullOrEmpty(_appVersion)) _appVersion = AppVersion();
            string label = string.IsNullOrEmpty(name) ? App.Boot.Name : name;
            if (App.Boot.Role == "door_station" && !string.IsNullOrEmpty(App.Boot.Door))
            {
                string doorLabel = DoorLabel(App.Boot.Door);
                if (!string.IsNullOrEmpty(doorLabel)) label = doorLabel;
            }
            string line = Texts.T("version.line", label, _coreVersion, _appVersion);
            if (_batteryPct >= 0)
            {
                line += " · " + _batteryPct + "%";
                if (_batteryCharging) line += " ⚡";
            }
            NodeInfo.Text = line;
            VisitorVersionLine.Text = line;
            NodeInfo.ToolTip = _batteryCharging ? Texts.T("power.charging") : null;
        }

        private static string AppVersion()
        {
            try
            {
                Assembly assembly = Assembly.GetExecutingAssembly();
                Version version = assembly.GetName().Version;
                return version == null ? "0" :
                    version.Major + "." + version.Minor + "." + version.Build;
            }
            catch { return "0"; }
        }

        /// <summary>Renders this node's own /admin/ URL and its QR (spec 6, N-win).</summary>
        private void RefreshAdminLink()
        {
            string url = AdminLink.PrimaryUrl(App.Boot.HttpPort);
            _adminUrl = url;
            bool available = !string.IsNullOrEmpty(url);
            AdminUrlText.Text = available ? url : Texts.T("web_admin.none");
            if (!available)
            {
                _renderedAdminQr = "";
                AdminQrImage.Source = null;
                CallAdminQrImage.Source = null;
                CallAdminQrCard.Visibility = Visibility.Collapsed;
                return;
            }
            CallAdminQrCard.Visibility = Visibility.Visible;
            if (url == _renderedAdminQr && AdminQrImage.Source != null) return;
            BitmapSource qr = QrCodeImage.Render(url, 160);
            _renderedAdminQr = qr == null ? "" : url;
            AdminQrImage.Source = qr;
            CallAdminQrImage.Source = qr;
        }

        private void OnWebAdminClick(object sender, MouseButtonEventArgs e)
        {
            OpenWebAdmin();
        }

        /// <summary>
        /// The dashboard 管理 button and the door station's 7-tap corner both land here, always
        /// behind the admin password.
        /// </summary>
        private void OnAdminEntryClick(object sender, RoutedEventArgs e)
        {
            var prompt = new AdminDialog { Owner = this };
            if (prompt.ShowDialog() != true) return;
            OpenWebAdmin();
        }

        private void OpenWebAdmin()
        {
            var window = new WebAdminWindow(App.Boot.HttpPort) { Owner = this, Topmost = Topmost };
            window.ShowDialog();
        }

        private bool LoadVideoStatsPreference()
        {
            try { return !File.Exists(Path.Combine(App.DataDir, "video-stats-hidden.flag")); }
            catch { return true; }
        }

        private void SaveVideoStatsPreference()
        {
            try
            {
                string path = Path.Combine(App.DataDir, "video-stats-hidden.flag");
                if (_showVideoStats) File.Delete(path);
                else File.WriteAllText(path, "1");
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
