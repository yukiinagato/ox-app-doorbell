using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using DoorbellApp.Core;

namespace DoorbellApp.Util
{
    internal sealed class SemanticStyle
    {
        public double? Scale, FontScale, Radius;
        public string Foreground, Background, Accent, Border;

        public Dictionary<string, object> ToDictionary()
        {
            var result = new Dictionary<string, object>();
            if (Scale.HasValue) result["scale"] = Scale.Value;
            if (FontScale.HasValue) result["font_scale"] = FontScale.Value;
            if (Radius.HasValue) result["radius"] = Radius.Value;
            if (Foreground != null) result["foreground"] = Foreground;
            if (Background != null) result["background"] = Background;
            if (Accent != null) result["accent"] = Accent;
            if (Border != null) result["border"] = Border;
            return result;
        }
    }

    /// <summary>Validated per-device semantic styles with an atomic last-known-good cache.</summary>
    internal sealed class SemanticUiOverrides
    {
        private static readonly HashSet<string> Allowed = new HashSet<string>(StringComparer.Ordinal)
        { "scale", "font_scale", "foreground", "background", "accent", "border", "radius" };
        private readonly Dictionary<string, SemanticStyle> _styles;
        public Dictionary<string, object> RuntimeReport { get; private set; }

        private SemanticUiOverrides(Dictionary<string, SemanticStyle> styles,
                                    Dictionary<string, object> report)
        {
            _styles = styles;
            RuntimeReport = report;
        }

        public SemanticStyle Get(string id)
        {
            SemanticStyle value;
            return id != null && _styles.TryGetValue(id, out value) ? value : null;
        }

        public static SemanticUiOverrides Load(Dictionary<string, object> config, string deviceId,
                                               string dataDirectory)
        {
            string path = Path.Combine(dataDirectory, "ui-overrides.lkg.json");
            var lastGood = ReadLkg(path, deviceId);
            var result = new Dictionary<string, SemanticStyle>(StringComparer.Ordinal);
            var outcomes = new Dictionary<string, Dictionary<string, object>>(StringComparer.Ordinal);
            if (config == null)
            {
                foreach (var pair in lastGood)
                {
                    result[pair.Key] = pair.Value;
                    outcomes[pair.Key] = Outcome("last_known_good", true, false, true,
                                                 "config_unavailable");
                }
                return new SemanticUiOverrides(result, BuildReport(outcomes));
            }
            object raw = string.IsNullOrEmpty(deviceId) ? null :
                CoreClient.Dig(config, "devices." + deviceId + ".local.ui.elements");
            var elements = raw as Dictionary<string, object>;
            if (elements != null)
            {
                foreach (var pair in elements)
                {
                    SemanticStyle style;
                    if (TryParse(pair.Key, pair.Value as Dictionary<string, object>, out style))
                    {
                        result[pair.Key] = style;
                        outcomes[pair.Key] = Outcome("override", true, false, false, "");
                    }
                    else if (lastGood.TryGetValue(pair.Key, out style))
                    {
                        result[pair.Key] = style;
                        outcomes[pair.Key] = Outcome("last_known_good", true, true, false,
                                                     "invalid_override");
                    }
                    else
                    {
                        outcomes[pair.Key] = Outcome("default", false, true, false,
                                                     "invalid_override");
                    }
                }
            }
            // Missing current values mean "default", not a stale override. Persist the complete
            // present-and-valid set (including recovered entries and the empty set), so deleting an
            // override cannot reappear during a later transient config read.
            string writeError;
            bool persisted = WriteLkg(path, deviceId, result, out writeError);
            foreach (var pair in result)
            {
                Dictionary<string, object> outcome;
                if (!outcomes.TryGetValue(pair.Key, out outcome)) continue;
                outcome["lkg_persisted"] = persisted;
                if (!persisted && string.IsNullOrEmpty(outcome["error"].ToString()))
                    outcome["error"] = writeError;
            }
            return new SemanticUiOverrides(result, BuildReport(outcomes));
        }

        private static bool TryParse(string semanticId, Dictionary<string, object> source,
                                     out SemanticStyle result)
        {
            result = null;
            if (source == null) return false;
            foreach (string key in source.Keys) if (!Allowed.Contains(key)) return false;
            var style = new SemanticStyle();
            foreach (var pair in source)
            {
                double number;
                switch (pair.Key)
                {
                    case "scale":
                        if (!Number(pair.Value, 0.75, 2.0, out number)) return false;
                        style.Scale = number; break;
                    case "font_scale":
                        if (!Number(pair.Value, 0.75, 2.0, out number)) return false;
                        style.FontScale = number; break;
                    case "radius":
                        if (!Number(pair.Value, 0, 64, out number)) return false;
                        style.Radius = number; break;
                    case "foreground": if (!ColorValue(pair.Value, out style.Foreground)) return false; break;
                    case "background": if (!ColorValue(pair.Value, out style.Background)) return false; break;
                    case "accent": if (!ColorValue(pair.Value, out style.Accent)) return false; break;
                    case "border": if (!ColorValue(pair.Value, out style.Border)) return false; break;
                }
            }
            bool safetyCritical = IsSafetyCritical(semanticId);
            if (safetyCritical &&
                ((style.Scale.HasValue && style.Scale.Value < 1.0) ||
                 (style.FontScale.HasValue && style.FontScale.Value < 1.0))) return false;
            var baseline = RuntimeContracts.UiDefaults(semanticId);
            string foreground = style.Foreground ?? baseline["foreground"].ToString();
            string background = style.Background ?? baseline["background"].ToString();
            string accent = style.Accent ?? baseline["accent"].ToString();
            string border = style.Border ?? baseline["border"].ToString();
            if ((style.Foreground != null || style.Background != null) &&
                !SemanticColorSafety.HasContrast(foreground, background, 4.5))
                return false;
            if ((style.Accent != null || style.Background != null) &&
                !SemanticColorSafety.HasContrast(accent, background, 3.0))
                return false;
            if ((style.Border != null || style.Background != null) &&
                !SemanticColorSafety.HasContrast(border, background, 3.0))
                return false;
            result = style;
            return true;
        }

        private static bool IsSafetyCritical(string semanticId)
        {
            return semanticId == "cancel.call" || semanticId == "call.end" ||
                   semanticId == "sos.trigger" || semanticId == "sos.cancel" ||
                   semanticId == "maintenance.exit";
        }

        private static bool Number(object value, double minimum, double maximum, out double result)
        {
            result = 0;
            if (value == null || !double.TryParse(value.ToString(),
                System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out result)) return false;
            return !double.IsNaN(result) && !double.IsInfinity(result) &&
                   result >= minimum && result <= maximum;
        }

        private static bool ColorValue(object value, out string result)
        {
            result = value == null ? null : value.ToString();
            if (string.IsNullOrEmpty(result) || result.Length != 7 || result[0] != '#')
                return false;
            for (int i = 1; i < result.Length; ++i)
                if (!Uri.IsHexDigit(result[i])) return false;
            return true;
        }

        private static Dictionary<string, SemanticStyle> ReadLkg(string path, string deviceId)
        {
            var result = new Dictionary<string, SemanticStyle>(StringComparer.Ordinal);
            try
            {
                if (!File.Exists(path)) return result;
                var root = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(
                    File.ReadAllText(path, Encoding.UTF8));
                object storedDevice, rawElements;
                if (root == null || !root.TryGetValue("device_id", out storedDevice) ||
                    !string.Equals(storedDevice == null ? "" : storedDevice.ToString(), deviceId,
                                   StringComparison.Ordinal) ||
                    !root.TryGetValue("elements", out rawElements)) return result;
                var elements = rawElements as Dictionary<string, object>;
                if (elements == null) return result;
                foreach (var pair in elements)
                {
                    SemanticStyle style;
                    if (TryParse(pair.Key, pair.Value as Dictionary<string, object>, out style))
                        result[pair.Key] = style;
                }
            }
            catch { }
            return result;
        }

        private static bool WriteLkg(string path, string deviceId,
                                     Dictionary<string, SemanticStyle> styles,
                                     out string error)
        {
            string temporary = path + ".tmp";
            error = "";
            try
            {
                var elements = new Dictionary<string, object>();
                foreach (var pair in styles) elements[pair.Key] = pair.Value.ToDictionary();
                var root = new Dictionary<string, object>
                {
                    { "schema_version", 1 }, { "device_id", deviceId }, { "elements", elements },
                };
                byte[] bytes = Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(root));
                using (var output = new FileStream(temporary, FileMode.Create, FileAccess.Write,
                                                   FileShare.None, 4096, FileOptions.WriteThrough))
                {
                    output.Write(bytes, 0, bytes.Length);
                    output.Flush(true);
                }
                if (File.Exists(path)) File.Replace(temporary, path, null, true);
                else File.Move(temporary, path);
                return true;
            }
            catch
            {
                error = "last_known_good_persist_failed";
                try { File.Delete(temporary); } catch { }
                return false;
            }
        }

        private static Dictionary<string, object> Outcome(string source, bool applied,
                                                          bool rejected, bool persisted,
                                                          string error)
        {
            return new Dictionary<string, object>
            {
                { "source", source }, { "applied", applied }, { "rejected", rejected },
                { "lkg_persisted", persisted }, { "error", error ?? "" },
            };
        }

        private static Dictionary<string, object> BuildReport(
            Dictionary<string, Dictionary<string, object>> outcomes)
        {
            var applied = new List<string>();
            var rejected = new List<Dictionary<string, object>>();
            var used = new List<string>();
            var persisted = new List<string>();
            string lastError = "";
            var keys = new List<string>(outcomes.Keys);
            keys.Sort(StringComparer.Ordinal);
            foreach (string id in keys)
            {
                Dictionary<string, object> outcome = outcomes[id];
                if ((bool)outcome["applied"]) applied.Add(id);
                if ((bool)outcome["rejected"])
                {
                    string reason = outcome["error"].ToString();
                    rejected.Add(new Dictionary<string, object>
                    { { "semantic_id", id }, { "reason", reason } });
                    lastError = id + ":" + reason;
                }
                if (outcome["source"].ToString() == "last_known_good") used.Add(id);
                if ((bool)outcome["lkg_persisted"]) persisted.Add(id);
                if (lastError.Length == 0 && outcome["error"].ToString().Length > 0)
                    lastError = id + ":" + outcome["error"];
            }
            return new Dictionary<string, object>
            {
                { "schema_version", 1 }, { "applied", applied }, { "rejected", rejected },
                { "last_known_good", new Dictionary<string, object>
                    { { "used", used }, { "persisted", persisted } } },
                { "last_error", lastError },
                { "updated_at_ms", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() },
                { "elements", outcomes },
            };
        }
    }

    internal static class SemanticColorSafety
    {
        public static bool HasContrast(string foreground, string background, double minimum)
        {
            Color fg, bg;
            return TryColor(foreground, out fg) && TryColor(background, out bg) &&
                   Contrast(fg, bg) >= minimum;
        }

        public static bool HasContrast(Brush foreground, Brush background, double minimum)
        {
            var fg = foreground as SolidColorBrush;
            var bg = background as SolidColorBrush;
            return fg != null && bg != null && fg.Color.A == 255 && bg.Color.A == 255 &&
                   Contrast(fg.Color, bg.Color) >= minimum;
        }

        private static bool TryColor(string value, out Color color)
        {
            color = new Color();
            try
            {
                object parsed = ColorConverter.ConvertFromString(value);
                if (!(parsed is Color)) return false;
                color = (Color)parsed;
                return color.A == 255;
            }
            catch { return false; }
        }

        private static double Contrast(Color first, Color second)
        {
            double a = Luminance(first), b = Luminance(second);
            return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05);
        }

        private static double Luminance(Color color)
        {
            return 0.2126 * Linear(color.R) + 0.7152 * Linear(color.G) +
                   0.0722 * Linear(color.B);
        }

        private static double Linear(byte value)
        {
            double channel = value / 255.0;
            return channel <= 0.04045 ? channel / 12.92 :
                Math.Pow((channel + 0.055) / 1.055, 2.4);
        }
    }

    internal sealed class SemanticUiApplier
    {
        private sealed class Baseline
        {
            public double MinWidth, MinHeight, FontSize;
            public Brush Foreground, Background, Border;
            public ControlTemplate Template;
            public Brush ElementBackground, ElementBorder;
            public CornerRadius ElementRadius;
        }
        private readonly Dictionary<FrameworkElement, Baseline> _baselines =
            new Dictionary<FrameworkElement, Baseline>();

        public void Apply(FrameworkElement element, SemanticStyle style, bool safetyCritical)
        {
            if (element == null) return;
            Baseline baseline;
            if (!_baselines.TryGetValue(element, out baseline))
            {
                var control = element as Control;
                var elementBorder = element as Border;
                baseline = new Baseline
                {
                    MinWidth = element.MinWidth,
                    MinHeight = element.MinHeight,
                    FontSize = control == null ? 0 : control.FontSize,
                    Foreground = control == null ? null : control.Foreground,
                    Background = control == null ? null : control.Background,
                    Border = control == null ? null : control.BorderBrush,
                    Template = control == null ? null : control.Template,
                    ElementBackground = elementBorder == null ? null : elementBorder.Background,
                    ElementBorder = elementBorder == null ? null : elementBorder.BorderBrush,
                    ElementRadius = elementBorder == null ? new CornerRadius() : elementBorder.CornerRadius,
                };
                _baselines[element] = baseline;
            }
            var c = element as Control;
            double scale = style != null && style.Scale.HasValue ? style.Scale.Value : 1.0;
            element.LayoutTransform = scale != 1.0
                ? new ScaleTransform(scale, scale) : Transform.Identity;
            // LayoutTransform also scales the hit-test box. Every Control, plus a safety-critical
            // wrapper, needs pre-transform compensation when scale is below one.
            bool requiresHitTarget = c != null || safetyCritical;
            double minimumHitTarget = requiresHitTarget ? (scale < 1.0 ? 44 / scale : 44) : 0;
            element.MinWidth = Math.Max(baseline.MinWidth, minimumHitTarget);
            element.MinHeight = Math.Max(baseline.MinHeight, minimumHitTarget);
            if (c != null)
            {
                c.FontSize = baseline.FontSize * (style != null && style.FontScale.HasValue ?
                                                  style.FontScale.Value : 1.0);
                Brush foreground = Brush(style == null ? null : style.Foreground) ??
                                   baseline.Foreground;
                Brush background = Brush(style == null ? null : style.Background) ??
                                   baseline.Background;
                bool changedTextColors = style != null &&
                    (style.Foreground != null || style.Background != null);
                if (changedTextColors &&
                    !SemanticColorSafety.HasContrast(foreground, background, 4.5))
                {
                    foreground = baseline.Foreground;
                    background = baseline.Background;
                }
                Brush outline = Brush(style == null ? null : (style.Border ?? style.Accent));
                if (outline != null &&
                    !SemanticColorSafety.HasContrast(outline, background, 3.0))
                    outline = null;
                c.Foreground = foreground;
                c.Background = background;
                c.BorderBrush = outline ?? baseline.Border;
                c.Template = style != null && style.Radius.HasValue ?
                    RoundedTemplate(style.Radius.Value) : baseline.Template;
            }
            var border = element as Border;
            if (border != null)
            {
                Brush background = Brush(style == null ? null : style.Background);
                Brush effectiveBackground = background ?? baseline.ElementBackground;
                Brush outline = Brush(style == null ? null : (style.Border ?? style.Accent));
                if (outline != null &&
                    !SemanticColorSafety.HasContrast(outline, effectiveBackground, 3.0))
                    outline = null;
                border.Background = background ?? baseline.ElementBackground;
                border.BorderBrush = outline ?? baseline.ElementBorder;
                border.CornerRadius = style != null && style.Radius.HasValue
                    ? new CornerRadius(style.Radius.Value) : baseline.ElementRadius;
            }
        }

        private static Brush Brush(string value)
        {
            if (string.IsNullOrEmpty(value)) return null;
            try
            {
                var color = (Color)ColorConverter.ConvertFromString(value);
                if (color.A != 255) return null;
                var brush = new SolidColorBrush(color); brush.Freeze(); return brush;
            }
            catch { return null; }
        }

        private static ControlTemplate RoundedTemplate(double radius)
        {
            var border = new FrameworkElementFactory(typeof(Border));
            border.SetValue(Border.CornerRadiusProperty, new CornerRadius(radius));
            border.SetBinding(Border.BackgroundProperty, new Binding("Background")
                { RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent) });
            border.SetBinding(Border.BorderBrushProperty, new Binding("BorderBrush")
                { RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent) });
            border.SetBinding(Border.BorderThicknessProperty, new Binding("BorderThickness")
                { RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent) });
            border.SetBinding(Border.PaddingProperty, new Binding("Padding")
                { RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent) });
            var content = new FrameworkElementFactory(typeof(ContentPresenter));
            content.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
            content.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
            border.AppendChild(content);
            return new ControlTemplate(typeof(Control)) { VisualTree = border };
        }
    }
}
