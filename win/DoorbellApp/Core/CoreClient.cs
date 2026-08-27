// core のライフサイクルと UI イベント配送。デリゲートを field に保持して GC から守る。
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Speech.Synthesis;
using System.Web.Script.Serialization;

namespace DoorbellApp.Core
{
    public sealed class UiEvent
    {
        public string T;                       // state / chime / reply / event / config_changed / ...
        public Dictionary<string, object> Data;
        public string Str(string key) =>
            Data != null && Data.TryGetValue(key, out var v) && v != null ? v.ToString() : "";
    }

    public sealed class CoreClient : IDisposable
    {
        private IntPtr _core;
        private CoreInterop.UiEventCb _uiCb;       // rooted
        private CoreInterop.LogLineCb _logCb;      // rooted
        private CoreInterop.TtsSpeakCb _ttsCb;     // rooted
        private GCHandle _platPin;
        private SpeechSynthesizer _tts;
        private readonly JavaScriptSerializer _json = new JavaScriptSerializer();

        /// <summary>core からの UI イベント (呼び出しスレッドは core 内部 — 受け側で Dispatcher へ)。</summary>
        public event Action<UiEvent> UiEventReceived;

        public bool Start(string dataDir, string bootJson)
        {
            CoreInterop.Preload();
            try { _tts = new SpeechSynthesizer(); } catch { _tts = null; /* 音声なし環境 */ }

            _logCb = (user, level, line) =>
                Debug.WriteLine("[core] " + CoreInterop.ReadUtf8(line));
            _ttsCb = (user, text, lang) => Speak(CoreInterop.ReadUtf8(text), CoreInterop.ReadUtf8(lang));
            var plat = new CoreInterop.DbPlatform
            {
                user = IntPtr.Zero,
                https_request = IntPtr.Zero,
                secure_get = IntPtr.Zero,
                secure_put = IntPtr.Zero,
                log_line = Marshal.GetFunctionPointerForDelegate(_logCb),
                tts_speak = Marshal.GetFunctionPointerForDelegate(_ttsCb),
            };
            _core = CoreInterop.db_core_create(ref plat, dataDir, bootJson);
            if (_core == IntPtr.Zero) return false;

            _uiCb = (user, ev) =>
            {
                string s = CoreInterop.ReadUtf8(ev);
                try
                {
                    var d = _json.Deserialize<Dictionary<string, object>>(s);
                    var e = new UiEvent { T = d != null && d.ContainsKey("t") ? d["t"] as string : "", Data = d };
                    UiEventReceived?.Invoke(e);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine("ui event parse error: " + ex.Message + " " + s);
                }
            };
            CoreInterop.db_core_set_ui_callback(_core, _uiCb, IntPtr.Zero);
            return CoreInterop.db_core_start(_core) == 0;
        }

        private void Speak(string text, string lang)
        {
            if (_tts == null || string.IsNullOrEmpty(text)) return;
            try
            {
                // 日本語音声があれば選ぶ (Haruka 等)。無ければ既定音声のまま読む。
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

        public void Press(string doorId) { if (_core != IntPtr.Zero) CoreInterop.db_core_press(_core, doorId ?? ""); }

        /// <summary>用件ボタンからの按鈴 (config visit_purposes の id)。</summary>
        public void PressPurpose(string doorId, string purpose)
        { if (_core != IntPtr.Zero) CoreInterop.db_core_press_purpose(_core, doorId ?? "", purpose ?? ""); }

        /// <summary>訪客言語の切替。全ノードへ複製され {"t":"visitor_lang"} が返ってくる。</summary>
        public void SetVisitorLang(string door, string lang)
        { if (_core != IntPtr.Zero) CoreInterop.db_core_set_visitor_lang(_core, door ?? "", lang ?? "ja"); }

        /// <summary>クイック返信 (門口機へ配送 — 表示 + カスタム音声/TTS は core が決める)。</summary>
        public void QuickReply(string replyId, string door)
        { if (_core != IntPtr.Zero && !string.IsNullOrEmpty(replyId)) CoreInterop.db_core_quick_reply(_core, replyId, door ?? ""); }

        /// <summary>殻からの TTS 発話 (カスタム音声の再生に失敗した時の回落先)。</summary>
        public void SpeakText(string text, string lang) { Speak(text, lang); }

        /// <summary>SOS 緊急モード。true=発報 / false=解除 (解除前の PIN 検証は呼び出し側)。</summary>
        public void Emergency(bool active) { if (_core != IntPtr.Zero) CoreInterop.db_core_emergency(_core, active ? 1 : 0); }

        /// <summary>SIP 発呼。target: 内線番号 or "sip:host:port" (直呼)。mode: ""/"monitor"/"answer"。</summary>
        public void SipCall(string target, string mode)
        { if (_core != IntPtr.Zero && !string.IsNullOrEmpty(target)) CoreInterop.db_core_sip_call(_core, target, mode ?? ""); }

        public void SipHangup() { if (_core != IntPtr.Zero) CoreInterop.db_core_sip_hangup(_core); }

        public Dictionary<string, object> Status()
        {
            if (_core == IntPtr.Zero) return null;
            string s = CoreInterop.TakeUtf8(CoreInterop.db_core_status_json(_core));
            if (s == null) return null;
            try { return _json.Deserialize<Dictionary<string, object>>(s); }
            catch { return null; }
        }

        public Dictionary<string, object> Config()
        {
            if (_core == IntPtr.Zero) return null;
            string s = CoreInterop.TakeUtf8(CoreInterop.db_core_config_json(_core));
            if (s == null) return null;
            try { return _json.Deserialize<Dictionary<string, object>>(s); }
            catch { return null; }
        }

        /// <summary>設定ツリーをドットパスで辿る ("doors.d_front.label.ja" 等)。無ければ null。</summary>
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
                CoreInterop.db_core_stop(_core);
                CoreInterop.db_core_destroy(_core);
                _core = IntPtr.Zero;
            }
            if (_platPin.IsAllocated) _platPin.Free();
            _tts?.Dispose();
        }
    }
}
