// 隠し管理入口の PIN ダイアログ。5 回失敗で 10 分ロック (プロセス内)。
// PIN の照合先: %ProgramData%\Doorbell\exit_pin.txt の SHA-256 hex (無ければ既定 PIN "000000" +
// 初回設置手順で必ず変更するよう docs に記載)。TODO(Phase1後半): fleet 設定の kiosk.exit_pin_hash と統合。
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using DoorbellApp.Util;

namespace DoorbellApp
{
    public partial class AdminDialog : Window
    {
        private static int _fails;
        private static DateTime _lockedUntil = DateTime.MinValue;

        public AdminDialog()
        {
            InitializeComponent();
            Prompt.Text = L10n.T("admin.pin_prompt");
            OkBtn.Content = "OK";
            CancelBtn.Content = L10n.T("calling.cancel");
            Pin.Focus();
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

        private void OnOk(object sender, RoutedEventArgs e)
        {
            if (DateTime.Now < _lockedUntil)
            {
                ErrorText.Text = L10n.T("admin.locked");
                return;
            }
            string expected = Sha256Hex("000000");
            try
            {
                var f = Path.Combine(App.DataDir, "exit_pin.txt");
                if (File.Exists(f)) expected = File.ReadAllText(f).Trim();
            }
            catch { }
            if (Sha256Hex(Pin.Password) == expected)
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
            Pin.Clear();
        }

        private void OnCancel(object sender, RoutedEventArgs e) => DialogResult = false;
    }
}
