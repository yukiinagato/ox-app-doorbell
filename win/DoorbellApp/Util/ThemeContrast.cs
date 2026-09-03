using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DoorbellApp.Core;

namespace DoorbellApp.Util
{
    /// <summary>
    /// What a background looks like under one text region: the average that decides the ink, and
    /// the darkest and lightest patch of the 16x16 sample, which decide whether it needs an
    /// outline. A flat surface is the degenerate case where all three agree.
    /// </summary>
    internal sealed class BackgroundSample
    {
        public Color Average;
        public double DarkestLuminance;
        public double LightestLuminance;

        public static BackgroundSample Uniform(Color colour)
        {
            double luminance = ThemeContrast.Luminance(colour);
            return new BackgroundSample
            {
                Average = colour,
                DarkestLuminance = luminance,
                LightestLuminance = luminance,
            };
        }
    }

    /// <summary>
    /// The ink one text region is drawn in, and whether it still needs the thin outline that
    /// keeps it legible when even the better ink misses the 4.5:1 body-text target.
    /// </summary>
    internal sealed class InkDecision
    {
        public Color Ink;
        public Color Shadow;
        public bool NeedsShadow;
        /// <summary>Where it came from: "admin", "core", "local_region", or "local".</summary>
        public string Source = "local";
    }

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

        /// <summary>
        /// The ink token that actually reads better on a background: whichever of the two has the
        /// higher WCAG contrast ratio against it. A luminance threshold at 0.5 gets this wrong in
        /// the middle of the range — a wallpaper averaging #BBBBB4 sits at Y = 0.494 and would
        /// take light ink at 1.7:1 where dark ink gives 9.0:1. The true crossover for these
        /// tokens is near Y = 0.179, and comparing the ratios finds it exactly.
        /// </summary>
        public static Color BetterInk(Color background)
        {
            return Ratio(DarkInk, background) >= Ratio(LightInk, background) ? DarkInk : LightInk;
        }

        public static double Ratio(Color first, Color second)
        {
            return RatioOf(Luminance(first), Luminance(second));
        }

        /// <summary>
        /// The neutral grey with the given relative luminance. The three coefficients sum to one,
        /// so for a grey the luminance is just the linearised channel, and this inverts it.
        /// </summary>
        public static Color GreyOfLuminance(double luminance)
        {
            if (luminance < 0) luminance = 0;
            if (luminance > 1) luminance = 1;
            double channel = luminance <= 0.0031308
                ? luminance * 12.92
                : 1.055 * Math.Pow(luminance, 1.0 / 2.4) - 0.055;
            int value = (int)Math.Round(channel * 255.0);
            if (value < 0) value = 0;
            if (value > 255) value = 255;
            return Color.FromRgb((byte)value, (byte)value, (byte)value);
        }

        /// <summary>WCAG contrast between two relative luminances.</summary>
        public static double RatioOf(double first, double second)
        {
            return (Math.Max(first, second) + 0.05) / (Math.Min(first, second) + 0.05);
        }

        /// <summary>
        /// Sample an image at no more than 16x16 as the spec requires, keeping the average colour
        /// and the darkest and lightest patch. Returns false when the source cannot be sampled,
        /// so the caller keeps the theme colour.
        /// </summary>
        public static bool TrySample(BitmapSource source, out BackgroundSample sample)
        {
            sample = BackgroundSample.Uniform(Colors.Black);
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
                int count = width * height;
                if (count == 0) return false;
                long r = 0, g = 0, b = 0;
                double darkest = 1.0, lightest = 0.0;
                for (int i = 0; i < count; i++)
                {
                    byte blue = pixels[i * 4];
                    byte green = pixels[i * 4 + 1];
                    byte red = pixels[i * 4 + 2];
                    b += blue;
                    g += green;
                    r += red;
                    double patch = 0.2126 * Channel(red) + 0.7152 * Channel(green) +
                                   0.0722 * Channel(blue);
                    if (patch < darkest) darkest = patch;
                    if (patch > lightest) lightest = patch;
                }
                sample = new BackgroundSample
                {
                    Average = Color.FromRgb((byte)(r / count), (byte)(g / count),
                                            (byte)(b / count)),
                    DarkestLuminance = darkest,
                    LightestLuminance = lightest,
                };
                return true;
            }
            catch { return false; }
        }

        /// <summary>The average alone, for callers that only need one flat colour.</summary>
        public static bool TryAverage(BitmapSource source, out Color average)
        {
            BackgroundSample sample;
            bool ok = TrySample(source, out sample);
            average = sample.Average;
            return ok;
        }

        /// <summary>
        /// Average only the part of a background image that lies under one element. Core computes
        /// its automatic ink from the whole image because it has no layout geometry, which reads
        /// white over a light corner; the shell has the geometry, so it refines per region.
        /// </summary>
        public static bool TrySampleRegion(BitmapSource source, Int32Rect crop,
                                           out BackgroundSample sample)
        {
            sample = BackgroundSample.Uniform(Colors.Black);
            if (source == null || crop.Width <= 0 || crop.Height <= 0) return false;
            try
            {
                return TrySample(new CroppedBitmap(source, crop), out sample);
            }
            catch (ArgumentException) { return false; }
            catch (InvalidOperationException) { return false; }
        }

        /// <summary>
        /// Map an element's rectangle in window coordinates onto the pixels of a background drawn
        /// with Stretch=UniformToFill, which scales to cover and centres the overflow.
        /// </summary>
        public static Int32Rect MapUniformToFill(BitmapSource source, Size viewport, Rect element)
        {
            if (source == null || viewport.Width <= 0 || viewport.Height <= 0)
                return Int32Rect.Empty;
            double imageWidth = source.PixelWidth;
            double imageHeight = source.PixelHeight;
            if (imageWidth <= 0 || imageHeight <= 0) return Int32Rect.Empty;
            double scale = Math.Max(viewport.Width / imageWidth, viewport.Height / imageHeight);
            if (scale <= 0) return Int32Rect.Empty;
            double offsetX = (viewport.Width - imageWidth * scale) / 2.0;
            double offsetY = (viewport.Height - imageHeight * scale) / 2.0;
            double left = (element.X - offsetX) / scale;
            double top = (element.Y - offsetY) / scale;
            double right = left + element.Width / scale;
            double bottom = top + element.Height / scale;
            int x = (int)Math.Floor(Math.Max(0, Math.Min(imageWidth - 1, left)));
            int y = (int)Math.Floor(Math.Max(0, Math.Min(imageHeight - 1, top)));
            int width = (int)Math.Ceiling(Math.Max(1, Math.Min(imageWidth - x, right - left)));
            int height = (int)Math.Ceiling(Math.Max(1, Math.Min(imageHeight - y, bottom - top)));
            return new Int32Rect(x, y, width, height);
        }

        /// <summary>
        /// The ink for one text region. An administrator override wins over everything. Core's
        /// per-region value wins next, but only when the caller is looking at the very background
        /// core measured: over a background image core holds one whole-image average and the ABI
        /// invites the shell to refine per region, and text over a card or a call screen sits on
        /// a surface core knows nothing about. Both of those cases pass decideLocally, and the
        /// background handed in decides. The outline is added only when the chosen ink still
        /// misses the 4.5:1 body-text target.
        /// </summary>
        public static InkDecision Decide(Dictionary<string, object> display, string regionId,
                                         Color background, bool decideLocally)
        {
            return Decide(display, regionId, BackgroundSample.Uniform(background), decideLocally);
        }

        public static InkDecision Decide(Dictionary<string, object> display, string regionId,
                                         BackgroundSample sample, bool decideLocally)
        {
            Color background = sample.Average;
            var decision = new InkDecision();
            Color parsed;
            object over = CoreClient.Dig(display, "theme.ink_override." + regionId);
            if (over != null && TryParse(over.ToString(), out parsed))
            {
                decision.Ink = parsed;
                decision.Source = "admin";
            }
            else
            {
                object auto = decideLocally ? null
                    : CoreClient.Dig(display, "theme.auto_ink." + regionId);
                string token = auto == null ? "" : auto.ToString();
                if (token == "light") { decision.Ink = LightInk; decision.Source = "core"; }
                else if (token == "dark") { decision.Ink = DarkInk; decision.Source = "core"; }
                else
                {
                    decision.Ink = BetterInk(background);
                    decision.Source = decideLocally ? "local_region" : "local";
                }
            }
            // The outline is the opposite of whatever ink was chosen, including an admin colour.
            decision.Shadow = BetterInk(decision.Ink);
            // The ink is chosen against the average, but legibility is judged against every patch
            // of the region: text that spans a light and a dark part of a photograph fails over
            // one of them even when the average reads well. Contrast falls off monotonically away
            // from the ink's own luminance, so the worst patch is one of the two extremes.
            double ink = Luminance(decision.Ink);
            decision.NeedsShadow = RatioOf(ink, sample.DarkestLuminance) < 4.5 ||
                                   RatioOf(ink, sample.LightestLuminance) < 4.5;
            return decision;
        }

        /// <summary>
        /// False when core reports auto_background.source "image_unsampled": a background image is
        /// configured but core could not read it, so its colour, auto_ink and auto_accent all came
        /// from the flat theme colour and describe nothing that is on screen. Shells must then
        /// sample locally instead of trusting the published values.
        /// </summary>
        public static bool CoreSampledBackground(Dictionary<string, object> display)
        {
            object source = CoreClient.Dig(display, "theme.auto_background.source");
            return source == null || source.ToString() != "image_unsampled";
        }

        /// <summary>
        /// The background core actually measured, image averaging included. Falls back to the
        /// caller's own sample when the contract has no auto_background, or when core says it
        /// never read the configured image.
        /// </summary>
        public static bool TryContractBackground(Dictionary<string, object> display,
                                                 out Color background)
        {
            background = Colors.Black;
            if (!CoreSampledBackground(display)) return false;
            object value = CoreClient.Dig(display, "theme.auto_background.color");
            return value != null && TryParse(value.ToString(), out background);
        }

        /// <summary>
        /// Door-station call-button colour. Precedence: per-device override, cluster override, the
        /// core-published automatic accent, then the local complement computation.
        /// </summary>
        public static Color CallButton(Dictionary<string, object> display,
                                       Dictionary<string, object> config, string nodeId,
                                       Color background)
        {
            Color parsed;
            // An administrator's colour always applies. Core folds it into theme.call_button_bg,
            // but that field also carries the computed accent, so when core never read the
            // background image the override is taken from configuration instead.
            if (!CoreSampledBackground(display))
            {
                object over = null;
                if (!string.IsNullOrEmpty(nodeId))
                    over = CoreClient.Dig(config,
                        "devices." + nodeId + ".local.theme.call_button_bg");
                if (over == null) over = CoreClient.Dig(config, "display.theme.call_button_bg");
                if (over != null && TryParse(over.ToString(), out parsed)) return parsed;
                return LocalAccent(background);
            }
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
            if (CoreSampledBackground(display))
            {
                object value = CoreClient.Dig(display, "theme.call_button_ink");
                if (value == null)
                    value = CoreClient.Dig(display, "theme.auto_accent.call_button_ink");
                string token = value == null ? "" : value.ToString();
                if (token == "light") return Colors.White;
                if (token == "dark") return Colors.Black;
            }
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
            bool preferDark = BetterInk(background) == DarkInk;
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
