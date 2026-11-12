using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using DoorbellApp.Util;

namespace DoorbellApp
{
    /// <summary>
    /// The two-step SOS guard (ui-guidelines 4, SOS). The compact trigger only opens a
    /// confirmation card; there the slide control must be moved end to end, or, without a pointer,
    /// "Send SOS" pressed, which never has the default focus. Nothing in the flow is a
    /// press-and-hold. Either confirmation starts the existing cancellable countdown, and Core is
    /// told only when that reaches zero. Clearing an active SOS uses the same slide.
    /// </summary>
    public partial class MainWindow
    {
        /// <summary>The confirmation closes by itself after this long without input.</summary>
        private static readonly TimeSpan SosConfirmTimeout = TimeSpan.FromSeconds(10);
        private DispatcherTimer _sosConfirmTimer;

        private void ApplySosConfirmStrings()
        {
            System.Windows.Automation.AutomationProperties.SetName(SosButton,
                Texts.T("sos.accessibility_start"));
            System.Windows.Automation.AutomationProperties.SetHelpText(SosButton,
                Texts.T("sos.accessibility_hint"));
            ApplyOutlineStates();
            SosConfirmTitle.Text = Texts.T("sos.confirm_title");
            SosConfirmBody.Text = Texts.T("sos.hint");
            SosConfirmSend.Content = Texts.T("sos.send");
            SosConfirmCancel.Content = Texts.T("sos.abort");
            EmergencyClearHint.Text = Texts.T("emergency.clear_confirm");
            EmergencyClearSlideText.Text = Texts.T("sos.slide_to_clear");
            EmergencyClearConfirm.Content = Texts.T("emergency.cancel");
            EmergencyClearBack.Content = Texts.T("sos.abort");
            System.Windows.Automation.AutomationProperties.SetName(EmergencyClearSlide,
                Texts.T("sos.slide_to_clear"));
        }

        /// <summary>
        /// The outlined buttons declared in XAML keep their role colour while hovered or
        /// pressed; redone whenever the appearance changes, because the brushes are per theme.
        /// </summary>
        private void ApplyOutlineStates()
        {
            SosButton.Content = IconLabel("IconAlertTriangle", Texts.T("sos.title"), 18,
                                          (Brush)FindResource("NegativeText"));
            Ui.Fluent.KeepOutlineStates(SosButton, "NegativeText");
            Ui.Fluent.KeepOutlineStates(SosConfirmSend, "NegativeText");
            Ui.Fluent.KeepOutlineStates(IgnoreButton, "NegativeText");
            Ui.Fluent.KeepOutlineStates(OpenDoorButton, "Warning");
            Ui.Fluent.KeepOutlineStates(InCallOpenDoorButton, "Warning");
        }

        /// <summary>SOS can be started: configured for this device, and not already under way.</summary>
        private bool SosTriggerAvailable()
        {
            return SosButton.Visibility == Visibility.Visible && SosButton.IsVisible &&
                   !_emergencyActive && _sosCountdownLeft == 0;
        }

        private void OnSosTriggerClick(object sender, RoutedEventArgs e)
        {
            if (!SosTriggerAvailable() || SosConfirmView.Visibility == Visibility.Visible) return;
            SosSlide.Reset();
            SosConfirmView.Visibility = Visibility.Visible;
            RestartSosConfirmTimeout();
            // Cancel takes the focus, so Enter or Space on a keyboard cannot send by default.
            SosConfirmCancel.Focus();
        }

        private void CloseSosConfirm()
        {
            if (_sosConfirmTimer != null) _sosConfirmTimer.Stop();
            SosConfirmView.Visibility = Visibility.Collapsed;
            SosSlide.Reset();
        }

        private void RestartSosConfirmTimeout()
        {
            if (_sosConfirmTimer == null)
            {
                _sosConfirmTimer = new DispatcherTimer { Interval = SosConfirmTimeout };
                _sosConfirmTimer.Tick += (s, e) => CloseSosConfirm();
            }
            _sosConfirmTimer.Stop();
            _sosConfirmTimer.Start();
        }

        private void OnSosConfirmInput(object sender, InputEventArgs e)
        {
            if (SosConfirmView.Visibility != Visibility.Visible) return;
            RestartSosConfirmTimeout();
            var key = e as KeyEventArgs;
            if (key != null && key.Key == Key.Escape)
            {
                CloseSosConfirm();
                e.Handled = true;
            }
        }

        private void OnSosConfirmCancel(object sender, RoutedEventArgs e) => CloseSosConfirm();

        private void OnSosConfirmSend(object sender, RoutedEventArgs e) => ConfirmSos();

        /// <summary>
        /// The second gesture was completed on the open confirmation: close it and start the
        /// countdown. A slide or press that arrives after the card closed does nothing.
        /// </summary>
        private void ConfirmSos()
        {
            if (SosConfirmView.Visibility != Visibility.Visible || !SosTriggerAvailable()) return;
            CloseSosConfirm();
            OnSosArmed();
        }
    }
}
