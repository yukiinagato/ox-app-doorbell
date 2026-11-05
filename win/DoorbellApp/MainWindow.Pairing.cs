using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Media;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Kiosk;
using DoorbellApp.Pairing;
using DoorbellApp.Util;


namespace DoorbellApp
{
    // Pairing state, the Add-device panel and the hidden admin corner.
    public partial class MainWindow
    {
        // Pairing is core-authoritative: this window renders pairing.state and never infers it.
        private void HandlePairingEvent(UiEvent ev)
        {
            switch (ev.T)
            {
                case "pairing_revoked":
                    // App owns the factory reset for a revoke (spec 5.4); this view only renders.
                    _pairingSkipped = false;
                    ShowPairingOverlay();
                    PairingOverlay.HandleCoreEvent(ev);
                    RequestHomeRefresh(HomeRefresh.Pairing);
                    return;
                case "pairing_state":
                case "paired":
                case "join_result":
                case "invite_rejected":
                case "pairing_persistence_error":
                case "join_token_changed":
                case "pending_changed":
                    PairingOverlay.HandleCoreEvent(ev);
                    RequestHomeRefresh(HomeRefresh.Pairing);
                    return;
            }
        }

        private void RefreshPairingState(Dictionary<string, object> pairing)
        {
            var snapshot = PairingSnapshot.From(pairing);
            // {} means core has not published a snapshot yet: unknown, so do not show onboarding.
            if (!snapshot.Known) return;
            _pairing = snapshot;
            bool ready = _pairing.IsReady;
            if (ready) _pairingSkipped = false;
            if (!ready && !_pairingSkipped && !PairingOverlay.IsActive) ShowPairingOverlay();

            PairBanner.Visibility = !ready && !PairingOverlay.IsActive ?
                Visibility.Visible : Visibility.Collapsed;
            MembershipStatus.Visibility = ready && !PairingOverlay.IsActive ?
                Visibility.Visible : Visibility.Collapsed;
            RefreshDeviceCounters();
        }

        private void ShowPairingOverlay()
        {
            PairBanner.Visibility = Visibility.Collapsed;
            MembershipStatus.Visibility = Visibility.Collapsed;
            PairingOverlay.Activate();
        }

        private void OnPairingDismissed()
        {
            _pairingSkipped = true;
            PairingOverlay.Deactivate();
            RequestHomeRefresh(HomeRefresh.Pairing);
        }

        private void OnPairBannerClick(object sender, MouseButtonEventArgs e)
        {
            _pairingSkipped = false;
            ShowPairingOverlay();
        }

        private void OnMembershipClick(object sender, MouseButtonEventArgs e)
        {
            OpenAddDevicePanel();
        }

        /// <summary>Opens the Add-device panel, behind the admin password on a kiosk.</summary>
        private void OpenAddDevicePanel()
        {
            if (App.Boot.Kiosk && !_adminUnlocked)
            {
                var prompt = new AdminDialog { Owner = this };
                if (prompt.ShowDialog() != true) return;
            }
            var panel = new AddDeviceWindow { Owner = this, Topmost = Topmost };
            panel.ShowDialog();
            if (panel.OnboardingRequested)
            {
                _pairingSkipped = false;
                ShowPairingOverlay();
                return;
            }
            RequestHomeRefresh(HomeRefresh.Pairing);
        }

        private void OnSecretCorner(object sender, MouseButtonEventArgs e)
        {
            var now = DateTime.Now;
            if ((now - _secretFirst).TotalSeconds > 5) { _secretFirst = now; _secretTaps = 0; }
            if (++_secretTaps < 7) return;
            _secretTaps = 0;
            var dlg = new AdminDialog { Owner = this };
            if (dlg.ShowDialog() == true)
            {
                _adminUnlocked = true;
                _kiosk?.Disable();
                Topmost = false;
                WindowState = WindowState.Normal;
                WindowStyle = WindowStyle.SingleBorderWindow;
                ResizeMode = ResizeMode.CanResize;
                try
                {
                    File.WriteAllText(Path.Combine(App.DataDir, "admin_unlocked.flag"),
                                      DateTime.Now.ToString("s"));
                }
                catch {  }
            }
        }
    }
}
