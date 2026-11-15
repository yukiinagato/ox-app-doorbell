using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using DoorbellApp.Util;

namespace DoorbellApp
{
    /// <summary>
    /// The PM2.5 indicator on both home screens. This shell only displays the reading that core
    /// resolves for this device (db_core_air_quality_json); it never hosts a Bluetooth sensor.
    /// </summary>
    public partial class MainWindow
    {
        private readonly DispatcherTimer _airQualityTimer = new DispatcherTimer();
        private Dictionary<string, object> _airQuality;

        // US EPA AQI category colours, matching core's six PM2.5 bands.
        private static readonly Dictionary<string, Brush> AirLevelBrushes =
            new Dictionary<string, Brush>
            {
                { "good", Frozen(new SolidColorBrush(Color.FromRgb(0x00, 0xE4, 0x00))) },
                { "moderate", Frozen(new SolidColorBrush(Color.FromRgb(0xFF, 0xFF, 0x00))) },
                { "sensitive", Frozen(new SolidColorBrush(Color.FromRgb(0xFF, 0x7E, 0x00))) },
                { "unhealthy", Frozen(new SolidColorBrush(Color.FromRgb(0xFF, 0x00, 0x00))) },
                { "very_unhealthy", Frozen(new SolidColorBrush(Color.FromRgb(0x8F, 0x3F, 0x97))) },
                { "hazardous", Frozen(new SolidColorBrush(Color.FromRgb(0x7E, 0x00, 0x23))) },
            };

        private const double AirStaleOpacity = 0.55;

        /// <summary>
        /// air_quality_changed covers every change except the reading's age, so the document is
        /// also re-read once a minute while the home screen is showing.
        /// </summary>
        private void StartAirQualityTimer()
        {
            _airQualityTimer.Interval = TimeSpan.FromMinutes(1);
            _airQualityTimer.Tick += (s, e) =>
            {
                if (IdleView.Visibility != Visibility.Visible) return;
                if (_airQuality != null && DictStr(_airQuality, "state") == "hidden") return;
                RequestHomeRefresh(HomeRefresh.AirQuality);
            };
            _airQualityTimer.Start();
        }

        /// <summary>A failed read keeps the last document rather than blanking the indicator.</summary>
        private void RefreshAirQuality(Dictionary<string, object> doc)
        {
            if (doc != null) _airQuality = doc;
            RenderAirQuality();
        }

        private void RenderAirQuality()
        {
            var doc = _airQuality;
            string state = DictStr(doc, "state");
            bool visible = doc != null && DictBool(doc, "show") && state.Length != 0 &&
                           state != "hidden";
            bool hasValue = visible && (state == "ok" || state == "stale") &&
                            doc.ContainsKey("pm25");

            string text = "";
            string spoken = "";
            Brush dot = null;
            if (hasValue)
            {
                string value = FormatPm25(DictDouble(doc, "pm25", 0));
                string level = DictStr(doc, "level");
                string status = state == "stale" ? Texts.T("air.stale") : AirLevelText(level);
                text = Texts.T("air.pm25_label") + "  " + value + " " + Texts.T("air.unit") +
                       (status.Length == 0 ? "" : "  " + status);
                spoken = Texts.T("air.a11y", value, status);
                AirLevelBrushes.TryGetValue(level, out dot);
            }
            else if (visible)
            {
                string placeholder = Texts.T(state == "unconfigured" ? "air.unconfigured"
                                                                      : "air.waiting");
                text = Texts.T("air.pm25_label") + "  " + placeholder;
                spoken = Texts.T("air.a11y_no_value", placeholder);
            }

            double opacity = state == "stale" ? AirStaleOpacity : 1.0;
            bool changed = ApplyAirIndicator(VisitorAirQuality, VisitorAirDot, VisitorAirText,
                                             visible, text, spoken, dot, opacity);
            changed |= ApplyAirIndicator(DashAirQuality, DashAirDot, DashAirText,
                                         visible, text, spoken, dot, opacity);
            // Ink is sampled from the pixels under an element, so a newly shown line needs a pass.
            if (changed) QueueInkPass();
        }

        private static bool ApplyAirIndicator(FrameworkElement row, Ellipse dot, TextBlock label,
                                              bool visible, string text, string spoken,
                                              Brush fill, double opacity)
        {
            var visibility = visible ? Visibility.Visible : Visibility.Collapsed;
            bool changed = row.Visibility != visibility;
            row.Visibility = visibility;
            row.Opacity = opacity;
            label.Text = text;
            AutomationProperties.SetName(label, spoken);
            dot.Fill = fill;
            dot.Visibility = fill == null ? Visibility.Collapsed : Visibility.Visible;
            return changed;
        }

        private static string AirLevelText(string level)
        {
            switch (level)
            {
                case "good": return Texts.T("air.level_good");
                case "moderate": return Texts.T("air.level_moderate");
                case "sensitive": return Texts.T("air.level_sensitive");
                case "unhealthy": return Texts.T("air.level_unhealthy");
                case "very_unhealthy": return Texts.T("air.level_very_unhealthy");
                case "hazardous": return Texts.T("air.level_hazardous");
                default: return "";
            }
        }

        private static string FormatPm25(double value)
        {
            return value == Math.Floor(value)
                ? value.ToString("0", CultureInfo.InvariantCulture)
                : value.ToString("0.#", CultureInfo.InvariantCulture);
        }
    }
}
