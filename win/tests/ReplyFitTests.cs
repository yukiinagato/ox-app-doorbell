using System;
using System.Linq;
using DoorbellApp.Ui;

internal static class ReplyFitTests
{
    private static int _assertions;

    private static void Check(bool value, string message)
    {
        ++_assertions;
        if (!value) throw new Exception(message);
    }

    private static bool Wide(char c) { return c >= 0x3040 && c <= 0x9fff; }

    // CJK glyphs are 1.0 em, Latin 0.55 em; CJK wraps per character, Latin per word.
    private static Func<double, ReplyExtent> Measurer(string text, double width)
    {
        return size =>
        {
            int lines = 0;
            double widest = 0;
            foreach (string par in text.Split('\n'))
            {
                lines++;
                double cur = 0;
                var tokens = par.Any(Wide)
                    ? par.Select(c => c.ToString()).ToArray()
                    : par.Split(' ').Select((w, i) => i == 0 ? w : " " + w).ToArray();
                foreach (string tok in tokens)
                {
                    double tw = tok.Sum(c => (Wide(c) ? 1.0 : 0.55) * size);
                    if (cur + tw > width && cur > 0) { widest = Math.Max(widest, cur); lines++; cur = 0; }
                    cur += tw;
                }
                widest = Math.Max(widest, cur);
            }
            return new ReplyExtent(widest, lines * size * 1.15);
        };
    }

    private static double Fit(string text, double w, double h, out bool fits)
    {
        return ReplyFit.Fit(w, h, 28, h, Measurer(text, w), out fits);
    }

    private static void Maximal(string text, double w, double h)
    {
        bool fits;
        double size = Fit(text, w, h, out fits);
        Check(fits, "fits: " + text);
        ReplyExtent at = Measurer(text, w)(size), next = Measurer(text, w)(size + 1);
        Check(at.Width <= w + 0.5 && at.Height <= h + 0.5, "inside the box: " + text);
        Check(size >= h || next.Width > w + 0.5 || next.Height > h + 0.5, "largest size: " + text);
    }

    private static int Main()
    {
        bool fits;
        double size = Fit("OK", 1000, 600, out fits);
        Check(fits && size >= 400, "a short text fills the box");
        Maximal("OK", 1000, 600);
        foreach (string t in new[] { "少々お待ちください", "One moment please, I will be right with you", "请稍等，我马上过来" })
            foreach (double[] box in new[] { new[] { 1200.0, 600 }, new[] { 340.0, 500 }, new[] { 700.0, 900 } })
                Maximal(t, box[0], box[1]);
        size = Fit(new string('あ', 600), 340, 300, out fits);
        Check(size == 28 && !fits, "the floor is kept when nothing fits");
        bool f;
        Check(Fit("a\nb\nc\nd", 600, 600, out f) < Fit("a b c d", 600, 600, out f), "explicit newlines add lines");
        Check(ReplyFit.Fit(10, 10, 10, 20, s => new ReplyExtent(1, 1), out f) == 20, "ceiling is respected");
        Console.WriteLine("reply fit tests passed: " + _assertions + " assertions");
        return 0;
    }
}
