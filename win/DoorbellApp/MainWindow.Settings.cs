using DoorbellApp.Settings;

namespace DoorbellApp
{
    // Entry points the native settings window uses; the work itself stays where it lives.
    public partial class MainWindow
    {
        /// <summary>The Admin entry: admin password first, then native settings.</summary>
        private void OpenSettings()
        {
            string nodeId = _nodeId;
            if (string.IsNullOrEmpty(nodeId))
                nodeId = DictStr(DoorbellApp.Core.CoreClient.Dig(App.Core.Status(), "node")
                                 as System.Collections.Generic.Dictionary<string, object>, "id");
            // Without this device's id the per-device keys would resolve to "devices..".
            if (string.IsNullOrEmpty(nodeId)) return;
            var settings = new SettingsWindow(this, nodeId, App.Boot.Role);
            settings.ShowDialog();
            RequestHomeRefresh(HomeRefresh.All);
            if (!_adminUnlocked) App.Core?.AdminLock();
        }

        /// <summary>
        /// True while restarting for an identity change would cut something short: a call in
        /// progress or ringing, an active SOS or its countdown, or pairing onboarding.
        /// </summary>
        internal bool IdentityChangeBlocked
        {
            get
            {
                return _inCall || !string.IsNullOrEmpty(_activeCallId) || _sipMode.Length != 0 ||
                       (IncomingView.Visibility == System.Windows.Visibility.Visible && !_monitorOnly) ||
                       InCallView.Visibility == System.Windows.Visibility.Visible ||
                       _emergencyActive || _sosCountdownLeft > 0 || PairingOverlay.IsActive;
            }
        }

        private string _identityAttempt = "";

        /// <summary>
        /// devices.&lt;self&gt;.name/.role/.door is the remotely editable desired identity (web
        /// Admin, another device). When it differs from what this device booted with, it is
        /// validated, written to boot.json and the app restarts, as on the other shells. It
        /// waits while a call, an SOS or pairing is in progress and is retried on the next
        /// refresh. One identity is attempted once per run, so a record Core does not converge
        /// cannot cause a restart loop.
        /// </summary>
        private void ApplyReplicatedIdentity()
        {
            if (App.Boot == null || string.IsNullOrEmpty(_nodeId) || App.UiTest) return;
            var record = DoorbellApp.Core.CoreClient.Dig(_cfg, "devices." + _nodeId)
                as System.Collections.Generic.Dictionary<string, object>;
            if (record == null) return;
            string name = DictStr(record, "name"), role = DictStr(record, "role"),
                   door = DictStr(record, "door");
            var decision = DoorbellApp.Util.ReplicatedIdentity.Decide(
                App.Boot.Name, App.Boot.Role, App.Boot.Door ?? "", name, role, door,
                BootConfig.ValidRole(role), BootConfig.ValidDoor(door));
            if (!decision.Apply || IdentityChangeBlocked) return;
            string signature = DoorbellApp.Util.ReplicatedIdentity.Signature(
                decision.Name, decision.Role, decision.Door);
            if (signature == _identityAttempt || IdentityAppliedRecently(signature)) return;
            _identityAttempt = signature;
            if (BootConfig.PersistSetup(App.Boot.FilePath, decision.Name, decision.Role,
                                        decision.Door) == null)
            {
                DoorbellApp.Core.CoreClient.WriteAppLog("replicated identity was not persisted");
                return;
            }
            RecordIdentityApplied(signature);
            DoorbellApp.Core.CoreClient.WriteAppLog("replicated identity applied; restarting");
            App.RestartApp("identity_changed");
        }

        private static string IdentityMarkerPath
        {
            get { return System.IO.Path.Combine(App.DataDir, "identity-applied.txt"); }
        }

        // The same identity applied again within two minutes of the last restart means Core did
        // not take it; applying it once more would only restart again.
        private static bool IdentityAppliedRecently(string signature)
        {
            try
            {
                var marker = new System.IO.FileInfo(IdentityMarkerPath);
                return marker.Exists &&
                       (System.DateTime.UtcNow - marker.LastWriteTimeUtc).TotalMinutes < 2 &&
                       System.IO.File.ReadAllText(marker.FullName) == signature;
            }
            catch (System.IO.IOException) { return false; }
            catch (System.UnauthorizedAccessException) { return false; }
        }

        private static void RecordIdentityApplied(string signature)
        {
            try { System.IO.File.WriteAllText(IdentityMarkerPath, signature); }
            catch (System.IO.IOException) { }
            catch (System.UnauthorizedAccessException) { }
        }

        internal void OpenNoticeDialogFromSettings() => OpenNoticeDialog(null);

        internal void OpenAddDevicePanelFromSettings() => OpenAddDevicePanel(true);

        internal void UnlockKioskFromSettings() => UnlockKiosk();

        internal void RelockKioskFromSettings() => RelockKiosk();

        internal bool VideoStatsVisibleForSettings => _showVideoStats;

        internal void SetVideoStatsVisibleFromSettings(bool visible)
        {
            _showVideoStats = visible;
            SaveVideoStatsPreference();
            VideoStatsCard.Visibility = _showVideoStats
                ? System.Windows.Visibility.Visible : System.Windows.Visibility.Collapsed;
        }

        internal void ReapplyLanguageFromSettings()
        {
            ApplyStrings();
            RequestHomeRefresh(HomeRefresh.All);
        }
    }
}
