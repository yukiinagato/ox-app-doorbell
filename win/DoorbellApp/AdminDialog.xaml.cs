using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp
{
    /// <summary>
    /// The single cluster 管理パスワード (spec 5.5). Core verifies it constant-time and
    /// rate-limited, sharing the lockout with the web login. A Core that cannot answer — because
    /// it predates the export or because the cluster has no password yet — falls back to this
    /// device's local digest, and a successful local entry publishes that digest as the shared
    /// secret so the migration happens on first use. Five local failures lock the keypad for ten
    /// minutes even when core is answering.
    /// </summary>
    public partial class AdminDialog : Window
    {
        private const int MaxLen = 128;
        private static int _fails;
        private static DateTime _lockedUntil = DateTime.MinValue;

        public AdminDialog()
        {
            InitializeComponent();
            Prompt.Text = L10n.T("admin.pin_prompt");
            CancelBtn.Content = L10n.T("calling.cancel");
            KeyDown += OnPhysicalKey;
            Loaded += (sender, args) => PasswordEntry.Focus();
        }

        private void OnPad(object sender, RoutedEventArgs e)
        {
            var tag = (sender as Button)?.Tag as string;
            if (string.IsNullOrEmpty(tag)) return;
            HandleKey(tag);
        }

        private void OnPhysicalKey(object sender, KeyEventArgs e)
        {
            // The password box takes ordinary typing itself; only the keypad shortcuts are needed.
            if (e.Key == Key.Enter) HandleKey("ok");
            else if (e.Key == Key.Escape) DialogResult = false;
        }

        private void HandleKey(string tag)
        {
            if (tag == "ok")
            {
                Submit();
                return;
            }
            string current = PasswordEntry.Password ?? "";
            if (tag == "back")
            {
                if (current.Length > 0) current = current.Substring(0, current.Length - 1);
            }
            else if (current.Length < MaxLen)
            {
                current += tag;
            }
            PasswordEntry.Password = current;
            ErrorText.Text = "";
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

        /// <summary>The device digest that predates the replicated cluster password.</summary>
        private static string LocalDigest()
        {
            try
            {
                var f = Path.Combine(App.DataDir, "exit_pin.txt");
                if (File.Exists(f)) return File.ReadAllText(f).Trim();
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            return Sha256Hex("000000");
        }

        private void Submit()
        {
            if (DateTime.Now < _lockedUntil)
            {
                Reject(L10n.T("admin.locked"));
                return;
            }
            string password = PasswordEntry.Password ?? "";
            if (password.Length == 0)
            {
                Reject(L10n.T("admin.pin_wrong"));
                return;
            }

            AdminPasswordVerdict verdict = App.Core == null ?
                AdminPasswordVerdict.Unavailable : App.Core.AdminPasswordVerify(password);
            if (verdict == AdminPasswordVerdict.Accepted)
            {
                Accept();
                return;
            }
            if (verdict == AdminPasswordVerdict.Rejected)
            {
                CountFailure();
                return;
            }
            // Core could not evaluate. A cluster that already carries a password hash must not be
            // opened with a stale device digest, so only an unconfigured cluster falls back.
            bool clusterPassword = App.Core != null && App.Core.AdminPasswordAvailable &&
                                   App.Core.AdminPasswordConfigured;
            if (clusterPassword)
            {
                CountFailure();
                return;
            }
            if (Sha256Hex(password) != LocalDigest())
            {
                CountFailure();
                return;
            }
            // First successful local entry publishes this device's secret as the cluster password.
            if (App.Core != null && App.Core.AdminPasswordAvailable &&
                !App.Core.AdminPasswordSet("", password))
                System.Diagnostics.Debug.WriteLine(
                    "cluster admin password was not published; local digest still applies");
            Accept();
        }

        private void Accept()
        {
            _fails = 0;
            DialogResult = true;
        }

        private void CountFailure()
        {
            if (++_fails >= 5)
            {
                _fails = 0;
                _lockedUntil = DateTime.Now.AddMinutes(10);
                Reject(L10n.T("admin.locked"));
                return;
            }
            Reject(L10n.T("admin.pin_wrong"));
        }

        private void Reject(string message)
        {
            ErrorText.Text = message;
            PasswordEntry.Password = "";
            PasswordEntry.Focus();
        }

        private void OnCancel(object sender, RoutedEventArgs e) => DialogResult = false;
    }
}
