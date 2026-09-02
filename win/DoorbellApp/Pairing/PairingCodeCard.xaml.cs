using System;
using System.Windows;
using System.Windows.Controls;
using DoorbellApp.Util;

namespace DoorbellApp.Pairing
{
    /// <summary>
    /// "Add with a Pairing PIN" card. Everything it shows comes from pairing.token, so reopening a
    /// panel redraws a live PIN and a ticking countdown instead of a stale one-shot dialog.
    /// </summary>
    public partial class PairingCodeCard : UserControl
    {
        /// <summary>Raised when the operator asks for a fresh PIN after expiry or burn.</summary>
        public event Action NewCodeRequested;

        public PairingCodeCard()
        {
            InitializeComponent();
            ApplyStrings();
        }

        public void ApplyStrings()
        {
            AddressLabel.Text = Texts.T("pair.address_label");
            AddressExample.Text = Texts.T("pair.address_example");
            AddressCopyButton.Content = Texts.T("pair.copy");
            CodeLabel.Text = Texts.T("pair.code_label");
            CodeCopyButton.Content = Texts.T("pair.copy");
            Instructions.Text = Texts.T("pair.code_instructions");
            ExpiredText.Text = Texts.T("pair.code_expired");
            NewCodeButton.Content = Texts.T("pair.add_with_code");
        }

        /// <summary>Re-renders the card from a fresh pairing snapshot.</summary>
        public void Apply(PairingSnapshot snapshot)
        {
            if (snapshot == null) return;
            AddressValue.Text = string.IsNullOrEmpty(snapshot.TokenHost) ?
                snapshot.SelfAddr : snapshot.TokenHost;
            if (snapshot.TokenActive)
            {
                CodeValue.Text = FormatPin(snapshot.TokenPin);
                CountdownText.Text = PairingText.Countdown(snapshot.TokenExpiresS);
                AttemptsText.Text = Texts.T("pair.code_attempts_left",
                                            Math.Max(0, snapshot.TokenAttemptsLeft).ToString());
                CountdownText.Visibility = Visibility.Visible;
                AttemptsText.Visibility = Visibility.Visible;
                Instructions.Visibility = Visibility.Visible;
                ExpiredPanel.Visibility = Visibility.Collapsed;
            }
            else
            {
                CodeValue.Text = "— — —";
                CountdownText.Visibility = Visibility.Collapsed;
                AttemptsText.Visibility = Visibility.Collapsed;
                Instructions.Visibility = Visibility.Collapsed;
                ExpiredPanel.Visibility = Visibility.Visible;
            }
        }

        private static string FormatPin(string pin)
        {
            if (string.IsNullOrEmpty(pin)) return "— — —";
            return pin.Length == 6 ? pin.Substring(0, 3) + " " + pin.Substring(3) : pin;
        }

        private void OnCopyAddress(object sender, RoutedEventArgs e)
        {
            CopyToClipboard(AddressValue.Text);
        }

        private void OnCopyCode(object sender, RoutedEventArgs e)
        {
            CopyToClipboard(CodeValue.Text.Replace(" ", ""));
        }

        private static void CopyToClipboard(string value)
        {
            if (string.IsNullOrEmpty(value)) return;
            try { Clipboard.SetText(value); }
            catch (Exception ex)
            {
                // A locked clipboard must never break the pairing flow; the value stays readable.
                System.Diagnostics.Debug.WriteLine("clipboard copy failed: " + ex.Message);
            }
        }

        private void OnNewCode(object sender, RoutedEventArgs e)
        {
            var handler = NewCodeRequested;
            if (handler != null) handler();
        }
    }
}
