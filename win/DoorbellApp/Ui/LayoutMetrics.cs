using System;
using System.Windows;

namespace DoorbellApp.Ui
{
    /// <summary>Window size classes from docs/en/ui-guidelines.md section 2.</summary>
    internal enum SizeClass { Compact, Medium, Expanded }

    /// <summary>
    /// Shared layout tokens (ui-guidelines section 3). All values are WPF device-independent
    /// pixels, so the per-monitor DPI scale in app.manifest maps them to physical pixels and the
    /// size class follows the effective width, not the panel resolution.
    /// </summary>
    internal static class LayoutMetrics
    {
        public const double CompactMax = 600;
        public const double ExpandedMin = 900;

        // 4-point spacing grid.
        public const double S1 = 4, S2 = 8, S3 = 12, S4 = 16, S6 = 24, S8 = 32, S12 = 48;

        /// <summary>Minimum touch target on Windows (Toughpad glove use included).</summary>
        public const double TouchMin = 44;
        /// <summary>Door-station visitor targets.</summary>
        public const double VisitorTouchMin = 72;

        // Type scale relative to body.
        public const double Caption = 0.8, Body = 1.0, Title = 1.25, Headline = 1.6, Display = 2.2;

        public const double CardRadius = 12, PillRadius = 999, SheetRadius = 20;

        /// <summary>Live-view overlay controls hide after this long without input.</summary>
        public static readonly TimeSpan OverlayAutoHide = TimeSpan.FromSeconds(4);

        public static SizeClass Classify(double width)
        {
            if (width < CompactMax) return SizeClass.Compact;
            if (width < ExpandedMin) return SizeClass.Medium;
            return SizeClass.Expanded;
        }

        /// <summary>Landscape action zone (right side) only when wide and wider than tall.</summary>
        public static bool SideActionZone(double width, double height)
        {
            return Classify(width) == SizeClass.Expanded && width > height;
        }

        /// <summary>Visitor purpose grid: 2 columns compact, 3 medium, 3–4 expanded.</summary>
        public static int PurposeColumns(SizeClass size, double width, int count)
        {
            int columns;
            if (size == SizeClass.Compact) columns = 2;
            else if (size == SizeClass.Medium) columns = 3;
            else columns = width >= 1280 ? 4 : 3;
            if (count > 0 && count < columns) columns = count;
            return Math.Max(1, columns);
        }

        /// <summary>Dashboard door tiles: 1 compact, 2 medium, 3–4 expanded.</summary>
        public static int TileColumns(SizeClass size, double width, int count)
        {
            int columns;
            if (size == SizeClass.Compact) columns = 1;
            else if (size == SizeClass.Medium) columns = 2;
            else columns = width >= 1400 ? 4 : 3;
            if (count > 0 && count < columns) columns = count;
            return Math.Max(1, columns);
        }

        /// <summary>
        /// Body font size for the size class, scaled by the system text-size setting so ja/zh at
        /// large text still fit (labels wrap rather than clip).
        /// </summary>
        public static double BodySize(SizeClass size)
        {
            double basis = size == SizeClass.Compact ? 16 : (size == SizeClass.Medium ? 18 : 20);
            return basis * TextScale();
        }

        /// <summary>Windows 10+ "Make text bigger" (Accessibility\TextScaleFactor), 1.0 elsewhere.</summary>
        public static double TextScale()
        {
            try
            {
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Accessibility"))
                {
                    object v = key == null ? null : key.GetValue("TextScaleFactor");
                    if (v is int)
                    {
                        int pct = (int)v;
                        if (pct >= 100 && pct <= 225) return Math.Min(pct / 100.0, 1.5);
                    }
                }
            }
            catch (Exception) { }
            return 1.0;
        }

        public static Thickness Pad(double h, double v) { return new Thickness(h, v, h, v); }
    }
}
