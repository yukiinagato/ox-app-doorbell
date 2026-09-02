using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using DoorbellApp.Util;

namespace DoorbellApp
{
    // Five failed PIN attempts lock the process-local keypad for ten minutes. The configured PIN is
    // compared as a SHA-256 digest; deployments must replace the commissioning default.
    public partial class AdminDialog : Window
    {
        private const int MaxLen = 6;
        private static int _fails;
        private static DateTime _lockedUntil = DateTime.MinValue;
        private string _pin = "";

        public AdminDialog()
        {
            InitializeComponent();
            Prompt.Text = L10n.T("admin.pin_prompt");
            CancelBtn.Content = L10n.T("calling.cancel");
            KeyDown += OnPhysicalKey;
            UpdateDisplay();
        }

        private void UpdateDisplay() => PinDisplay.Text = new string('●', _pin.Length);

        private void OnPad(object sender, RoutedEventArgs e)
        {
            var tag = (sender as Button)?.Tag as string;
            if (string.IsNullOrEmpty(tag)) return;
            HandleKey(tag);
        }

        private void OnPhysicalKey(object sender, KeyEventArgs e)
        {
            if (e.Key >= Key.D0 && e.Key <= Key.D9) HandleKey(((int)(e.Key - Key.D0)).ToString());
            else if (e.Key >= Key.NumPad0 && e.Key <= Key.NumPad9)
                HandleKey(((int)(e.Key - Key.NumPad0)).ToString());
            else if (e.Key == Key.Back) HandleKey("back");
            else if (e.Key == Key.Enter) HandleKey("ok");
            else if (e.Key == Key.Escape) DialogResult = false;
        }

        private void HandleKey(string tag)
        {
            if (tag == "back")
            {
                if (_pin.Length > 0) _pin = _pin.Substring(0, _pin.Length - 1);
            }
            else if (tag == "ok")
            {
                Submit();
                return;
            }
            else if (_pin.Length < MaxLen)
            {
                _pin += tag;
            }
            ErrorText.Text = "";
            UpdateDisplay();
        }

        private static string Sha256Hex(string s)
        {
            using (var sha = SHA256.Create())
            {
                var b = sha.ComputeHash(Encoding.UTF8.GetBytes(s));
                var sb = new StringBuilder(b.Length * 2);
                foreach (var x in b) sb.Append(x.ToString("x2"));
                return sb.ToString();
            }
        }

        private void Submit()
        {
            if (DateTime.Now < _lockedUntil)
            {
                ErrorText.Text = L10n.T("admin.locked");
                _pin = "";
                UpdateDisplay();
                return;
            }
            string expected = Sha256Hex("000000");
            try
            {
                var f = Path.Combine(App.DataDir, "exit_pin.txt");
                if (File.Exists(f)) expected = File.ReadAllText(f).Trim();
            }
            catch { }
            if (Sha256Hex(_pin) == expected)
            {
                _fails = 0;
                DialogResult = true;
                return;
            }
            if (++_fails >= 5)
            {
                _fails = 0;
                _lockedUntil = DateTime.Now.AddMinutes(10);
                ErrorText.Text = L10n.T("admin.locked");
            }
            else
            {
                ErrorText.Text = L10n.T("admin.pin_wrong");
            }
            _pin = "";
            UpdateDisplay();
        }

        private void OnCancel(object sender, RoutedEventArgs e) => DialogResult = false;
    }
}
