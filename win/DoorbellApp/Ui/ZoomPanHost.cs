using System;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace DoorbellApp.Ui
{
    /// <summary>
    /// Wraps a live picture so it can be pinched from 1x to 4x, dragged while zoomed, zoomed with
    /// the mouse wheel, and toggled between fit and 2x by a double tap or double click
    /// (ui-guidelines 4, Live view). The rules live in <see cref="ZoomPanMath"/>; this class only
    /// feeds it input and applies the result as a scale and a translation on its child, clipped
    /// to its own bounds. It handles input over the picture only, so the call actions beside or
    /// below it are never triggered or blocked by a gesture.
    /// </summary>
    public sealed class ZoomPanHost : Decorator
    {
        private const double WheelStep = 1.2;
        private const double DoubleTapMs = 350;
        private const double DoubleTapSlop = 48;

        private readonly ZoomPanMath _math = new ZoomPanMath();
        private readonly ScaleTransform _scale = new ScaleTransform();
        private readonly TranslateTransform _translate = new TranslateTransform();
        private readonly TransformGroup _transform = new TransformGroup();
        private bool _dragging;
        private Point _dragLast;
        private DateTime _lastTapAt = DateTime.MinValue;
        private Point _lastTapPoint;

        public ZoomPanHost()
        {
            _transform.Children.Add(_scale);
            _transform.Children.Add(_translate);
            ClipToBounds = true;
            IsManipulationEnabled = true;
        }

        public override UIElement Child
        {
            get { return base.Child; }
            set
            {
                base.Child = value;
                if (value == null) return;
                value.RenderTransformOrigin = new Point(0, 0);
                value.RenderTransform = _transform;
            }
        }

        /// <summary>The current zoom factor, 1 when the picture is fitted.</summary>
        public double Scale { get { return _math.Scale; } }

        /// <summary>Back to the fitted picture; called when the door or the call changes.</summary>
        public void Reset()
        {
            EndDrag();
            _math.Reset();
            Apply();
        }

        // A Decorator has no automation peer of its own; this one lets UI automation find the
        // picture area by its x:Name and send it input.
        protected override AutomationPeer OnCreateAutomationPeer()
        {
            return new FrameworkElementAutomationPeer(this);
        }

        // The whole area takes input, including the letterbox bars beside the picture.
        protected override HitTestResult HitTestCore(PointHitTestParameters hitTestParameters)
        {
            return new PointHitTestResult(this, hitTestParameters.HitPoint);
        }

        protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo)
        {
            base.OnRenderSizeChanged(sizeInfo);
            MeasurePicture();
            Apply();
        }

        // ---- touch ----------------------------------------------------------------------------

        protected override void OnManipulationStarting(ManipulationStartingEventArgs e)
        {
            base.OnManipulationStarting(e);
            e.ManipulationContainer = this;
            e.Mode = ManipulationModes.Scale | ManipulationModes.Translate;
            MeasurePicture();
            e.Handled = true;
        }

        protected override void OnManipulationDelta(ManipulationDeltaEventArgs e)
        {
            base.OnManipulationDelta(e);
            if (e.IsInertial)
            {
                // No coasting: the picture stops where the fingers left it, inside its edges.
                e.Complete();
                e.Handled = true;
                return;
            }
            var delta = e.DeltaManipulation;
            _math.ZoomAt(delta.Scale.X, e.ManipulationOrigin.X, e.ManipulationOrigin.Y);
            _math.PanBy(delta.Translation.X, delta.Translation.Y);
            Apply();
            e.Handled = true;
        }

        protected override void OnTouchDown(TouchEventArgs e)
        {
            base.OnTouchDown(e);
            Point at = e.GetTouchPoint(this).Position;
            DateTime now = DateTime.UtcNow;
            bool second = (now - _lastTapAt).TotalMilliseconds <= DoubleTapMs &&
                          Math.Abs(at.X - _lastTapPoint.X) <= DoubleTapSlop &&
                          Math.Abs(at.Y - _lastTapPoint.Y) <= DoubleTapSlop;
            if (second)
            {
                _lastTapAt = DateTime.MinValue;
                MeasurePicture();
                _math.ToggleAt(at.X, at.Y);
                Apply();
                return;
            }
            _lastTapAt = now;
            _lastTapPoint = at;
        }

        // ---- mouse ----------------------------------------------------------------------------

        protected override void OnMouseWheel(MouseWheelEventArgs e)
        {
            base.OnMouseWheel(e);
            Point at = e.GetPosition(this);
            MeasurePicture();
            _math.ZoomAt(e.Delta > 0 ? WheelStep : 1 / WheelStep, at.X, at.Y);
            Apply();
            e.Handled = true;
        }

        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
        {
            base.OnMouseLeftButtonDown(e);
            if (e.StylusDevice != null) return;   // touch is handled by the manipulation above
            Point at = e.GetPosition(this);
            if (e.ClickCount == 2)
            {
                EndDrag();
                MeasurePicture();
                _math.ToggleAt(at.X, at.Y);
                Apply();
                return;
            }
            if (!_math.IsZoomed) return;
            _dragging = true;
            _dragLast = at;
            CaptureMouse();
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (!_dragging) return;
            Point at = e.GetPosition(this);
            _math.PanBy(at.X - _dragLast.X, at.Y - _dragLast.Y);
            _dragLast = at;
            Apply();
        }

        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
        {
            base.OnMouseLeftButtonUp(e);
            EndDrag();
        }

        protected override void OnLostMouseCapture(MouseEventArgs e)
        {
            base.OnLostMouseCapture(e);
            _dragging = false;
        }

        private void EndDrag()
        {
            if (!_dragging) return;
            _dragging = false;
            if (IsMouseCaptured) ReleaseMouseCapture();
        }

        // ---- geometry -------------------------------------------------------------------------

        /// <summary>
        /// Tells the math where the picture sits at 1x: the bounds of the topmost visible Image or
        /// MediaElement inside the child (a Uniform picture is arranged at its fitted size, so its
        /// bounds exclude the letterbox bars). With no picture the whole host is the content.
        /// </summary>
        private void MeasurePicture()
        {
            Rect picture = new Rect(0, 0, ActualWidth, ActualHeight);
            var child = Child as Visual;
            if (child != null)
            {
                FrameworkElement found = FindPicture(child);
                if (found != null)
                {
                    try
                    {
                        Rect bounds = found.TransformToAncestor(child).TransformBounds(
                            new Rect(0, 0, found.ActualWidth, found.ActualHeight));
                        if (bounds.Width > 0 && bounds.Height > 0) picture = bounds;
                    }
                    catch (InvalidOperationException)
                    {
                        // Not in the visual tree yet; the whole host stands in for the picture.
                    }
                }
            }
            _math.SetGeometry(ActualWidth, ActualHeight, picture.X, picture.Y,
                              picture.Width, picture.Height);
        }

        private static FrameworkElement FindPicture(DependencyObject node)
        {
            FrameworkElement found = null;
            int count = VisualTreeHelper.GetChildrenCount(node);
            for (int i = 0; i < count; i++)
            {
                DependencyObject item = VisualTreeHelper.GetChild(node, i);
                var element = item as FrameworkElement;
                if (element != null && element.Visibility != Visibility.Visible) continue;
                bool picture = (element is Image && ((Image)element).Source != null) ||
                               element is MediaElement;
                if (picture && element.ActualWidth > 0 && element.ActualHeight > 0 &&
                    element.Opacity > 0) found = element;
                FrameworkElement deeper = FindPicture(item);
                if (deeper != null) found = deeper;
            }
            return found;
        }

        private void Apply()
        {
            _scale.ScaleX = _math.Scale;
            _scale.ScaleY = _math.Scale;
            _translate.X = _math.OffsetX;
            _translate.Y = _math.OffsetY;
        }
    }
}
