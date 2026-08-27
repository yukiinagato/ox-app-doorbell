// 起動: boot.json (%ProgramData%\Doorbell\boot.json) を読み core を起動、全画面 kiosk へ。
using System;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp
{
    public partial class App : Application
    {
        public static CoreClient Core { get; private set; }
        public static string DataDir { get; private set; }
        public static BootConfig Boot { get; private set; }

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            DispatcherUnhandledException += OnUnhandled;

            DataDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Doorbell");
            Directory.CreateDirectory(DataDir);
            // 前回の管理解錠 flag を掃除 — 再起動でロック状態 (watchdog 前台守衛有効) に戻る
            try { File.Delete(Path.Combine(DataDir, "admin_unlocked.flag")); } catch { }
            Boot = BootConfig.Load(Path.Combine(DataDir, "boot.json"));
            L10n.SetLanguage(Boot.UiLang);

            Core = new CoreClient();
            if (!Core.Start(DataDir, Boot.RawJson))
            {
                MessageBox.Show("core の起動に失敗しました。ログを確認してください。", "Doorbell",
                                MessageBoxButton.OK, MessageBoxImage.Error);
                Shutdown(1);
                return;
            }
            // 文言解決 (i18n_overrides の前段) を core 設定と結線してから画面を作る
            Texts.SetConfig(Core.Config());
            Texts.SetLang(Boot.UiLang);

            var w = new MainWindow();
            MainWindow = w;
            w.Show();
        }

        private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
        {
            // kiosk 機: 例外で固まるより落ちて watchdog に再起動させる
            File.AppendAllText(Path.Combine(DataDir, "crash.log"),
                DateTime.Now + " " + e.Exception + Environment.NewLine);
        }

        protected override void OnExit(ExitEventArgs e)
        {
            Core?.Dispose();
            base.OnExit(e);
        }
    }
}
