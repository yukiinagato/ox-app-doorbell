using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Speech.Synthesis;
using System.Threading;
using System.Web.Script.Serialization;

namespace DoorbellApp.Core
{
    public sealed class UiEvent
    {
        public string T;
        public Dictionary<string, object> Data;
        public string Str(string key) =>
            Data != null && Data.TryGetValue(key, out var v) && v != null ? v.ToString() : "";
    }

    public sealed class CoreClient : IDisposable
    {
        private IntPtr _core;
        // Native Core retains callback pointers for the client's lifetime, so every delegate must
        // remain strongly rooted until Core is stopped and destroyed.
        private CoreInterop.UiEventCb _uiCb;
        private CoreInterop.LogLineCb _logCb;
        private CoreInterop.TtsSpeakCb _ttsCb;
        private CoreInterop.HttpsRequestCb _httpsCb;
        private CoreInterop.SecureGetCb _secureGetCb;
        private CoreInterop.SecurePutCb _securePutCb;
        private CoreInterop.DeviceInfoCb _deviceInfoCb;
        private CoreInterop.ReleaseBufferCb _releaseBufferCb;
        private DpapiSecretStore _secretStore;
        private SpeechSynthesizer _tts;
        private readonly JavaScriptSerializer _json = new JavaScriptSerializer();
        private readonly object _nativeLock = new object();
        private readonly object _eventLock = new object();
        private UiEvent _pendingRecovery;
        private Dictionary<string, object> _uiStyleStatus;
        private Dictionary<string, object> _deviceAlertStatus;
        private DoorbellApp.RuntimeProcessSnapshot _runtimeProcess;
        private bool _watchdogAvailable;
        private long _watchdogSignalWallMs;
        private bool _uiRunning;

        public event Action<UiEvent> UiEventReceived;

        public bool Start(string dataDir, string bootJson)
        {
            CoreInterop.Preload();
            try { _tts = new SpeechSynthesizer(); } catch { _tts = null;  }
            _secretStore = new DpapiSecretStore(dataDir);

            _logCb = (user, level, line) =>
            {
                try { Debug.WriteLine("[core] " + CoreInterop.ReadUtf8(line)); }
                catch { /* managed exceptions must never cross the native callback boundary */ }
            };
            _ttsCb = (user, text, lang) =>
            {
                try { Speak(CoreInterop.ReadUtf8(text), CoreInterop.ReadUtf8(lang)); }
                catch { }
            };
            _releaseBufferCb = (user, buffer) =>
            {
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            };
            _httpsCb = (user, method, url, headers, body, bodyLength, responseOut, statusOut) =>
            {
                try
                {
                    if (responseOut != IntPtr.Zero) Marshal.WriteIntPtr(responseOut, IntPtr.Zero);
                    if (statusOut != IntPtr.Zero) Marshal.WriteInt32(statusOut, 0);
                    byte[] response;
                    int status;
                    int rc = WinHttpTransport.Request(CoreInterop.ReadUtf8(method),
                        CoreInterop.ReadUtf8(url), CoreInterop.ReadUtf8(headers), body, bodyLength,
                        out response, out status);
                    if (rc != 0) return rc;
                    if (statusOut != IntPtr.Zero) Marshal.WriteInt32(statusOut, status);
                    if (responseOut != IntPtr.Zero)
                        Marshal.WriteIntPtr(responseOut, NativeUtf8.Alloc(response));
                    return 0;
                }
                catch { return -1; }
            };
            _secureGetCb = (user, key, valueOut) =>
            {
                try
                {
                    if (valueOut == IntPtr.Zero) return -1;
                    Marshal.WriteIntPtr(valueOut, IntPtr.Zero);
                    string value = _secretStore.Get(CoreInterop.ReadUtf8(key));
                    if (value == null) return -1;
                    Marshal.WriteIntPtr(valueOut, NativeUtf8.Alloc(value));
                    return 0;
                }
                catch { return -1; }
            };
            _securePutCb = (user, key, value) =>
            {
                try { return _secretStore.Put(CoreInterop.ReadUtf8(key), CoreInterop.ReadUtf8(value)) ? 0 : -1; }
                catch { return -1; }
            };
            _deviceInfoCb = (user, jsonOut) =>
            {
                try
                {
                    if (jsonOut == IntPtr.Zero) return -1;
                    Marshal.WriteIntPtr(jsonOut, IntPtr.Zero);
                    Marshal.WriteIntPtr(jsonOut, NativeUtf8.Alloc(DeviceInfoProvider.SnapshotJson()));
                    return 0;
                }
                catch { return -1; }
            };
            var plat = new CoreInterop.DbPlatformV2
            {
                struct_size = checked((uint)Marshal.SizeOf(typeof(CoreInterop.DbPlatformV2))),
                version = CoreInterop.DbPlatformV2Version,
                user = IntPtr.Zero,
                https_request = Marshal.GetFunctionPointerForDelegate(_httpsCb),
                secure_get = Marshal.GetFunctionPointerForDelegate(_secureGetCb),
                secure_put = Marshal.GetFunctionPointerForDelegate(_securePutCb),
                log_line = Marshal.GetFunctionPointerForDelegate(_logCb),
                tts_speak = Marshal.GetFunctionPointerForDelegate(_ttsCb),
                device_info = Marshal.GetFunctionPointerForDelegate(_deviceInfoCb),
                release_buffer = Marshal.GetFunctionPointerForDelegate(_releaseBufferCb),
            };
            _core = CoreInterop.db_core_create_v2(ref plat, dataDir, bootJson);
            if (_core == IntPtr.Zero) return false;

            _uiCb = (user, ev) =>
            {
                try
                {
                    string s = CoreInterop.ReadUtf8(ev);
                    var d = _json.Deserialize<Dictionary<string, object>>(s);
                    var e = new UiEvent { T = d != null && d.ContainsKey("t") ? d["t"] as string : "", Data = d };
                    if (e.T == "call_recovery_required")
                        lock (_eventLock) _pendingRecovery = e;
                    UiEventReceived?.Invoke(e);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine("ui event parse error: " + ex.Message);
                }
            };
            CoreInterop.db_core_set_ui_callback(_core, _uiCb, IntPtr.Zero);
            if (CoreInterop.db_core_start(_core) == 0) return true;
            CoreInterop.db_core_destroy(_core);
            _core = IntPtr.Zero;
            return false;
        }

        private void Speak(string text, string lang)
        {
            if (_tts == null || string.IsNullOrEmpty(text)) return;
            try
            {
                try
                {
                    var culture = new CultureInfo(string.IsNullOrEmpty(lang) ? "ja-JP" :
                        (lang == "ja" ? "ja-JP" : lang));
                    foreach (var v in _tts.GetInstalledVoices())
                        if (v.Enabled && v.VoiceInfo.Culture.TwoLetterISOLanguageName ==
                            culture.TwoLetterISOLanguageName)
                        {
                            _tts.SelectVoice(v.VoiceInfo.Name);
                            break;
                        }
                }
                catch { }
                _tts.SpeakAsyncCancelAll();
                _tts.SpeakAsync(text);
            }
            catch (Exception ex)
            {
                Debug.WriteLine("tts error: " + ex.Message);
            }
        }

        public string Press(string doorId) => PressPurpose(doorId, "");

        public string PressPurpose(string doorId, string purpose)
        {
            lock (_nativeLock)
                return _core == IntPtr.Zero ? null : CoreInterop.TakeUtf8(
                    CoreInterop.db_core_press_v2(_core, doorId ?? "", purpose ?? ""));
        }

        public bool SelectPurpose(string doorId, string callId, string purpose)
        {
            if (string.IsNullOrEmpty(callId) || string.IsNullOrEmpty(purpose)) return false;
            lock (_nativeLock)
                return _core != IntPtr.Zero && CoreInterop.db_core_select_purpose_v2(
                    _core, doorId ?? "", callId, purpose) == 0;
        }

        public bool CancelCall(string doorId, string callId, string reason)
        {
            if (string.IsNullOrEmpty(callId)) return false;
            lock (_nativeLock)
                return _core != IntPtr.Zero && CoreInterop.db_core_cancel_call_v2(
                    _core, doorId ?? "", callId, reason ?? "visitor") == 0;
        }

        public void ReportCallRecovery(string callId, bool restored)
        {
            if (string.IsNullOrEmpty(callId)) return;
            lock (_nativeLock)
                if (_core != IntPtr.Zero) CoreInterop.db_core_report_call_recovery(
                    _core, callId, restored ? 1 : 0);
        }

        public bool ReportCallAnswered(string doorId, string callId, int stageRevision)
        {
            if (string.IsNullOrEmpty(doorId) || string.IsNullOrEmpty(callId) ||
                stageRevision < 0) return false;
            lock (_nativeLock)
                return _core != IntPtr.Zero && CoreInterop.db_core_report_call_answered_v2(
                    _core, doorId, callId, stageRevision) == 0;
        }

        public bool ReportCallEnded(string doorId, string callId, int stageRevision,
                                    string reason = "sip_ended")
        {
            if (string.IsNullOrEmpty(doorId) || string.IsNullOrEmpty(callId) ||
                stageRevision < 0) return false;
            lock (_nativeLock)
                return _core != IntPtr.Zero && CoreInterop.db_core_report_call_ended_v2(
                    _core, doorId, callId, stageRevision, reason ?? "sip_ended") == 0;
        }

        public UiEvent TakePendingRecovery()
        {
            lock (_eventLock)
            {
                UiEvent value = _pendingRecovery;
                _pendingRecovery = null;
                return value;
            }
        }

        public void SetVisitorLang(string door, string lang)
        { if (_core != IntPtr.Zero) CoreInterop.db_core_set_visitor_lang(_core, door ?? "", lang ?? "ja"); }

        public void QuickReply(string replyId, string door)
        { if (_core != IntPtr.Zero && !string.IsNullOrEmpty(replyId)) CoreInterop.db_core_quick_reply(_core, replyId, door ?? ""); }

        public bool QuickReplyV2(string replyId, string door, string callId, int stageRevision)
        {
            if (string.IsNullOrEmpty(replyId) || string.IsNullOrEmpty(callId) ||
                stageRevision < 0) return false;
            lock (_nativeLock)
                return _core != IntPtr.Zero && CoreInterop.db_core_quick_reply_v2(
                    _core, replyId, door ?? "", callId, stageRevision) == 0;
        }

        public void SpeakText(string text, string lang) { Speak(text, lang); }

        public bool Emergency(bool active)
        {
            lock (_nativeLock)
                return _core != IntPtr.Zero &&
                    CoreInterop.db_core_emergency_v2(_core, active ? 1 : 0) != 0;
        }

        public void SipCall(string target, string mode)
        { if (_core != IntPtr.Zero && !string.IsNullOrEmpty(target)) CoreInterop.db_core_sip_call(_core, target, mode ?? ""); }

        public void SipHangup() { if (_core != IntPtr.Zero) CoreInterop.db_core_sip_hangup(_core); }

        public bool SipSendDtmf(string digits)
        {
            if (string.IsNullOrEmpty(digits)) return false;
            lock (_nativeLock)
                return _core != IntPtr.Zero && CoreInterop.db_core_sip_send_dtmf(_core, digits) == 0;
        }

        public string SipBackend => CoreInterop.ReadUtf8(CoreInterop.db_core_sip_backend()) ?? "unknown";

        public bool SipAvailable => string.Equals(SipBackend, "pjsip", StringComparison.Ordinal);

        public Dictionary<string, object> Status()
        {
            if (_core == IntPtr.Zero) return null;
            string s;
            lock (_nativeLock) s = CoreInterop.TakeUtf8(CoreInterop.db_core_status_json(_core));
            if (s == null) return null;
            try { return _json.Deserialize<Dictionary<string, object>>(s); }
            catch { return null; }
        }

        public Dictionary<string, object> Config()
        {
            if (_core == IntPtr.Zero) return null;
            string s;
            lock (_nativeLock) s = CoreInterop.TakeUtf8(CoreInterop.db_core_config_json(_core));
            if (s == null) return null;
            try { return _json.Deserialize<Dictionary<string, object>>(s); }
            catch { return null; }
        }

        public Dictionary<string, object> PairingInfo()
        {
            if (_core == IntPtr.Zero) return null;
            string s;
            lock (_nativeLock) s = CoreInterop.TakeUtf8(CoreInterop.db_core_pairing_json(_core));
            if (s == null) return null;
            try { return _json.Deserialize<Dictionary<string, object>>(s); }
            catch { return null; }
        }

        public void JoinCluster(string host, string pin)
        {
            if (string.IsNullOrEmpty(host) || string.IsNullOrEmpty(pin)) return;
            lock (_nativeLock) if (_core != IntPtr.Zero) CoreInterop.db_core_join_cluster(_core, host, pin);
        }

        public bool FoundCluster()
        {
            lock (_nativeLock) return _core != IntPtr.Zero && CoreInterop.db_core_found_cluster(_core) != 0;
        }

        public void SetPairingMode(int seconds)
        {
            lock (_nativeLock) if (_core != IntPtr.Zero) CoreInterop.db_core_pairing_mode(_core, seconds);
        }

        public void InviteDevice(string nodeId)
        {
            if (string.IsNullOrEmpty(nodeId)) return;
            lock (_nativeLock) if (_core != IntPtr.Zero) CoreInterop.db_core_invite_device(_core, nodeId);
        }

        public void PublishRuntimeContracts(string role, bool safeMode)
        {
            lock (_nativeLock)
            {
                if (_core == IntPtr.Zero) return;
                string backend = SipBackend;
                CoreInterop.db_core_set_capabilities_json(_core,
                    RuntimeContracts.Json(RuntimeContracts.Capabilities(backend, role, safeMode)));
                CoreInterop.db_core_set_runtime_status_json(_core,
                    RuntimeContracts.Json(RuntimeStatus(role, backend, safeMode)));
                if (RuntimeContracts.SupportsUiManifest(role))
                    CoreInterop.db_core_set_ui_manifest_json(_core,
                        RuntimeContracts.Json(RuntimeContracts.UiManifest(role)));
            }
        }

        internal void PublishRuntimeHealth(string role, bool safeMode,
                                           DoorbellApp.RuntimeProcessSnapshot process,
                                           bool watchdogAvailable, long watchdogSignalWallMs,
                                           bool uiRunning)
        {
            lock (_nativeLock)
            {
                if (_core == IntPtr.Zero || process == null) return;
                _runtimeProcess = process;
                _watchdogAvailable = watchdogAvailable;
                _watchdogSignalWallMs = watchdogSignalWallMs;
                _uiRunning = uiRunning;
                var status = RuntimeStatus(role, SipBackend, safeMode);
                CoreInterop.db_core_set_runtime_status_json(_core, RuntimeContracts.Json(status));
            }
        }

        public void PublishUiStyleStatus(string role, bool safeMode,
                                         Dictionary<string, object> report)
        {
            lock (_nativeLock)
            {
                if (_core == IntPtr.Zero) return;
                _uiStyleStatus = report ?? new Dictionary<string, object>();
                var status = RuntimeStatus(role, SipBackend, safeMode);
                CoreInterop.db_core_set_runtime_status_json(_core, RuntimeContracts.Json(status));
            }
        }

        public void PublishDeviceAlertStatus(string role, bool safeMode,
                                             Dictionary<string, object> report)
        {
            lock (_nativeLock)
            {
                if (_core == IntPtr.Zero) return;
                _deviceAlertStatus = report ?? new Dictionary<string, object>();
                var status = RuntimeStatus(role, SipBackend, safeMode);
                CoreInterop.db_core_set_runtime_status_json(_core, RuntimeContracts.Json(status));
            }
        }

        private Dictionary<string, object> RuntimeStatus(string role, string backend, bool safeMode)
        {
            var status = RuntimeContracts.Status(role, backend, safeMode);
            if (_uiStyleStatus != null) status["ui_style"] = _uiStyleStatus;
            if (_deviceAlertStatus != null) status["device_alert"] = _deviceAlertStatus;
            RuntimeContracts.ApplyProcessHealth(status, _runtimeProcess, safeMode,
                _watchdogAvailable, _watchdogSignalWallMs, _uiRunning);
            return status;
        }

        public static object Dig(Dictionary<string, object> root, string dotpath)
        {
            object cur = root;
            foreach (var part in dotpath.Split('.'))
            {
                var d = cur as Dictionary<string, object>;
                if (d == null || !d.TryGetValue(part, out cur)) return null;
            }
            return cur;
        }

        public void Dispose()
        {
            if (_core != IntPtr.Zero)
            {
                CoreInterop.db_core_set_ui_callback(_core, null, IntPtr.Zero);
                CoreInterop.db_core_stop(_core);
                CoreInterop.db_core_destroy(_core);
                _core = IntPtr.Zero;
            }
            _tts?.Dispose();
        }
    }
}
