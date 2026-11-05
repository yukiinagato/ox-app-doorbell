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
