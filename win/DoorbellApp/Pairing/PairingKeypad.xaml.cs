using System;
using System.Windows;
using System.Windows.Controls;

namespace DoorbellApp.Pairing
{
    /// <summary>
    /// Drawn numeric keypad for the Pairing PIN. Door stations and kiosk tablets have no IME and
    /// often no hardware keyboard, so PIN entry never depends on the on-screen system keyboard.
    /// </summary>
    public partial class PairingKeypad : UserControl
    {
        /// <summary>Raises "0".."9", "back" or "clear".</summary>
        public event Action<string> KeyPressed;

        public PairingKeypad()
        {
            InitializeComponent();
        }

        private void OnPad(object sender, RoutedEventArgs e)
        {
            var button = sender as Button;
            string tag = button == null || button.Tag == null ? null : button.Tag.ToString();
            if (string.IsNullOrEmpty(tag)) return;
            var handler = KeyPressed;
            if (handler != null) handler(tag);
        }
    }
}
