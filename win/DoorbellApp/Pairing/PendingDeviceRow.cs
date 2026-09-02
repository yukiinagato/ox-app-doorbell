using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using DoorbellApp.Util;

namespace DoorbellApp.Pairing
{
    /// <summary>
    /// One row of the Nearby-devices list. The row owns its own in-flight/success/failure state so
    /// a rebuild from pending.devices[] never loses the adding state or a failure message.
    /// </summary>
    public sealed class PendingDeviceRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;

        private static readonly Brush OkBrush = Frozen(Color.FromRgb(0x5D, 0xD3, 0x9E));
        private static readonly Brush ErrorBrush = Frozen(Color.FromRgb(0xFF, 0x6B, 0x6B));

        private static Brush Frozen(Color color)
        {
            var brush = new SolidColorBrush(color);
            brush.Freeze();
            return brush;
        }

        private string _title = "";
        private string _subtitle = "";
        private string _waiting = "";
        private string _actionText = "";
        private bool _busy;
        private bool _added;
        private string _status = "";
        private string _detail = "";
        private bool _statusIsError;

        public PendingDeviceRow(PairingDevice device)
        {
            Id = device == null ? "" : device.Id;
            Addr = device == null ? "" : device.Addr;
            Update(device);
            _actionText = Texts.T("pair.add");
        }

        public string Id { get; private set; }
        public string Addr { get; private set; }

        /// <summary>Button captions are bound, because no user-facing string is hardcoded.</summary>
        public string DenyText { get { return Texts.T("pair.deny"); } }

        /// <summary>Refreshes the descriptive fields without touching the action state.</summary>
        public void Update(PairingDevice device)
        {
            if (device == null) return;
            Addr = device.Addr;
            Title = PairingText.DisplayName(device);
            Subtitle = PairingText.Subtitle(device);
            Waiting = Texts.T("pair.nearby_waiting_since", Math.Max(0, device.AgeS).ToString());
        }

        public string Title
        {
            get { return _title; }
            private set { Set(ref _title, value, "Title"); }
        }

        public string Subtitle
        {
            get { return _subtitle; }
            private set { Set(ref _subtitle, value, "Subtitle"); }
        }

        public string Waiting
        {
            get { return _waiting; }
            private set { Set(ref _waiting, value, "Waiting"); }
        }

        public string ActionText
        {
            get { return _actionText; }
            private set { Set(ref _actionText, value, "ActionText"); }
        }

        public bool CanAct
        {
            get { return !_busy && !_added; }
        }

        public Visibility BusyVisibility
        {
            get { return _busy ? Visibility.Visible : Visibility.Collapsed; }
        }

        public Visibility DenyVisibility
        {
            get { return _busy || _added ? Visibility.Collapsed : Visibility.Visible; }
        }

        public string StatusText
        {
            get { return _status; }
            private set { Set(ref _status, value, "StatusText"); }
        }

        public Visibility StatusVisibility
        {
            get { return string.IsNullOrEmpty(_status) ? Visibility.Collapsed : Visibility.Visible; }
        }

        public string DetailText
        {
            get { return _detail; }
            private set { Set(ref _detail, value, "DetailText"); }
        }

        public Visibility DetailVisibility
        {
            get { return string.IsNullOrEmpty(_detail) ? Visibility.Collapsed : Visibility.Visible; }
        }

        public Brush StatusBrush
        {
            get { return _statusIsError ? ErrorBrush : OkBrush; }
        }

        /// <summary>The device is being added: disabled control plus the in-flight label.</summary>
        public void MarkAdding()
        {
            _busy = true;
            _added = false;
            _statusIsError = false;
            ActionText = Texts.T("pair.adding");
            StatusText = "";
            DetailText = "";
            RaiseActionState();
        }

        /// <summary>Positive confirmation, driven by device_joined and never by invite_result.</summary>
        public void MarkAdded()
        {
            _busy = false;
            _added = true;
            _statusIsError = false;
            ActionText = Texts.T("pair.added");
            StatusText = Texts.T("pair.added") + " ✓";
            DetailText = "";
            RaiseActionState();
        }

        public void MarkFailed(string errorCode)
        {
            _busy = false;
            _added = false;
            _statusIsError = true;
            ActionText = Texts.T("pair.add");
            StatusText = Texts.T("pair.add_failed") + " — " + PairingText.ErrorMessage(errorCode);
            DetailText = PairingText.ErrorDetail(errorCode);
            RaiseActionState();
        }

        private void RaiseActionState()
        {
            Raise("CanAct");
            Raise("BusyVisibility");
            Raise("DenyVisibility");
            Raise("StatusVisibility");
            Raise("DetailVisibility");
            Raise("StatusBrush");
        }

        private void Set<T>(ref T field, T value, string name)
        {
            if (Equals(field, value)) return;
            field = value;
            Raise(name);
            if (name == "StatusText") Raise("StatusVisibility");
            if (name == "DetailText") Raise("DetailVisibility");
        }

        private void Raise(string name)
        {
            var handler = PropertyChanged;
            if (handler != null) handler(this, new PropertyChangedEventArgs(name));
        }
    }
}
