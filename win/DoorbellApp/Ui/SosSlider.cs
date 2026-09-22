using System;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
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
        public event Action ReviewRequested;
        private long _reviewRevision;

        public SosSlider()
        {
            Minimum = 0;
            Maximum = 100;
            Value = 0;
            IsSnapToTickEnabled = false;
            IsMoveToPointEnabled = false;
            Focusable = true;
            Unloaded += (s, e) => Reset();
            IsVisibleChanged += (s, e) => { if (!IsVisible) Reset(); };
            IsEnabledChanged += (s, e) => { if (!IsEnabled) Reset(); };
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
            bool armed = !e.Canceled && IsEnabled && IsVisible && IsLoaded && Value >= ArmThreshold;
            Value = 0;
            if (!armed) return;
            var handler = Armed;
            if (handler != null) handler();
        }

        /// <summary>Returns the thumb to the start, for example when a countdown is cancelled.</summary>
        public void Reset()
        {
            System.Threading.Interlocked.Increment(ref _reviewRevision);
            IsSliding = false;
            Value = 0;
        }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.Key == Key.Enter || e.Key == Key.Space)
            {
                e.Handled = true;
                if (!e.IsRepeat) RequestReview(System.Threading.Interlocked.Read(ref _reviewRevision));
                return;
            }
            base.OnKeyDown(e);
        }

        private void RequestReview(long revision)
        {
            if (revision != _reviewRevision || !IsLoaded || !IsVisible || !IsEnabled) return;
            var handler = ReviewRequested;
            if (handler != null) handler();
        }

        protected override AutomationPeer OnCreateAutomationPeer() => new SosAutomationPeer(this);

        private sealed class SosAutomationPeer : SliderAutomationPeer, IInvokeProvider
        {
            private readonly SosSlider _slider;
            internal SosAutomationPeer(SosSlider slider) : base(slider) { _slider = slider; }
            public override object GetPattern(PatternInterface patternInterface) =>
                patternInterface == PatternInterface.Invoke ? this : base.GetPattern(patternInterface);
            protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Button;
            public void Invoke()
            {
                long revision = System.Threading.Interlocked.Read(ref _slider._reviewRevision);
                _slider.Dispatcher.BeginInvoke(new Action(() => _slider.RequestReview(revision)));
            }
        }
    }
}
