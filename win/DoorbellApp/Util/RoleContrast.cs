using System;

namespace DoorbellApp.Util
{
    /// <summary>
    /// WCAG contrast arithmetic on plain RGB values, for the colours a role takes when it is
    /// used as text or as an outline rather than as a fill. A role fill only has to carry its
    /// own "on" ink; the same colour as text has to reach 4.5:1 against whatever surface it is
    /// drawn on, in both appearances. It has no WPF dependency so the rule is tested on the host.
    /// </summary>
    internal static class RoleContrast
    {
        public const double TextMinimum = 4.5;
        public const double OutlineMinimum = 3.0;

        public static int Rgb(int r, int g, int b) { return (r << 16) | (g << 8) | b; }

        private static double Channel(int value)
        {
            double v = value / 255.0;
            return v <= 0.04045 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4);
        }

        public static double Luminance(int rgb)
        {
            return 0.2126 * Channel((rgb >> 16) & 0xFF) + 0.7152 * Channel((rgb >> 8) & 0xFF) +
                   0.0722 * Channel(rgb & 0xFF);
        }

        public static double Ratio(int first, int second)
        {
            double a = Luminance(first), b = Luminance(second);
            return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05);
        }

        /// <summary>A colour with the given opacity (0..1) composited over an opaque one.</summary>
        public static int Over(int top, double opacity, int under)
        {
            Func<int, int> mix = shift =>
                (int)Math.Round(((top >> shift) & 0xFF) * opacity +
                                ((under >> shift) & 0xFF) * (1 - opacity));
            return Rgb(mix(16), mix(8), mix(0));
        }

        /// <summary>
        /// The colour itself when it already reads against the surface; otherwise the same hue
        /// moved towards white on a dark surface, or towards black on a light one, in small
        /// steps until it does. Used for the accent, which Core or Windows may set to anything.
        /// </summary>
        public static int EnsureReadable(int color, int surface, double minimum)
        {
            if (Ratio(color, surface) >= minimum) return color;
            int target = Luminance(surface) < 0.18 ? 0xFFFFFF : 0x000000;
            for (int step = 1; step <= 20; step++)
            {
                int candidate = Over(target, step / 20.0, color);
                if (Ratio(candidate, surface) >= minimum) return candidate;
            }
            return target;
        }
    }
}
