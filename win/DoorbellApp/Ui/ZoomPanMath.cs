using System;

namespace DoorbellApp.Ui
{
    /// <summary>
    /// The zoom and pan state of one live picture, with every rule that keeps the picture on
    /// screen. It has no WPF dependency so it is tested on the build host.
    ///
    /// The viewport is the whole video stage and the picture is aspect-fitted inside it;
    /// <c>Content*</c> is the rectangle the picture occupies at 1x. A viewport point p shows
    /// source point (p - Offset) / Scale. The stage, not the fitted picture, is the clip: a
    /// zoomed picture grows into the letterbox bars until it covers the stage. Each axis is
    /// clamped on its own: where the zoomed picture is no larger than the stage it stays
    /// centred; where it is larger, it can be dragged only until its edge meets the stage edge.
    /// </summary>
    internal sealed class ZoomPanMath
    {
        public const double MinScale = 1.0;
        public const double MaxScale = 4.0;
        public const double DoubleTapScale = 2.0;

        public double Scale { get; private set; } = MinScale;
        public double OffsetX { get; private set; }
        public double OffsetY { get; private set; }

        public double ViewWidth { get; private set; }
        public double ViewHeight { get; private set; }
        public double ContentX { get; private set; }
        public double ContentY { get; private set; }
        public double ContentWidth { get; private set; }
        public double ContentHeight { get; private set; }

        public bool IsZoomed { get { return Scale > MinScale + 1e-6; } }

        /// <summary>Sets the viewport and where the picture sits in it at 1x, then re-clamps.</summary>
        public void SetGeometry(double viewWidth, double viewHeight, double contentX,
                                double contentY, double contentWidth, double contentHeight)
        {
            ViewWidth = Math.Max(0, viewWidth);
            ViewHeight = Math.Max(0, viewHeight);
            ContentX = contentX;
            ContentY = contentY;
            ContentWidth = Math.Max(0, contentWidth);
            ContentHeight = Math.Max(0, contentHeight);
            Clamp();
        }

        /// <summary>
        /// Where a picture of the given aspect sits when it is fitted (letterboxed) into the
        /// viewport. A missing or degenerate aspect fills the viewport.
        /// </summary>
        public void SetGeometryForAspect(double viewWidth, double viewHeight, double pictureWidth,
                                         double pictureHeight)
        {
            if (viewWidth <= 0 || viewHeight <= 0 || pictureWidth <= 0 || pictureHeight <= 0)
            {
                SetGeometry(viewWidth, viewHeight, 0, 0, viewWidth, viewHeight);
                return;
            }
            double fit = Math.Min(viewWidth / pictureWidth, viewHeight / pictureHeight);
            double width = pictureWidth * fit, height = pictureHeight * fit;
            SetGeometry(viewWidth, viewHeight, (viewWidth - width) / 2, (viewHeight - height) / 2,
                        width, height);
        }

        public void Reset()
        {
            Scale = MinScale;
            OffsetX = 0;
            OffsetY = 0;
        }

        /// <summary>Multiplies the zoom, keeping the viewport point (x, y) over the same pixel.</summary>
        public void ZoomAt(double factor, double x, double y)
        {
            if (double.IsNaN(factor) || double.IsInfinity(factor) || factor <= 0) return;
            SetScaleAt(Scale * factor, x, y);
        }

        public void SetScaleAt(double scale, double x, double y)
        {
            double next = Math.Max(MinScale, Math.Min(MaxScale, scale));
            double ratio = next / Scale;
            OffsetX = x - (x - OffsetX) * ratio;
            OffsetY = y - (y - OffsetY) * ratio;
            Scale = next;
            Clamp();
        }

        public void PanBy(double dx, double dy)
        {
            if (!IsZoomed) return;
            OffsetX += dx;
            OffsetY += dy;
            Clamp();
        }

        /// <summary>Double tap: fit when zoomed, otherwise 2x about the tapped point.</summary>
        public void ToggleAt(double x, double y)
        {
            if (IsZoomed) Reset();
            else SetScaleAt(DoubleTapScale, x, y);
        }

        private void Clamp()
        {
            if (Scale <= MinScale + 1e-6)
            {
                Reset();
                return;
            }
            OffsetX = ClampAxis(OffsetX, ViewWidth, ContentX, ContentWidth);
            OffsetY = ClampAxis(OffsetY, ViewHeight, ContentY, ContentHeight);
        }

        private double ClampAxis(double offset, double view, double contentStart, double contentSize)
        {
            double scaled = contentSize * Scale;
            // Narrower than the viewport on this axis: nothing to pan, keep it centred.
            if (scaled <= view) return (view - scaled) / 2 - contentStart * Scale;
            double highest = -contentStart * Scale;                     // leading edges meet
            double lowest = view - (contentStart + contentSize) * Scale; // trailing edges meet
            return Math.Max(lowest, Math.Min(highest, offset));
        }
    }
}
