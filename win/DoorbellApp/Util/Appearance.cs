using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using DoorbellApp.Core;
using Microsoft.Win32;

namespace DoorbellApp.Util
{
    /// <summary>
    /// Resolves <c>display.appearance</c> into light or dark and hands it to ModernWpf's
    /// <c>ThemeManager</c>, which repaints every Fluent control. Core's accent becomes the Fluent
    /// accent. The shell's own brush tokens are then re-pointed: the neutral ones at the matching
    /// ModernWpf theme brushes, the semantic roles at their fixed light or dark values. Every XAML
    /// consumer binds with DynamicResource, so a swap repaints the whole shell. Windows 7/8 have
    /// no system light/dark setting; there <c>auto_system</c> is read as <c>auto_schedule</c>,
    /// exactly like the iOS 5 kiosk.
    /// </summary>
    internal static class Appearance
    {
        public const string Light = "light";
        public const string Dark = "dark";

        /// <summary>
        /// Neutral tokens and the ModernWpf theme brush each one aliases. The colour beside it
        /// (light, dark) is used only if the theme dictionary does not answer.
        /// </summary>
        private static readonly string[,] ThemeBrushes =
        {
            { "Bg", "ApplicationPageBackgroundThemeBrush", "#FFFFFF", "#000000" },
            { "Card", "SystemControlBackgroundChromeMediumLowBrush", "#F2F2F2", "#2B2B2B" },
            { "Fg", "SystemControlForegroundBaseHighBrush", "#000000", "#FFFFFF" },
            { "Line", "SystemControlForegroundBaseLowBrush", "#33000000", "#33FFFFFF" },
            { "Accent", "SystemControlBackgroundAccentBrush", "#0063B1", "#0078D4" },
        };

        /// <summary>
        /// Semantic color roles (ui-guidelines section 3) as aliases of the tokens that Core's
        /// effective appearance selects. Screens bind the role, never a literal color.
        /// </summary>
        internal static readonly string[,] RoleAliases =
        {
            { "Surface", "Card" }, { "OnSurface", "Fg" }, { "Negative", "Danger" },
            { "OnNegative", "OnDanger" }, { "Warning", "Warn" }, { "Muted", "Dim" },
        };

        // Fixed role colours. They are not part of the Fluent theme: positive and negative mean
        // the same thing on every platform, whatever the accent is. Two kinds live here:
        //   fills    Positive, Danger (= Negative), Notice: drawn under their white "On" ink,
        //            which must reach 4.5:1 on them;
        //   text     NegativeText, Warn (= Warning), Ok, Dim: drawn as text or as an outline on
        //            the page or a card, where they must reach 4.5:1 themselves. Negative has
        //            both, because the red that carries white text is too dark to read on a
        //            dark card. Dim (secondary text) is fixed here and opaque: the theme's own
        //            medium ink measured 3:1 on a light card on a real screen.
        // win/tests/test_windows_contracts.py computes every one of these ratios.
        private static readonly Dictionary<string, string> DarkRoles =
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                { "Warn", "#FFB454" }, { "Danger", "#C0392B" }, { "Ok", "#5DD39E" },
                { "Notice", "#8A5A00" }, { "OnDanger", "#FFFFFF" }, { "Track", "#802A21" },
                { "Positive", "#107C10" }, { "OnPositive", "#FFFFFF" },
                { "NegativeText", "#FF99A4" }, { "Dim", "#C8C8C8" },
            };

        private static readonly Dictionary<string, string> LightRoles =
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                { "Warn", "#8A5A00" }, { "Danger", "#B3261E" }, { "Ok", "#0F7B0F" },
                { "Notice", "#8A5A00" }, { "OnDanger", "#FFFFFF" }, { "Track", "#E4C9C6" },
                { "Positive", "#1E7F55" }, { "OnPositive", "#FFFFFF" },
                { "NegativeText", "#C42B1C" }, { "Dim", "#5E5E5E" },
            };

        private static DateTime _systemProbedAt = DateTime.MinValue;
        private static int _systemAppsUseLightTheme = -1;
        private static bool _applied;

        /// <summary>
        /// A fixed appearance for automated screenshots; null (always, outside UI test mode)
        /// follows Core. Only MainWindow.UiTest.cs sets it.
        /// </summary>
        internal static string TestOverride;
        private static Color? _accent;

        /// <summary>The appearance in force right now, "light" or "dark".</summary>
        public static string Current { get; private set; } = Dark;

        /// <summary>Configured mode before automatic resolution, for diagnostics.</summary>
        public static string ConfiguredMode { get; private set; } = "auto_system";

        /// <summary>The colour a token resolves to in the current appearance.</summary>
        public static Color Token(string key)
        {
            var resources = Application.Current == null ? null : Application.Current.Resources;
            var brush = resources == null || !resources.Contains(key)
                ? null : resources[key] as SolidColorBrush;
            if (brush != null) return brush.Color;
            for (int i = 0; i < ThemeBrushes.GetLength(0); i++)
                if (ThemeBrushes[i, 0] == key)
                    return Parse(ThemeBrushes[i, Current == Light ? 2 : 3]);
            var roles = Current == Light ? LightRoles : DarkRoles;
            string value;
            return Parse(roles.TryGetValue(key, out value) ? value : "#000000");
        }

        /// <summary>
        /// The appearance before Core is running (first-run setup): the system setting where
        /// Windows has one, dark otherwise.
        /// </summary>
        public static void ApplySystemDefault()
        {
            Current = SystemAppsUseLightTheme() == 1 ? Light : Dark;
            ApplyTheme(null);
        }

        /// <summary>
        /// Recomputes the effective appearance and accent and, when either changed, switches the
        /// Fluent theme and re-points the tokens.
        /// <paramref name="localTime"/> is the core clock document so the schedule is evaluated in
        /// the cluster time zone; null falls back to this machine's local time.
        /// </summary>
        public static bool Apply(Dictionary<string, object> config, string nodeId,
                                 Dictionary<string, object> localTime,
                                 Dictionary<string, object> display)
        {
            string effective = FromDisplayContract(display);
            if (effective == null)
            {
                // Older core: resolve display.appearance locally from configuration.
                ConfiguredMode = Resolve(config, nodeId);
                effective = Effective(ConfiguredMode, config, localTime);
            }
            if (TestOverride == Light || TestOverride == Dark) effective = TestOverride;
            Color? accent = HouseholdAccent(config, nodeId, display, effective == Light);
            if (_applied && effective == Current && accent == _accent) return false;
            Current = effective;
            ApplyTheme(accent);
            return true;
        }

        /// <summary>
        /// The accent Fluent controls take. Core's automatic accent is not used: only a
        /// call-button colour an administrator set (this device's, then the cluster's) that
        /// differs from the automatic one and stands out from the page. Null means the Windows
        /// accent, which ModernWpf falls back to by itself. The door-station Call button is
        /// painted separately from Core's call-button colours (ThemeContrast.CallButton).
        /// </summary>
        private static Color? HouseholdAccent(Dictionary<string, object> config, string nodeId,
                                              Dictionary<string, object> display, bool light)
        {
            object chosen = null;
            if (!string.IsNullOrEmpty(nodeId))
                chosen = CoreClient.Dig(config, "devices." + nodeId + ".local.theme.call_button_bg");
            if (chosen == null) chosen = CoreClient.Dig(config, "display.theme.call_button_bg");
            Color parsed;
            if (chosen == null || !ThemeContrast.TryParse(chosen.ToString(), out parsed)) return null;
            int? automatic = null;
            object auto = CoreClient.Dig(display, "theme.auto_accent.call_button");
            Color computed;
            if (auto != null && ThemeContrast.TryParse(auto.ToString(), out computed))
                automatic = RoleContrast.Rgb(computed.R, computed.G, computed.B);
            Color page = Parse(ThemeBrushes[0, light ? 2 : 3]);
            int? accent = RoleContrast.ChooseAccent(
                RoleContrast.Rgb(parsed.R, parsed.G, parsed.B), automatic,
                RoleContrast.Rgb(page.R, page.G, page.B));
            return accent.HasValue ? (Color?)parsed : null;
        }

        /// <summary>Raised after the theme or accent changed and the tokens were re-pointed.</summary>
        public static event Action Changed;

        private static void ApplyTheme(Color? accent)
        {
            _applied = true;
            _accent = accent;
            bool light = Current == Light;
            var resources = Application.Current == null ? null : Application.Current.Resources;
            if (resources == null) return;
            try
            {
                ModernWpf.ThemeManager.Current.ApplicationTheme = light
                    ? ModernWpf.ApplicationTheme.Light : ModernWpf.ApplicationTheme.Dark;
                ModernWpf.ThemeManager.Current.AccentColor = accent;
            }
            catch (Exception ex)
            {
                // A theme that cannot switch must not take the doorbell down; the tokens below
                // still follow the appearance.
                System.Diagnostics.Debug.WriteLine("Fluent theme switch failed: " + ex.Message);
            }
            PointTokens(resources, light);
            // ThemeManager may finish swapping its dictionaries after this call returns; one
            // more pass once the dispatcher is idle picks up the final brushes.
            var dispatcher = Application.Current.Dispatcher;
            if (dispatcher != null)
                dispatcher.BeginInvoke(new Action(() =>
                {
                    var current = Application.Current == null ? null : Application.Current.Resources;
                    if (current != null) PointTokens(current, Current == Light);
                    var changed = Changed;
                    if (changed != null) changed();
                }), System.Windows.Threading.DispatcherPriority.Background);
        }

        private static void PointTokens(ResourceDictionary resources, bool light)
        {
            for (int i = 0; i < ThemeBrushes.GetLength(0); i++)
            {
                var themed = Application.Current.TryFindResource(ThemeBrushes[i, 1])
                    as SolidColorBrush;
                Set(resources, ThemeBrushes[i, 0],
                    themed != null ? themed.Color : Parse(ThemeBrushes[i, light ? 2 : 3]));
            }
            Color card = ((SolidColorBrush)resources["Card"]).Color;
            Color ink = ((SolidColorBrush)resources["Fg"]).Color;
            Color accent = ((SolidColorBrush)resources["Accent"]).Color;
            Set(resources, "OnAccent", ThemeContrast.BetterInk(accent));
            // The accent as text (a link, a code, a selected glyph): the same hue, moved until
            // it reads on the card, which is the least favourable surface it is drawn on.
            int readable = RoleContrast.EnsureReadable(
                RoleContrast.Rgb(accent.R, accent.G, accent.B),
                RoleContrast.Rgb(card.R, card.G, card.B), RoleContrast.TextMinimum);
            Set(resources, "AccentText", Color.FromRgb((byte)((readable >> 16) & 0xFF),
                (byte)((readable >> 8) & 0xFF), (byte)(readable & 0xFF)));
            // The card material over the wallpaper (Ui/Frost) and its tints, from the same theme.
            Set(resources, "Plate", Color.FromArgb(0xA6, card.R, card.G, card.B));
            Set(resources, "Pill", Color.FromArgb(0xCC, card.R, card.G, card.B));
            Set(resources, "PlateLine", Color.FromArgb(light ? (byte)0x1F : (byte)0x26,
                                                       ink.R, ink.G, ink.B));
            Set(resources, "Row", Color.FromArgb(0x14, ink.R, ink.G, ink.B));
            foreach (KeyValuePair<string, string> role in light ? LightRoles : DarkRoles)
                Set(resources, role.Key, Parse(role.Value));
            for (int i = 0; i < RoleAliases.GetLength(0); i++)
            {
                object source = resources[RoleAliases[i, 1]];
                if (source != null) resources[RoleAliases[i, 0]] = source;
            }
        }

        private static void Set(ResourceDictionary resources, string key, Color color)
        {
            var existing = resources.Contains(key) ? resources[key] as SolidColorBrush : null;
            if (existing != null && existing.Color == color) return;
            var brush = new SolidColorBrush(color);
            brush.Freeze();
            resources[key] = brush;
        }

        private static Color Parse(string value)
        {
            return (Color)ColorConverter.ConvertFromString(value);
        }

        /// <summary>
        /// Core resolves the schedule in the cluster time zone and publishes
        /// display.appearance = {configured, effective, follow_system, schedule}. follow_system
        /// tells the shell to prefer the operating system's own setting where one exists, which
        /// is why Windows 7 and 8 still land on core's scheduled answer.
        /// </summary>
        private static string FromDisplayContract(Dictionary<string, object> display)
        {
            var appearance = CoreClient.Dig(display, "appearance") as Dictionary<string, object>;
            if (appearance == null) return null;
            object configured;
            if (appearance.TryGetValue("configured", out configured) && configured != null)
                ConfiguredMode = configured.ToString();
            object followSystem;
            bool follow = appearance.TryGetValue("follow_system", out followSystem) &&
                          followSystem is bool && (bool)followSystem;
            if (follow)
            {
                int system = SystemAppsUseLightTheme();
                if (system == 1) return Light;
                if (system == 0) return Dark;
            }
            object effective;
            if (!appearance.TryGetValue("effective", out effective) || effective == null)
                return null;
            string value = effective.ToString();
            return value == Light || value == Dark ? value : null;
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
