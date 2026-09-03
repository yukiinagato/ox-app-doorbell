using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
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
        private const string RegionStatusLine = "status_line";
        private const string RegionTileLabel = "tile_label";
        private const string RegionNotice = "notice";
        // Just over 60 % black is where the picture still reads and the cards over it still do.
        // The same figure the kiosk compositor measures against.
        private const int DefaultBackdropOpacity = 62;

        private Color _backdropColour = Colors.Black;
        private double _backdropAlpha;

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

            LayOutSosAndFooters(width, portrait);
            // Sampling the background under an element needs its arranged bounds, so the ink pass
            // waits for the layout this call just requested.
            QueueInkPass();
        }

        private bool _inkPassQueued;

        /// <summary>Runs one coalesced ink pass once the pending layout has been arranged.</summary>
        private void QueueInkPass()
        {
            if (_inkPassQueued) return;
            _inkPassQueued = true;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                _inkPassQueued = false;
                ApplyAutoInk();
            }), DispatcherPriority.Loaded);
        }

        // The SOS slider floats over whichever home screen is showing, so the footers have to
        // reserve room for it explicitly. A real device found the version and battery line
        // running underneath it in the narrow layout; these are the numbers that stop it.
        private const double SosBarWidth = 238;
        private const double SosBarHeight = 62;
        private const double SosBarMargin = 20;
        private const double SosBarBottom = 16;
        private const double SosClearance = 12;
        private const double FooterMinimumWidth = 320;

        /// <summary>Width the footers must leave free when the slider sits beside them.</summary>
        internal static double SosReservedWidth
        {
            get { return SosBarWidth + SosBarMargin + SosClearance; }
        }

        /// <summary>Height the footers must leave free when the slider sits below them.</summary>
        internal static double SosReservedHeight
        {
            get { return SosBarHeight + SosBarBottom + SosClearance; }
        }

        /// <summary>
        /// Places the slider and reserves exactly the space it occupies, so the footer and the
        /// slider cannot overlap at any window size. Beside the footer there is room only when
        /// the footer still gets its minimum width; otherwise the slider becomes a full-width
        /// band and the footer reserves height above it instead.
        /// </summary>
        private void LayOutSosAndFooters(double width, bool portrait)
        {
            bool sosVisible = SosButton.Visibility == Visibility.Visible;
            bool sosBelow = sosVisible &&
                (portrait || width < SosReservedWidth + FooterMinimumWidth);

            SosButton.HorizontalAlignment = sosBelow ?
                HorizontalAlignment.Stretch : HorizontalAlignment.Right;
            SosButton.Width = sosBelow ? double.NaN : SosBarWidth;
            SosButton.Margin = sosBelow
                ? new Thickness(SosBarMargin, 0, SosBarMargin, SosBarBottom)
                : new Thickness(0, 0, SosBarMargin, SosBarBottom);

            double reserveWidth = sosVisible && !sosBelow ? SosReservedWidth : 0;
            double reserveHeight = sosBelow ? SosReservedHeight : 0;
            DashboardSosColumn.Width = new GridLength(reserveWidth);
            DashboardFooter.Margin = new Thickness(0, 0, 0, reserveHeight);
            VisitorFooter.Margin = new Thickness(0, 12, reserveWidth, reserveHeight);
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

        /// <summary>
        /// The darkening over the theme picture. Administrators set colour and opacity through
        /// display.theme.backdrop, per cluster or per device; core resolves the two and publishes
        /// the answer in the display contract. An absent key keeps the built-in scrim, and
        /// enabled false draws nothing at all. It only ever applies over a picture: painting a
        /// scrim over a flat theme colour would just be a different, darker colour than the one
        /// the administrator chose.
        /// </summary>
        private void ApplyThemeBackdrop()
        {
            bool picture = ThemeBgImage.Visibility == Visibility.Visible &&
                           ThemeBgImage.Source != null;
            bool enabled = true;
            Color colour = Colors.Black;
            int percent = DefaultBackdropOpacity;

            var backdrop = CoreClient.Dig(_display, "theme.backdrop")
                as Dictionary<string, object>;
            if (backdrop != null)
            {
                object flag;
                if (backdrop.TryGetValue("enabled", out flag) && flag is bool)
                    enabled = (bool)flag;
                Color parsed;
                if (ThemeContrast.TryParse(DictStr(backdrop, "color"), out parsed))
                    colour = parsed;
                percent = DictInt(backdrop, "opacity", DefaultBackdropOpacity);
                if (percent < 0) percent = 0;
                if (percent > 100) percent = 100;
            }

            bool draw = picture && enabled && percent > 0;
            _backdropColour = colour;
            _backdropAlpha = draw ? percent / 100.0 : 0;
            ThemeBackdrop.Visibility = draw ? Visibility.Visible : Visibility.Collapsed;
            ThemeBackdrop.Background = draw ? ThemeContrast.Brush(colour) : null;
            ThemeBackdrop.Opacity = _backdropAlpha;
        }

        /// <summary>
        /// What a colour behind the scrim actually looks like on screen. The ink decision has to
        /// see the darkened picture, not the bright original, or a wallpaper that reads as light
        /// would take dark ink over a scrim that made it dark.
        /// </summary>
        private BackgroundSample OverBackdrop(BackgroundSample sample)
        {
            if (_backdropAlpha <= 0) return sample;
            return new BackgroundSample
            {
                Average = OverBackdrop(sample.Average),
                // The extremes decide the outline, so they are darkened too. They are held as
                // luminances, so each is taken back to the grey that carries it, composited, and
                // measured again.
                DarkestLuminance = OverBackdropLuminance(sample.DarkestLuminance),
                LightestLuminance = OverBackdropLuminance(sample.LightestLuminance),
            };
        }

        private double OverBackdropLuminance(double luminance)
        {
            if (_backdropAlpha <= 0) return luminance;
            return ThemeContrast.Luminance(
                OverBackdrop(ThemeContrast.GreyOfLuminance(luminance)));
        }

        private Color OverBackdrop(Color under)
        {
            if (_backdropAlpha <= 0) return under;
            double a = _backdropAlpha;
            return Color.FromRgb(
                (byte)Math.Round(under.R * (1 - a) + _backdropColour.R * a),
                (byte)Math.Round(under.G * (1 - a) + _backdropColour.G * a),
                (byte)Math.Round(under.B * (1 - a) + _backdropColour.B * a));
        }

        /// <summary>Applies display.appearance and then the per-region automatic ink.</summary>
        private void ApplyAppearance()
        {
            Appearance.Apply(_cfg, _nodeId, ScheduleClock(), _display);
            ApplyAutoInk();
            QueueInkPass();
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

            // Every text region that is drawn straight onto a background, on all three screens.
            // Each is decided from the pixels under that element, not from the whole image.
            InkText(ClockText, RegionClock, 0);
            InkText(DashClock, RegionClock, 0);
            InkText(DateText, RegionDate, 0.35);
            InkText(DashDate, RegionDate, 0.35);
            InkText(TouchHint, RegionHint, 0.25);
            InkText(NodeInfo, RegionFooter, 0.35);
            InkText(VisitorVersionLine, RegionFooter, 0.35);
            InkText(VisitorNoticeText, RegionNotice, 0);
            InkText(ClusterCountText, RegionStatusLine, 0);
            InkText(DoorCountText, RegionStatusLine, 0);
            InkText(PanelCountText, RegionStatusLine, 0);
            InkText(RecentCallsTitle, RegionTileLabel, 0);
            // The call screens draw over their own opaque surface, so the same rule resolves
            // there against that surface rather than against the theme background.
            InkText(IncomingTitle, RegionStatusLine, 0);
            InkText(InCallTitle, RegionStatusLine, 0);
            InkText(IncomingHint, RegionHint, 0.25);
            InkText(IncomingNoVideo, RegionHint, 0.25);
            foreach (TextBlock label in _tileLabels) InkText(label, RegionTileLabel, 0);

            if (App.Boot.Role == "door_station")
            {
                Color fill = ThemeContrast.CallButton(_display, _cfg, _nodeId, background);
                CallButton.Background = ThemeContrast.Brush(fill);
                CallButton.Foreground =
                    ThemeContrast.Brush(ThemeContrast.CallButtonInk(_display, fill));
            }
        }

        /// <summary>
        /// Resolves one text element's ink against whatever is actually behind it, and adds the
        /// 40 % opposite-ink outline only when the chosen ink still misses 4.5:1. muted mixes the
        /// ink towards the background for secondary lines, after the decision is made.
        /// </summary>
        private void InkText(TextBlock element, string regionId, double muted)
        {
            if (element == null) return;
            bool decideLocally;
            BackgroundSample sample = BackgroundUnder(element, out decideLocally);
            // Core's published ink also has to be ignored when core says it never read the
            // configured background image: it then describes the flat theme colour, not the photo.
            decideLocally |= !ThemeContrast.CoreSampledBackground(_display);
            InkDecision decision =
                ThemeContrast.Decide(_display, regionId, sample, decideLocally);
            element.Foreground = ThemeContrast.Brush(
                muted > 0 ? MixTowards(decision.Ink, sample.Average, muted) : decision.Ink);
            element.Effect = decision.NeedsShadow ? OutlineFor(decision.Shadow) : null;
        }

        private static DropShadowEffect OutlineFor(Color shadow)
        {
            return new DropShadowEffect
            {
                Color = shadow,
                Opacity = 0.4,
                ShadowDepth = 1,
                BlurRadius = 2,
                Direction = 315,
            };
        }

        /// <summary>
        /// What is behind one element. An opaque ancestor surface — a card, a call screen —
        /// answers directly and uniformly; otherwise the theme background image is sampled under
        /// exactly this element's bounds, which is the refinement core cannot make without layout
        /// geometry, and the sample keeps its darkest and lightest patch so the outline can be
        /// judged against the whole region rather than its average.
        /// decideLocally is true in both of those cases, because core's published token describes
        /// only the theme background as a whole; it is false when that whole is what applies.
        /// </summary>
        private BackgroundSample BackgroundUnder(FrameworkElement element, out bool decideLocally)
        {
            decideLocally = false;
            for (DependencyObject node = element; node != null && node != this;
                 node = VisualTreeHelper.GetParent(node))
            {
                var opaque = SurfaceColour(node);
                if (opaque.HasValue)
                {
                    // Core never saw this surface, so its whole-image token cannot describe it.
                    decideLocally = true;
                    return BackgroundSample.Uniform(opaque.Value);
                }
            }

            var bitmap = ThemeBgImage.Source as BitmapSource;
            if (ThemeBgImage.Visibility == Visibility.Visible && bitmap != null)
            {
                try
                {
                    if (element.ActualWidth > 0 && element.ActualHeight > 0 && IsAncestorOf(element))
                    {
                        Point origin = element.TransformToAncestor(this).Transform(new Point(0, 0));
                        var bounds = new Rect(origin,
                            new Size(element.ActualWidth, element.ActualHeight));
                        Int32Rect crop = ThemeContrast.MapUniformToFill(bitmap,
                            new Size(ActualWidth, ActualHeight), bounds);
                        BackgroundSample region;
                        if (ThemeContrast.TrySampleRegion(bitmap, crop, out region))
                        {
                            decideLocally = true;
                            return OverBackdrop(region);   // the scrim is part of what is seen
                        }
                    }
                }
                catch (InvalidOperationException)
                {
                    // Not connected to this window's visual tree yet; the shared value applies.
                }
            }
            return BackgroundSample.Uniform(EffectiveBackground());
        }

        private static Color? SurfaceColour(DependencyObject node)
        {
            Brush brush = null;
            var control = node as Control;
            if (control != null) brush = control.Background;
            var panel = node as Panel;
            if (brush == null && panel != null) brush = panel.Background;
            var border = node as Border;
            if (brush == null && border != null) brush = border.Background;
            var solid = brush as SolidColorBrush;
            return solid != null && solid.Color.A == 255 ? (Color?)solid.Color : null;
        }

        private bool IsAncestorOf(DependencyObject node)
        {
            for (; node != null; node = VisualTreeHelper.GetParent(node))
                if (node == this) return true;
            return false;
        }

        /// <summary>The colour actually behind the idle screen, sampled from a theme image.</summary>
        private Color EffectiveBackground()
        {
            Color contract;
            // Core measured this once for the whole cluster, image averaging included.
            if (ThemeContrast.TryContractBackground(_display, out contract))
                return OverBackdrop(contract);
            Color average;
            var bitmap = ThemeBgImage.Source as BitmapSource;
            if (ThemeBgImage.Visibility == Visibility.Visible && bitmap != null &&
                ThemeContrast.TryAverage(bitmap, out average)) return OverBackdrop(average);
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
