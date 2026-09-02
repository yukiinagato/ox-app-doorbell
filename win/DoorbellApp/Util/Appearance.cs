using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using DoorbellApp.Core;
using Microsoft.Win32;

namespace DoorbellApp.Util
{
    /// <summary>
    /// Resolves <c>display.appearance</c> into the light or dark palette and swaps the application
    /// resource brushes. Every XAML consumer binds with DynamicResource, so a swap repaints the
    /// whole shell. Windows 7/8 have no system light/dark setting; there
    /// <c>auto_system</c> is read as <c>auto_schedule</c>, exactly like the iOS 5 kiosk.
    /// </summary>
    internal static class Appearance
    {
        public const string Light = "light";
        public const string Dark = "dark";

        private static readonly string[] TokenOrder =
        {
            "Bg", "Card", "Fg", "Dim", "Accent", "Warn", "Line", "Danger", "Ok", "Notice",
            "OnAccent", "OnDanger", "Track",
        };

        private static readonly Dictionary<string, string> DarkPalette =
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                { "Bg", "#101418" }, { "Card", "#1A2027" }, { "Fg", "#E8EDF2" },
                { "Dim", "#8A97A5" }, { "Accent", "#4DA3FF" }, { "Warn", "#FFB454" },
                { "Line", "#2A333D" }, { "Danger", "#C0392B" }, { "Ok", "#5DD39E" },
                { "Notice", "#B7791F" }, { "OnAccent", "#04121F" }, { "OnDanger", "#FFFFFF" },
                { "Track", "#802A21" },
            };

        private static readonly Dictionary<string, string> LightPalette =
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                { "Bg", "#F3F5F8" }, { "Card", "#FFFFFF" }, { "Fg", "#171B21" },
                { "Dim", "#56616D" }, { "Accent", "#1B62B8" }, { "Warn", "#8A5A00" },
                { "Line", "#D2DAE2" }, { "Danger", "#B3261E" }, { "Ok", "#1E7F55" },
                { "Notice", "#8A5A00" }, { "OnAccent", "#FFFFFF" }, { "OnDanger", "#FFFFFF" },
                { "Track", "#E4C9C6" },
            };

        private static DateTime _systemProbedAt = DateTime.MinValue;
        private static int _systemAppsUseLightTheme = -1;

        /// <summary>The appearance in force right now, "light" or "dark".</summary>
        public static string Current { get; private set; } = Dark;

        /// <summary>Configured mode before automatic resolution, for diagnostics.</summary>
        public static string ConfiguredMode { get; private set; } = "auto_system";

        public static Color Token(string key)
        {
            var palette = Current == Light ? LightPalette : DarkPalette;
            string value;
            if (!palette.TryGetValue(key, out value)) value = "#000000";
            return (Color)ColorConverter.ConvertFromString(value);
        }

        /// <summary>
        /// Recomputes the effective appearance and, when it changed, replaces the palette brushes.
        /// <paramref name="localTime"/> is the core clock document so the schedule is evaluated in
        /// the cluster time zone; null falls back to this machine's local time.
        /// </summary>
        public static bool Apply(Dictionary<string, object> config, string nodeId,
                                 Dictionary<string, object> localTime)
        {
            string configured = Resolve(config, nodeId);
            ConfiguredMode = configured;
            string effective = Effective(configured, config, localTime);
            if (effective == Current && Application.Current != null &&
                Application.Current.Resources.Contains("Line")) return false;
            Current = effective;
            var palette = effective == Light ? LightPalette : DarkPalette;
            var resources = Application.Current == null ? null : Application.Current.Resources;
            if (resources == null) return true;
            foreach (string key in TokenOrder)
            {
                string value;
                if (!palette.TryGetValue(key, out value)) continue;
                var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(value));
                brush.Freeze();
                resources[key] = brush;
            }
            return true;
        }

        private static string Resolve(Dictionary<string, object> config, string nodeId)
        {
            object value = null;
            if (!string.IsNullOrEmpty(nodeId))
                value = CoreClient.Dig(config,
                    "devices." + nodeId + ".local.display.appearance");
            if (value == null) value = CoreClient.Dig(config, "display.appearance");
            string mode = value == null ? "" : value.ToString();
            switch (mode)
            {
                case "light":
                case "dark":
                case "auto_schedule":
                case "auto_system":
                    return mode;
                default:
                    return "auto_system";
            }
        }

        private static string Effective(string mode, Dictionary<string, object> config,
                                        Dictionary<string, object> localTime)
        {
            if (mode == Light || mode == Dark) return mode;
            if (mode == "auto_system")
            {
                int system = SystemAppsUseLightTheme();
                if (system == 1) return Light;
                if (system == 0) return Dark;
                // No system setting on this Windows release: fall through to the schedule.
            }
            return ScheduleAppearance(config, localTime);
        }

        /// <summary>Returns 1 for light, 0 for dark, and -1 when Windows has no such setting.</summary>
        private static int SystemAppsUseLightTheme()
        {
            if ((DateTime.UtcNow - _systemProbedAt).TotalSeconds < 10)
                return _systemAppsUseLightTheme;
            _systemProbedAt = DateTime.UtcNow;
            _systemAppsUseLightTheme = -1;
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                {
                    if (key == null) return -1;
                    object raw = key.GetValue("AppsUseLightTheme");
                    if (raw == null) return -1;
                    int parsed;
                    if (!int.TryParse(raw.ToString(), out parsed)) return -1;
                    _systemAppsUseLightTheme = parsed == 0 ? 0 : 1;
                }
            }
            catch { _systemAppsUseLightTheme = -1; }
            return _systemAppsUseLightTheme;
        }

        private static string ScheduleAppearance(Dictionary<string, object> config,
                                                 Dictionary<string, object> localTime)
        {
            int darkFrom = Minutes(CoreClient.Dig(config, "display.appearance_schedule.dark_from"),
                                   19 * 60);
            int lightFrom = Minutes(CoreClient.Dig(config,
                                                   "display.appearance_schedule.light_from"),
                                    6 * 60 + 30);
            int now = NowMinutes(localTime);
            if (darkFrom == lightFrom) return Dark;
            bool dark = darkFrom < lightFrom
                ? now >= darkFrom && now < lightFrom
                : now >= darkFrom || now < lightFrom;
            return dark ? Dark : Light;
        }

        private static int NowMinutes(Dictionary<string, object> localTime)
        {
            if (localTime != null)
            {
                object hh, mm;
                int hour, minute;
                if (localTime.TryGetValue("hh", out hh) && hh != null &&
                    localTime.TryGetValue("mm", out mm) && mm != null &&
                    int.TryParse(hh.ToString(), out hour) &&
                    int.TryParse(mm.ToString(), out minute) &&
                    hour >= 0 && hour < 24 && minute >= 0 && minute < 60)
                    return hour * 60 + minute;
            }
            DateTime now = DateTime.Now;
            return now.Hour * 60 + now.Minute;
        }

        private static int Minutes(object value, int fallback)
        {
            string text = value == null ? "" : value.ToString();
            int colon = text.IndexOf(':');
            if (colon <= 0) return fallback;
            int hour, minute;
            if (!int.TryParse(text.Substring(0, colon), out hour) ||
                !int.TryParse(text.Substring(colon + 1), out minute) ||
                hour < 0 || hour > 23 || minute < 0 || minute > 59) return fallback;
            return hour * 60 + minute;
        }
    }
}
