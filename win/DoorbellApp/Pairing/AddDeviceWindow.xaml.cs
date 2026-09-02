using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp.Pairing
{
    /// <summary>
    /// "Add device" panel for state ready (spec 5.1): nearby devices, the Pairing-PIN card, bulk
    /// add, the QR scanner, this device's own QR, and leaving the Cluster. Callers gate it behind
    /// the admin password wherever kiosk gating applies.
    /// </summary>
    public partial class AddDeviceWindow : Window
    {
        private const int PairingModeSeconds = 600;
        private const int TokenSeconds = 600;
        private const int AddedRowLingerSeconds = 3;

        private readonly ObservableCollection<PendingDeviceRow> _rows =
            new ObservableCollection<PendingDeviceRow>();
        private readonly Dictionary<string, PendingDeviceRow> _byId =
            new Dictionary<string, PendingDeviceRow>();
        private readonly List<string> _joinedRows = new List<string>();
        private readonly DispatcherTimer _poll = new DispatcherTimer();
        private readonly DispatcherTimer _joinedSweep = new DispatcherTimer();
        private readonly Action<UiEvent> _eventHandler;

        private PairingSnapshot _snapshot = new PairingSnapshot();
        private string _renderedQr = "";
        private bool _codeCardOpen;

        /// <summary>Set when an unpaired node asks the caller to reopen onboarding instead.</summary>
        public bool OnboardingRequested { get; private set; }

        public AddDeviceWindow()
        {
            InitializeComponent();
            Title = Texts.T("app.name");
            NearbyList.ItemsSource = _rows;
            ApplyStrings();

            CodeCard.NewCodeRequested += OnNewCodeRequested;

            _poll.Interval = TimeSpan.FromSeconds(1);
            _poll.Tick += (sender, args) => Refresh();
            _joinedSweep.Interval = TimeSpan.FromSeconds(AddedRowLingerSeconds);
            _joinedSweep.Tick += (sender, args) => SweepJoinedRows();

            _eventHandler = ev => Dispatcher.BeginInvoke(
                new Action(() => OnCoreEvent(ev)));

            Loaded += (sender, args) =>
            {
                App.Core.UiEventReceived += _eventHandler;
                Refresh();
                _poll.Start();
            };
            Closed += (sender, args) =>
            {
                App.Core.UiEventReceived -= _eventHandler;
                _poll.Stop();
                _joinedSweep.Stop();
            };
        }

        private void ApplyStrings()
        {
            CloseButton.Content = Texts.T("monitor.close");
            NearbyTitle.Text = Texts.T("pair.nearby_title");
            NearbyEmptyText.Text = Texts.T("pair.nearby_none");
            AddWithCodeButton.Content = Texts.T("pair.add_with_code");
            AddAllTitle.Text = Texts.T("pair.add_all");
            AddAllWarning.Text = Texts.T("pair.add_all_warning");
            AddAllButton.Content = Texts.T("pair.add_all");
            ScanQrButton.Content = Texts.T("pair.scan_qr");
            OwnQrTitle.Text = Texts.T("pair.qr_caption");
            OwnQrPlaceholder.Text = Texts.T("pair.searching");
            ClearTitle.Text = Texts.T("pair.clear_title");
            ClearButton.Content = Texts.T("pair.clear_title");
            ClearConfirmText.Text = Texts.T("pair.clear_confirm");
            ClearConfirmYes.Content = Texts.T("pair.clear_title");
            ClearConfirmNo.Content = Texts.T("admin.cancel");
            CreatedBadgeText.Text = Texts.T("pair.created_badge");
            UnpairedText.Text = Texts.T("pair.searching_hint");
            UnpairedCreateButton.Content = Texts.T("pair.create_home");
            UnpairedJoinButton.Content = Texts.T("pair.join_with_code");
            CodeCard.ApplyStrings();
        }

        private void OnCoreEvent(UiEvent ev)
        {
            if (ev == null) return;
            switch (ev.T)
            {
                case "invite_result":
                    {
                        // Success only means the invite was accepted; the row keeps "adding" until
                        // device_joined confirms the device is really in the Cluster.
                        var row = FindRow(ev.Str("id"));
                        if (row != null && !EventBool(ev, "ok")) row.MarkFailed(ev.Str("err"));
                        break;
                    }
                case "device_joined":
                    {
                        var row = FindRow(ev.Str("id"));
                        if (row != null)
                        {
                            row.MarkAdded();
                            if (!_joinedRows.Contains(row.Id)) _joinedRows.Add(row.Id);
                            _joinedSweep.Stop();
                            _joinedSweep.Start();
                        }
                        Refresh();
                        break;
                    }
                case "pending_changed":
                case "pairing_mode_changed":
                case "join_token_changed":
                case "pairing_state":
                case "pairing_revoked":
                    Refresh();
                    break;
            }
        }

        private static bool EventBool(UiEvent ev, string key)
        {
            object value;
            if (ev == null || ev.Data == null || !ev.Data.TryGetValue(key, out value) ||
                value == null) return false;
            if (value is bool) return (bool)value;
            string text = value.ToString();
            return text == "true" || text == "True" || text == "1";
        }

        private PendingDeviceRow FindRow(string id)
        {
            PendingDeviceRow row;
            return !string.IsNullOrEmpty(id) && _byId.TryGetValue(id, out row) ? row : null;
        }

        private void Refresh()
        {
            var snapshot = PairingSnapshot.From(App.Core.PairingInfo());
            if (!snapshot.Known) return;
            _snapshot = snapshot;

            bool ready = snapshot.IsReady;
            PairedPanel.Visibility = ready ? Visibility.Visible : Visibility.Collapsed;
            UnpairedPanel.Visibility = ready ? Visibility.Collapsed : Visibility.Visible;

            MembershipText.Text = Texts.T("pair.membership", snapshot.MemberCount.ToString());
            ConnectedText.Text = Texts.T("pair.membership_connected",
                                         snapshot.ConnectedCount.ToString());
            CreatedBadge.Visibility = snapshot.IsFounder ? Visibility.Visible :
                                                           Visibility.Collapsed;
            SelfLine.Text = string.IsNullOrEmpty(snapshot.SelfAddr) ? snapshot.SelfName :
                snapshot.SelfName + " · " + snapshot.SelfAddr;

            if (!ready) return;

            SyncRows(snapshot);
            NearbyEmptyPanel.Visibility = _rows.Count == 0 ? Visibility.Visible :
                                                             Visibility.Collapsed;

            if (snapshot.TokenActive) _codeCardOpen = true;
            CodeCard.Visibility = _codeCardOpen ? Visibility.Visible : Visibility.Collapsed;
            if (_codeCardOpen) CodeCard.Apply(snapshot);

            if (snapshot.PairingMode)
            {
                AddAllTitle.Text = PairingText.AddAllOn(snapshot.PairingModeLeftS,
                                                        snapshot.AutoAddedCount);
                AddAllButton.Content = Texts.T("pair.add_all_stop");
            }
            else
            {
                AddAllTitle.Text = Texts.T("pair.add_all");
                AddAllButton.Content = Texts.T("pair.add_all");
            }

            RenderOwnQr(snapshot.PairQr);
        }

        private void SyncRows(PairingSnapshot snapshot)
        {
            var seen = new HashSet<string>();
            foreach (PairingDevice device in snapshot.Devices)
            {
                seen.Add(device.Id);
                PendingDeviceRow row;
                if (_byId.TryGetValue(device.Id, out row))
                {
                    row.Update(device);
                    continue;
                }
                row = new PendingDeviceRow(device);
                _byId[device.Id] = row;
                _rows.Add(row);
            }
            for (int i = _rows.Count - 1; i >= 0; i--)
            {
                PendingDeviceRow row = _rows[i];
                // In-flight and just-added rows survive until their own outcome removes them.
                if (seen.Contains(row.Id) || !row.CanAct) continue;
                _rows.RemoveAt(i);
                _byId.Remove(row.Id);
            }
        }

        private void SweepJoinedRows()
        {
            _joinedSweep.Stop();
            foreach (string id in _joinedRows)
            {
                PendingDeviceRow row;
                if (!_byId.TryGetValue(id, out row)) continue;
                _rows.Remove(row);
                _byId.Remove(id);
            }
            _joinedRows.Clear();
            NearbyEmptyPanel.Visibility = _rows.Count == 0 ? Visibility.Visible :
                                                             Visibility.Collapsed;
        }

        private void RenderOwnQr(string payload)
        {
            if (string.IsNullOrEmpty(payload))
            {
                _renderedQr = "";
                OwnQrImage.Source = null;
                OwnQrPlaceholder.Visibility = Visibility.Visible;
                return;
            }
            if (payload == _renderedQr) return;
            var bitmap = QrCodeImage.Render(payload, 360);
            _renderedQr = bitmap == null ? "" : payload;
            OwnQrImage.Source = bitmap;
            OwnQrPlaceholder.Visibility = bitmap == null ? Visibility.Visible :
                                                           Visibility.Collapsed;
        }

        private void OnAddClick(object sender, RoutedEventArgs e)
        {
            var element = sender as FrameworkElement;
            var row = element == null ? null : element.DataContext as PendingDeviceRow;
            if (row == null || !row.CanAct) return;
            row.MarkAdding();
            string id = row.Id;
            Task.Factory.StartNew(() => App.Core.InviteDevice(id));
        }

        private void OnDenyClick(object sender, RoutedEventArgs e)
        {
            var element = sender as FrameworkElement;
            var row = element == null ? null : element.DataContext as PendingDeviceRow;
            if (row == null) return;
            string id = row.Id;
            _rows.Remove(row);
            _byId.Remove(id);
            NearbyEmptyPanel.Visibility = _rows.Count == 0 ? Visibility.Visible :
                                                             Visibility.Collapsed;
            Task.Factory.StartNew(() => App.Core.DenyDevice(id));
        }

        private void OnAddWithCodeClick(object sender, RoutedEventArgs e)
        {
            _codeCardOpen = true;
            RequestNewCode();
        }

        private void OnNewCodeRequested()
        {
            RequestNewCode();
        }

        private void RequestNewCode()
        {
            AddWithCodeButton.IsEnabled = false;
            // A PIN never opens the pairing-mode window (spec 5.4).
            Task.Factory.StartNew(() => App.Core.MintJoinToken(TokenSeconds))
                .ContinueWith(task => Dispatcher.BeginInvoke(new Action(() =>
                {
                    AddWithCodeButton.IsEnabled = true;
                    Refresh();
                })));
        }

        private void OnAddAllClick(object sender, RoutedEventArgs e)
        {
            bool stopping = _snapshot.PairingMode;
            AddAllButton.IsEnabled = false;
            // Only this explicit button, with its warning, opens the pairing-mode window.
            Task.Factory.StartNew(() =>
                {
                    if (stopping) App.Core.SetPairingMode(0);
                    else App.Core.StartPairing(PairingModeSeconds);
                })
                .ContinueWith(task => Dispatcher.BeginInvoke(new Action(() =>
                {
                    AddAllButton.IsEnabled = true;
                    Refresh();
                })));
        }

        private void OnScanQrClick(object sender, RoutedEventArgs e)
        {
            var scanner = new QrScanWindow { Owner = this, Topmost = Topmost };
            scanner.ShowDialog();
            Refresh();
        }

        private void OnClearClick(object sender, RoutedEventArgs e)
        {
            ClearConfirmPanel.Visibility = Visibility.Visible;
        }

        private void OnClearCancelClick(object sender, RoutedEventArgs e)
        {
            ClearConfirmPanel.Visibility = Visibility.Collapsed;
        }

        private void OnClearConfirmClick(object sender, RoutedEventArgs e)
        {
            ClearConfirmYes.IsEnabled = false;
            Task.Factory.StartNew(() => App.Core.Unpair())
                .ContinueWith(task => Dispatcher.BeginInvoke(new Action(Close)));
        }

        private void OnOpenOnboardingClick(object sender, RoutedEventArgs e)
        {
            OnboardingRequested = true;
            Close();
        }

        private void OnCloseClick(object sender, RoutedEventArgs e)
        {
            Close();
        }
    }
}
