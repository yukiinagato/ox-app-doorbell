using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp.Pairing
{
    /// <summary>
    /// Onboarding surface for states unpaired / joining / persist_error (spec 5.0). It replaces the
    /// main UI until core reports state "ready", renders every pairing event, and never infers a
    /// state from paired/persistence_ready.
    /// </summary>
    public partial class PairingOnboardingView : UserControl
    {
        private const int JoinTimeoutSeconds = 25;
        private const int JoinedDismissSeconds = 2;

        private enum Mode { Status, CreateConfirm, CodeEntry, Created }

        private readonly DispatcherTimer _poll = new DispatcherTimer();
        private readonly DispatcherTimer _joinTimeout = new DispatcherTimer();
        private readonly DispatcherTimer _dismissDelay = new DispatcherTimer();

        private PairingSnapshot _snapshot = new PairingSnapshot();
        private Mode _mode = Mode.Status;
        private string _pin = "";
        private string _renderedQr = "";
        private bool _joining;
        private bool _createRequested;
        private bool _createdCardArmed;
        private bool _active;

        /// <summary>Raised for "set up later", and after the joined confirmation has been read.</summary>
        public event Action DismissRequested;

        public PairingOnboardingView()
        {
            InitializeComponent();
            ApplyStrings();

            _poll.Interval = TimeSpan.FromSeconds(1);
            _poll.Tick += (sender, args) => Refresh();
            _joinTimeout.Tick += (sender, args) =>
            {
                _joinTimeout.Stop();
                if (!_joining) return;
                _joining = false;
                ShowEntryError("timeout");
                Render();
            };
            _dismissDelay.Tick += (sender, args) =>
            {
                _dismissDelay.Stop();
                RaiseDismiss();
            };

            Keypad.KeyPressed += OnKeypadKey;
            CreatedCodeCard.NewCodeRequested += OnNewCodeRequested;
            AddressBox.TextChanged += (sender, args) => UpdateJoinEnabled();
            PreviewKeyDown += OnPreviewKey;
        }

        public bool IsActive { get { return _active; } }

        /// <summary>The snapshot last rendered; empty until core has published one.</summary>
        public PairingSnapshot Snapshot { get { return _snapshot; } }

        public void ApplyStrings()
        {
            TitleText.Text = Texts.T("pair.title_unpaired");
            JoinWithCodeButton.Content = Texts.T("pair.join_with_code");
            CreateHomeButton.Content = Texts.T("pair.create_home");
            LaterButton.Content = Texts.T("pair.later");
            CreatedLaterButton.Content = Texts.T("pair.later");
            CreateConfirmText.Text = Texts.T("pair.create_home_confirm");
            CreateConfirmYes.Content = Texts.T("pair.create_home");
            CreateConfirmNo.Content = Texts.T("admin.cancel");
            EntryAddressLabel.Text = Texts.T("pair.address_label");
            EntryAddressExample.Text = Texts.T("pair.address_example");
            EntryCodeLabel.Text = Texts.T("pair.code_label");
            JoinButton.Content = Texts.T("pair.join_with_code");
            JoinBackButton.Content = Texts.T("admin.cancel");
            CreatedTitle.Text = Texts.T("pair.created") + " ✓";
            CreatedNext.Text = Texts.T("pair.created_next");
            PersistErrorTitle.Text = Texts.T("pair.persist_error_title");
            PersistErrorBody.Text = Texts.T("pair.persist_error_body");
            RetryButton.Content = Texts.T("pair.retry");
            QrCaption.Text = Texts.T("pair.qr_caption");
            QrPlaceholder.Text = Texts.T("pair.searching");
            CreatedCodeCard.ApplyStrings();
        }

        /// <summary>Shows the surface and starts the one-second snapshot poll.</summary>
        public void Activate()
        {
            _active = true;
            Visibility = Visibility.Visible;
            Refresh();
            _poll.Start();
        }

        public void Deactivate()
        {
            _active = false;
            _poll.Stop();
            _dismissDelay.Stop();
            Visibility = Visibility.Collapsed;
        }

        /// <summary>Every pairing event is rendered; nothing here is toast-only feedback.</summary>
        public void HandleCoreEvent(UiEvent ev)
        {
            if (ev == null) return;
            switch (ev.T)
            {
                case "join_result":
                    _joinTimeout.Stop();
                    if (!EventBool(ev, "ok"))
                    {
                        _joining = false;
                        ShowEntryError(ev.Str("err"));
                    }
                    Refresh();
                    break;
                case "invite_rejected":
                    _joining = false;
                    _joinTimeout.Stop();
                    ShowEntryError(ev.Str("reason"));
                    Refresh();
                    break;
                case "pairing_state":
                case "paired":
                case "pairing_persistence_error":
                case "pairing_revoked":
                case "join_token_changed":
                case "pending_changed":
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

        private void Refresh()
        {
            var snapshot = PairingSnapshot.From(App.Core.PairingInfo());
            // An empty snapshot means core has not published pairing state yet. Rendering it as
            // "unpaired" would flash onboarding on a healthy paired device.
            if (!snapshot.Known) return;
            _snapshot = snapshot;
            Render();
        }

        private void Render()
        {
            var snapshot = _snapshot;
            IdentityText.Text = IdentityLine(snapshot);
            RenderQr(snapshot.PairQr);

            bool persistError = snapshot.State == PairingSnapshot.StatePersistError;
            bool joiningState = snapshot.State == PairingSnapshot.StateJoining || _joining;
            bool ready = snapshot.State == PairingSnapshot.StateReady;
            bool revoked = snapshot.State == PairingSnapshot.StateRevoked;

            if (persistError)
            {
                // A persistence failure is only cleared by a successful retry.
                _mode = Mode.Status;
                _joining = false;
            }
            else if (ready && _createRequested)
            {
                _mode = Mode.Created;
            }

            if (persistError)
            {
                StatusSpinner.Visibility = Visibility.Collapsed;
                StatusText.Text = Texts.T("pair.persist_error_title");
                StatusHint.Text = "";
            }
            else if (revoked)
            {
                // Core already dropped the key; state stays "revoked" until this device pairs
                // again, so the normal unpaired actions have to stay reachable underneath.
                StatusSpinner.Visibility = Visibility.Collapsed;
                StatusText.Text = Texts.T("pair.revoked");
                StatusHint.Text = Texts.T("pair.searching_hint");
            }
            else if (ready)
            {
                StatusSpinner.Visibility = Visibility.Collapsed;
                StatusText.Text = (_createRequested ? Texts.T("pair.created") :
                                                      Texts.T("pair.joined")) + " ✓";
                StatusHint.Text = "";
                if (!_createRequested && _active && !_dismissDelay.IsEnabled)
                {
                    _dismissDelay.Interval = TimeSpan.FromSeconds(JoinedDismissSeconds);
                    _dismissDelay.Start();
                }
            }
            else if (joiningState)
            {
                StatusSpinner.Visibility = Visibility.Visible;
                StatusText.Text = Texts.T("pair.joining");
                StatusHint.Text = "";
            }
            else
            {
                StatusSpinner.Visibility = Visibility.Visible;
                StatusText.Text = Texts.T("pair.searching");
                StatusHint.Text = Texts.T("pair.searching_hint");
            }

            bool secondaryAllowed = !persistError && !ready && !joiningState;
            ActionsPanel.Visibility = secondaryAllowed && _mode == Mode.Status ?
                Visibility.Visible : Visibility.Collapsed;
            CreateConfirmPanel.Visibility = secondaryAllowed && _mode == Mode.CreateConfirm ?
                Visibility.Visible : Visibility.Collapsed;
            CodeEntryPanel.Visibility = _mode == Mode.CodeEntry && !persistError && !ready ?
                Visibility.Visible : Visibility.Collapsed;
            CreatedPanel.Visibility = _mode == Mode.Created && ready ?
                Visibility.Visible : Visibility.Collapsed;
            PersistErrorPanel.Visibility = persistError ?
                Visibility.Visible : Visibility.Collapsed;

            AddressBox.IsEnabled = !_joining;
            Keypad.IsEnabled = !_joining;
            JoinBackButton.IsEnabled = !_joining;
            UpdateJoinEnabled();
            CodeDisplay.Text = FormatPin(_pin);

            if (_mode == Mode.Created && ready)
            {
                // The card must be on screen with a live PIN the moment the Cluster exists.
                if (!_createdCardArmed)
                {
                    _createdCardArmed = true;
                    if (!snapshot.TokenActive) RequestNewCode();
                }
                CreatedCodeCard.Apply(snapshot);
            }
        }

        private static string IdentityLine(PairingSnapshot snapshot)
        {
            var parts = new System.Collections.Generic.List<string>();
            if (!string.IsNullOrEmpty(snapshot.SelfName)) parts.Add(snapshot.SelfName);
            string role = PairingText.RoleLabel(snapshot.Role);
            if (!string.IsNullOrEmpty(role)) parts.Add(role);
            if (!string.IsNullOrEmpty(snapshot.SelfModel)) parts.Add(snapshot.SelfModel);
            if (!string.IsNullOrEmpty(snapshot.SelfAddr)) parts.Add(snapshot.SelfAddr);
            return string.Join(" · ", parts.ToArray());
        }

        private void RenderQr(string payload)
        {
            if (string.IsNullOrEmpty(payload))
            {
                _renderedQr = "";
                QrImage.Source = null;
                QrPlaceholder.Visibility = Visibility.Visible;
                return;
            }
            if (payload == _renderedQr) return;
            var bitmap = QrCodeImage.Render(payload, 480);
            _renderedQr = bitmap == null ? "" : payload;
            QrImage.Source = bitmap;
            QrPlaceholder.Visibility = bitmap == null ? Visibility.Visible : Visibility.Collapsed;
        }

        private static string FormatPin(string pin)
        {
            if (string.IsNullOrEmpty(pin)) return "";
            return pin.Length > 3 ? pin.Substring(0, 3) + " " + pin.Substring(3) : pin;
        }

        private void UpdateJoinEnabled()
        {
            JoinButton.IsEnabled = !_joining && _pin.Length == 6 &&
                                   !string.IsNullOrEmpty(AddressBox.Text.Trim());
        }

        private void ShowEntryError(string code)
        {
            EntryError.Text = PairingText.ErrorMessage(code);
            EntryError.Visibility = Visibility.Visible;
            string detail = PairingText.ErrorDetail(code);
            EntryErrorDetail.Text = detail;
            EntryErrorDetail.Visibility = string.IsNullOrEmpty(detail) ?
                Visibility.Collapsed : Visibility.Visible;
        }

        private void ClearEntryError()
        {
            EntryError.Visibility = Visibility.Collapsed;
            EntryErrorDetail.Visibility = Visibility.Collapsed;
        }

        private void OnKeypadKey(string key)
        {
            if (_joining) return;
            if (key == "back")
            {
                if (_pin.Length > 0) _pin = _pin.Substring(0, _pin.Length - 1);
            }
            else if (key == "clear")
            {
                _pin = "";
            }
            else if (_pin.Length < 6)
            {
                _pin += key;
            }
            ClearEntryError();
            CodeDisplay.Text = FormatPin(_pin);
            UpdateJoinEnabled();
        }

        private void OnPreviewKey(object sender, KeyEventArgs e)
        {
            if (CodeEntryPanel.Visibility != Visibility.Visible) return;
            if (AddressBox.IsKeyboardFocusWithin) return;
            if (e.Key >= Key.D0 && e.Key <= Key.D9)
                OnKeypadKey(((int)(e.Key - Key.D0)).ToString());
            else if (e.Key >= Key.NumPad0 && e.Key <= Key.NumPad9)
                OnKeypadKey(((int)(e.Key - Key.NumPad0)).ToString());
            else if (e.Key == Key.Back) OnKeypadKey("back");
            else if (e.Key == Key.Enter && JoinButton.IsEnabled) StartJoin();
            else return;
            e.Handled = true;
        }

        private void OnJoinWithCodeClick(object sender, RoutedEventArgs e)
        {
            _mode = Mode.CodeEntry;
            ClearEntryError();
            Render();
            AddressBox.Focus();
        }

        private void OnJoinBackClick(object sender, RoutedEventArgs e)
        {
            _mode = Mode.Status;
            ClearEntryError();
            Render();
        }

        private void OnCreateHomeClick(object sender, RoutedEventArgs e)
        {
            _mode = Mode.CreateConfirm;
            CreateError.Visibility = Visibility.Collapsed;
            CreateErrorDetail.Visibility = Visibility.Collapsed;
            Render();
        }

        private void OnCreateCancelClick(object sender, RoutedEventArgs e)
        {
            _mode = Mode.Status;
            Render();
        }

        private void OnCreateConfirmClick(object sender, RoutedEventArgs e)
        {
            CreateConfirmYes.IsEnabled = false;
            CreateConfirmNo.IsEnabled = false;
            _createRequested = true;
            _createdCardArmed = false;
            // Cluster creation generates a key and writes the secure store; never on the UI thread.
            Task.Factory.StartNew(() => App.Core.FoundCluster())
                .ContinueWith(task =>
                {
                    bool started = task.Status == TaskStatus.RanToCompletion && task.Result;
                    Dispatcher.BeginInvoke(new Action(() => OnCreateReturned(started)));
                });
        }

        // The result of found_cluster is advisory: the authoritative signal is pairing_state.
        private void OnCreateReturned(bool started)
        {
            CreateConfirmYes.IsEnabled = true;
            CreateConfirmNo.IsEnabled = true;
            Refresh();
            if (started || _snapshot.State == PairingSnapshot.StateReady) return;
            _createRequested = false;
            _mode = Mode.CreateConfirm;
            CreateError.Text = PairingText.ErrorMessage("create_failed");
            CreateError.Visibility = Visibility.Visible;
            CreateErrorDetail.Text = PairingText.ErrorDetail("create_failed");
            CreateErrorDetail.Visibility = Visibility.Visible;
            Render();
        }

        private void OnJoinClick(object sender, RoutedEventArgs e)
        {
            StartJoin();
        }

        private void StartJoin()
        {
            if (_joining) return;
            string host = AddressBox.Text.Trim();
            if (host.Length == 0 || _pin.Length != 6) return;
            _joining = true;
            ClearEntryError();
            Render();
            _joinTimeout.Interval = TimeSpan.FromSeconds(JoinTimeoutSeconds);
            _joinTimeout.Stop();
            _joinTimeout.Start();
            string pin = _pin;
            Task.Factory.StartNew(() => App.Core.JoinCluster(host, pin));
        }

        private void OnRetryClick(object sender, RoutedEventArgs e)
        {
            RetryButton.IsEnabled = false;
            RetryResult.Visibility = Visibility.Collapsed;
            Task.Factory.StartNew(() => App.Core.RetryPairingPersistence())
                .ContinueWith(task =>
                {
                    bool ok = task.Status == TaskStatus.RanToCompletion && task.Result;
                    Dispatcher.BeginInvoke(new Action(() =>
                    {
                        RetryButton.IsEnabled = true;
                        if (!ok)
                        {
                            RetryResult.Text = PairingText.ErrorMessage("persist_failed");
                            RetryResult.Visibility = Visibility.Visible;
                        }
                        Refresh();
                    }));
                });
        }

        private void OnNewCodeRequested()
        {
            RequestNewCode();
        }

        private void RequestNewCode()
        {
            Task.Factory.StartNew(() => App.Core.StartPairing(600))
                .ContinueWith(task => Dispatcher.BeginInvoke(new Action(Refresh)));
        }

        private void OnLaterClick(object sender, RoutedEventArgs e)
        {
            RaiseDismiss();
        }

        private void RaiseDismiss()
        {
            var handler = DismissRequested;
            if (handler != null) handler();
        }
    }
}
