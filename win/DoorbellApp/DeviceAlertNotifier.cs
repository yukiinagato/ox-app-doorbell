using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace DoorbellApp
{
    internal sealed class DeviceAlertNotifier : IDisposable
    {
        private const uint NimAdd = 0x00000000;
        private const uint NimModify = 0x00000001;
        private const uint NimDelete = 0x00000002;
        private const uint NifMessage = 0x00000001;
        private const uint NifIcon = 0x00000002;
        private const uint NifTip = 0x00000004;
        private const uint NifInfo = 0x00000010;
        private const uint NiifWarning = 0x00000002;
        private const uint NiifNoSound = 0x00000010;

        private readonly AlertWindow _window = new AlertWindow();
        private bool _added;

        internal static bool SystemNotificationAvailable()
        {
            if (!Environment.UserInteractive) return false;
            try { return GetShellWindow() != IntPtr.Zero; }
            catch { return false; }
        }

        public bool Show(string title, string message, bool visual)
        {
            Clear();
            if (!visual) return true;
            try
            {
                var data = BaseData();
                data.uFlags = NifMessage | NifIcon | NifTip;
                data.uCallbackMessage = 0x8001;
                data.hIcon = SystemIcons.Warning.Handle;
                data.szTip = "Doorbell";
                if (!Shell_NotifyIcon(NimAdd, ref data)) return false;
                _added = true;

                data = BaseData();
                data.uFlags = NifInfo;
                data.szInfoTitle = string.IsNullOrEmpty(title) ? "Doorbell" : title;
                data.szInfo = string.IsNullOrEmpty(message) ? data.szInfoTitle : message;
                // Application audio owns the rule volume. This prevents the shell from adding
                // an ungoverned sound, including when the configured volume is zero.
                data.dwInfoFlags = NiifWarning | NiifNoSound;
                return Shell_NotifyIcon(NimModify, ref data);
            }
            catch
            {
                Clear();
                return false;
            }
        }

        public void Clear()
        {
            if (!_added) return;
            try
            {
                var data = BaseData();
                Shell_NotifyIcon(NimDelete, ref data);
            }
            catch { }
            _added = false;
        }

        public void Dispose()
        {
            Clear();
            _window.Dispose();
        }

        private NotifyIconData BaseData()
        {
            return new NotifyIconData
            {
                cbSize = Marshal.SizeOf(typeof(NotifyIconData)),
                hWnd = _window.Handle,
                uID = 911,
            };
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool Shell_NotifyIcon(uint message, ref NotifyIconData data);

        [DllImport("user32.dll")]
        private static extern IntPtr GetShellWindow();

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct NotifyIconData
        {
            public int cbSize;
            public IntPtr hWnd;
            public uint uID;
            public uint uFlags;
            public uint uCallbackMessage;
            public IntPtr hIcon;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
            public uint dwState;
            public uint dwStateMask;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
            public uint uTimeoutOrVersion;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
            public uint dwInfoFlags;
            public Guid guidItem;
            public IntPtr hBalloonIcon;
        }

        private sealed class AlertWindow : NativeWindow, IDisposable
        {
            public AlertWindow()
            {
                CreateHandle(new CreateParams { Caption = "Doorbell device alert" });
            }

            public void Dispose()
            {
                DestroyHandle();
            }
        }
    }
}
