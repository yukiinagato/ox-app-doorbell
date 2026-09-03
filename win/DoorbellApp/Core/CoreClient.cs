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

    /// <summary>Outcome of one cluster-password check (core: &gt;0, 0, -1, -2).</summary>
    public enum AdminPasswordVerdict
    {
        /// <summary>Core cannot answer at all: no export, or core is not started.</summary>
        Unavailable,
        Accepted,
        Rejected,
        /// <summary>Too many failures; core shares the lockout with the web login.</summary>
        LockedOut,
        /// <summary>No cluster password has been set yet, so the next entry sets it.</summary>
        NotSet,
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
        private CoreInterop.SecureDeleteCb _secureDeleteCb;
        private CoreInterop.DeviceInfoCb _deviceInfoCb;
        private CoreInterop.PowerStateCb _powerStateCb;
        private CoreInterop.ReleaseBufferCb _releaseBufferCb;
        private CoreInterop.SipSetMicMutedFn _sipSetMicMuted;
        private CoreInterop.MintJoinTokenFn _mintJoinToken;
        private CoreInterop.AdminPasswordVerifyFn _adminPasswordVerify;
        private CoreInterop.AdminPasswordSetFn _adminPasswordSet;
        private CoreInterop.SetConfigJsonFn _setConfigJson;
        private CoreInterop.LastWriteWarningsFn _lastWriteWarnings;
        private CoreInterop.ConfigBatchJsonFn _configBatchJson;
        private CoreInterop.DeleteConfigKeyFn _deleteConfigKey;
        private CoreInterop.CallLogJsonV2Fn _callLogJsonV2;
        private bool _optionalProbed;
        private bool _cameraAvailable;
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
            _secureDeleteCb = (user, key) =>
            {
                try { return _secretStore.Delete(CoreInterop.ReadUtf8(key)) ? 0 : -1; }
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
            _powerStateCb = (user, jsonOut) =>
            {
                try
                {
                    if (jsonOut == IntPtr.Zero) return -1;
                    Marshal.WriteIntPtr(jsonOut, IntPtr.Zero);
                    Marshal.WriteIntPtr(jsonOut,
                        NativeUtf8.Alloc(DeviceInfoProvider.PowerStateJson()));
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
                secure_delete = Marshal.GetFunctionPointerForDelegate(_secureDeleteCb),
                power_state = Marshal.GetFunctionPointerForDelegate(_powerStateCb),
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

        /// <summary>
        /// Binds every entry point that lands with the batch-2 core delta (spec 5.5). Each one is
        /// optional: an older Core simply reports the feature as unavailable and the shell hides
        /// or degrades it rather than terminating at the first call.
        /// </summary>
        private void ProbeOptionalExports()
        {
            lock (_nativeLock)
            {
                if (_optionalProbed) return;
                _optionalProbed = true;
                _sipSetMicMuted = CoreInterop.OptionalExport<CoreInterop.SipSetMicMutedFn>(
                    "db_core_sip_set_mic_muted");
                _mintJoinToken = CoreInterop.OptionalExport<CoreInterop.MintJoinTokenFn>(
                    "db_core_mint_join_token_json");
                _adminPasswordVerify =
                    CoreInterop.OptionalExport<CoreInterop.AdminPasswordVerifyFn>(
                        "db_core_admin_password_verify");
                _adminPasswordSet = CoreInterop.OptionalExport<CoreInterop.AdminPasswordSetFn>(
                    "db_core_admin_password_set");
                _setConfigJson = CoreInterop.OptionalExport<CoreInterop.SetConfigJsonFn>(
                    "db_core_set_config_json");
                _lastWriteWarnings = CoreInterop.OptionalExport<CoreInterop.LastWriteWarningsFn>(
                    "db_core_last_write_warnings_json");
                _configBatchJson = CoreInterop.OptionalExport<CoreInterop.ConfigBatchJsonFn>(
                    "db_core_config_batch_json");
                _deleteConfigKey = CoreInterop.OptionalExport<CoreInterop.DeleteConfigKeyFn>(
                    "db_core_delete_config_key");
                _callLogJsonV2 = CoreInterop.OptionalExport<CoreInterop.CallLogJsonV2Fn>(
                    "db_core_call_log_json_v2");
            }
        }

        /// <summary>
        /// True when this Core build exports a microphone mute entry point. The control row hides
        /// the microphone toggle instead of offering a button that cannot do anything.
        /// </summary>
        public bool SipMicMuteAvailable
        {
            get
            {
                ProbeOptionalExports();
                return _sipSetMicMuted != null;
            }
        }

        public bool SipSetMicMuted(bool muted)
        {
            if (!SipMicMuteAvailable) return false;
            lock (_nativeLock)
                return _core != IntPtr.Zero && _sipSetMicMuted(_core, muted ? 1 : 0) == 0;
        }

        /// <summary>
        /// One 管理パスワード for the whole cluster (spec 5.5). Verification is constant-time and
        /// rate-limited inside core, shared with the web login.
        /// </summary>
        public AdminPasswordVerdict AdminPasswordVerify(string password)
        {
            ProbeOptionalExports();
            if (_adminPasswordVerify == null || string.IsNullOrEmpty(password))
                return AdminPasswordVerdict.Unavailable;
            int result;
            lock (_nativeLock)
            {
                if (_core == IntPtr.Zero) return AdminPasswordVerdict.Unavailable;
                result = _adminPasswordVerify(_core, password);
            }
            // Fail closed: only an explicit positive answer opens anything.
            if (result > 0) return AdminPasswordVerdict.Accepted;
            if (result == 0) return AdminPasswordVerdict.Rejected;
            if (result == -1) return AdminPasswordVerdict.LockedOut;
            if (result == -2) return AdminPasswordVerdict.NotSet;
            return AdminPasswordVerdict.Unavailable;
        }

        /// <summary>
        /// Publishes the cluster password. current is empty when none has been set yet, which is
        /// how a device's migrated local digest becomes the shared secret.
        /// </summary>
        public bool AdminPasswordSet(string current, string next)
        {
            ProbeOptionalExports();
            if (_adminPasswordSet == null || string.IsNullOrEmpty(next)) return false;
            lock (_nativeLock)
                return _core != IntPtr.Zero &&
                    _adminPasswordSet(_core, current ?? "", next) == 0;
        }

        /// <summary>True once core can answer for the shared password.</summary>
        public bool AdminPasswordAvailable
        {
            get
            {
                ProbeOptionalExports();
                return _adminPasswordVerify != null;
            }
        }

        /// <summary>True when the cluster already carries a replicated password hash.</summary>
        public bool AdminPasswordConfigured
        {
            get
            {
                object value = Dig(Config(), "admin.password_hash");
                return value != null && !string.IsNullOrEmpty(value.ToString());
            }
        }

        /// <summary>
        /// True when core would answer -2: it can verify, but no cluster password exists yet.
        /// Nothing that must stay reachable — clearing a running SOS alarm above all — may be
        /// gated behind a password in that state.
        /// </summary>
        public bool AdminPasswordUnset
        {
            get { return AdminPasswordAvailable && !AdminPasswordConfigured; }
        }

        /// <summary>
        /// Core's own answer for the SOS clear control: emergency.cancel_requires_pin AND a
        /// password actually being set. The header is explicit that the control must never be
        /// gated on cancel_requires_pin alone. Null means this core does not report it.
        /// </summary>
        public bool? EmergencyCancelRequiresPassword(Dictionary<string, object> status)
        {
            object value = Dig(status, "emergency.cancel_requires_password");
            return value is bool ? (bool?)(bool)value : null;
        }

        /// <summary>
        /// Native configuration writes with the same validation and advisory warnings as the web
        /// (spec 5.5). Returns the result document, or null when this Core cannot answer.
        /// </summary>
        public bool SetConfigJson(string key, string valueJson)
        {
            ProbeOptionalExports();
            if (_setConfigJson == null || string.IsNullOrEmpty(key)) return false;
            lock (_nativeLock)
                return _core != IntPtr.Zero &&
                    _setConfigJson(_core, key, valueJson ?? "null") == 0;
        }

        /// <summary>
        /// Readability warnings from the write that just committed: the same array the batch form
        /// embeds, and an empty array when there is nothing to report. A warning never means the
        /// write failed, so it is shown as the measured ratio, not as an error.
        /// </summary>
        public string LastWriteWarnings()
        {
            ProbeOptionalExports();
            if (_lastWriteWarnings == null) return null;
            lock (_nativeLock)
                return _core == IntPtr.Zero ? null :
                    CoreInterop.TakeUtf8(_lastWriteWarnings(_core));
        }

        /// <summary>
        /// A batch write answers with the /api/config/batch document, so the caller can render the
        /// advisory warnings core returns instead of guessing at them.
        /// </summary>
        public string ConfigBatchJson(string json)
        {
            ProbeOptionalExports();
            if (_configBatchJson == null || string.IsNullOrEmpty(json)) return null;
            lock (_nativeLock)
                return _core == IntPtr.Zero ? null :
                    CoreInterop.TakeUtf8(_configBatchJson(_core, json));
        }

        public bool DeleteConfigKey(string key)
        {
            ProbeOptionalExports();
            if (_deleteConfigKey == null || string.IsNullOrEmpty(key)) return false;
            lock (_nativeLock)
                return _core != IntPtr.Zero && _deleteConfigKey(_core, key) == 0;
        }

        /// <summary>
        /// The cluster-wide announcement is the door target "*" (core commit 0fb8d27). A
        /// door-specific announcement always overrides it, so the two are never merged here.
        /// </summary>
        public const string GlobalNoticeDoor = "*";

        public bool SetGlobalNotice(string text, long expiresMs)
        {
            return SetDoorNotice(GlobalNoticeDoor, text, expiresMs);
        }

        public bool ClearGlobalNotice()
        {
            return ClearDoorNotice(GlobalNoticeDoor);
        }

        /// <summary>
        /// Triggers the configured unlock action. Returns core's code: 0 queued, -2 unknown door,
        /// and -3 when nothing is configured, which the shell must say out loud.
        /// </summary>
        public int OpenDoor(string door)
        {
            if (string.IsNullOrEmpty(door)) return -1;
            lock (_nativeLock)
                return _core == IntPtr.Zero ? -1 : CoreInterop.db_core_open_door(_core, door);
        }

        /// <summary>True when history can page older with an exclusive upper bound.</summary>
        public bool CallLogPagingAvailable
        {
            get
            {
                ProbeOptionalExports();
                return _callLogJsonV2 != null;
            }
        }

        /// <summary>One page of call history older than beforeMs; zero means "the newest".</summary>
        public Dictionary<string, object> CallLogPage(long sinceMs, long beforeMs, int limit)
        {
            if (!CallLogPagingAvailable) return null;
            string s;
            lock (_nativeLock)
            {
                if (_core == IntPtr.Zero) return null;
                s = CoreInterop.TakeUtf8(_callLogJsonV2(_core, sinceMs, beforeMs, limit));
            }
            if (s == null) return null;
            try { return _json.Deserialize<Dictionary<string, object>>(s); }
            catch { return null; }
        }

        /// <summary>Local wall clock rendered by core in the cluster time zone.</summary>
        public Dictionary<string, object> LocalTime(long wallMs)
        {
            if (_core == IntPtr.Zero) return null;
            string s;
            lock (_nativeLock)
                s = CoreInterop.TakeUtf8(CoreInterop.db_core_local_time_json(_core, wallMs));
            if (s == null) return null;
            try { return _json.Deserialize<Dictionary<string, object>>(s); }
            catch { return null; }
        }

        public bool TimeSyncNow()
        {
            lock (_nativeLock)
                return _core != IntPtr.Zero && CoreInterop.db_core_time_sync_now(_core) != 0;
        }

        /// <summary>Effective {call,sos,idle} volumes for this device, 0-100.</summary>
        public Dictionary<string, object> AudioVolumes(string deviceId)
        {
            if (_core == IntPtr.Zero) return null;
            string s;
            lock (_nativeLock)
                s = CoreInterop.TakeUtf8(CoreInterop.db_core_audio_json(_core, deviceId ?? ""));
            if (s == null) return null;
            try { return _json.Deserialize<Dictionary<string, object>>(s); }
            catch { return null; }
        }

        public bool SetDoorNotice(string door, string text, long expiresMs)
        {
            if (string.IsNullOrEmpty(door) || string.IsNullOrEmpty(text)) return false;
            lock (_nativeLock)
                return _core != IntPtr.Zero && CoreInterop.db_core_set_door_notice(
                    _core, door, text, expiresMs) == 0;
        }

        public bool ClearDoorNotice(string door)
        {
            if (string.IsNullOrEmpty(door)) return false;
            lock (_nativeLock)
                return _core != IntPtr.Zero &&
                    CoreInterop.db_core_clear_door_notice(_core, door) == 0;
        }

        /// <summary>Call history, newest first. limit is clamped by core to 1..500.</summary>
        public Dictionary<string, object> CallLog(long sinceMs, int limit)
        {
            if (_core == IntPtr.Zero) return null;
            string s;
            lock (_nativeLock)
                s = CoreInterop.TakeUtf8(
                    CoreInterop.db_core_call_log_json(_core, sinceMs, limit));
            if (s == null) return null;
            try { return _json.Deserialize<Dictionary<string, object>>(s); }
            catch { return null; }
        }

        public bool CallLogMarkSeen(string upToHlc)
        {
            lock (_nativeLock)
                return _core != IntPtr.Zero &&
                    CoreInterop.db_core_call_log_mark_seen(_core, upToHlc ?? "") == 0;
        }

        public string CoreVersion =>
            CoreInterop.ReadUtf8(CoreInterop.db_core_version()) ?? "";

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

        /// <summary>
        /// Mints or refreshes the Pairing PIN without opening the pairing-mode window
        /// (spec 5.4): {ok,host,pin,expires_s}. Every PIN card uses this, never StartPairing.
        /// A Core that predates the export returns null instead of terminating the shell.
        /// </summary>
        public Dictionary<string, object> MintJoinToken(int seconds)
        {
            ProbeOptionalExports();
            if (_mintJoinToken == null)
            {
                Debug.WriteLine("core has no db_core_mint_join_token_json; no PIN minted");
                return null;
            }
            string s;
            lock (_nativeLock)
            {
                if (_core == IntPtr.Zero) return null;
                s = CoreInterop.TakeUtf8(_mintJoinToken(_core, seconds));
            }
            if (s == null) return null;
            try { return _json.Deserialize<Dictionary<string, object>>(s); }
            catch { return null; }
        }

        /// <summary>
        /// Whether this node can serve camera frames right now. CameraProbe owns the answer and
        /// republishes the contracts whenever it changes.
        /// </summary>
        public bool CameraAvailable
        {
            get { return _cameraAvailable; }
            set { _cameraAvailable = value; }
        }

        /// <summary>Removes one secure-store entry, for the revoke/unpair factory reset.</summary>
        public bool DeleteSecret(string key)
        {
            if (_secretStore == null || string.IsNullOrEmpty(key)) return false;
            try { return _secretStore.Delete(key); }
            catch { return false; }
        }

        /// <summary>
        /// Opens the "add everything nearby" pairing-mode window. Only the explicit
        /// bulk-add button calls this; PIN cards use MintJoinToken.
        /// </summary>
        public Dictionary<string, object> StartPairing(int seconds)
        {
            string s;
            lock (_nativeLock)
            {
                if (_core == IntPtr.Zero) return null;
                s = CoreInterop.TakeUtf8(CoreInterop.db_core_start_pairing_json(_core, seconds));
            }
            if (s == null) return null;
            try { return _json.Deserialize<Dictionary<string, object>>(s); }
            catch { return null; }
        }

        public void InviteDirect(string addr, string nodeId, string publicKeyHex)
        {
            if (string.IsNullOrEmpty(addr) || string.IsNullOrEmpty(publicKeyHex)) return;
            lock (_nativeLock)
                if (_core != IntPtr.Zero)
                    CoreInterop.db_core_invite_direct(_core, addr, nodeId ?? "", publicKeyHex);
        }

        public void DenyDevice(string nodeId)
        {
            if (string.IsNullOrEmpty(nodeId)) return;
            lock (_nativeLock)
                if (_core != IntPtr.Zero) CoreInterop.db_core_deny_device(_core, nodeId);
        }

        /// <summary>Re-runs the secure-store write after state "persist_error".</summary>
        public bool RetryPairingPersistence()
        {
            lock (_nativeLock)
                return _core != IntPtr.Zero &&
                    CoreInterop.db_core_retry_pairing_persistence(_core) != 0;
        }

        /// <summary>Leaves the cluster. Core emits pairing_state with state "unpaired".</summary>
        public void Unpair()
        {
            lock (_nativeLock) if (_core != IntPtr.Zero) CoreInterop.db_core_unpair(_core);
        }

        /// <summary>Returns size*size row-major modules, one byte per module, or null.</summary>
        public static byte[] QrEncode(string text, out int size)
        {
            size = 0;
            if (string.IsNullOrEmpty(text)) return null;
            int encoded;
            IntPtr p = CoreInterop.db_core_qr_encode(text, out encoded);
            if (p == IntPtr.Zero) return null;
            try
            {
                if (encoded <= 0 || encoded > 4096) return null;
                var modules = new byte[encoded * encoded];
                Marshal.Copy(p, modules, 0, modules.Length);
                size = encoded;
                return modules;
            }
            finally { CoreInterop.db_free(p); }
        }

        /// <summary>Synchronously decodes one 8-bit grayscale image. Returns null when empty.</summary>
        public static string QrDecodeGray(byte[] gray, int width, int height)
        {
            if (gray == null || width <= 0 || height <= 0 ||
                gray.Length < width * height) return null;
            IntPtr text;
            if (CoreInterop.db_core_qr_decode(gray, width, height, out text) != 0) return null;
            return CoreInterop.TakeUtf8(text);
        }

        public void QrScanStart()
        {
            lock (_nativeLock) if (_core != IntPtr.Zero) CoreInterop.db_core_qr_scan_start(_core);
        }

        public void QrScanStop()
        {
            lock (_nativeLock) if (_core != IntPtr.Zero) CoreInterop.db_core_qr_scan_stop(_core);
        }

        /// <summary>Pushes one raw frame. format: 0=NV21, 1=NV12, 2=YUY2, 3=BGRA.</summary>
        public void PushCameraFrame(byte[] data, int format, int width, int height, int stride,
                                    long timestampMs)
        {
            if (data == null || data.Length == 0 || width <= 0 || height <= 0) return;
            var pinned = GCHandle.Alloc(data, GCHandleType.Pinned);
            try
            {
                lock (_nativeLock)
                    if (_core != IntPtr.Zero)
                        CoreInterop.db_core_on_camera_frame(_core, pinned.AddrOfPinnedObject(),
                            format, width, height, stride, timestampMs);
            }
            finally { pinned.Free(); }
        }

        public void PublishRuntimeContracts(string role, bool safeMode)
        {
            lock (_nativeLock)
            {
                if (_core == IntPtr.Zero) return;
                string backend = SipBackend;
                CoreInterop.db_core_set_capabilities_json(_core,
                    RuntimeContracts.Json(RuntimeContracts.Capabilities(backend, role, safeMode,
                                                                        SipMicMuteAvailable,
                                                                        _cameraAvailable)));
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
