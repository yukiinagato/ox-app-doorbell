using System;
using System.IO;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp
{
    public partial class App : Application
    {
        // Exit codes the supervisor understands (win/watchdog/recovery_policy.h).
        public const int ExitClean = 0;
        public const int ExitRestartRequested = 3;
        public const int ExitSessionEnded = 4;
        public const int ExitAlreadyRunning = 5;

        public static CoreClient Core { get; private set; }
        public static string DataDir { get; private set; }
        public static BootConfig Boot { get; private set; }
        public static bool SafeMode { get; private set; }
        /// <summary>True when the watchdog service launched this process.</summary>
        public static bool Supervised { get; private set; }
        internal static WatchdogChannel Watchdog { get; private set; }
        private CameraProbe _cameraProbe;
        private RuntimeProcessState _runtimeProcess;
        private DispatcherTimer _runtimeStatusTimer;
        private bool _uiRunning;
        private static Mutex _instance;
        private static bool _instanceOwned;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            DispatcherUnhandledException += OnUnhandled;
            if (WindowsFirewall.IsRepairRequest(e.Args))
            {
                Shutdown(WindowsFirewall.Configure(WindowsFirewall.PortsFromArguments(e.Args)) ? 0 : 1);
                return;
            }
            Supervised = e.Args.Contains("--supervised");
            SafeMode = e.Args.Contains("--safe-mode");
            int waitForPid = WaitForPidArgument(e.Args);

            DataDir = ResolveDataDir();
            Boot = BootConfig.Load(Path.Combine(DataDir, "boot.json"));
            L10n.SetLanguage(Boot.UiLang);
            if (!AcquireSingleInstance(waitForPid))
            {
                if (!Supervised)
                    MessageBox.Show(L10n.T("app.already_running"), "Doorbell",
                                    MessageBoxButton.OK, MessageBoxImage.Information);
                Shutdown(ExitAlreadyRunning);
                return;
            }
            // Loopback media connections are long-lived; the default of two per host would let a
            // live stream and a fallback stream starve the next request.
            ServicePointManager.DefaultConnectionLimit = 16;
            _runtimeProcess = RuntimeProcessState.Begin(
                Path.Combine(DataDir, "runtime-process-v1.json"));
            // First-run setup opens before Core can publish an appearance.
            Appearance.ApplySystemDefault();
            if (Boot.SetupRequired)
            {
                var setup = new BootstrapSetupWindow(Boot);
                if (setup.ShowDialog() != true || setup.ResultConfig == null)
                {
                    Shutdown(ExitClean);
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
                MessageBox.Show(L10n.T("app.core_start_failed"), "Doorbell",
                                MessageBoxButton.OK, MessageBoxImage.Error);
                Shutdown(1);
                return;
            }
            Watchdog = new WatchdogChannel(Dispatcher, Supervised);
            Watchdog.ExitRequested += reason =>
                Dispatcher.BeginInvoke(new Action(() => ExitForSupervisor(reason)));
            // The capture device may appear or disappear while the app runs, so caps.camera is
            // watched rather than sampled once at startup.
            _cameraProbe = new CameraProbe(Boot.HttpPort, OnCameraAvailabilityChanged);
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

        private static int WaitForPidArgument(string[] args)
        {
            for (int i = 0; i + 1 < args.Length; i++)
            {
                int pid;
                if (args[i] == "--wait-for-pid" && int.TryParse(args[i + 1], out pid) && pid > 0)
                    return pid;
            }
            return 0;
        }

        /// <summary>
        /// One instance per device, across console sessions: two would fight over the mesh and
        /// HTTP ports and the SQLite store. A relaunch after a factory reset passes the old PID
        /// and waits for that process to release everything first.
        /// </summary>
        private static bool AcquireSingleInstance(int waitForPid)
        {
            if (waitForPid > 0)
            {
                try
                {
                    using (var previous = System.Diagnostics.Process.GetProcessById(waitForPid))
                        previous.WaitForExit(30000);
                }
                catch (ArgumentException) { }
                catch (InvalidOperationException) { }
            }
            try
            {
                _instance = new Mutex(false, @"Global\DoorbellApp.Instance.v1");
                try { _instanceOwned = _instance.WaitOne(waitForPid > 0 ? 30000 : 0, false); }
                catch (AbandonedMutexException) { _instanceOwned = true; }
            }
            catch (UnauthorizedAccessException)
            {
                // Another user's instance holds the name.
                _instanceOwned = false;
            }
            return _instanceOwned;
        }

        /// <summary>
        /// The app's data lives in %ProgramData%\Doorbell\data. The installer gives that
        /// directory to the app's users and keeps the parent and the supervisor's own directory
        /// administrator-only. Files left at the old top level by an earlier version are moved in
        /// once, so a manual (non-installer) upgrade keeps its pairing and history.
        /// </summary>
        private static string ResolveDataDir()
        {
            string root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Doorbell");
            string data = Path.Combine(root, "data");
            Directory.CreateDirectory(data);
            if (File.Exists(Path.Combine(data, "boot.json")) ||
                !File.Exists(Path.Combine(root, "boot.json")))
                return data;
            var skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                "data", "service", "watchdog-state.txt", "watchdog-state.txt.tmp", "watchdog.log",
                "admin_unlocked.flag", "updates",
            };
            foreach (string entry in Directory.EnumerateFileSystemEntries(root))
            {
                string name = Path.GetFileName(entry);
                if (skip.Contains(name)) continue;
                try
                {
                    string target = Path.Combine(data, name);
                    if (Directory.Exists(entry)) Directory.Move(entry, target);
                    else File.Move(entry, target);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            return data;
        }

        /// <summary>
        /// Runs on the probe's own timer thread. CoreClient serialises native access, so the
        /// republish needs no dispatcher hop.
        /// </summary>
        private void OnCameraAvailabilityChanged(bool available)
        {
            if (Core == null) return;
            Core.CameraAvailable = available;
            Core.PublishRuntimeContracts(Boot.Role, SafeMode);
        }

        private void PublishRuntimeHealth()
        {
            if (Core == null || _runtimeProcess == null) return;
            Core.PublishRuntimeHealth(Boot.Role, SafeMode, _runtimeProcess.Snapshot(),
                Watchdog != null && Watchdog.Available,
                Watchdog == null ? 0L : Watchdog.LastSignalWallMs, _uiRunning);
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
        /// first-run setup. Under the watchdog the exit code asks for an immediate restart, which
        /// is not counted as a crash. Without one the process relaunches itself; the new process
        /// waits for this one to exit and release its ports and store before it starts Core.
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
            bool watchdog = Watchdog != null && Watchdog.Available;
            if (!watchdog)
            {
                try
                {
                    string exe = System.Reflection.Assembly.GetEntryAssembly() == null ? null :
                        System.Reflection.Assembly.GetEntryAssembly().Location;
                    int pid = System.Diagnostics.Process.GetCurrentProcess().Id;
                    if (!string.IsNullOrEmpty(exe))
                        System.Diagnostics.Process.Start(exe, "--wait-for-pid " + pid);
                }
                catch (Exception ex)
                {
                    CoreClient.WriteAppLog("relaunch after factory reset failed: " + ex.Message);
                }
            }
            // Shutdown must run on the UI thread; core delivers this event on its own thread.
            if (app != null)
                app.Dispatcher.BeginInvoke(new Action(() =>
                    app.Shutdown(watchdog ? ExitRestartRequested : ExitClean)));
        }

        private static bool _factoryResetStarted;

        /// <summary>
        /// Restarts the app after a change that only takes effect at startup (identity, kiosk
        /// mode). Under the watchdog the restart exit code is not a crash; without one the new
        /// process waits for this one to release its ports and store.
        /// </summary>
        internal static void RestartApp(string reason)
        {
            var app = Current as App;
            if (app == null || _factoryResetStarted) return;
            _factoryResetStarted = true;
            app._runtimeProcess?.RecordExit(reason);
            bool watchdog = Watchdog != null && Watchdog.Available;
            if (!watchdog)
            {
                try
                {
                    string exe = System.Reflection.Assembly.GetEntryAssembly() == null ? null :
                        System.Reflection.Assembly.GetEntryAssembly().Location;
                    int pid = System.Diagnostics.Process.GetCurrentProcess().Id;
                    if (!string.IsNullOrEmpty(exe))
                        System.Diagnostics.Process.Start(exe, "--wait-for-pid " + pid);
                }
                catch (Exception ex)
                {
                    CoreClient.WriteAppLog("relaunch failed: " + ex.Message);
                }
            }
            if (app.MainWindow is MainWindow main) main.AllowClose();
            app.Dispatcher.BeginInvoke(new Action(() =>
                app.Shutdown(watchdog ? ExitRestartRequested : ExitClean)));
        }

        /// <summary>The supervisor asked this instance to go: session change or service stop.</summary>
        private void ExitForSupervisor(string reason)
        {
            _runtimeProcess?.RecordExit(reason == "session" ? "session_moved" : "service_stop");
            if (MainWindow is MainWindow main) main.AllowClose();
            Shutdown(reason == "session" ? ExitSessionEnded : ExitClean);
        }

        private void OnCoreLifecycleEvent(UiEvent ev)
        {
            if (ev == null) return;
            if (ev.T == "cluster_key_changed")
            {
                CoreClient.WriteAppLog("cluster key changed to " + ev.Str("psk_id"));
                return;
            }
            if (ev.T == "peer_rejected")
            {
                CoreClient.WriteAppLog("peer rejected: " + ev.Str("id") + " " + ev.Str("reason"));
                return;
            }
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
                CoreClient.WriteAppLog("paired: boot.json persisted atomically");
            }
            else
            {
                ReportPairingPersistenceFailure("boot.json secure-reference persistence failed");
            }
        }

        private void ReportPairingPersistenceFailure(string detail)
        {
            CoreClient.WriteAppLog("paired: " + detail);
            try
            {
                File.AppendAllText(Path.Combine(DataDir, "pairing-error.log"),
                    DateTime.UtcNow.ToString("o") + " " + detail + Environment.NewLine);
            }
            catch { }
            Dispatcher.BeginInvoke(new Action(() => MessageBox.Show(MainWindow,
                L10n.T("pairing.persist_failed_detail"), L10n.T("pairing.persist_failed_title"),
                MessageBoxButton.OK, MessageBoxImage.Error)));
        }

        private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
        {
            _runtimeProcess?.RecordExit("unhandled_exception");
            PublishRuntimeHealth();
            try
            {
                File.AppendAllText(Path.Combine(DataDir, "crash.log"),
                    DateTime.Now + " " + e.Exception + Environment.NewLine);
            }
            catch { }
            // Keep the exception unhandled so the service watchdog applies bounded restart policy.
        }

        protected override void OnExit(ExitEventArgs e)
        {
            _runtimeStatusTimer?.Stop();
            if (!_factoryResetStarted && _runtimeProcess != null &&
                e.ApplicationExitCode == ExitClean)
                _runtimeProcess.RecordExit("clean_exit");
            _uiRunning = false;
            PublishRuntimeHealth();
            // Only deliberate exits are announced; any other code stays a failure for the
            // supervisor's crash-loop accounting.
            if (e.ApplicationExitCode == ExitClean) Watchdog?.ExpectExit("clean");
            else if (e.ApplicationExitCode == ExitRestartRequested) Watchdog?.ExpectExit("restart");
            else if (e.ApplicationExitCode == ExitSessionEnded) Watchdog?.ExpectExit("session");
            _cameraProbe?.Dispose();
            Core?.AdminLock();
            Core?.Dispose();
            Watchdog?.Dispose();
            if (_instanceOwned)
            {
                try { _instance.ReleaseMutex(); } catch (ApplicationException) { }
            }
            _instance?.Dispose();
            base.OnExit(e);
        }
    }
}
