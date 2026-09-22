using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using DoorbellApp.Ui;
using DoorbellApp.Util;

namespace DoorbellApp
{
    public partial class MainWindow
    {
        private readonly VisitorActionGuard _visitorAction = new VisitorActionGuard();
        private readonly SosReviewGuard _sosReview = new SosReviewGuard();
        private bool _sosReviewOpen;

        private void BindVisitorAction(Button button, VisitorActionKind kind)
        {
            long inputRevision = 0;
            Action capture = () => inputRevision = _visitorAction.Begin(_activeCallId, App.Core.Generation,
                                                                       _callViewRevision, kind);
            Action complete = () => {
                long completed = inputRevision;
                // WPF can release capture before raising Click in the same routed input event.
                // Retire after that event returns, before a later queued accessibility activation.
                Dispatcher.BeginInvoke(DispatcherPriority.Send,
                    new Action(() => _visitorAction.CompleteInput(completed)));
            };
            button.PreviewMouseLeftButtonDown += (s, e) => capture();
            button.PreviewTouchDown += (s, e) => capture();
            button.PreviewMouseLeftButtonUp += (s, e) => complete();
            button.PreviewTouchUp += (s, e) => complete();
            button.LostMouseCapture += (s, e) => complete();
            button.LostTouchCapture += (s, e) => complete();
            button.LostKeyboardFocus += (s, e) => complete();
            button.PreviewKeyDown += (s, e) => {
                if (!e.IsRepeat && (e.Key == Key.Space || e.Key == Key.Enter)) capture();
            };
            button.PreviewKeyUp += (s, e) => {
                if (e.Key == Key.Space || e.Key == Key.Enter) complete();
            };
        }

        private bool AllowVisitorAction(VisitorActionKind kind)
        {
            bool available = IsVisible && EmergencyView.Visibility != Visibility.Visible &&
                PairingOverlay.Visibility != Visibility.Visible && SosCountdownView.Visibility != Visibility.Visible;
            bool visible = available && (kind == VisitorActionKind.Cancel
                ? !_inCall && CallingView.Visibility == Visibility.Visible && CancelButton.IsVisible && CancelButton.IsEnabled
                : _inCall && InCallView.Visibility == Visibility.Visible && EndCallButton.IsVisible && EndCallButton.IsEnabled);
            return _visitorAction.Consume(_activeCallId, App.Core.Generation,
                                           _callViewRevision, kind, visible);
        }

        private void OnPurposeSkipClick(object sender, RoutedEventArgs e)
        {
            if (_inCall || CallingView.Visibility != Visibility.Visible || !ShowsCallingPurposes()) return;
            _purposeChosenCallId = _activeCallId;
            CallingPurposeSection.Visibility = Visibility.Collapsed;
        }

        private void OnSosReviewRequested()
        {
            if (_sosReviewOpen || !SosSlide.IsLoaded || !SosSlide.IsVisible ||
                !SosSlide.IsEnabled || _emergencyActive || _sosCountdownLeft > 0) return;
            long revision = _sosReview.Begin(), generation = App.Core.Generation;
            _sosReviewOpen = true;
            MessageBoxResult result;
            try {
                result = MessageBox.Show(this, Texts.T("sos.accessibility_confirm"),
                    Texts.T("sos.accessibility_start"), MessageBoxButton.OKCancel,
                    MessageBoxImage.Warning, MessageBoxResult.Cancel);
            }
            finally { _sosReviewOpen = false; }
            if (_sosReview.Consume(revision, generation, App.Core.Generation,
                    result == MessageBoxResult.OK && SosSlide.IsLoaded && SosSlide.IsVisible &&
                    SosSlide.IsEnabled && !_emergencyActive && _sosCountdownLeft == 0)) OnSosArmed();
        }

        private void UpdateVisitorActionHeights(double width)
        {
            if (width <= 40) width = ActualWidth > 40 ? ActualWidth : SystemParameters.PrimaryScreenWidth;
            double available = Math.Max(1, Math.Min(620, width - 40) - 40);
            double height = 96;
            foreach (var button in new[] { CallButton, CancelButton, EndCallButton, OfflineAction })
            {
                var text = new TextBlock { Text = button.Content as string ?? "", FontSize = button.FontSize,
                    FontFamily = button.FontFamily, FontWeight = button.FontWeight, TextWrapping = TextWrapping.Wrap };
                text.Measure(new Size(available, double.PositiveInfinity));
                height = Math.Max(height, Math.Ceiling(text.DesiredSize.Height + 32));
            }
            foreach (var button in new[] { CallButton, CancelButton, EndCallButton, OfflineAction })
                button.MinHeight = height;
        }
    }
}
