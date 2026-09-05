using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;

namespace DoorbellApp.Ui
{
    /// <summary>
    /// The frosted-glass material of the indoor dashboard, after the iPad 1 kiosk: a plate shows
    /// the wallpaper behind it blurred, under a 65 % surface tint and a hairline. WPF has no live
    /// backdrop filter, so the window renders one blurred copy of the wallpaper (with the theme
    /// scrim baked in) and every plate paints the rectangle of that bitmap it sits over through an
    /// ImageBrush with an absolute viewbox. Over a flat background there is nothing to blur and the
    /// plate is just its tint, which is what the kiosk does too.
    ///
    /// Usage: <c>ui:Frost.Enabled="True"</c> on a Border; the Border's own Background is replaced,
    /// so put the tint on a child Border (or use the Plate style, which does both).
    /// </summary>
    public static class Frost
    {
        public static readonly DependencyProperty EnabledProperty =
            DependencyProperty.RegisterAttached("Enabled", typeof(bool), typeof(Frost),
                new PropertyMetadata(false, OnEnabledChanged));

        public static void SetEnabled(DependencyObject element, bool value)
        {
            element.SetValue(EnabledProperty, value);
        }

        public static bool GetEnabled(DependencyObject element)
        {
            return (bool)element.GetValue(EnabledProperty);
        }

        private static readonly List<WeakReference> Plates = new List<WeakReference>();
        private static BitmapSource _blurred;
        private static Size _blurredFor;
        private static FrameworkElement _root;

        /// <summary>Blur radius in device-independent pixels at the reduced render scale.</summary>
        private const double BlurRadius = 26;
        private const double RenderScale = 0.5;

        private static void OnEnabledChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            var border = d as Border;
            if (border == null) return;
            if ((bool)e.NewValue)
            {
                Plates.Add(new WeakReference(border));
                border.LayoutUpdated += (s, a) => Paint(border);
                border.Loaded += (s, a) => Paint(border);
                Paint(border);
            }
            else
            {
                border.Background = null;
            }
        }

        /// <summary>
        /// Re-renders the blurred wallpaper. <paramref name="wallpaper"/> is the theme picture as
        /// shown (UniformToFill over the window); null clears the material so plates fall back to
        /// their tint. <paramref name="scrim"/>/<paramref name="scrimOpacity"/> reproduce the
        /// backdrop overlay that darkens the picture, so the blur matches what is seen around it.
        /// </summary>
        public static void SetWallpaper(FrameworkElement root, BitmapSource wallpaper, Color scrim,
                                        double scrimOpacity)
        {
            _root = root;
            _blurred = null;
            if (wallpaper == null || root == null || root.ActualWidth < 1 || root.ActualHeight < 1)
            {
                RepaintAll();
                return;
            }
            try
            {
                double w = root.ActualWidth, h = root.ActualHeight;
                int pw = Math.Max(1, (int)Math.Round(w * RenderScale));
                int ph = Math.Max(1, (int)Math.Round(h * RenderScale));
                var visual = new DrawingVisual();
                using (DrawingContext dc = visual.RenderOpen())
                {
                    // UniformToFill: scale to cover, centre the overflow, like the Image control.
                    double scale = Math.Max(pw / (double)wallpaper.PixelWidth,
                                            ph / (double)wallpaper.PixelHeight);
                    double dw = wallpaper.PixelWidth * scale, dh = wallpaper.PixelHeight * scale;
                    dc.DrawImage(wallpaper, new Rect((pw - dw) / 2, (ph - dh) / 2, dw, dh));
                    if (scrimOpacity > 0)
                    {
                        var tint = new SolidColorBrush(scrim) { Opacity = scrimOpacity };
                        dc.DrawRectangle(tint, null, new Rect(0, 0, pw, ph));
                    }
                }
                var host = new Border
                {
                    Width = pw, Height = ph,
                    Child = new Image { Source = Snapshot(visual, pw, ph), Stretch = Stretch.Fill },
                    Effect = new BlurEffect { Radius = BlurRadius, KernelType = KernelType.Gaussian },
                };
                host.Measure(new Size(pw, ph));
                host.Arrange(new Rect(0, 0, pw, ph));
                var target = new RenderTargetBitmap(pw, ph, 96, 96, PixelFormats.Pbgra32);
                target.Render(host);
                target.Freeze();
                _blurred = target;
                _blurredFor = new Size(w, h);
            }
            catch
            {
                _blurred = null;
            }
            RepaintAll();
        }

        private static BitmapSource Snapshot(Visual visual, int width, int height)
        {
            var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            bitmap.Freeze();
            return bitmap;
        }

        public static void RepaintAll()
        {
            for (int i = Plates.Count - 1; i >= 0; i--)
            {
                var border = Plates[i].Target as Border;
                if (border == null) { Plates.RemoveAt(i); continue; }
                Paint(border);
            }
        }

        private static void Paint(Border border)
        {
            if (_blurred == null || _root == null || !GetEnabled(border) ||
                border.ActualWidth < 1 || border.ActualHeight < 1)
            {
                if (border.Background != null) border.Background = null;
                return;
            }
            Point origin;
            try { origin = border.TransformToAncestor(_root).Transform(new Point(0, 0)); }
            catch { return; }
            double sx = _blurred.PixelWidth / _blurredFor.Width;
            double sy = _blurred.PixelHeight / _blurredFor.Height;
            var viewbox = new Rect(origin.X * sx, origin.Y * sy,
                                   border.ActualWidth * sx, border.ActualHeight * sy);
            var current = border.Background as ImageBrush;
            if (current != null && current.ImageSource == _blurred && current.Viewbox == viewbox)
                return;
            border.Background = new ImageBrush(_blurred)
            {
                ViewboxUnits = BrushMappingMode.Absolute,
                Viewbox = viewbox,
                Stretch = Stretch.Fill,
            };
        }
    }
}
