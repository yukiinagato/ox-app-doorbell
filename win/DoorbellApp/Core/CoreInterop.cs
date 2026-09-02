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

        public const uint DbPlatformV2Version = 2;

        // This declaration must stay byte-for-byte compatible with db_platform_v2. Do not add
        // managed-only fields: struct_size is checked by core before any callback is retained.
        [StructLayout(LayoutKind.Sequential)]
        public struct DbPlatformV2
        {
            public uint struct_size;
            public uint version;
            public IntPtr user;
            public IntPtr https_request;
            public IntPtr secure_get;
            public IntPtr secure_put;
            public IntPtr log_line;
            public IntPtr tts_speak;
            public IntPtr device_info;
            public IntPtr release_buffer;
        }

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void LogLineCb(IntPtr user, int level, IntPtr lineUtf8);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void TtsSpeakCb(IntPtr user, IntPtr textUtf8, IntPtr langUtf8);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int HttpsRequestCb(IntPtr user, IntPtr methodUtf8, IntPtr urlUtf8,
            IntPtr headersJsonUtf8, IntPtr body, UIntPtr bodyLength, IntPtr responseBodyOut,
            IntPtr httpStatusOut);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int SecureGetCb(IntPtr user, IntPtr keyUtf8, IntPtr valueOut);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int SecurePutCb(IntPtr user, IntPtr keyUtf8, IntPtr valueUtf8);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int DeviceInfoCb(IntPtr user, IntPtr jsonOut);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void ReleaseBufferCb(IntPtr user, IntPtr buffer);

        private const string Dll = "doorbell";

        [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr LoadLibrary(string path);

        public static void Preload()
        {
            string arch = Environment.Is64BitProcess ? "win-x64" : "win-x86";
            string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "lib", arch, "doorbell.dll");
            if (File.Exists(path) && LoadLibrary(path) == IntPtr.Zero)
                throw new DllNotFoundException("Failed to load doorbell.dll: " + path +
                                               " (GetLastError=" + Marshal.GetLastWin32Error() + ")");
        }

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_create_v2(ref DbPlatformV2 platform,
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
        public static extern void db_core_press_purpose(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string doorId,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string purpose);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_press_v2(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string doorId,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string purpose);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_select_purpose_v2(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string doorId,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string callId,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string purpose);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_cancel_call_v2(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string doorId,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string callId,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string reason);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_report_call_recovery(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string callId, int restored);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_report_call_answered_v2(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string doorId,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string callId, int stageRevision);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_report_call_ended_v2(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string doorId,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string callId, int stageRevision,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string reason);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_set_visitor_lang(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string door,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string lang);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_quick_reply(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string replyId,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string door);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_quick_reply_v2(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string replyId,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string door,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string callId, int stageRevision);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_status_json(IntPtr core);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_config_json(IntPtr core);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_pairing_json(IntPtr core);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_join_cluster(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string host,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string pin);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_found_cluster(IntPtr core);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_pairing_mode(IntPtr core, int seconds);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_invite_device(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string nodeId);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_set_capabilities_json(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string json);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_set_runtime_status_json(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string json);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_set_ui_manifest_json(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string json);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_on_camera_frame(IntPtr core, IntPtr data, int format,
            int width, int height, int stride, long tsMs);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_free(IntPtr p);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_version();

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_sip_backend();

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_emergency_v2(IntPtr core, int active);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_sip_call(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string target,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string mode);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_sip_hangup(IntPtr core);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_sip_send_dtmf(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string digits);

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
