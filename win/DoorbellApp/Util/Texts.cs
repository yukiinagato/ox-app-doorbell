// 文言解決の前段 (L10n の手前): config i18n_overrides.<lang>.<key> があればそれを使い、
// 無ければ組込 resx (L10n) へ回落する。訪客言語 (門口機の言語バー) の現在値もここが持つ。
// 上書き文言のプレースホルダは i18n/strings.yaml と同じ名前付き ({unit} 等) — 出現順に
// 引数で埋める (tools/gen_i18n.py が {0}/%1$s へ変換するのと同じ順序規約)。
using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using DoorbellApp.Core;

namespace DoorbellApp.Util
{
    public static class Texts
    {
        private static readonly Regex NamedPlaceholder =
            new Regex(@"\{[A-Za-z_][A-Za-z0-9_]*\}", RegexOptions.Compiled);

        private static Dictionary<string, object> _cfg;
        private static Dictionary<string, object> _overrides;  // i18n_overrides.<lang>

        /// <summary>現在の表示言語 (門口機は訪客言語、室内機は boot.ui_lang)。</summary>
        public static string Lang { get; private set; }

        static Texts()
        {
            Lang = "ja";
        }

        /// <summary>設定ツリーの差し替え (起動時 / config_changed)。</summary>
        public static void SetConfig(Dictionary<string, object> cfg)
        {
            _cfg = cfg;
            ReloadOverrides();
        }

        /// <summary>表示言語の切替 (resx の CurrentUICulture も同時に切り替える)。</summary>
        public static void SetLang(string lang)
        {
            Lang = string.IsNullOrEmpty(lang) ? "ja" : lang;
            L10n.SetLanguage(Lang);
            ReloadOverrides();
        }

        private static void ReloadOverrides()
        {
            // i18n_overrides.<lang> のキーはドットを含む ("idle.touch_to_call") ため
            // Dig ではここまでしか辿れない — 中は素引きする。
            _overrides = CoreClient.Dig(_cfg, "i18n_overrides." + Lang) as Dictionary<string, object>;
        }

        public static string T(string key, params object[] args)
        {
            object ov;
            if (_overrides != null && _overrides.TryGetValue(key, out ov) && ov != null)
            {
                string s = ov.ToString();
                if (!string.IsNullOrEmpty(s)) return FillNamed(s, args);
            }
            return L10n.T(key, args);
        }

        private static string FillNamed(string s, object[] args)
        {
            if (args == null || args.Length == 0) return s;
            int i = 0;
            return NamedPlaceholder.Replace(s, m =>
            {
                if (i >= args.Length) return m.Value;
                object a = args[i++];
                return a == null ? "" : a.ToString();
            });
        }
    }
}
