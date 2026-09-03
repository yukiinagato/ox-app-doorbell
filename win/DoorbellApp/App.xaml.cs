using System;
using System.IO;
using System.Collections.Generic;
using System.Threading.Tasks;
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
        public static bool SafeMode { get; private set; }
        private WatchdogHeartbeat _heartbeat;
        private RuntimeProcessState _runtimeProcess;
        private DispatcherTimer _runtimeStatusTimer;
        private bool _uiRunning;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            DispatcherUnhandledException += OnUnhandled;
            if (WindowsFirewall.IsRepairRequest(e.Args))
            {
                Shutdown(WindowsFirewall.Configure(WindowsFirewall.PortsFromArguments(e.Args)) ? 0 : 1);
                return;
            }
            SafeMode = e.Args != null && Array.IndexOf(e.Args, "--safe-mode") >= 0;

            DataDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Doorbell");
            Directory.CreateDirectory(DataDir);
            _runtimeProcess = RuntimeProcessState.Begin(
                Path.Combine(DataDir, "runtime-process-v1.json"));
            try { File.Delete(Path.Combine(DataDir, "admin_unlocked.flag")); } catch { }
            Boot = BootConfig.Load(Path.Combine(DataDir, "boot.json"));
            L10n.SetLanguage(Boot.UiLang);
            if (Boot.SetupRequired)
            {
                var setup = new BootstrapSetupWindow(Boot);
                if (setup.ShowDialog() != true || setup.ResultConfig == null)
                {
                    Shutdown(0);
                    return;
                }
                Boot = setup.ResultConfig;
                L10n.SetLanguage(Boot.UiLang);
            }

            Core = new CoreClient();
            Core.UiEventReceived += OnCoreLifecycleEvent;
            if (!Core.Start(DataDir, Boot.RawJson))
            {
                _runtimeProcess.RecordExit("core_start_failed");
                MessageBox.Show("core の起動に失敗しました。ログを確認してください。", "Doorbell",
                                MessageBoxButton.OK, MessageBoxImage.Error);
                Shutdown(1);
                return;
            }
            _heartbeat = new WatchdogHeartbeat();
            Core.PublishRuntimeContracts(Boot.Role, SafeMode);
            PublishRuntimeHealth();
            Texts.SetConfig(Core.Config());
            Texts.SetLang(Boot.UiLang);

            var w = new MainWindow();
            MainWindow = w;
            w.Show();
            Dispatcher.BeginInvoke(new Action(CheckWindowsFirewall));
            _uiRunning = true;
            PublishRuntimeHealth();
            _runtimeStatusTimer = new DispatcherTimer(
                TimeSpan.FromSeconds(10), DispatcherPriority.Background,
                (sender, args) => PublishRuntimeHealth(), Dispatcher);
            _runtimeStatusTimer.Start();
        }

        private void PublishRuntimeHealth()
        {
            if (Core == null || _runtimeProcess == null) return;
            Core.PublishRuntimeHealth(Boot.Role, SafeMode, _runtimeProcess.Snapshot(),
                _heartbeat != null && _heartbeat.Available,
                _heartbeat == null ? 0L : _heartbeat.LastSignalWallMs, _uiRunning);
        }

        private void CheckWindowsFirewall()
        {
            var ports = new FirewallPorts(Boot.ListenPort, Boot.HttpPort, 47171,
                Core.SipAvailable ? FirewallPort(CoreClient.Dig(Core.Config(), "sip.direct_port"),
                                                  47190) : 0);
            FirewallStatus status = WindowsFirewall.Check(ports);
            if (status == FirewallStatus.Allowed) return;
            if (status == FirewallStatus.Unavailable)
            {
                MessageBox.Show(MainWindow, Texts.T("firewall.check_unavailable"),
                    Texts.T("firewall.title"), MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            if (MessageBox.Show(MainWindow, Texts.T("firewall.rules_missing"),
                Texts.T("firewall.title"), MessageBoxButton.YesNo, MessageBoxImage.Warning) !=
                MessageBoxResult.Yes) return;
            Task.Factory.StartNew(() => WindowsFirewall.RequestRepair(ports)).ContinueWith(task =>
                Dispatcher.BeginInvoke(new Action(() => MessageBox.Show(MainWindow,
                    task.Status == TaskStatus.RanToCompletion && task.Result ?
                        Texts.T("firewall.repaired") : Texts.T("firewall.repair_failed"),
                    Texts.T("firewall.title"), MessageBoxButton.OK,
                    task.Status == TaskStatus.RanToCompletion && task.Result ?
                        MessageBoxImage.Information : MessageBoxImage.Warning))));
        }

        private static int FirewallPort(object value, int fallback)
        {
            int port;
            return value != null && int.TryParse(value.ToString(), out port) && port > 0 &&
                port < 65536 ? port : fallback;
        }

        /// <summary>Drops psk_ref and seed_peers from boot.json after an unpair or a revoke.</summary>
        internal static void ClearPairingBootReference()
        {
            if (Boot == null || string.IsNullOrEmpty(Boot.PskRef)) return;
            if (BootConfig.ClearPairingReference(Boot.FilePath))
                Boot = BootConfig.Load(Boot.FilePath);
        }

        /// <summary>
        /// Revoke, and "leave the Cluster" confirmed on this device, are a factory reset
        /// (spec 5.4): the DPAPI mesh key, the boot.json pairing fields, and the operator's own
        /// name/role/door/setup_complete confirmation are all removed, then the app restarts into
        /// first-run setup. A watchdog-managed install is restarted by the watchdog; without one
        /// the process relaunches itself so a kiosk never sits on a blank screen.
        /// </summary>
        internal static void FactoryResetAndRestart(string reason)
        {
            if (_factoryResetStarted) return;
            _factoryResetStarted = true;
            var app = Current as App;
            try { Core?.DeleteSecret("mesh.psk"); } catch { }
            try { if (Boot != null) BootConfig.ResetToFactory(Boot.FilePath); } catch { }
            try
            {
                File.AppendAllText(Path.Combine(DataDir, "pairing-error.log"),
                    DateTime.UtcNow.ToString("o") + " factory_reset " + (reason ?? "") +
                    Environment.NewLine);
            }
            catch { }
            if (app != null) app._runtimeProcess?.RecordExit("factory_reset");
            bool watchdog = app != null && app._heartbeat != null && app._heartbeat.Available;
            if (!watchdog)
            {
                try
                {
                    string exe = System.Reflection.Assembly.GetEntryAssembly() == null ? null :
                        System.Reflection.Assembly.GetEntryAssembly().Location;
                    if (!string.IsNullOrEmpty(exe)) System.Diagnostics.Process.Start(exe);
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Debug.WriteLine("relaunch after factory reset failed: " +
                                                       ex.Message);
                }
            }
            // Shutdown must run on the UI thread; core delivers this event on its own thread.
            if (app != null)
                app.Dispatcher.BeginInvoke(new Action(() => app.Shutdown(0)));
        }

        private static bool _factoryResetStarted;

        private void OnCoreLifecycleEvent(UiEvent ev)
        {
            if (ev == null) return;
            if (ev.T == "pairing_persistence_error")
            {
                ReportPairingPersistenceFailure("Core secure-store callback failed");
                return;
            }
            if (ev.T == "pairing_revoked")
            {
                // Removed by an administrator: wipe the key, the pairing reference and this
                // device's own setup, then come back in first-run setup.
                FactoryResetAndRestart("pairing_revoked");
                return;
            }
            if (ev.T == "pairing_state")
            {
                // Leaving the Cluster must not leave a boot reference to a secret that is gone.
                // A device that had been paired is reset the same way a revoke resets it; a device
                // that was never paired simply starts out unpaired and is left alone.
                if (ev.Str("state") == "unpaired")
                {
                    if (Boot != null && !string.IsNullOrEmpty(Boot.PskRef))
                        FactoryResetAndRestart("unpaired");
                    else ClearPairingBootReference();
                }
                return;
            }
            if (ev.T != "paired" || ev.Data == null) return;
            string secretRef = ev.Str("psk_ref");
            var seeds = new List<string>();
            object raw;
            if (ev.Data.TryGetValue("seeds", out raw) && raw is System.Collections.IEnumerable &&
                !(raw is string))
                foreach (object value in (System.Collections.IEnumerable)raw)
                    if (value != null && !string.IsNullOrWhiteSpace(value.ToString()))
                        seeds.Add(value.ToString());
            if (secretRef != "secret:mesh.psk")
            {
                ReportPairingPersistenceFailure("Core did not confirm secure mesh.psk storage");
                return;
            }
            string updated = BootConfig.PersistPairingReference(Boot.FilePath, seeds);
            if (updated != null)
            {
                Boot = BootConfig.Load(Boot.FilePath);
                System.Diagnostics.Debug.WriteLine("paired: boot.json persisted atomically");
            }
            else
            {
                ReportPairingPersistenceFailure("boot.json secure-reference persistence failed");
            }
        }

        private void ReportPairingPersistenceFailure(string detail)
        {
            System.Diagnostics.Debug.WriteLine("paired: " + detail);
            try
            {
                File.AppendAllText(Path.Combine(DataDir, "pairing-error.log"),
                    DateTime.UtcNow.ToString("o") + " " + detail + Environment.NewLine);
            }
            catch { }
            Dispatcher.BeginInvoke(new Action(() => MessageBox.Show(MainWindow,
                "Pairing succeeded but secure persistence failed. The device has not been " +
                "marked ready; check pairing-error.log and free disk/permissions.",
                "Doorbell pairing", MessageBoxButton.OK, MessageBoxImage.Error)));
        }

        private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
        {
            _runtimeProcess?.RecordExit("unhandled_exception");
            PublishRuntimeHealth();
            File.AppendAllText(Path.Combine(DataDir, "crash.log"),
                DateTime.Now + " " + e.Exception + Environment.NewLine);
            // Keep the exception unhandled so the service watchdog applies bounded restart policy.
        }

        protected override void OnExit(ExitEventArgs e)
        {
            _runtimeStatusTimer?.Stop();
            _runtimeProcess?.RecordExit("clean_exit");
            _uiRunning = false;
            PublishRuntimeHealth();
            _heartbeat?.Dispose();
            Core?.Dispose();
            base.OnExit(e);
        }
    }
}
