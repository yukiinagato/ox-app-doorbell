using System;

namespace DoorbellApp.Ui
{
    internal struct ReplyExtent
    {
        public double Width;
        public double Height;
        public ReplyExtent(double width, double height) { Width = width; Height = height; }
    }

    internal static class ReplyFit
    {
        /// <summary>
        /// Largest whole size in [floor, ceiling] at which measure(size) fits width x height.
        /// When even the floor overflows the floor is returned and fits is false: the caller
        /// scrolls instead of truncating.
        /// </summary>
        public static double Fit(double width, double height, double floor, double ceiling,
                                 Func<double, ReplyExtent> measure, out bool fits)
        {
            int lo = (int)Math.Floor(floor);
            int hi = Math.Max(lo, (int)Math.Floor(ceiling));
            fits = Fits(width, height, lo, measure);
            if (!fits) return lo;
            while (lo < hi)
            {
                int mid = (lo + hi + 1) / 2;
                if (Fits(width, height, mid, measure)) lo = mid; else hi = mid - 1;
            }
            return lo;
        }

        private static bool Fits(double width, double height, int size, Func<double, ReplyExtent> measure)
        {
            ReplyExtent e = measure(size);
            return e.Width <= width + 0.5 && e.Height <= height + 0.5;
        }
    }
}
