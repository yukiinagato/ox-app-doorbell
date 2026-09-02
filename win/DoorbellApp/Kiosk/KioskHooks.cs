using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace DoorbellApp.Kiosk
{
    // The low-level hook blocks shell shortcuts but cannot intercept the secure attention sequence;
    // managed kiosk deployments must enforce Ctrl+Alt+Delete policy outside this process.
    public sealed class KioskHooks : IDisposable
    {
        private const int WH_KEYBOARD_LL = 13;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_TAB = 0x09, VK_F4 = 0x73, VK_ESCAPE = 0x1B;

        [StructLayout(LayoutKind.Sequential)]
        private struct KBDLLHOOKSTRUCT { public int vkCode; public int scanCode; public int flags; public int time; public IntPtr dwExtraInfo; }

        private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32")]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);
        [DllImport("kernel32")]
        private static extern uint SetThreadExecutionState(uint esFlags);

        private const uint ES_CONTINUOUS = 0x80000000, ES_DISPLAY_REQUIRED = 0x00000002,
                           ES_SYSTEM_REQUIRED = 0x00000001;

        private IntPtr _hook = IntPtr.Zero;
        private HookProc _proc;  // Keep the delegate rooted while the native hook owns its pointer.

        public void Enable()
        {
            if (_hook != IntPtr.Zero) return;
            _proc = Callback;
            using (var mod = Process.GetCurrentProcess().MainModule)
                _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(mod.ModuleName), 0);
        }

        public void Disable()
        {
            if (_hook == IntPtr.Zero) return;
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }

        public static void KeepDisplayOn() =>
            SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);

        private IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                int msg = wParam.ToInt32();
                if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN)
                {
                    var k = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
                    bool alt = (k.flags & 0x20) != 0;  // LLKHF_ALTDOWN
                    if (k.vkCode == VK_LWIN || k.vkCode == VK_RWIN) return (IntPtr)1;
                    if (alt && (k.vkCode == VK_TAB || k.vkCode == VK_F4 || k.vkCode == VK_ESCAPE))
                        return (IntPtr)1;
                }
            }
            return CallNextHookEx(_hook, nCode, wParam, lParam);
        }

        public void Dispose() => Disable();
    }
}
