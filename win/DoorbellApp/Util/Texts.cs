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

        public static string Lang { get; private set; }

        static Texts()
        {
            Lang = "ja";
        }

        public static void SetConfig(Dictionary<string, object> cfg)
        {
            _cfg = cfg;
            ReloadOverrides();
        }

        public static void SetLang(string lang)
        {
            Lang = string.IsNullOrEmpty(lang) ? "ja" : lang;
            L10n.SetLanguage(Lang);
            ReloadOverrides();
        }

        private static void ReloadOverrides()
        {
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
