using System;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;

namespace DoorbellApp.Ui
{
    /// <summary>
    /// Slide-to-trigger SOS control (spec 4.4). Releasing the thumb past 90 % of the track raises
    /// <see cref="Armed"/>; the owner runs the cancellable countdown and only then tells core the
    /// emergency is real. Releasing short of the threshold snaps back and does nothing.
    /// </summary>
    public class SosSlider : Slider
    {
        public const double ArmThreshold = 90.0;

        /// <summary>Raised on the dispatcher thread when the thumb was released past 90 %.</summary>
        public event Action Armed;

        public SosSlider()
        {
            Minimum = 0;
            Maximum = 100;
            Value = 0;
            IsSnapToTickEnabled = false;
            IsMoveToPointEnabled = false;
            Focusable = false;
            AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler(OnThumbDragStarted));
            AddHandler(Thumb.DragCompletedEvent,
                       new DragCompletedEventHandler(OnThumbDragCompleted));
        }

        /// <summary>True while the visitor or resident is dragging the thumb.</summary>
        public bool IsSliding { get; private set; }

        private void OnThumbDragStarted(object sender, DragStartedEventArgs e)
        {
            IsSliding = true;
        }

        private void OnThumbDragCompleted(object sender, DragCompletedEventArgs e)
        {
            IsSliding = false;
            bool armed = Value >= ArmThreshold;
            Value = 0;
            if (!armed) return;
            var handler = Armed;
            if (handler != null) handler();
        }

        /// <summary>Returns the thumb to the start, for example when a countdown is cancelled.</summary>
        public void Reset()
        {
            IsSliding = false;
            Value = 0;
        }
    }
}
