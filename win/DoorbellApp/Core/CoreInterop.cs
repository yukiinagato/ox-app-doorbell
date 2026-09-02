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
            // Appended in this ABI generation. NULL is legal and means core keeps an orphaned
            // secret when pairing is cleared, so struct_size must always be sizeof(this struct).
            public IntPtr secure_delete;
            // Appended after secure_delete. NULL is legal and means core reports no power state.
            // Fields are only ever appended, so power_state must stay last.
            public IntPtr power_state;
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
        public delegate int SecureDeleteCb(IntPtr user, IntPtr keyUtf8);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int DeviceInfoCb(IntPtr user, IntPtr jsonOut);

        // {"battery_pct":<-1..100>,"charging":bool,"mains":bool}; core releases the buffer with
        // release_buffer, so the same allocator as device_info must be used.
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int PowerStateCb(IntPtr user, IntPtr jsonOut);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void ReleaseBufferCb(IntPtr user, IntPtr buffer);

        private const string Dll = "doorbell";

        [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr LoadLibrary(string path);

        [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr GetModuleHandle(string name);

        [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Ansi,
                   BestFitMapping = false)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);

        // ---- Optional exports (spec 5.5) -------------------------------------------------
        // Every entry point below lands with the batch-2 core delta. Each is bound through
        // OptionalExport, so a shell running against an older Core hides or degrades the feature
        // instead of terminating at the first call.

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int SipSetMicMutedFn(IntPtr core, int muted);

        // Mints or refreshes the Pairing PIN without opening the pairing-mode window.
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate IntPtr MintJoinTokenFn(IntPtr core, int seconds);

        // One cluster-wide 管理パスワード: >0 accepted, 0 rejected, -1 locked out,
        // -2 no cluster password has been set yet.
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int AdminPasswordVerifyFn(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string password);

        // current may be empty when no password has been set yet. Zero on success.
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int AdminPasswordSetFn(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string current,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string next);

        // Native configuration writes, mirroring POST /api/config, /api/config/batch and
        // /api/config/delete exactly. One write and one deletion answer with a status code
        // (0 committed, -1 invalid arguments, -2 rejected or not persisted); the readability
        // warnings that write produced are read straight afterwards from
        // db_core_last_write_warnings_json. The batch answers with an owned document shaped like
        // /api/config/batch, warnings included, released with db_free.
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int SetConfigJsonFn(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string key,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string valueJson);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate IntPtr LastWriteWarningsFn(IntPtr core);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate IntPtr ConfigBatchJsonFn(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string json);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int DeleteConfigKeyFn(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string key);

        // Call history with an exclusive upper bound, so the history page really pages.
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate IntPtr CallLogJsonV2Fn(IntPtr core, long sinceMs, long beforeMs,
                                               int limit);

        /// <summary>
        /// Binds an export that is optional in this Core generation. A missing export returns
        /// null instead of throwing at the first call site, so the shell can hide the control.
        /// </summary>
        public static TDelegate OptionalExport<TDelegate>(string name) where TDelegate : class
        {
            if (string.IsNullOrEmpty(name)) return null;
            try
            {
                IntPtr module = GetModuleHandle("doorbell.dll");
                if (module == IntPtr.Zero) module = GetModuleHandle("doorbell");
                if (module == IntPtr.Zero) return null;
                IntPtr proc = GetProcAddress(module, name);
                if (proc == IntPtr.Zero) return null;
                return Marshal.GetDelegateForFunctionPointer(proc, typeof(TDelegate)) as TDelegate;
            }
            catch { return null; }
        }

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

        // Opens the "add everything nearby" window. Reserved for that explicit button.
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_start_pairing_json(IntPtr core, int seconds);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_invite_direct(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string addr,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string nodeId,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string publicKeyHex);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_deny_device(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string nodeId);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_retry_pairing_persistence(IntPtr core);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_unpair(IntPtr core);

        // Returns size*size row-major bytes where one means dark. Release with db_free.
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_qr_encode(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string text, out int outSize);

        // 0 on success (release textOut with db_free), 1 when no code was found, -1 on bad input.
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_qr_decode(byte[] gray, int width, int height,
                                                   out IntPtr textOut);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_qr_scan_start(IntPtr core);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void db_core_qr_scan_stop(IntPtr core);

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

        // Render a wall-clock instant in the configured IANA zone. wall_ms of zero means "now".
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_local_time_json(IntPtr core, long wallMs);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_time_sync_now(IntPtr core);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_audio_json(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string deviceId);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_set_door_notice(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string door,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string text, long expiresMs);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_clear_door_notice(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string door);

        // 0 queued, -1 null core or empty door, -2 unknown door, -3 no unlock action configured.
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_open_door(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string door);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr db_core_call_log_json(IntPtr core, long sinceMs, int limit);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int db_core_call_log_mark_seen(IntPtr core,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string upToHlc);

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
