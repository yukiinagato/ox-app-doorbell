// doorbell-core C ABI (include/doorbell/doorbell.h) の P/Invoke 層。
// DLL はプロセスのビット数に応じて lib\win-x64|win-x86\doorbell.dll を明示ロードする。
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace DoorbellApp.Core
{
    internal static class CoreInterop
    {
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void UiEventCb(IntPtr user, IntPtr eventJsonUtf8);

        [StructLayout(LayoutKind.Sequential)]
        public struct DbPlatform
        {
            public IntPtr user;
            public IntPtr https_request;  // Phase 2 (WinHTTP ラッパ) — 未使用は IntPtr.Zero
            public IntPtr secure_get;     // Phase 1 後半 (DPAPI)
            public IntPtr secure_put;
            public IntPtr log_line;       // LogLineCb
            public IntPtr tts_speak;      // TtsSpeakCb
        }

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void LogLineCb(IntPtr user, int level, IntPtr lineUtf8);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void TtsSpeakCb(IntPtr user, IntPtr textUtf8, IntPtr langUtf8);

        private const string Dll = "doorbell";

        [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr LoadLibrary(string path);

        /// <summary>最初の P/Invoke より前に、アーキテクチャに合う DLL を明示ロードする。</summary>
        public static void Preload()
        {
            string arch = Environment.Is64BitProcess ? "win-x64" : "win-x86";
            string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "lib", arch, "doorbell.dll");
            if (File.Exists(path) && LoadLibrary(path) == IntPtr.Zero)
                throw new DllNotFoundException("doorbell.dll のロードに失敗: " + path +
                                               " (GetLastError=" + Marshal.GetLastWin32Error() + ")");
            // 見つからない場合は既定の探索 (実行ディレクトリ直下等) に任せる
        }

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_create(ref DbPlatform platform,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string dataDir,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string bootJson);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_start(IntPtr core);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_stop(IntPtr core);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_destroy(IntPtr core);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_set_ui_callback(IntPtr core, UiEventCb cb, IntPtr user);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_press(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string doorId);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_status_json(IntPtr core);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_config_json(IntPtr core);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_on_camera_frame(IntPtr core, IntPtr data, int format,
            int width, int height, int stride, long tsMs);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_free(IntPtr p);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_version();

        /// <summary>SOS 緊急モード。active=1 発報 / 0 解除 (PIN 検証は殻の責務)。</summary>
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_emergency(IntPtr core, int active);

        /// <summary>core が返した char* を UTF-8 として読み、db_free で解放する。</summary>
        public static string TakeUtf8(IntPtr p)
        {
            if (p == IntPtr.Zero) return null;
            try
            {
                int len = 0;
                while (Marshal.ReadByte(p, len) != 0) len++;
                byte[] buf = new byte[len];
                Marshal.Copy(p, buf, 0, len);
                return Encoding.UTF8.GetString(buf);
            }
            finally
            {
                db_free(p);
            }
        }

        /// <summary>借用 char* (解放しない) を UTF-8 で読む。コールバック引数用。</summary>
        public static string ReadUtf8(IntPtr p)
        {
            if (p == IntPtr.Zero) return null;
            int len = 0;
            while (Marshal.ReadByte(p, len) != 0) len++;
            byte[] buf = new byte[len];
            Marshal.Copy(p, buf, 0, len);
            return Encoding.UTF8.GetString(buf);
        }
    }
}
