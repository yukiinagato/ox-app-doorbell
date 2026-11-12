using System;
using DoorbellApp.Ui;

internal static class ZoomPanMathTests
{
    private static int _assertions;

    private static void Check(bool value, string message)
    {
        ++_assertions;
        if (!value) throw new Exception(message);
    }

    private static bool Near(double a, double b) { return Math.Abs(a - b) < 1e-6; }

    private static void EdgesInside(ZoomPanMath z, string where)
    {
        double left = z.OffsetX + z.ContentX * z.Scale;
        double right = z.OffsetX + (z.ContentX + z.ContentWidth) * z.Scale;
        double top = z.OffsetY + z.ContentY * z.Scale;
        double bottom = z.OffsetY + (z.ContentY + z.ContentHeight) * z.Scale;
        if (z.ContentWidth * z.Scale > z.ViewWidth)
            Check(left <= 1e-6 && right >= z.ViewWidth - 1e-6, where + ": horizontal gap");
        else
            Check(Near(left + right, z.ViewWidth), where + ": not centred horizontally");
        if (z.ContentHeight * z.Scale > z.ViewHeight)
            Check(top <= 1e-6 && bottom >= z.ViewHeight - 1e-6, where + ": vertical gap");
        else
            Check(Near(top + bottom, z.ViewHeight), where + ": not centred vertically");
    }

    public static int Main()
    {
        var z = new ZoomPanMath();
        z.SetGeometry(800, 600, 0, 0, 800, 600);
        Check(Near(z.Scale, 1) && !z.IsZoomed, "starts fitted");

        // Panning at 1x does nothing.
        z.PanBy(50, 50);
        Check(Near(z.OffsetX, 0) && Near(z.OffsetY, 0), "pan at 1x moved the picture");

        // Zoom keeps the pinch centre over the same source pixel.
        z.ZoomAt(2, 400, 300);
        Check(Near(z.Scale, 2), "2x");
        Check(Near((400 - z.OffsetX) / z.Scale, 400) && Near((300 - z.OffsetY) / z.Scale, 300),
              "pinch centre drifted");

        // The range is 1x to 4x.
        z.ZoomAt(100, 400, 300);
        Check(Near(z.Scale, ZoomPanMath.MaxScale) && ZoomPanMath.MaxScale >= 4, "max zoom");
        z.ZoomAt(0.0001, 400, 300);
        Check(Near(z.Scale, 1) && Near(z.OffsetX, 0) && Near(z.OffsetY, 0), "min zoom refits");
        z.ZoomAt(double.NaN, 0, 0);
        z.ZoomAt(-1, 0, 0);
        z.ZoomAt(0, 0, 0);
        Check(Near(z.Scale, 1), "bad factors are ignored");

        // A drag never shows what is beyond the picture's edges.
        z.SetScaleAt(3, 400, 300);
        z.PanBy(100000, 100000);
        Check(Near(z.OffsetX, 0) && Near(z.OffsetY, 0), "dragged past the top-left edge");
        z.PanBy(-100000, -100000);
        Check(Near(z.OffsetX, 800 - 2400) && Near(z.OffsetY, 600 - 1800),
              "dragged past the bottom-right edge");
        EdgesInside(z, "full-frame 3x");

        // Zooming about a corner cannot pull the edge in either.
        z.Reset();
        z.SetScaleAt(4, 0, 0);
        EdgesInside(z, "corner zoom");
        z.SetScaleAt(1.5, 800, 600);
        EdgesInside(z, "corner zoom out");

        // Double tap toggles fit and 2x about the tapped point.
        z.Reset();
        z.ToggleAt(200, 150);
        Check(Near(z.Scale, ZoomPanMath.DoubleTapScale), "double tap zooms to 2x");
        Check(Near((200 - z.OffsetX) / z.Scale, 200), "double tap centre drifted");
        z.ToggleAt(10, 10);
        Check(Near(z.Scale, 1) && Near(z.OffsetX, 0), "second double tap refits");

        // A portrait camera letterboxed in a landscape stage: the bars are not picture.
        z.SetGeometryForAspect(800, 600, 480, 640);
        Check(Near(z.ContentWidth, 450) && Near(z.ContentHeight, 600) && Near(z.ContentX, 175),
              "letterbox geometry");
        z.SetScaleAt(1.5, 400, 300);   // 675 wide: still narrower than the stage
        EdgesInside(z, "letterboxed 1.5x");
        z.PanBy(300, 0);
        EdgesInside(z, "letterboxed 1.5x after drag");
        z.SetScaleAt(4, 400, 300);     // 1800 wide: now pannable to its own edges only
        z.PanBy(100000, 0);
        Check(Near(z.OffsetX, -175 * 4), "panned into the left letterbox bar");
        z.PanBy(-100000, 0);
        Check(Near(z.OffsetX, 800 - (175 + 450) * 4.0), "panned into the right letterbox bar");
        EdgesInside(z, "letterboxed 4x");

        // A resize while zoomed re-clamps instead of leaving a gap.
        z.SetGeometryForAspect(400, 300, 480, 640);
        EdgesInside(z, "after resize");

        // Degenerate geometry falls back to the whole viewport and never throws.
        z.SetGeometryForAspect(0, 0, 0, 0);
        z.SetGeometryForAspect(800, 600, 0, 0);
        Check(Near(z.ContentWidth, 800) && Near(z.ContentHeight, 600), "no aspect fills the view");

        // Reset is what a door or call change calls.
        z.SetScaleAt(3, 100, 100);
        z.Reset();
        Check(!z.IsZoomed && Near(z.OffsetX, 0) && Near(z.OffsetY, 0), "reset");

        Console.WriteLine("Windows zoom/pan tests: " + _assertions + " assertions passed");
        return 0;
    }
}
