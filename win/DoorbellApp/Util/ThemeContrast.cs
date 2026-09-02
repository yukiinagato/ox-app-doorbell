using System;
using System.Collections.Generic;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DoorbellApp.Core;

namespace DoorbellApp.Util
{
    /// <summary>One advisory record for a colour pair that misses its WCAG 2.1 target.</summary>
    internal sealed class ContrastAdvisory
    {
        public string Element;
        public double Ratio;
        public double Minimum;

        public Dictionary<string, object> ToDictionary()
        {
            return new Dictionary<string, object>
            {
                { "element", Element ?? "" },
                { "ratio", Math.Round(Ratio, 2) },
                { "minimum", Minimum },
            };
        }
    }

    /// <summary>
    /// Automatic text contrast and the computed call-button colour (spec 5 and 5.2). Core
    /// publishes <c>display.theme.auto_ink</c> and <c>display.theme.auto_accent</c> so every shell
    /// agrees; the local computation here is the fallback for a Core that predates those keys.
    /// Custom colours are never rejected: a colour that misses its target still applies and is
    /// reported as an advisory in the runtime UI-style status.
    /// </summary>
    internal static class ThemeContrast
    {
        public static readonly Color LightInk = Color.FromRgb(0xEE, 0xF2, 0xF5);
        public static readonly Color DarkInk = Color.FromRgb(0x17, 0x1B, 0x21);

        public static bool TryParse(string value, out Color color)
        {
            color = Colors.Black;
            if (string.IsNullOrEmpty(value)) return false;
            try
            {
                object parsed = ColorConverter.ConvertFromString(value);
                if (!(parsed is Color)) return false;
                color = (Color)parsed;
                return color.A == 255;
            }
            catch { return false; }
        }

        private static double Channel(byte value)
        {
            double v = value / 255.0;
            return v <= 0.04045 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4);
        }

        /// <summary>WCAG 2.x relative luminance of an opaque sRGB colour.</summary>
        public static double Luminance(Color color)
        {
            return 0.2126 * Channel(color.R) + 0.7152 * Channel(color.G) +
                   0.0722 * Channel(color.B);
        }

        public static double Ratio(Color first, Color second)
        {
            double a = Luminance(first), b = Luminance(second);
            return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05);
        }

        /// <summary>
        /// Average colour of an image, sampled at no more than 16x16 as the spec requires. Returns
        /// false when the source cannot be sampled, so the caller keeps the theme colour.
        /// </summary>
        public static bool TryAverage(BitmapSource source, out Color average)
        {
            average = Colors.Black;
            if (source == null) return false;
            try
            {
                var scaled = new TransformedBitmap(source,
                    new ScaleTransform(16.0 / Math.Max(1, source.PixelWidth),
                                       16.0 / Math.Max(1, source.PixelHeight)));
                var converted = new FormatConvertedBitmap(scaled, PixelFormats.Bgra32, null, 0);
                int width = Math.Max(1, converted.PixelWidth);
                int height = Math.Max(1, converted.PixelHeight);
                int stride = width * 4;
                var pixels = new byte[stride * height];
                converted.CopyPixels(pixels, stride, 0);
                long r = 0, g = 0, b = 0;
                int count = width * height;
                for (int i = 0; i < count; i++)
                {
                    b += pixels[i * 4];
                    g += pixels[i * 4 + 1];
                    r += pixels[i * 4 + 2];
                }
                if (count == 0) return false;
                average = Color.FromRgb((byte)(r / count), (byte)(g / count), (byte)(b / count));
                return true;
            }
            catch { return false; }
        }

        /// <summary>
        /// Ink for one semantic region. Precedence: per-device override, cluster override, the
        /// core-published automatic decision, then the local luminance rule.
        /// </summary>
        public static Color Ink(Dictionary<string, object> display, string regionId,
                                Color background)
        {
            Color parsed;
            // Core already folded the per-device and cluster overrides into theme.ink_override.
            object value = CoreClient.Dig(display, "theme.ink_override." + regionId);
            if (value != null && TryParse(value.ToString(), out parsed)) return parsed;

            object auto = CoreClient.Dig(display, "theme.auto_ink." + regionId);
            string token = auto == null ? "" : auto.ToString();
            if (token == "light") return LightInk;
            if (token == "dark") return DarkInk;
            // Older core, or a region it does not know: the same WCAG rule, computed locally.
            return Luminance(background) >= 0.5 ? DarkInk : LightInk;
        }

        /// <summary>
        /// The background core actually measured, image averaging included. Falls back to the
        /// caller's own sample when the contract has no auto_background.
        /// </summary>
        public static bool TryContractBackground(Dictionary<string, object> display,
                                                 out Color background)
        {
            background = Colors.Black;
            object value = CoreClient.Dig(display, "theme.auto_background.color");
            return value != null && TryParse(value.ToString(), out background);
        }

        /// <summary>
        /// True when the chosen ink needs the 40 % opposite-ink outline, that is when it does not
        /// reach the 4.5:1 body-text target against the sampled background.
        /// </summary>
        public static bool NeedsOutline(Color ink, Color background)
        {
            return Ratio(ink, background) < 4.5;
        }

        /// <summary>
        /// Door-station call-button colour. Precedence: per-device override, cluster override, the
        /// core-published automatic accent, then the local complement computation.
        /// </summary>
        public static Color CallButton(Dictionary<string, object> display, Color background)
        {
            Color parsed;
            // theme.call_button_bg is what core says to paint: the override when there is one,
            // otherwise the computed accent.
            object value = CoreClient.Dig(display, "theme.call_button_bg");
            if (value != null && TryParse(value.ToString(), out parsed)) return parsed;
            object auto = CoreClient.Dig(display, "theme.auto_accent.call_button");
            if (auto != null && TryParse(auto.ToString(), out parsed)) return parsed;
            return LocalAccent(background);
        }

        /// <summary>
        /// Always take the button text colour from call_button_ink: on a mid-luminance background
        /// core returns the best compromise rather than an unreadable button.
        /// </summary>
        public static Color CallButtonInk(Dictionary<string, object> display, Color fill)
        {
            object value = CoreClient.Dig(display, "theme.call_button_ink");
            if (value == null) value = CoreClient.Dig(display, "theme.auto_accent.call_button_ink");
            string token = value == null ? "" : value.ToString();
            if (token == "light") return Colors.White;
            if (token == "dark") return Colors.Black;
            return TextOn(fill);
        }

        /// <summary>
        /// Rotate the background hue by 180 degrees, then move lightness until the button reaches
        /// 3:1 against the background and its text reaches 4.5:1, preferring the darker direction
        /// on a light background (spec 5.2).
        /// </summary>
        public static Color LocalAccent(Color background)
        {
            double h, s, l;
            ToHsl(background, out h, out s, out l);
            h = (h + 180.0) % 360.0;
            if (s < 0.25) s = 0.55;
            bool preferDark = Luminance(background) >= 0.5;
            Color best = FromHsl(h, s, preferDark ? 0.2 : 0.8);
            double bestScore = -1;
            for (int step = 0; step <= 20; step++)
            {
                double candidateLightness = preferDark ? 0.05 + step * 0.045
                                                       : 0.95 - step * 0.045;
                Color candidate = FromHsl(h, s, candidateLightness);
                double onBackground = Ratio(candidate, background);
                Color text = TextOn(candidate);
                double onText = Ratio(text, candidate);
                if (onBackground >= 3.0 && onText >= 4.5) return candidate;
                double score = Math.Min(onBackground / 3.0, onText / 4.5);
                if (score > bestScore) { bestScore = score; best = candidate; }
            }
            return best;
        }

        /// <summary>Black or white text, whichever reads better on the given fill.</summary>
        public static Color TextOn(Color fill)
        {
            return Ratio(Colors.Black, fill) >= Ratio(Colors.White, fill)
                ? Colors.Black : Colors.White;
        }

        public static SolidColorBrush Brush(Color color)
        {
            var brush = new SolidColorBrush(color);
            brush.Freeze();
            return brush;
        }

        public static ContrastAdvisory Advise(string element, Color foreground, Color background,
                                              double minimum)
        {
            double ratio = Ratio(foreground, background);
            if (ratio >= minimum) return null;
            return new ContrastAdvisory
            { Element = element, Ratio = ratio, Minimum = minimum };
        }

        private static void ToHsl(Color color, out double h, out double s, out double l)
        {
            double r = color.R / 255.0, g = color.G / 255.0, b = color.B / 255.0;
            double max = Math.Max(r, Math.Max(g, b));
            double min = Math.Min(r, Math.Min(g, b));
            l = (max + min) / 2.0;
            if (Math.Abs(max - min) < 0.0001)
            {
                h = 0;
                s = 0;
                return;
            }
            double d = max - min;
            s = l > 0.5 ? d / (2.0 - max - min) : d / (max + min);
            if (max == r) h = 60.0 * (((g - b) / d) % 6.0);
            else if (max == g) h = 60.0 * ((b - r) / d + 2.0);
            else h = 60.0 * ((r - g) / d + 4.0);
            if (h < 0) h += 360.0;
        }

        private static Color FromHsl(double h, double s, double l)
        {
            if (l < 0) l = 0;
            if (l > 1) l = 1;
            if (s < 0) s = 0;
            if (s > 1) s = 1;
            double c = (1.0 - Math.Abs(2.0 * l - 1.0)) * s;
            double x = c * (1.0 - Math.Abs(((h / 60.0) % 2.0) - 1.0));
            double m = l - c / 2.0;
            double r, g, b;
            if (h < 60) { r = c; g = x; b = 0; }
            else if (h < 120) { r = x; g = c; b = 0; }
            else if (h < 180) { r = 0; g = c; b = x; }
            else if (h < 240) { r = 0; g = x; b = c; }
            else if (h < 300) { r = x; g = 0; b = c; }
            else { r = c; g = 0; b = x; }
            return Color.FromRgb(ToByte(r + m), ToByte(g + m), ToByte(b + m));
        }

        private static byte ToByte(double value)
        {
            int scaled = (int)Math.Round(value * 255.0);
            if (scaled < 0) scaled = 0;
            if (scaled > 255) scaled = 255;
            return (byte)scaled;
        }
    }
}
